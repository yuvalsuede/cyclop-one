import Foundation

/// Pruning extensions for ConversationManager.
///
/// Sprint 6 refactor: Extracted from ConversationManager.swift to keep each
/// file under 400 lines. Contains cycle-based eviction, screenshot pruning,
/// and tool-result compression. The top-level pruneConversationHistory()
/// orchestrates all pruning steps.
///
/// Related files:
/// - ConversationManager+Compression.swift: Old-message compression, summarization
/// - ConversationManager+Validation.swift: validateBeforeSend(), legacy redirect
/// - ConversationManager+Injection.swift: Message injection methods
extension ConversationManager {

    // MARK: - Top-Level Pruning Entry Point

    /// Prune old messages and screenshots from conversation history to reduce API payload size.
    ///
    /// Flow:
    /// 1. Evict old cycles when message count exceeds `maxConversationMessages`
    /// 2. Compress verbose tool results in messages older than the last 4
    /// 3. Replace old screenshot base64 data with placeholder text
    /// 4. Compress old messages beyond the last 10 (strip images, truncate AX trees)
    mutating func pruneConversationHistory() {
        evictOldCycles()
        compressOldToolResults()
        pruneOldScreenshots()
        compressOldMessages()
    }

    // MARK: - Cycle Eviction

    /// Enforce max conversation message count by removing complete cycles from the
    /// oldest end. A cycle is an assistant+user pair (tool_use + tool_result) or a
    /// standalone message. Message[0] (initial user intent) is always preserved.
    private mutating func evictOldCycles() {
        guard conversationHistory.count > maxConversationMessages else { return }

        var cycleStartIndices: [Int] = []
        var cycleLengths: [Int] = []
        var i = 1  // Skip message[0]

        while i < conversationHistory.count {
            let message = conversationHistory[i]

            if message.role == .assistant {
                if message.hasToolUse {
                    if i + 1 < conversationHistory.count {
                        let nextMessage = conversationHistory[i + 1]
                        if nextMessage.role == .user {
                            cycleStartIndices.append(i)
                            cycleLengths.append(2)
                            i += 2
                            continue
                        }
                    }
                    cycleStartIndices.append(i)
                    cycleLengths.append(1)
                    i += 1
                } else {
                    cycleStartIndices.append(i)
                    cycleLengths.append(1)
                    i += 1
                }
            } else {
                cycleStartIndices.append(i)
                cycleLengths.append(1)
                i += 1
            }
        }

        let excess = conversationHistory.count - maxConversationMessages
        var messagesToEvict = 0
        var cyclesToEvict = 0

        for c in 0..<cycleStartIndices.count {
            if messagesToEvict >= excess { break }
            let remainingAfterEvict = conversationHistory.count - 1 - (messagesToEvict + cycleLengths[c])
            if remainingAfterEvict < maxConversationMessages / 2 { break }

            messagesToEvict += cycleLengths[c]
            cyclesToEvict += 1
        }

        if messagesToEvict > 0 && cyclesToEvict > 0 {
            let removeStart = cycleStartIndices[0]
            conversationHistory.removeSubrange(removeStart..<(removeStart + messagesToEvict))
            NSLog("CyclopOne [ConversationManager]: Evicted %d messages (%d complete cycles), history now %d messages",
                  messagesToEvict, cyclesToEvict, conversationHistory.count)
        }
    }

    // MARK: - Screenshot Pruning

    /// Replace old screenshot base64 data with placeholder text to reduce payload size.
    /// Only the most recent `screenshotPruneThreshold` screenshots are kept intact.
    private mutating func pruneOldScreenshots() {
        var imageMessageIndices: [Int] = []
        for (index, message) in conversationHistory.enumerated() {
            if message.containsImage {
                imageMessageIndices.append(index)
            }
        }

        let countToPreserve = screenshotPruneThreshold
        guard imageMessageIndices.count > countToPreserve else { return }

        let indicesToPrune = imageMessageIndices.dropLast(countToPreserve)
        var prunedBytes = 0

        for index in indicesToPrune {
            let (pruned, bytesRemoved) = conversationHistory[index].pruneImages()
            conversationHistory[index] = pruned
            prunedBytes += bytesRemoved
        }

        if prunedBytes > 0 {
            let prunedKB = prunedBytes / 1024
            NSLog("CyclopOne [ConversationManager]: Pruned %d old screenshots (~%dKB freed)",
                  indicesToPrune.count, prunedKB)
        }
    }

    // MARK: - Tool Result Compression

    /// Compress old tool results to reduce payload size.
    ///
    /// For messages older than the last 4, this truncates:
    /// - AX tree content (text starting with "Target App:") to first 2000 chars
    /// - Shell command results (text > 1000 chars) to last 500 chars
    /// - Leaves recent messages (last 4) untouched
    private mutating func compressOldToolResults() {
        let preserveCount = 4
        guard conversationHistory.count > preserveCount else { return }

        let cutoff = conversationHistory.count - preserveCount
        var totalCompressed = 0

        for i in 0..<cutoff {
            let message = conversationHistory[i]
            guard message.role == .user else { continue }

            var modified = false
            let compressedBlocks: [ContentBlock] = message.content.map { block in
                switch block {
                case .toolResult(let toolUseId, let content, let isError):
                    if let compressed = compressToolResultText(content) {
                        modified = true
                        return .toolResult(toolUseId: toolUseId, content: compressed, isError: isError)
                    }
                    return block

                case .toolResultRich(let toolUseId, let innerBlocks, let isError):
                    var innerModified = false
                    let compressedInner: [ContentBlock] = innerBlocks.map { inner in
                        if case .text(let text) = inner,
                           let compressed = compressToolResultText(text) {
                            innerModified = true
                            return .text(compressed)
                        }
                        return inner
                    }
                    if innerModified {
                        modified = true
                        return .toolResultRich(toolUseId: toolUseId, contentBlocks: compressedInner, isError: isError)
                    }
                    return block

                default:
                    return block
                }
            }

            if modified {
                conversationHistory[i] = APIMessage(role: message.role, content: compressedBlocks)
                totalCompressed += 1
            }
        }

        if totalCompressed > 0 {
            NSLog("CyclopOne [ConversationManager]: Compressed tool results in %d old messages", totalCompressed)
        }
    }

    /// Attempt to compress a single tool result text string.
    /// Returns the compressed string, or nil if no compression was needed.
    private func compressToolResultText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // AX tree content: starts with "Target App:"
        if trimmed.hasPrefix("Target App:") && trimmed.count > 2000 {
            return String(trimmed.prefix(2000)) + "\n[truncated]"
        }

        // Long shell/tool output (not AX tree): keep last 500 chars
        if trimmed.count > 1000 && !trimmed.hasPrefix("Target App:") {
            return "[truncated -- showing last 500 chars]\n" + String(trimmed.suffix(500))
        }

        return nil
    }

}
