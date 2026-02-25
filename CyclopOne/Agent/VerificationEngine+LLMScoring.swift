import Foundation

// MARK: - LLM-Based Verification

extension VerificationEngine {

    // MARK: - LLM Verification

    /// Perform LLM-based verification by sending the post-action screenshot to
    /// Claude Haiku and parsing the returned score/reason JSON.
    ///
    /// Throws on network errors, rate limits, or other API failures so the
    /// caller can fall back to heuristic scoring.
    func llmVerify(
        command: String,
        textContent: String,
        postScreenshot: ScreenCapture,
        preScreenshot: ScreenCapture?,
        toolResults: [ToolCallSummary],
        threshold: Int
    ) async throws -> VerificationScore {

        let toolErrors = toolResults.filter { $0.isError }
        let totalToolCalls = toolResults.count

        NSLog("CyclopOne [Verification]: LLM verify starting — promptLen=%d, screenshotSize=%d bytes, mediaType=%@, threshold=%d, toolErrors=%d/%d",
              command.count, postScreenshot.imageData.count,
              postScreenshot.mediaType, threshold, toolErrors.count, totalToolCalls)

        let prompt = buildVerificationPrompt(
            command: command,
            toolErrors: toolErrors,
            totalToolCalls: totalToolCalls
        )

        let response = try await ClaudeAPIService.shared.verifyWithVision(
            prompt: prompt,
            screenshot: postScreenshot.imageData,
            mediaType: postScreenshot.mediaType
        )

        NSLog("CyclopOne [Verification]: LLM raw response (%d chars): %@",
              response.count, String(response.prefix(300)))

        // Parse JSON response from the LLM
        var (score, reason) = parseVerificationResponse(response)

        // Apply tool error penalty if any tools failed
        (score, reason) = applyToolErrorPenalty(score: score, reason: reason, toolErrors: toolErrors)

        NSLog("CyclopOne [Verification]: LLM score=%d, reason=%@", score, reason)

        return VerificationScore(
            overall: score,
            visualScore: score, structuralScore: score, outputScore: score,
            breakdown: [
                "method": "llm_vision",
                "raw_response": String(response.prefix(500)),
                "threshold": "\(threshold)",
                "command": command,
                "tool_errors": "\(toolErrors.count)/\(totalToolCalls)"
            ],
            passed: score >= threshold,
            reason: reason
        )
    }

    // MARK: - Prompt Building

    /// Build the verification prompt sent to the LLM, including tool error context.
    ///
    /// Pure function — no side effects, no async calls.
    func buildVerificationPrompt(
        command: String,
        toolErrors: [ToolCallSummary],
        totalToolCalls: Int
    ) -> String {

        var toolErrorContext = ""
        if !toolErrors.isEmpty {
            let errorDetails = toolErrors.prefix(5).map {
                "- \($0.toolName): \($0.resultText.prefix(200))"
            }.joined(separator: "\n")
            toolErrorContext = """

            IMPORTANT: \(toolErrors.count) of \(totalToolCalls) tool calls returned errors:
            \(errorDetails)
            Factor these tool errors into your score. A task cannot be "complete" if critical tools failed.
            """
        }

        return """
        You are a verification agent. The user asked: "\(command)"

        Look at the current screenshot and assess:
        1. Has the requested action been completed?
        2. Is the screen in the expected state?
        \(toolErrorContext)

        Score 0-100 where:
        - 100 = fully complete, screen shows expected result
        - 80+ = mostly complete, minor issues
        - 40-79 = partial progress, needs more work
        - 0-39 = no progress or wrong state

        Respond with ONLY a JSON object:
        {"score": N, "reason": "brief explanation"}
        """
    }

    // MARK: - Tool Error Penalty

    /// Apply a score penalty for tool errors, even when the screenshot looks fine.
    ///
    /// Penalty: `-toolErrorPenaltyPerError` per errored tool call,
    /// capped so the score never falls below `toolErrorMinScore`.
    func applyToolErrorPenalty(
        score: Int,
        reason: String,
        toolErrors: [ToolCallSummary]
    ) -> (score: Int, reason: String) {

        guard !toolErrors.isEmpty else { return (score, reason) }

        let penaltyPerError = toolErrorPenaltyPerError
        let minScore = toolErrorMinScore
        let penalty = max(0, min(toolErrors.count * penaltyPerError, score - minScore))
        let adjustedScore = max(minScore, score - penalty)

        NSLog("CyclopOne [Verification]: Tool error penalty applied — original=%d, penalty=%d, adjusted=%d (errors=%d)",
              score, penalty, adjustedScore, toolErrors.count)

        let adjustedReason = reason + " [tool error penalty: -\(penalty) for \(toolErrors.count) error(s)]"
        return (adjustedScore, adjustedReason)
    }

    // MARK: - LLM Response Parsing

    /// Parse the JSON response from the verification LLM call.
    /// Expected format: {"score": N, "reason": "..."}
    /// Returns (score, reason) with safe defaults if parsing fails.
    func parseVerificationResponse(_ response: String) -> (Int, String) {
        // Try to extract JSON from the response (LLM may wrap it in markdown)
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Find JSON object boundaries
        guard let jsonStart = trimmed.firstIndex(of: "{"),
              let jsonEnd = trimmed.lastIndex(of: "}") else {
            NSLog("CyclopOne [Verification]: No JSON found in response: %@", String(trimmed.prefix(200)))
            return (neutralScore, "Could not parse verification response")
        }

        let jsonString = String(trimmed[jsonStart...jsonEnd])

        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            NSLog("CyclopOne [Verification]: Invalid JSON: %@", jsonString)
            return (neutralScore, "Could not parse verification JSON")
        }

        let score: Int
        if let s = json["score"] as? Int {
            score = min(100, max(0, s))
        } else if let s = json["score"] as? Double {
            score = min(100, max(0, Int(s.rounded())))
        } else {
            score = neutralScore
        }

        let reason = json["reason"] as? String ?? "No reason provided"

        return (score, reason)
    }
}
