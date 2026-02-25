import Foundation

// MARK: - Graph State
// Shared mutable state bag passed between graph nodes.
// Sprint 3: Foundation — Sprint 4 wires this into Orchestrator.

/// Thread-safe shared state for a single agent run.
/// All graph nodes read from and write to this state.
actor GraphState {

    // MARK: - Run Context (set once at start)

    let runId: String
    let command: String
    let completionToken: String
    let source: String

    // MARK: - Iteration Tracking

    /// Current iteration number (incremented by GraphRunner or Orchestrator).
    var iteration: Int = 0

    /// Maximum iterations before forced termination.
    var maxIterations: Int = 50

    /// Timestamp when the run started.
    let runStartTime: Date = Date()

    // MARK: - Memory State (Sprint 7 Refactoring)

    /// Memory context loaded from the Obsidian vault.
    /// Loaded at run start, refreshed every 10 iterations to keep
    /// long-running tasks from losing earlier context.
    var memoryContext: String = ""

    /// Last iteration at which memory context was refreshed.
    var lastMemoryRefreshIteration: Int = 0

    // MARK: - Perception State (written by PERCEIVE, read by PLAN/ACT)

    /// Most recent screenshot before the current action.
    var preActionScreenshot: ScreenCapture?

    /// Most recent screenshot after the current action.
    var postActionScreenshot: ScreenCapture?

    /// Accessibility tree summary of the current screen.
    var uiTreeSummary: String = ""

    // MARK: - Planning State (written by PLAN, read by ACT)

    /// Claude's response from the current iteration.
    var claudeResponse: ClaudeResponse?

    /// Whether Claude returned tool calls (wants to continue working).
    var hasToolCalls: Bool = false

    /// Text content from Claude's response (non-tool-use blocks).
    var textContent: String = ""

    /// Whether the agent has more work to do (tool calls pending).
    /// Used to skip stuck detection when the agent is actively executing tools.
    var hasMoreWork: Bool = false

    // MARK: - Action State (written by ACT, read by OBSERVE/EVALUATE)

    /// The type of the last executed action, used by PerceiveNode to decide
    /// whether a screenshot is needed. One of: "click", "type", "keyboard",
    /// "scroll", "navigate", "launch", "screenshot", "unknown", or "" (initial).
    var _lastActionType: String = ""

    /// The raw name of the last executed tool (e.g. "type_text", "key_press", "click").
    /// Sprint 8: Used by PerceiveNode for fine-grained adaptive capture decisions.
    var _lastToolName: String = ""

    /// Number of consecutive screenshot captures without an intervening tool action.
    /// Incremented by PerceiveNode when a screenshot is taken, reset by ActNode
    /// when a tool executes. Sprint 8: Prevents redundant captures (threshold: 2).
    var _consecutiveScreenshotsWithoutAction: Int = 0

    /// Whether the current iteration's screenshot was skipped due to adaptive capture.
    var adaptiveSkippedScreenshot: Bool = false

    /// Brief description of visual changes between pre and post screenshots.
    /// Written by ObserveNode when it detects significant visual changes.
    var visualDiffDescription: String = ""

    /// Sprint 8: Whether pre and post action screenshots are perceptually identical.
    /// Set by ObserveNode using perceptual hash comparison. When true, downstream
    /// EVALUATE can weigh this as a signal that no visual progress was made.
    var screenshotsIdentical: Bool = false

    /// Sprint 8: Whether AX-first verification succeeded (post-action screenshot skipped).
    /// Set by ObserveNode when AX tree confirms the expected state change.
    var axVerificationSucceeded: Bool = false

    /// Summary of tool calls executed this iteration.
    var toolCallSummaries: [ToolCallSummary] = []

    /// Whether any visual tool calls were executed (click, type, screenshot).
    var hasVisualToolCalls: Bool = false

    /// Whether any tool calls were executed across the entire run.
    var anyToolCallsExecuted: Bool = false

    /// Whether any tool calls succeeded across the entire run.
    var anyToolCallsSucceeded: Bool = false

    /// Number of failed tool calls in the current iteration.
    var failedToolCount: Int = 0

    /// Whether any visual tool calls were executed across the entire run.
    var anyVisualToolCallsExecuted: Bool = false

    // MARK: - Evaluation State (written by EVALUATE, read by edge conditions)

    /// Whether the task is detected as complete.
    var taskComplete: Bool = false

    /// Source of completion signal ("token match", "Claude indicated done", etc.).
    var completionSource: String = ""

    /// Whether the agent appears stuck (repeated screenshots/text).
    var isStuck: Bool = false

    /// Reason for stuck detection (e.g. "5 identical screenshots").
    var stuckReason: String = ""

    /// Whether the brain model has been consulted for this stuck episode.
    var hasEscalatedToBrain: Bool = false

    // MARK: - Verification State (written by COMPLETE)

    /// Final verification score (0-100).
    var verificationScore: Int = 0

    /// Whether verification passed the threshold.
    var verificationPassed: Bool = false

    /// Verification reason/explanation.
    var verificationReason: String = ""

    /// Number of times completion was rejected by verification.
    var rejectedCompletions: Int = 0

    /// Maximum rejections before force-completing.
    let maxRejectedCompletions: Int = 2

    // MARK: - Token Tracking

    /// Cumulative input tokens across all iterations.
    var totalInputTokens: Int = 0

    /// Cumulative output tokens across all iterations.
    var totalOutputTokens: Int = 0

    /// Verification-specific token usage.
    var verificationInputTokens: Int = 0
    var verificationOutputTokens: Int = 0

    // MARK: - Error State

    /// Whether an unrecoverable error occurred.
    var hasError: Bool = false

    /// Error message if hasError is true.
    var errorMessage: String = ""

    /// Whether the run was cancelled by the user.
    var isCancelled: Bool = false

    // MARK: - Recovery State (written by RECOVER)

    /// Number of recovery attempts in the current stuck episode.
    var recoveryAttempts: Int = 0

    /// Total recovery attempts across all stuck episodes in this run.
    var totalRecoveryAttempts: Int = 0

    /// Maximum recovery attempts per stuck episode before escalating to COMPLETE.
    /// Sprint 9: Increased from 3 to 5 to accommodate all RecoveryStrategy tiers.
    let maxRecoveryAttempts: Int = 5

    /// Maximum total recovery attempts across the entire run.
    /// Sprint 9: Increased from 5 to 8 to allow more recovery across episodes.
    let maxTotalRecoveryAttempts: Int = 8

    /// Current recovery strategy tier within a stuck episode (0-4).
    /// Incremented each time RECOVER fires. Determines which strategy to try:
    /// 0=rephrase, 1=haiku, 2=backtrack, 3=brain (Opus), 4=force complete.
    /// Sprint 9: Strategy chain for graduated recovery.
    var _recoveryStrategyIndex: Int = 0

    /// Classification of the last error encountered (written by EVALUATE).
    /// Used by RecoverNode to select the appropriate recovery strategy.
    /// Sprint 9: Error classification integration.
    var _lastErrorClass: String = "none"

    /// Whether a screenshot was available in the last PERCEIVE pass.
    /// When false, PlanNode should note "Screenshot unavailable — rely on AX tree".
    /// Sprint 9: Graceful degradation on screenshot failure.
    var _screenshotAvailable: Bool = true

    // MARK: - Initialization

    init(
        runId: String,
        command: String,
        completionToken: String,
        source: String = "chat",
        maxIterations: Int = 50
    ) {
        self.runId = runId
        self.command = command
        self.completionToken = completionToken
        self.source = source
        self.maxIterations = maxIterations
    }

    // MARK: - Convenience Mutators

    /// Record token usage from a single iteration.
    func addTokens(input: Int, output: Int) {
        totalInputTokens += input
        totalOutputTokens += output
    }

    /// Mark the run as stuck with a reason.
    func markStuck(reason: String) {
        isStuck = true
        stuckReason = reason
    }

    /// Clear stuck state (after recovery attempt).
    func clearStuck() {
        isStuck = false
        stuckReason = ""
    }

    /// Mark the run as complete with a source description.
    func markComplete(source: String) {
        taskComplete = true
        completionSource = source
    }

    /// Mark the run as cancelled.
    func markCancelled() {
        isCancelled = true
    }

    /// Mark an error condition.
    func markError(_ message: String) {
        hasError = true
        errorMessage = message
    }

    /// Reset per-iteration transient state before each iteration.
    func resetForNewIteration() {
        claudeResponse = nil
        hasToolCalls = false
        hasMoreWork = false
        textContent = ""
        toolCallSummaries = []
        hasVisualToolCalls = false
        failedToolCount = 0
        postActionScreenshot = nil
        uiTreeSummary = ""
        // Sprint 8: Reset adaptive perception state
        adaptiveSkippedScreenshot = false
        visualDiffDescription = ""
        screenshotsIdentical = false
        axVerificationSucceeded = false
        // Note: lastActionType, lastToolName, and consecutiveScreenshotsWithoutAction
        // are NOT reset — they carry over from the previous iteration so PerceiveNode
        // can decide whether to skip the screenshot
    }

    /// Increment iteration counter and return new value.
    @discardableResult
    func incrementIteration() -> Int {
        iteration += 1
        return iteration
    }

}
// Property setters, recovery strategies, error classification, and snapshot
// are defined in GraphState+Setters.swift
