import Foundation
import os.log

private let logger = Logger(subsystem: "com.cyclop.one.app", category: "SkillLoader")

// MARK: - Skill Model

/// Represents a single skill parsed from a SKILL.md file.
struct Skill: Sendable {
    /// Unique name of the skill.
    let name: String

    /// Human-readable description of what the skill does.
    let description: String

    /// Regex trigger patterns that match user commands.
    let triggers: [String]

    /// Ordered sequence of tool steps the agent should follow.
    let steps: [String]

    /// Permission tier overrides for tools used in this skill.
    /// Maps tool names to tier strings (e.g. "tier1", "tier2", "tier3").
    let permissions: [String: String]

    /// Maximum iterations allowed for this skill's execution.
    let maxIterations: Int

    /// Whether the skill is currently enabled.
    var isEnabled: Bool

    /// The file path this skill was loaded from (nil for built-in skills).
    let filePath: String?

    /// Whether this skill is a built-in (not user-authored).
    let isBuiltIn: Bool
}

// MARK: - SkillLoader

/// Loads and manages skills from ~/.cyclopone/skills/*.md files.
///
/// Skills are YAML-like markdown files that define reusable tool sequences
/// triggered by regex patterns against user commands. When matched, a skill's
/// steps are injected into the system prompt as additional context.
///
/// This is an actor to ensure thread-safe access to mutable skill state
/// (skills array, enable/disable, command history).
actor SkillLoader {

    // MARK: - Singleton

    static let shared = SkillLoader()

    // MARK: - Properties

    /// All loaded skills (built-in + user-authored).
    private(set) var skills: [Skill] = []

    /// The directory where user skill files are stored.
    private let skillsDirectory: URL

    /// UserDefaults key for storing disabled skill names.
    private let disabledSkillsKey = "CyclopOne_DisabledSkills"

    /// Pre-compiled trigger regexes keyed by pattern string. Avoids recompiling on every matchSkills call.
    private var compiledTriggers: [String: NSRegularExpression] = [:]

    /// UserDefaults key for storing command history (for self-authoring).
    private let commandHistoryKey = "CyclopOne_CommandHistory"

    /// Maximum number of commands to keep in history for pattern detection.
    private let maxCommandHistory = 100

    /// Minimum number of similar commands to suggest a skill.
    private let similarCommandThreshold = 3

    /// Similarity threshold (0.0 to 1.0) for detecting similar commands.
    private let similarityThreshold = 0.6

    // MARK: - Init

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.skillsDirectory = home.appendingPathComponent(".cyclopone/skills")
    }

    // MARK: - Loading

    /// Load all skills: built-in skills first, then user-authored from disk.
    /// Call this once at app startup.
    func loadAll() {
        var loaded: [Skill] = []

        // Load built-in skills
        loaded.append(contentsOf: builtInSkills())

        // Ensure the skills directory exists
        ensureSkillsDirectory()

        // Install built-in skill files if they don't exist on disk
        installBuiltInSkillFiles()

        // Load user-authored skills from disk
        loaded.append(contentsOf: loadUserSkills())

        // Apply enabled/disabled state from UserDefaults
        let disabledNames = disabledSkillNames()
        for i in loaded.indices {
            if disabledNames.contains(loaded[i].name) {
                loaded[i].isEnabled = false
            }
        }

        // Pre-compile all trigger regexes with proper error handling
        compiledTriggers.removeAll()
        for i in loaded.indices {
            var hasInvalidTrigger = false
            for pattern in loaded[i].triggers {
                if compiledTriggers[pattern] == nil {
                    do {
                        compiledTriggers[pattern] = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                    } catch {
                        hasInvalidTrigger = true
                        logger.error("Failed to compile trigger regex for skill '\(loaded[i].name)': pattern='\(pattern)' error=\(error.localizedDescription)")
                        NSLog("CyclopOne [SkillLoader]: Invalid regex in skill '%@': pattern='%@' — %@", loaded[i].name, pattern, error.localizedDescription)
                    }
                }
            }
            // Disable skill if any trigger regex failed to compile
            if hasInvalidTrigger {
                loaded[i].isEnabled = false
                logger.warning("Disabled skill '\(loaded[i].name)' due to invalid trigger regex")
                NSLog("CyclopOne [SkillLoader]: Disabled skill '%@' due to invalid trigger regex", loaded[i].name)
            }
        }

        self.skills = loaded

        logger.info("Loaded \(loaded.count) skills (\(loaded.filter { $0.isBuiltIn }.count) built-in, \(loaded.filter { !$0.isBuiltIn }.count) user)")

        // Run full trigger validation and report any issues
        validateSkillTriggers()
    }

    /// Reload skills from disk (e.g. after a new skill is authored).
    func reload() {
        loadAll()
    }

    // MARK: - Skill Matching

    /// Find all skills whose trigger patterns match the given user command.
    /// Only returns enabled skills.
    ///
    /// - Parameter command: The user's command text.
    /// - Returns: Array of matched skills, sorted by specificity (most triggers matched first).
    func matchSkills(for command: String) -> [Skill] {
        let normalizedCommand = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var matched: [Skill] = []

        for skill in skills where skill.isEnabled {
            for pattern in skill.triggers {
                if let regex = compiledTriggers[pattern],
                   regex.firstMatch(in: normalizedCommand, range: NSRange(normalizedCommand.startIndex..., in: normalizedCommand)) != nil {
                    matched.append(skill)
                    break // Only add the skill once even if multiple triggers match
                }
            }
        }

        return matched
    }

    /// Build additional system prompt context from matched skills.
    ///
    /// - Parameter skills: The matched skills to inject.
    /// - Returns: A string to append to the system prompt, or empty if no skills matched.
    func buildSkillContext(for matchedSkills: [Skill]) -> String {
        guard !matchedSkills.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("\n\n## Available Skills")
        lines.append("The following skills match the user's request. Follow their steps in order:")

        for skill in matchedSkills {
            lines.append("")
            lines.append("### Skill: \(skill.name)")
            lines.append(skill.description)
            lines.append("")
            lines.append("**Steps:**")
            for (i, step) in skill.steps.enumerated() {
                lines.append("\(i + 1). \(step)")
            }
            if skill.maxIterations > 0 {
                lines.append("")
                lines.append("Max iterations for this skill: \(skill.maxIterations)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Enable / Disable

    /// Enable a skill by name.
    func enableSkill(named name: String) {
        if let index = skills.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            skills[index].isEnabled = true
            var disabled = disabledSkillNames()
            disabled.remove(skills[index].name)
            saveDisabledSkillNames(disabled)
            logger.info("Enabled skill: \(self.skills[index].name)")
        }
    }

    /// Disable a skill by name.
    func disableSkill(named name: String) {
        if let index = skills.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            skills[index].isEnabled = false
            var disabled = disabledSkillNames()
            disabled.insert(skills[index].name)
            saveDisabledSkillNames(disabled)
            logger.info("Disabled skill: \(self.skills[index].name)")
        }
    }

    /// Toggle a skill's enabled state.
    func toggleSkill(named name: String) -> Bool {
        if let skill = skills.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            if skill.isEnabled {
                disableSkill(named: name)
                return false
            } else {
                enableSkill(named: name)
                return true
            }
        }
        return false
    }

    // MARK: - Self-Authoring

    /// Record a command in the history for pattern detection.
    /// Call this for every user command processed.
    ///
    /// - Parameter command: The user's command text.
    /// - Returns: A suggested skill if a repeated pattern is detected, or nil.
    func recordCommand(_ command: String) -> SuggestedSkill? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var history = commandHistory()
        history.append(trimmed)

        // Keep only the last N commands
        if history.count > maxCommandHistory {
            history = Array(history.suffix(maxCommandHistory))
        }
        saveCommandHistory(history)

        // Check for repeated patterns
        return detectRepeatedPattern(in: history, latestCommand: trimmed)
    }

    /// Write a new SKILL.md file for a suggested skill.
    ///
    /// - Parameter suggestion: The suggested skill to write.
    /// - Returns: The file path where the skill was saved, or nil on failure.
    @discardableResult
    func writeSkillFile(from suggestion: SuggestedSkill) -> String? {
        ensureSkillsDirectory()

        let sanitizedName = suggestion.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }

        let filePath = skillsDirectory.appendingPathComponent("\(sanitizedName).md")

        let content = """
        # SKILL: \(suggestion.name)

        ## Description
        \(suggestion.description)

        ## Triggers
        \(suggestion.triggers.map { "- `\($0)`" }.joined(separator: "\n"))

        ## Steps
        \(suggestion.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

        ## Permissions
        \(suggestion.permissions.isEmpty ? "- (none)" : suggestion.permissions.map { "- \($0.key): \($0.value)" }.joined(separator: "\n"))

        ## MaxIterations
        \(suggestion.maxIterations)
        """

        // Validate all regex patterns before writing to disk
        let validationErrors = validateSkillFile(content)
        if !validationErrors.isEmpty {
            for err in validationErrors {
                logger.error("Skill validation failed: \(err)")
            }
            NSLog("CyclopOne [SkillLoader]: Refusing to write skill '%@' — %d validation error(s)", suggestion.name, validationErrors.count)
            return nil
        }

        do {
            try content.write(to: filePath, atomically: true, encoding: .utf8)
            logger.info("Wrote skill file: \(filePath.path)")

            // Reload skills to pick up the new file
            reload()

            return filePath.path
        } catch {
            logger.error("Failed to write skill file: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Listing

    /// Returns a formatted list of all skills for display.
    func formattedSkillList() -> String {
        guard !skills.isEmpty else {
            return "No skills loaded."
        }

        var lines: [String] = ["*Skills:*\n"]
        for skill in skills {
            let status = skill.isEnabled ? "[ON]" : "[OFF]"
            let source = skill.isBuiltIn ? "(built-in)" : "(custom)"
            lines.append("\(status) *\(skill.name)* \(source)")
            lines.append("  \(skill.description)")
            lines.append("  Triggers: \(skill.triggers.joined(separator: ", "))")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Private: Built-in Skills

    private func builtInSkills() -> [Skill] {
        return [
            Skill(
                name: "web-search",
                description: "Open Safari, perform a web search, and return the results.",
                triggers: [
                    #"(?i)\b(search|google|look\s*up|find\s+online|web\s+search)\b"#,
                    #"(?i)\bsearch\s+(for|the\s+web)\b"#
                ],
                steps: [
                    "Open Safari using the open_application tool",
                    "Click the address/search bar (usually top center of the browser window)",
                    "Type the search query using type_text",
                    "Press Return to execute the search",
                    "Take a screenshot to see the results",
                    "Read and summarize the top results visible on screen"
                ],
                permissions: ["open_application": "tier1"],
                maxIterations: 15,
                isEnabled: true,
                filePath: nil,
                isBuiltIn: true
            ),
            Skill(
                name: "file-organizer",
                description: "Organize the Downloads folder by sorting files into subfolders by type.",
                triggers: [
                    #"(?i)\b(organize|clean\s*up|sort|tidy)\s+(downloads|my\s+downloads)\b"#,
                    #"(?i)\bdownloads?\s+(folder|directory)\s+(organiz|clean|sort|tidy)"#
                ],
                steps: [
                    "List the contents of ~/Downloads using run_shell_command: ls -la ~/Downloads",
                    "Identify file types present (images, documents, archives, videos, etc.)",
                    "Create category subdirectories if they don't exist: Images, Documents, Archives, Videos, Audio, Other",
                    "Move files into the appropriate category folders using mv commands",
                    "List the organized structure to confirm",
                    "Report a summary of what was moved"
                ],
                permissions: ["run_shell_command": "tier2"],
                maxIterations: 15,
                isEnabled: true,
                filePath: nil,
                isBuiltIn: true
            ),
            Skill(
                name: "app-launcher",
                description: "Open and configure applications by name with optional setup steps.",
                triggers: [
                    #"(?i)\b(open|launch|start)\s+(\w+)\s+(and|then|with)\s+"#,
                    #"(?i)\b(set\s*up|configure|prepare)\s+(\w+)\s+(for|to)\b"#
                ],
                steps: [
                    "Open the requested application using open_application or run_applescript",
                    "Wait for the application to finish launching (take a screenshot to verify)",
                    "If configuration was requested, navigate to the appropriate settings or interface",
                    "Apply the requested configuration changes using click, type_text, or keyboard shortcuts",
                    "Take a final screenshot to confirm the app is open and configured as requested"
                ],
                permissions: ["open_application": "tier1", "run_applescript": "tier2"],
                maxIterations: 15,
                isEnabled: true,
                filePath: nil,
                isBuiltIn: true
            ),
        ]
    }

    // MARK: - Private: File I/O

    private func ensureSkillsDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: skillsDirectory.path) {
            do {
                try fm.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
                logger.info("Created skills directory: \(self.skillsDirectory.path)")
            } catch {
                logger.error("Failed to create skills directory: \(error.localizedDescription)")
            }
        }
    }

    /// Install built-in skill markdown files to disk so users can see and edit them.
    private func installBuiltInSkillFiles() {
        let fm = FileManager.default

        for skill in builtInSkills() {
            let sanitizedName = skill.name
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
            let filePath = skillsDirectory.appendingPathComponent("\(sanitizedName).md")

            guard !fm.fileExists(atPath: filePath.path) else { continue }

            let content = """
            # SKILL: \(skill.name)

            ## Description
            \(skill.description)

            ## Triggers
            \(skill.triggers.map { "- `\($0)`" }.joined(separator: "\n"))

            ## Steps
            \(skill.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

            ## Permissions
            \(skill.permissions.isEmpty ? "- (none)" : skill.permissions.map { "- \($0.key): \($0.value)" }.joined(separator: "\n"))

            ## MaxIterations
            \(skill.maxIterations)
            """

            do {
                try content.write(to: filePath, atomically: true, encoding: .utf8)
                logger.info("Installed built-in skill file: \(filePath.path)")
            } catch {
                logger.error("Failed to install built-in skill file \(skill.name): \(error.localizedDescription)")
            }
        }
    }

    /// Load user-authored skills from ~/.cyclopone/skills/*.md
    private func loadUserSkills() -> [Skill] {
        let fm = FileManager.default

        guard fm.fileExists(atPath: skillsDirectory.path) else { return [] }

        let builtInNames = Set(builtInSkills().map { $0.name })

        do {
            let files = try fm.contentsOfDirectory(at: skillsDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "md" }

            var userSkills: [Skill] = []
            for file in files {
                if let skill = parseSkillFile(at: file) {
                    // Skip if this is a built-in skill name (already loaded from code)
                    if builtInNames.contains(skill.name) { continue }
                    userSkills.append(skill)
                }
            }

            return userSkills
        } catch {
            logger.error("Failed to read skills directory: \(error.localizedDescription)")
            return []
        }
    }

    /// Parse a single SKILL.md file into a Skill struct.
    ///
    /// Expected format:
    /// ```
    /// # SKILL: <name>
    ///
    /// ## Description
    /// <text>
    ///
    /// ## Triggers
    /// - `<regex>`
    ///
    /// ## Steps
    /// 1. <step>
    ///
    /// ## Permissions
    /// - <tool>: <tier>
    ///
    /// ## MaxIterations
    /// <number>
    /// ```
    func parseSkillFile(at url: URL) -> Skill? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.warning("Cannot read skill file: \(url.path)")
            return nil
        }

        return parseSkillContent(content, filePath: url.path)
    }

    /// Parse skill content from a string (testable without file I/O).
    func parseSkillContent(_ content: String, filePath: String? = nil) -> Skill? {
        let lines = content.components(separatedBy: .newlines)

        var name: String?
        var description: String = ""
        var triggers: [String] = []
        var steps: [String] = []
        var permissions: [String: String] = [:]
        var maxIterations: Int = 15

        var currentSection: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Parse skill name from header
            if trimmed.hasPrefix("# SKILL:") {
                name = trimmed
                    .replacingOccurrences(of: "# SKILL:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            // Detect section headers
            if trimmed.hasPrefix("## ") {
                currentSection = trimmed
                    .replacingOccurrences(of: "## ", with: "")
                    .lowercased()
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            // Skip empty lines
            guard !trimmed.isEmpty else { continue }

            // Parse content based on current section
            switch currentSection {
            case "description":
                if description.isEmpty {
                    description = trimmed
                } else {
                    description += " " + trimmed
                }

            case "triggers":
                // Expect lines like: - `pattern` or - pattern
                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    var pattern = String(trimmed.dropFirst(2))
                        .trimmingCharacters(in: .whitespaces)
                    // Strip backticks if present
                    if pattern.hasPrefix("`") && pattern.hasSuffix("`") {
                        pattern = String(pattern.dropFirst().dropLast())
                    }
                    if !pattern.isEmpty {
                        triggers.append(pattern)
                    }
                }

            case "steps":
                // Expect numbered lines: 1. Step description
                let stepPattern = #"^\d+\.\s+"#
                var stepRegexMatch = false
                do {
                    let regex = try NSRegularExpression(pattern: stepPattern)
                    if regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                        stepRegexMatch = true
                        let step = trimmed.replacingOccurrences(
                            of: #"^\d+\.\s+"#,
                            with: "",
                            options: .regularExpression
                        )
                        steps.append(step)
                    }
                } catch {
                    logger.error("Failed to compile step-parsing regex '\(stepPattern)': \(error.localizedDescription)")
                    NSLog("CyclopOne [SkillLoader]: Step-parsing regex failed: '%@' — %@", stepPattern, error.localizedDescription)
                }
                if !stepRegexMatch && (trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")) {
                    steps.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                }

            case "permissions":
                // Expect lines like: - tool_name: tier1
                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    let entry = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    let parts = entry.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2 {
                        permissions[parts[0]] = parts[1]
                    }
                }

            case "maxiterations":
                if let value = Int(trimmed) {
                    maxIterations = value
                }

            default:
                break
            }
        }

        guard let skillName = name, !skillName.isEmpty, !triggers.isEmpty else {
            logger.warning("Invalid skill file (missing name or triggers): \(filePath ?? "unknown")")
            return nil
        }

        return Skill(
            name: skillName,
            description: description,
            triggers: triggers,
            steps: steps,
            permissions: permissions,
            maxIterations: maxIterations,
            isEnabled: true,
            filePath: filePath,
            isBuiltIn: false
        )
    }

    // MARK: - Skill Validation

    /// Validate all regex patterns in a skill file before saving.
    ///
    /// Parses the skill content, then attempts to compile every trigger regex.
    /// Returns an array of error descriptions for any invalid patterns.
    /// An empty array means all patterns are valid.
    ///
    /// - Parameter content: The SKILL.md file content to validate.
    /// - Returns: Array of validation error descriptions. Empty if all valid.
    func validateSkillFile(_ content: String) -> [String] {
        guard let skill = parseSkillContent(content) else {
            return ["Failed to parse skill file: missing name or triggers"]
        }

        var errors: [String] = []

        if skill.triggers.isEmpty {
            errors.append("Skill '\(skill.name)' has no trigger patterns defined")
        }

        for pattern in skill.triggers {
            do {
                _ = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            } catch {
                errors.append("Invalid regex '\(pattern)' in skill '\(skill.name)': \(error.localizedDescription)")
            }
        }

        if skill.steps.isEmpty {
            errors.append("Skill '\(skill.name)' has no steps defined")
        }

        return errors
    }

    /// Validate all trigger regex patterns across all loaded skills.
    ///
    /// Iterates every skill in `self.skills`, attempts to compile each trigger pattern,
    /// and collects errors. Logs a summary via NSLog and os.log.
    ///
    /// - Returns: A dictionary mapping skill names to arrays of error descriptions.
    ///            Skills with all valid triggers are omitted from the result.
    @discardableResult
    func validateSkillTriggers() -> [String: [String]] {
        var report: [String: [String]] = [:]

        for skill in skills {
            var errors: [String] = []
            for pattern in skill.triggers {
                do {
                    _ = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                } catch {
                    let msg = "Invalid regex '\(pattern)': \(error.localizedDescription)"
                    errors.append(msg)
                    logger.error("Skill '\(skill.name)' trigger validation failed — \(msg)")
                    NSLog("CyclopOne [SkillLoader]: Skill '%@' trigger validation failed — pattern='%@' error=%@",
                          skill.name, pattern, error.localizedDescription)
                }
            }

            if skill.triggers.isEmpty {
                let msg = "No trigger patterns defined"
                errors.append(msg)
                logger.warning("Skill '\(skill.name)' has no trigger patterns")
                NSLog("CyclopOne [SkillLoader]: Skill '%@' has no trigger patterns", skill.name)
            }

            if !errors.isEmpty {
                report[skill.name] = errors
            }
        }

        if report.isEmpty {
            logger.info("All \(self.skills.count) skill(s) passed trigger validation")
            NSLog("CyclopOne [SkillLoader]: All %d skill(s) passed trigger validation", skills.count)
        } else {
            let totalErrors = report.values.reduce(0) { $0 + $1.count }
            logger.warning("\(report.count) skill(s) have trigger errors (\(totalErrors) total)")
            NSLog("CyclopOne [SkillLoader]: %d skill(s) have trigger errors (%d total)", report.count, totalErrors)
        }

        return report
    }

    // MARK: - Private: UserDefaults Persistence

    private func disabledSkillNames() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: disabledSkillsKey) ?? []
        return Set(array)
    }

    private func saveDisabledSkillNames(_ names: Set<String>) {
        UserDefaults.standard.set(Array(names), forKey: disabledSkillsKey)
    }

    private func commandHistory() -> [String] {
        return UserDefaults.standard.stringArray(forKey: commandHistoryKey) ?? []
    }

    private func saveCommandHistory(_ history: [String]) {
        UserDefaults.standard.set(history, forKey: commandHistoryKey)
    }

    // MARK: - Private: Self-Authoring Pattern Detection

    /// Detect if the latest command is part of a repeated pattern.
    ///
    /// Uses a simple similarity metric to find clusters of 3+ similar commands.
    /// When a pattern is detected, suggests a skill definition.
    private func detectRepeatedPattern(in history: [String], latestCommand: String) -> SuggestedSkill? {
        // Only check the recent window
        let recentWindow = Array(history.suffix(30))

        // Find commands similar to the latest one
        var similarCommands: [String] = []
        for cmd in recentWindow {
            if commandSimilarity(cmd, latestCommand) >= similarityThreshold {
                similarCommands.append(cmd)
            }
        }

        guard similarCommands.count >= similarCommandThreshold else { return nil }

        // Check if we already have a skill that matches this pattern
        let existingMatch = matchSkills(for: latestCommand)
        if !existingMatch.isEmpty { return nil }

        // Build a suggested skill from the pattern
        let commonWords = extractCommonWords(from: similarCommands)
        let triggerPattern = buildTriggerPattern(from: commonWords)

        guard !triggerPattern.isEmpty else { return nil }

        let suggestedName = commonWords.prefix(3).joined(separator: "-")
        let suggestion = SuggestedSkill(
            name: suggestedName.isEmpty ? "custom-task" : suggestedName,
            description: "Auto-detected pattern from repeated commands: \(similarCommands.first ?? latestCommand)",
            triggers: [triggerPattern],
            steps: [
                "Execute the user's command as requested",
                "Take a screenshot to verify the result"
            ],
            permissions: [:],
            maxIterations: 10,
            exampleCommands: similarCommands
        )

        logger.info("Detected repeated pattern, suggesting skill: \(suggestedName)")
        return suggestion
    }

    /// Simple string similarity based on shared word overlap (Jaccard-like).
    private func commandSimilarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
        let wordsB = Set(b.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })

        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 0.0 }

        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count

        return Double(intersection) / Double(union)
    }

    /// Extract words that appear in the majority of the similar commands.
    private func extractCommonWords(from commands: [String]) -> [String] {
        var wordCounts: [String: Int] = [:]

        for cmd in commands {
            let words = Set(cmd.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
            for word in words {
                wordCounts[word, default: 0] += 1
            }
        }

        let threshold = commands.count / 2
        return wordCounts
            .filter { $0.value > threshold }
            .sorted { $0.value > $1.value }
            .map { $0.key }
            .filter { $0.count > 2 }  // Skip short words
    }

    /// Build a regex trigger pattern from common words.
    /// Validates the generated regex before returning it.
    /// Returns an empty string if the pattern cannot be compiled.
    private func buildTriggerPattern(from words: [String]) -> String {
        guard !words.isEmpty else { return "" }

        let escaped = words.prefix(4).map { NSRegularExpression.escapedPattern(for: $0) }
        // Build a pattern that matches if all key words are present (in any order)
        let parts = escaped.map { "(?=.*\\b\($0)\\b)" }
        let pattern = "(?i)" + parts.joined() + ".*"

        // Validate the generated pattern compiles before returning
        do {
            _ = try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            logger.error("Generated trigger pattern failed to compile: '\(pattern)' — \(error.localizedDescription)")
            NSLog("CyclopOne [SkillLoader]: Generated trigger pattern failed to compile: '%@' — %@", pattern, error.localizedDescription)
            return ""
        }

        return pattern
    }
}

// MARK: - SuggestedSkill

/// A skill suggestion generated by the self-authoring system.
struct SuggestedSkill: Sendable {
    let name: String
    let description: String
    let triggers: [String]
    let steps: [String]
    let permissions: [String: String]
    let maxIterations: Int
    let exampleCommands: [String]

    init(
        name: String,
        description: String,
        triggers: [String],
        steps: [String],
        permissions: [String: String] = [:],
        maxIterations: Int = 10,
        exampleCommands: [String] = []
    ) {
        self.name = name
        self.description = description
        self.triggers = triggers
        self.steps = steps
        self.permissions = permissions
        self.maxIterations = maxIterations
        self.exampleCommands = exampleCommands
    }
}
