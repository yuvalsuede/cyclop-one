import Foundation

/// Represents a single message in the chat conversation.
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

/// Claude API message format
struct APIMessage: Codable {
    let role: String
    let content: [ContentBlock]
}

/// Content block for Claude API
enum ContentBlock: Codable {
    case text(String)
    case image(String, String) // base64 data, media type
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)

    struct ToolUseBlock: Codable {
        let id: String
        let name: String
        let input: [String: AnyCodable]
    }

    struct ToolResultBlock: Codable {
        let type: String
        let tool_use_id: String
        let content: String
    }

    enum CodingKeys: String, CodingKey {
        case type, text, source, id, name, input, tool_use_id, content
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let data, let mediaType):
            try container.encode("image", forKey: .type)
            let source: [String: String] = [
                "type": "base64",
                "media_type": mediaType,
                "data": data
            ]
            try container.encode(source, forKey: .source)
        case .toolUse(let block):
            try container.encode("tool_use", forKey: .type)
            try container.encode(block.id, forKey: .id)
            try container.encode(block.name, forKey: .name)
            try container.encode(block.input, forKey: .input)
        case .toolResult(let block):
            try container.encode("tool_result", forKey: .type)
            try container.encode(block.tool_use_id, forKey: .tool_use_id)
            try container.encode(block.content, forKey: .content)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "tool_use":
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let input = try container.decode([String: AnyCodable].self, forKey: .input)
            self = .toolUse(ToolUseBlock(id: id, name: name, input: input))
        case "tool_result":
            let toolUseId = try container.decode(String.self, forKey: .tool_use_id)
            let content = try container.decode(String.self, forKey: .content)
            self = .toolResult(ToolResultBlock(type: "tool_result", tool_use_id: toolUseId, content: content))
        default:
            self = .text("")
        }
    }
}

/// Type-erased Codable wrapper for JSON values
struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let string = value as? String {
            try container.encode(string)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else if let array = value as? [Any] {
            try container.encode(array.map { AnyCodable($0) })
        } else if let dict = value as? [String: Any] {
            try container.encode(dict.mapValues { AnyCodable($0) })
        } else {
            try container.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // Simplified equality for basic types
        if let l = lhs.value as? String, let r = rhs.value as? String { return l == r }
        if let l = lhs.value as? Int, let r = rhs.value as? Int { return l == r }
        if let l = lhs.value as? Double, let r = rhs.value as? Double { return l == r }
        if let l = lhs.value as? Bool, let r = rhs.value as? Bool { return l == r }
        return false
    }
}
