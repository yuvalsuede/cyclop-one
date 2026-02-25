import Foundation

// MARK: - MemoryService+Retrieval
// Search, retrieval, context building, and relevant memory assembly.

extension MemoryService {

    // MARK: - Pre-Run Memory Loading

    /// Load core context that is always included in the system prompt.
    /// Contains user profile, active tasks, and current status (~500 tokens).
    func loadCoreContext() -> String {
        var sections: [String] = []

        for file in coreFiles {
            if hasBeenModified(file) {
                NSLog("MemoryService: Core file modified by user: %@", file)
            }
            if let content = readFile(file) {
                let trimmed = String(content.prefix(4000))
                let label = file
                    .replacingOccurrences(of: ".md", with: "")
                    .replacingOccurrences(of: "Identity/", with: "")
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
    /// Sprint 7: Raised default budget from 4,000 to 15,000 tokens.
    /// Section budgets proportionally increased. TF-IDF scoring with recency
    /// weighting replaces raw keyword count for broader vault search.
    func retrieveRelevantMemories(for command: String, tokenBudget: Int = 15000) -> String {
        let charBudget = Int(Double(tokenBudget) * tokenCharRatio)
        var sections: [(priority: Int, label: String, content: String)] = []

        // Priority 1: User profile (always included)
        if let profile = readFile("Identity/user-profile.md") {
            sections.append((priority: 1, label: "user_profile", content: truncate(profile, maxChars: 3000)))
        }

        // Priority 2: Recent context (working memory)
        if let recent = readFile("Context/recent-actions.md") {
            let lastEntries = extractLastEntries(recent, count: 10)
            if !lastEntries.isEmpty {
                sections.append((priority: 2, label: "recent_context", content: truncate(lastEntries, maxChars: 4000)))
            }
        }

        // Priority 3: App-specific knowledge
        let appNames = detectAppNames(in: command)
        for app in appNames {
            let slug = app.lowercased().replacingOccurrences(of: " ", with: "-")
            if let knowledge = readFile("Knowledge/apps/\(slug).md") {
                sections.append((priority: 3, label: "app_knowledge_\(slug)", content: truncate(knowledge, maxChars: 3000)))
            }
        }

        // Priority 4: Matching task templates
        let templates = findMatchingTemplates(for: command)
        if let best = templates.first {
            sections.append((priority: 4, label: "task_template", content: truncate(best, maxChars: 3000)))
        }

        // Priority 5: Relevant procedures (how we did similar tasks before)
        if let procedures = readFile("Learning/procedures.md") {
            let relevant = extractRelevantEntries(procedures, for: command)
            if !relevant.isEmpty {
                sections.append((priority: 5, label: "procedures", content: truncate(relevant, maxChars: 3000)))
            }
        }

        // Priority 6: Relevant failures to avoid
        if let failures = readFile("Learning/failures.md") {
            let relevant = extractRelevantEntries(failures, for: command)
            if !relevant.isEmpty {
                sections.append((priority: 6, label: "avoid_mistakes", content: truncate(relevant, maxChars: 2000)))
            }
        }

        // Priority 7: Search broader vault for relevant notes (TF-IDF + recency)
        let keywords = extractKeywords(from: command)
        if !keywords.isEmpty {
            let searchResults = searchVaultForKeywords(keywords, limit: 5, excludeFolders: ["Templates", ".obsidian"])
            if !searchResults.isEmpty {
                let formatted = searchResults.map { "**\($0.path)** (score: \(String(format: "%.1f", $0.score))): \($0.excerpt)" }.joined(separator: "\n\n")
                sections.append((priority: 7, label: "relevant_knowledge", content: truncate(formatted, maxChars: 4000)))
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

    /// Search vault for notes relevant to a command by TF-IDF scoring.
    func searchMemories(query: String, limit: Int = 5) -> String {
        let keywords = extractKeywords(from: query)
        guard !keywords.isEmpty else { return "" }

        let results = searchVaultForKeywords(keywords, limit: limit, excludeFolders: ["Templates", ".obsidian"])
        if results.isEmpty { return "" }

        return results.map { "**\($0.path)** (relevance: \(String(format: "%.1f", $0.score)))\n\($0.excerpt)" }
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

    // MARK: - Retrieval Helpers

    /// Truncate text to a maximum character count.
    func truncate(_ text: String, maxChars: Int) -> String {
        if text.count <= maxChars { return text }
        let truncated = String(text.prefix(maxChars))
        if let lastNewline = truncated.lastIndex(of: "\n") {
            return String(truncated[...lastNewline]) + "\n... (truncated)"
        }
        return truncated + "... (truncated)"
    }

    /// Extract the last N entries from a markdown list.
    func extractLastEntries(_ text: String, count: Int) -> String {
        let lines = text.components(separatedBy: "\n")
            .filter { $0.hasPrefix("- ") }
        let last = Array(lines.suffix(count))
        return last.joined(separator: "\n")
    }

    /// Detect app names referenced in a command string.
    /// Sprint 7: Expanded to include web apps (Gmail, YouTube, etc.) since
    /// these are commonly automated via Chrome and have app-specific knowledge.
    func detectAppNames(in command: String) -> [String] {
        let knownApps = [
            // Desktop apps
            "Chrome", "Safari", "Firefox", "Terminal", "iTerm",
            "VS Code", "Xcode", "Finder", "Mail", "Messages",
            "Slack", "Discord", "Telegram", "Notes", "Calendar",
            "Preview", "TextEdit", "System Preferences", "Activity Monitor",
            "Docker", "Figma", "Notion", "Obsidian", "Spotify",
            "Numbers", "Pages", "Keynote", "Photos", "Maps",
            // Web apps (automated via browser)
            "Gmail", "YouTube", "Google Docs", "Google Sheets",
            "GitHub", "Twitter", "LinkedIn", "WhatsApp Web",
            "ChatGPT", "Claude", "Amazon", "Reddit"
        ]

        let lower = command.lowercased()
        return knownApps.filter { lower.contains($0.lowercased()) }
    }

    /// Find task templates matching a command using trigger regex patterns.
    func findMatchingTemplates(for command: String) -> [String] {
        let templatesDir = vaultRoot.appendingPathComponent("Tasks/task-templates")
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
    func extractRelevantEntries(_ content: String, for command: String) -> String {
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

    /// Sprint 7: Search vault with TF-IDF scoring + recency weighting.
    ///
    /// Replaces raw keyword count with:
    /// 1. TF-IDF: term frequency normalized by document length
    /// 2. Recency boost: files modified recently score higher
    /// 3. Vault index cache: avoids FileManager.enumerator walk on every call
    func searchVaultForKeywords(
        _ keywords: [String],
        limit: Int,
        excludeFolders: [String] = []
    ) -> [(path: String, score: Double, excerpt: String)] {
        let fileList = getVaultFileIndex(excludeFolders: excludeFolders)

        var results: [(path: String, score: Double, excerpt: String)] = []

        for (relativePath, mtime) in fileList {
            let fileURL = vaultRoot.appendingPathComponent(relativePath)
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            let lower = content.lowercased()
            let docLength = max(lower.count, 1)

            // TF-IDF scoring: count occurrences, normalize by document length
            var tfScore: Double = 0
            for keyword in keywords {
                let lowerKeyword = keyword.lowercased()
                var searchRange = lower.startIndex..<lower.endIndex
                var occurrences = 0

                while let range = lower.range(of: lowerKeyword, range: searchRange) {
                    occurrences += 1
                    searchRange = range.upperBound..<lower.endIndex
                }

                if occurrences > 0 {
                    // TF: occurrences normalized by document length (per 100 chars)
                    let tf = Double(occurrences) / (Double(docLength) / 100.0)
                    // IDF approximation: rarer keywords in the query score higher
                    let idf = log2(Double(keywords.count + 1) / 1.0)
                    tfScore += tf * idf
                }
            }

            guard tfScore > 0 else { continue }

            // Recency boost: recent files are more relevant
            let daysSince = Date().timeIntervalSince(mtime) / 86400.0
            let recencyMultiplier: Double
            if daysSince < 1 {
                recencyMultiplier = 3.0
            } else if daysSince < 7 {
                recencyMultiplier = 2.0
            } else if daysSince < 30 {
                recencyMultiplier = 1.5
            } else {
                recencyMultiplier = 1.0
            }

            let finalScore = tfScore * recencyMultiplier
            let excerpt = extractExcerpt(from: content, keywords: keywords, maxLength: 400)
            results.append((path: relativePath, score: finalScore, excerpt: excerpt))
        }

        return results
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    /// Sprint 7: Get cached vault file index, rebuilding if stale (>60s).
    private func getVaultFileIndex(
        excludeFolders: [String]
    ) -> [(path: String, mtime: Date)] {
        let staleness = Date().timeIntervalSince(vaultIndexTimestamp)
        if staleness < 60.0 && !vaultIndex.isEmpty {
            // Return cached index, filtering excluded folders
            return vaultIndex.filter { entry in
                !excludeFolders.contains(where: { entry.path.hasPrefix($0) })
            }
        }

        // Rebuild index
        guard let enumerator = fm.enumerator(
            at: vaultRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var index: [(path: String, mtime: Date)] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "md" else { continue }

            let relativePath = fileURL.path
                .replacingOccurrences(of: vaultRoot.path + "/", with: "")

            let mtime: Date
            if let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let modDate = attrs.contentModificationDate {
                mtime = modDate
            } else {
                mtime = .distantPast
            }

            index.append((path: relativePath, mtime: mtime))
        }

        vaultIndex = index
        vaultIndexTimestamp = Date()

        NSLog("MemoryService: Rebuilt vault index — %d files", index.count)

        return index.filter { entry in
            !excludeFolders.contains(where: { entry.path.hasPrefix($0) })
        }
    }

    /// Extract keywords from text, filtering stop words and short tokens.
    func extractKeywords(from text: String) -> [String] {
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }

    /// Extract a relevant excerpt from content around matching keywords.
    func extractExcerpt(from content: String, keywords: [String], maxLength: Int) -> String {
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
}
