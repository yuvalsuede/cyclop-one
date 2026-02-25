import Foundation

/// Manages run lifecycle state: cancellation, timing, budget warnings, and run ID generation.
///
/// This is a plain **struct** owned by the Orchestrator actor (no actor boundary of its own).
/// All state-modifying methods use `mutating func`.
///
/// **Safety note on Task references:** This struct holds `Task` references
/// (`currentIterationTask`, `cancelWatchdog`). This is safe because:
/// 1. The struct is only ever stored as a `private var` on the `Orchestrator` actor.
/// 2. It is never copied or shared outside the actor boundary.
/// 3. All mutations happen on the actor's serial executor, so there are no races.
/// If this struct were ever used outside an actor, the Task references would
/// need to be managed through an actor or a class with proper synchronization.
///
/// Extracted from Orchestrator.swift in Sprint 3 to separate run lifecycle concerns
/// from step-level logic and planning/brain consultation.
struct RunLifecycleManager {

    // MARK: - Run Identity

    /// The current run's unique identifier (nil when idle).
    var currentRunId: String?

    // MARK: - Cancellation State

    /// Whether a cancellation has been requested for the current run.
    var isCancellationRequested: Bool = false

    /// Whether a hard cancel is in progress (prevents re-entrant cancel calls).
    var isHardCancelInProgress: Bool = false

    /// Maximum time to wait for cooperative cancellation before force-terminating.
    let cancelTimeout: TimeInterval = 5.0

    /// Reference to the currently executing iteration Task.
    /// Stored so cancelCurrentRun() can call task.cancel() for immediate
    /// cooperative cancellation propagation through every await point.
    var currentIterationTask: Task<IterationResult, Error>?

    /// Watchdog task that force-terminates the run if the iteration
    /// does not respond to cancellation within the timeout.
    var cancelWatchdog: Task<Void, Never>?

    /// Optional closure called during cancellation to cancel the outer graph runner Task.
    /// Set by runFlatLoopViaGraph / runStepDrivenLoop before entering the run loop.
    var hardCancelAction: (@Sendable () -> Void)?

    // MARK: - Run Tracking (Sprint 11)

    /// The command text for the current run (for status reporting).
    var currentCommand: String?

    /// The iteration count of the current run.
    var currentIteration: Int = 0

    /// The start time of the current run.
    var runStartTime: Date?

    /// Description of the last action executed in the current run.
    var lastActionDescription: String?

    // MARK: - Budget Warnings

    /// Whether the 80% budget warning has been sent for the current run (Sprint 14).
    var budgetWarningSent: Bool = false

    /// Whether the early iteration warning has been sent for the current run.
    var earlyWarningSent: Bool = false

    // MARK: - Run State Queries

    /// Whether a run is currently active.
    var isRunning: Bool { currentRunId != nil }

    // MARK: - Run ID & Token Generation

    /// Generate a unique run ID based on timestamp and UUID fragment.
    func generateRunId() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let ts = formatter.string(from: Date())
        let suffix = String(UUID().uuidString.prefix(8).lowercased())
        return "\(ts)_\(suffix)"
    }

    /// Generate a random completion token (hex string).
    func generateCompletionToken() -> String {
        (0..<16).map { _ in String(format: "%x", Int.random(in: 0...15)) }.joined()
    }

    // MARK: - Run Tracking

    /// Reset all run tracking and lifecycle state. Called at the start and end of each run.
    /// This is the single point of truth for resetting all per-run state, including
    /// budget/early warnings, cancellation flags, and tracking metadata.
    mutating func resetRunTracking() {
        currentCommand = nil
        currentIteration = 0
        runStartTime = nil
        lastActionDescription = nil
        isCancellationRequested = false
        budgetWarningSent = false
        earlyWarningSent = false
    }

    /// Initialize tracking for a new run.
    mutating func startTracking(runId: String, command: String) {
        currentRunId = runId
        resetRunTracking()
        currentCommand = command
        runStartTime = Date()
    }

    /// Clear the current run ID (run is finished).
    mutating func endRun() {
        currentRunId = nil
    }

    // MARK: - Cancellation

    /// Initiate a two-phase cancellation:
    /// 1. Set cooperative flags (existing behavior, immediate)
    /// 2. Cancel the Swift Task (propagates through every await)
    ///
    /// Returns false if no run is active or hard cancel is already in progress.
    @discardableResult
    mutating func requestCancellation() -> Bool {
        guard currentRunId != nil else { return false }
        guard !isHardCancelInProgress else {
            NSLog("CyclopOne [RunLifecycleManager]: Hard cancel already in progress, ignoring duplicate")
            return false
        }

        isHardCancelInProgress = true
        isCancellationRequested = true

        // Cancel the per-iteration Task (step-driven loop path)
        if let task = currentIterationTask {
            task.cancel()
            NSLog("CyclopOne [RunLifecycleManager]: Hard cancel -- iteration Task cancelled")
        } else {
            NSLog("CyclopOne [RunLifecycleManager]: Hard cancel -- no active iteration Task")
        }

        // Cancel the outer graph runner Task (flat/graph loop path)
        if let action = hardCancelAction {
            action()
            NSLog("CyclopOne [RunLifecycleManager]: Hard cancel -- graph runner Task cancelled")
        }

        return true
    }

    /// Force-terminate the current run. Nuclear option invoked by the watchdog.
    mutating func forceTerminateRun() {
        currentIterationTask?.cancel()
        currentIterationTask = nil
        hardCancelAction?()
        hardCancelAction = nil
        cancelWatchdog?.cancel()
        cancelWatchdog = nil
        isHardCancelInProgress = false
        resetRunTracking()
        currentRunId = nil
        NSLog("CyclopOne [RunLifecycleManager]: Run force-terminated")
    }

    /// Clean up cancel infrastructure after a run completes normally.
    mutating func cleanupCancelState() {
        currentIterationTask = nil
        hardCancelAction = nil
        cancelWatchdog?.cancel()
        cancelWatchdog = nil
        isHardCancelInProgress = false
    }

    // MARK: - Status

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

    // MARK: - Budget & Timing Checks

    /// Check if the early iteration warning should be sent.
    /// Returns the warning message if it should be sent, nil otherwise.
    mutating func checkEarlyWarning(iteration: Int, maxIterations: Int, earlyWarningIteration: Int) -> String? {
        guard iteration >= earlyWarningIteration && !earlyWarningSent else { return nil }
        earlyWarningSent = true
        let remaining = maxIterations - iteration
        return "You've used \(iteration) of \(maxIterations) iterations. Focus on completing the task now or declare it impossible. You have \(remaining) iterations left."
    }

    /// Check if the budget warning should be sent.
    /// Returns the warning message if it should be sent, nil otherwise.
    mutating func checkBudgetWarning(iteration: Int, maxIterations: Int, budgetWarningPercent: Double) -> String? {
        let budgetThreshold = Int(Double(maxIterations) * budgetWarningPercent)
        guard iteration >= budgetThreshold && !budgetWarningSent else { return nil }
        budgetWarningSent = true
        let remaining = maxIterations - iteration
        return "Budget warning: \(remaining) iterations remaining out of \(maxIterations) max."
    }

    /// Check if the run has exceeded its maximum duration.
    /// Returns a reason string if timed out, nil otherwise.
    func checkRunTimeout(maxRunDuration: TimeInterval) -> String? {
        guard let startTime = runStartTime else { return nil }
        if Date().timeIntervalSince(startTime) > maxRunDuration {
            return "Run exceeded max duration (\(Int(maxRunDuration))s)"
        }
        return nil
    }
}
