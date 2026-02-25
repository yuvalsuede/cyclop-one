import Foundation

// MARK: - GraphState Property Setters
// Extracted from GraphState.swift (Sprint 8) to keep file size manageable.
// All actor-isolated setters and computed properties for node access.

extension GraphState {

    // MARK: - Action Type Accessors

    /// The type of the last executed action (read by PERCEIVE to decide capture strategy).
    var lastActionType: String { _lastActionType }

    /// The raw tool name of the last executed tool.
    var lastToolName: String { _lastToolName }

    /// Consecutive screenshots without an intervening tool action.
    var consecutiveScreenshotsWithoutAction: Int { _consecutiveScreenshotsWithoutAction }

    /// Whether a screenshot was available in the last PERCEIVE pass.
    var screenshotAvailable: Bool { _screenshotAvailable }

    /// Set the last action type (written by ACT after tool execution).
    func setLastActionType(_ type: String) {
        _lastActionType = type
    }

    /// Set the last tool name (written by ACT after tool execution).
    func setLastToolName(_ name: String) {
        _lastToolName = name
    }

    /// Increment consecutive screenshots counter (written by PERCEIVE).
    func incrementConsecutiveScreenshots() {
        _consecutiveScreenshotsWithoutAction += 1
    }

    /// Reset consecutive screenshots counter (written by ACT when a tool executes).
    func resetConsecutiveScreenshots() {
        _consecutiveScreenshotsWithoutAction = 0
    }

    /// Set screenshot availability flag (written by PERCEIVE).
    func setScreenshotAvailable(_ available: Bool) {
        _screenshotAvailable = available
    }

    /// Set the visual diff description (written by OBSERVE).
    func setVisualDiffDescription(_ description: String) {
        visualDiffDescription = description
    }

    /// Set the adaptive skipped screenshot flag (written by PERCEIVE).
    func setAdaptiveSkippedScreenshot(_ skipped: Bool) {
        adaptiveSkippedScreenshot = skipped
    }

    /// Set whether pre/post screenshots are identical (written by OBSERVE).
    func setScreenshotsIdentical(_ identical: Bool) {
        screenshotsIdentical = identical
    }

    /// Set whether AX verification succeeded (written by OBSERVE).
    func setAXVerificationSucceeded(_ succeeded: Bool) {
        axVerificationSucceeded = succeeded
    }

    // MARK: - Memory Context

    /// Set memory context and record when it was last refreshed (written by PLAN).
    func setMemoryContext(_ context: String, atIteration iter: Int) {
        memoryContext = context
        lastMemoryRefreshIteration = iter
    }

    // MARK: - Screenshot Setters

    /// Set the pre-action screenshot (written by PERCEIVE/OBSERVE).
    func setPreActionScreenshot(_ screenshot: ScreenCapture?) {
        preActionScreenshot = screenshot
    }

    /// Set the post-action screenshot (written by OBSERVE).
    func setPostActionScreenshot(_ screenshot: ScreenCapture?) {
        postActionScreenshot = screenshot
    }

    /// Set the UI tree summary (written by PERCEIVE/OBSERVE).
    func setUITreeSummary(_ summary: String) {
        uiTreeSummary = summary
    }

    // MARK: - Response Setters

    /// Store Claude's API response (written by PLAN).
    func setClaudeResponse(_ response: ClaudeResponse?) {
        claudeResponse = response
        if let r = response {
            hasToolCalls = r.hasToolUse
            textContent = r.textContent
            hasMoreWork = r.hasToolUse
        } else {
            hasToolCalls = false
            textContent = ""
            hasMoreWork = false
        }
    }

    /// Store tool call results (written by ACT).
    func setToolCallResults(
        summaries: [ToolCallSummary],
        hasVisual: Bool
    ) {
        toolCallSummaries = summaries
        hasVisualToolCalls = hasVisual
        failedToolCount = summaries.filter { $0.isError }.count
        let succeededCount = summaries.count - failedToolCount
        if !summaries.isEmpty {
            anyToolCallsExecuted = true
        }
        if succeededCount > 0 {
            anyToolCallsSucceeded = true
        }
        if hasVisual {
            anyVisualToolCallsExecuted = true
        }
    }

    // MARK: - Verification Setters

    /// Store verification results (written by COMPLETE).
    func setVerificationResult(
        score: Int,
        passed: Bool,
        reason: String
    ) {
        verificationScore = score
        verificationPassed = passed
        verificationReason = reason
    }

    /// Add verification token usage.
    func addVerificationTokens(input: Int, output: Int) {
        verificationInputTokens += input
        verificationOutputTokens += output
    }

    /// Increment rejected completions and return whether max is exceeded.
    @discardableResult
    func incrementRejectedCompletions() -> Bool {
        rejectedCompletions += 1
        return rejectedCompletions >= maxRejectedCompletions
    }

    // MARK: - Recovery Setters

    /// Increment recovery attempts (both per-episode and global) and return current episode count.
    @discardableResult
    func incrementRecoveryAttempts() -> Int {
        recoveryAttempts += 1
        totalRecoveryAttempts += 1
        return recoveryAttempts
    }

    /// Set the brain escalation flag.
    func setEscalatedToBrain(_ value: Bool) {
        hasEscalatedToBrain = value
    }

    /// Clear completion state (after verification rejection).
    func clearCompletion() {
        taskComplete = false
        completionSource = ""
    }

    /// The current recovery strategy index.
    var recoveryStrategyIndex: Int { _recoveryStrategyIndex }

    /// Increment recovery strategy index and return new value.
    @discardableResult
    func incrementRecoveryStrategyIndex() -> Int {
        _recoveryStrategyIndex += 1
        return _recoveryStrategyIndex
    }

    /// Reset recovery strategy index (when starting a new stuck episode).
    func resetRecoveryStrategyIndex() {
        _recoveryStrategyIndex = 0
    }

    /// Alias for recoveryStrategyIndex (used by EvaluateNode/RecoverNode).
    var currentRecoveryStrategy: Int { _recoveryStrategyIndex }

    /// Alias for resetRecoveryStrategyIndex (used by EvaluateNode).
    func resetRecoveryStrategies() {
        _recoveryStrategyIndex = 0
        recoveryAttempts = 0
    }

    /// Alias for incrementRecoveryStrategyIndex (used by RecoverNode).
    @discardableResult
    func incrementRecoveryStrategy() -> Int {
        _recoveryStrategyIndex += 1
        return _recoveryStrategyIndex
    }

    // MARK: - Error Classification

    /// Get the last error class as an ErrorClass enum value.
    var lastErrorClass: ErrorClass {
        ErrorClass(rawValue: _lastErrorClass) ?? .none
    }

    /// Set the last error classification (written by EVALUATE).
    func setLastErrorClass(_ cls: ErrorClass) {
        _lastErrorClass = cls.rawValue
    }

    // MARK: - Snapshot

    /// Create a read-only snapshot for logging or edge evaluation.
    func snapshot() -> GraphStateSnapshot {
        GraphStateSnapshot(
            runId: runId,
            command: command,
            iteration: iteration,
            taskComplete: taskComplete,
            completionSource: completionSource,
            isStuck: isStuck,
            stuckReason: stuckReason,
            hasToolCalls: hasToolCalls,
            hasError: hasError,
            errorMessage: errorMessage,
            isCancelled: isCancelled,
            verificationScore: verificationScore,
            verificationPassed: verificationPassed,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            recoveryAttempts: recoveryAttempts,
            rejectedCompletions: rejectedCompletions
        )
    }
}
