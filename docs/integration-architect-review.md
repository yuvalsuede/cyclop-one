# Integration Architect Review: Memory-Aware Agent Loop Redesign

**Date:** 2026-02-20
**Scope:** End-to-end flow audit, memory integration design, new tool schemas, system prompt redesign

---

## Part 1: End-to-End Flow Audit

### Current Architecture Summary

The agent operates as a **stateless perceive-reason-act loop**:

```
User Command
  -> AgentCoordinator.handleUserMessage()
    -> Orchestrator.startRun()
      -> AgentLoop.prepareRun()       [capture screenshot, build first message]
      -> loop: AgentLoop.executeIteration()  [send to Claude, execute tools]
        -> VerificationEngine.verify() [score completion]
      -> RunJournal.close()           [write JSONL log]
  -> state = .idle                    [everything discarded]
```

### Where Intelligence Breaks Down

#### 1. CRITICAL: Complete Memory Loss Between Runs

**File:** `AgentLoop.swift:254-256`
```swift
func prepareRun(...) async -> ScreenCapture? {
    isCancelled = false
    conversationHistory.removeAll()  // <-- ALL CONTEXT DESTROYED
    latestScreenshot = nil
```

Every single run starts with `conversationHistory.removeAll()`. Claude has zero knowledge of:
- What it did 30 seconds ago
- Who the user is or their preferences
- What projects exist
- What tasks are in progress
- What it learned from past mistakes

This is the **single biggest reason the agent feels stupid**. A human assistant who forgets everything after each conversation would seem equally incompetent.

#### 2. Context Loss Within Iterations (Minor)

**File:** `AgentLoop.swift:350-351`
```swift
iterationCount += 1
pruneConversationHistory()
```

Screenshot pruning after 5 iterations replaces old screenshots with `[screenshot removed]`. This is actually fine -- it prevents payload bloat while maintaining text context. The within-run context is adequate.

#### 3. Verification Feedback Is Effective But Narrow

**File:** `AgentLoop.swift:631-638`
```swift
func injectVerificationFeedback(_ feedback: String) {
    let message: [String: Any] = [
        "role": "user",
        "content": [["type": "text", "text": feedback]]
    ]
    conversationHistory.append(message)
}
```

The verification feedback loop works correctly -- rejected completions inject feedback into the conversation and Claude sees it on the next iteration. However, verification results are never persisted for future runs. If Claude fails the same task repeatedly across runs, it cannot learn from past failures.

#### 4. System Prompt Is Competent But Amnesiac

**File:** `ToolDefinitions.swift:7-67`

The system prompt is well-written for screenshot interpretation and action guidelines. But it tells Claude nothing about:
- Persistent memory or how to use it
- The user's identity, preferences, or context
- Ongoing tasks or projects
- Communication channels (OpenClaw)
- How to save/recall learned information

Claude is told "you are OmniAgent" but given no context about *whose* agent it is or what history exists.

#### 5. Tool Set Is Action-Only, No Knowledge Tools

**File:** `ToolDefinitions.swift:84-307`

The 10 current tools are all **physical action tools**:
- `run_shell_command`, `run_applescript`
- `click`, `right_click`, `type_text`, `press_key`
- `take_screenshot`, `open_application`
- `move_mouse`, `drag`, `scroll`

There are zero tools for:
- Reading/writing persistent notes
- Managing tasks
- Searching memory
- Communicating with the user asynchronously

Claude can manipulate the screen but cannot manage knowledge. It is a pair of hands without a notebook.

#### 6. Journal Logs Everything But Exposes Nothing to Claude

**File:** `RunJournal.swift`

The RunJournal meticulously records every run event to `~/.omniagent/runs/<runId>/journal.jsonl`. This data includes commands, tool calls, verification scores, and timestamps. But this data is:
- Never loaded back into future runs
- Never surfaced to Claude in the system prompt
- Never analyzed for patterns

The journal is a write-only audit log, not a learning system.

#### 7. Skill Loader Provides Pattern Matching, Not Memory

**File:** `Orchestrator.swift:142-156`

The SkillLoader matches commands against predefined skills and injects context. This is useful but is static configuration, not learned behavior. It also suggests new skills based on repeated commands, which is a primitive form of learning -- but the suggestions are ephemeral (shown as a chat message, never persisted).

