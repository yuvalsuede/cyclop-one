import Foundation

/// Compression extensions for ConversationManager.
///
/// Sprint 6 refactor: Extracted from ConversationManager+Pruning.swift to keep
/// each file under 400 lines. Contains old-message compression (strip images,
/// truncate verbose text/AX trees) and payload-budget summarization.
///
/// Related files:
/// - ConversationManager+Pruning.swift: Cycle eviction, screenshot pruning, tool-result compression
/// - ConversationManager+Validation.swift: validateBeforeSend(), legacy redirect
/// - ConversationManager+Injection.swift: Message injection methods
extension ConversationManager {

    // MARK: - Old Message Compression

    /// Compress verbose content in old messages to reduce payload size.
    ///
    /// For messages older than the most recent 10 (but not message[0]):
    /// - Strip base64 image data (replace with placeholder text)
    /// - Truncate tool_result text blocks longer than 500 chars
    /// - Truncate AX tree content (lines matching "[AX" or "Target App:") to first 30 lines
    mutating func compressOldMessages() {
        let preserveRecentCount = 10
        guard conversationHistory.count > preserveRecentCount + 1 else { return }

        let compressEnd = conversationHistory.count - preserveRecentCount
        var compressedCount = 0

        for idx in 1..<compressEnd {
            let original = conversationHistory[idx]
            let compressed = compressMessageBlocks(original)
            if compressed.content.count != original.content.count ||
               zip(original.content, compressed.content).contains(where: { !blocksMatch($0, $1) }) {
                conversationHistory[idx] = compressed
                compressedCount += 1
            }
        }

        if compressedCount > 0 {
            NSLog("CyclopOne [ConversationManager]: compressOldMessages -- compressed %d messages (indices 1..<%d)",
                  compressedCount, compressEnd)
        }
    }

    /// Returns a compressed copy of an APIMessage.
    private func compressMessageBlocks(_ message: APIMessage) -> APIMessage {
        let compressedBlocks: [ContentBlock] = message.content.map { block in
            switch block {
            case .image:
                return .text("[image removed -- see recent screenshots]")
            case .text(let text):
                return .text(truncateAXTree(text))
            case .toolUse:
                return block
            case .toolResult(let id, let content, let isError):
                return .toolResult(toolUseId: id, content: truncateAXTree(truncateLong(content)), isError: isError)
            case .toolResultRich(let id, let innerBlocks, let isError):
                let inner: [ContentBlock] = innerBlocks.map { b in
                    switch b {
                    case .image: return .text("[image removed]")
                    case .text(let t): return .text(truncateAXTree(truncateLong(t)))
                    default: return b
                    }
                }
                return .toolResultRich(toolUseId: id, contentBlocks: inner, isError: isError)
            }
        }
        return APIMessage(role: message.role, content: compressedBlocks)
    }

    private func truncateLong(_ content: String) -> String {
        guard content.count > 500 else { return content }
        return String(content.prefix(500)) + "... [truncated]"
    }

    private func truncateAXTree(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let axCount = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[AX") ||
                                      $0.trimmingCharacters(in: .whitespaces).hasPrefix("Target App:") }.count
        guard axCount >= 10 && lines.count > 30 else { return text }
        return lines.prefix(30).joined(separator: "\n") + "\n... [\(lines.count - 30) more AX tree lines truncated]"
    }

    private func blocksMatch(_ a: ContentBlock, _ b: ContentBlock) -> Bool {
        switch (a, b) {
        case (.text(let tA), .text(let tB)): return tA == tB
        case (.image, .image): return true
        case (.toolUse(let idA, _, _), .toolUse(let idB, _, _)): return idA == idB
        case (.toolResult(let idA, let cA, _), .toolResult(let idB, let cB, _)): return idA == idB && cA == cB
        case (.toolResultRich(let idA, _, _), .toolResultRich(let idB, _, _)): return idA == idB
        default: return false
        }
    }

    // MARK: - Payload Budget Summarization

    /// Summarize old conversation messages when payload exceeds budget.
    ///
    /// When payload exceeds 100KB: keep message[0] and last 10 messages verbatim,
    /// condense everything in between into a single summary message.
    mutating func summarizeIfOverBudget() {
        let budget = 100_000
        let payloadSize = conversationPayloadSize()
        guard payloadSize > budget else { return }

        let preserveRecentCount = 10
        guard conversationHistory.count > preserveRecentCount + 2 else { return }

        let summarizeEnd = conversationHistory.count - preserveRecentCount
        guard summarizeEnd > 1 else { return }

        var parts: [String] = []
        for idx in 1..<summarizeEnd {
            let msg = conversationHistory[idx]
            let label = msg.role == .user ? "User" : "Assistant"
            for block in msg.content {
                switch block {
                case .text(let t):
                    let snippet = String(t.prefix(100))
                    if !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        parts.append("[\(label)] \(snippet)")
                    }
                case .toolUse(_, let name, _):
                    parts.append("[Tool call: \(name)]")
                case .toolResult(_, let c, let e):
                    let first = c.components(separatedBy: "\n").first ?? ""
                    parts.append("[Tool result\(e ? " (error)" : ""): \(String(first.prefix(80)))]")
                case .toolResultRich(_, let blocks, let e):
                    for b in blocks {
                        if case .text(let t) = b {
                            let first = t.components(separatedBy: "\n").first ?? ""
                            parts.append("[Tool result\(e ? " (error)" : ""): \(String(first.prefix(80)))]")
                            break
                        }
                    }
                case .image:
                    parts.append("[Screenshot]")
                }
            }
        }

        let count = summarizeEnd - 1
        let summary = APIMessage.userText(
            "[Conversation summary -- \(count) older messages condensed]\n\n\(parts.joined(separator: "\n"))"
        )
        let bridge = APIMessage.assistant([.text("[Acknowledged -- older context summarized.]")])

        conversationHistory.removeSubrange(1..<summarizeEnd)
        conversationHistory.insert(summary, at: 1)
        conversationHistory.insert(bridge, at: 2)

        NSLog("CyclopOne [ConversationManager]: summarizeIfOverBudget -- condensed %d messages, payload %d -> %d bytes",
              count, payloadSize, conversationPayloadSize())
    }
}
