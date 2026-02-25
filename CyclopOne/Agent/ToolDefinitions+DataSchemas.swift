import Foundation

// MARK: - ToolDefinitions + Data & Communication Schemas

extension ToolDefinitions {

    // MARK: Vault Management Schemas

    /// Tool schemas for vault operations: vault_read, vault_write,
    /// vault_append, vault_search, vault_list.
    static let vaultSchemas: [ToolSchema] = [

        ToolSchema(
            name: "vault_read",
            description: "Read a note from your memory vault at ~/Documents/CyclopOne/. Use this to recall information you've previously saved about projects, tasks, contacts, preferences, or any other topic. The user can also edit these files directly and your changes will be visible to them. Path is relative to the vault root (e.g., 'Projects/CyclopOne.md', 'Identity/user-profile.md', 'Daily/2026-02-20.md').",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "Path to the note relative to the vault root. Include .md extension."
                    ]
                ],
                "required": ["path"]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "vault_write",
            description: "Write or update a note in your memory vault at ~/Documents/CyclopOne/. Use this to save important information: project details, user preferences, task notes, decisions, or anything worth remembering. The user can see and edit these files. Use [[wikilinks]] to connect related notes (e.g., [[Current Status]], [[Components/AgentLoop]]). If the file exists, it will be overwritten — read it first and append if you want to preserve existing content.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "Path to the note relative to the vault root. Include .md extension. Directories are created automatically."
                    ],
                    "content": [
                        "type": "string",
                        "description": "The full markdown content to write to the note."
                    ]
                ],
                "required": ["path", "content"]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "vault_append",
            description: "Append content to an existing note in your vault (~/Documents/CyclopOne/) without overwriting it. Ideal for adding entries to logs, daily notes, or running lists. Creates the file if it does not exist. Use [[wikilinks]] to reference related notes.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "Path to the note relative to the vault root."
                    ],
                    "content": [
                        "type": "string",
                        "description": "Content to append to the end of the note."
                    ]
                ],
                "required": ["path", "content"]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "vault_search",
            description: "Search your memory vault (~/Documents/CyclopOne/) for notes containing specific text or related to a topic. Returns matching note paths and relevant excerpts. Use this when you need to find information but are not sure which note it is in.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Search query -- can be keywords, a phrase, or a topic name."
                    ],
                    "directory": [
                        "type": "string",
                        "description": "Optional: limit search to a specific directory (e.g., 'Projects/', 'Daily/'). Omit to search the entire vault."
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Maximum number of results to return. Default: 10."
                    ]
                ],
                "required": ["query"]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "vault_list",
            description: "List notes in a vault directory (~/Documents/CyclopOne/). Returns filenames and last-modified dates. Use to browse the vault structure or find recent notes.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "directory": [
                        "type": "string",
                        "description": "Directory path relative to vault root (e.g., 'Projects/', 'Daily/'). Omit or use '' for the vault root."
                    ]
                ],
                "required": [] as [String]
            ] as [String: Any]
        ),
    ]

    // MARK: Task Management Schemas

    /// Tool schemas for task management: task_create, task_update, task_list.
    static let taskSchemas: [ToolSchema] = [

        ToolSchema(
            name: "task_create",
            description: "Create a new task in your Active Tasks list. Tasks persist across sessions and help you track ongoing work. Use for anything the user asks you to do that may span multiple sessions or needs follow-up.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "Short task title (e.g., 'Set up Python environment for ML project')"
                    ],
                    "details": [
                        "type": "string",
                        "description": "Detailed description of what needs to be done."
                    ],
                    "priority": [
                        "type": "string",
                        "enum": ["high", "medium", "low"],
                        "description": "Task priority. Default: medium."
                    ],
                    "project": [
                        "type": "string",
                        "description": "Optional: associated project name for grouping."
                    ]
                ],
                "required": ["title"]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "task_update",
            description: "Update the status of an existing task. Use when you complete a task, make progress, or need to add notes.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "The task title to update (exact match or close match)."
                    ],
                    "status": [
                        "type": "string",
                        "enum": ["todo", "in_progress", "blocked", "done", "cancelled"],
                        "description": "New status for the task."
                    ],
                    "notes": [
                        "type": "string",
                        "description": "Optional: additional notes to append to the task."
                    ]
                ],
                "required": ["title", "status"]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "task_list",
            description: "List all active tasks, optionally filtered by status or project. Use at the start of sessions to see what needs attention.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "status": [
                        "type": "string",
                        "enum": ["all", "todo", "in_progress", "blocked", "done"],
                        "description": "Filter by status. Default: all non-done tasks."
                    ],
                    "project": [
                        "type": "string",
                        "description": "Optional: filter by project name."
                    ]
                ],
                "required": [] as [String]
            ] as [String: Any]
        ),
    ]

    // MARK: Memory Shortcut Schemas

    /// Tool schemas for memory shortcuts: remember, recall.
    static let memorySchemas: [ToolSchema] = [

        ToolSchema(
            name: "remember",
            description: "Store a fact or preference for future recall. This is a quick way to save atomic pieces of information (user preferences, learned patterns, important details). The information will be available in future sessions.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "fact": [
                        "type": "string",
                        "description": "The fact or preference to remember (e.g., 'User prefers dark mode in all apps', 'The project repo is at ~/Projects/myapp')."
                    ],
                    "category": [
                        "type": "string",
                        "enum": ["preference", "fact", "pattern", "contact", "project", "issue"],
                        "description": "Category for organizing the memory. Default: fact."
                    ]
                ],
                "required": ["fact"]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "recall",
            description: "Search your memories for information about a topic. Returns relevant facts, preferences, and notes you have previously saved. Use this when you need context about the user, a project, or a past interaction.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "topic": [
                        "type": "string",
                        "description": "The topic to recall information about (e.g., 'user preferences', 'Python project', 'John's email')."
                    ]
                ],
                "required": ["topic"]
            ] as [String: Any]
        ),
    ]

    // MARK: OpenClaw Communication Schemas

    /// Tool schemas for OpenClaw messaging: openclaw_send, openclaw_check.
    static let openclawSchemas: [ToolSchema] = [

        ToolSchema(
            name: "openclaw_send",
            description: "Send a message through OpenClaw to the user or a specific channel. Use this to communicate with the user when they are not at the keyboard, deliver results, or send notifications. The user receives messages on their phone via Telegram/WhatsApp/etc.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "message": [
                        "type": "string",
                        "description": "The message text to send."
                    ],
                    "channel": [
                        "type": "string",
                        "description": "Target channel (e.g., 'telegram', 'default'). Default: the user's primary channel."
                    ]
                ],
                "required": ["message"]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "openclaw_check",
            description: "Check for new messages from OpenClaw channels. Returns unread messages from Telegram, WhatsApp, and other connected platforms. Use this to see if the user has sent additional instructions or context.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "channel": [
                        "type": "string",
                        "description": "Optional: check a specific channel only. Omit to check all channels."
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "Maximum number of messages to retrieve. Default: 10."
                    ]
                ],
                "required": [] as [String]
            ] as [String: Any]
        ),
    ]
}