### Flow Diagram: Current vs. Proposed

```
CURRENT:
  Command -> [empty context] -> Execute -> Discard everything

PROPOSED:
  Command -> [load relevant memories] -> Execute -> [save outcomes] -> Memories persist
            ^                                            |
            |____________________________________________|
                        (next run reads this)
```

---

## Part 2: Memory-Aware Agent Loop Redesign

### Obsidian Vault as Persistent Memory

The vault at `~/Documents/Obsidian Vault/OmniAgent/` will serve as the agent's long-term memory. Obsidian was chosen because:
- Plain markdown files, no lock-in
- Wikilinks create a knowledge graph
- User can browse/edit the vault directly
- Integrates with existing Obsidian workflows

### Vault Structure

```
~/Documents/Obsidian Vault/OmniAgent/
  OmniAgent Home.md           # Hub page with links to all sections
  Current Status.md           # What the agent knows about current state
  Known Issues.md             # Problems encountered and their resolutions
  User Profile.md             # User preferences, name, common patterns
  Active Tasks.md             # Current task list with status
  Architecture/               # System design knowledge
  Components/                 # Per-component documentation
  Projects/                   # Per-project knowledge
    <project-name>.md
  Contacts/                   # People the agent knows about
    <name>.md
  Decisions/                  # Decision log
    Decision Log.md
  Daily/                      # Daily session notes
    YYYY-MM-DD.md
  Memory/                     # Atomic memory notes
    <topic>.md
  Skills/                     # Learned patterns and procedures
    <skill-name>.md
```

### New Agent Loop Flow

#### Phase 1: Pre-Run Memory Loading

Before the Orchestrator calls `AgentLoop.prepareRun()`, a new `MemoryService` loads relevant context:

```swift
// In Orchestrator.startRun(), BEFORE agentLoop.prepareRun():

// 1. Load core context (always loaded, ~500 tokens)
let coreMemory = await memoryService.loadCoreContext()
// Contains: User Profile, Active Tasks, Current Status, recent daily note

// 2. Load command-relevant memories (semantic search, ~500 tokens)
let relevantMemories = await memoryService.searchMemories(query: command, limit: 5)
// Uses keyword matching against vault notes, returns most relevant snippets

// 3. Load recent run history (~200 tokens)
let recentHistory = await memoryService.loadRecentRunSummaries(limit: 5)
// Last 5 run outcomes: "Opened Chrome and navigated to GitHub - Success"

// 4. Build memory context string
let memoryContext = memoryService.buildContextString(
    core: coreMemory,
    relevant: relevantMemories,
    history: recentHistory
)

// 5. Inject into agent loop (alongside skill context)
await agentLoop.setMemoryContext(memoryContext)
```

#### Phase 2: During-Run Memory Updates

Claude gets new tools to interact with memory during execution:

```swift
// In AgentLoop.executeToolCall(), new cases:

case "vault_read":
    // Read a note from the vault
    let path = input["path"] as? String ?? ""
    let content = await memoryService.readNote(path: path)
    return ToolResult(result: content, isError: false)

case "vault_write":
    // Write or update a note in the vault
    let path = input["path"] as? String ?? ""
    let content = input["content"] as? String ?? ""
    await memoryService.writeNote(path: path, content: content)
    return ToolResult(result: "Note saved: \(path)", isError: false)

case "vault_search":
    // Search the vault for relevant notes
    let query = input["query"] as? String ?? ""
    let results = await memoryService.searchNotes(query: query, limit: 10)
    return ToolResult(result: results, isError: false)

case "vault_list":
    // List notes in a directory
    let directory = input["directory"] as? String ?? ""
    let listing = await memoryService.listNotes(directory: directory)
    return ToolResult(result: listing, isError: false)

case "task_create":
    // Create a new task in Active Tasks.md
    let title = input["title"] as? String ?? ""
    let details = input["details"] as? String ?? ""
    let priority = input["priority"] as? String ?? "medium"
    await memoryService.createTask(title: title, details: details, priority: priority)
    return ToolResult(result: "Task created: \(title)", isError: false)

case "task_update":
    // Update task status
    let title = input["title"] as? String ?? ""
    let status = input["status"] as? String ?? ""
    await memoryService.updateTask(title: title, status: status)
    return ToolResult(result: "Task updated: \(title) -> \(status)", isError: false)

case "remember":
    // Store an atomic memory (shortcut for common pattern)
    let fact = input["fact"] as? String ?? ""
    let category = input["category"] as? String ?? "general"
    await memoryService.remember(fact: fact, category: category)
    return ToolResult(result: "Remembered: \(fact)", isError: false)

case "recall":
    // Recall memories about a topic
    let topic = input["topic"] as? String ?? ""
    let memories = await memoryService.recall(topic: topic)
    return ToolResult(result: memories, isError: false)
```

