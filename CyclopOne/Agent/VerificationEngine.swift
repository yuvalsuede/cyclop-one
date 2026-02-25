import Foundation
import AppKit

/// Result of a verification pass.
struct VerificationScore: Sendable {
    /// Overall composite score (0-100).
    let overall: Int
    /// Visual diff score (heuristic fallback only).
    let visualScore: Int
    /// Structural score (heuristic fallback only).
    let structuralScore: Int
    /// Output score (heuristic fallback only).
    let outputScore: Int
    /// Detailed breakdown for journal/debugging.
    let breakdown: [String: String]
    /// Whether the overall score meets the passing threshold.
    let passed: Bool
    /// Human-readable reason from the LLM verifier (empty for heuristic fallback).
    let reason: String

    /// Default passing threshold.
    static let defaultThreshold = 50
}

/// Verification engine that scores post-action state using LLM vision analysis.
///
/// Primary verification sends the post-action screenshot to Claude Haiku for
/// visual assessment of task completion. Falls back to heuristic scoring
/// (pixel diff, accessibility tree, keyword matching) when the LLM call fails.
actor VerificationEngine {

    // MARK: - Thresholds

    /// Centralised scoring constants — replaces magic numbers throughout the engine.
    private enum Thresholds {
        static let successScore = 70
        static let failureScore = 30
        static let neutralScore = 50
        static let toolErrorPenaltyPerError = 20
        static let toolErrorMinScore = 5
        static let heavyErrorRatio: Double = 0.5
        static let outputScoreHeavyPenalty = 15
        static let outputScoreModPenalty = 30
    }

    // MARK: - Internal Threshold Accessors (for extensions)

    var successScore: Int { Thresholds.successScore }
    var failureScore: Int { Thresholds.failureScore }
    var neutralScore: Int { Thresholds.neutralScore }
    var toolErrorPenaltyPerError: Int { Thresholds.toolErrorPenaltyPerError }
    var toolErrorMinScore: Int { Thresholds.toolErrorMinScore }
    var heavyErrorRatio: Double { Thresholds.heavyErrorRatio }
    var outputScoreHeavyPenalty: Int { Thresholds.outputScoreHeavyPenalty }
    var outputScoreModPenalty: Int { Thresholds.outputScoreModPenalty }

    // MARK: - Configuration

    /// Weights for composite scoring in heuristic fallback (must sum to 1.0).
    struct Weights {
        let visual: Double
        let structural: Double
        let output: Double

        init(visual: Double = 0.30, structural: Double = 0.30, output: Double = 0.40) {
            self.visual = visual
            self.structural = structural
            self.output = output
        }
    }

    private let weights = Weights()
    private let accessibility = AccessibilityService.shared

    /// Internal accessor for weights (used by heuristic extension).
    var heuristicWeights: Weights { weights }

    /// Internal accessor for accessibility service (used by heuristic extension).
    var accessibilityService: AccessibilityService { accessibility }

    /// Token usage from the most recent verification call (for cost tracking).
    private(set) var lastVerificationInputTokens: Int = 0
    private(set) var lastVerificationOutputTokens: Int = 0

    // MARK: - Success / Failure Indicators (for heuristic fallback)

    private let successIndicators: [String] = [
        "completed", "done", "created", "saved", "success",
        "opened", "launched", "navigated", "typed", "clicked",
        "pressed", "scrolled", "dragged", "moved", "installed",
        "downloaded", "uploaded", "sent", "finished", "applied",
        "updated", "modified", "set", "configured", "enabled",
        "disabled", "connected", "resolved", "found", "loaded",
        "copied", "pasted", "deleted", "removed", "closed",
        "ok", "200", "exit code 0"
    ]

    private let failureIndicators: [String] = [
        "error", "failed", "not found", "couldn't", "cannot",
        "unable", "denied", "permission", "timeout", "timed out",
        "crash", "exception", "invalid", "missing", "refused",
        "rejected", "unauthorized", "forbidden", "404", "500",
        "502", "503", "aborted", "cancelled", "no such file",
        "does not exist", "exit code 1", "exit code 2",
        "fatal", "panic", "segfault", "killed"
    ]

    /// Internal accessor for success indicators (used by heuristic extension).
    var successIndicatorList: [String] { successIndicators }

    /// Internal accessor for failure indicators (used by heuristic extension).
    var failureIndicatorList: [String] { failureIndicators }

    // MARK: - Public Interface

    /// Verify the result of an agent iteration using LLM vision scoring.
    ///
    /// Sends the post-action screenshot to Claude Haiku with a verification prompt.
    /// The LLM returns a JSON score and reason. Falls back to heuristic scoring
    /// if the LLM call fails (network error, rate limit, parse error).
    ///
    /// - Parameters:
    ///   - command: The original user command being executed.
    ///   - textContent: Text output from Claude's response / tool results in this iteration.
    ///   - postScreenshot: Screenshot captured after the action (may be nil).
    ///   - preScreenshot: Screenshot captured before the action (may be nil).
    ///   - toolResults: Summaries of tool calls executed in this iteration, including error status.
    ///   - threshold: Minimum overall score to pass (default 60).
    /// - Returns: A `VerificationScore` with score and reason.
    func verify(
        command: String,
        textContent: String,
        postScreenshot: ScreenCapture?,
        preScreenshot: ScreenCapture?,
        toolResults: [ToolCallSummary] = [],
        threshold: Int = VerificationScore.defaultThreshold
    ) async -> VerificationScore {

        // If no screenshot available, return neutral score
        guard let postScreenshot = postScreenshot, postScreenshot.imageData.count > 0 else {
            NSLog("CyclopOne [Verification]: No post-screenshot, returning neutral score")
            return VerificationScore(
                overall: Thresholds.neutralScore,
                visualScore: Thresholds.neutralScore,
                structuralScore: Thresholds.neutralScore,
                outputScore: Thresholds.neutralScore,
                breakdown: ["method": "no_screenshot", "command": command],
                passed: Thresholds.neutralScore >= threshold,
                reason: "No screenshot available for verification"
            )
        }

        do {
            return try await llmVerify(
                command: command,
                textContent: textContent,
                postScreenshot: postScreenshot,
                preScreenshot: preScreenshot,
                toolResults: toolResults,
                threshold: threshold
            )
        } catch {
            NSLog("CyclopOne [Verification]: LLM call failed (%@), falling back to heuristic scoring. Error domain=%@",
                  error.localizedDescription, (error as NSError).domain)
            return await fallbackVerify(
                command: command,
                textContent: textContent,
                postScreenshot: postScreenshot,
                preScreenshot: preScreenshot,
                toolResults: toolResults,
                threshold: threshold
            )
        }
    }
}
