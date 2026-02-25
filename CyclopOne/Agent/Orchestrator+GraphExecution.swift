import Foundation

// MARK: - Orchestrator Graph-Based Execution
// Sprint 4: Replaces the flat iteration loop with the LangGraph-style state graph.
// The step-driven loop remains unchanged.

extension Orchestrator {

    /// Run the flat iteration loop using the state graph.
    /// Replaces the body of runFlatIterationLoop() from Orchestrator+IterationLoops.swift.
    func runFlatLoopViaGraph(
        runId: String,
        command: String,
        completionToken: String,
        startIteration: Int,
        totalInput: Int,
        totalOutput: Int,
        journal: RunJournal,
        agentLoop: AgentLoop,
        replyChannel: (any ReplyChannel)?,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void,
        onConfirmationNeeded: @Sendable @escaping (String) async -> Bool,
        observer: (any AgentObserver)? = nil
    ) async -> RunResult {
        defer { lifecycle.cleanupCancelState() }

        // Build graph with all dependencies
        let graphConfig = await AgentGraphBuilder.build(
            agentLoop: agentLoop,
            verificationEngine: verificationEngine,
            brainModel: AgentConfig.defaultBrainModel,
            maxIterations: runConfig.maxIterations,
            verificationThreshold: runConfig.verificationThreshold,
            onStateChange: onStateChange,
            onMessage: onMessage,
            onConfirmationNeeded: onConfirmationNeeded
        )

        // Build shared state for the graph
        let graphState = GraphState(
            runId: runId,
            command: command,
            completionToken: completionToken,
            source: "chat",
            maxIterations: runConfig.maxIterations
        )

        // Inject initial pre-action screenshot from Orchestrator's prepareRun()
        if let initialSS = stepMachine.preActionScreenshot {
            await graphState.setPreActionScreenshot(initialSS)
        }

        // Set pre-iteration hook for Orchestrator-level concerns
        // (cancellation, network, timeout, budget warnings, display sleep).
        // The hook is @Sendable and runs on the GraphRunner actor, so all
        // Orchestrator property access goes through the actor-isolated helper.
        await graphConfig.runner.setPreIterationHook { [self] in
            try await self.checkPreIterationConditions(
                graphState: graphState,
                agentLoop: agentLoop,
                onMessage: onMessage,
                observer: observer
            )
        }

        // Run the graph — wrap in a Task so cancelCurrentRun() can cancel it immediately
        // via lifecycle.hardCancelAction, even mid-Claude-API-call.
        let graphRunTask = Task<String, Error> {
            try await graphConfig.runner.run(state: graphState)
        }
        lifecycle.hardCancelAction = { graphRunTask.cancel() }

        let finalNode: String
        do {
            finalNode = try await graphRunTask.value
        } catch is CancellationError {
            return await extractGraphResult(
                graphState: graphState, runId: runId, command: command,
                journal: journal, observer: observer,
                replyChannel: replyChannel, onStateChange: onStateChange,
                agentLoop: agentLoop
            )
        } catch {
            await journal.append(.fail(reason: error.localizedDescription))
            await journal.close()
            onMessage(ChatMessage(role: .system, content: "Error: \(error.localizedDescription)"))
            onStateChange(.error(error.localizedDescription))
            lifecycle.endRun()
            return RunResult(
                runId: runId, success: false, summary: error.localizedDescription,
                iterations: await graphState.iteration, finalScore: nil,
                totalInputTokens: await graphState.totalInputTokens,
                totalOutputTokens: await graphState.totalOutputTokens
            )
        }

        // Extract final result
        _ = finalNode  // Used for logging if needed
        return await extractGraphResult(
            graphState: graphState, runId: runId, command: command,
            journal: journal, observer: observer,
            replyChannel: replyChannel, onStateChange: onStateChange,
            agentLoop: agentLoop
        )
    }

    // MARK: - Pre-Iteration Conditions (Actor-Isolated)