#### Phase 3: Post-Run Memory Persistence

After the Orchestrator receives the `RunResult`, before returning:

```swift
// In Orchestrator.runIterationLoop(), after the run completes:

// 1. Save run summary to daily note
await memoryService.appendToDailyNote(
    command: command,
    success: result.success,
    summary: result.summary,
    iterations: iteration,
    score: result.finalScore
)

// 2. Update Active Tasks if the command was task-related
await memoryService.updateTasksFromRun(command: command, success: result.success)

// 3. Record learned patterns (e.g., if a particular approach failed)
if !result.success {
    await memoryService.recordFailure(
        command: command,
        reason: result.summary,
        iterations: iteration
    )
}

// 4. Update Current Status with latest activity
await memoryService.updateCurrentStatus(
    lastCommand: command,
    lastOutcome: result.success ? "success" : "failed",
    timestamp: Date()
)
```

---

## Part 3: New Tool Definitions

### Vault Management Tools

```swift
// vault_read
[
    "name": "vault_read",
    "description": "Read a note from your Obsidian memory vault. Use this to recall information you've previously saved about projects, tasks, contacts, preferences, or any other topic. Path is relative to the vault root (e.g., 'Projects/OmniAgent.md', 'User Profile.md', 'Daily/2026-02-20.md').",
    "input_schema": [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Path to the note relative to the vault root. Include .md extension."
            ]
        ],
        "required": ["path"]
    ]
]

// vault_write
[
    "name": "vault_write",
    "description": "Write or update a note in your Obsidian memory vault. Use this to save important information you've learned: project details, user preferences, task notes, decisions, or anything worth remembering for future sessions. Use [[wikilinks]] to connect related notes. If the file exists, it will be overwritten -- read it first and append if you want to preserve existing content.",
    "input_schema": [
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
    ]
]

// vault_append
[
    "name": "vault_append",
    "description": "Append content to an existing note in the vault without overwriting it. Ideal for adding entries to logs, daily notes, or running lists. Creates the file if it does not exist.",
    "input_schema": [
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
    ]
]

// vault_search
[
    "name": "vault_search",
    "description": "Search your memory vault for notes containing specific text or related to a topic. Returns matching note paths and relevant excerpts. Use this when you need to find information but are not sure which note it is in.",
    "input_schema": [
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
    ]
]

// vault_list
[
    "name": "vault_list",
    "description": "List notes in a vault directory. Returns filenames and last-modified dates. Use to browse the vault structure or find recent notes.",
    "input_schema": [
        "type": "object",
        "properties": [
            "directory": [
                "type": "string",
                "description": "Directory path relative to vault root (e.g., 'Projects/', 'Daily/'). Omit or use '' for the vault root."
            ]
        ],
        "required": []
    ]
]
```

### Task Management Tools

```swift
// task_create
[
    "name": "task_create",
    "description": "Create a new task in your Active Tasks list. Tasks persist across sessions and help you track ongoing work. Use for anything the user asks you to do that may span multiple sessions or needs follow-up.",
    "input_schema": [
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
    ]
]

// task_update
[
    "name": "task_update",
    "description": "Update the status of an existing task. Use when you complete a task, make progress, or need to add notes.",
    "input_schema": [
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
    ]
]

// task_list
[
    "name": "task_list",
    "description": "List all active tasks, optionally filtered by status or project. Use at the start of sessions to see what needs attention.",
    "input_schema": [
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
        "required": []
    ]
]
```

### Memory Shortcut Tools

