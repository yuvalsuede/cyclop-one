# OS/Integration Architect Review: Obsidian Vault & OpenClaw Integration

**Author:** OS/Integration Architect
**Date:** 2026-02-20
**Status:** Design Proposal
**Scope:** ObsidianService actor, Vault tool definitions, OpenClaw bridge, new agent tools

---

## 1. Executive Summary

OmniAgent currently has **no persistent memory** and **no integration with OpenClaw**. This document designs two new subsystems:

1. **ObsidianService** — A Swift actor for all Obsidian vault I/O (CRUD, search, wikilinks, file watching)
2. **OpenClawBridge** — A Swift actor that wraps the `openclaw` CLI to send/receive messages and manage channels

Both integrate into the existing `ToolDefinitions.swift` as new Claude-callable tools, routed through `ActionExecutor` with appropriate permission tiers.

---

## 2. Codebase Review Findings

### 2.1 CommandGateway.swift

The gateway already supports `CommandSource.openClaw` as an enum case, with a `ReplyChannel` protocol that OpenClaw can implement. The architecture is sound — we need to:

- Implement `OpenClawReplyChannel: ReplyChannel` that sends responses back via `openclaw message send`
- Create an `OpenClawListener` that polls or listens for incoming messages and submits them through `CommandGateway.submit()`

### 2.2 ToolDefinitions.swift

Current tools are OS-interaction focused (click, type, shell, screenshot). The tool schema pattern is consistent:
- Each tool is a `[String: Any]` dictionary with `name`, `description`, and `input_schema`
- `input_schema` follows JSON Schema with `type`, `properties`, `required`

New vault and messaging tools should follow this exact pattern.

### 2.3 OpenClaw Installation

OpenClaw is installed at `/Users/suede/.nvm/versions/node/v25.1.0/bin/openclaw` (v2026.2.9). Key facts:

- **CLI-based**: All operations go through `openclaw` subcommands
- **Channels**: Supports Telegram, WhatsApp, Discord, Slack, Signal, iMessage, and 10+ more
- **No channels configured yet** (`openclaw channels list` shows none)
- **Skills system**: The `omniagent` skill at `~/.openclaw/skills/omniagent/SKILL.md` already defines desktop control via cliclick/screencapture
- **Message API**: `openclaw message send --channel <ch> --target <dest> --message <text>` / `openclaw message read --channel <ch> --target <dest>`
- **Workspace**: Has `AGENTS.md`, `SOUL.md`, `USER.md`, `TOOLS.md`, `HEARTBEAT.md` structure at `~/.openclaw/workspace/`
- **Heartbeat**: 30-minute heartbeat configured in `openclaw.json`

### 2.4 PermissionClassifier

The tiered permission system (Tier 1/2/3) works well. New vault tools should be:
- Vault reads → Tier 1 (always safe)
- Vault writes → Tier 2 (file_writes category, session approval)
- OpenClaw send → Tier 2 (network_access category)
- OpenClaw channel config → Tier 3 (modifying communication infrastructure)

---

## 3. ObsidianService Design

### 3.1 Vault Location

```
~/Documents/Obsidian Vault/OmniAgent-Brain/
```

This keeps the agent's memory separate from any existing user vaults while remaining visible in Obsidian as a standalone vault.

### 3.2 Folder Structure

```
OmniAgent-Brain/
├── Index.md                    ← Hub page with links to everything
├── Tasks/
│   ├── _template.md            ← Task template
│   ├── active/                 ← Tasks currently in progress
│   └── completed/              ← Archived completed tasks
├── Contacts/
│   ├── _template.md            ← Contact template
│   └── (person-name.md)
├── Projects/
│   ├── _template.md            ← Project template
│   └── (project-name.md)
├── Journal/
│   └── (YYYY-MM-DD.md)         ← Daily action logs
├── Memory/
│   ├── Preferences.md          ← User preferences and patterns
│   ├── Facts.md                ← Learned factual knowledge
│   └── Patterns.md             ← Behavioral patterns and routines
└── Templates/
    ├── task.md
    ├── contact.md
    ├── project.md
    └── journal.md
```

### 3.3 Template Definitions

#### Task Template (`Templates/task.md`)
```markdown
---
status: active
priority: medium
created: {{date}}
due:
tags: []
project:
---
# {{title}}

## Description


## Steps
- [ ]

## Notes

## Related
```

#### Contact Template (`Templates/contact.md`)
```markdown
---
created: {{date}}
tags: []
---
# {{name}}

## Details
- **Relationship:**
- **Email:**
- **Phone:**

## Context


## Interactions
- {{date}}:
```

#### Journal Template (`Templates/journal.md`)
```markdown
---
date: {{date}}
---
# {{date}}

## Actions Taken

## Commands Received

## Observations

## Decisions Made

## Follow-ups
```

### 3.4 ObsidianService Actor

