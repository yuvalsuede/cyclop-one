import Foundation
import AppKit

/// Babysitter-style run manager that wraps every user task in a supervised run.
///
/// Responsibilities:
/// - Event-sourced journal (RunJournal) for each run
/// - Completion token generation and validation
/// - Timing guards (per-iteration and per-run)
/// - Stuck detection (screenshot similarity + text repetition)
/// - Verification scoring via VerificationEngine (Sprint 4)
/// - Circuit breaker for API call protection (Sprint 14)
/// - Retry strategies with exponential backoff (Sprint 14)
/// - Iteration budget warnings at 80% usage (Sprint 14)
actor Orchestrator {

    // MARK: - Configuration

    struct RunConfig {
        var maxIterations: Int = 15
        var maxRunDuration: TimeInterval = 30 * 60  // 30 minutes
        var minIterationDuration: TimeInterval = 5   // 5 seconds
        var maxIterationDuration: TimeInterval = 5 * 60  // 5 minutes
        var stuckThreshold: Int = 3  // consecutive identical screenshots/texts before circuit break
        var verificationThreshold: Int = 60  // minimum score to pass verification
        var budgetWarningPercent: Double = 0.8  // warn at 80% of max iterations
        var earlyWarningIteration: Int = 7  // inject focus message at this iteration
        var iterationRetryStrategy: RetryStrategy = .exponentialBackoff(base: 2.0, maxDelay: 30.0, maxAttempts: 3)
    }

    /// Result of a completed orchestrated run.
    struct RunResult {
        let runId: String
        let success: Bool
        let summary: String
        let iterations: Int
        let finalScore: Int?
        let totalInputTokens: Int
        let totalOutputTokens: Int
        /// Token usage from verification LLM calls (separate from main conversation).
        let verificationInputTokens: Int
        let verificationOutputTokens: Int

        init(runId: String, success: Bool, summary: String, iterations: Int,
             finalScore: Int?, totalInputTokens: Int, totalOutputTokens: Int,
             verificationInputTokens: Int = 0, verificationOutputTokens: Int = 0) {
            self.runId = runId
            self.success = success
            self.summary = summary
            self.iterations = iterations
            self.finalScore = finalScore
            self.totalInputTokens = totalInputTokens
            self.totalOutputTokens = totalOutputTokens
            self.verificationInputTokens = verificationInputTokens
            self.verificationOutputTokens = verificationOutputTokens
        }
    }

    private var runConfig = RunConfig()
    /// Stores the default maxIterations to restore after skill overrides.
    private let defaultMaxIterations: Int = RunConfig().maxIterations
    private var currentRunId: String?

    /// Verification engine for scoring post-action state (Sprint 4).
    private let verificationEngine = VerificationEngine()

    /// Circuit breaker for API calls. Opens after consecutive failures to prevent
    /// hammering a failing API. Auto-recovers after cooldown. (Sprint 14)
    private let apiCircuitBreaker = CircuitBreaker(failureThreshold: 3, cooldownInterval: 30)

    /// Sprint 18: Skill context matched for the current run.
    /// Injected into the system prompt via AgentLoop.
    private var currentSkillContext: String = ""

    /// Intent classifier — determines what kind of command this is
    /// BEFORE any planning or execution begins.
    private let intentClassifier = IntentClassifier()

    /// Memory service for persistent vault-backed memory across runs.
    private let memoryService = MemoryService.shared

    /// Update the intent classifier with the outcome of a completed run,
    /// so follow-up messages have context.
    private func updateClassifierContext(command: String, result: RunResult) {
        let outcome = result.success ? "Success" : "Failed"
        // Get the frontmost app name for context
        let activeApp = NSWorkspace.shared.frontmostApplication?.localizedName
        Task {
            await intentClassifier.setLastRunContext(
                command: command, outcome: outcome, activeApp: activeApp
            )
        }
    }

    // MARK: - M2: Plan Step Tracking

    /// The current execution plan (nil if no plan or simple task).
    private var currentPlan: ExecutionPlan?

    /// Index of the step currently being executed (0-based).
    private var currentStepIndex: Int = 0

    /// Iterations spent on the current step (resets when advancing).
    private var currentStepIterations: Int = 0

    /// History of step outcomes for journal and brain consultation.
    private var stepOutcomes: [(stepId: Int, outcome: StepOutcome)] = []

    // Stuck detection: last N screenshot image data for comparison
    private var recentScreenshotData: [Data] = []

    // Stuck detection: last N AX tree summaries for comparison alongside screenshots
    private var recentAXTreeSummaries: [String] = []

    // Stuck detection: last N text responses for repetition detection (Sprint 14)
    private var recentTextResponses: [String] = []

    // Pre-action screenshot for visual diff comparison
    private var preActionScreenshot: ScreenCapture?

    // Whether the 80% budget warning has been sent for the current run (Sprint 14)
    private var budgetWarningSent = false

    // Whether the early iteration warning has been sent for the current run
    private var earlyWarningSent = false

    // Whether we've already escalated to the brain model for the current run
    private var hasEscalatedToBrain = false

    // MARK: - Run Tracking (Sprint 11)

    /// Whether a cancellation has been requested for the current run.
    private var isCancellationRequested = false

    /// The command text for the current run (for status reporting).
    private var currentCommand: String?

    /// The iteration count of the current run.
    private var currentIteration: Int = 0

    /// The start time of the current run.
    private var runStartTime: Date?

    /// Description of the last action executed in the current run.
    private var lastActionDescription: String?

    // MARK: - M6: Hard Cancel

    /// Reference to the currently executing iteration Task.
    /// Stored so cancelCurrentRun() can call task.cancel() for immediate
    /// cooperative cancellation propagation through every await point.
    private var currentIterationTask: Task<IterationResult, Error>?

    /// Watchdog task that force-terminates the run if the iteration
    /// does not respond to cancellation within the timeout.
    private var cancelWatchdog: Task<Void, Never>?

    /// Maximum time to wait for cooperative cancellation before force-terminating.
    private let cancelTimeout: TimeInterval = 5.0

    /// Whether a hard cancel is in progress (prevents re-entrant cancel calls).
    private var isHardCancelInProgress: Bool = false

    // MARK: - Start Run

    /// Start a new supervised run for a user command.
    /// This is the main entry point -- called by CommandGateway or AgentCoordinator.
    ///
    /// - Parameters:
    ///   - command: The user's text command.
    ///   - source: Where the command came from (e.g. "localUI", "hotkey", "openClaw").
    ///   - agentLoop: The agent loop to execute iterations with.
    ///   - replyChannel: Optional reply channel for routing results back to the source.
    ///   - onStateChange: Callback for state transitions (still used by local UI).
    ///   - onMessage: Callback for chat messages (still used by local UI).
    ///   - onConfirmationNeeded: Callback for destructive action approval.
    ///   - observer: Optional AgentObserver for real-time feedback to the command source.
    func startRun(
        command: String,
        source: String = "chat",
        agentLoop: AgentLoop,
        replyChannel: (any ReplyChannel)? = nil,
        targetPID: pid_t? = nil,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void,
        onConfirmationNeeded: @Sendable @escaping (String) async -> Bool,
        observer: (any AgentObserver)? = nil
    ) async -> RunResult {
        let runId = generateRunId()
        currentRunId = runId
        let journal = RunJournal(runId: runId)
        let completionToken = generateCompletionToken()
        recentScreenshotData.removeAll()
        recentAXTreeSummaries.removeAll()
        recentTextResponses.removeAll()
        preActionScreenshot = nil
        budgetWarningSent = false
        earlyWarningSent = false
        hasEscalatedToBrain = false

        // M2: Reset plan tracking
        currentPlan = nil
        currentStepIndex = 0
        currentStepIterations = 0
        stepOutcomes.removeAll()

        // Sprint 14: Reset circuit breaker for fresh run
        await apiCircuitBreaker.reset()

        // Reset maxIterations to default before applying skill overrides
        runConfig.maxIterations = defaultMaxIterations

        // Sprint 18: Match skills and build context for the system prompt
        let skillLoader = SkillLoader.shared
        let matchedSkills = await skillLoader.matchSkills(for: command)
        currentSkillContext = await skillLoader.buildSkillContext(for: matchedSkills)

        // Sprint 18: Apply max iterations override from matched skill if lower
        if let skillMaxIter = matchedSkills.first?.maxIterations, skillMaxIter > 0, skillMaxIter < runConfig.maxIterations {
            runConfig.maxIterations = skillMaxIter
        }

        // Sprint 18: Inject skill context into the agent loop
        if !currentSkillContext.isEmpty {
            await agentLoop.setSkillContext(currentSkillContext)
        } else {
            await agentLoop.setSkillContext("")
        }

        // Load memory context from the Obsidian vault and inject into agent loop
        let coreContext = await memoryService.loadCoreContext()
        let relevantMemories = await memoryService.retrieveRelevantMemories(for: command)
        let recentHistory = await memoryService.loadRecentRunSummaries(limit: 5)
        let memoryContext = await memoryService.buildContextString(
            core: coreContext, relevant: relevantMemories, history: recentHistory
        )
        await agentLoop.setMemoryContext(memoryContext)
        NSLog("CyclopOne [Orchestrator]: Memory context loaded — %d chars", memoryContext.count)

        // Sprint 18: Self-authoring -- record command and check for repeated patterns
        if let suggestion = await skillLoader.recordCommand(command) {
            let suggestionMsg = "I noticed you've been running similar commands. Would you like me to create a skill called '\(suggestion.name)' to automate this pattern?\n\nExamples: \(suggestion.exampleCommands.prefix(3).joined(separator: ", "))"
            onMessage(ChatMessage(role: .system, content: suggestionMsg))
        }

        // Step 1: Classify intent BEFORE any planning
        let intent = await intentClassifier.classify(
            command: command,
            source: CommandSource(rawValue: source) ?? .localUI
        )
        NSLog("CyclopOne [Orchestrator]: Intent classified — %@ (confidence: %.2f)",
              String(describing: intent), intent.confidence)

        // Step 2: Route based on intent
        switch intent {
        case .chat(let topic, let confidence):
            NSLog("CyclopOne [Orchestrator]: Chat intent (topic=%@, confidence=%.2f), responding conversationally", topic, confidence)
            let chatReply = await generateChatReply(command: command)
            if let rc = replyChannel {
                await rc.sendText(chatReply)
            }
            onMessage(ChatMessage(role: .assistant, content: chatReply))
            currentRunId = nil
            return RunResult(
                runId: runId, success: true, summary: chatReply,
                iterations: 0, finalScore: 100,
                totalInputTokens: 0, totalOutputTokens: 0
            )

        case .metaCommand(let metaCmd, _):
            NSLog("CyclopOne [Orchestrator]: Meta command: %@", metaCmd.rawValue)
            let result = await handleMetaCommand(
                metaCmd, replyChannel: replyChannel, onMessage: onMessage
            )
            currentRunId = nil
            return RunResult(
                runId: runId, success: true, summary: result,
                iterations: 0, finalScore: 100,
                totalInputTokens: 0, totalOutputTokens: 0
            )

        case .clarification(let question, let confidence):
            NSLog("CyclopOne [Orchestrator]: Clarification needed (confidence=%.2f): %@", confidence, question)
            if let rc = replyChannel {
                await rc.sendText(question)
            }
            onMessage(ChatMessage(role: .assistant, content: question))
            currentRunId = nil
            return RunResult(
                runId: runId, success: true, summary: "Asked for clarification",
                iterations: 0, finalScore: 100,
                totalInputTokens: 0, totalOutputTokens: 0
            )

        case .task(let description, let complexity, let confidence):
            NSLog("CyclopOne [Orchestrator]: Task intent (desc=%@, complexity=%@, confidence=%.2f)",
                  description, complexity.rawValue, confidence)

            // Only consult brain for moderate/complex tasks -- simple tasks go straight to execution
            let plan: ExecutionPlan
            if complexity == .simple {
                plan = ExecutionPlan(command: command, steps: [], summary: "")
            } else {
                let brainModel = AgentConfig().brainModel
                plan = await consultBrainForPlan(command: command, model: brainModel, complexity: complexity)
            }

            // Store plan for step tracking
            currentPlan = plan
            currentStepIndex = 0
            currentStepIterations = 0
            stepOutcomes.removeAll()

            if !plan.isEmpty {
                // Display plan to user before execution
                let planText = formatPlanForUser(plan)
                if let rc = replyChannel {
                    await rc.sendText(planText)
                }
                onMessage(ChatMessage(role: .system, content: planText))
                NSLog("CyclopOne [Orchestrator]: Brain plan injected (%d steps, estimated %d iterations)",
                      plan.steps.count, plan.estimatedTotalIterations)
            } else {
                // Empty plan -- fall back to single-instruction mode
                NSLog("CyclopOne [Orchestrator]: Empty plan -- falling back to single-instruction mode")
                await agentLoop.setCurrentStepInstruction(command)
            }
        }
        // Execution continues below for .task case only...

        // Sprint 11: Initialize run tracking metadata
        resetRunTracking()
        currentCommand = command
        runStartTime = Date()

        let totalInput = 0
        let totalOutput = 0
        let iteration = 0

        NSLog("CyclopOne [Orchestrator]: startRun — runId=%@, command=%@, source=%@, model=%@, maxIter=%d, skills=%d",
              runId, command, source, await agentLoop.currentModelName,
              runConfig.maxIterations, matchedSkills.count)

        // Open journal
        do {
            try await journal.open()
        } catch {
            NSLog("CyclopOne [Orchestrator]: Journal open failed: %@", error.localizedDescription)
            onMessage(ChatMessage(role: .system, content: "Error: Journal open failed — \(error.localizedDescription)"))
            onStateChange(.error("Journal open failed"))
            currentRunId = nil
            return RunResult(
                runId: runId, success: false,
                summary: "Journal open failed: \(error.localizedDescription)",
                iterations: 0, finalScore: nil,
                totalInputTokens: 0, totalOutputTokens: 0
            )
        }

        await journal.append(.created(command: command, source: source))

        // -- Prepare the run (initial screenshot, build first message) --
        NSLog("CyclopOne [Orchestrator]: Preparing run — capturing screenshot... (targetPID: %@)",
              targetPID.map { String($0) } ?? "auto-detect")
        let initialScreenshot = await agentLoop.prepareRun(
            userMessage: command,
            completionToken: completionToken,
            targetPID: targetPID,
            onStateChange: onStateChange,
            onMessage: onMessage
        )

        // Save initial screenshot to journal and as pre-action baseline
        if let ssData = initialScreenshot?.imageData {
            await journal.saveScreenshot(ssData, name: "iter0_pre.jpg")
        }
        preActionScreenshot = initialScreenshot

        // -- Main iteration loop --
        return await runIterationLoop(
            runId: runId,
            command: command,
            completionToken: completionToken,
            startIteration: iteration,
            totalInput: totalInput,
            totalOutput: totalOutput,
            journal: journal,
            agentLoop: agentLoop,
            replyChannel: replyChannel,
            onStateChange: onStateChange,
            onMessage: onMessage,
            onConfirmationNeeded: onConfirmationNeeded,
            observer: observer
        )
    }

    // MARK: - Iteration Retry (Sprint 14)

    /// Execute a single iteration wrapped in the circuit breaker and retry logic.
    ///
    /// The circuit breaker protects against cascade failures (e.g. Claude API down).
    /// Retry strategy is determined by error classification:
    /// - Transient errors: exponential backoff
    /// - Rate limits: fixed delay (respecting retry-after if available)
    /// - Permanent errors: no retry
    private func executeIterationWithRetry(
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
        // Previously used 0...maxAttempts which caused one extra retry attempt (off-by-one).
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

    // MARK: - Sprint 16: Resume Run

    /// Resume an incomplete run detected on launch.
    ///
    /// Replays the JSONL journal to reconstruct state (command, iteration count,
    /// tool history), takes a fresh screenshot, restores conversation history
    /// in the AgentLoop, and resumes execution from the last committed iteration.
    ///
    /// - Parameters:
    ///   - runId: The ID of the incomplete run to resume.
    ///   - agentLoop: The agent loop instance to execute iterations with.
    ///   - replyChannel: Optional reply channel for routing results.
    ///   - onStateChange: Callback for state transitions.
    ///   - onMessage: Callback for chat messages.
    ///   - onConfirmationNeeded: Callback for destructive action approval.
    ///   - observer: Optional AgentObserver for real-time feedback.
    /// - Returns: The run result, or `nil` if the run could not be resumed.
    func resumeRun(
        runId: String,
        agentLoop: AgentLoop,
        replyChannel: (any ReplyChannel)? = nil,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void,
        onConfirmationNeeded: @Sendable @escaping (String) async -> Bool,
        observer: (any AgentObserver)? = nil
    ) async -> RunResult? {
        // Replay the journal to get the run state
        guard let replayedState = RunJournal.replayRunState(runId: runId) else {
            onMessage(ChatMessage(role: .system, content: "Cannot resume run \(runId): journal replay failed."))
            return nil
        }

        // Check if the run is too old to resume (> 1 hour)
        if RunJournal.isRunStale(runId: runId) {
            RunJournal.markAbandoned(runId: runId)
            let msg = "Abandoned stale task: \(replayedState.command). It was interrupted over an hour ago."
            onMessage(ChatMessage(role: .system, content: msg))
            if let channel = replyChannel {
                await channel.sendText(msg)
            }
            return nil
        }

        // Set up run tracking
        currentRunId = runId
        resetRunTracking()
        currentCommand = replayedState.command
        runStartTime = Date()
        currentIteration = replayedState.iterationCount

        recentScreenshotData.removeAll()
        recentAXTreeSummaries.removeAll()
        recentTextResponses.removeAll()
        preActionScreenshot = nil
        budgetWarningSent = false
        earlyWarningSent = false
        hasEscalatedToBrain = false
        await apiCircuitBreaker.reset()

        // Open the journal for appending (resume writing to the same file)
        let journal = RunJournal(runId: runId)
        do {
            try await journal.open()
        } catch {
            currentRunId = nil
            onMessage(ChatMessage(role: .system, content: "Cannot resume run: journal open failed."))
            return nil
        }

        await journal.append(RunEvent(type: .iterationStart, timestamp: Date(), iteration: replayedState.iterationCount + 1, reason: "Resumed after crash"))

        // Generate a new completion token for the resumed run
        let completionToken = generateCompletionToken()

        // Take a fresh screenshot to assess current state
        let freshScreenshot = await agentLoop.prepareRun(
            userMessage: replayedState.command,
            completionToken: completionToken,
            onStateChange: onStateChange,
            onMessage: onMessage
        )

        // Instead of using prepareRun's conversation (which starts clean),
        // restore the conversation with journal context
        await agentLoop.restoreForResume(
            command: replayedState.command,
            completionToken: completionToken,
            toolEvents: replayedState.toolEvents,
            screenshot: freshScreenshot
        )

        if let ssData = freshScreenshot?.imageData {
            await journal.saveScreenshot(ssData, name: "resume_pre.jpg")
        }
        preActionScreenshot = freshScreenshot

        // Notify about the resume
        let resumeMsg = "Resumed task: \(replayedState.command). Continuing from step \(replayedState.iterationCount + 1)."
        onMessage(ChatMessage(role: .system, content: resumeMsg))
        if let channel = replyChannel {
            await channel.sendText(resumeMsg)
        }

        // Continue the iteration loop from where we left off
        return await runIterationLoop(
            runId: runId,
            command: replayedState.command,
            completionToken: completionToken,
            startIteration: replayedState.iterationCount,
            totalInput: 0,
            totalOutput: 0,
            journal: journal,
            agentLoop: agentLoop,
            replyChannel: replyChannel,
            onStateChange: onStateChange,
            onMessage: onMessage,
            onConfirmationNeeded: onConfirmationNeeded,
            observer: observer
        )
    }

    // MARK: - Shared Iteration Loop

    /// Dispatch to either the step-driven loop (when a plan exists) or
    /// the flat iteration loop (legacy behavior, simple tasks, failed parsing).
    private func runIterationLoop(
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
        // M5: Start safety gate session for this run
        await agentLoop.startSafetyGateRun(runId: runId)

        let result: RunResult
        // If we have a non-empty plan, use the step-driven loop
        if let plan = currentPlan, !plan.isEmpty {
            result = await runStepDrivenLoop(
                runId: runId, command: command, completionToken: completionToken,
                plan: plan, startIteration: startIteration,
                totalInput: totalInput, totalOutput: totalOutput,
                journal: journal, agentLoop: agentLoop,
                replyChannel: replyChannel,
                onStateChange: onStateChange, onMessage: onMessage,
                onConfirmationNeeded: onConfirmationNeeded, observer: observer
            )
        } else {
            // No plan -- fall back to flat iteration loop (legacy behavior)
            result = await runFlatIterationLoop(
                runId: runId, command: command, completionToken: completionToken,
                startIteration: startIteration,
                totalInput: totalInput, totalOutput: totalOutput,
                journal: journal, agentLoop: agentLoop,
                replyChannel: replyChannel,
                onStateChange: onStateChange, onMessage: onMessage,
                onConfirmationNeeded: onConfirmationNeeded, observer: observer
            )
        }

        // M5: End safety gate session -- flush audit log
        await agentLoop.endSafetyGateRun()
        return result
    }

    /// Flat iteration loop -- the original M1 behavior preserved for:
    /// - Simple tasks (no plan)
    /// - Failed plan parsing (empty plan)
    /// - Resume runs (plan state not yet persisted)
    private func runFlatIterationLoop(
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
        defer { cleanupCancelState() }  // M6: Always clean up cancel state

        var totalInput = totalInput
        var totalOutput = totalOutput
        var iteration = startIteration
        var anyToolCallsExecuted = false
        var anyVisualToolCalls = false
        var rejectedCompletions = 0
        let maxRejectedCompletions = 2
        var verificationInputTokens = 0
        var verificationOutputTokens = 0

        while iteration < runConfig.maxIterations {
            iteration += 1
            currentIteration = iteration
            let iterStartTime = Date()

            // Check for cooperative cancellation
            if isCancellationRequested {
                await journal.append(.cancelled())
                await journal.close()
                onStateChange(.idle)
                let result = RunResult(
                    runId: runId, success: false, summary: "Cancelled by user",
                    iterations: iteration, finalScore: nil,
                    totalInputTokens: totalInput, totalOutputTokens: totalOutput
                )
                resetRunTracking()
                currentRunId = nil
                return result
            }

            // Display sleep protection: pause if display is off
            if ScreenCaptureService.isDisplayAsleep() {
                NSLog("CyclopOne [Orchestrator]: Display is asleep, pausing run...")
                await journal.append(RunEvent(type: .iterationStart, timestamp: Date(), iteration: iteration, reason: "Display asleep — pausing"))
                var sleepWaitCount = 0
                let maxSleepWait = 150 // 5 minutes at 2-second intervals
                while ScreenCaptureService.isDisplayAsleep() && sleepWaitCount < maxSleepWait {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                    sleepWaitCount += 1
                }
                if ScreenCaptureService.isDisplayAsleep() {
                    NSLog("CyclopOne [Orchestrator]: Display remained asleep for 5 minutes, aborting run.")
                    await journal.append(.fail(reason: "Display remained asleep for 5 minutes"))
                    onMessage(ChatMessage(role: .system, content: "Error: Display remained asleep for 5 minutes — aborting run."))
                    break
                }
                NSLog("CyclopOne [Orchestrator]: Display woke up after %d seconds, resuming run.", sleepWaitCount * 2)
                await journal.append(RunEvent(type: .iterationStart, timestamp: Date(), iteration: iteration, reason: "Display woke — resuming"))
            }

            // Check run timeout
            if let startTime = runStartTime, Date().timeIntervalSince(startTime) > runConfig.maxRunDuration {
                let reason = "Run exceeded max duration (\(Int(runConfig.maxRunDuration))s)"
                await journal.append(.fail(reason: reason))
                await journal.close()
                onMessage(ChatMessage(role: .system, content: "Warning: \(reason)"))
                onStateChange(.done)
                currentRunId = nil
                return RunResult(
                    runId: runId, success: false, summary: "Timed out",
                    iterations: iteration, finalScore: nil,
                    totalInputTokens: totalInput, totalOutputTokens: totalOutput
                )
            }

            // Early warning at configured iteration to nudge the model to focus
            if iteration >= runConfig.earlyWarningIteration && !earlyWarningSent {
                earlyWarningSent = true
                let remaining = runConfig.maxIterations - iteration
                let earlyMsg = "You've used \(iteration) of \(runConfig.maxIterations) iterations. Focus on completing the task now or declare it impossible. You have \(remaining) iterations left."
                NSLog("CyclopOne [Orchestrator]: Early iteration warning at %d/%d", iteration, runConfig.maxIterations)
                onMessage(ChatMessage(role: .system, content: earlyMsg))
                await agentLoop.injectIterationWarning(earlyMsg)
                if let channel = replyChannel {
                    await channel.sendText(earlyMsg)
                }
            }

            // Budget warning at 80% of max iterations
            let budgetThreshold = Int(Double(runConfig.maxIterations) * runConfig.budgetWarningPercent)
            if iteration >= budgetThreshold && !budgetWarningSent {
                budgetWarningSent = true
                let remaining = runConfig.maxIterations - iteration
                let warningMsg = "Budget warning: \(remaining) iterations remaining out of \(runConfig.maxIterations) max."
                onMessage(ChatMessage(role: .system, content: warningMsg))
                if let channel = replyChannel {
                    await channel.sendText(warningMsg)
                }
            }

            await journal.append(.iterationStart(iteration: iteration, screenshot: nil))

            // M3: Fire iteration start observer event (fire-and-forget to avoid blocking)
            let currentIteration = iteration
            let maxIter = runConfig.maxIterations
            notifyObserver(observer) { obs in
                await obs.onIterationStart(iteration: currentIteration, maxIterations: maxIter)
            }

            // M6: Wrap iteration in a Task for hard-cancel support.
            // Storing the Task reference allows cancelCurrentRun() to call
            // task.cancel(), propagating CancellationError through every await.
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
            currentIterationTask = iterationTask

            let iterResult: IterationResult
            do {
                iterResult = try await iterationTask.value
            } catch is CancellationError {
                // M6: Task was cancelled via hard cancel
                NSLog("CyclopOne [Orchestrator]: Iteration %d hard-cancelled", iteration)
                await journal.append(.cancelled())
                await journal.close()
                onStateChange(.idle)
                let result = RunResult(
                    runId: runId, success: false, summary: "Hard-cancelled by user",
                    iterations: iteration, finalScore: nil,
                    totalInputTokens: totalInput, totalOutputTokens: totalOutput
                )
                resetRunTracking()
                currentRunId = nil
                return result
            } catch let cbError as CircuitBreaker.CircuitBreakerError {
                let reason = "Circuit breaker open: \(cbError.localizedDescription)"
                let ssData = preActionScreenshot?.imageData
                notifyObserver(observer) { obs in
                    await obs.onError(error: reason, screenshot: ssData, isFatal: true)
                }
                await journal.append(.fail(reason: reason))
                await journal.close()
                onMessage(ChatMessage(role: .system, content: "Error: API circuit breaker triggered. \(cbError.localizedDescription)"))
                onStateChange(.error(reason))
                currentRunId = nil
                return RunResult(
                    runId: runId, success: false, summary: reason,
                    iterations: iteration, finalScore: nil,
                    totalInputTokens: totalInput, totalOutputTokens: totalOutput
                )
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
                let ssData = preActionScreenshot?.imageData
                notifyObserver(observer) { obs in
                    await obs.onError(error: errMsg, screenshot: ssData, isFatal: true)
                }
                await journal.append(.fail(reason: "Iteration \(iteration) \(classLabel) error: \(error.localizedDescription)"))
                await journal.close()
                onMessage(ChatMessage(role: .system, content: "Error [\(classLabel)]: \(error.localizedDescription)"))
                onStateChange(.error(error.localizedDescription))
                currentRunId = nil
                return RunResult(
                    runId: runId, success: false, summary: error.localizedDescription,
                    iterations: iteration, finalScore: nil,
                    totalInputTokens: totalInput, totalOutputTokens: totalOutput
                )
            }

            // Check cancellation immediately after iteration completes
            if isCancellationRequested || iterResult.cancelled {
                await journal.append(.cancelled())
                await journal.close()
                onStateChange(.idle)
                let result = RunResult(
                    runId: runId, success: false, summary: "Cancelled by user",
                    iterations: iteration, finalScore: nil,
                    totalInputTokens: totalInput + iterResult.inputTokens,
                    totalOutputTokens: totalOutput + iterResult.outputTokens
                )
                resetRunTracking()
                currentRunId = nil
                return result
            }

            totalInput += iterResult.inputTokens
            totalOutput += iterResult.outputTokens

            // Save post-iteration screenshot + stuck detection
            if let ss = iterResult.screenshot {
                let ssName = "iter\(iteration)_post.jpg"
                await journal.saveScreenshot(ss.imageData, name: ssName)
                recentScreenshotData.append(ss.imageData)
                if recentScreenshotData.count > runConfig.stuckThreshold {
                    recentScreenshotData.removeFirst()
                }
            }

            // Capture AX tree summary for stuck detection (compare alongside screenshots).
            // If screenshots are identical but AX tree changed, the agent IS making progress.
            let axTreeSummary = await AccessibilityService.shared.getUITreeSummary(maxDepth: 2)
            recentAXTreeSummaries.append(axTreeSummary)
            if recentAXTreeSummaries.count > runConfig.stuckThreshold {
                recentAXTreeSummaries.removeFirst()
            }

            // Track text responses for repetition detection
            let trimmedText = iterResult.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                recentTextResponses.append(trimmedText)
                if recentTextResponses.count > runConfig.stuckThreshold {
                    recentTextResponses.removeFirst()
                }
            }

            // Enhanced stuck detection (screenshots OR text repetition)
            // Skip stuck detection for the first few iterations to give the agent
            // time to execute multi-step tasks before judging progress.
            if iteration >= runConfig.stuckThreshold, let stuckReason = detectStuck() {
                if !hasEscalatedToBrain {
                    // First stuck: consult brain model (Opus) for strategic advice
                    hasEscalatedToBrain = true
                    let brainModel = AgentConfig().brainModel
                    NSLog("CyclopOne [Orchestrator]: Stuck detected (%@), consulting brain (%@)", stuckReason, brainModel)
                    await journal.append(.stuck(reason: "\(stuckReason) — consulting \(brainModel)"))

                    // Make a separate API call to Opus — text only, no tools
                    let brainPrompt = """
                    The agent executing the task "\(command)" is stuck. \
                    Reason: \(stuckReason). \
                    The agent has completed \(iteration) iterations so far. \
                    Recent actions have not made progress. \
                    Provide 2-3 concise, specific suggestions for what the agent should try differently. \
                    Focus on alternative approaches, not repeating what failed.
                    """
                    do {
                        let brainResponse = try await ClaudeAPIService.shared.sendMessage(
                            messages: [["role": "user", "content": brainPrompt]],
                            systemPrompt: "You are a strategic advisor helping an autonomous desktop agent get unstuck. Be concise and actionable.",
                            tools: [],
                            model: brainModel,
                            maxTokens: 1024
                        )
                        let advice = brainResponse.textContent
                        NSLog("CyclopOne [Orchestrator]: Brain advice received (%d chars)", advice.count)
                        onMessage(ChatMessage(role: .system, content: "Agent stuck — consulting brain model for guidance..."))
                        await agentLoop.injectBrainGuidance(advice)
                    } catch {
                        NSLog("CyclopOne [Orchestrator]: Brain consultation failed: %@", error.localizedDescription)
                        onMessage(ChatMessage(role: .system, content: "Error: Brain consultation failed — \(error.localizedDescription)"))
                    }

                    // Clear stuck tracking to give executor a fresh start with guidance
                    recentScreenshotData.removeAll()
                    recentTextResponses.removeAll()
                    continue
                }

                // Already consulted brain and still stuck — terminate
                let stuckMsg = "Agent appears stuck: \(stuckReason)"
                let stuckSS = preActionScreenshot?.imageData
                notifyObserver(observer) { obs in
                    await obs.onError(error: stuckMsg, screenshot: stuckSS, isFatal: true)
                }
                await journal.append(.stuck(reason: stuckReason))
                await journal.close()
                onMessage(ChatMessage(role: .system, content: "Warning: Agent appears stuck -- \(stuckReason)."))
                onStateChange(.done)
                currentRunId = nil
                return RunResult(
                    runId: runId, success: false, summary: "Stuck detected",
                    iterations: iteration, finalScore: nil,
                    totalInputTokens: totalInput, totalOutputTokens: totalOutput
                )
            }

            if let ss = iterResult.screenshot {
                preActionScreenshot = ss
            }

            // Track whether any tool calls were executed across the run,
            // and whether any of those tools produce visual changes.
            if iterResult.hasMoreWork {
                anyToolCallsExecuted = true
                if iterResult.hasVisualToolCalls {
                    anyVisualToolCalls = true
                }
            }

            // Check completion marker or no-more-work as completion signals.
            // SECURITY: Claude outputs the canonical marker <task_complete/>;
            // the secret token is never exposed in the prompt.
            let completionTokenFound = containsCompletionToken(iterResult.textContent)
            let claudeIndicatedDone = !iterResult.hasMoreWork

            if completionTokenFound || claudeIndicatedDone {
                let completionSource = completionTokenFound ? "token match" : "Claude indicated done"
                NSLog("CyclopOne [Orchestrator]: Completion signal detected — source=%@, iteration=%d, anyToolCalls=%d, rejectedSoFar=%d",
                      completionSource, iteration, anyToolCallsExecuted, rejectedCompletions)

                // Skip visual verification when no visual tools were used.
                // Verification scores visual/structural/output which only makes sense
                // when the agent performed actions on screen.
                // Cases: (1) no tool calls at all, (2) only non-visual tools (memory, vault, tasks).
                let score: Int
                let passed: Bool
                let reason: String
                if !anyToolCallsExecuted {
                    score = 100
                    passed = true
                    reason = "Text-only run, auto-pass"
                    NSLog("CyclopOne [Orchestrator]: Text-only run, skipping verification (auto-pass score=100)")
                } else if !anyVisualToolCalls {
                    score = 100
                    passed = true
                    reason = "Non-visual tools only, auto-pass"
                    NSLog("CyclopOne [Orchestrator]: Non-visual tools only, skipping verification (auto-pass score=100)")
                } else {
                    let verificationResult = await verificationEngine.verify(
                        command: command,
                        textContent: iterResult.textContent,
                        postScreenshot: iterResult.screenshot,
                        preScreenshot: preActionScreenshot,
                        threshold: runConfig.verificationThreshold
                    )
                    score = verificationResult.overall
                    passed = verificationResult.passed
                    reason = verificationResult.reason
                    NSLog("CyclopOne [Orchestrator]: Verification result — score=%d, passed=%d, reason=%@, threshold=%d",
                          score, passed, reason, runConfig.verificationThreshold)
                }
                verificationInputTokens += await verificationEngine.lastVerificationInputTokens
                verificationOutputTokens += await verificationEngine.lastVerificationOutputTokens

                // Babysitter exit lock: reject completion if score is below threshold
                if !passed && rejectedCompletions < maxRejectedCompletions {
                    rejectedCompletions += 1
                    NSLog("CyclopOne [Orchestrator]: Completion rejected — verification score %d/100: %@", score, reason)

                    await journal.append(.iterationEnd(iteration: iteration, screenshot: nil, verificationScore: score))
                    await journal.append(.fail(reason: "Completion rejected (attempt \(rejectedCompletions)/\(maxRejectedCompletions)) — score \(score)/100: \(reason)"))

                    let feedbackMsg = "Verification check: your completion was rejected. Score: \(score)/100. Reason: \(reason). Please try again."
                    onMessage(ChatMessage(role: .system, content: "Completion rejected — verification score \(score)/100: \(reason)"))

                    // Inject feedback into the conversation so Claude sees it on the next iteration
                    await agentLoop.injectVerificationFeedback(feedbackMsg)

                    // Record the verification rejection for failure-avoidance learning
                    Task.detached { [memoryService = self.memoryService] in
                        await memoryService.recordVerificationRejection(
                            command: command, score: score, reason: reason
                        )
                    }

                    // Continue the loop — do NOT return RunResult yet
                    continue
                }

                // Accept: either passed verification or max rejections exhausted
                if rejectedCompletions >= maxRejectedCompletions && !passed {
                    NSLog("CyclopOne [Orchestrator]: Force-completing after %d rejected completions (score: %d)", rejectedCompletions, score)
                } else {
                    NSLog("CyclopOne [Orchestrator]: Completion accepted — score=%d, iterations=%d, totalTokens=%d/%d",
                          score, iteration, totalInput, totalOutput)
                }

                // M3: Fire completion observer event (fire-and-forget to avoid blocking)
                let completionIter = iteration
                let completionScore = score
                notifyObserver(observer) { obs in
                    await obs.onCompletion(success: passed, summary: "Completed (score: \(completionScore))", score: completionScore, iterations: completionIter)
                }

                await journal.append(.iterationEnd(iteration: iteration, screenshot: nil, verificationScore: score))
                await journal.append(.complete(summary: "Completed via \(completionSource) (verification: \(score))", finalScore: score))
                await journal.close()

                // Post-run memory recording
                let outcome = RunOutcome(
                    runId: runId, command: command, success: passed,
                    score: score, iterations: iteration
                )
                await memoryService.recordRunOutcome(outcome)
                await memoryService.updateCurrentStatus(
                    lastCommand: command,
                    lastOutcome: passed ? "Success (score: \(score))" : "Failed (score: \(score))",
                    timestamp: Date()
                )
                if !passed {
                    await memoryService.recordFailure(
                        command: command, reason: reason, iterations: iteration
                    )
                }

                onStateChange(.done)
                currentRunId = nil
                let result = RunResult(
                    runId: runId, success: passed, summary: "Completed (score: \(score))",
                    iterations: iteration, finalScore: score,
                    totalInputTokens: totalInput, totalOutputTokens: totalOutput,
                    verificationInputTokens: verificationInputTokens,
                    verificationOutputTokens: verificationOutputTokens
                )
                updateClassifierContext(command: command, result: result)
                return result
            }

            if iterResult.cancelled {
                await journal.append(.cancelled())
                await journal.close()
                onStateChange(.idle)
                currentRunId = nil
                return RunResult(
                    runId: runId, success: false, summary: "Cancelled",
                    iterations: iteration, finalScore: nil,
                    totalInputTokens: totalInput, totalOutputTokens: totalOutput
                )
            }

            await journal.append(.iterationEnd(iteration: iteration, screenshot: nil, verificationScore: nil))

            let actionDesc = iterResult.textContent.isEmpty
                ? "Processing..."
                : String(iterResult.textContent.prefix(120))
            lastActionDescription = actionDesc

            // Enforce minimum iteration duration (avoid tight spin loops)
            let iterElapsed = Date().timeIntervalSince(iterStartTime)
            if iterElapsed < runConfig.minIterationDuration {
                let remaining = runConfig.minIterationDuration - iterElapsed
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }

        // Max iterations reached
        let elapsed = runStartTime.map { Date().timeIntervalSince($0) } ?? 0
        NSLog("CyclopOne [Orchestrator]: Run ended — maxIterations reached (%d), elapsed=%.1fs, tokens=%d/%d, rejected=%d",
              runConfig.maxIterations, elapsed, totalInput, totalOutput, rejectedCompletions)
        let reason = "Max iterations (\(runConfig.maxIterations)) reached"
        await journal.append(.fail(reason: reason))
        await journal.close()
        onMessage(ChatMessage(role: .system, content: "Warning: \(reason)."))
        onStateChange(.done)
        currentRunId = nil
        return RunResult(
            runId: runId, success: false, summary: reason,
            iterations: iteration, finalScore: nil,
            totalInputTokens: totalInput, totalOutputTokens: totalOutput
        )
    }

    // MARK: - M2: Step-Driven Iteration Loop

    /// Step-driven iteration loop. Executes each plan step sequentially,
    /// injecting only the current step's instruction into the executor.
    /// Falls back to the flat loop if anything goes structurally wrong.
    private func runStepDrivenLoop(
        runId: String,
        command: String,
        completionToken: String,
        plan: ExecutionPlan,
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
        defer { cleanupCancelState() }  // M6: Always clean up cancel state

        var totalInput = totalInput
        var totalOutput = totalOutput
        var iteration = startIteration
        var anyToolCallsExecuted = false
        var anyVisualToolCalls = false
        var verificationInputTokens = 0
        var verificationOutputTokens = 0
        // Mutable copy of plan for revisions
        var mutablePlan = plan

        NSLog("CyclopOne [Orchestrator]: Starting step-driven loop with %d steps", mutablePlan.steps.count)

        while currentStepIndex < mutablePlan.steps.count {
            let step = mutablePlan.steps[currentStepIndex]
            currentStepIterations = 0

            NSLog("CyclopOne [Orchestrator]: Starting step %d/%d: %@",
                  step.id + 1, mutablePlan.steps.count, step.title)

            // --- Confirmation Gate ---
            if step.requiresConfirmation {
                let confirmMsg = "Step \(step.id + 1): \(step.title)\n\n\(step.action)\n\nProceed?"
                let approved = await onConfirmationNeeded(confirmMsg)
                if !approved {
                    stepOutcomes.append((step.id, .skipped(reason: "User denied")))
                    await journal.append(.fail(reason: "Step \(step.id + 1) skipped (user denied confirmation)"))
                    if let rc = replyChannel {
                        await rc.sendText("Step \(step.id + 1) skipped (user denied).")
                    }
                    currentStepIndex += 1
                    continue
                }
            }

            // --- Inject Current Step Instruction ---
            let stepInstruction = buildStepInstruction(step: step, plan: mutablePlan, stepOutcomes: stepOutcomes)
            await agentLoop.setCurrentStepInstruction(stepInstruction)

            // M3: Fire step start observer event (fire-and-forget to avoid blocking)
            let stepId = step.id
            let totalSteps = mutablePlan.steps.count
            let stepTitle = step.title
            notifyObserver(observer) { obs in
                await obs.onStepStart(stepIndex: stepId, totalSteps: totalSteps, title: stepTitle)
            }
            // Also send to replyChannel for backward compat (non-observer paths)
            if observer == nil, let rc = replyChannel {
                await rc.sendText("Step \(step.id + 1)/\(mutablePlan.steps.count): \(step.title)")
            }

            // --- Execute Step (inner iteration loop) ---
            var stepComplete = false
            while currentStepIterations < step.maxIterations && iteration < runConfig.maxIterations {
                iteration += 1
                currentIteration = iteration
                currentStepIterations += 1
                let iterStartTime = Date()

                // Check for cooperative cancellation
                if isCancellationRequested {
                    await journal.append(.cancelled())
                    await journal.close()
                    onStateChange(.idle)
                    let result = RunResult(
                        runId: runId, success: false, summary: "Cancelled by user",
                        iterations: iteration, finalScore: nil,
                        totalInputTokens: totalInput, totalOutputTokens: totalOutput
                    )
                    resetRunTracking()
                    currentRunId = nil
                    return result
                }

                // Check run timeout
                if let startTime = runStartTime, Date().timeIntervalSince(startTime) > runConfig.maxRunDuration {
                    let reason = "Run exceeded max duration (\(Int(runConfig.maxRunDuration))s)"
                    await journal.append(.fail(reason: reason))
                    await journal.close()
                    onMessage(ChatMessage(role: .system, content: "Warning: \(reason)"))
                    onStateChange(.done)
                    currentRunId = nil
                    return RunResult(
                        runId: runId, success: false, summary: "Timed out",
                        iterations: iteration, finalScore: nil,
                        totalInputTokens: totalInput, totalOutputTokens: totalOutput
                    )
                }

                // Early warning at configured iteration to nudge the model to focus
                if iteration >= runConfig.earlyWarningIteration && !earlyWarningSent {
                    earlyWarningSent = true
                    let remaining = runConfig.maxIterations - iteration
                    let earlyMsg = "You've used \(iteration) of \(runConfig.maxIterations) iterations. Focus on completing the task now or declare it impossible. You have \(remaining) iterations left."
                    NSLog("CyclopOne [Orchestrator]: Early iteration warning at %d/%d (step-driven)", iteration, runConfig.maxIterations)
                    onMessage(ChatMessage(role: .system, content: earlyMsg))
                    await agentLoop.injectIterationWarning(earlyMsg)
                    if let channel = replyChannel {
                        await channel.sendText(earlyMsg)
                    }
                }

                // Budget warning at 80%
                let budgetThreshold = Int(Double(runConfig.maxIterations) * runConfig.budgetWarningPercent)
                if iteration >= budgetThreshold && !budgetWarningSent {
                    budgetWarningSent = true
                    let remaining = runConfig.maxIterations - iteration
                    let warningMsg = "Budget warning: \(remaining) iterations remaining out of \(runConfig.maxIterations) max."
                    onMessage(ChatMessage(role: .system, content: warningMsg))
                    if let channel = replyChannel {
                        await channel.sendText(warningMsg)
                    }
                }

                await journal.append(.iterationStart(iteration: iteration, screenshot: nil))

                // M6: Wrap iteration in a Task for hard-cancel support.
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
                currentIterationTask = iterationTask

                let iterResult: IterationResult
                do {
                    iterResult = try await iterationTask.value
                } catch is CancellationError {
                    // M6: Task was cancelled via hard cancel
                    NSLog("CyclopOne [Orchestrator]: Iteration %d hard-cancelled (step-driven)", iteration)
                    await journal.append(.cancelled())
                    await journal.close()
                    onStateChange(.idle)
                    let result = RunResult(
                        runId: runId, success: false, summary: "Hard-cancelled by user",
                        iterations: iteration, finalScore: nil,
                        totalInputTokens: totalInput, totalOutputTokens: totalOutput
                    )
                    resetRunTracking()
                    currentRunId = nil
                    return result
                } catch let cbError as CircuitBreaker.CircuitBreakerError {
                    let reason = "Circuit breaker open: \(cbError.localizedDescription)"
                    let ssData = preActionScreenshot?.imageData
                    notifyObserver(observer) { obs in
                        await obs.onError(error: reason, screenshot: ssData, isFatal: true)
                    }
                    await journal.append(.fail(reason: reason))
                    await journal.close()
                    onMessage(ChatMessage(role: .system, content: "Error: API circuit breaker triggered. \(cbError.localizedDescription)"))
                    onStateChange(.error(reason))
                    currentRunId = nil
                    return RunResult(
                        runId: runId, success: false, summary: reason,
                        iterations: iteration, finalScore: nil,
                        totalInputTokens: totalInput, totalOutputTokens: totalOutput
                    )
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
                    let ssData = preActionScreenshot?.imageData
                    notifyObserver(observer) { obs in
                        await obs.onError(error: errMsg, screenshot: ssData, isFatal: true)
                    }
                    await journal.append(.fail(reason: "Iteration \(iteration) \(classLabel) error: \(error.localizedDescription)"))
                    await journal.close()
                    onMessage(ChatMessage(role: .system, content: "Error [\(classLabel)]: \(error.localizedDescription)"))
                    onStateChange(.error(error.localizedDescription))
                    currentRunId = nil
                    return RunResult(
                        runId: runId, success: false, summary: error.localizedDescription,
                        iterations: iteration, finalScore: nil,
                        totalInputTokens: totalInput, totalOutputTokens: totalOutput
                    )
                }

                // Check cancellation after iteration
                if isCancellationRequested || iterResult.cancelled {
                    await journal.append(.cancelled())
                    await journal.close()
                    onStateChange(.idle)
                    let result = RunResult(
                        runId: runId, success: false, summary: "Cancelled by user",
                        iterations: iteration, finalScore: nil,
                        totalInputTokens: totalInput + iterResult.inputTokens,
                        totalOutputTokens: totalOutput + iterResult.outputTokens
                    )
                    resetRunTracking()
                    currentRunId = nil
                    return result
                }

                totalInput += iterResult.inputTokens
                totalOutput += iterResult.outputTokens

                // Save post-iteration screenshot + stuck detection
                if let ss = iterResult.screenshot {
                    let ssName = "iter\(iteration)_post.jpg"
                    await journal.saveScreenshot(ss.imageData, name: ssName)
                    recentScreenshotData.append(ss.imageData)
                    if recentScreenshotData.count > runConfig.stuckThreshold {
                        recentScreenshotData.removeFirst()
                    }
                    preActionScreenshot = ss
                }

                // AX tree for stuck detection
                let axTreeSummary = await AccessibilityService.shared.getUITreeSummary(maxDepth: 2)
                recentAXTreeSummaries.append(axTreeSummary)
                if recentAXTreeSummaries.count > runConfig.stuckThreshold {
                    recentAXTreeSummaries.removeFirst()
                }

                // Text response tracking for stuck detection
                let trimmedText = iterResult.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedText.isEmpty {
                    recentTextResponses.append(trimmedText)
                    if recentTextResponses.count > runConfig.stuckThreshold {
                        recentTextResponses.removeFirst()
                    }
                }

                // Track tool call execution
                if iterResult.hasMoreWork {
                    anyToolCallsExecuted = true
                    if iterResult.hasVisualToolCalls {
                        anyVisualToolCalls = true
                    }
                }

                // --- Check completion within this step ---
                let completionTokenFound = containsCompletionToken(iterResult.textContent)
                let claudeIndicatedDone = !iterResult.hasMoreWork

                if completionTokenFound || claudeIndicatedDone {
                    // Agent thinks this step is done -- validate outcome
                    let outcome = validateStepOutcome(
                        step: step,
                        textContent: iterResult.textContent
                    )
                    stepOutcomes.append((step.id, outcome))

                    switch outcome {
                    case .succeeded:
                        NSLog("CyclopOne [Orchestrator]: Step %d succeeded", step.id + 1)
                        stepComplete = true

                    case .uncertain:
                        // Proceed anyway -- don't call Opus for every step (save cost)
                        NSLog("CyclopOne [Orchestrator]: Step %d uncertain, proceeding", step.id + 1)
                        stepComplete = true

                    case .failed(let reason):
                        let crit = effectiveCriticality(of: step)
                        NSLog("CyclopOne [Orchestrator]: Step %d failed (%@): %@", step.id + 1, crit.rawValue, reason)
                        if crit == .critical {
                            let abortReason = "Critical step \(step.id + 1) ('\(step.title)') failed: \(reason). Aborting to prevent cascading errors."
                            NSLog("CyclopOne [Orchestrator]: ABORTING plan — %@", abortReason)
                            await journal.append(.fail(reason: abortReason))
                            await journal.close()
                            if let rc = replyChannel { await rc.sendText("ABORTED: \(abortReason)") }
                            onMessage(ChatMessage(role: .system, content: abortReason))
                            onStateChange(.error(abortReason))
                            currentRunId = nil
                            return RunResult(
                                runId: runId, success: false, summary: abortReason,
                                iterations: iteration, finalScore: nil,
                                totalInputTokens: totalInput, totalOutputTokens: totalOutput,
                                verificationInputTokens: verificationInputTokens,
                                verificationOutputTokens: verificationOutputTokens
                            )
                        }
                        stepComplete = true

                    case .skipped:
                        stepComplete = true
                    }

                    if stepComplete { break }
                }

                // --- Per-step stuck detection ---
                if currentStepIterations >= step.maxIterations {
                    let crit = effectiveCriticality(of: step)
                    NSLog("CyclopOne [Orchestrator]: Step %d exhausted maxIterations (%d), criticality=%@",
                          step.id + 1, step.maxIterations, crit.rawValue)
                    let outcome = StepOutcome.failed(reason: "Exceeded max iterations for step")
                    stepOutcomes.append((step.id, outcome))
                    if crit == .critical {
                        let abortReason = "Critical step \(step.id + 1) ('\(step.title)') exceeded max iterations. Aborting to prevent wrong-field input."
                        NSLog("CyclopOne [Orchestrator]: ABORTING plan — %@", abortReason)
                        await journal.append(.fail(reason: abortReason))
                        await journal.close()
                        if let rc = replyChannel { await rc.sendText("ABORTED: \(abortReason)") }
                        onMessage(ChatMessage(role: .system, content: abortReason))
                        onStateChange(.error(abortReason))
                        currentRunId = nil
                        return RunResult(
                            runId: runId, success: false, summary: abortReason,
                            iterations: iteration, finalScore: nil,
                            totalInputTokens: totalInput, totalOutputTokens: totalOutput,
                            verificationInputTokens: verificationInputTokens,
                            verificationOutputTokens: verificationOutputTokens
                        )
                    }
                    stepComplete = true
                    break
                }

                // Global stuck detection (safety net)
                if iteration >= runConfig.stuckThreshold, let stuckReason = detectStuck() {
                    if !hasEscalatedToBrain {
                        hasEscalatedToBrain = true
                        let brainModel = AgentConfig().brainModel
                        NSLog("CyclopOne [Orchestrator]: Stuck detected (%@) at step %d, consulting brain (%@)",
                              stuckReason, step.id + 1, brainModel)
                        await journal.append(.stuck(reason: "\(stuckReason) at step \(step.id + 1) -- consulting \(brainModel)"))

                        let brainPrompt = """
                        The agent executing the task "\(command)" is stuck at step \(step.id + 1): "\(step.title)". \
                        Reason: \(stuckReason). \
                        The agent has completed \(iteration) iterations so far (\(currentStepIterations) on this step). \
                        Recent actions have not made progress. \
                        Provide 2-3 concise, specific suggestions for what the agent should try differently. \
                        Focus on alternative approaches, not repeating what failed.
                        """
                        do {
                            let brainResponse = try await ClaudeAPIService.shared.sendMessage(
                                messages: [["role": "user", "content": brainPrompt]],
                                systemPrompt: "You are a strategic advisor helping an autonomous desktop agent get unstuck. Be concise and actionable.",
                                tools: [],
                                model: brainModel,
                                maxTokens: 1024
                            )
                            let advice = brainResponse.textContent
                            NSLog("CyclopOne [Orchestrator]: Brain advice received (%d chars)", advice.count)
                            onMessage(ChatMessage(role: .system, content: "Agent stuck at step \(step.id + 1) — consulting brain model for guidance..."))
                            await agentLoop.injectBrainGuidance(advice)
                        } catch {
                            NSLog("CyclopOne [Orchestrator]: Brain consultation failed: %@", error.localizedDescription)
                            onMessage(ChatMessage(role: .system, content: "Error: Brain consultation failed — \(error.localizedDescription)"))
                        }

                        recentScreenshotData.removeAll()
                        recentTextResponses.removeAll()
                        continue
                    }

                    // Already consulted brain and still stuck -- terminate step
                    let crit = effectiveCriticality(of: step)
                    NSLog("CyclopOne [Orchestrator]: Still stuck after brain consultation, ending step %d (criticality=%@)", step.id + 1, crit.rawValue)
                    let outcome = StepOutcome.failed(reason: stuckReason)
                    stepOutcomes.append((step.id, outcome))
                    if crit == .critical {
                        let abortReason = "Critical step \(step.id + 1) ('\(step.title)') stuck after brain consultation: \(stuckReason). Aborting."
                        NSLog("CyclopOne [Orchestrator]: ABORTING plan — %@", abortReason)
                        await journal.append(.fail(reason: abortReason))
                        await journal.close()
                        if let rc = replyChannel { await rc.sendText("ABORTED: \(abortReason)") }
                        onMessage(ChatMessage(role: .system, content: abortReason))
                        onStateChange(.error(abortReason))
                        currentRunId = nil
                        return RunResult(
                            runId: runId, success: false, summary: abortReason,
                            iterations: iteration, finalScore: nil,
                            totalInputTokens: totalInput, totalOutputTokens: totalOutput,
                            verificationInputTokens: verificationInputTokens,
                            verificationOutputTokens: verificationOutputTokens
                        )
                    }
                    stepComplete = true
                    break
                }

                await journal.append(.iterationEnd(iteration: iteration, screenshot: nil, verificationScore: nil))

                let actionDesc = iterResult.textContent.isEmpty
                    ? "Processing..."
                    : String(iterResult.textContent.prefix(120))
                lastActionDescription = actionDesc

                // Enforce minimum iteration duration
                let iterElapsed = Date().timeIntervalSince(iterStartTime)
                if iterElapsed < runConfig.minIterationDuration {
                    let remaining = runConfig.minIterationDuration - iterElapsed
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
            }

            // M3: Fire step complete observer event (fire-and-forget to avoid blocking)
            if stepComplete {
                let outcomeDesc = stepOutcomes.last.map { describeOutcome($0.1) } ?? "unknown"
                let completeStepId = step.id
                let completeTotalSteps = mutablePlan.steps.count
                let completeTitle = step.title
                let completeSS = preActionScreenshot?.imageData
                notifyObserver(observer) { obs in
                    await obs.onStepComplete(
                        stepIndex: completeStepId,
                        totalSteps: completeTotalSteps,
                        title: completeTitle,
                        outcome: outcomeDesc,
                        screenshot: completeSS
                    )
                }
            }

            // Advance to next step
            currentStepIndex += 1
        }

        // --- All steps completed: run final verification ---
        NSLog("CyclopOne [Orchestrator]: All %d steps completed, running final verification", mutablePlan.steps.count)

        let stepSummary = stepOutcomes.map { (id, outcome) in
            "Step \(id + 1): \(describeOutcome(outcome))"
        }.joined(separator: "; ")

        // Final verification using existing VerificationEngine
        let score: Int
        let passed: Bool
        let reason: String
        if !anyToolCallsExecuted {
            score = 100; passed = true; reason = "Text-only run, auto-pass"
        } else if !anyVisualToolCalls {
            score = 100; passed = true; reason = "Non-visual tools only, auto-pass"
        } else {
            let verificationResult = await verificationEngine.verify(
                command: command,
                textContent: stepSummary,
                postScreenshot: preActionScreenshot,
                preScreenshot: nil,
                threshold: runConfig.verificationThreshold
            )
            score = verificationResult.overall
            passed = verificationResult.passed
            reason = verificationResult.reason
        }
        verificationInputTokens += await verificationEngine.lastVerificationInputTokens
        verificationOutputTokens += await verificationEngine.lastVerificationOutputTokens

        NSLog("CyclopOne [Orchestrator]: Step-driven run complete -- score=%d, passed=%d, steps=%d, iterations=%d",
              score, passed, mutablePlan.steps.count, iteration)

        // M3: Fire completion observer event (fire-and-forget to avoid blocking)
        let finalStepCount = mutablePlan.steps.count
        let finalScore = score
        let finalIter = iteration
        notifyObserver(observer) { obs in
            await obs.onCompletion(
                success: passed,
                summary: "Completed (score: \(finalScore), \(finalStepCount) steps)",
                score: finalScore,
                iterations: finalIter
            )
        }

        await journal.append(.complete(
            summary: "Plan complete (\(mutablePlan.steps.count) steps, verification: \(score)). \(stepSummary)",
            finalScore: score
        ))
        await journal.close()

        // Post-run memory recording
        let outcome = RunOutcome(
            runId: runId, command: command, success: passed,
            score: score, iterations: iteration
        )
        await memoryService.recordRunOutcome(outcome)
        await memoryService.updateCurrentStatus(
            lastCommand: command,
            lastOutcome: passed ? "Success (score: \(score))" : "Failed (score: \(score))",
            timestamp: Date()
        )
        if !passed {
            await memoryService.recordFailure(
                command: command, reason: reason, iterations: iteration
            )
        }

        onStateChange(.done)
        currentRunId = nil
        let result = RunResult(
            runId: runId, success: passed, summary: "Completed (score: \(score), \(mutablePlan.steps.count) steps)",
            iterations: iteration, finalScore: score,
            totalInputTokens: totalInput, totalOutputTokens: totalOutput,
            verificationInputTokens: verificationInputTokens,
            verificationOutputTokens: verificationOutputTokens
        )
        updateClassifierContext(command: command, result: result)
        return result
    }

    // MARK: - M6: Hard Cancel (replaces Sprint 11 cancel())

    /// Two-phase cancellation:
    /// 1. Set cooperative flags (existing behavior, immediate)
    /// 2. Cancel the Swift Task (propagates through every await)
    /// 3. Start watchdog timer for force-termination
    func cancelCurrentRun() {
        guard currentRunId != nil else { return }
        guard !isHardCancelInProgress else {
            NSLog("CyclopOne [Orchestrator]: Hard cancel already in progress, ignoring duplicate")
            return
        }

        isHardCancelInProgress = true
        isCancellationRequested = true

        // Cancel the iteration Task -- this propagates CancellationError
        // through every `await` in the AgentLoop call chain
        if let task = currentIterationTask {
            task.cancel()
            NSLog("CyclopOne [Orchestrator]: Hard cancel -- iteration Task cancelled")
        } else {
            NSLog("CyclopOne [Orchestrator]: Hard cancel -- no active iteration Task")
        }

        // Start watchdog: if the iteration does not stop within cancelTimeout,
        // force-terminate the run
        cancelWatchdog?.cancel()
        cancelWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(5.0 * 1_000_000_000))
            guard let self = self else { return }
            let stillRunning = await self.isRunning
            if stillRunning {
                NSLog("CyclopOne [Orchestrator]: WATCHDOG FIRED -- force-terminating run after 5s")
                await self.forceTerminateRun()
            }
        }
    }

    /// Force-terminate the current run. Nuclear option invoked by the watchdog.
    private func forceTerminateRun() {
        currentIterationTask?.cancel()
        currentIterationTask = nil
        cancelWatchdog?.cancel()
        cancelWatchdog = nil
        isHardCancelInProgress = false
        resetRunTracking()
        currentRunId = nil
        NSLog("CyclopOne [Orchestrator]: Run force-terminated")
    }

    /// Clean up cancel infrastructure after a run completes normally.
    private func cleanupCancelState() {
        currentIterationTask = nil
        cancelWatchdog?.cancel()
        cancelWatchdog = nil
        isHardCancelInProgress = false
    }

    // MARK: - Status (Sprint 11)

    /// Returns a snapshot of the current orchestrator state for status reporting.
    func getStatus() -> OrchestratorStatus {
        OrchestratorStatus(
            isRunning: currentRunId != nil,
            currentCommand: currentCommand,
            iterationCount: currentIteration,
            startTime: runStartTime,
            lastAction: lastActionDescription,
            runId: currentRunId
        )
    }

    // MARK: - State

    var isRunning: Bool { currentRunId != nil }

    // MARK: - Stuck Detection (Sprint 14 enhanced)

    // MARK: - Meta-Command Handling

    /// Handle meta-commands (status, stop, screenshot, help) directly.
    /// These bypass planning and the agent loop entirely.
    private func handleMetaCommand(
        _ command: MetaCommandType,
        replyChannel: (any ReplyChannel)?,
        onMessage: @Sendable @escaping (ChatMessage) -> Void
    ) async -> String {
        switch command {
        case .status:
            let status = getStatus()
            let msg = status.isRunning
                ? "Running: \(status.currentCommand ?? "unknown") — iteration \(status.iterationCount), \(status.durationString ?? "?")"
                : "Idle — no active task."
            if let rc = replyChannel { await rc.sendText(msg) }
            onMessage(ChatMessage(role: .assistant, content: msg))
            return msg

        case .stop:
            cancelCurrentRun()
            let msg = "Cancellation requested."
            if let rc = replyChannel { await rc.sendText(msg) }
            onMessage(ChatMessage(role: .assistant, content: msg))
            return msg

        case .screenshot:
            do {
                let capture = try await ScreenCaptureService.shared.captureScreen(maxDimension: 1280, quality: 0.7)
                if let rc = replyChannel { await rc.sendScreenshot(capture.imageData) }
                onMessage(ChatMessage(role: .system, content: "[Screenshot captured]"))
                return "Screenshot sent"
            } catch {
                let msg = "Screenshot failed: \(error.localizedDescription)"
                if let rc = replyChannel { await rc.sendText(msg) }
                return msg
            }

        case .help:
            let msg = """
            I'm Cyclop One, your desktop automation agent. I can:
            - Open and control apps on your Mac
            - Click, type, drag, and scroll
            - Search the web, fill forms, send messages
            - Take screenshots and read screen content

            Just tell me what to do in plain language.
            Say "stop" to cancel, "status" to check progress.
            """
            if let rc = replyChannel { await rc.sendText(msg) }
            onMessage(ChatMessage(role: .assistant, content: msg))
            return msg
        }
    }

    // MARK: - M2: Brain Planning (Structured JSON)

    /// Planning system prompt for structured JSON output.
    private static let planningSystemPrompt = """
    You are a planning agent for a macOS desktop automation agent called Cyclop One.

    Your job is to decompose the user's command into a step-by-step execution plan.
    The plan will be executed by a fast but less capable model (Haiku) that follows
    instructions literally.

    Output ONLY a JSON object. No other text, no markdown fences.

    ## Output Format

    {
      "summary": "Brief description of the approach",
      "steps": [
        {
          "title": "Short step name",
          "action": "Detailed instruction for the executor. Be specific about what to click, what to type. The executor sees ONLY this instruction plus a screenshot -- it does not see the full plan.",
          "targetApp": "The app, website, or tool to use for this step (e.g., 'Safari', 'Messages', 'Terminal', 'google.com'). null if no specific app is needed.",
          "expectedOutcome": "What the screen should show after this step. Be specific: 'Safari is open with google.com loaded' not 'browser is open'.",
          "requiresConfirmation": false,
          "maxIterations": 3,
          "expectedTools": ["open_application"]
        }
      ]
    }

    ## Rules

    1. Each step must be independently executable from a screenshot + the action text.
       Do NOT write "continue from previous step" -- describe the full context.
       The action MUST specify the EXACT UI element by its visible label or position
       (e.g., "the text area to the right of the To: label"). Generic instructions like
       "enter the email" are NOT specific enough.
    2. Mark steps IRREVERSIBLE with "requiresConfirmation": true. Examples:
       - Sending email/messages
       - Deleting files
       - Submitting forms
       - Making purchases
       - Publishing content
    3. maxIterations per step:
       - Pure text input (type into focused field, press Tab/Enter): maxIterations = 2
       - Single click or navigate to app/URL: maxIterations = 3
       - Multi-field form fill (Tab between fields): maxIterations = 3
       - Complex multi-action (search, scroll, select): maxIterations = 5
       NEVER set maxIterations above 5 for any single step.
    4. expectedOutcome must be verifiable from a screenshot. Avoid abstract outcomes
       like "task is done" -- describe what is VISIBLE on screen.
    5. Maximum 10 steps. If the task needs more, break it into phases and plan phase 1.
    6. expectedTools: list the tool names the executor will likely need.
       Available tools: click, right_click, type_text, press_key, take_screenshot,
       open_application, open_url, run_shell_command, run_applescript, move_mouse,
       drag, scroll, vault_read, vault_write, vault_search, vault_list, vault_append,
       remember, recall, task_create, task_update, task_list, openclaw_send, openclaw_check
    7. For form-filling or email steps, instruct the executor to use Tab to navigate
       between fields instead of clicking each one separately. This is faster and
       more reliable.

    ## Email Task Planning
    When decomposing email tasks:
    - The To field is at the TOP of the compose window. Subject is below it. Body is below Subject.
    - ALWAYS instruct the executor to type the email address DIRECTLY in the To field.
      NEVER instruct to search contacts, browse address book, or use autocomplete.
    - After typing the email address, instruct to press Return to confirm it.
    - Use Tab to move between fields (To → Subject → Body).
    - The Send step MUST have "requiresConfirmation": true.

    ## Form Field Planning
    - Always specify field position relative to the window (top/middle/bottom).
    - For sequential fields, use Tab navigation instead of clicking each field.
    - Each step action must be unambiguous — the executor only sees the action text + a screenshot.

    ## Example: Send an email
    User command: "Send an email to user@example.com saying hello"

    {
      "summary": "Open Mail, compose email to user@example.com with greeting",
      "steps": [
        {
          "title": "Open Mail and compose",
          "action": "Open the Mail application. Once Mail is open, press Cmd+N to create a new compose window.",
          "targetApp": "Mail",
          "expectedOutcome": "A new Mail compose window is visible with empty To, Subject, and Body fields.",
          "requiresConfirmation": false,
          "maxIterations": 3,
          "expectedTools": ["open_application", "press_key"]
        },
        {
          "title": "Type recipient in To field",
          "action": "Click directly on the text area to the RIGHT of the 'To:' label at the TOP of the compose window. Type: user@example.com. Then press Return to confirm. Do NOT use autocomplete or contacts.",
          "targetApp": "Mail",
          "expectedOutcome": "The To field shows user@example.com as a confirmed recipient.",
          "requiresConfirmation": false,
          "maxIterations": 3,
          "expectedTools": ["click", "type_text", "press_key"]
        },
        {
          "title": "Type subject",
          "action": "Press Tab to move focus to the Subject field. Type: Hello",
          "targetApp": "Mail",
          "expectedOutcome": "The Subject field shows 'Hello'.",
          "requiresConfirmation": false,
          "maxIterations": 2,
          "expectedTools": ["press_key", "type_text"]
        },
        {
          "title": "Type body and send",
          "action": "Press Tab to move focus to the message body. Type: Hello! Then click the Send button or press Cmd+Shift+D.",
          "targetApp": "Mail",
          "expectedOutcome": "The compose window closes, email sent.",
          "requiresConfirmation": true,
          "maxIterations": 3,
          "expectedTools": ["press_key", "type_text", "click"]
        }
      ]
    }
    """

    /// Consult the brain model (Opus) for a structured execution plan.
    ///
    /// Returns an ExecutionPlan with parsed steps, or an empty plan if
    /// the brain call fails or returns unparseable JSON.
    private func consultBrainForPlan(
        command: String,
        model: String,
        complexity: TaskComplexity
    ) async -> ExecutionPlan {
        let planPrompt = """
        The user's command is:

        "\(command)"

        Task complexity: \(complexity.rawValue)
        """
        do {
            let response = try await ClaudeAPIService.shared.sendMessage(
                messages: [["role": "user", "content": planPrompt]],
                systemPrompt: Self.planningSystemPrompt,
                tools: [],
                model: model,
                maxTokens: 1024
            )
            let responseText = response.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("CyclopOne [Orchestrator]: Brain plan response from %@ (%d chars)", model, responseText.count)
            return parseBrainPlanResponse(responseText, command: command)
        } catch {
            NSLog("CyclopOne [Orchestrator]: Brain planning failed: %@", error.localizedDescription)
            return ExecutionPlan(command: command, steps: [], summary: "")
        }
    }

    /// Parse the brain model's JSON response into an ExecutionPlan.
    /// Falls back to an empty plan if parsing fails.
    private func parseBrainPlanResponse(_ responseText: String, command: String) -> ExecutionPlan {
        // Step 1: Extract JSON from potential markdown wrapping
        let jsonString = extractJSON(from: responseText)

        // Step 2: Parse JSON
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stepsArray = json["steps"] as? [[String: Any]],
              !stepsArray.isEmpty else {
            NSLog("CyclopOne [Orchestrator]: Failed to parse brain plan JSON, falling back to empty plan")
            return ExecutionPlan(command: command, steps: [], summary: "")
        }

        let summary = json["summary"] as? String ?? ""

        // Step 3: Parse each step with defensive defaults
        let steps: [PlanStep] = stepsArray.enumerated().compactMap { index, stepDict in
            guard let title = stepDict["title"] as? String,
                  let action = stepDict["action"] as? String,
                  let expectedOutcome = stepDict["expectedOutcome"] as? String else {
                NSLog("CyclopOne [Orchestrator]: Skipping malformed step at index %d", index)
                return nil
            }
            let targetApp = stepDict["targetApp"] as? String
            let critStr = stepDict["criticality"] as? String
            let criticality = critStr.flatMap { StepCriticality(rawValue: $0) } ?? .normal
            return PlanStep(
                id: index,
                title: title,
                action: action,
                expectedOutcome: expectedOutcome,
                requiresConfirmation: stepDict["requiresConfirmation"] as? Bool ?? false,
                maxIterations: stepDict["maxIterations"] as? Int ?? 3,
                targetApp: targetApp,
                expectedTools: stepDict["expectedTools"] as? [String],
                criticality: criticality
            )
        }

        NSLog("CyclopOne [Orchestrator]: Parsed %d plan steps from brain response", steps.count)
        return ExecutionPlan(command: command, steps: steps, summary: summary)
    }

    /// Extract JSON from potential markdown wrapping (```json...``` or raw JSON).
    private func extractJSON(from text: String) -> String {
        // Try to find JSON between code fences
        if let start = text.range(of: "```json"),
           let end = text.range(of: "```", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = text.range(of: "```"),
           let end = text.range(of: "```", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Try to find a raw JSON object
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text
    }

    // MARK: - M2: Plan Display & Step Building

    /// Format an ExecutionPlan for human display.
    private func formatPlanForUser(_ plan: ExecutionPlan) -> String {
        var lines: [String] = []
        lines.append("Plan: \(plan.summary)")
        lines.append("")
        for step in plan.steps {
            let confirmTag = step.requiresConfirmation ? " [CONFIRM]" : ""
            let targetTag = step.targetApp.map { " [\($0)]" } ?? ""
            lines.append("\(step.id + 1). \(step.title)\(confirmTag)\(targetTag)")
            lines.append("   \(step.action)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Build the instruction string injected into the executor's system prompt
    /// for a specific plan step.
    private func buildStepInstruction(step: PlanStep, plan: ExecutionPlan, stepOutcomes: [(Int, StepOutcome)] = []) -> String {
        var instruction = "Step \(step.id + 1) of \(plan.steps.count): \(step.title)"
        instruction += "\n\n\(step.action)"

        if let targetApp = step.targetApp {
            instruction += "\n\nTARGET APP: \(targetApp)"
        }

        instruction += "\n\nEXPECTED RESULT: \(step.expectedOutcome)"

        // Add context about what was done previously (brief, not full history)
        if step.id > 0 {
            let previousTitles = plan.steps.prefix(step.id).map { $0.title }
            instruction += "\n\nPrevious steps completed: \(previousTitles.joined(separator: ", "))"
        }

        // Warn about previous step failures
        let failedSteps = stepOutcomes.filter { if case .failed = $0.1 { return true }; return false }
        if !failedSteps.isEmpty {
            let failedDesc = failedSteps.map { "Step \($0.0 + 1)" }.joined(separator: ", ")
            instruction += "\n\nWARNING: Previous steps failed: \(failedDesc). Verify preconditions before acting."
        }

        return instruction
    }

    // MARK: - M2: Step Criticality

    /// Determine the effective criticality of a step.
    /// If the brain explicitly set it, use that. Otherwise, auto-classify
    /// based on action keywords: text-input steps are critical.
    private func effectiveCriticality(of step: PlanStep) -> StepCriticality {
        if step.criticality != .normal { return step.criticality }
        let actionLower = step.action.lowercased()
        let criticalKeywords = [
            "type", "enter", "fill", "input", "email", "address",
            "recipient", "compose", "write", "paste", "type_text",
            "send", "submit", "password", "username", "login", "sign in"
        ]
        if criticalKeywords.contains(where: { actionLower.contains($0) }) {
            return .critical
        }
        return .normal
    }

    // MARK: - M2: Step Outcome Validation

    /// Validate whether a plan step's expected outcome was achieved.
    /// Uses a lightweight heuristic approach (no Opus calls per step).
    private func validateStepOutcome(
        step: PlanStep,
        textContent: String
    ) -> StepOutcome {
        let heuristicScore = computeStepHeuristicScore(
            step: step,
            textContent: textContent
        )

        if heuristicScore >= 0.8 {
            return .succeeded(
                confidence: heuristicScore,
                evidence: "Heuristic score \(String(format: "%.2f", heuristicScore)): text matches expected outcome"
            )
        }

        if heuristicScore <= 0.3 {
            return .failed(
                reason: "Heuristic score \(String(format: "%.2f", heuristicScore)): outcome does not match expected"
            )
        }

        // Uncertain range (0.3-0.8): proceed but log
        return .uncertain(
            confidence: heuristicScore,
            evidence: "Heuristic score \(String(format: "%.2f", heuristicScore)): uncertain match"
        )
    }

    /// Compute a heuristic confidence score (0.0-1.0) for whether a step
    /// achieved its expected outcome.
    private func computeStepHeuristicScore(
        step: PlanStep,
        textContent: String
    ) -> Double {
        var score = 0.0
        var factors = 0

        // Factor 1: Keyword overlap with expectedOutcome
        let outcomeKeywords = extractKeywords(from: step.expectedOutcome)
        let textLower = textContent.lowercased()
        let matchedKeywords = outcomeKeywords.filter { textLower.contains($0) }
        if !outcomeKeywords.isEmpty {
            let keywordRatio = Double(matchedKeywords.count) / Double(outcomeKeywords.count)
            score += keywordRatio
            factors += 1
        }

        // Factor 2: No error indicators
        let hasErrors = ["error", "failed", "not found", "denied", "timeout"]
            .contains { textLower.contains($0) }
        score += hasErrors ? 0.0 : 0.8
        factors += 1

        // Factor 3: Tool usage matches expectedTools
        if let expectedTools = step.expectedTools, !expectedTools.isEmpty {
            let usedExpectedTool = expectedTools.contains { tool in
                textLower.contains(tool.lowercased())
            }
            score += usedExpectedTool ? 0.9 : 0.3
            factors += 1
        }

        // Factor 4: Completion signal present
        if containsCompletionToken(textContent) || !textContent.isEmpty {
            score += 0.7
            factors += 1
        }

        return factors > 0 ? score / Double(factors) : 0.5
    }

    /// Extract meaningful keywords from a string for fuzzy matching.
    private func extractKeywords(from text: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "be", "been",
            "being", "have", "has", "had", "do", "does", "did", "will",
            "would", "could", "should", "may", "might", "shall", "can",
            "to", "of", "in", "for", "on", "with", "at", "by", "from",
            "and", "or", "not", "no", "but", "if", "then", "than",
            "that", "this", "it", "its"
        ]
        return text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }

    /// Describe a StepOutcome as a human-readable string.
    private func describeOutcome(_ outcome: StepOutcome) -> String {
        switch outcome {
        case .succeeded(let confidence, let evidence):
            return "Succeeded (confidence: \(String(format: "%.2f", confidence)), \(evidence))"
        case .uncertain(let confidence, let evidence):
            return "Uncertain (confidence: \(String(format: "%.2f", confidence)), \(evidence))"
        case .failed(let reason):
            return "Failed (\(reason))"
        case .skipped(let reason):
            return "Skipped (\(reason))"
        }
    }

    /// Generate a quick conversational reply for non-task messages (greetings, questions).
    /// Uses Haiku for speed — no tools, no screenshots, just a text response.
    private func generateChatReply(command: String) async -> String {
        do {
            let response = try await ClaudeAPIService.shared.sendMessage(
                messages: [["role": "user", "content": command]],
                systemPrompt: "You are Cyclop One. Reply like a chill friend over text — super short, no introductions, no explaining what you are. Never say your name or what you do unless asked. Just vibe.",
                tools: [],
                model: AgentConfig().modelName,
                maxTokens: 256
            )
            return response.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            NSLog("CyclopOne [Orchestrator]: Chat reply failed: %@", error.localizedDescription)
            return "Hey! What's up?"
        }
    }

    /// Enhanced stuck detection that checks both screenshot similarity and text repetition.
    ///
    /// Returns a reason string if stuck is detected, nil otherwise.
    private func detectStuck() -> String? {
        // Check 1: Screenshot similarity (original logic)
        if isScreenshotStuck() {
            return "Last \(runConfig.stuckThreshold) screenshots are identical"
        }

        // Check 2: Text response repetition (Sprint 14)
        if isTextStuck() {
            return "Last \(runConfig.stuckThreshold) text responses are repeating"
        }

        return nil
    }

    /// Check if the last N screenshots are identical (agent is stuck).
    /// Uses byte-level comparison — identical Data means identical pixels.
    ///
    /// Enhanced: also checks the AX tree summaries. If screenshots are byte-identical
    /// but the AX tree has changed between iterations, the agent IS making progress
    /// (e.g. typing text that doesn't change the visual layout enough to alter the screenshot).
    /// In that case, we do NOT report stuck.
    private func isScreenshotStuck() -> Bool {
        guard recentScreenshotData.count >= runConfig.stuckThreshold else { return false }
        let recent = Array(recentScreenshotData.suffix(runConfig.stuckThreshold))
        let first = recent[0]
        let allIdentical = recent.dropFirst().allSatisfy { $0 == first }

        guard allIdentical else { return false }

        // Screenshots are byte-identical — but check if the AX tree changed.
        // If the AX tree differs across any of the recent entries, the agent
        // is making progress despite identical screenshots.
        if recentAXTreeSummaries.count >= runConfig.stuckThreshold {
            let recentAX = Array(recentAXTreeSummaries.suffix(runConfig.stuckThreshold))
            let firstAX = recentAX[0]
            let allAXIdentical = recentAX.dropFirst().allSatisfy { $0 == firstAX }
            if !allAXIdentical {
                NSLog("CyclopOne [Orchestrator]: Screenshots are byte-identical but AX tree changed — NOT stuck (progress detected via AX)")
                return false
            }
        }

        NSLog("CyclopOne [Orchestrator]: Screenshot stuck detected — last %d screenshots are byte-identical (%d bytes each) AND AX tree unchanged",
              runConfig.stuckThreshold, first.count)
        return true
    }

    /// Check if the last N text responses are substantially the same.
    /// Uses normalized comparison to catch near-identical responses that differ
    /// only in whitespace, punctuation, or minor variations.
    private func isTextStuck() -> Bool {
        guard recentTextResponses.count >= runConfig.stuckThreshold else { return false }
        let recent = Array(recentTextResponses.suffix(runConfig.stuckThreshold))

        // Normalize: lowercase, collapse whitespace, trim
        let normalized = recent.map { normalizeForComparison($0) }
        let first = normalized[0]

        // All responses must be identical after normalization
        return normalized.dropFirst().allSatisfy { $0 == first }
    }

    /// Normalize text for stuck comparison: lowercase, collapse whitespace,
    /// remove leading/trailing whitespace.
    private func normalizeForComparison(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Completion Token Detection

    /// Detect the `<task_complete/>` marker in Claude's text response.
    /// Robust against whitespace variations, case differences, and minor formatting.
    /// Matches: `<task_complete/>`, `<task_complete />`, `<TASK_COMPLETE/>`,
    /// `< task_complete / >`, `<task_complete>`, etc.
    private func containsCompletionToken(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
        // Match <task_complete/> or <task_complete> (self-closing or not)
        return normalized.contains("<task_complete/>")
            || normalized.contains("<task_complete>")
    }

    // MARK: - Observer Helpers

    /// Fire an observer callback without blocking the iteration loop.
    /// Uses a detached task with a 5-second timeout so slow Telegram I/O
    /// (rate limits, network issues, offline) cannot stall the agent.
    private func notifyObserver(
        _ observer: (any AgentObserver)?,
        _ body: @Sendable @escaping (any AgentObserver) async -> Void
    ) {
        guard let obs = observer else { return }
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await body(obs) }
                group.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000) }
                await group.next()
                group.cancelAll()
            }
        }
    }

    // MARK: - Helpers

    private func generateRunId() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let ts = formatter.string(from: Date())
        let suffix = String(UUID().uuidString.prefix(8).lowercased())
        return "\(ts)_\(suffix)"
    }

    private func generateCompletionToken() -> String {
        (0..<16).map { _ in String(format: "%x", Int.random(in: 0...15)) }.joined()
    }

    /// Reset run tracking state. Called at the start and end of each run.
    private func resetRunTracking() {
        currentCommand = nil
        currentIteration = 0
        runStartTime = nil
        lastActionDescription = nil
        isCancellationRequested = false
    }
}

// MARK: - OrchestratorStatus

/// Snapshot of the orchestrator's current state, used for /status reporting.
struct OrchestratorStatus: Sendable {
    let isRunning: Bool
    let currentCommand: String?
    let iterationCount: Int
    let startTime: Date?
    let lastAction: String?
    let runId: String?

    /// Formatted duration string (e.g. "1m 23s") or nil if not running.
    var durationString: String? {
        guard let start = startTime else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}