```swift
// remember
[
    "name": "remember",
    "description": "Store a fact or preference for future recall. This is a quick way to save atomic pieces of information (user preferences, learned patterns, important details). The information will be available in future sessions.",
    "input_schema": [
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
    ]
]

// recall
[
    "name": "recall",
    "description": "Search your memories for information about a topic. Returns relevant facts, preferences, and notes you have previously saved. Use this when you need context about the user, a project, or a past interaction.",
    "input_schema": [
        "type": "object",
        "properties": [
            "topic": [
                "type": "string",
                "description": "The topic to recall information about (e.g., 'user preferences', 'Python project', 'John's email')."
            ]
        ],
        "required": ["topic"]
    ]
]
```

### OpenClaw Communication Tools

```swift
// openclaw_send
[
    "name": "openclaw_send",
    "description": "Send a message through OpenClaw to the user or a specific channel. Use this to communicate with the user when they are not at the keyboard, deliver results, or send notifications. The user receives messages on their phone via Telegram/WhatsApp/etc.",
    "input_schema": [
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
    ]
]

// openclaw_check
[
    "name": "openclaw_check",
    "description": "Check for new messages from OpenClaw channels. Returns unread messages from Telegram, WhatsApp, and other connected platforms. Use this to see if the user has sent additional instructions or context.",
    "input_schema": [
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
        "required": []
    ]
]
```

---

## Part 4: System Prompt Redesign

The system prompt in `ToolDefinitions.swift` needs significant expansion. The new prompt should be structured in sections:

### Proposed System Prompt

```
You are OmniAgent, a persistent AI assistant that controls a macOS desktop and maintains long-term memory. You belong to {user_name} and have been working with them since {first_session_date}.

## Your Memory
You have persistent memory stored in an Obsidian vault. Before each session, relevant memories are loaded automatically (shown below). You can also actively read, write, and search your vault during tasks.

### How to Use Memory
1. **Before acting:** Check if you have relevant memories about this task, project, or topic. Use `recall` or `vault_search` if the auto-loaded context is insufficient.
2. **During tasks:** Save important discoveries, decisions, and outcomes as you work. Use `remember` for quick facts or `vault_write` for detailed notes.
3. **After completing tasks:** Update task status, record what you learned, and note any follow-up items.
4. **Always save:**
   - New user preferences (e.g., "prefers tabs over spaces")
   - Project-specific knowledge (e.g., "this repo uses pnpm, not npm")
   - Contact information mentioned by the user
   - Patterns you discover (e.g., "user usually wants screenshots saved to Desktop")
   - Failures and their resolutions (so you do not repeat mistakes)

### Auto-Loaded Context
{memory_context}

## Your Tasks
You maintain a persistent task list. When the user gives you multi-step or ongoing work:
1. Create tasks with `task_create`
2. Update progress with `task_update`
3. Check your task list at the start of sessions to see unfinished work

## Communication
You can communicate with the user through OpenClaw when they are not at the keyboard:
- Use `openclaw_send` to deliver results or ask questions
- Use `openclaw_check` to see if the user sent additional instructions
- The user may send commands via Telegram that arrive through OpenClaw

## Screen Control
[existing screenshot interpretation rules, coordinate system, and action guidelines remain here unchanged]

## CRITICAL: On-Screen Content Safety
[existing safety rules remain here unchanged]
```

### Implementation: Dynamic System Prompt Assembly

```swift
// In ToolDefinitions.swift, replace the static systemPrompt with:

static func buildSystemPrompt(
    memoryContext: String,
    skillContext: String,
    userName: String = "the user"
) -> String {
    var prompt = """
    You are OmniAgent, a persistent AI assistant that controls a macOS desktop \
    and maintains long-term memory. You belong to \(userName).

    ## Your Memory
    You have persistent memory stored in an Obsidian vault. Relevant memories \
    are loaded automatically before each session. You can also actively read, \
    write, and search your vault during tasks.

    ### How to Use Memory
    1. Before acting: Check if you have relevant context. Use `recall` or \
       `vault_search` if the auto-loaded context seems insufficient.
    2. During tasks: Save important discoveries, decisions, and outcomes.
    3. After completing tasks: Update task status and record what you learned.
    4. Always save: User preferences, project knowledge, contact info, \
       patterns you discover, and failure resolutions.

    ### Current Context
    \(memoryContext.isEmpty ? "(No memories loaded yet. This may be your first session.)" : memoryContext)

    """

    // Add screen control section (existing content)
    prompt += screenControlSection

    // Add skill context if any
    if !skillContext.isEmpty {
        prompt += skillContext
    }

    // Add safety section (existing content)
    prompt += safetySection

    return prompt
}
```