```swift
// OmniAgent/Services/ObsidianService.swift

import Foundation
import os.log

private let logger = Logger(subsystem: "com.omniagent.app", category: "ObsidianService")

/// Manages all Obsidian vault I/O for OmniAgent's persistent memory.
///
/// The vault lives at ~/Documents/Obsidian Vault/OmniAgent-Brain/
/// and is structured with folders for Tasks, Contacts, Projects,
/// Journal, and Memory.
///
/// All file operations are async and go through FileManager.
/// Wikilinks are resolved relative to the vault root.
actor ObsidianService {

    // MARK: - Singleton

    static let shared = ObsidianService()

    // MARK: - Properties

    /// Root path of the Obsidian vault.
    let vaultRoot: URL

    /// FileManager instance for all I/O.
    private let fm = FileManager.default

    /// Debounce interval for file watching (seconds).
    private let fileWatchDebounce: TimeInterval = 1.0

    /// Dispatch source for file watching (optional feature).
    private var fileWatcher: DispatchSourceFileSystemObject?

    // MARK: - Init

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.vaultRoot = home
            .appendingPathComponent("Documents")
            .appendingPathComponent("Obsidian Vault")
            .appendingPathComponent("OmniAgent-Brain")
    }

    // MARK: - Vault Initialization

    /// Ensure the vault directory structure exists.
    /// Creates all folders and the Index.md hub page if missing.
    /// Call this once at app startup.
    func ensureVault() throws {
        let folders = [
            "Tasks/active",
            "Tasks/completed",
            "Contacts",
            "Projects",
            "Journal",
            "Memory",
            "Templates",
        ]

        for folder in folders {
            let url = vaultRoot.appendingPathComponent(folder)
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                logger.info("Created vault folder: \(folder)")
            }
        }

        // Create Index.md if missing
        let indexPath = vaultRoot.appendingPathComponent("Index.md")
        if !fm.fileExists(atPath: indexPath.path) {
            let indexContent = """
            # OmniAgent Brain

            Welcome to OmniAgent's persistent memory vault.

            ## Quick Links
            - [[Tasks]] — Active and completed tasks
            - [[Contacts]] — People the agent knows
            - [[Projects]] — Ongoing projects with context
            - [[Journal]] — Daily action logs
            - [[Memory/Preferences]] — Learned preferences
            - [[Memory/Facts]] — Factual knowledge
            - [[Memory/Patterns]] — Behavioral patterns

            ## Recent Activity
            _Updated automatically by OmniAgent_
            """
            try indexContent.write(to: indexPath, atomically: true, encoding: .utf8)
            logger.info("Created Index.md")
        }

        // Install templates if missing
        try installTemplates()

        logger.info("Vault initialized at: \(self.vaultRoot.path)")
    }

    /// Install default templates into Templates/ folder.
    private func installTemplates() throws {
        let templates: [(String, String)] = [
            ("task.md", Self.taskTemplate),
            ("contact.md", Self.contactTemplate),
            ("project.md", Self.projectTemplate),
            ("journal.md", Self.journalTemplate),
        ]

        for (name, content) in templates {
            let path = vaultRoot.appendingPathComponent("Templates/\(name)")
            if !fm.fileExists(atPath: path.path) {
                try content.write(to: path, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - CRUD Operations

    /// Read a note by its vault-relative path.
    ///
    /// - Parameter relativePath: Path relative to vault root (e.g., "Tasks/active/fix-bug.md")
    /// - Returns: The note content as a string, or nil if not found.
    func readNote(at relativePath: String) -> String? {
        let url = vaultRoot.appendingPathComponent(relativePath)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Write or overwrite a note at a vault-relative path.
    ///
    /// - Parameters:
    ///   - relativePath: Path relative to vault root.
    ///   - content: The markdown content to write.
    func writeNote(at relativePath: String, content: String) throws {
        let url = vaultRoot.appendingPathComponent(relativePath)

        // Ensure parent directory exists
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        try content.write(to: url, atomically: true, encoding: .utf8)
        logger.debug("Wrote note: \(relativePath)")
    }

    /// Append text to an existing note, or create it if it doesn't exist.
    ///
    /// - Parameters:
    ///   - relativePath: Path relative to vault root.
    ///   - text: Text to append (a newline is prepended if the file exists).
    func appendToNote(at relativePath: String, text: String) throws {
        let url = vaultRoot.appendingPathComponent(relativePath)

        if fm.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            let data = "\n\(text)".data(using: .utf8)!
            handle.write(data)
            handle.closeFile()
        } else {
            try writeNote(at: relativePath, content: text)
        }
    }

    /// Delete a note at a vault-relative path.
    ///
    /// - Parameter relativePath: Path relative to vault root.
    /// - Returns: True if the file was deleted, false if it didn't exist.
    @discardableResult
    func deleteNote(at relativePath: String) -> Bool {
        let url = vaultRoot.appendingPathComponent(relativePath)
        do {
            try fm.removeItem(at: url)
            logger.debug("Deleted note: \(relativePath)")
            return true
        } catch {
            return false
        }
    }

    // MARK: - Search

    /// Search notes by content substring (case-insensitive).
    ///
    /// - Parameters:
    ///   - query: The search string.
    ///   - folder: Optional folder to restrict search (e.g., "Tasks/active").
    ///   - limit: Maximum results to return. Default 20.
    /// - Returns: Array of (relativePath, matchingLine) tuples.
    func searchNotes(
        query: String,
        folder: String? = nil,
        limit: Int = 20
    ) -> [(path: String, snippet: String)] {
        let searchRoot: URL
        if let folder = folder {
            searchRoot = vaultRoot.appendingPathComponent(folder)
        } else {
            searchRoot = vaultRoot
        }

        guard let enumerator = fm.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let lowerQuery = query.lowercased()
        var results: [(path: String, snippet: String)] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "md" else { continue }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            let lines = content.components(separatedBy: .newlines)
            for line in lines {
                if line.lowercased().contains(lowerQuery) {
                    let relativePath = fileURL.path
                        .replacingOccurrences(of: vaultRoot.path + "/", with: "")
                    let snippet = String(line.prefix(200))
                    results.append((path: relativePath, snippet: snippet))
                    break // One match per file
                }
            }

            if results.count >= limit { break }
        }

        return results
    }

    /// Search notes by frontmatter tags.
    ///
    /// - Parameters:
    ///   - tag: The tag to search for (without #).
    ///   - folder: Optional folder to restrict search.
    /// - Returns: Array of vault-relative paths that contain the tag.
    func searchByTag(_ tag: String, folder: String? = nil) -> [String] {
        let searchRoot: URL
        if let folder = folder {
            searchRoot = vaultRoot.appendingPathComponent(folder)
        } else {
            searchRoot = vaultRoot
        }

        guard let enumerator = fm.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [String] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "md" else { continue }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            // Check YAML frontmatter tags
            if content.contains("tags:") && content.lowercased().contains(tag.lowercased()) {
                let relativePath = fileURL.path
                    .replacingOccurrences(of: vaultRoot.path + "/", with: "")
                results.append(relativePath)
            }
        }

        return results
    }

    // MARK: - List

    /// List all notes in a vault folder.
    ///
    /// - Parameter folder: Folder relative to vault root (e.g., "Tasks/active").
    /// - Returns: Array of vault-relative paths.
    func listNotes(in folder: String) -> [String] {
        let folderURL = vaultRoot.appendingPathComponent(folder)
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "md" }
            .map { $0.lastPathComponent }
            .sorted()
    }

    // MARK: - Wikilink Resolution

    /// Resolve a [[wikilink]] to a vault-relative file path.
    ///
    /// Searches all .md files in the vault for a matching filename.
    /// Returns the first match (Obsidian convention: filenames are unique).
    ///
    /// - Parameter wikilink: The link text without brackets (e.g., "My Note").
    /// - Returns: The vault-relative path, or nil if not found.
    func resolveWikilink(_ wikilink: String) -> String? {
        let targetName = wikilink.trimmingCharacters(in: .whitespaces)
        let targetFilename = "\(targetName).md"

        guard let enumerator = fm.enumerator(
            at: vaultRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.caseInsensitiveCompare(targetFilename) == .orderedSame {
                return fileURL.path
                    .replacingOccurrences(of: vaultRoot.path + "/", with: "")
            }
        }

        return nil
    }

    // MARK: - Task Helpers

    /// Create a new task note from the template.
    ///
    /// - Parameters:
    ///   - title: Task title (used as filename).
    ///   - description: Task description.
    ///   - priority: Priority level (low/medium/high/urgent).
    ///   - project: Optional project wikilink.
    ///   - tags: Optional tags array.
    /// - Returns: The vault-relative path of the created task.
    @discardableResult
    func createTask(
        title: String,
        description: String,
        priority: String = "medium",
        project: String? = nil,
        tags: [String] = []
    ) throws -> String {
        let dateStr = Self.todayString()
        let sanitizedTitle = Self.sanitizeFilename(title)
        let relativePath = "Tasks/active/\(sanitizedTitle).md"

        let tagsStr = tags.isEmpty ? "[]" : "[\(tags.map { "\"\($0)\"" }.joined(separator: ", "))]"
        let projectStr = project ?? ""

        let content = """
        ---
        status: active
        priority: \(priority)
        created: \(dateStr)
        due:
        tags: \(tagsStr)
        project: \(projectStr)
        ---
        # \(title)

        ## Description
        \(description)

        ## Steps
        - [ ]

        ## Notes

        ## Related
        """

        try writeNote(at: relativePath, content: content)
        return relativePath
    }

    /// Move a task from active to completed.
    ///
    /// - Parameter filename: The task filename (e.g., "fix-bug.md").
    /// - Returns: True if moved successfully.
    @discardableResult
    func completeTask(filename: String) throws -> Bool {
        let sourcePath = "Tasks/active/\(filename)"
        let destPath = "Tasks/completed/\(filename)"

        let sourceURL = vaultRoot.appendingPathComponent(sourcePath)
        let destURL = vaultRoot.appendingPathComponent(destPath)

        guard fm.fileExists(atPath: sourceURL.path) else { return false }

        // Update frontmatter status
        if var content = try? String(contentsOf: sourceURL, encoding: .utf8) {
            content = content.replacingOccurrences(
                of: "status: active",
                with: "status: completed\ncompleted: \(Self.todayString())"
            )
            try content.write(to: sourceURL, atomically: true, encoding: .utf8)
        }

        try fm.moveItem(at: sourceURL, to: destURL)
        logger.info("Completed task: \(filename)")
        return true
    }

    /// Update a task's frontmatter field.
    ///
    /// - Parameters:
    ///   - filename: Task filename.
    ///   - field: Frontmatter field name (e.g., "priority", "due", "status").
    ///   - value: New value for the field.
    func updateTask(filename: String, field: String, value: String) throws {
        let path = "Tasks/active/\(filename)"
        guard var content = readNote(at: path) else { return }

        let pattern = "\(field): .*"
        let replacement = "\(field): \(value)"
        content = content.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: .regularExpression
        )

        try writeNote(at: path, content: content)
    }

    // MARK: - Contact Helpers

    /// Create a new contact note.
    ///
    /// - Parameters:
    ///   - name: Contact name (used as filename).
    ///   - details: Dictionary of detail fields (relationship, email, phone, etc.).
    /// - Returns: The vault-relative path of the created contact.
    @discardableResult
    func createContact(
        name: String,
        details: [String: String] = [:]
    ) throws -> String {
        let dateStr = Self.todayString()
        let sanitizedName = Self.sanitizeFilename(name)
        let relativePath = "Contacts/\(sanitizedName).md"

        var detailLines = ""
        for (key, value) in details.sorted(by: { $0.key < $1.key }) {
            detailLines += "- **\(key.capitalized):** \(value)\n"
        }

        let content = """
        ---
        created: \(dateStr)
        tags: []
        ---
        # \(name)

        ## Details
        \(detailLines.isEmpty ? "- **Relationship:**\n- **Email:**\n- **Phone:**" : detailLines)

        ## Context


        ## Interactions
        - \(dateStr): Initial contact created
        """

        try writeNote(at: relativePath, content: content)
        return relativePath
    }

    /// Append an interaction entry to a contact's note.
    func addContactInteraction(filename: String, interaction: String) throws {
        let path = "Contacts/\(filename)"
        try appendToNote(at: path, text: "- \(Self.todayString()): \(interaction)")
    }

    // MARK: - Journal Helpers

    /// Append an entry to today's journal.
    ///
    /// - Parameters:
    ///   - section: Journal section ("Actions Taken", "Commands Received", "Observations", "Decisions Made", "Follow-ups").
    ///   - entry: The text entry to append.
    func journalAppend(section: String, entry: String) throws {
        let dateStr = Self.todayString()
        let path = "Journal/\(dateStr).md"

        // Create today's journal if it doesn't exist
        if readNote(at: path) == nil {
            let template = """
            ---
            date: \(dateStr)
            ---
            # \(dateStr)

            ## Actions Taken

            ## Commands Received

            ## Observations

            ## Decisions Made

            ## Follow-ups
            """
            try writeNote(at: path, content: template)
        }

        // Read current content and append under the right section
        guard var content = readNote(at: path) else { return }

        let sectionHeader = "## \(section)"
        if let range = content.range(of: sectionHeader) {
            // Find the end of the section header line
            let afterHeader = content[range.upperBound...]
            if let nextNewline = afterHeader.firstIndex(of: "\n") {
                let insertionPoint = content.index(after: nextNewline)
                content.insert(contentsOf: "- \(entry)\n", at: insertionPoint)
            } else {
                content += "\n- \(entry)"
            }
        } else {
            // Section not found, append to end
            content += "\n\n## \(section)\n- \(entry)"
        }

        try writeNote(at: path, content: content)
    }

    // MARK: - File Watching (Optional)

    /// Start watching the vault for external changes.
    /// Calls the callback when any .md file is modified externally.
    func startFileWatching(onChange: @escaping () -> Void) {
        let fd = open(vaultRoot.path, O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("Cannot watch vault directory: open failed")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler {
            onChange()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileWatcher = source
        logger.info("File watching started on vault")
    }

    /// Stop watching the vault for changes.
    func stopFileWatching() {
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    // MARK: - Helpers

    /// Today's date as YYYY-MM-DD string.
    static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Sanitize a string for use as a filename.
    static func sanitizeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        return name
            .components(separatedBy: allowed.inverted)
            .joined()
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
            .prefix(80)
            .description
    }

    // MARK: - Templates (Static)

    static let taskTemplate = """
    ---
    status: active
    priority: medium
    created: {{date}}
    due:
    tags: []
    project:
    ---
    # {{title}}

    ## Description

    ## Steps
    - [ ]

    ## Notes

    ## Related
    """

    static let contactTemplate = """
    ---
    created: {{date}}
    tags: []
    ---
    # {{name}}

    ## Details
    - **Relationship:**
    - **Email:**
    - **Phone:**

    ## Context

    ## Interactions
    - {{date}}: Initial contact
    """

    static let projectTemplate = """
    ---
    status: active
    created: {{date}}
    tags: []
    ---
    # {{title}}

    ## Overview

    ## Goals

    ## Tasks
    - [[]]

    ## Notes

    ## Related
    """

    static let journalTemplate = """
    ---
    date: {{date}}
    ---
    # {{date}}

    ## Actions Taken

    ## Commands Received

    ## Observations

    ## Decisions Made

    ## Follow-ups
    """
}
```

