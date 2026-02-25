import Foundation

/// Message injection extensions for ConversationManager.
///
/// Sprint 6 refactor: Extracted from ConversationManager.swift to keep each
/// file under 400 lines. Contains all methods that inject synthetic messages
/// into the conversation history (brain guidance, verification feedback,
/// iteration warnings, step transitions).
extension ConversationManager {

    // MARK: - Brain Guidance

    /// Sanitize brain guidance by removing lines that contain instruction-override patterns.
    /// Returns the cleaned guidance string with dangerous lines stripped.
    func sanitizeBrainGuidance(_ guidance: String) -> String {
        let dangerousPatterns: [String] = [
            "ignore",
            "bypass",
            "override",
            "execute",
            "delete all",
            "disable safety",
            "you are now",
            "forget your",
            "forget all",
            "new instructions",
            "disregard",
            "pretend you",
            "act as if",
            "sudo",
            "rm -rf",
            "drop table",
            "ignore previous",
            "ignore above",
            "system prompt",
        ]

        let lines = guidance.components(separatedBy: .newlines)
        var cleanLines: [String] = []
        var strippedCount = 0

        for line in lines {
            let lowerLine = line.lowercased().trimmingCharacters(in: .whitespaces)

            if lowerLine.isEmpty {
                cleanLines.append(line)
                continue
            }

            let isDangerous = dangerousPatterns.contains { pattern in
                lowerLine.contains(pattern)
            }

            if isDangerous {
                strippedCount += 1
                NSLog("CyclopOne [ConversationManager]: SANITIZED -- Stripped dangerous line from brain guidance: '%@'",
                      String(line.prefix(120)))
            } else {
                cleanLines.append(line)
            }
        }

        if strippedCount > 0 {
            NSLog("CyclopOne [ConversationManager]: Brain guidance sanitization stripped %d of %d lines",
                  strippedCount, lines.count)
        }

        return cleanLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pending brain guidance to be prepended to the next system prompt.
    /// Using system prompt injection avoids breaking conversation role alternation
    /// (which caused orphaned tool_use blocks and context loss).
    /// Stored as a mutable property on the struct — consumed by buildIterationSystemPrompt().

    /// Inject strategic guidance from the brain model.
    /// Instead of appending as a user message (which breaks role alternation
    /// and creates orphaned tool_use/tool_result blocks), stores the guidance
    /// to be prepended to the next system prompt via consumePendingBrainGuidance().
    mutating func injectBrainGuidance(_ guidance: String) {
        let sanitized = sanitizeBrainGuidance(guidance)

        if sanitized.isEmpty {
            NSLog("CyclopOne [ConversationManager]: WARNING -- Brain guidance REJECTED entirely after sanitization (original %d chars)", guidance.count)
            return
        }

        pendingBrainGuidance = "[STRATEGIC GUIDANCE FROM SUPERVISOR]\n\nYou appear to be stuck repeating the same actions. Here is advice from a senior model on how to proceed:\n\n\(sanitized)\n\nTry a different approach based on this guidance."
        NSLog("CyclopOne [ConversationManager]: Stored brain guidance (%d chars) for next system prompt",
              sanitized.count)
    }

    /// Consume pending brain guidance (returns and clears it).
    /// Called by system prompt builder to prepend guidance to the next API call.
    mutating func consumePendingBrainGuidance() -> String? {
        let guidance = pendingBrainGuidance
        pendingBrainGuidance = nil
        return guidance
    }

    // MARK: - Verification Feedback

    /// Inject a verification rejection message into the conversation history.
    mutating func injectVerificationFeedback(_ feedback: String) {
        if let lastMessage = conversationHistory.last, lastMessage.role == .user {
            let bridgeMessage = APIMessage.assistant([.text("[Acknowledged \u{2014} processing verification feedback.]")])
            conversationHistory.append(bridgeMessage)
        }
        let message = APIMessage.userText(feedback)
        conversationHistory.append(message)
    }

    // MARK: - Iteration Warning

    /// Inject an iteration budget warning into the conversation history.
    mutating func injectIterationWarning(_ warning: String) {
        if let lastMessage = conversationHistory.last, lastMessage.role == .user {
            let bridgeMessage = APIMessage.assistant([.text("[Acknowledged \u{2014} processing iteration warning.]")])
            conversationHistory.append(bridgeMessage)
        }
        let message = APIMessage.userText("[ITERATION BUDGET WARNING]\n\n\(warning)")
        conversationHistory.append(message)
        NSLog("CyclopOne [ConversationManager]: Injected iteration warning into conversation")
    }

    // MARK: - Step Transition

    /// Inject a step transition message into the conversation history.
    mutating func injectStepTransitionMessage(stepIndex: Int, totalSteps: Int, stepTitle: String) {
        // Guard: skip injection if the last message is already a user message.
        if let lastRole = conversationHistory.last?.role, lastRole == .user {
            NSLog("CyclopOne [ConversationManager]: Skipping step transition injection -- last message is already user role (step %d of %d)", stepIndex + 1, totalSteps)
            return
        }

        let transitionText = "[Step transition: Moving to step \(stepIndex + 1) of \(totalSteps): \(stepTitle). Review the screen and proceed with this step.]"
        let message = APIMessage.userText(transitionText)
        conversationHistory.append(message)
        NSLog("CyclopOne [ConversationManager]: Injected step transition message -- step %d of %d: %@", stepIndex + 1, totalSteps, stepTitle)
    }

    // MARK: - Trailing Message Guard

    /// Ensure the conversation history ends with a user-role message.
    ///
    /// The Claude API requires that the last message in the conversation has
    /// role "user". When Claude returns `end_turn` with no tool calls, the
    /// assistant message is appended but no user message follows. If the
    /// Orchestrator then advances to the next step and calls `executeIteration()`
    /// again, the API rejects the payload with HTTP 400.
    ///
    /// This method checks the last message and, if it is role "assistant",
    /// appends a synthetic user message to satisfy the API contract.
    mutating func ensureConversationEndsWithUserMessage() {
        guard let lastMessage = conversationHistory.last, lastMessage.role == .assistant else {
            return
        }

        let syntheticMessage = APIMessage.userText(
            "[System: Continue with the current task. Take the next action or output <task_complete/> when done.]"
        )
        conversationHistory.append(syntheticMessage)
        NSLog("CyclopOne [ConversationManager]: ensureConversationEndsWithUserMessage -- appended synthetic user message (history was trailing assistant)")
    }
}