---

## Part 5: New Service — MemoryService

### File: `OmniAgent/Services/MemoryService.swift`

```swift
actor MemoryService {
    static let shared = MemoryService()

    /// Root path of the Obsidian vault
    let vaultRoot: URL

    /// Core files that are always loaded (capped at ~500 tokens each)
    private let coreFiles = [
        "User Profile.md",
        "Active Tasks.md",
        "Current Status.md"
    ]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.vaultRoot = home
            .appendingPathComponent("Documents/Obsidian Vault/OmniAgent")
    }

    // MARK: - Pre-Run Loading

    /// Load core context that is always included in the system prompt.
    func loadCoreContext() -> String {
        var sections: [String] = []

        for file in coreFiles {
            let url = vaultRoot.appendingPathComponent(file)
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                let trimmed = String(content.prefix(2000)) // ~500 tokens
                sections.append("### \(file.replacingOccurrences(of: ".md", with: ""))\n\(trimmed)")
            }
        }

        // Load today's daily note if it exists
        let today = dailyNotePath()
        let todayURL = vaultRoot.appendingPathComponent(today)
        if let content = try? String(contentsOf: todayURL, encoding: .utf8) {
            let trimmed = String(content.suffix(1000)) // Last ~250 tokens
            sections.append("### Today's Notes\n\(trimmed)")
        }

        return sections.joined(separator: "\n\n")
    }

    /// Search vault for notes relevant to a command.
    func searchMemories(query: String, limit: Int = 5) -> String {
        let keywords = extractKeywords(from: query)
        var results: [(path: String, score: Int, excerpt: String)] = []

        // Walk the vault and score each note
        let enumerator = FileManager.default.enumerator(
            at: vaultRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let relativePath = url.path.replacingOccurrences(
                of: vaultRoot.path + "/", with: ""
            )

            // Simple keyword scoring
            let lower = content.lowercased()
            var score = 0
            for keyword in keywords {
                if lower.contains(keyword.lowercased()) {
                    score += 1
                }
            }

            if score > 0 {
                // Extract a relevant excerpt
                let excerpt = extractExcerpt(from: content, keywords: keywords, maxLength: 300)
                results.append((path: relativePath, score: score, excerpt: excerpt))
            }
        }

        // Sort by score descending, take top N
        let top = results.sorted { $0.score > $1.score }.prefix(limit)

        if top.isEmpty {
            return ""
        }

        return top.map { "**\($0.path)** (relevance: \($0.score))\n\($0.excerpt)" }
            .joined(separator: "\n\n")
    }

    /// Load summaries of recent runs from daily notes.
    func loadRecentRunSummaries(limit: Int = 5) -> String {
        // Read the last few lines of recent daily notes
        let calendar = Calendar.current
        var summaries: [String] = []

        for dayOffset in 0..<7 {
            guard summaries.count < limit else { break }
            let date = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
            let path = dailyNotePath(for: date)
            let url = vaultRoot.appendingPathComponent(path)

            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            // Extract run entries (lines starting with "- [")
            let runLines = content.components(separatedBy: "\n")
                .filter { $0.hasPrefix("- [") || $0.hasPrefix("  - ") }
                .suffix(limit - summaries.count)

            summaries.append(contentsOf: runLines)
        }

        return summaries.isEmpty ? "" : "### Recent Activity\n" + summaries.joined(separator: "\n")
    }

    /// Build the complete memory context string for the system prompt.
    func buildContextString(core: String, relevant: String, history: String) -> String {
        var parts: [String] = []
        if !core.isEmpty { parts.append(core) }
        if !relevant.isEmpty { parts.append("### Relevant Memories\n\(relevant)") }
        if !history.isEmpty { parts.append(history) }
        return parts.joined(separator: "\n\n---\n\n")
    }

    // MARK: - During-Run Operations

    /// Read a note from the vault.
    func readNote(path: String) -> String {
        let url = vaultRoot.appendingPathComponent(path)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return "Note not found: \(path)"
        }
        return content
    }

    /// Write a note to the vault (creates directories as needed).
    func writeNote(path: String, content: String) {
        let url = vaultRoot.appendingPathComponent(path)
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Append content to a note (creates if needed).
    func appendToNote(path: String, content: String) {
        let url = vaultRoot.appendingPathComponent(path)
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let updated = existing + "\n" + content
            try? updated.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Search notes by keyword. Returns formatted results.
    func searchNotes(query: String, directory: String? = nil, limit: Int = 10) -> String {
        let searchRoot: URL
        if let dir = directory, !dir.isEmpty {
            searchRoot = vaultRoot.appendingPathComponent(dir)
        } else {
            searchRoot = vaultRoot
        }

        let keywords = extractKeywords(from: query)
        var results: [(path: String, excerpt: String)] = []

        let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "md",
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let lower = content.lowercased()
            let matches = keywords.filter { lower.contains($0.lowercased()) }

            if !matches.isEmpty {
                let relativePath = url.path.replacingOccurrences(
                    of: vaultRoot.path + "/", with: ""
                )
                let excerpt = extractExcerpt(from: content, keywords: keywords, maxLength: 200)
                results.append((path: relativePath, excerpt: excerpt))
            }
        }

        let top = results.prefix(limit)
        if top.isEmpty { return "No results found for: \(query)" }

        return top.map { "- **\($0.path)**: \($0.excerpt)" }.joined(separator: "\n")
    }

    /// List notes in a directory.
    func listNotes(directory: String = "") -> String {
        let listRoot = directory.isEmpty ? vaultRoot : vaultRoot.appendingPathComponent(directory)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: listRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else {
            return "Directory not found: \(directory)"
        }

        let items = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines: [String] = []

        for item in items {
            let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            let isDir = values?.isDirectory ?? false
            let name = item.lastPathComponent

            if isDir {
                lines.append("  [dir] \(name)/")
            } else if name.hasSuffix(".md") {
                let date = values?.contentModificationDate
                let dateStr = date.map { ISO8601DateFormatter().string(from: $0) } ?? ""
                lines.append("  \(name)  (\(dateStr))")
            }
        }

        return lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n")
    }

    // MARK: - Task Management

    func createTask(title: String, details: String = "", priority: String = "medium", project: String? = nil) {
        let taskLine = "- [ ] **\(title)** [\(priority)]\(project.map { " #\($0)" } ?? "")\(details.isEmpty ? "" : "\n  \(details)")"
        appendToNote(path: "Active Tasks.md", content: taskLine)
    }

    func updateTask(title: String, status: String, notes: String? = nil) {
        let url = vaultRoot.appendingPathComponent("Active Tasks.md")
        guard var content = try? String(contentsOf: url, encoding: .utf8) else { return }

        // Find the task line and update it
        let lines = content.components(separatedBy: "\n")
        var updated = false

        let newLines = lines.map { line -> String in
            if line.contains(title) && line.contains("- [") {
                updated = true
                let checkbox = status == "done" ? "- [x]" : "- [ ]"
                let statusTag = status == "done" ? "" : " (\(status))"
                var newLine = line
                    .replacingOccurrences(of: "- [ ]", with: checkbox)
                    .replacingOccurrences(of: "- [x]", with: checkbox)
                // Remove old status tags
                if let range = newLine.range(of: #" \(todo|in_progress|blocked|cancelled\)"#, options: .regularExpression) {
                    newLine.removeSubrange(range)
                }
                newLine += statusTag
                if let noteText = notes {
                    newLine += "\n  > \(noteText)"
                }
                return newLine
            }
            return line
        }

        if updated {
            content = newLines.joined(separator: "\n")
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func listTasks(status: String? = nil, project: String? = nil) -> String {
        let url = vaultRoot.appendingPathComponent("Active Tasks.md")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return "No active tasks."
        }

        var lines = content.components(separatedBy: "\n")
            .filter { $0.hasPrefix("- [") }

        if let status = status, status != "all" {
            switch status {
            case "done": lines = lines.filter { $0.hasPrefix("- [x]") }
            case "todo": lines = lines.filter { $0.hasPrefix("- [ ]") && !$0.contains("(in_progress)") && !$0.contains("(blocked)") }
            default: lines = lines.filter { $0.contains("(\(status))") }
            }
        } else {
            // Default: exclude done tasks
            lines = lines.filter { !$0.hasPrefix("- [x]") }
        }

        if let project = project {
            lines = lines.filter { $0.contains("#\(project)") }
        }

        return lines.isEmpty ? "No matching tasks." : lines.joined(separator: "\n")
    }

    // MARK: - Memory Shortcuts

    func remember(fact: String, category: String = "general") {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "- \(fact) `[\(category)]` `[\(timestamp)]`"
        appendToNote(path: "Memory/\(category).md", content: entry)
    }

    func recall(topic: String) -> String {
        return searchNotes(query: topic, directory: "Memory", limit: 10)
    }

    // MARK: - Post-Run

    func appendToDailyNote(command: String, success: Bool, summary: String, iterations: Int, score: Int?) {
        let path = dailyNotePath()
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        let status = success ? "done" : "failed"
        let scoreStr = score.map { " (score: \($0))" } ?? ""
        let entry = "- [\(time)] `\(status)` \(command)\(scoreStr) — \(summary) (\(iterations) iterations)"
        appendToNote(path: path, content: entry)
    }

    func updateCurrentStatus(lastCommand: String, lastOutcome: String, timestamp: Date) {
        let time = ISO8601DateFormatter().string(from: timestamp)
        let content = """
        # Current Status

        **Last active:** \(time)
        **Last command:** \(lastCommand)
        **Last outcome:** \(lastOutcome)
        """
        writeNote(path: "Current Status.md", content: content)
    }

    func recordFailure(command: String, reason: String, iterations: Int) {
        let entry = "- **\(command)** failed after \(iterations) iterations: \(reason)"
        appendToNote(path: "Known Issues.md", content: entry)
    }

    // MARK: - Helpers

    private func dailyNotePath(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "Daily/\(formatter.string(from: date)).md"
    }

    private func extractKeywords(from text: String) -> [String] {
        let stopWords: Set<String> = ["the", "a", "an", "is", "are", "was", "were",
            "be", "been", "being", "have", "has", "had", "do", "does", "did",
            "will", "would", "could", "should", "may", "might", "shall",
            "can", "to", "of", "in", "for", "on", "with", "at", "by",
            "from", "it", "this", "that", "my", "your", "me", "i", "and",
            "or", "but", "not", "please", "open", "go"]

        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }

    private func extractExcerpt(from content: String, keywords: [String], maxLength: Int) -> String {
        let lines = content.components(separatedBy: "\n")
        let lower = content.lowercased()

        // Find the first line containing a keyword
        for (i, line) in lines.enumerated() {
            let lineLower = line.lowercased()
            if keywords.contains(where: { lineLower.contains($0) }) {
                let start = max(0, i - 1)
                let end = min(lines.count, i + 3)
                let excerpt = lines[start..<end].joined(separator: "\n")
                return String(excerpt.prefix(maxLength))
            }
        }

        return String(content.prefix(maxLength))
    }
}
```

