import Foundation

/// Conversation validation extensions for ConversationManager.
///
/// Sprint 6 refactor: Extracted from ConversationManager+Pruning.swift to keep
/// each file under 400 lines. Contains the single-pass validateBeforeSend()
/// method and the legacy repairAndValidateConversationHistory() redirect.
extension ConversationManager {

    // MARK: - Single-Pass Validation

    /// Validate and repair conversation history in a single forward pass.
    ///
    /// Sprint 6: Replaces the old triple-call pattern of removeOrphanedToolResults() +
    /// repairRoleAlternation() + repairAndValidateConversationHistory().
    ///
    /// This method:
    /// 1. Ensures first message is user role
    /// 2. Strips orphaned tool_use/tool_result content blocks (not entire messages)
    /// 3. Removes empty messages left after block stripping
    /// 4. Merges consecutive same-role user messages; bridges consecutive assistant messages
    /// 5. Ensures last message is user role
    /// 6. Runs exactly once -- no recursion, no repeat-until-stable loops
    ///
    /// The key improvement over the old approach: **filter individual content blocks
    /// instead of deleting entire messages**, and **merge same-role messages instead
    /// of deleting them**.
    ///
    /// - Returns: `true` if no changes were needed; `false` if repairs were applied.
    @discardableResult
    mutating func validateBeforeSend() -> Bool {
        var changed = false

        // 1. First message must be user role
        if let first = conversationHistory.first, first.role != .user {
            conversationHistory.insert(APIMessage.userText("[System: Begin task.]"), at: 0)
            changed = true
            NSLog("CyclopOne [ConversationManager]: validateBeforeSend -- prepended user message")
        }

        // 2. Strip orphaned tool_use / tool_result content blocks.
        //    Only strip the BLOCKS, not the entire messages.
        var allToolUseIDs = Set<String>()
        var allToolResultIDs = Set<String>()

        for message in conversationHistory {
            if message.role == .assistant {
                allToolUseIDs.formUnion(message.toolUseIDs)
            } else if message.role == .user {
                allToolResultIDs.formUnion(message.toolResultIDs)
            }
        }

        let orphanedToolUses = allToolUseIDs.subtracting(allToolResultIDs)
        let orphanedToolResults = allToolResultIDs.subtracting(allToolUseIDs)

        if !orphanedToolUses.isEmpty || !orphanedToolResults.isEmpty {
            if !orphanedToolUses.isEmpty {
                NSLog("CyclopOne [ConversationManager]: validateBeforeSend -- stripping %d orphaned tool_use blocks", orphanedToolUses.count)
            }
            if !orphanedToolResults.isEmpty {
                NSLog("CyclopOne [ConversationManager]: validateBeforeSend -- stripping %d orphaned tool_result blocks", orphanedToolResults.count)
            }

            for (idx, message) in conversationHistory.enumerated() {
                if message.role == .assistant && !orphanedToolUses.isEmpty {
                    let filtered = message.content.filter { block in
                        guard let id = block.toolUseId else { return true }
                        return !orphanedToolUses.contains(id)
                    }
                    if filtered.count != message.content.count {
                        if filtered.isEmpty {
                            conversationHistory[idx] = APIMessage.assistant(
                                [.text("[Previous tool calls removed -- results were lost during context management.]")]
                            )
                        } else {
                            conversationHistory[idx] = APIMessage(role: .assistant, content: filtered)
                        }
                        changed = true
                    }
                } else if message.role == .user && !orphanedToolResults.isEmpty {
                    let filtered = message.content.filter { block in
                        guard let toolUseId = block.toolResultToolUseId else { return true }
                        return !orphanedToolResults.contains(toolUseId)
                    }
                    if filtered.count != message.content.count {
                        if filtered.isEmpty {
                            conversationHistory[idx] = APIMessage.userText(
                                "[Previous tool results removed -- corresponding tool calls were lost during context management.]"
                            )
                        } else {
                            conversationHistory[idx] = APIMessage(role: .user, content: filtered)
                        }
                        changed = true
                    }
                }
            }
        }

        // 3. Remove empty messages (can happen after block stripping)
        let beforeCount = conversationHistory.count
        conversationHistory.removeAll { $0.content.isEmpty }
        if conversationHistory.count != beforeCount { changed = true }

        // 4. Fix consecutive same-role messages:
        //    - Consecutive user messages -> merge content blocks into one message
        //    - Consecutive assistant messages -> insert a synthetic user bridge between them
        var i = 1
        while i < conversationHistory.count {
            let prev = conversationHistory[i - 1]
            let curr = conversationHistory[i]

            if prev.role == curr.role {
                if prev.role == .user {
                    let merged = APIMessage(role: .user, content: prev.content + curr.content)
                    conversationHistory[i - 1] = merged
                    conversationHistory.remove(at: i)
                    changed = true
                    // Don't increment -- re-check from same position
                } else {
                    let bridge = APIMessage.userText("[System: Continue.]")
                    conversationHistory.insert(bridge, at: i)
                    changed = true
                    i += 2  // Skip past both the inserted bridge and the current assistant
                }
            } else {
                i += 1
            }
        }

        // 5. Ensure last message is user role
        if let last = conversationHistory.last, last.role != .user {
            conversationHistory.append(APIMessage.userText(
                "[System: Continue with the current task. Take the next action or output <task_complete/> when done.]"
            ))
            changed = true
            NSLog("CyclopOne [ConversationManager]: validateBeforeSend -- appended trailing user message")
        }

        if changed {
            NSLog("CyclopOne [ConversationManager]: validateBeforeSend -- repairs applied, history now %d messages", conversationHistory.count)
        }

        return !changed
    }

    // MARK: - Legacy Compatibility

    /// Sprint 6: Redirects to validateBeforeSend(). Kept for callers that haven't been updated.
    @discardableResult
    mutating func repairAndValidateConversationHistory() -> Bool {
        return validateBeforeSend()
    }
}