---

## 4. OpenClaw Bridge Design

### 4.1 Architecture

```
                    ┌──────────────┐
                    │  Telegram /  │
                    │  WhatsApp /  │
                    │  Discord ... │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │   OpenClaw   │
                    │   Gateway    │
                    │  (Node.js)   │
                    └──────┬───────┘
                           │  CLI calls
                    ┌──────▼───────────┐
                    │ OpenClawBridge   │
                    │   (Swift actor)  │
                    │                  │
                    │ - poll for msgs  │
                    │ - send responses │
                    │ - manage channels│
                    └──────┬───────────┘
                           │
                    ┌──────▼───────┐
                    │ CommandGateway│
                    │  .submit()   │
                    └──────────────┘
```

### 4.2 OpenClawBridge Actor

```swift
// OmniAgent/Services/OpenClawBridge.swift

import Foundation
import os.log

private let logger = Logger(subsystem: "com.omniagent.app", category: "OpenClawBridge")

/// Bridge between OmniAgent and the OpenClaw messaging platform.
///
/// OpenClaw is a Node.js gateway that connects to Telegram, WhatsApp,
/// Discord, Slack, Signal, iMessage, and other messaging platforms.
/// This actor wraps the `openclaw` CLI to send messages, read incoming
/// commands, and manage channel configuration.
///
/// Commands from OpenClaw are submitted to the CommandGateway with
/// source `.openClaw` and a dedicated OpenClawReplyChannel.
actor OpenClawBridge {

    // MARK: - Singleton

    static let shared = OpenClawBridge()

    // MARK: - Configuration

    struct Config {
        /// Path to the openclaw CLI binary.
        var cliPath: String = "/Users/suede/.nvm/versions/node/v25.1.0/bin/openclaw"

        /// Poll interval for checking new messages (seconds).
        var pollInterval: TimeInterval = 5.0

        /// Maximum message age to process (seconds). Ignore messages older than this.
        var maxMessageAge: TimeInterval = 300 // 5 minutes

        /// Channels to listen on. Each entry is (channel, target).
        /// Example: [("telegram", "@mybot"), ("whatsapp", "+15555550123")]
        var listeners: [(channel: String, target: String)] = []
    }

    private var config = Config()

    /// Whether the polling loop is active.
    private var isPolling = false

    /// The last message ID seen per (channel, target) pair, to avoid re-processing.
    private var lastSeenMessageIds: [String: String] = [:]

    /// Reference to the CommandGateway for submitting incoming commands.
    private weak var commandGateway: CommandGateway?

    private init() {}

    // MARK: - Setup

    /// Configure the bridge and start listening.
    ///
    /// - Parameters:
    ///   - gateway: The CommandGateway to submit incoming commands to.
    ///   - config: Bridge configuration.
    func start(gateway: CommandGateway, config: Config? = nil) {
        if let config = config {
            self.config = config
        }
        self.commandGateway = gateway
        isPolling = true
        logger.info("OpenClawBridge started with \(self.config.listeners.count) listeners")

        // Start polling loop
        Task { [weak self] in
            await self?.pollLoop()
        }
    }

    /// Stop the polling loop.
    func stop() {
        isPolling = false
        logger.info("OpenClawBridge stopped")
    }

    // MARK: - Send Message

    /// Send a text message through OpenClaw.
    ///
    /// - Parameters:
    ///   - channel: Platform name (telegram, whatsapp, discord, etc.)
    ///   - target: Recipient identifier (chat ID, phone number, channel ID, etc.)
    ///   - message: The message text to send.
    ///   - media: Optional local file path or URL for media attachment.
    /// - Returns: The CLI output (for logging/debugging).
    @discardableResult
    func sendMessage(
        channel: String,
        target: String,
        message: String,
        media: String? = nil
    ) async throws -> String {
        var args = [
            "message", "send",
            "--channel", channel,
            "--target", target,
            "--message", message,
            "--json"
        ]

        if let media = media {
            args.append(contentsOf: ["--media", media])
        }

        let result = try await runCLI(args)
        logger.info("Sent message to \(channel):\(target) — \(result.isSuccess ? "OK" : "FAIL")")
        return result.stdout
    }

    // MARK: - Read Messages

    /// Read recent messages from a channel.
    ///
    /// - Parameters:
    ///   - channel: Platform name.
    ///   - target: Chat/channel identifier.
    ///   - limit: Maximum messages to retrieve.
    ///   - afterId: Only return messages after this ID.
    /// - Returns: Array of parsed messages.
    func readMessages(
        channel: String,
        target: String,
        limit: Int = 10,
        afterId: String? = nil
    ) async throws -> [OpenClawMessage] {
        var args = [
            "message", "read",
            "--channel", channel,
            "--target", target,
            "--limit", String(limit),
            "--json"
        ]

        if let afterId = afterId {
            args.append(contentsOf: ["--after", afterId])
        }

        let result = try await runCLI(args)
        guard result.isSuccess else {
            throw OpenClawError.readFailed(result.stderr)
        }

        return parseMessages(result.stdout)
    }

    // MARK: - Channel Management

    /// List configured channels.
    func listChannels() async throws -> String {
        let result = try await runCLI(["channels", "list", "--json"])
        return result.stdout
    }

    /// Check channel status.
    func channelStatus() async throws -> String {
        let result = try await runCLI(["channels", "status"])
        return result.stdout
    }

    /// Check gateway health.
    func gatewayHealth() async throws -> String {
        let result = try await runCLI(["health"])
        return result.stdout
    }

    // MARK: - Polling Loop

    /// Main polling loop that checks for new messages on all configured listeners.
    private func pollLoop() async {
        while isPolling {
            for (channel, target) in config.listeners {
                do {
                    let key = "\(channel):\(target)"
                    let messages = try await readMessages(
                        channel: channel,
                        target: target,
                        limit: 5,
                        afterId: lastSeenMessageIds[key]
                    )

                    for msg in messages {
                        // Update last seen ID
                        lastSeenMessageIds[key] = msg.id

                        // Skip if the message is from the bot itself
                        if msg.isFromBot { continue }

                        // Skip stale messages
                        if let timestamp = msg.timestamp,
                           Date().timeIntervalSince(timestamp) > config.maxMessageAge {
                            continue
                        }

                        // Submit to CommandGateway
                        await submitCommand(from: msg, channel: channel, target: target)
                    }
                } catch {
                    logger.error("Poll error for \(channel):\(target) — \(error.localizedDescription)")
                }
            }

            try? await Task.sleep(nanoseconds: UInt64(config.pollInterval * 1_000_000_000))
        }
    }

    /// Submit an incoming OpenClaw message as a Command to the gateway.
    private func submitCommand(
        from message: OpenClawMessage,
        channel: String,
        target: String
    ) async {
        guard let gateway = commandGateway else {
            logger.warning("No CommandGateway set, dropping message from \(channel)")
            return
        }

        let replyChannel = OpenClawReplyChannel(
            bridge: self,
            channel: channel,
            target: target
        )

        let command = Command(
            text: message.text,
            source: .openClaw,
            replyChannel: replyChannel
        )

        await gateway.submit(command)
    }

    // MARK: - CLI Execution

    /// Run the openclaw CLI with the given arguments.
    private func runCLI(_ arguments: [String]) async throws -> CLIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.cliPath)
        process.arguments = arguments

        // Inherit environment for Node.js/npm path resolution
        var env = ProcessInfo.processInfo.environment
        // Ensure nvm paths are available
        if let path = env["PATH"] {
            env["PATH"] = "/Users/suede/.nvm/versions/node/v25.1.0/bin:\(path)"
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: OpenClawError.launchFailed(error.localizedDescription))
                return
            }

            process.terminationHandler = { _ in
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: CLIResult(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: process.terminationStatus
                ))
            }
        }
    }

    // MARK: - Message Parsing

    /// Parse JSON output from `openclaw message read --json` into message structs.
    private func parseMessages(_ json: String) -> [OpenClawMessage] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let text = dict["text"] as? String ?? dict["body"] as? String else {
                return nil
            }

            let isFromBot = dict["fromBot"] as? Bool ?? dict["isBot"] as? Bool ?? false
            var timestamp: Date?
            if let ts = dict["timestamp"] as? TimeInterval {
                timestamp = Date(timeIntervalSince1970: ts)
            } else if let ts = dict["timestamp"] as? String {
                let formatter = ISO8601DateFormatter()
                timestamp = formatter.date(from: ts)
            }

            return OpenClawMessage(
                id: id,
                text: text,
                sender: dict["sender"] as? String ?? dict["from"] as? String,
                isFromBot: isFromBot,
                timestamp: timestamp
            )
        }
    }

    // MARK: - Types

    struct CLIResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        var isSuccess: Bool { exitCode == 0 }
    }
}

// MARK: - OpenClawMessage

struct OpenClawMessage: Sendable {
    let id: String
    let text: String
    let sender: String?
    let isFromBot: Bool
    let timestamp: Date?
}

// MARK: - OpenClawError

enum OpenClawError: LocalizedError {
    case launchFailed(String)
    case readFailed(String)
    case sendFailed(String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .launchFailed(let msg): return "OpenClaw launch failed: \(msg)"
        case .readFailed(let msg): return "OpenClaw read failed: \(msg)"
        case .sendFailed(let msg): return "OpenClaw send failed: \(msg)"
        case .notConfigured: return "OpenClaw is not configured. Run `openclaw configure` first."
        }
    }
}

// MARK: - OpenClawReplyChannel

/// ReplyChannel implementation that sends responses back through OpenClaw.
final class OpenClawReplyChannel: ReplyChannel, @unchecked Sendable {

    private let bridge: OpenClawBridge
    private let channel: String
    private let target: String

    init(bridge: OpenClawBridge, channel: String, target: String) {
        self.bridge = bridge
        self.channel = channel
        self.target = target
    }

    func sendText(_ text: String) async {
        do {
            try await bridge.sendMessage(
                channel: channel,
                target: target,
                message: text
            )
        } catch {
            NSLog("OpenClawReplyChannel: Failed to send text: %@", error.localizedDescription)
        }
    }

    func sendScreenshot(_ data: Data) async {
        // Write screenshot to temp file and send as media
        let tempPath = NSTemporaryDirectory() + "omniagent_screenshot_\(UUID().uuidString).jpg"
        let tempURL = URL(fileURLWithPath: tempPath)
        do {
            try data.write(to: tempURL)
            try await bridge.sendMessage(
                channel: channel,
                target: target,
                message: "Screenshot",
                media: tempPath
            )
            try? FileManager.default.removeItem(at: tempURL)
        } catch {
            NSLog("OpenClawReplyChannel: Failed to send screenshot: %@", error.localizedDescription)
        }
    }

    func requestApproval(_ prompt: String) async -> Bool {
        // Send the approval prompt to the remote user
        do {
            try await bridge.sendMessage(
                channel: channel,
                target: target,
                message: "Approval needed: \(prompt)\n\nReply 'yes' to approve or 'no' to deny."
            )
        } catch {
            return false
        }

        // Poll for response (simplified — production should use a callback/webhook)
        for _ in 0..<60 {  // Wait up to 5 minutes (60 * 5s)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            do {
                let messages = try await bridge.readMessages(
                    channel: channel,
                    target: target,
                    limit: 3
                )
                for msg in messages {
                    let lower = msg.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if lower == "yes" || lower == "approve" || lower == "y" {
                        return true
                    }
                    if lower == "no" || lower == "deny" || lower == "n" {
                        return false
                    }
                }
            } catch {
                continue
            }
        }

        return false // Timeout — default deny
    }
}
```

