import Foundation

// MARK: - SkillPackageManifest

/// Unified manifest describing a skill package — used for both built-in skills
/// and user/marketplace packages.
struct SkillPackageManifest: Codable, Sendable {
    let name: String
    let version: String
    let description: String
    let author: String?
    /// Regex patterns that trigger this skill.
    let triggers: [String]
    /// Ordered procedural steps injected into the agent's system prompt.
    let steps: [String]
    /// Optional tool definitions for external executables.
    let tools: [SkillToolDef]?
    /// Required permission strings (e.g. "network", "filesystem").
    let permissions: [String]?
    /// Max iterations override for this skill (nil = use global default).
    let maxIterations: Int?
    /// Marketplace metadata (nil for built-in / user skills).
    let marketplace: SkillMarketplaceInfo?
}

// MARK: - SkillToolDef

/// Definition of an external tool executable provided by a skill package.
/// Uses @unchecked Sendable because inputSchema is [String: Any] containing
/// only JSON-serializable value types (strings, numbers, arrays, dicts).
struct SkillToolDef: @unchecked Sendable {
    let name: String
    let description: String
    /// Relative path to the executable within the skill package directory.
    let entrypoint: String
    /// JSON Schema for the tool's input (must have "type": "object").
    let inputSchema: [String: Any]?
}

extension SkillToolDef: Codable {
    enum CodingKeys: String, CodingKey {
        case name, description, entrypoint, inputSchema
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        entrypoint = try container.decode(String.self, forKey: .entrypoint)
        // inputSchema is freeform JSON — decode as Any via JSONDecoder workaround
        inputSchema = nil // populated separately when loading from JSON
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(entrypoint, forKey: .entrypoint)
        // inputSchema encoding skipped (freeform JSON)
    }
}

// MARK: - SkillMarketplaceInfo

struct SkillMarketplaceInfo: Codable, Sendable {
    let category: String
    let tags: [String]
    let verified: Bool
    let rating: Double?
}

// MARK: - SkillSource

/// Where a skill package originated from.
enum SkillSource: Sendable {
    /// Hardcoded in the app binary.
    case builtIn
    /// Installed by the user under ~/.cyclopone/skills/ (legacy .md or package dir).
    case user(directoryURL: URL)
    /// Downloaded from the marketplace.
    case marketplace(directoryURL: URL)
}

// MARK: - SkillPackage

/// A fully loaded skill package ready for matching and context injection.
struct SkillPackage: Sendable {
    let manifest: SkillPackageManifest
    let source: SkillSource
    var isEnabled: Bool = true
    /// Whether execution of this skill's tools requires user approval.
    var requiresApproval: Bool = false
    /// The file path this skill was loaded from (nil for built-in).
    var filePath: String?

    // MARK: - Convenience accessors

    var name: String { manifest.name }
    var description: String { manifest.description }
    var triggers: [String] { manifest.triggers }
    var steps: [String] { manifest.steps }
    var maxIterations: Int? { manifest.maxIterations }

    var isBuiltIn: Bool {
        if case .builtIn = source { return true }
        return false
    }

}

// MARK: - SuggestedSkill (previously in SkillLoader.swift)

struct SuggestedSkill: Sendable {
    let name: String
    let description: String
    let triggers: [String]
    let steps: [String]
    let permissions: [String: String]
    let maxIterations: Int
    let exampleCommands: [String]
}
