import Foundation

// MARK: - MemoryService+Session
// Session lifecycle (startSession, endSession), vault maintenance,
// templates, and hub page generation.

extension MemoryService {

    // MARK: - Hub Page

    static let hubPageContent = """
    ---
    aliases: [Home, Index]
    ---
    # Cyclop One

    Welcome to Cyclop One's memory vault. This is the persistent knowledge base for your AI assistant.
    You can browse and edit any file here — changes are picked up automatically.

    ## Quick Status
    - [[Current Status]] — What the agent last did and when
    - [[Active Tasks]] — Current task list
    - [[Known Issues]] — Bugs and failure patterns

    ## Knowledge
    - [[Identity/user-profile|User Profile]] — What Cyclop One knows about you
    - [[Identity/preferences|Preferences]] — Your learned preferences

    ## Activity
    - [[Daily/|Daily Notes]] — Session-by-session activity logs
    - [[Journal/|Journal]] — Detailed action logs per day
    - [[Context/recent-actions|Recent Actions]] — Last significant actions

    ## Memory
    - [[Memory/fact|Facts]] — Atomic facts and knowledge
    - [[Memory/preference|Preferences]] — Learned preferences
    - [[Memory/pattern|Patterns]] — Recurring behavioral patterns

    ## Learning
    - [[Learning/failures|Failures]] — What went wrong and how to avoid it
    - [[Learning/corrections|Corrections]] — User corrections to agent behavior
    - [[Learning/patterns|Patterns]] — Extracted recurring patterns

    ## Tasks
    - [[Tasks/task-log|Task Log]] — Chronological run history
    - [[Tasks/active/|Active Tasks (folder)]] — Individual task files
    - [[Tasks/completed/|Completed Tasks]] — Archived completed tasks

    ## Projects & People
    - [[Projects/|Projects]] — Per-project knowledge and context
    - [[Contacts/|Contacts]] — People and interaction history
    - [[Decisions/Decision Log|Decision Log]] — Architectural and strategic decisions

    ## System
    - [[Architecture/|Architecture]] — System design documents
    - [[Components/|Components]] — Per-module documentation
    - [[Templates/|Templates]] — Note templates
    """

    // MARK: - Templates

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

    // MARK: - Migration

    /// Sentinel file written after a successful migration from the old vault.
    private static let migrationSentinel = ".migration-complete"