---

## Part 6: Required File Changes

### Summary of Changes

| File | Change Type | Description |
|------|-----------|-------------|
| `Services/MemoryService.swift` | **NEW** | Obsidian vault read/write/search/task management |
| `Agent/ToolDefinitions.swift` | **MODIFY** | Add 12 new tool definitions, restructure system prompt |
| `Agent/AgentLoop.swift` | **MODIFY** | Add memory context property, handle 12 new tool cases |
| `Agent/Orchestrator.swift` | **MODIFY** | Add pre-run memory loading and post-run memory saving |
| `Agent/AgentCoordinator.swift` | **MODIFY** | Initialize MemoryService, ensure vault exists |
| `Services/OpenClawService.swift` | **NEW** | OpenClaw messaging bridge (send/receive) |

### Detailed Changes

#### `Agent/AgentLoop.swift`

1. Add `private var memoryContext: String = ""` property (line ~31)
2. Add `func setMemoryContext(_ context: String)` method
3. In `executeIteration()`, modify system prompt assembly to include memory context:
   ```swift
   var systemPrompt = ToolDefinitions.buildSystemPrompt(
       memoryContext: memoryContext,
       skillContext: skillContext
   )
   ```
4. In `executeToolCall()`, add cases for all 12 new tools
5. In the `default` case, keep "Unknown tool" error

