import Foundation

/// Retry strategies for different failure types in the agent loop.
///
/// - `none`: No retry. Fail immediately.
/// - `fixed`: Retry with a constant delay between attempts.
/// - `exponentialBackoff`: Retry with exponentially increasing delay, capped at `maxDelay`.
/// - `adaptive`: Adjusts strategy based on error classification.
enum RetryStrategy: Sendable {
    case none
    case fixed(delay: TimeInterval, maxAttempts: Int)
    case exponentialBackoff(base: TimeInterval, maxDelay: TimeInterval, maxAttempts: Int)
    case adaptive

    /// Calculate the delay before the next attempt, or nil if max attempts exhausted.
    ///
    /// - Parameter attempt: The current attempt number (0-based: 0 = first retry).
    /// - Returns: Delay in seconds before the next attempt, or nil to stop retrying.
    func nextDelay(attempt: Int) -> TimeInterval? {
        switch self {
        case .none:
            return nil

        case .fixed(let delay, let maxAttempts):
            guard attempt < maxAttempts else { return nil }
            return delay

        case .exponentialBackoff(let base, let maxDelay, let maxAttempts):
            guard attempt < maxAttempts else { return nil }
            let delay = base * pow(2.0, Double(attempt))
            return min(delay, maxDelay)

        case .adaptive:
            // Adaptive uses exponential backoff with sensible defaults.
            // Callers should use `strategyForError` to get a more specific strategy.
            let maxAttempts = 3
            guard attempt < maxAttempts else { return nil }
            let delay = 1.0 * pow(2.0, Double(attempt))
            return min(delay, 30.0)
        }
    }

    /// Maximum number of retry attempts for this strategy.
    var maxAttempts: Int {
        switch self {
        case .none: return 0
        case .fixed(_, let max): return max
        case .exponentialBackoff(_, _, let max): return max
        case .adaptive: return 3
        }
    }
}

/// Context passed to retry logic with information about the current attempt.
struct RetryContext: Sendable {
    /// Current attempt number (0-based).
    let attempt: Int

    /// Description of the last error, if any.
    let lastError: String?

    /// The retry strategy being used.
    let strategy: RetryStrategy
}

// MARK: - Error Classification

/// Classification of errors to determine retry strategy.
enum ErrorClassification: Sendable {
    /// Transient error that is likely to resolve on retry (network blip, 500, 503).
    case transient

    /// Rate limit hit. Should backoff using retry-after or exponential backoff.
    case rateLimit(retryAfter: TimeInterval?)

    /// Permanent error that will not resolve on retry (400, 401, 403, invalid input).
    case permanent

    /// Unknown error type. Use conservative retry.
    case unknown
}

/// Classify an API error to determine the appropriate retry strategy.
///
/// - Parameter error: The error thrown by the API call.
/// - Returns: Classification of the error for retry decisions.
func classifyError(_ error: Error) -> ErrorClassification {
    if let apiError = error as? APIError {
        switch apiError {
        case .noAPIKey:
            return .permanent
        case .invalidResponse:
            return .transient
        case .httpError(let statusCode, let body):
            switch statusCode {
            case 429:
                // Try to parse retry-after from the body or use default
                let retryAfter = parseRetryAfter(from: body)
                return .rateLimit(retryAfter: retryAfter)
            case 400:
                // Parse the error body to distinguish credit/billing errors from
                // truly permanent 400 errors (invalid request).
                if let data = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorObj = json["error"] as? [String: Any] {
                    let errorType = errorObj["type"] as? String ?? ""
                    let errorMessage = (errorObj["message"] as? String ?? "").lowercased()

                    // Check error type directly
                    if errorType == "insufficient_credits" || errorType == "billing_error" {
                        return .permanent  // No point retrying — credits won't auto-refill
                    }
                    // Check message content for credit/billing keywords
                    // (Anthropic sometimes sends these as invalid_request_error)
                    if errorMessage.contains("credit balance") ||
                       errorMessage.contains("billing") ||
                       errorMessage.contains("insufficient credits") ||
                       errorMessage.contains("purchase credits") {
                        return .permanent  // Credit exhaustion — permanent until user tops up
                    }
                }
                return .permanent
            case 401, 403, 404:
                return .permanent
            case 500, 502, 503, 529:
                return .transient
            default:
                return .unknown
            }
        case .parseError:
            return .permanent
        }
    }

    // URLSession errors (network timeouts, connection refused, etc.)
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        switch nsError.code {
        case NSURLErrorTimedOut,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet:
            return .transient
        default:
            return .unknown
        }
    }

    return .unknown
}

/// Determine the retry strategy for a given error classification.
///
/// - Parameter classification: The error classification.
/// - Returns: Appropriate retry strategy.
func retryStrategyFor(_ classification: ErrorClassification) -> RetryStrategy {
    switch classification {
    case .transient:
        return .exponentialBackoff(base: 1.0, maxDelay: 15.0, maxAttempts: 3)
    case .rateLimit(let retryAfter):
        let delay = retryAfter ?? 5.0
        return .fixed(delay: delay, maxAttempts: 3)
    case .permanent:
        return .none
    case .unknown:
        return .exponentialBackoff(base: 2.0, maxDelay: 30.0, maxAttempts: 2)
    }
}

// MARK: - Helpers

/// Attempt to parse a retry-after value from an API error body.
/// Looks for common patterns like `"retry_after": 5` or `retry-after` headers in the body.
private func parseRetryAfter(from body: String) -> TimeInterval? {
    // Try JSON-style: "retry_after": N or "retry-after": N
    let patterns = [
        "\"retry_after\"\\s*:\\s*(\\d+\\.?\\d*)",
        "\"retry-after\"\\s*:\\s*(\\d+\\.?\\d*)"
    ]

    for pattern in patterns {
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
           let range = Range(match.range(at: 1), in: body),
           let value = Double(body[range]) {
            return value
        }
    }

    return nil
}
