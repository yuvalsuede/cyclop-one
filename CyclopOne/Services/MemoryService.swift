import Foundation

// MARK: - MemoryService

/// The agent's persistent memory — a markdown vault backed service that provides
/// episodic, semantic, procedural, and working memory across runs.
///
/// Vault location: ~/.cyclopone/memory/
///
/// Memory types:
///   - **Episodic** (tasks/task-log.md): What happened — run outcomes, durations, scores
///   - **Semantic** (knowledge/apps/, Memory/): What we know — app knowledge, facts, preferences
///   - **Procedural** (tasks/task-templates/): How to do things — reusable action sequences
///   - **Working** (context/recent-actions.md): Current context — rolling window of recent actions
///
/// The vault is stored as plain markdown files that users can browse and edit
/// with any text editor or Obsidian. All I/O is serialised through this actor.
actor MemoryService {

    // MARK: - Singleton

    static let shared = MemoryService()

    // MARK: - Properties

    /// Root path of the Obsidian vault.
    let vaultRoot: URL

    /// FileManager instance for all I/O.
    private let fm = FileManager.default

    /// Token-to-character ratio for budget estimation (~4 chars per token).
    private let tokenCharRatio = 4.0

    /// Default memory token budget for system prompt injection.
    private let defaultTokenBudget = 6000

    /// Core files that are always loaded into the system prompt.
    private let coreFiles = [
        "identity/user-profile.md",
        "Current Status.md",
        "Active Tasks.md"
    ]

    /// Stop words excluded from keyword extraction.
    private let stopWords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "shall", "can", "to", "of", "in", "for",
        "on", "with", "at", "by", "from", "it", "this", "that", "my", "your",
        "me", "i", "and", "or", "but", "not", "please", "open", "go", "the"
    ]

    // MARK: - Init

    private init() {
        // Store memory as plain markdown files in ~/.cyclopone/memory/
        // Users can browse/edit with any text editor or Obsidian.
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.vaultRoot = home
            .appendingPathComponent(".cyclopone")
            .appendingPathComponent("memory")
    }

    // MARK: - Vault Bootstrap

    /// Create the vault directory structure and seed files if they don't exist.
    /// Call once at app startup.
    func bootstrap() {
        let dirs = [
            "",
            "identity",
            "tasks", "tasks/active", "tasks/completed", "tasks/task-templates",
            "knowledge", "knowledge/apps",
            "learning",
            "context",
            "Contacts",
            "Projects",
            "Journal",
            "Memory",
            "Daily",
            "Templates"
        ]

        for dir in dirs {
            let url = vaultRoot.appendingPathComponent(dir)
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url, withIntermediateDirectories: true)
                NSLog("MemoryService: Created directory: %@", dir.isEmpty ? "(vault root)" : dir)
            }
        }

        // Seed core files
        ensureFile("identity/user-profile.md", default: """
        ---
        type: user-profile
        updated: \(Self.todayString())
        ---
        # User Profile

        _No profile yet. Will be learned over time._
        """)

        ensureFile("identity/preferences.md", default: """
        # Preferences

        _No preferences recorded yet._
        """)

        ensureFile("Active Tasks.md", default: """
        # Active Tasks

        _No tasks yet._
        """)

        ensureFile("Current Status.md", default: """
        # Current Status

        **Last active:** Never
        **Last command:** None
        **Last outcome:** N/A
        """)

        ensureFile("Known Issues.md", default: """
        # Known Issues

        _No known issues recorded yet._
        """)

        ensureFile("tasks/task-log.md", default: "# Task Log\n\n")
        ensureFile("learning/failures.md", default: "# Failure Log\n\n")
        ensureFile("learning/corrections.md", default: "# User Corrections\n\n")
        ensureFile("learning/patterns.md", default: "# Learned Patterns\n\n")
        ensureFile("context/recent-actions.md", default: "# Recent Actions\n\n")
        ensureFile("context/daily-summary.md", default: "# Daily Summary\n\n")
        ensureFile("Memory/preference.md", default: "# Preferences\n\n")
        ensureFile("Memory/fact.md", default: "# Facts\n\n")
        ensureFile("Memory/pattern.md", default: "# Patterns\n\n")

        // Index page
        ensureFile("Index.md", default: """
        # Cyclop One Memory

        Welcome to Cyclop One's persistent memory vault.

        ## Quick Links
        - [[Active Tasks]] — Current task list
        - [[Current Status]] — Latest agent state
        - [[Known Issues]] — Bugs and failure patterns
        - [[identity/user-profile]] — User profile and preferences
        - [[tasks/task-log]] — Chronological run history
        - [[learning/failures]] — What went wrong and how to avoid it
        - [[learning/patterns]] — Recurring patterns
        - [[context/recent-actions]] — Last significant actions

        ## Recent Activity
        _Updated automatically by Cyclop One_
        """)

        // Install templates
        ensureFile("Templates/task.md", default: Self.taskTemplate)
        ensureFile("Templates/contact.md", default: Self.contactTemplate)
        ensureFile("Templates/journal.md", default: Self.journalTemplate)

        NSLog("MemoryService: Vault bootstrapped at %@", vaultRoot.path)
    }

    // MARK: - Pre-Run Memory Loading

    /// Load core context that is always included in the system prompt.
    /// Contains user profile, active tasks, and current status (~500 tokens).
    func loadCoreContext() -> String {
        var sections: [String] = []

        for file in coreFiles {
            if let content = readFile(file) {
                let trimmed = String(content.prefix(4000))
                let label = file
                    .replacingOccurrences(of: ".md", with: "")
                    .replacingOccurrences(of: "identity/", with: "")
                sections.append("### \(label)\n\(trimmed)")
            }
        }

        // Include today's daily note if it exists
        let todayPath = dailyNotePath()
        if let content = readFile(todayPath) {
            let tail = String(content.suffix(1000))
            sections.append("### Today's Notes\n\(tail)")
        }

        return sections.joined(separator: "\n\n")
    }

    /// Retrieve memories relevant to a given command, assembled within a token budget.
    /// Uses keyword matching + recency weighting to rank results.
    ///
    /// The returned string is formatted with XML-like tags for Claude to parse:
    /// ```
    /// <memory>
    /// <user_profile>...</user_profile>
    /// <recent_context>...</recent_context>
    /// ...
    /// </memory>
    /// ```
    func retrieveRelevantMemories(for command: String, tokenBudget: Int = 4000) -> String {
        let charBudget = Int(Double(tokenBudget) * tokenCharRatio)
        var sections: [(priority: Int, label: String, content: String)] = []

        // Priority 1: User profile (always included)
        if let profile = readFile("identity/user-profile.md") {
            sections.append((priority: 1, label: "user_profile", content: truncate(profile, maxChars: 2400)))
        }

        // Priority 2: Recent context (working memory)
        if let recent = readFile("context/recent-actions.md") {
            let lastEntries = extractLastEntries(recent, count: 5)
            if !lastEntries.isEmpty {
                sections.append((priority: 2, label: "recent_context", content: truncate(lastEntries, maxChars: 3000)))
            }
        }

        // Priority 3: App-specific knowledge
        let appNames = detectAppNames(in: command)
        for app in appNames {
            let slug = app.lowercased().replacingOccurrences(of: " ", with: "-")
            if let knowledge = readFile("knowledge/apps/\(slug).md") {
                sections.append((priority: 3, label: "app_knowledge_\(slug)", content: truncate(knowledge, maxChars: 1600)))
            }
        }

        // Priority 4: Matching task templates
        let templates = findMatchingTemplates(for: command)
        if let best = templates.first {
            sections.append((priority: 4, label: "task_template", content: truncate(best, maxChars: 2000)))
        }

        // Priority 5: Relevant failures to avoid
        if let failures = readFile("learning/failures.md") {
            let relevant = extractRelevantEntries(failures, for: command)
            if !relevant.isEmpty {
                sections.append((priority: 5, label: "avoid_mistakes", content: truncate(relevant, maxChars: 1600)))
            }
        }

        // Priority 6: Search broader vault for relevant notes
        let keywords = extractKeywords(from: command)
        if !keywords.isEmpty {
            let searchResults = searchVaultForKeywords(keywords, limit: 3, excludeFolders: ["Templates"])
            if !searchResults.isEmpty {
                let formatted = searchResults.map { "**\($0.path)**: \($0.excerpt)" }.joined(separator: "\n\n")
                sections.append((priority: 6, label: "relevant_knowledge", content: truncate(formatted, maxChars: 2000)))
            }
        }

        // Assemble within budget, dropping lowest-priority sections if needed
        var result = "<memory>\n"
        var usedChars = 20

        for section in sections.sorted(by: { $0.priority < $1.priority }) {
            let sectionText = "<\(section.label)>\n\(section.content)\n</\(section.label)>\n\n"
            if usedChars + sectionText.count <= charBudget {
                result += sectionText
                usedChars += sectionText.count
            }
        }

        result += "</memory>"
        return usedChars > 40 ? result : ""
    }

    /// Search vault for notes relevant to a command by keyword matching.
    func searchMemories(query: String, limit: Int = 5) -> String {
        let keywords = extractKeywords(from: query)
        guard !keywords.isEmpty else { return "" }

        let results = searchVaultForKeywords(keywords, limit: limit, excludeFolders: ["Templates"])
        if results.isEmpty { return "" }

        return results.map { "**\($0.path)** (relevance: \($0.score))\n\($0.excerpt)" }
            .joined(separator: "\n\n")
    }

    /// Load summaries of recent runs from daily notes and task log.
    func loadRecentRunSummaries(limit: Int = 5) -> String {
        let calendar = Calendar.current
        var summaries: [String] = []

        for dayOffset in 0..<7 {
            guard summaries.count < limit else { break }
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            let path = dailyNotePath(for: date)

            guard let content = readFile(path) else { continue }

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

    // MARK: - CRUD Operations

    /// Read a note by its vault-relative path.
    func readNote(at relativePath: String) -> String? {
        return readFile(relativePath)
    }

    /// Write or overwrite a note at a vault-relative path.
    func writeNote(at relativePath: String, content: String) throws {
        let url = vaultRoot.appendingPathComponent(relativePath)
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        NSLog("MemoryService: Wrote note: %@", relativePath)
    }

    /// Append text to an existing note, or create it if it doesn't exist.
    func appendToNote(at relativePath: String, text: String) throws {
        let url = vaultRoot.appendingPathComponent(relativePath)
        if fm.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            if let data = "\n\(text)".data(using: .utf8) {
                handle.write(data)
            }
            try handle.close()
        } else {
            try writeNote(at: relativePath, content: text)
        }
    }

    /// Delete a note at a vault-relative path.
    @discardableResult
    func deleteNote(at relativePath: String) -> Bool {
        let url = vaultRoot.appendingPathComponent(relativePath)
        do {
            try fm.removeItem(at: url)
            NSLog("MemoryService: Deleted note: %@", relativePath)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Search

    /// Search notes by content substring (case-insensitive).
    func searchNotes(
        query: String,
        folder: String? = nil,
        limit: Int = 20
    ) -> [(path: String, snippet: String)] {
        let searchRoot: URL
        if let folder = folder, !folder.isEmpty {
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
                    results.append((path: relativePath, snippet: String(line.prefix(200))))
                    break
                }
            }

            if results.count >= limit { break }
        }

        return results
    }

    /// Search notes by YAML frontmatter tag.
    func searchByTag(_ tag: String, folder: String? = nil) -> [String] {
        let searchRoot: URL
        if let folder = folder, !folder.isEmpty {
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

            if content.contains("tags:") && content.lowercased().contains(tag.lowercased()) {
                let relativePath = fileURL.path
                    .replacingOccurrences(of: vaultRoot.path + "/", with: "")
                results.append(relativePath)
            }
        }

        return results
    }

    /// List all notes in a vault folder.
    func listNotes(in folder: String) -> [String] {
        let folderURL = vaultRoot.appendingPathComponent(folder)
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var lines: [String] = []
        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let isDir = values?.isDirectory ?? false
            let name = item.lastPathComponent

            if isDir {
                lines.append("[dir] \(name)/")
            } else if name.hasSuffix(".md") {
                let date = values?.contentModificationDate
                let dateStr = date.map { ISO8601DateFormatter().string(from: $0) } ?? ""
                lines.append("\(name)  (\(dateStr))")
            }
        }
        return lines
    }

    /// Resolve a [[wikilink]] to a vault-relative file path.
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

    /// Create a new task note from template.
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
        let relativePath = "tasks/active/\(sanitizedTitle).md"

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

        // Also append to Active Tasks.md for quick reference
        let taskLine = "- [ ] **\(title)** [\(priority)]\(project.map { " #\($0)" } ?? "")"
        try appendToNote(at: "Active Tasks.md", text: taskLine)

        return relativePath
    }

    /// Move a task from active to completed.
    @discardableResult
    func completeTask(filename: String) throws -> Bool {
        let sourcePath = "tasks/active/\(filename)"
        let destPath = "tasks/completed/\(filename)"

        let sourceURL = vaultRoot.appendingPathComponent(sourcePath)
        let destURL = vaultRoot.appendingPathComponent(destPath)

        guard fm.fileExists(atPath: sourceURL.path) else { return false }

        if var content = try? String(contentsOf: sourceURL, encoding: .utf8) {
            content = content.replacingOccurrences(
                of: "status: active",
                with: "status: completed\ncompleted: \(Self.todayString())"
            )
            try content.write(to: sourceURL, atomically: true, encoding: .utf8)
        }

        try fm.moveItem(at: sourceURL, to: destURL)
        NSLog("MemoryService: Completed task: %@", filename)
        return true
    }

    /// Update a task's frontmatter field.
    func updateTask(filename: String, field: String, value: String) throws {
        let path = "tasks/active/\(filename)"
        guard var content = readFile(path) else { return }

        let pattern = "\(field): .*"
        let replacement = "\(field): \(value)"
        content = content.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: .regularExpression
        )

        try writeNote(at: path, content: content)
    }

    /// Update task status in Active Tasks.md by title match.
    func updateTaskByTitle(title: String, status: String, notes: String? = nil) {
        let url = vaultRoot.appendingPathComponent("Active Tasks.md")
        guard var content = try? String(contentsOf: url, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: "\n")
        var updated = false

        let newLines = lines.map { line -> String in
            if line.contains(title) && line.contains("- [") {
                updated = true
                let checkbox = status == "done" ? "- [x]" : "- [ ]"
                var newLine = line
                    .replacingOccurrences(of: "- [ ]", with: checkbox)
                    .replacingOccurrences(of: "- [x]", with: checkbox)
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

    /// List tasks from Active Tasks.md, optionally filtered.
    func listTasks(status: String? = nil, project: String? = nil) -> String {
        guard let content = readFile("Active Tasks.md") else {
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
            lines = lines.filter { !$0.hasPrefix("- [x]") }
        }

        if let project = project {
            lines = lines.filter { $0.contains("#\(project)") }
        }

        return lines.isEmpty ? "No matching tasks." : lines.joined(separator: "\n")
    }

    // MARK: - Contact Helpers

    /// Create a new contact note.
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

    /// Append an entry to today's journal, creating it if needed.
    func journalAppend(section: String, entry: String) throws {
        let dateStr = Self.todayString()
        let path = "Journal/\(dateStr).md"

        if readFile(path) == nil {
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

        guard var content = readFile(path) else { return }

        let sectionHeader = "## \(section)"
        if let range = content.range(of: sectionHeader) {
            let afterHeader = content[range.upperBound...]
            if let nextNewline = afterHeader.firstIndex(of: "\n") {
                let insertionPoint = content.index(after: nextNewline)
                content.insert(contentsOf: "- \(entry)\n", at: insertionPoint)
            } else {
                content += "\n- \(entry)"
            }
        } else {
            content += "\n\n## \(section)\n- \(entry)"
        }

        try writeNote(at: path, content: content)
    }

    // MARK: - Memory Shortcuts (remember/recall)

    /// Store an atomic memory fact with category and timestamp.
    func remember(fact: String, category: String = "fact") {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "- \(fact) `[\(category)]` `[\(timestamp)]`"
        let path = "Memory/\(category).md"
        try? appendToNote(at: path, text: entry)
    }

    /// Recall memories about a topic by searching the Memory/ folder.
    func recall(topic: String) -> String {
        let results = searchNotes(query: topic, folder: "Memory", limit: 10)
        if results.isEmpty { return "No memories found for: \(topic)" }
        return results.map { "- **\($0.path)**: \($0.snippet)" }.joined(separator: "\n")
    }

    // MARK: - Post-Run Recording

    /// Record a completed run's outcome for episodic memory.
    func recordRunOutcome(_ outcome: RunOutcome) {
        let dateStr = ISO8601DateFormatter().string(from: Date())
        let statusLabel = outcome.success ? "Success" : "Failed"

        // Episodic memory: task log
        let logEntry = """

        ## \(dateStr)
        - **Command:** \(outcome.command)
        - **Outcome:** \(statusLabel) (score: \(outcome.score ?? 0))
        - **Iterations:** \(outcome.iterations)
        - **RunId:** \(outcome.runId)
        """
        try? appendToNote(at: "tasks/task-log.md", text: logEntry)

        // Working memory: recent actions
        let recentEntry = "- [\(timeString())] \(outcome.command) (\(statusLabel.lowercased()))"
        try? appendToNote(at: "context/recent-actions.md", text: recentEntry)

        // Daily note
        let time = timeString()
        let scoreStr = outcome.score.map { " (score: \($0))" } ?? ""
        let dailyEntry = "- [\(time)] `\(statusLabel.lowercased())` \(outcome.command)\(scoreStr) — \(outcome.iterations) iterations"
        try? appendToNote(at: dailyNotePath(), text: dailyEntry)

        NSLog("MemoryService: Recorded run outcome: %@ — %@", outcome.command, statusLabel)
    }

    /// Record a verification rejection for failure-avoidance learning.
    func recordVerificationRejection(command: String, score: Int, reason: String) {
        let entry = """

        ## \(ISO8601DateFormatter().string(from: Date()))
        - **Command:** \(command)
        - **Score:** \(score)/100
        - **Reason:** \(reason)
        """
        try? appendToNote(at: "learning/failures.md", text: entry)
    }

    /// Record a user correction (when user retries with a modified command).
    func recordUserCorrection(originalCommand: String, correctedCommand: String) {
        let entry = """

        ## \(ISO8601DateFormatter().string(from: Date()))
        - **Original:** \(originalCommand)
        - **Corrected:** \(correctedCommand)
        """
        try? appendToNote(at: "learning/corrections.md", text: entry)
    }

    /// Update app-specific knowledge.
    func updateAppKnowledge(appName: String, insight: String) {
        let slug = appName.lowercased().replacingOccurrences(of: " ", with: "-")
        let path = "knowledge/apps/\(slug).md"

        if readFile(path) == nil {
            let header = """
            ---
            type: app-knowledge
            app: \(appName)
            updated: \(Self.todayString())
            confidence: medium
            ---
            # \(appName)

            ## Reliable Approaches

            ## Known Issues

            ## User Patterns
            """
            try? writeNote(at: path, content: header)
        }

        let entry = "- \(insight) (\(Self.todayString()))"
        try? appendToNote(at: path, text: entry)
    }

    /// Update user preferences.
    func updatePreferences(key: String, value: String) {
        let entry = "- **\(key):** \(value) (learned \(Self.todayString()))"
        try? appendToNote(at: "identity/preferences.md", text: entry)
    }

    /// Update Current Status with latest activity.
    func updateCurrentStatus(lastCommand: String, lastOutcome: String, timestamp: Date) {
        let time = ISO8601DateFormatter().string(from: timestamp)
        let content = """
        # Current Status

        **Last active:** \(time)
        **Last command:** \(lastCommand)
        **Last outcome:** \(lastOutcome)
        """
        try? writeNote(at: "Current Status.md", content: content)
    }

    /// Record a failure to Known Issues.
    func recordFailure(command: String, reason: String, iterations: Int) {
        let entry = "- **\(command)** failed after \(iterations) iterations: \(reason) (\(Self.todayString()))"
        try? appendToNote(at: "Known Issues.md", text: entry)
    }

    // MARK: - Consolidation

    /// Consolidate episodic memories into patterns (run periodically).
    func consolidateMemories() {
        // Prune recent-actions to last 50 entries
        if let content = readFile("context/recent-actions.md") {
            let lines = content.components(separatedBy: "\n")
            if lines.count > 60 {
                let header = lines.first ?? "# Recent Actions"
                let kept = Array(lines.suffix(50))
                let pruned = [header, ""] + kept
                try? writeNote(at: "context/recent-actions.md", content: pruned.joined(separator: "\n"))
                NSLog("MemoryService: Pruned recent-actions to 50 entries")
            }
        }

        // Prune task-log to last 200 entries
        if let content = readFile("tasks/task-log.md") {
            let sections = content.components(separatedBy: "\n## ")
            if sections.count > 210 {
                let header = sections.first ?? "# Task Log"
                let kept = sections.suffix(200)
                let pruned = header + "\n\n## " + kept.joined(separator: "\n## ")
                try? writeNote(at: "tasks/task-log.md", content: pruned)
                NSLog("MemoryService: Pruned task-log to 200 entries")
            }
        }
    }

    /// Generate daily summary from today's journal entries.
    func generateDailySummary() {
        let todayPath = dailyNotePath()
        guard let content = readFile(todayPath) else { return }

        let actionCount = content.components(separatedBy: "\n")
            .filter { $0.hasPrefix("- [") || $0.hasPrefix("- `") }
            .count

        let summaryEntry = "## \(Self.todayString())\n- Actions recorded: \(actionCount)"
        try? appendToNote(at: "context/daily-summary.md", text: summaryEntry)
    }

    // MARK: - Private Helpers

    /// Read a file relative to vault root.
    private func readFile(_ relativePath: String) -> String? {
        let url = vaultRoot.appendingPathComponent(relativePath)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Ensure a file exists with default content.
    private func ensureFile(_ relativePath: String, default content: String) {
        let url = vaultRoot.appendingPathComponent(relativePath)
        if !fm.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Truncate text to a maximum character count.
    private func truncate(_ text: String, maxChars: Int) -> String {
        if text.count <= maxChars { return text }
        let truncated = String(text.prefix(maxChars))
        if let lastNewline = truncated.lastIndex(of: "\n") {
            return String(truncated[...lastNewline]) + "\n... (truncated)"
        }
        return truncated + "... (truncated)"
    }

    /// Extract the last N entries from a markdown list.
    private func extractLastEntries(_ text: String, count: Int) -> String {
        let lines = text.components(separatedBy: "\n")
            .filter { $0.hasPrefix("- ") }
        let last = Array(lines.suffix(count))
        return last.joined(separator: "\n")
    }

    /// Detect app names referenced in a command string.
    private func detectAppNames(in command: String) -> [String] {
        let knownApps = [
            "Chrome", "Safari", "Firefox", "Terminal", "iTerm",
            "VS Code", "Xcode", "Finder", "Mail", "Messages",
            "Slack", "Discord", "Telegram", "Notes", "Calendar",
            "Preview", "TextEdit", "System Preferences", "Activity Monitor",
            "Docker", "Figma", "Notion", "Obsidian", "Spotify"
        ]

        let lower = command.lowercased()
        return knownApps.filter { lower.contains($0.lowercased()) }
    }

    /// Find task templates matching a command using trigger regex patterns.
    private func findMatchingTemplates(for command: String) -> [String] {
        let templatesDir = vaultRoot.appendingPathComponent("tasks/task-templates")
        guard let files = try? fm.contentsOfDirectory(
            at: templatesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var matches: [(content: String, score: Double)] = []
        let lowerCommand = command.lowercased()

        for file in files where file.pathExtension == "md" {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }

            // Check for trigger pattern in YAML frontmatter
            if let triggerRange = content.range(of: "trigger: \"", options: .literal),
               let endRange = content[triggerRange.upperBound...].range(of: "\"") {
                let pattern = String(content[triggerRange.upperBound..<endRange.lowerBound])
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let range = NSRange(lowerCommand.startIndex..., in: lowerCommand)
                    if regex.firstMatch(in: lowerCommand, range: range) != nil {
                        matches.append((content: content, score: 1.0))
                        continue
                    }
                }
            }

            // Fallback: keyword matching against template content
            let keywords = extractKeywords(from: command)
            let templateLower = content.lowercased()
            let matchCount = keywords.filter { templateLower.contains($0) }.count
            if matchCount >= 2 {
                matches.append((content: content, score: Double(matchCount) / Double(keywords.count)))
            }
        }

        return matches
            .sorted { $0.score > $1.score }
            .map { $0.content }
    }

    /// Extract relevant entries from a failures/log file based on command keywords.
    private func extractRelevantEntries(_ content: String, for command: String) -> String {
        let keywords = extractKeywords(from: command)
        guard !keywords.isEmpty else { return "" }

        let sections = content.components(separatedBy: "\n## ")
        var relevant: [String] = []

        for section in sections {
            let sectionLower = section.lowercased()
            if keywords.contains(where: { sectionLower.contains($0) }) {
                relevant.append("## " + section)
            }
        }

        return relevant.suffix(3).joined(separator: "\n")
    }

    /// Search the vault for notes matching keywords, with scoring.
    private func searchVaultForKeywords(
        _ keywords: [String],
        limit: Int,
        excludeFolders: [String] = []
    ) -> [(path: String, score: Int, excerpt: String)] {
        guard let enumerator = fm.enumerator(
            at: vaultRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [(path: String, score: Int, excerpt: String)] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "md" else { continue }

            let relativePath = fileURL.path
                .replacingOccurrences(of: vaultRoot.path + "/", with: "")

            // Skip excluded folders
            if excludeFolders.contains(where: { relativePath.hasPrefix($0) }) { continue }

            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            let lower = content.lowercased()
            var score = 0
            for keyword in keywords {
                if lower.contains(keyword.lowercased()) {
                    score += 1
                }
            }

            if score > 0 {
                let excerpt = extractExcerpt(from: content, keywords: keywords, maxLength: 300)
                results.append((path: relativePath, score: score, excerpt: excerpt))
            }
        }

        return results
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    /// Extract keywords from text, filtering stop words and short tokens.
    private func extractKeywords(from text: String) -> [String] {
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }

    /// Extract a relevant excerpt from content around matching keywords.
    private func extractExcerpt(from content: String, keywords: [String], maxLength: Int) -> String {
        let lines = content.components(separatedBy: "\n")

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

    /// Current time as HH:mm string.
    private func timeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }

    /// Path for a daily note, defaulting to today.
    private func dailyNotePath(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "Daily/\(formatter.string(from: date)).md"
    }

    // MARK: - Static Helpers

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

    // MARK: - Templates

    private static let taskTemplate = """
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

    private static let contactTemplate = """
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

    private static let journalTemplate = """
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

// MARK: - RunOutcome

/// Structured outcome of a completed run, used for episodic memory recording.
struct RunOutcome: Sendable {
    let runId: String
    let command: String
    let success: Bool
    let score: Int?
    let iterations: Int
}
