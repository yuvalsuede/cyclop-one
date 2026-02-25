import Foundation
import os.log

private let authoringLogger = Logger(subsystem: "com.cyclop.one.app", category: "SkillRegistry+Authoring")

// MARK: - SkillRegistry Self-Authoring

extension SkillRegistry {

    // MARK: - Constants

    var maxCommandHistory: Int { 100 }
    var similarCommandThreshold: Int { 3 }
    var similarityThreshold: Double { 0.6 }

    private var commandHistoryKey: String { "CyclopOne_CommandHistory" }

    // MARK: - Command History

    func commandHistory() -> [String] {
        UserDefaults.standard.stringArray(forKey: commandHistoryKey) ?? []
    }

    func saveCommandHistory(_ history: [String]) {
        UserDefaults.standard.set(history, forKey: commandHistoryKey)
    }

    // MARK: - Record & Detect

    /// Record a command in history and detect repeated patterns.
    /// Returns a `SuggestedSkill` if a repeating pattern is found.
    func recordCommand(_ command: String) -> SuggestedSkill? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var history = commandHistory()
        history.append(trimmed)
        if history.count > maxCommandHistory {
            history = Array(history.suffix(maxCommandHistory))
        }
        saveCommandHistory(history)

        return detectRepeatedPattern(in: history, latestCommand: trimmed)
    }

    /// Detect if the latest command is part of a repeated pattern.
    func detectRepeatedPattern(in history: [String], latestCommand: String) -> SuggestedSkill? {
        let recentWindow = Array(history.suffix(30))
        var similarCommands: [String] = []
        for cmd in recentWindow {
            if commandSimilarity(cmd, latestCommand) >= similarityThreshold {
                similarCommands.append(cmd)
            }
        }

        guard similarCommands.count >= similarCommandThreshold else { return nil }

        // Don't suggest if we already match a skill
        if !matchSkills(for: latestCommand).isEmpty { return nil }

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

        authoringLogger.info("Detected repeated pattern, suggesting skill: \(suggestedName)")
        return suggestion
    }

    // MARK: - Write Skill File

    /// Write a new SKILL.md file for a suggested skill.
    @discardableResult
    func writeSkillFile(from suggestion: SuggestedSkill) -> String? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: skillsDirectory.path) {
            try? fm.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        }

        let sanitized = suggestion.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }

        let filePath = skillsDirectory.appendingPathComponent("\(sanitized).md")

        let manifest = SkillPackageManifest(
            name: suggestion.name,
            version: "1.0.0",
            description: suggestion.description,
            author: nil,
            triggers: suggestion.triggers,
            steps: suggestion.steps,
            tools: nil,
            permissions: nil,
            maxIterations: suggestion.maxIterations,
            marketplace: nil
        )
        var pkg = SkillPackage(manifest: manifest, source: .user(directoryURL: skillsDirectory))
        pkg.filePath = filePath.path

        let content = LegacySkillParser.serialize(pkg)

        // Validate before writing
        let errors = validateSkillContent(content)
        if !errors.isEmpty {
            for err in errors {
                authoringLogger.error("Skill validation failed: \(err)")
            }
            NSLog("CyclopOne [SkillRegistry]: Refusing to write skill '%@' — %d validation error(s)",
                  suggestion.name, errors.count)
            return nil
        }

        do {
            try content.write(to: filePath, atomically: true, encoding: .utf8)
            authoringLogger.info("Wrote skill file: \(filePath.path)")
            reload()
            return filePath.path
        } catch {
            authoringLogger.error("Failed to write skill file: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Validation

    func validateSkillContent(_ content: String) -> [String] {
        guard let pkg = LegacySkillParser.parseContent(content, filePath: nil) else {
            return ["Failed to parse skill content: missing name or triggers"]
        }
        var errors: [String] = []
        if pkg.triggers.isEmpty {
            errors.append("Skill '\(pkg.name)' has no trigger patterns defined")
        }
        if pkg.steps.isEmpty {
            errors.append("Skill '\(pkg.name)' has no steps defined")
        }
        for pattern in pkg.triggers {
            do {
                _ = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            } catch {
                errors.append("Invalid regex '\(pattern)' in skill '\(pkg.name)': \(error.localizedDescription)")
            }
        }
        return errors
    }
}
