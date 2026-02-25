import Foundation

/// Represents a single message in the chat conversation (UI layer).
struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date
    var isLoading: Bool

    enum Role: String, Equatable {
        case user
        case assistant
        case system
        case toolResult
    }

    init(role: Role, content: String, isLoading: Bool = false) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isLoading = isLoading
    }
}

// MARK: - Sprint 4: Typed API Messages

/// Role for Claude API messages.
enum MessageRole: String, Sendable {
    case user
    case assistant
}

/// A single content block within an API message.
///
/// `@unchecked Sendable` because `toolUse.input` is `[String: Any]`.
/// This is safe because inputs are never mutated after construction.
enum ContentBlock: @unchecked Sendable {
    /// Plain text content.
    case text(String)

    /// Base64-encoded image content.
    case image(mediaType: String, data: String)

    /// Tool use request from the assistant.
    case toolUse(id: String, name: String, input: [String: Any])

    /// Tool result returned to the assistant (simple text content).
    case toolResult(toolUseId: String, content: String, isError: Bool)

    /// Tool result with rich content (e.g., screenshot + text).
    case toolResultRich(toolUseId: String, contentBlocks: [ContentBlock], isError: Bool)

    /// Serialize to the Claude API dictionary format.
    func toDict() -> [String: Any] {
        switch self {
        case .text(let text):
            return ["type": "text", "text": text]

        case .image(let mediaType, let data):
            return [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType,
                    "data": data
                ] as [String: Any]
            ]

        case .toolUse(let id, let name, let input):
            return [
                "type": "tool_use",
                "id": id,
                "name": name,
                "input": input
            ]

        case .toolResult(let toolUseId, let content, let isError):
            return [
                "type": "tool_result",
                "tool_use_id": toolUseId,
                "content": content,
                "is_error": isError
            ]

        case .toolResultRich(let toolUseId, let contentBlocks, let isError):
            return [
                "type": "tool_result",
                "tool_use_id": toolUseId,
                "content": contentBlocks.map { $0.toDict() },
                "is_error": isError
            ]
        }
    }

    // MARK: - Inspection Helpers

    /// Returns the block type as a string for logging/debugging.
    var typeName: String {
        switch self {
        case .text: return "text"
        case .image: return "image"
        case .toolUse: return "tool_use"
        case .toolResult: return "tool_result"
        case .toolResultRich: return "tool_result"
        }
    }

    /// Returns the tool_use ID if this is a toolUse block, nil otherwise.
    var toolUseId: String? {
        if case .toolUse(let id, _, _) = self { return id }
        return nil
    }

    /// Returns the tool_use_id reference if this is a toolResult block, nil otherwise.
    var toolResultToolUseId: String? {
        switch self {
        case .toolResult(let id, _, _): return id
        case .toolResultRich(let id, _, _): return id
        default: return nil
        }
    }

    /// Returns true if this block is an image block.
    var isImage: Bool {
        if case .image = self { return true }
        return false
    }

    /// Returns true if this is a toolUse block.
    var isToolUse: Bool {
        if case .toolUse = self { return true }
        return false
    }

    /// Returns true if this is a toolResult or toolResultRich block.
    var isToolResult: Bool {
        switch self {
        case .toolResult, .toolResultRich: return true
        default: return false
        }
    }

    /// Sprint 6: Returns the text content of a simple toolResult, nil otherwise.
    var toolResultText: String? {
        if case .toolResult(_, let content, _) = self { return content }
        return nil
    }

    /// Sprint 6: Returns the isError flag of a toolResult, false for non-toolResult blocks.
    var toolResultIsError: Bool {
        switch self {
        case .toolResult(_, _, let isError): return isError
        case .toolResultRich(_, _, let isError): return isError
        default: return false
        }
    }

    /// Returns true if this block (or its nested blocks) contains an image.
    var containsImage: Bool {
        switch self {
        case .image:
            return true
        case .toolResultRich(_, let blocks, _):
            return blocks.contains { $0.isImage }
        default:
            return false
        }
    }

    /// Replace image data with a placeholder text block. Returns the pruned block
    /// and the number of bytes removed.
    func pruneImage() -> (ContentBlock, Int) {
        switch self {
        case .image(_, let data):
            return (.text("[screenshot removed]"), data.utf8.count)

        case .toolResultRich(let toolUseId, let blocks, let isError):
            var totalRemoved = 0
            let prunedBlocks: [ContentBlock] = blocks.map { block in
                if case .image(_, let data) = block {
                    totalRemoved += data.utf8.count
                    return .text("[screenshot removed]")
                }
                return block
            }
            return (.toolResultRich(toolUseId: toolUseId, contentBlocks: prunedBlocks, isError: isError), totalRemoved)

        default:
            return (self, 0)
        }
    }
}