### 4.3 OpenClaw as Agent Tools

**Decision: YES, OpenClaw commands should be exposed as agent tools.**

The agent needs to proactively send messages (e.g., "notify me when the build finishes") and check messages. These should be tools Claude can call, not just passive infrastructure.

---

## 5. New Tool Definitions

All new tools follow the existing pattern in `ToolDefinitions.swift`. Add these to the `static let tools` array:

### 5.1 Vault Tools

```swift
// ── Vault Read ──
[
    "name": "vault_read",
    "description": "Read a note from the OmniAgent Obsidian vault. Returns the full markdown content. Use vault-relative paths like 'Tasks/active/fix-bug.md' or 'Memory/Preferences.md'.",
    "input_schema": [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Vault-relative path to the note (e.g., 'Journal/2026-02-20.md', 'Contacts/john-doe.md')"
            ]
        ],
        "required": ["path"]
    ] as [String: Any]
],

// ── Vault Write ──
[
    "name": "vault_write",
    "description": "Write or overwrite a note in the OmniAgent Obsidian vault. Creates parent directories if needed. Use [[wikilinks]] to connect notes.",
    "input_schema": [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Vault-relative path for the note (e.g., 'Tasks/active/new-task.md')"
            ],
            "content": [
                "type": "string",
                "description": "Full markdown content to write"
            ]
        ],
        "required": ["path", "content"]
    ] as [String: Any]
],

// ── Vault Search ──
[
    "name": "vault_search",
    "description": "Search notes in the OmniAgent Obsidian vault by content. Returns matching file paths and snippets. Optionally restrict to a folder.",
    "input_schema": [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "Search text (case-insensitive substring match)"
            ],
            "folder": [
                "type": "string",
                "description": "Optional folder to restrict search (e.g., 'Tasks/active', 'Contacts', 'Memory')"
            ],
            "limit": [
                "type": "integer",
                "description": "Maximum results to return. Default 20."
            ]
        ],
        "required": ["query"]
    ] as [String: Any]
],

// ── Vault List ──
[
    "name": "vault_list",
    "description": "List all notes in a vault folder. Returns filenames sorted alphabetically.",
    "input_schema": [
        "type": "object",
        "properties": [
            "folder": [
                "type": "string",
                "description": "Vault folder to list (e.g., 'Tasks/active', 'Tasks/completed', 'Contacts', 'Journal', 'Memory')"
            ]
        ],
        "required": ["folder"]
    ] as [String: Any]
],

// ── Task Create ──
[
    "name": "task_create",
    "description": "Create a new task in the Obsidian vault. The task is created in Tasks/active/ with YAML frontmatter.",
    "input_schema": [
        "type": "object",
        "properties": [
            "title": [
                "type": "string",
                "description": "Task title (used as filename)"
            ],
            "description": [
                "type": "string",
                "description": "Task description"
            ],
            "priority": [
                "type": "string",
                "description": "Priority: low, medium, high, or urgent. Default: medium."
            ],
            "project": [
                "type": "string",
                "description": "Optional project name (creates a wikilink)"
            ],
            "tags": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Optional tags for categorization"
            ]
        ],
        "required": ["title", "description"]
    ] as [String: Any]
],

// ── Task Update ──
[
    "name": "task_update",
    "description": "Update a task's frontmatter field (status, priority, due date, etc.).",
    "input_schema": [
        "type": "object",
        "properties": [
            "filename": [
                "type": "string",
                "description": "Task filename in Tasks/active/ (e.g., 'fix-bug.md')"
            ],
            "field": [
                "type": "string",
                "description": "Frontmatter field to update (e.g., 'priority', 'due', 'status')"
            ],
            "value": [
                "type": "string",
                "description": "New value for the field"
            ]
        ],
        "required": ["filename", "field", "value"]
    ] as [String: Any]
],

// ── Task Complete ──
[
    "name": "task_complete",
    "description": "Mark a task as completed. Moves it from Tasks/active/ to Tasks/completed/ and sets completion date.",
    "input_schema": [
        "type": "object",
        "properties": [
            "filename": [
                "type": "string",
                "description": "Task filename to complete (e.g., 'fix-bug.md')"
            ]
        ],
        "required": ["filename"]
    ] as [String: Any]
],

// ── Contact Create ──
[
    "name": "contact_create",
    "description": "Create a new contact in the Obsidian vault. Stored in Contacts/ with details and interaction history.",
    "input_schema": [
        "type": "object",
        "properties": [
            "name": [
                "type": "string",
                "description": "Contact's name (used as filename)"
            ],
            "relationship": [
                "type": "string",
                "description": "Relationship description (e.g., 'colleague', 'friend', 'client')"
            ],
            "email": [
                "type": "string",
                "description": "Email address"
            ],
            "phone": [
                "type": "string",
                "description": "Phone number"
            ],
            "notes": [
                "type": "string",
                "description": "Additional context about this person"
            ]
        ],
        "required": ["name"]
    ] as [String: Any]
],

// ── Contact Update ──
[
    "name": "contact_update",
    "description": "Add an interaction entry to a contact's note, recording when and what happened.",
    "input_schema": [
        "type": "object",
        "properties": [
            "filename": [
                "type": "string",
                "description": "Contact filename (e.g., 'john-doe.md')"
            ],
            "interaction": [
                "type": "string",
                "description": "Description of the interaction"
            ]
        ],
        "required": ["filename", "interaction"]
    ] as [String: Any]
],

// ── Journal Append ──
[
    "name": "journal_append",
    "description": "Append an entry to today's journal in the Obsidian vault. Creates today's journal if it doesn't exist.",
    "input_schema": [
        "type": "object",
        "properties": [
            "section": [
                "type": "string",
                "description": "Journal section: 'Actions Taken', 'Commands Received', 'Observations', 'Decisions Made', or 'Follow-ups'"
            ],
            "entry": [
                "type": "string",
                "description": "The text entry to append"
            ]
        ],
        "required": ["section", "entry"]
    ] as [String: Any]
],
```

