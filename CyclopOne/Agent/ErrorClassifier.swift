import Foundation

// MARK: - Error Classification
// Classifies errors into categories to determine appropriate recovery strategy.
// Sprint 9: Refactoring — Structured recovery and error classification.

/// Classification of errors encountered during agent execution.
/// Used by EvaluateNode to annotate GraphState and by RecoverNode
/// to select the appropriate recovery strategy.
enum ErrorClass: String, Sendable, CaseIterable {
    /// Network timeout, API 429, screenshot failed — retry after brief delay.
    case transient = "transient"

    /// Invalid tool, permission denied, app crashed — skip or abort.
    case permanent = "permanent"

    /// Same screenshot 3x, no progress — enter recovery flow.
    case stuck = "stuck"

    /// Token limit, time limit, budget exceeded — warn then abort.
    case resource = "resource"

    /// No error detected.
    case none = "none"
}

// MARK: - Error Classifier

/// Stateless classifier that maps errors and tool error strings to ErrorClass.
///
/// Used by:
/// - EvaluateNode: classifies tool errors to annotate GraphState
/// - RecoverNode: reads classification to select recovery strategy
///
/// Sprint 9: Foundation. Patterns are intentionally broad to catch
/// variations in error messages from different services.
enum ErrorClassifier {

    // MARK: - Classify Swift Errors

    /// Classify a Swift Error into an ErrorClass.
    static func classify(_ error: Error) -> ErrorClass {
        let message = error.localizedDescription.lowercased()
        return classifyMessage(message)
    }

    // MARK: - Classify Tool Error Strings

    /// Classify a tool error result string into an ErrorClass.
    static func classify(toolError: String) -> ErrorClass {
        let message = toolError.lowercased()
        return classifyMessage(message)
    }

    // MARK: - Classify from Tool Call Summaries

    /// Classify errors from a batch of tool call summaries.
    /// Returns the most severe error class found (permanent > resource > stuck > transient).
    static func classify(summaries: [ToolCallSummary]) -> ErrorClass {
        var worst: ErrorClass = .none

        for summary in summaries where summary.isError {
            let cls = classify(toolError: summary.resultText)
            if cls.severity > worst.severity {
                worst = cls
            }
        }
        return worst
    }

    // MARK: - Private

    /// Core classification logic based on lowercased message content.
    private static func classifyMessage(_ message: String) -> ErrorClass {
        // Transient: retriable errors
        if matchesAny(message, patterns: transientPatterns) {
            return .transient
        }

        // Permanent: non-retriable errors
        if matchesAny(message, patterns: permanentPatterns) {
            return .permanent
        }

        // Stuck: progress-related errors
        if matchesAny(message, patterns: stuckPatterns) {
            return .stuck
        }

        // Resource: limit-related errors
        if matchesAny(message, patterns: resourcePatterns) {
            return .resource
        }

        // Default: treat unknown errors as transient (safer to retry)
        return .transient
    }

    private static func matchesAny(_ message: String, patterns: [String]) -> Bool {
        patterns.contains { message.contains($0) }
    }

    // MARK: - Pattern Lists

    private static let transientPatterns: [String] = [
        "rate limit",
        "429",
        "timeout",
        "timed out",
        "connection",
        "network",
        "temporarily unavailable",
        "service unavailable",
        "503",
        "502",
        "retry",
        "screenshot capture failed",
        "screenshot failed",
        "econnreset",
        "econnrefused",
    ]

    private static let permanentPatterns: [String] = [
        "not found",
        "permission denied",
        "invalid tool",
        "unknown tool",
        "invalid parameter",
        "crashed",
        "app not running",
        "accessibility not available",
        "403",
        "401",
        "unauthorized",
        "forbidden",
        "unsupported",
        "malformed",
    ]

    private static let stuckPatterns: [String] = [
        "stuck",
        "identical",
        "no progress",
        "repeating",
        "same state",
        "loop detected",
        "repeated action",
    ]

    private static let resourcePatterns: [String] = [
        "token limit",
        "token budget",
        "max iterations",
        "max tokens",
        "context length",
        "budget exceeded",
        "time limit",
        "quota",
        "payload too large",
        "413",
    ]
}

// MARK: - ErrorClass Severity

extension ErrorClass {
    /// Severity ranking for determining the "worst" error in a batch.
    /// Higher = more severe.
    var severity: Int {
        switch self {
        case .none:       return 0
        case .transient:  return 1
        case .stuck:      return 2
        case .resource:   return 3
        case .permanent:  return 4
        }
    }
}