    /// Old vault path for backward-compatible migration detection.
    static let legacyVaultRoot: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".cyclopone")
            .appendingPathComponent("memory")
    }()

    /// Directory renames from legacy lowercase to Obsidian-friendly capitalized names.
    private static let directoryRenames: [String: String] = [
        "identity": "Identity",
        "tasks": "Tasks",
        "knowledge": "Knowledge",
        "learning": "Learning",
        "context": "Context",
    ]

    /// Migrate content from ~/.cyclopone/memory/ to the new Obsidian vault location.
    /// This is a one-time operation. A sentinel file is written on success.
    func migrateFromLegacyVaultIfNeeded() {
        let legacy = Self.legacyVaultRoot
        let sentinel = legacy.appendingPathComponent(Self.migrationSentinel)

        // Skip if legacy vault doesn't exist or migration already done
        guard fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: sentinel.path) else {
            return
        }

        // Check that legacy vault has actual content (at least one .md file)
        guard let enumerator = fm.enumerator(at: legacy, includingPropertiesForKeys: nil,
                                              options: [.skipsHiddenFiles]) else { return }
        let hasContent = enumerator.contains { ($0 as? URL)?.pathExtension == "md" }
        guard hasContent else { return }

        NSLog("MemoryService: Migrating from legacy vault at %@", legacy.path)

        // Create destination if needed
        if !fm.fileExists(atPath: vaultRoot.path) {
            try? fm.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        }

        // Walk legacy vault and copy files, preserving directory structure
        guard let walker = fm.enumerator(at: legacy, includingPropertiesForKeys: [.isDirectoryKey],
                                          options: [.skipsHiddenFiles]) else { return }

        var migratedCount = 0
        var skippedCount = 0

        for case let fileURL as URL in walker {
            var relativePath = fileURL.path.replacingOccurrences(of: legacy.path + "/", with: "")

            // Rename legacy lowercase directories to capitalized Obsidian-friendly names
            for (old, new) in Self.directoryRenames {
                if relativePath.hasPrefix(old + "/") || relativePath == old {
                    relativePath = new + relativePath.dropFirst(old.count)
                    break
                }
            }

            let destURL = vaultRoot.appendingPathComponent(relativePath)

            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            if isDir {
                try? fm.createDirectory(at: destURL, withIntermediateDirectories: true)
            } else {
                // Create parent directory if needed
                let parent = destURL.deletingLastPathComponent()
                if !fm.fileExists(atPath: parent.path) {
                    try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
                }

                if fm.fileExists(atPath: destURL.path) {
                    // CONFLICT: destination file already exists. Keep the NEWER file.
                    let srcDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let dstDate = (try? destURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast

                    if srcDate > dstDate {
                        try? fm.removeItem(at: destURL)
                        try? fm.copyItem(at: fileURL, to: destURL)
                        migratedCount += 1
                    } else {
                        skippedCount += 1
                    }
                } else {
                    try? fm.copyItem(at: fileURL, to: destURL)
                    migratedCount += 1
                }
            }
        }

        // Write sentinel to mark migration complete
        try? "Migration completed at \(ISO8601DateFormatter().string(from: Date()))\nMigrated: \(migratedCount) files, Skipped: \(skippedCount) conflicts"
            .write(to: sentinel, atomically: true, encoding: .utf8)

        NSLog("MemoryService: Migration complete. Migrated %d files, skipped %d conflicts.", migratedCount, skippedCount)
    }

    // MARK: - Session Lifecycle

    /// Called once at app launch to create the daily note and record session start.
    func startSession() {
        let dailyPath = dailyNotePath()
        ensureDailyNote()

        // Append session start marker
        let time = timeString()
        let entry = "\n## Session started at \(time)\n"
        try? appendToNote(at: dailyPath, text: entry)
        NSLog("MemoryService: Session started — daily note at %@", dailyPath)

        // Reload core files into cache to detect user edits between sessions
        for file in coreFiles {
            if hasBeenModified(file) {
                NSLog("MemoryService: Core file modified by user: %@", file)
            }
        }

        // Run vault maintenance in background
        Task.detached { [self] in
            await self.performVaultMaintenance()
        }
    }

    /// Called when the app is quitting — finalize the daily note.
    func endSession(totalRuns: Int, successCount: Int, totalTokens: Int) {
        let time = timeString()
        let summary = """

        ## Session ended at \(time)
        - Runs: \(totalRuns) (\(successCount) succeeded)
        - Total tokens: \(totalTokens)
        """
        try? appendToNote(at: dailyNotePath(), text: summary)

        // Consolidate memories to prevent unbounded growth
        consolidateMemories()
        generateDailySummary()

        NSLog("MemoryService: Session ended — %d runs, %d succeeded", totalRuns, successCount)
    }

    // MARK: - Vault Maintenance (Rot Prevention)

    /// Periodic maintenance to keep the vault healthy.
    /// Runs on session start (background) and detects:
    ///   - Empty files (created but never populated)
    ///   - Oversized notes (>500 lines)
    ///   - Stale daily notes (>30 days old)
    func performVaultMaintenance() {
        var issues: [String] = []

        // 1. Detect empty files (>0 bytes header-only or truly empty)
        let emptyFiles = findEmptyFiles()
        if !emptyFiles.isEmpty {
            issues.append("Empty files: \(emptyFiles.count) (\(emptyFiles.prefix(3).joined(separator: ", ")))")
        }

        // 2. Detect oversized notes
        let oversized = findOversizedNotes(maxLines: 500)
        for (path, lines) in oversized {
            issues.append("Oversized: \(path) (\(lines) lines)")
        }

        // 3. Clean up stale daily notes (>30 days)
        let cleaned = cleanStaleDailyNotes(daysOld: 30)
        if cleaned > 0 {
            issues.append("Archived \(cleaned) daily notes older than 30 days")
        }

        if issues.isEmpty {
            NSLog("MemoryService: Vault maintenance — all clean")
        } else {
            for issue in issues {
                NSLog("MemoryService: Vault maintenance — %@", issue)
            }
        }
    }

    /// Find markdown files with no meaningful content (just headers or empty).
    func findEmptyFiles() -> [String] {
        var emptyFiles: [String] = []
        let enumerator = fm.enumerator(at: vaultRoot, includingPropertiesForKeys: [.fileSizeKey])

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            // Skip daily notes and index files
            let relative = url.path.replacingOccurrences(of: vaultRoot.path + "/", with: "")
            guard !relative.hasPrefix("Daily/"), !relative.hasPrefix(".") else { continue }

            if let content = try? String(contentsOf: url, encoding: .utf8) {
                let meaningful = content.components(separatedBy: "\n")
                    .filter { !$0.hasPrefix("#") && !$0.hasPrefix("---") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if meaningful.isEmpty {
                    emptyFiles.append(relative)
                }
            }
        }
        return emptyFiles
    }

    /// Find notes exceeding a line limit.
    func findOversizedNotes(maxLines: Int) -> [(String, Int)] {
        var oversized: [(String, Int)] = []
        let enumerator = fm.enumerator(at: vaultRoot, includingPropertiesForKeys: nil)

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                let lineCount = content.components(separatedBy: "\n").count
                if lineCount > maxLines {
                    let relative = url.path.replacingOccurrences(of: vaultRoot.path + "/", with: "")
                    oversized.append((relative, lineCount))
                }
            }
        }
        return oversized
    }

    /// Archive daily notes older than N days by moving to Daily/archive/.
    func cleanStaleDailyNotes(daysOld: Int) -> Int {
        let dailyDir = vaultRoot.appendingPathComponent("Daily")
        let archiveDir = dailyDir.appendingPathComponent("archive")

        guard let files = try? fm.contentsOfDirectory(at: dailyDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return 0
        }

        let cutoff = Date().addingTimeInterval(-Double(daysOld) * 86400)
        var archivedCount = 0

        for file in files {
            guard file.pathExtension == "md",
                  let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = attrs.contentModificationDate,
                  mtime < cutoff else { continue }

            // Move to archive subdirectory
            try? fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
            let dest = archiveDir.appendingPathComponent(file.lastPathComponent)
            if (try? fm.moveItem(at: file, to: dest)) != nil {
                archivedCount += 1
            }
        }
        return archivedCount
    }

    /// Ensure today's daily note exists with a header.
    func ensureDailyNote() {
        let path = dailyNotePath()
        let date = Self.todayString()
        ensureFile(path, default: """
        ---
        date: \(date)
        type: daily-note
        ---
        # \(date)

        """)
    }
}
