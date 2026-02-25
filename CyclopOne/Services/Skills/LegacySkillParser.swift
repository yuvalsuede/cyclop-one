import Foundation
import os.log

private let parserLogger = Logger(subsystem: "com.cyclop.one.app", category: "LegacySkillParser")

// MARK: - LegacySkillParser

/// Parses old `.md` SKILL file format into `SkillPackage` values.
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
struct LegacySkillParser {

    // MARK: - Parse from URL

    static func parse(_ url: URL) -> SkillPackage? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            parserLogger.warning("Cannot read skill file: \(url.path)")
            return nil
        }
        return parseContent(content, filePath: url.path, directoryURL: url.deletingLastPathComponent())
    }

    // MARK: - Parse from String

    static func parseContent(
        _ content: String,
        filePath: String?,
        directoryURL: URL? = nil
    ) -> SkillPackage? {
        let lines = content.components(separatedBy: .newlines)

        var name: String?
        var description = ""
        var triggers: [String] = []
        var steps: [String] = []
        var maxIterations = 15
        var currentSection: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("# SKILL:") {
                name = trimmed
                    .replacingOccurrences(of: "# SKILL:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            if trimmed.hasPrefix("## ") {
                currentSection = trimmed
                    .replacingOccurrences(of: "## ", with: "")
                    .lowercased()
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            guard !trimmed.isEmpty else { continue }

            switch currentSection {
            case "description":
                description = description.isEmpty ? trimmed : description + " " + trimmed

            case "triggers":
                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    var pattern = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if pattern.hasPrefix("`") && pattern.hasSuffix("`") {
                        pattern = String(pattern.dropFirst().dropLast())
                    }
                    if !pattern.isEmpty { triggers.append(pattern) }
                }

            case "steps":
                // Numbered list: "1. Step text"
                let stepRegex = #"^\d+\.\s+"#
                if let regex = try? NSRegularExpression(pattern: stepRegex),
                   regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                    let step = trimmed.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
                    steps.append(step)
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    steps.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                }

            case "maxiterations":
                if let val = Int(trimmed) { maxIterations = val }

            default:
                break
            }
        }

        guard let skillName = name, !skillName.isEmpty, !triggers.isEmpty else {
            parserLogger.warning("Invalid skill file (missing name or triggers): \(filePath ?? "unknown")")
            return nil
        }

        let manifest = SkillPackageManifest(
            name: skillName,
            version: "1.0.0",
            description: description,
            author: nil,
            triggers: triggers,
            steps: steps,
            tools: nil,
            permissions: nil,
            maxIterations: maxIterations,
            marketplace: nil
        )

        let sourceDir = directoryURL ?? URL(fileURLWithPath: filePath.flatMap { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? NSHomeDirectory())
        var pkg = SkillPackage(manifest: manifest, source: .user(directoryURL: sourceDir))
        pkg.isEnabled = true
        pkg.filePath = filePath
        return pkg
    }

    // MARK: - Serialize to .md

    /// Serialize a `SkillPackage` to the legacy SKILL.md format.
    static func serialize(_ pkg: SkillPackage) -> String {
        var lines: [String] = [
            "# SKILL: \(pkg.name)",
            "",
            "## Description",
            pkg.description,
            "",
            "## Triggers"
        ]
        for trigger in pkg.triggers {
            lines.append("- `\(trigger)`")
        }
        lines.append("")
        lines.append("## Steps")
        for (i, step) in pkg.steps.enumerated() {
            lines.append("\(i + 1). \(step)")
        }
        lines.append("")
        lines.append("## Permissions")
        if let permissions = pkg.manifest.permissions, !permissions.isEmpty {
            for perm in permissions { lines.append("- \(perm)") }
        } else {
            lines.append("- (none)")
        }
        lines.append("")
        lines.append("## MaxIterations")
        lines.append("\(pkg.maxIterations ?? 15)")
        return lines.joined(separator: "\n")
    }
}
