import Foundation

// MARK: - Read-Only Snapshot

/// Immutable snapshot of GraphState for logging and debugging.
/// Extracted from GraphState.swift (Sprint 8) to keep file size manageable.
struct GraphStateSnapshot: Sendable {
    let runId: String
    let command: String
    let iteration: Int
    let taskComplete: Bool
    let completionSource: String
    let isStuck: Bool
    let stuckReason: String
    let hasToolCalls: Bool
    let hasError: Bool
    let errorMessage: String
    let isCancelled: Bool
    let verificationScore: Int
    let verificationPassed: Bool
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let recoveryAttempts: Int
    let rejectedCompletions: Int
}
