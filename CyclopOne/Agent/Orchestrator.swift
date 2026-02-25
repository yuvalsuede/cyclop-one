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
///
/// Extension files:
/// - Orchestrator+IterationLoops.swift — Flat iteration loop
/// - Orchestrator+StepDrivenLoop.swift — Step-driven iteration loop
/// - Orchestrator+IterationHelpers.swift — Shared iteration helpers (retry, pre/post checks)
/// - Orchestrator+BrainPlanning.swift — Brain model planning and stuck consultation
/// - Orchestrator+Resume.swift — Crash recovery resume
/// - Orchestrator+Helpers.swift — Meta-commands, chat reply, memory recording
actor Orchestrator {

    // MARK: - Configuration

    struct RunConfig {
        var maxIterations: Int = 50
        var maxRunDuration: TimeInterval = 60 * 60  // 60 minutes
        var minIterationDuration: TimeInterval = 5   // 5 seconds
        var maxIterationDuration: TimeInterval = 5 * 60  // 5 minutes
        var stuckThreshold: Int = 3  // consecutive identical screenshots/texts before circuit break
        var verificationThreshold: Int = 50  // minimum score to pass verification
        var budgetWarningPercent: Double = 0.8  // warn at 80% of max iterations
        var earlyWarningIteration: Int = 20  // inject focus message at this iteration
        var iterationRetryStrategy: RetryStrategy = .exponentialBackoff(base: 2.0, maxDelay: 30.0, maxAttempts: 3)
        var maxTokensPerRun: Int = 400_000  // cumulative token cap — system prompt re-sent every call, so per-call ~15K × many iterations easily exceeds 150K
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

    // MARK: - Properties

    var runConfig = RunConfig()
    /// Stores the default maxIterations to restore after skill overrides.
    let defaultMaxIterations: Int = RunConfig().maxIterations

    /// Step state machine: plan tracking, stuck detection, outcome validation.
    var stepMachine = StepStateMachine()

    /// Run lifecycle manager: cancellation, timing, budget warnings, run ID generation.
    var lifecycle = RunLifecycleManager()

    /// Verification engine for scoring post-action state (Sprint 4).
    let verificationEngine = VerificationEngine()

    /// Circuit breaker for API calls. Opens after consecutive failures to prevent
    /// hammering a failing API. Auto-recovers after cooldown. (Sprint 14)
    let apiCircuitBreaker = CircuitBreaker(failureThreshold: 3, cooldownInterval: 30)

    /// Sprint 18: Skill context matched for the current run.
    var currentSkillContext: String = ""

    /// Intent classifier — determines what kind of command this is.
    let intentClassifier = IntentClassifier()

    /// Memory service for persistent vault-backed memory across runs.
    let memoryService = MemoryService.shared

    /// Sprint 7 Refactoring: Track last run for user correction detection.
    /// If the previous run failed and the new command is similar, the user
    /// is likely correcting the approach.
    var lastRunCommand: String?
    var lastRunSuccess: Bool = true

    // MARK: - Start Run

    /// Start a new supervised run for a user command.
    /// This is the main entry point -- called by CommandGateway or AgentCoordinator.
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
        let runId = lifecycle.generateRunId()
        let journal = RunJournal(runId: runId)
        let completionToken = lifecycle.generateCompletionToken()

        // Reset extracted managers for the new run
        ScreenCaptureToolHandler.resetRunState()
        lifecycle.startTracking(runId: runId, command: command)
        stepMachine.resetForNewRun()
        stepMachine.stuckThreshold = runConfig.stuckThreshold

        // Sprint 14: Reset circuit breaker for fresh run
        await apiCircuitBreaker.reset()

        // Reset maxIterations to default before applying skill overrides
        runConfig.maxIterations = defaultMaxIterations

        // Match skills and build context for the system prompt
        let matchedSkills = await SkillRegistry.shared.matchSkills(for: command)
        currentSkillContext = await SkillRegistry.shared.buildSkillContext(for: matchedSkills)

        // Apply max iterations override from matched skill if lower
        if let skillMaxIter = matchedSkills.first?.manifest.maxIterations, skillMaxIter > 0, skillMaxIter < runConfig.maxIterations {
            runConfig.maxIterations = skillMaxIter
        }

        // Sprint 18: Inject skill context into the agent loop
        if !currentSkillContext.isEmpty {
            await agentLoop.setSkillContext(currentSkillContext)
        } else {
            await agentLoop.setSkillContext("")
        }

        // Sprint 7 Refactoring: Clear task-scoped memory from previous run
        await memoryService.clearCurrentRunContext()

        // Sprint 7 Refactoring: Detect user corrections — if last run failed
        // and this command targets the same app/action, record the correction.
        await detectAndRecordUserCorrection(newCommand: command)

        // Load memory context from the Obsidian vault and inject into agent loop
        let coreContext = await memoryService.loadCoreContext()
        let relevantMemories = await memoryService.retrieveRelevantMemories(for: command)
        let recentHistory = await memoryService.loadRecentRunSummaries(limit: 5)
        let memoryContext = await memoryService.buildContextString(
            core: coreContext, relevant: relevantMemories, history: recentHistory
        )
        // Load procedural memory (known step sequences + traps for this app/task)
        let proceduralContext = await ProceduralMemoryService.shared.retrieveAndFormatForPrompt(command: command)
        await ProceduralMemoryService.shared.setRunContext(app: nil, taskType: nil)
        let fullMemoryContext = proceduralContext.isEmpty ? memoryContext : memoryContext + "\n\n## Procedures\n" + proceduralContext
        await agentLoop.setMemoryContext(fullMemoryContext)
        NSLog("CyclopOne [Orchestrator]: Memory context loaded — %d chars (procedural: %d chars)", fullMemoryContext.count, proceduralContext.count)

        // Self-authoring -- record command and check for repeated patterns
        if let suggestion = await SkillRegistry.shared.recordCommand(command) {
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
            lifecycle.endRun()
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
            lifecycle.endRun()
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
            lifecycle.endRun()
            return RunResult(
                runId: runId, success: true, summary: "Asked for clarification",
                iterations: 0, finalScore: 100,
                totalInputTokens: 0, totalOutputTokens: 0
            )

        case .task(let description, let complexity, let confidence):
            NSLog("CyclopOne [Orchestrator]: Task intent (desc=%@, complexity=%@, confidence=%.2f)",
                  description, complexity.rawValue, confidence)

            // REACTIVE LOOP: feature flag bypass
            if UserDefaults.standard.bool(forKey: "useReactiveLoop") {
                NSLog("CyclopOne [Orchestrator]: Using ReactiveLoopActor (vision-first mode)")
                let reactiveLoop = ReactiveLoopActor()
                let reactiveTask = Task<ReactiveRunResult, Never> {
                    await reactiveLoop.run(
                        goal: command,
                        targetPID: targetPID,
                        onStateChange: onStateChange,
                        onMessage: onMessage,
                        onConfirmationNeeded: onConfirmationNeeded
                    )
                }
                lifecycle.hardCancelAction = { reactiveTask.cancel() }
                let reactiveResult = await reactiveTask.value
                lifecycle.hardCancelAction = nil
                // Record completion
                updateClassifierContext(command: command, result: reactiveResult.toOrchestratorRunResult())
                lifecycle.endRun()
                return reactiveResult.toOrchestratorRunResult()
            }

            // Only consult brain for moderate/complex tasks
            let plan: ExecutionPlan
            if complexity == .simple {
                plan = ExecutionPlan(command: command, steps: [], summary: "")
            } else {
                let brainModel = AgentConfig().brainModel
                let planResult = await consultBrainForPlan(
                    command: command, model: brainModel,
                    complexity: complexity, memoryContext: memoryContext
                )
                // If the planner needs clarification, surface question and stop
                if case .clarify(let question) = planResult {
                    onMessage(ChatMessage(role: .assistant, content: question))
                    if let rc = replyChannel { await rc.sendText(question) }
                    lifecycle.endRun()
                    return RunResult(
                        runId: runId, success: true, summary: "Asked for clarification",
                        iterations: 0, finalScore: 100,
                        totalInputTokens: 0, totalOutputTokens: 0
                    )
                }
                if case .plan(let p) = planResult { plan = p } else {
                    plan = ExecutionPlan(command: command, steps: [], summary: "")
                }
            }

            // Store plan for step tracking
            stepMachine.currentPlan = plan
            stepMachine.currentStepIndex = 0
            stepMachine.currentStepIterations = 0
            stepMachine.stepOutcomes.removeAll()

            if !plan.isEmpty {
                let planText = formatPlanForUser(plan)
                if let rc = replyChannel {
                    await rc.sendText(planText)
                }
                onMessage(ChatMessage(role: .system, content: planText))
                NSLog("CyclopOne [Orchestrator]: Brain plan injected (%d steps, estimated %d iterations)",
                      plan.steps.count, plan.estimatedTotalIterations)
            } else {
                NSLog("CyclopOne [Orchestrator]: Empty plan -- falling back to single-instruction mode")
                await agentLoop.setCurrentStepInstruction(command)
            }
        }

        // Execution continues for .task case only
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
            lifecycle.endRun()
            return RunResult(
                runId: runId, success: false,
                summary: "Journal open failed: \(error.localizedDescription)",
                iterations: 0, finalScore: nil,
                totalInputTokens: 0, totalOutputTokens: 0
            )
        }

        await journal.append(.created(command: command, source: source))

        // Prepare the run (initial screenshot, build first message)
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
        stepMachine.preActionScreenshot = initialScreenshot

        // Main iteration loop
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

    // MARK: - Hard Cancel

    /// Two-phase cancellation:
    /// 1. Set cooperative flags (existing behavior, immediate)
    /// 2. Cancel the Swift Task (propagates through every await)
    /// 3. Start watchdog timer for force-termination
    func cancelCurrentRun() {
        guard lifecycle.requestCancellation() else { return }

        // Start watchdog: if the iteration does not stop within cancelTimeout,
        // force-terminate the run
        lifecycle.cancelWatchdog?.cancel()
        lifecycle.cancelWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(5.0 * 1_000_000_000))
            guard let self = self else { return }
            let stillRunning = await self.isRunning
            if stillRunning {
                NSLog("CyclopOne [Orchestrator]: WATCHDOG FIRED -- force-terminating run after 5s")
                await self.performForceTerminate()
            }
        }
    }

    /// Actor-isolated helper so the watchdog Task can mutate `lifecycle`.
    private func performForceTerminate() {
        lifecycle.forceTerminateRun()
    }

    // MARK: - Status

    /// Returns a snapshot of the current orchestrator state for status reporting.
    func getStatus() -> OrchestratorStatus {
        lifecycle.getStatus()
    }

    // MARK: - State

    var isRunning: Bool { lifecycle.isRunning }
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