    /// Actor-isolated helper for the pre-iteration hook.
    /// All Orchestrator property access is safe here because this runs
    /// on the Orchestrator actor's serial executor.
    func checkPreIterationConditions(
        graphState: GraphState,
        agentLoop: AgentLoop,
        onMessage: @Sendable @escaping (ChatMessage) -> Void,
        observer: (any AgentObserver)?
    ) async throws {
        // Update lifecycle iteration tracking
        let currentIter = await graphState.iteration
        lifecycle.currentIteration = currentIter

        // Cooperative cancellation
        if lifecycle.isCancellationRequested {
            await graphState.markCancelled()
            throw CancellationError()
        }

        // Network reachability
        if await !NetworkMonitor.shared.isReachable {
            NSLog("CyclopOne [GraphExecution]: Network unreachable, waiting...")
            onMessage(ChatMessage(role: .system, content: "Network offline -- pausing..."))
            let recovered = await NetworkMonitor.shared.waitForReachability(timeout: 60)
            if !recovered {
                await graphState.markError("Network unreachable for 60 seconds")
                throw CancellationError()
            }
        }

        // Run timeout
        if let timeoutReason = lifecycle.checkRunTimeout(maxRunDuration: runConfig.maxRunDuration) {
            await graphState.markError(timeoutReason)
            throw CancellationError()
        }

        // Early/budget warnings
        if let earlyMsg = lifecycle.checkEarlyWarning(
            iteration: currentIter,
            maxIterations: runConfig.maxIterations,
            earlyWarningIteration: runConfig.earlyWarningIteration
        ) {
            onMessage(ChatMessage(role: .system, content: earlyMsg))
            await agentLoop.injectIterationWarning(earlyMsg)
        }
        if let budgetMsg = lifecycle.checkBudgetWarning(
            iteration: currentIter,
            maxIterations: runConfig.maxIterations,
            budgetWarningPercent: runConfig.budgetWarningPercent
        ) {
            onMessage(ChatMessage(role: .system, content: budgetMsg))
        }

        // Token limit — Sprint 9: warn at 80%, force-complete at 100%
        let inputTokens = await graphState.totalInputTokens
        let outputTokens = await graphState.totalOutputTokens
        let totalTokens = inputTokens + outputTokens
        let tokenLimit = runConfig.maxTokensPerRun
        let warningThreshold = Int(Double(tokenLimit) * 0.8)

        if totalTokens >= tokenLimit {
            let reason = "Token limit reached (\(totalTokens)/\(tokenLimit))"
            NSLog("CyclopOne [GraphExecution]: %@", reason)
            await graphState.markError(reason)
            throw CancellationError()
        } else if totalTokens >= warningThreshold {
            let warningMsg = "Approaching token limit: \(totalTokens)/\(tokenLimit) tokens used (80%+). Wrap up the current task soon."
            NSLog("CyclopOne [GraphExecution]: Token warning — %d/%d", totalTokens, tokenLimit)
            onMessage(ChatMessage(role: .system, content: warningMsg))
            await agentLoop.injectIterationWarning(warningMsg)
        }

        // Display sleep
        if ScreenCaptureService.isDisplayAsleep() {
            NSLog("CyclopOne [GraphExecution]: Display asleep, waiting...")
            var waitCount = 0
            while ScreenCaptureService.isDisplayAsleep() && waitCount < 150 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                waitCount += 1
            }
            if ScreenCaptureService.isDisplayAsleep() {
                await graphState.markError("Display remained asleep for 5 minutes")
                throw CancellationError()
            }
        }

        // Observer notification
        ObserverNotifier.notifyIterationStart(
            observer, iteration: currentIter, maxIterations: runConfig.maxIterations
        )
    }

    // MARK: - Result Extraction

    /// Extract RunResult from GraphState after graph completes.
    private func extractGraphResult(
        graphState: GraphState,
        runId: String,
        command: String,
        journal: RunJournal,
        observer: (any AgentObserver)?,
        replyChannel: (any ReplyChannel)?,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        agentLoop: AgentLoop? = nil
    ) async -> RunResult {
        let iteration = await graphState.iteration
        let totalInput = await graphState.totalInputTokens
        let totalOutput = await graphState.totalOutputTokens
        let verifyInput = await graphState.verificationInputTokens
        let verifyOutput = await graphState.verificationOutputTokens
        let score = await graphState.verificationScore
        let passed = await graphState.verificationPassed
        let reason = await graphState.verificationReason
        let taskComplete = await graphState.taskComplete
        let hasError = await graphState.hasError
        let errorMessage = await graphState.errorMessage
        let isCancelled = await graphState.isCancelled

        // Cancelled
        if isCancelled {
            await journal.append(.cancelled())
            await journal.close()
            onStateChange(.idle)
            lifecycle.resetRunTracking()
            lifecycle.endRun()
            return RunResult(
                runId: runId, success: false, summary: "Cancelled by user",
                iterations: iteration, finalScore: nil,
                totalInputTokens: totalInput, totalOutputTokens: totalOutput
            )
        }

        // Error
        if hasError {
            await journal.append(.fail(reason: errorMessage))
            await journal.close()
            onStateChange(.error(errorMessage))
            lifecycle.endRun()
            return RunResult(
                runId: runId, success: false, summary: errorMessage,
                iterations: iteration, finalScore: nil,
                totalInputTokens: totalInput, totalOutputTokens: totalOutput
            )
        }

        // Task completed (verification handled by CompleteNode)
        if taskComplete {
            let summary = "Completed (score: \(score))"
            ObserverNotifier.notifyCompletion(
                observer, success: passed, summary: summary,
                score: score, iterations: iteration
            )
            await journal.append(.complete(summary: summary, finalScore: score))
            await journal.close()
            await recordRunCompletion(
                runId: runId, command: command, passed: passed,
                score: score, reason: reason, iteration: iteration,
                agentLoop: agentLoop
            )
            onStateChange(.done)
            lifecycle.endRun()
            let result = RunResult(
                runId: runId, success: passed, summary: summary,
                iterations: iteration, finalScore: score,
                totalInputTokens: totalInput, totalOutputTokens: totalOutput,
                verificationInputTokens: verifyInput,
                verificationOutputTokens: verifyOutput
            )
            updateClassifierContext(command: command, result: result)
            return result
        }

        // Max iterations reached or graph exited without completion
        let elapsed = lifecycle.runStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let maxIter = await graphState.maxIterations
        NSLog("CyclopOne [GraphExecution]: Run ended -- maxIterations=%d, elapsed=%.1fs",
              maxIter, elapsed)
        let summaryMsg = "Max iterations (\(maxIter)) reached"
        await journal.append(.fail(reason: summaryMsg))
        await journal.close()
        onStateChange(.done)
        lifecycle.endRun()
        return RunResult(
            runId: runId, success: false, summary: summaryMsg,
            iterations: iteration, finalScore: nil,
            totalInputTokens: totalInput, totalOutputTokens: totalOutput
        )
    }
}
