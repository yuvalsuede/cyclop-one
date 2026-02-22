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
        var maxIterations: Int = 30
        var maxRunDuration: TimeInterval = 30 * 60  // 30 minutes
        var minIterationDuration: TimeInterval = 5   // 5 seconds
        var maxIterationDuration: TimeInterval = 5 * 60  // 5 minutes
        var stuckThreshold: Int = 6  // consecutive identical screenshots/texts before circuit break
        var verificationThreshold: Int = 60  // minimum score to pass verification
        var budgetWarningPercent: Double = 0.8  // warn at 80% of max iterations
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

    /// Memory service for persistent vault-backed memory across runs.
    private let memoryService = MemoryService.shared

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
    ///   - onProgress: Optional callback fired after each iteration with (iterationNumber, lastActionDescription).
    func startRun(
        command: String,
        source: String = "chat",
        agentLoop: AgentLoop,
        replyChannel: (any ReplyChannel)? = nil,
        targetPID: pid_t? = nil,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void,
        onConfirmationNeeded: @Sendable @escaping (String) async -> Bool,
        onProgress: (@Sendable (Int, String) -> Void)? = nil
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
            onProgress: onProgress
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
        onConfirmationNeeded: @Sendable @escaping (String) async -> Bool
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
                        onConfirmationNeeded: onConfirmationNeeded
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
    ///   - onProgress: Optional callback fired after each iteration.
    /// - Returns: The run result, or `nil` if the run could not be resumed.
    func resumeRun(
        runId: String,
        agentLoop: AgentLoop,
        replyChannel: (any ReplyChannel)? = nil,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void,
        onConfirmationNeeded: @Sendable @escaping (String) async -> Bool,
        onProgress: (@Sendable (Int, String) -> Void)? = nil
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
            onProgress: onProgress
        )
    }

    // MARK: - Shared Iteration Loop

    /// Shared iteration loop used by both `startRun` and `resumeRun`.
    /// Eliminates code duplication between the two entry points.
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
        onProgress: (@Sendable (Int, String) -> Void)?
    ) async -> RunResult {
        var totalInput = totalInput
        var totalOutput = totalOutput
        var iteration = startIteration
        var anyToolCallsExecuted = false
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

            // Execute one iteration with circuit breaker + retry
            let iterResult: IterationResult
            do {
                iterResult = try await executeIterationWithRetry(
                    agentLoop: agentLoop,
                    iteration: iteration,
                    journal: journal,
                    onStateChange: onStateChange,
                    onMessage: onMessage,
                    onConfirmationNeeded: onConfirmationNeeded
                )
            } catch let cbError as CircuitBreaker.CircuitBreakerError {
                let reason = "Circuit breaker open: \(cbError.localizedDescription)"
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

            // Track whether any tool calls were executed across the run.
            // hasMoreWork is true only when Claude returned tool_use blocks
            // that were executed (see AgentLoop.executeIteration).
            if iterResult.hasMoreWork {
                anyToolCallsExecuted = true
            }

            // Check completion marker or no-more-work as completion signals.
            // SECURITY: Claude outputs the canonical marker <task_complete/>;
            // the secret token is never exposed in the prompt.
            let completionTokenFound = iterResult.textContent.contains("<task_complete/>")
            let claudeIndicatedDone = !iterResult.hasMoreWork

            if completionTokenFound || claudeIndicatedDone {
                let completionSource = completionTokenFound ? "token match" : "Claude indicated done"
                NSLog("CyclopOne [Orchestrator]: Completion signal detected — source=%@, iteration=%d, anyToolCalls=%d, rejectedSoFar=%d",
                      completionSource, iteration, anyToolCallsExecuted, rejectedCompletions)

                // Skip visual verification for text-only runs (no tool calls executed).
                // Verification scores visual/structural/output which only makes sense
                // when the agent performed actions on screen.
                let score: Int
                let passed: Bool
                let reason: String
                if !anyToolCallsExecuted {
                    score = 100
                    passed = true
                    reason = "Text-only run, auto-pass"
                    NSLog("CyclopOne [Orchestrator]: Text-only run, skipping verification (auto-pass score=100)")
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
                return RunResult(
                    runId: runId, success: passed, summary: "Completed (score: \(score))",
                    iterations: iteration, finalScore: score,
                    totalInputTokens: totalInput, totalOutputTokens: totalOutput,
                    verificationInputTokens: verificationInputTokens,
                    verificationOutputTokens: verificationOutputTokens
                )
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
            onProgress?(iteration, actionDesc)

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

    // MARK: - Cancellation (Sprint 11)

    /// Request cooperative cancellation of the current run.
    /// The run loop checks this flag at the start of each iteration.
    func cancel() {
        guard currentRunId != nil else { return }
        isCancellationRequested = true
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
