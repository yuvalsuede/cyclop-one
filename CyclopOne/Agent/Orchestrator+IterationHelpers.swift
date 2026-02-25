import Foundation

// MARK: - Orchestrator Iteration Helpers
// Shared helper methods for both flat and step-driven iteration loops:
// retry logic, iteration execution, pre/post checks, mid-step verification.
// Extracted from Orchestrator.swift in Sprint 1 (Refactoring).

extension Orchestrator {

    // MARK: - Helper Enums

    /// Result of pre-iteration checks. If an early exit is needed, contains the RunResult.
    /// Otherwise, `.continue` means "proceed with iteration".
    enum PreIterationCheckResult {
        case `continue`
        case earlyExit(RunResult)
    }

    /// Result of executing and awaiting a single iteration task.
    enum IterationTaskResult {
        case success(IterationResult)
        case earlyExit(RunResult)
    }

    /// Result of a mid-step verification check.
    struct MidStepVerificationResult {
        let passed: Bool
        let score: Int
        let reason: String
        let inputTokens: Int
        let outputTokens: Int
    }

    // MARK: - Iteration Retry (Sprint 14)

    /// Execute a single iteration wrapped in the circuit breaker and retry logic.
    ///
    /// The circuit breaker protects against cascade failures (e.g. Claude API down).
    /// Retry strategy is determined by error classification:
    /// - Transient errors: exponential backoff
    /// - Rate limits: fixed delay (respecting retry-after if available)
    /// - Permanent errors: no retry
    func executeIterationWithRetry(
        agentLoop: AgentLoop,
        iteration: Int,
        journal: RunJournal,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void,
        onConfirmationNeeded: @Sendable @escaping (String) async -> Bool,
        observer: (any AgentObserver)? = nil
    ) async throws -> IterationResult {
        var lastError: Error?

        // First attempt + retries: 0..<maxAttempts (not inclusive of maxAttempts)
        for attempt in 0..<runConfig.iterationRetryStrategy.maxAttempts {
            do {
                let result = try await apiCircuitBreaker.execute {
                    try await agentLoop.executeIteration(
                        onStateChange: onStateChange,
                        onMessage: onMessage,
                        onConfirmationNeeded: onConfirmationNeeded,
                        observer: observer
                    )
                }
                return result
            } catch let cbError as CircuitBreaker.CircuitBreakerError {
                // Circuit breaker is open -- propagate immediately, no retry
                throw cbError
            } catch {
                lastError = error
                let classification = classifyError(error)

                // Determine if we should retry
                let strategy = retryStrategyFor(classification)
                guard let delay = strategy.nextDelay(attempt: attempt) else {
                    // No more retries for this classification
                    throw error
                }

                // Log retry attempt
                let classLabel: String
                switch classification {
                case .transient: classLabel = "transient"
                case .rateLimit: classLabel = "rate_limit"
                case .permanent: throw error  // Should not reach here, but safety net
                case .unknown: classLabel = "unknown"
                }

                await journal.append(.fail(reason: "Iteration \(iteration) attempt \(attempt + 1) failed (\(classLabel)), retrying in \(Int(delay))s"))

                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        throw lastError ?? APIError.invalidResponse
    }

    // MARK: - Execute and Await Iteration

    /// Execute a single iteration wrapped in a Task for hard-cancel support,
    /// with retry logic and circuit breaker. Handles CancellationError,
    /// CircuitBreakerError, and classified errors.
    /// Returns `.success(iterResult)` or `.earlyExit(runResult)`.
    func executeAndAwaitIteration(
        runId: String,
        iteration: Int,
        totalInput: Int,
        totalOutput: Int,
        journal: RunJournal,
        agentLoop: AgentLoop,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void,
        onConfirmationNeeded: @Sendable @escaping (String) async -> Bool,
        observer: (any AgentObserver)? = nil
    ) async -> IterationTaskResult {
        await journal.append(.iterationStart(iteration: iteration, screenshot: nil))

        let iterationTask = Task<IterationResult, Error> { [self] in
            try await self.executeIterationWithRetry(
                agentLoop: agentLoop,
                iteration: iteration,
                journal: journal,
                onStateChange: onStateChange,
                onMessage: onMessage,
                onConfirmationNeeded: onConfirmationNeeded,
                observer: observer
            )
        }
        lifecycle.currentIterationTask = iterationTask

        let iterResult: IterationResult
        do {
            iterResult = try await iterationTask.value
        } catch is CancellationError {
            NSLog("CyclopOne [Orchestrator]: Iteration %d hard-cancelled", iteration)
            await journal.append(.cancelled())
            await journal.close()
            onStateChange(.idle)
            let result = RunResult(
                runId: runId, success: false, summary: "Hard-cancelled by user",
                iterations: iteration, finalScore: nil,
                totalInputTokens: totalInput, totalOutputTokens: totalOutput
            )
            lifecycle.resetRunTracking()
            lifecycle.endRun()
            return .earlyExit(result)
        } catch let cbError as CircuitBreaker.CircuitBreakerError {
            let reason = "Circuit breaker open: \(cbError.localizedDescription)"
            let ssData = stepMachine.preActionScreenshot?.imageData
            ObserverNotifier.notifyError(observer, error: reason, screenshot: ssData, isFatal: true)
            await journal.append(.fail(reason: reason))
            await journal.close()
            onMessage(ChatMessage(role: .system, content: "Error: API circuit breaker triggered. \(cbError.localizedDescription)"))
            onStateChange(.error(reason))
            lifecycle.endRun()
            return .earlyExit(RunResult(
                runId: runId, success: false, summary: reason,
                iterations: iteration, finalScore: nil,
                totalInputTokens: totalInput, totalOutputTokens: totalOutput
            ))
        } catch {
            let classification = classifyError(error)
            let classLabel: String
            switch classification {
            case .permanent: classLabel = "permanent"
            case .transient: classLabel = "transient (retries exhausted)"
            case .rateLimit: classLabel = "rate limited (retries exhausted)"
            case .unknown: classLabel = "unknown"
            }
            let errMsg = "[\(classLabel)] \(error.localizedDescription)"
            let ssData = stepMachine.preActionScreenshot?.imageData
            ObserverNotifier.notifyError(observer, error: errMsg, screenshot: ssData, isFatal: true)
            await journal.append(.fail(reason: "Iteration \(iteration) \(classLabel) error: \(error.localizedDescription)"))
            await journal.close()
            onMessage(ChatMessage(role: .system, content: "Error [\(classLabel)]: \(error.localizedDescription)"))
            onStateChange(.error(error.localizedDescription))
            lifecycle.endRun()
            return .earlyExit(RunResult(
                runId: runId, success: false, summary: error.localizedDescription,
                iterations: iteration, finalScore: nil,
                totalInputTokens: totalInput, totalOutputTokens: totalOutput
            ))
        }

        // Check cancellation immediately after iteration completes
        if lifecycle.isCancellationRequested || iterResult.cancelled {
            await journal.append(.cancelled())
            await journal.close()
            onStateChange(.idle)
            let result = RunResult(
                runId: runId, success: false, summary: "Cancelled by user",
                iterations: iteration, finalScore: nil,
                totalInputTokens: totalInput + iterResult.inputTokens,
                totalOutputTokens: totalOutput + iterResult.outputTokens
            )
            lifecycle.resetRunTracking()
            lifecycle.endRun()
            return .earlyExit(result)
        }

        return .success(iterResult)
    }

    // MARK: - Pre-Iteration Checks

    /// Run pre-iteration checks shared between flat and step-driven loops:
    /// cooperative cancellation, run timeout, early/budget warnings.
    /// Returns `.earlyExit(result)` if the run should terminate, `.continue` otherwise.
    func runPreIterationChecks(
        runId: String,
        iteration: Int,
        totalInput: Int,
        totalOutput: Int,
        journal: RunJournal,
        agentLoop: AgentLoop,
        replyChannel: (any ReplyChannel)?,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void
    ) async -> PreIterationCheckResult {
        // Check for cooperative cancellation
        if lifecycle.isCancellationRequested {
            await journal.append(.cancelled())
            await journal.close()
            onStateChange(.idle)
            let result = RunResult(
                runId: runId, success: false, summary: "Cancelled by user",
                iterations: iteration, finalScore: nil,
                totalInputTokens: totalInput, totalOutputTokens: totalOutput
            )
            lifecycle.resetRunTracking()
            lifecycle.endRun()
            return .earlyExit(result)
        }

        // Network reachability check: pause if offline instead of burning retries
        if await !NetworkMonitor.shared.isReachable {
            NSLog("CyclopOne [Orchestrator]: Network unreachable at iteration %d, waiting...", iteration)
            onMessage(ChatMessage(role: .system, content: "Network offline — pausing until connectivity returns..."))
            let recovered = await NetworkMonitor.shared.waitForReachability(timeout: 60)
            if !recovered {
                let reason = "Network unreachable for 60 seconds"
                NSLog("CyclopOne [Orchestrator]: %@", reason)
                await journal.append(.fail(reason: reason))
                await journal.close()
                onMessage(ChatMessage(role: .system, content: "Error: \(reason) — aborting run."))
                onStateChange(.error(reason))
                lifecycle.endRun()
                return .earlyExit(RunResult(
                    runId: runId, success: false, summary: reason,
                    iterations: iteration, finalScore: nil,
                    totalInputTokens: totalInput, totalOutputTokens: totalOutput
                ))
            }
            NSLog("CyclopOne [Orchestrator]: Network recovered, resuming.")
        }

        // Check run timeout
        if let timeoutReason = lifecycle.checkRunTimeout(maxRunDuration: runConfig.maxRunDuration) {
            await journal.append(.fail(reason: timeoutReason))
            await journal.close()
            onMessage(ChatMessage(role: .system, content: "Warning: \(timeoutReason)"))
            onStateChange(.done)
            lifecycle.endRun()
            return .earlyExit(RunResult(
                runId: runId, success: false, summary: "Timed out",
                iterations: iteration, finalScore: nil,
                totalInputTokens: totalInput, totalOutputTokens: totalOutput
            ))
        }

        // Early warning at configured iteration to nudge the model to focus
        if let earlyMsg = lifecycle.checkEarlyWarning(iteration: iteration, maxIterations: runConfig.maxIterations, earlyWarningIteration: runConfig.earlyWarningIteration) {
            NSLog("CyclopOne [Orchestrator]: Early iteration warning at %d/%d", iteration, runConfig.maxIterations)
            onMessage(ChatMessage(role: .system, content: earlyMsg))
            await agentLoop.injectIterationWarning(earlyMsg)
            if let channel = replyChannel {
                await channel.sendText(earlyMsg)
            }
        }

        // Budget warning at 80% of max iterations
        if let warningMsg = lifecycle.checkBudgetWarning(iteration: iteration, maxIterations: runConfig.maxIterations, budgetWarningPercent: runConfig.budgetWarningPercent) {
            onMessage(ChatMessage(role: .system, content: warningMsg))
            if let channel = replyChannel {
                await channel.sendText(warningMsg)
            }
        }

        // Cumulative token limit check
        let totalTokens = totalInput + totalOutput
        if totalTokens >= runConfig.maxTokensPerRun {
            let reason = "Token limit reached (\(totalTokens)/\(runConfig.maxTokensPerRun))"
            NSLog("CyclopOne [Orchestrator]: %@", reason)
            await journal.append(.fail(reason: reason))
            await journal.close()
            onMessage(ChatMessage(role: .system, content: "Error: \(reason) — aborting run to prevent excessive API costs."))
            onStateChange(.error(reason))
            lifecycle.endRun()
            return .earlyExit(RunResult(
                runId: runId, success: false, summary: reason,
                iterations: iteration, finalScore: nil,
                totalInputTokens: totalInput, totalOutputTokens: totalOutput
            ))
        }

        // Display sleep protection: pause if display is off
        if ScreenCaptureService.isDisplayAsleep() {
            NSLog("CyclopOne [Orchestrator]: Display is asleep at iteration %d, pausing...", iteration)
            await journal.append(RunEvent(type: .iterationStart, timestamp: Date(), iteration: iteration, reason: "Display asleep — pausing"))
            var sleepWaitCount = 0
            let maxSleepWait = 150 // 5 minutes at 2-second intervals
            while ScreenCaptureService.isDisplayAsleep() && sleepWaitCount < maxSleepWait {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                sleepWaitCount += 1
            }
            if ScreenCaptureService.isDisplayAsleep() {
                NSLog("CyclopOne [Orchestrator]: Display remained asleep for 5 minutes, aborting run.")
                await journal.append(.fail(reason: "Display remained asleep for 5 minutes"))
                await journal.close()
                onMessage(ChatMessage(role: .system, content: "Error: Display remained asleep for 5 minutes — aborting run."))
                onStateChange(.error("Display asleep"))
                lifecycle.endRun()
                return .earlyExit(RunResult(
                    runId: runId, success: false, summary: "Display remained asleep for 5 minutes",
                    iterations: iteration, finalScore: nil,
                    totalInputTokens: totalInput, totalOutputTokens: totalOutput
                ))
            }
            NSLog("CyclopOne [Orchestrator]: Display woke up after %d seconds, resuming.", sleepWaitCount * 2)
            await journal.append(RunEvent(type: .iterationStart, timestamp: Date(), iteration: iteration, reason: "Display woke — resuming"))
        }

        return .continue
    }

    // MARK: - Post-Iteration Processing

    /// Post-iteration processing shared between flat and step-driven loops:
    /// screenshot saving, AX tree recording, text response tracking, stuck detection tracking,
    /// min iteration duration enforcement.
    func runPostIterationProcessing(
        iterResult: IterationResult,
        iteration: Int,
        iterStartTime: Date,
        journal: RunJournal
    ) async {
        // Save post-iteration screenshot + stuck detection
        if let ss = iterResult.screenshot {
            let ssName = "iter\(iteration)_post.jpg"
            await journal.saveScreenshot(ss.imageData, name: ssName)
            stepMachine.recordScreenshot(ss.imageData)
            stepMachine.preActionScreenshot = ss
        }

        // Capture AX tree summary for stuck detection
        let axTreeSummary = await AccessibilityService.shared.getUITreeSummary(maxDepth: 2)
        stepMachine.recordAXTreeSummary(axTreeSummary)

        // Track text responses for repetition detection
        stepMachine.recordTextResponse(iterResult.textContent)

        // Update action description
        let actionDesc = iterResult.textContent.isEmpty
            ? "Processing..."
            : String(iterResult.textContent.prefix(120))
        lifecycle.lastActionDescription = actionDesc

        // Enforce minimum iteration duration (avoid tight spin loops)
        let iterElapsed = Date().timeIntervalSince(iterStartTime)
        if iterElapsed < runConfig.minIterationDuration {
            let remaining = runConfig.minIterationDuration - iterElapsed
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }

    // MARK: - Mid-Step Verification

    /// Run a lightweight verification check after a critical step completes.
    /// Uses the VerificationEngine with the step's expected outcome as the command.
    func runMidStepVerification(
        step: PlanStep,
        plan: ExecutionPlan,
        command: String,
        textContent: String,
        screenshot: ScreenCapture?,
        agentLoop: AgentLoop,
        onMessage: @Sendable @escaping (ChatMessage) -> Void
    ) async -> MidStepVerificationResult {
        // Build a verification prompt focused on the step, not the whole command
        let stepCommand = "Step \(step.id + 1) of '\(command)': \(step.title). Expected outcome: \(step.expectedOutcome)"

        NSLog("CyclopOne [Orchestrator]: Mid-step verification for step %d: %@", step.id + 1, step.title)

        let result = await verificationEngine.verify(
            command: stepCommand,
            textContent: textContent,
            postScreenshot: screenshot,
            preScreenshot: stepMachine.preActionScreenshot,
            threshold: max(runConfig.verificationThreshold - 10, 40)  // Slightly lower threshold for mid-step
        )

        let inputTokens = await verificationEngine.lastVerificationInputTokens
        let outputTokens = await verificationEngine.lastVerificationOutputTokens

        NSLog("CyclopOne [Orchestrator]: Mid-step verification result — step=%d, score=%d, passed=%d, reason=%@",
              step.id + 1, result.overall, result.passed, result.reason)

        if !result.passed {
            onMessage(ChatMessage(role: .system, content: "Mid-step check: Step \(step.id + 1) score \(result.overall)/100 — \(result.reason)"))
        }

        return MidStepVerificationResult(
            passed: result.passed,
            score: result.overall,
            reason: result.reason,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }
}