### 5.2 OpenClaw Tools

```swift
// ── OpenClaw Send Message ──
[
    "name": "openclaw_send",
    "description": "Send a message through OpenClaw to a messaging platform (Telegram, WhatsApp, Discord, Slack, Signal, iMessage, etc.).",
    "input_schema": [
        "type": "object",
        "properties": [
            "channel": [
                "type": "string",
                "description": "Platform: telegram, whatsapp, discord, slack, signal, imessage"
            ],
            "target": [
                "type": "string",
                "description": "Recipient: E.164 phone for WhatsApp/Signal, chat ID for Telegram, channel/user for Discord/Slack"
            ],
            "message": [
                "type": "string",
                "description": "Message text to send"
            ],
            "media": [
                "type": "string",
                "description": "Optional: local file path or URL for media attachment"
            ]
        ],
        "required": ["channel", "target", "message"]
    ] as [String: Any]
],

// ── OpenClaw Read Messages ──
[
    "name": "openclaw_read",
    "description": "Read recent messages from a messaging platform through OpenClaw.",
    "input_schema": [
        "type": "object",
        "properties": [
            "channel": [
                "type": "string",
                "description": "Platform: telegram, whatsapp, discord, slack, signal, imessage"
            ],
            "target": [
                "type": "string",
                "description": "Chat/channel to read from"
            ],
            "limit": [
                "type": "integer",
                "description": "Maximum messages to return. Default 10."
            ]
        ],
        "required": ["channel", "target"]
    ] as [String: Any]
],

// ── OpenClaw Status ──
[
    "name": "openclaw_status",
    "description": "Check OpenClaw gateway health and channel connection status.",
    "input_schema": [
        "type": "object",
        "properties": [:] as [String: Any],
        "required": [] as [String]
    ] as [String: Any]
],
```