#### `Agent/Orchestrator.swift`

1. Add `private let memoryService = MemoryService.shared` property
2. In `startRun()`, after skill matching and before `agentLoop.prepareRun()`:
   ```swift
   // Load memory context
   let coreMemory = await memoryService.loadCoreContext()
   let relevantMemories = await memoryService.searchMemories(query: command, limit: 5)
   let recentHistory = await memoryService.loadRecentRunSummaries(limit: 5)
   let memoryContext = await memoryService.buildContextString(
       core: coreMemory, relevant: relevantMemories, history: recentHistory
   )
   await agentLoop.setMemoryContext(memoryContext)
   ```
3. In `runIterationLoop()`, after the run completes (before returning `RunResult`):
   ```swift
   // Post-run memory persistence
   await memoryService.appendToDailyNote(
       command: command, success: passed,
       summary: result.summary, iterations: iteration,
       score: score
   )
   await memoryService.updateCurrentStatus(
       lastCommand: command,
       lastOutcome: passed ? "success" : "failed",
       timestamp: Date()
   )
   if !passed {
       await memoryService.recordFailure(
           command: command, reason: reason, iterations: iteration
       )
   }
   ```

#### `Agent/ToolDefinitions.swift`

1. Replace `static let systemPrompt` with `static func buildSystemPrompt(...)` that assembles the prompt dynamically
2. Extract screen control and safety sections into static properties for reuse
3. Add all 12 new tool definitions to the `tools` array

