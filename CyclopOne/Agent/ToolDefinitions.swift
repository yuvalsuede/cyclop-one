import Foundation

// MARK: - ToolSchema

/// A structured representation of a single tool definition for the Claude API.
///
/// Each tool has a name, description, and JSON-compatible input schema.
/// Use `toDict` to produce the `[String: Any]` dictionary expected by the API.
struct ToolSchema {
    let name: String
    let description: String
    let inputSchema: [String: Any]

    /// Convert to the dictionary format expected by the Claude API.
    var toDict: [String: Any] {
        return [
            "name": name,
            "description": description,
            "input_schema": inputSchema
        ]
    }
}

// MARK: - ToolDefinitions

/// Defines all tools available to Claude for OS interaction.
///
/// The struct is split across multiple files via extensions:
/// - `ToolDefinitions.swift` — struct definition, ToolSchema, safety sets, registry
/// - `ToolDefinitions+SystemPrompt.swift` — system prompt sections and builders
/// - `ToolDefinitions+InputSchemas.swift` — CGEvent input + system action schemas
/// - `ToolDefinitions+DataSchemas.swift` — vault, task, memory, OpenClaw schemas
struct ToolDefinitions {

    // MARK: - Tool Safety Sets

    /// Tools that are always safe to execute without any approval or logging.
    static let alwaysSafeToolNames: Set<String> = [
        "take_screenshot", "read_screen",
        "vault_read", "vault_search", "vault_list",
        "task_list",
        "recall",
        "openclaw_check",
        "move_mouse", "scroll"
    ]

    /// Tools that perform low-risk mutations (internal data only, no OS side-effects).
    /// Logged at moderate level but auto-approved.
    static let lowRiskMutationToolNames: Set<String> = [
        "vault_write", "vault_append",
        "task_create", "task_update", "task_complete",
        "remember"
    ]

    // MARK: - Tool Schemas (Combined)

    /// All tool definitions as structured `ToolSchema` instances.
    /// Assembled from sub-arrays defined in extension files.
    static let allSchemas: [ToolSchema] =
        inputSchemas + actionSchemas +
        vaultSchemas + taskSchemas + memorySchemas + openclawSchemas

    // MARK: - Tool Registry

    /// Set of all recognized tool names — schema-defined tools plus virtual/signal tools
    /// that may appear in conversation but have no formal API schema.
    static let allToolNames: Set<String> = {
        var names = Set(allSchemas.map { $0.name })
        // Virtual tools: handled in switch default/special cases, not formal API tools
        names.insert("task_complete")  // XML signal in prompt, handled by AgentLoop
        names.insert("read_screen")    // Alias for take_screenshot in some contexts
        return names
    }()

    /// All tool definitions for the Claude API.
    /// Computed from `allSchemas` to ensure a single source of truth.
    static var tools: [[String: Any]] {
        allSchemas.map { $0.toDict }
    }
}