/// A typed message for the Claude API, replacing untyped `[String: Any]` dictionaries.
///
/// `Sendable` because `ContentBlock` is `@unchecked Sendable`.
struct APIMessage: Sendable {
    let role: MessageRole
    var content: [ContentBlock]

    /// Serialize to the Claude API dictionary format.
    func toDict() -> [String: Any] {
        // For user messages containing tool_results, the API expects the
        // tool_result blocks as the top-level content array items.
        // For all other messages, each content block maps to a dict.
        return [
            "role": role.rawValue,
            "content": content.map { $0.toDict() }
        ]
    }

    // MARK: - Convenience Constructors

    /// Create a user-role message with the given content blocks.
    static func user(_ blocks: [ContentBlock]) -> APIMessage {
        return APIMessage(role: .user, content: blocks)
    }

    /// Create an assistant-role message with the given content blocks.
    static func assistant(_ blocks: [ContentBlock]) -> APIMessage {
        return APIMessage(role: .assistant, content: blocks)
    }

    /// Create a simple user-role text message.
    static func userText(_ text: String) -> APIMessage {
        return APIMessage(role: .user, content: [.text(text)])
    }

    /// Create a user message with text + optional screenshot + optional UI tree.
    static func userWithScreenshot(
        text: String,
        screenshot: ScreenCapture?,
        uiTreeSummary: String?
    ) -> APIMessage {
        var blocks: [ContentBlock] = []

        if let ss = screenshot {
            blocks.append(.image(mediaType: ss.mediaType, data: ss.base64))
        }

        if let uiTree = uiTreeSummary {
            blocks.append(.text("<ui_tree>\n\(uiTree)\n</ui_tree>"))
        }

        blocks.append(.text(text))

        return APIMessage(role: .user, content: blocks)
    }

    /// Create an assistant message from a ClaudeResponse.
    static func assistant(from response: ClaudeResponse) -> APIMessage {
        var blocks: [ContentBlock] = []
        for block in response.contentBlocks {
            switch block {
            case .text(let text):
                blocks.append(.text(text))
            case .toolUse(let id, let name, let input):
                blocks.append(.toolUse(id: id, name: name, input: input))
            }
        }
        return APIMessage(role: .assistant, content: blocks)
    }

    /// Create a user message containing a tool result (simple text).
    static func toolResult(
        toolUseId: String,
        result: String,
        isError: Bool = false,
        screenshot: ScreenCapture? = nil
    ) -> APIMessage {
        if let ss = screenshot {
            // Rich tool result with screenshot image + text
            let innerBlocks: [ContentBlock] = [
                .image(mediaType: ss.mediaType, data: ss.base64),
                .text(result)
            ]
            return APIMessage(role: .user, content: [
                .toolResultRich(toolUseId: toolUseId, contentBlocks: innerBlocks, isError: isError)
            ])
        }

        // Simple text tool result
        return APIMessage(role: .user, content: [
            .toolResult(toolUseId: toolUseId, content: result, isError: isError)
        ])
    }

    // MARK: - Inspection Helpers

    /// Returns true if any content block is a toolUse block.
    var hasToolUse: Bool {
        content.contains { $0.isToolUse }
    }

    /// Returns the set of tool_use IDs in this message.
    var toolUseIDs: Set<String> {
        Set(content.compactMap { $0.toolUseId })
    }

    /// Returns the set of tool_use_id references from tool_result blocks.
    var toolResultIDs: Set<String> {
        Set(content.compactMap { $0.toolResultToolUseId })
    }

    /// Returns true if any content block contains an image.
    var containsImage: Bool {
        content.contains { $0.containsImage }
    }

    /// Returns a comma-separated string of content block type names for logging.
    var contentTypeDescription: String {
        let types = Set(content.map { $0.typeName })
        return types.sorted().joined(separator: ", ")
    }

    /// Replace all image data in this message with placeholder text.
    /// Returns the modified message and total bytes removed.
    func pruneImages() -> (APIMessage, Int) {
        var totalRemoved = 0
        let prunedBlocks: [ContentBlock] = content.map { block in
            let (pruned, removed) = block.pruneImage()
            totalRemoved += removed
            return pruned
        }
        return (APIMessage(role: role, content: prunedBlocks), totalRemoved)
    }
}

// MARK: - Collection Helpers

extension Array where Element == APIMessage {
    /// Serialize the entire conversation to the Claude API format.
    func toDicts() -> [[String: Any]] {
        return map { $0.toDict() }
    }
}