---

## 6. Permission Tier Assignments

| Tool | Tier | Rationale |
|------|------|-----------|
| `vault_read` | Tier 1 | Read-only, local file |
| `vault_write` | Tier 2 (file_writes) | Creates/modifies local files |
| `vault_search` | Tier 1 | Read-only search |
| `vault_list` | Tier 1 | Read-only listing |
| `task_create` | Tier 2 (file_writes) | Creates a file |
| `task_update` | Tier 2 (file_writes) | Modifies a file |
| `task_complete` | Tier 2 (file_writes) | Moves a file |
| `contact_create` | Tier 2 (file_writes) | Creates a file |
| `contact_update` | Tier 2 (file_writes) | Modifies a file |
| `journal_append` | Tier 2 (file_writes) | Modifies a file |
| `openclaw_send` | Tier 2 (network_access) | Sends data externally |
| `openclaw_read` | Tier 2 (network_access) | Reads from external service |
| `openclaw_status` | Tier 1 | Read-only health check |

**Note:** In `autonomous` permission mode, all Tier 2 operations auto-approve after the first session approval. This means the agent can freely manage its vault and send messages without repeated confirmation once the user has approved the categories.

---

## 7. Tool Execution in ActionExecutor

The new tools need execution handlers in the `AgentLoop.executeIteration()` tool dispatch. Here's the pattern:

```swift
// In AgentLoop's tool dispatch switch (inside executeIteration):

case "vault_read":
    let path = input["path"] as? String ?? ""
    let obsidian = ObsidianService.shared
    if let content = await obsidian.readNote(at: path) {
        toolResult = content
    } else {
        toolResult = "Error: Note not found at \(path)"
    }

case "vault_write":
    let path = input["path"] as? String ?? ""
    let content = input["content"] as? String ?? ""
    let obsidian = ObsidianService.shared
    do {
        try await obsidian.writeNote(at: path, content: content)
        toolResult = "Note written to \(path)"
    } catch {
        toolResult = "Error writing note: \(error.localizedDescription)"
    }

case "vault_search":
    let query = input["query"] as? String ?? ""
    let folder = input["folder"] as? String
    let limit = input["limit"] as? Int ?? 20
    let obsidian = ObsidianService.shared
    let results = await obsidian.searchNotes(query: query, folder: folder, limit: limit)
    if results.isEmpty {
        toolResult = "No results found for '\(query)'"
    } else {
        toolResult = results.map { "- \($0.path): \($0.snippet)" }.joined(separator: "\n")
    }

case "vault_list":
    let folder = input["folder"] as? String ?? ""
    let obsidian = ObsidianService.shared
    let files = await obsidian.listNotes(in: folder)
    toolResult = files.isEmpty ? "No notes in \(folder)" : files.joined(separator: "\n")

case "task_create":
    let title = input["title"] as? String ?? "Untitled"
    let desc = input["description"] as? String ?? ""
    let priority = input["priority"] as? String ?? "medium"
    let project = input["project"] as? String
    let tags = input["tags"] as? [String] ?? []
    let obsidian = ObsidianService.shared
    do {
        let path = try await obsidian.createTask(
            title: title, description: desc,
            priority: priority, project: project, tags: tags
        )
        toolResult = "Task created: \(path)"
    } catch {
        toolResult = "Error creating task: \(error.localizedDescription)"
    }

case "task_update":
    let filename = input["filename"] as? String ?? ""
    let field = input["field"] as? String ?? ""
    let value = input["value"] as? String ?? ""
    let obsidian = ObsidianService.shared
    do {
        try await obsidian.updateTask(filename: filename, field: field, value: value)
        toolResult = "Task updated: \(filename) — \(field) = \(value)"
    } catch {
        toolResult = "Error updating task: \(error.localizedDescription)"
    }

case "task_complete":
    let filename = input["filename"] as? String ?? ""
    let obsidian = ObsidianService.shared
    do {
        let moved = try await obsidian.completeTask(filename: filename)
        toolResult = moved ? "Task completed: \(filename)" : "Task not found: \(filename)"
    } catch {
        toolResult = "Error completing task: \(error.localizedDescription)"
    }

case "contact_create":
    let name = input["name"] as? String ?? "Unknown"
    var details: [String: String] = [:]
    if let rel = input["relationship"] as? String { details["relationship"] = rel }
    if let email = input["email"] as? String { details["email"] = email }
    if let phone = input["phone"] as? String { details["phone"] = phone }
    if let notes = input["notes"] as? String { details["notes"] = notes }
    let obsidian = ObsidianService.shared
    do {
        let path = try await obsidian.createContact(name: name, details: details)
        toolResult = "Contact created: \(path)"
    } catch {
        toolResult = "Error creating contact: \(error.localizedDescription)"
    }

case "contact_update":
    let filename = input["filename"] as? String ?? ""
    let interaction = input["interaction"] as? String ?? ""
    let obsidian = ObsidianService.shared
    do {
        try await obsidian.addContactInteraction(filename: filename, interaction: interaction)
        toolResult = "Interaction added to \(filename)"
    } catch {
        toolResult = "Error updating contact: \(error.localizedDescription)"
    }

case "journal_append":
    let section = input["section"] as? String ?? "Actions Taken"
    let entry = input["entry"] as? String ?? ""
    let obsidian = ObsidianService.shared
    do {
        try await obsidian.journalAppend(section: section, entry: entry)
        toolResult = "Journal entry added to '\(section)'"
    } catch {
        toolResult = "Error appending to journal: \(error.localizedDescription)"
    }

case "openclaw_send":
    let channel = input["channel"] as? String ?? ""
    let target = input["target"] as? String ?? ""
    let message = input["message"] as? String ?? ""
    let media = input["media"] as? String
    let bridge = OpenClawBridge.shared
    do {
        let result = try await bridge.sendMessage(
            channel: channel, target: target,
            message: message, media: media
        )
        toolResult = "Message sent to \(channel):\(target)"
    } catch {
        toolResult = "Error sending message: \(error.localizedDescription)"
    }

case "openclaw_read":
    let channel = input["channel"] as? String ?? ""
    let target = input["target"] as? String ?? ""
    let limit = input["limit"] as? Int ?? 10
    let bridge = OpenClawBridge.shared
    do {
        let messages = try await bridge.readMessages(
            channel: channel, target: target, limit: limit
        )
        if messages.isEmpty {
            toolResult = "No recent messages"
        } else {
            toolResult = messages.map { msg in
                let sender = msg.sender ?? "unknown"
                return "[\(sender)] \(msg.text)"
            }.joined(separator: "\n")
        }
    } catch {
        toolResult = "Error reading messages: \(error.localizedDescription)"
    }

case "openclaw_status":
    let bridge = OpenClawBridge.shared
    do {
        let health = try await bridge.gatewayHealth()
        let channels = try await bridge.channelStatus()
        toolResult = "Gateway: \(health)\nChannels: \(channels)"
    } catch {
        toolResult = "OpenClaw status check failed: \(error.localizedDescription)"
    }
```

