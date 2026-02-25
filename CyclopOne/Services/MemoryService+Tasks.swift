import Foundation

// MARK: - MemoryService+Tasks
// Task management, contact management, and journal operations.

extension MemoryService {

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
        - [[Active Tasks]]
        - [[Tasks/task-log|Task Log]]
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
        let sourcePath = "Tasks/active/\(filename)"
        let destPath = "Tasks/completed/\(filename)"

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
        let path = "Tasks/active/\(filename)"
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

    // MARK: - Note Search & Listing

    /// Resolve a folder parameter into a full URL under the vault root.
    /// Returns vault root if folder is nil or empty.
    func resolvedSearchRoot(folder: String?) -> URL {
        if let folder = folder, !folder.isEmpty {
            return vaultRoot.appendingPathComponent(folder)
        }
        return vaultRoot
    }

    /// Search notes by content substring (case-insensitive).
    func searchNotes(
        query: String,
        folder: String? = nil,
        limit: Int = 20
    ) -> [(path: String, snippet: String)] {
        let searchRoot = resolvedSearchRoot(folder: folder)

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
        let searchRoot = resolvedSearchRoot(folder: folder)

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
}