#### `Agent/AgentCoordinator.swift`

1. In `init()`, call `ensureVaultStructure()` to create the vault directories on first launch:
   ```swift
   Task {
       await MemoryService.shared.ensureVaultStructure()
   }
   ```

---

## Part 7: Token Budget Analysis

Memory context must fit within the API's context window alongside screenshots and conversation history.

| Component | Estimated Tokens |
|-----------|-----------------|
| System prompt (base) | ~800 |
| Memory context (core) | ~500 |
| Memory context (relevant) | ~500 |
| Memory context (history) | ~200 |
| Skill context | ~200 |
| Screenshot (base64 in message) | counted as image tokens by API |
| Tool definitions (22 tools) | ~2000 |
| **Total fixed overhead** | **~4200 tokens** |

With Claude's 200k context window and 8192 max output tokens, this leaves ample room for conversation history and screenshots. The memory context is deliberately capped at ~1200 tokens total to avoid crowding out conversation space.

### Scaling Strategy

As the vault grows, the keyword search will become slower. Phase 2 should add:
1. A local embedding index (e.g., using `NaturalLanguage.framework` for on-device embeddings)
2. A metadata cache (`vault_index.json`) that stores note titles, tags, and last-modified dates
3. Incremental indexing triggered by vault file changes (FSEvents)

For now, keyword search over a few hundred notes is fast enough (<100ms).

---

## Part 8: Implementation Priority

### Phase 1 (Must-Have, Week 1)
1. Create `MemoryService.swift` with vault read/write/search/list
2. Add `vault_read`, `vault_write`, `vault_append`, `vault_search`, `vault_list` tools
3. Add `remember` and `recall` shortcut tools
4. Modify `Orchestrator` for pre-run memory loading and post-run saving
5. Restructure system prompt to include memory context

### Phase 2 (Important, Week 2)
1. Add `task_create`, `task_update`, `task_list` tools
2. Add daily note auto-creation
3. Add failure recording to Known Issues
4. Ensure vault structure creation on first launch

### Phase 3 (Enhancement, Week 3)
1. Create `OpenClawService.swift` and add `openclaw_send`, `openclaw_check` tools
2. Add semantic search improvements (NaturalLanguage.framework embeddings)
3. Add vault file change watching for cache invalidation
4. Add memory context relevance scoring improvements

---

## Part 9: Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| Vault corruption from concurrent writes | Medium | MemoryService is an actor (serial access). File writes use `atomically: true`. |
| Memory context exceeds token budget | Low | Hard cap at ~1200 tokens. Truncation applied. |
| Irrelevant memories loaded | Medium | Keyword search is simple but effective. Phase 2 adds embeddings. |
| Claude over-uses memory tools (wastes iterations) | Medium | System prompt instructs Claude to use auto-loaded context first, only search when needed. |
| User edits vault while agent is writing | Low | Atomic file writes prevent partial reads. Last-write-wins is acceptable. |
| Vault grows unbounded | Low | Daily notes are dated. Periodic cleanup can be added. Memory notes are small. |
