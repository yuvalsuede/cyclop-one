import Foundation

/// Stateless per-screenshot decision loop state.
/// Each iteration is self-contained — no conversation history accumulates.
struct ReactiveAgentState {
    let goal: String
    let runId: String
    let startedAt: Date

    var iteration: Int = 0
    /// Rolling log of completed actions — max 10 lines, one line per completed action.
    var progressLines: [String] = []
    /// The most recently executed action (for anti-repetition detection).
    var lastAction: ReactiveLastAction? = nil
    /// How many consecutive API/tool failures have occurred without progress.
    var consecutiveFailures: Int = 0
    /// How many consecutive iterations have produced the same action fingerprint.
    var consecutiveSameActions: Int = 0
    /// Fingerprint of the last action used for repetition detection.
    var lastActionFingerprint: String = ""
    /// Rolling window of the last 8 action fingerprints for frequency-based stuck detection.
    /// Catches interleaved repetition like: click(x)→Tab→click(x)→Tab→click(x) where
    /// consecutive counter resets on each Tab but the click keeps repeating.
    var recentFingerprints: [String] = []

    // MARK: - Terminal State

    var isComplete: Bool = false
    var isFailed: Bool = false
    var completionReason: String = ""

    // MARK: - Token Accounting

    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0
}

/// Summary of the last executed action, stored for prompt injection.
struct ReactiveLastAction {
    let toolName: String
    let summary: String
    let succeeded: Bool
    let fingerprint: String
}