---

## 8. System Prompt Additions

Add this to `ToolDefinitions.systemPrompt`:

```
## Memory & Vault
You have an Obsidian vault at ~/Documents/Obsidian Vault/OmniAgent-Brain/ for persistent memory.
Use it proactively:
- Before starting any task, check if there's relevant context in the vault (search Memory/, check Tasks/)
- After completing tasks, log what you did in the journal
- When you learn user preferences, save them to Memory/Preferences.md
- When you meet new people or receive contact info, create a Contact
- When given multi-step work, create a Task to track progress
- Use [[wikilinks]] to connect related notes

## Messaging (OpenClaw)
You can send and receive messages through OpenClaw to platforms like Telegram, WhatsApp, Discord, etc.
- Use openclaw_send to notify the user or respond to remote commands
- Use openclaw_read to check for new messages
- Use openclaw_status to verify connectivity
- When a command arrives from OpenClaw, results are automatically sent back through the same channel
```

---

## 9. Startup Integration

In `OmniAgentApp.swift` or `AppDelegate.swift`, add vault and OpenClaw initialization:

```swift
// During app startup (after existing initialization):

// 1. Initialize Obsidian vault
Task {
    let obsidian = ObsidianService.shared
    do {
        try await obsidian.ensureVault()
    } catch {
        NSLog("OmniAgent: Failed to initialize vault: %@", error.localizedDescription)
    }
}

// 2. Start OpenClaw bridge (if channels are configured)
Task {
    let bridge = OpenClawBridge.shared
    var config = OpenClawBridge.Config()
    // TODO: Load listeners from user preferences or OpenClaw config
    // config.listeners = [("telegram", "@my_chat_id")]
    await bridge.start(gateway: commandGateway, config: config)
}
```

---

## 10. Open Questions & Recommendations

### 10.1 OpenClaw Gateway vs CLI Polling

**Current design:** Poll via `openclaw message read` CLI calls every 5 seconds.

**Recommended improvement:** OpenClaw supports a gateway daemon (`openclaw gateway`). In a future sprint, switch to:
- Run `openclaw gateway` as a background process
- Use the gateway's webhook/HTTP endpoint for real-time message delivery instead of polling
- This eliminates the 5-second latency and reduces CLI process spawning

### 10.2 Vault Conflict Resolution

If Obsidian is open simultaneously, both OmniAgent and the user could edit the same note. The current design uses atomic file writes (`atomically: true`), which prevents corruption but doesn't merge changes.

**Recommendation:** For now, last-write-wins is acceptable. Add a `.obsidian/` folder check — if Obsidian is running, prefer appending over overwriting. The optional file watcher can detect external edits.

### 10.3 Search Performance

For vaults with thousands of notes, the linear `enumerator` search will be slow.

**Recommendation:** Add a SQLite-backed index in a future sprint (similar to what Obsidian itself does). For MVP, the file-walking search is fine — the vault will be small initially.

### 10.4 No Channels Configured

OpenClaw currently has **no channels configured** (`openclaw channels list` shows none). Before the bridge is useful, the user needs to run:

```bash
# Example: Add a Telegram bot
openclaw channels add --channel telegram --token BOT_TOKEN_HERE

# Example: Add WhatsApp
openclaw channels add --channel whatsapp
```

**Recommendation:** The `openclaw_status` tool should detect this and tell Claude, so Claude can guide the user through setup.

### 10.5 CLI Path Hardcoding

The OpenClaw CLI path is currently hardcoded to the nvm path.

**Recommendation:** Resolve the path dynamically:
```swift
// Use which to find openclaw
let whichResult = try await executeProcess("which openclaw", timeout: 5)
config.cliPath = whichResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
```

---

## 11. Implementation Priority

| Priority | Component | Effort | Dependencies |
|----------|-----------|--------|-------------|
| **P0** | ObsidianService actor | 1 sprint | None |
| **P0** | Vault tool definitions + execution | 1 sprint | ObsidianService |
| **P0** | System prompt additions | Included with tools | Tool definitions |
| **P1** | OpenClawBridge actor | 1 sprint | None |
| **P1** | OpenClaw tool definitions + execution | 1 sprint | OpenClawBridge |
| **P1** | OpenClawReplyChannel | Included with bridge | CommandGateway (exists) |
| **P2** | Vault file watching | 0.5 sprint | ObsidianService |
| **P2** | Gateway webhook (replacing polling) | 1 sprint | OpenClawBridge |
| **P2** | SQLite search index | 1 sprint | ObsidianService |

**Recommended approach:** Implement ObsidianService + vault tools first (P0), then OpenClaw integration (P1). The agent gains persistent memory immediately, and messaging follows.

---

## 12. File Summary

New files to create:

| File | Type | Description |
|------|------|-------------|
| `OmniAgent/Services/ObsidianService.swift` | Actor | All Obsidian vault I/O |
| `OmniAgent/Services/OpenClawBridge.swift` | Actor | OpenClaw CLI wrapper + polling |

Files to modify:

| File | Changes |
|------|---------|
| `OmniAgent/Agent/ToolDefinitions.swift` | Add 12 new tool schemas + system prompt additions |
| `OmniAgent/Agent/AgentLoop.swift` | Add tool execution dispatch for 12 new tools |
| `OmniAgent/Agent/CommandGateway.swift` | No changes needed (already supports .openClaw) |
| `OmniAgent/Services/PermissionClassifier.swift` | No changes needed (existing tiers cover new tools) |
| `OmniAgent/App/AppDelegate.swift` or `OmniAgentApp.swift` | Add startup initialization for vault + bridge |
