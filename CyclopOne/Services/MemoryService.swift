import Foundation

// MARK: - MemoryService

/// The agent's persistent memory — a markdown vault backed service that provides
/// episodic, semantic, procedural, and working memory across runs.
///
/// Default vault location: ~/Documents/CyclopOne/
///
/// Memory types:
///   - **Episodic** (Tasks/task-log.md): What happened — run outcomes, durations, scores
///   - **Semantic** (Knowledge/apps/, Memory/): What we know — app knowledge, facts, preferences
///   - **Procedural** (Tasks/task-templates/): How to do things — reusable action sequences
///   - **Working** (Context/recent-actions.md): Current context — rolling window of recent actions
///
/// The vault is stored as plain markdown files that users can browse and edit
/// with any text editor or Obsidian. All I/O is serialised through this actor.
///
/// Extensions:
///   - `MemoryService+Retrieval.swift` — search, retrieval, context building
///   - `MemoryService+Recording.swift` — run recording, consolidation, app knowledge
///   - `MemoryService+Tasks.swift` — task/contact/journal management
///   - `MemoryService+Session.swift` — session lifecycle, vault maintenance, templates
actor MemoryService {

    // MARK: - Singleton

    static let shared = MemoryService()

    // MARK: - Properties

    /// Root path of the Obsidian vault.
    let vaultRoot: URL

    /// Vault root path, accessible synchronously for UI display.
    /// Safe because vaultRoot is a let constant assigned in init.
    nonisolated var vaultRootPath: String {
        vaultRoot.path
    }

    /// FileManager instance for all I/O.
    let fm = FileManager.default

    /// Token-to-character ratio for budget estimation (~4 chars per token).
    let tokenCharRatio = 4.0

    /// Default memory token budget for system prompt injection.
    /// Sprint 7: Raised from 6,000 to 15,000 tokens (~7% of context window).
    /// Better retrieval means higher relevance per token, so the larger budget
    /// is justified by improved signal-to-noise ratio.
    let defaultTokenBudget = 15000

    /// Core files that are always loaded into the system prompt.
    let coreFiles = [
        "Identity/user-profile.md",
        "Current Status.md",
        "Active Tasks.md"
    ]

    /// Cache of file modification times for detecting user edits.
    /// Key: vault-relative path, Value: last known modification date.
    private var mtimeCache: [String: Date] = [:]

    /// Sprint 7: Cached vault file index for search.
    /// Avoids full FileManager.enumerator walk on every retrieval.
    /// Rebuilt when stale (> 60 seconds old) or when vault structure changes.
    var vaultIndex: [(path: String, mtime: Date)] = []
    var vaultIndexTimestamp: Date = .distantPast

    /// Stop words excluded from keyword extraction.
    let stopWords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "shall", "can", "to", "of", "in", "for",
        "on", "with", "at", "by", "from", "it", "this", "that", "my", "your",
        "me", "i", "and", "or", "but", "not", "please", "open", "go", "the"
    ]

    // MARK: - Init

    private init() {
        // Use custom vault path from UserDefaults if set, otherwise use default
        if let custom = UserDefaults.standard.string(forKey: "vaultPath"), !custom.isEmpty {
            self.vaultRoot = URL(fileURLWithPath: custom)
        } else {
            self.vaultRoot = Self.defaultVaultURL()
        }
    }

    /// Construct the default vault URL: ~/Documents/CyclopOne/
    static func defaultVaultURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Documents")
            .appendingPathComponent("CyclopOne")
    }

    /// The display path for the current vault root, using ~ for the home directory.
    nonisolated var vaultDisplayPath: String {
        let path = vaultRoot.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Vault Bootstrap

    /// Create the vault directory structure and seed files if they don't exist.
    /// Call once at app startup.
    func bootstrap() {
        // Step 1: Migrate legacy vault if applicable (defined in MemoryService+Session)
        migrateFromLegacyVaultIfNeeded()

        // Step 2: Create directory structure
        let dirs = [
            "",
            "Architecture",
            "Components",
            "Contacts",
            "Context",
            "Daily",
            "Decisions",
            "Identity",
            "Journal",
            "Knowledge", "Knowledge/apps",
            "Learning",
            "Memory",
            "Projects",
            "Tasks", "Tasks/active", "Tasks/completed", "Tasks/task-templates",
            "Templates"
        ]

        for dir in dirs {
            let url = vaultRoot.appendingPathComponent(dir)
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url, withIntermediateDirectories: true)
                NSLog("MemoryService: Created directory: %@", dir.isEmpty ? "(vault root)" : dir)
            }
        }

        // Step 3: Seed core files with wikilinks
        ensureFile("Identity/user-profile.md", default: """
        ---
        type: user-profile
        updated: \(Self.todayString())
        ---
        # User Profile

        _No profile yet. Will be learned over time._

        ---
        See also: [[Cyclop One Home]] | [[Identity/preferences|Preferences]]
        """)

        ensureFile("Identity/preferences.md", default: """
        # Preferences

        _No preferences recorded yet._

        ---
        See also: [[Cyclop One Home]] | [[Identity/user-profile|User Profile]]
        """)

        ensureFile("Active Tasks.md", default: """
        # Active Tasks

        _No tasks yet._

        ---
        See also: [[Cyclop One Home]] | [[Current Status]] | [[Tasks/task-log|Task Log]]
        """)

        ensureFile("Current Status.md", default: """
        # Current Status

        **Last active:** Never
        **Last command:** None
        **Last outcome:** N/A

        ---
        See also: [[Cyclop One Home]] | [[Active Tasks]] | [[Known Issues]]
        """)

        ensureFile("Known Issues.md", default: """
        # Known Issues

        _No known issues recorded yet._

        ---
        See also: [[Cyclop One Home]] | [[Current Status]] | [[Learning/failures|Failure Log]]
        """)

        ensureFile("Decisions/Decision Log.md", default: """
        # Decision Log

        Architectural and strategic decisions, recorded chronologically.

        ---
        See also: [[Cyclop One Home]] | [[Architecture/]]
        """)

        ensureFile("Tasks/task-log.md", default: "# Task Log\n\n---\nSee also: [[Active Tasks]] | [[Cyclop One Home]]\n")
        ensureFile("Learning/failures.md", default: "# Failure Log\n\n---\nSee also: [[Known Issues]] | [[Cyclop One Home]]\n")
        ensureFile("Learning/corrections.md", default: "# User Corrections\n\n---\nSee also: [[Cyclop One Home]] | [[Learning/failures|Failure Log]]\n")
        ensureFile("Learning/patterns.md", default: "# Learned Patterns\n\n---\nSee also: [[Cyclop One Home]]\n")
        ensureFile("Learning/procedures.md", default: "# Procedures\n\nHow the agent accomplished tasks — auto-recorded after successful runs.\n\n---\nSee also: [[Cyclop One Home]] | [[Learning/patterns|Patterns]]\n")
        ensureFile("Context/recent-actions.md", default: "# Recent Actions\n\n")
        ensureFile("Context/daily-summary.md", default: "# Daily Summary\n\n")
        ensureFile("Memory/preference.md", default: "# Preferences\n\n")
        ensureFile("Memory/fact.md", default: "# Facts\n\n")
        ensureFile("Memory/pattern.md", default: "# Patterns\n\n")

        // Step 4: Hub page
        ensureFile("Cyclop One Home.md", default: Self.hubPageContent)

        // Step 5: Templates
        ensureFile("Templates/task.md", default: Self.taskTemplate)
        ensureFile("Templates/contact.md", default: Self.contactTemplate)
        ensureFile("Templates/journal.md", default: Self.journalTemplate)

        // Step 6: Obsidian configuration
        let obsidianDir = vaultRoot.appendingPathComponent(".obsidian")
        if !fm.fileExists(atPath: obsidianDir.path) {
            try? fm.createDirectory(at: obsidianDir, withIntermediateDirectories: true)
        }
        ensureFile(".obsidian/app.json", default: """
        {
          "showLineNumber": true,
          "strictLineBreaks": false,
          "readableLineLength": true
        }
        """)

        // Post-bootstrap writability check
        if !fm.isWritableFile(atPath: vaultRoot.path) {
            NSLog("MemoryService: WARNING — vault root is not writable: %@", vaultRoot.path)
        }

        NSLog("MemoryService: Vault bootstrapped at %@", vaultRoot.path)
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
    /// Uses String read + concatenation + atomic write for crash safety.
    func appendToNote(at relativePath: String, text: String) throws {
        let url = vaultRoot.appendingPathComponent(relativePath)
        if fm.fileExists(atPath: url.path) {
            let existing = try String(contentsOf: url, encoding: .utf8)
            let updated = existing + "\n" + text
            try updated.write(to: url, atomically: true, encoding: .utf8)
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

    // MARK: - Internal Helpers (used by extensions)

    /// Read a file relative to vault root.
    func readFile(_ relativePath: String) -> String? {
        let url = vaultRoot.appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        updateMtimeCache(relativePath)
        return content
    }

    // MARK: - File Modification Tracking

    /// Check if a file has been modified since we last read it.
    func hasBeenModified(_ relativePath: String) -> Bool {
        let url = vaultRoot.appendingPathComponent(relativePath)
        guard let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let currentMtime = attrs.contentModificationDate else {
            return false
        }

        if let cachedMtime = mtimeCache[relativePath] {
            return currentMtime > cachedMtime
        }

        // Never read before — treat as "modified" (needs loading)
        return true
    }

    /// Update the mtime cache after reading a file.
    private func updateMtimeCache(_ relativePath: String) {
        let url = vaultRoot.appendingPathComponent(relativePath)
        if let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
           let mtime = attrs.contentModificationDate {
            mtimeCache[relativePath] = mtime
        }
    }

    /// Reload a file if it has been modified since last read.
    /// Returns the new content if modified, nil if unchanged.
    func reloadIfModified(_ relativePath: String) -> String? {
        guard hasBeenModified(relativePath) else { return nil }
        NSLog("MemoryService: Reloading modified file: %@", relativePath)
        return readFile(relativePath)
    }

    /// Ensure a file exists with default content.
    func ensureFile(_ relativePath: String, default content: String) {
        let url = vaultRoot.appendingPathComponent(relativePath)
        if !fm.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Current time as HH:mm string.
    func timeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }

    /// Path for a daily note, defaulting to today.
    func dailyNotePath(for date: Date = Date()) -> String {
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
