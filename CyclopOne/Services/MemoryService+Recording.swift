import Foundation

// MARK: - MemoryService+Recording
// Recording run completions, verification rejections, command patterns,
// app knowledge, preferences, status updates, consolidation, and daily summaries.

extension MemoryService {

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
        - **Daily:** [[Daily/\(Self.todayString())]]
        """
        try? appendToNote(at: "Tasks/task-log.md", text: logEntry)

        // Working memory: recent actions
        let recentEntry = "- [\(timeString())] \(outcome.command) (\(statusLabel.lowercased()))"
        try? appendToNote(at: "Context/recent-actions.md", text: recentEntry)

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
        try? appendToNote(at: "Learning/failures.md", text: entry)
    }

    /// Record a user correction (when user retries with a modified command).
    func recordUserCorrection(originalCommand: String, correctedCommand: String) {
        let entry = """

        ## \(ISO8601DateFormatter().string(from: Date()))
        - **Original:** \(originalCommand)
        - **Corrected:** \(correctedCommand)
        """
        try? appendToNote(at: "Learning/corrections.md", text: entry)
    }

    /// Update app-specific knowledge.
    func updateAppKnowledge(appName: String, insight: String) {
        let slug = appName.lowercased().replacingOccurrences(of: " ", with: "-")
        let path = "Knowledge/apps/\(slug).md"

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
        try? appendToNote(at: "Identity/preferences.md", text: entry)
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
        let entry = "- **\(command)** failed after \(iterations) iterations: \(reason) (\(Self.todayString())) — see [[Learning/failures|Failure Log]]"
        try? appendToNote(at: "Known Issues.md", text: entry)
    }

    // MARK: - Procedural Memory (Sprint 7)

    /// Record how a task was accomplished for future retrieval.
    /// Called after successful runs with score >= 70. Saves the command,
    /// key steps taken, and app used so similar future tasks can benefit.
    func recordProceduralMemory(command: String, toolCalls: [(name: String, summary: String)], appName: String?) {
        guard !toolCalls.isEmpty else { return }

        // Deduplicate consecutive same-tool calls (e.g., multiple click_element)
        var steps: [String] = []
        var lastTool = ""
        var repeatCount = 0

        for call in toolCalls {
            if call.name == lastTool {
                repeatCount += 1
            } else {
                if repeatCount > 1 {
                    steps.append("  (repeated \(repeatCount)x)")
                }
                let summary = String(call.summary.prefix(80))
                steps.append("- `\(call.name)`: \(summary)")
                lastTool = call.name
                repeatCount = 1
            }
        }
        if repeatCount > 1 {
            steps.append("  (repeated \(repeatCount)x)")
        }

        // Limit to first 10 steps to keep procedures concise
        let trimmedSteps = Array(steps.prefix(10))
        let stepsText = trimmedSteps.joined(separator: "\n")

        let entry = """

        ## \(Self.todayString()) — \(command.prefix(80))
        **App:** \(appName ?? "unknown")
        **Steps (\(toolCalls.count) total):**
        \(stepsText)
        """

        try? appendToNote(at: "Learning/procedures.md", text: entry)

        // Also update app-specific knowledge with the procedure
        if let app = appName {
            let procedureNote = "Procedure for \"\(command.prefix(60))\": \(toolCalls.count) steps (\(Self.todayString()))"
            updateAppKnowledge(appName: app, insight: procedureNote)
        }

        NSLog("MemoryService: Recorded procedural memory — %d steps for: %@",
              toolCalls.count, String(command.prefix(60)))
    }

    // MARK: - Task-Scoped Memory (Sprint 7 Refactoring)

    /// Record a step outcome during execution for incremental learning.
    /// Called after each iteration so that partial progress is preserved
    /// even if the run fails before completion.
    func recordStepOutcome(command: String, step: String, action: String, success: Bool) {
        let status = success ? "ok" : "FAIL"
        let entry = "- [\(timeString())] [\(status)] \(action) — \(step)"
        try? appendToNote(at: "Context/current-run-steps.md", text: entry)
    }

    /// Clear the current run context file at run start.
    /// Ensures stale data from a previous run doesn't bleed in.
    func clearCurrentRunContext() {
        let header = """
        # Current Run Steps
        _Auto-recorded during execution. Cleared at run start._

        """
        try? writeNote(at: "Context/current-run-steps.md", content: header)
    }

    /// Persist the current run context at run end.
    /// On success, appends the steps to Learning/procedures.md as a procedure.
    /// On failure, appends to Learning/failures.md for avoidance learning.
    func persistCurrentRunContext(command: String, success: Bool) {
        guard let content = readFile("Context/current-run-steps.md") else { return }

        // Extract just the step lines (skip header)
        let steps = content.components(separatedBy: "\n")
            .filter { $0.hasPrefix("- [") }
        guard !steps.isEmpty else { return }

        let stepsText = steps.suffix(20).joined(separator: "\n")
        let label = success ? "Succeeded" : "Failed"

        let entry = """

        ## \(Self.todayString()) — \(command.prefix(80))
        **Outcome:** \(label)
        **Steps recorded during execution:**
        \(stepsText)
        """

        if success {
            try? appendToNote(at: "Learning/procedures.md", text: entry)
        } else {
            try? appendToNote(at: "Learning/failures.md", text: entry)
        }

        NSLog("MemoryService: Persisted run context — %d steps, %@",
              steps.count, label)
    }

    // MARK: - Consolidation

    /// Consolidate episodic memories into patterns (run periodically).
    func consolidateMemories() {
        // Prune recent-actions to last 50 entries
        if let content = readFile("Context/recent-actions.md") {
            let lines = content.components(separatedBy: "\n")
            if lines.count > 60 {
                let header = lines.first ?? "# Recent Actions"
                let kept = Array(lines.suffix(50))
                let pruned = [header, ""] + kept
                try? writeNote(at: "Context/recent-actions.md", content: pruned.joined(separator: "\n"))
                NSLog("MemoryService: Pruned recent-actions to 50 entries")
            }
        }

        // Prune task-log to last 200 entries
        if let content = readFile("Tasks/task-log.md") {
            let sections = content.components(separatedBy: "\n## ")
            if sections.count > 210 {
                let header = sections.first ?? "# Task Log"
                let kept = sections.suffix(200)
                let pruned = header + "\n\n## " + kept.joined(separator: "\n## ")
                try? writeNote(at: "Tasks/task-log.md", content: pruned)
                NSLog("MemoryService: Pruned task-log to 200 entries")
            }
        }

        // Sprint 7: Prune procedures to last 50 entries
        if let content = readFile("Learning/procedures.md") {
            let sections = content.components(separatedBy: "\n## ")
            if sections.count > 55 {
                let header = sections.first ?? "# Procedures"
                let kept = sections.suffix(50)
                let pruned = header + "\n\n## " + kept.joined(separator: "\n## ")
                try? writeNote(at: "Learning/procedures.md", content: pruned)
                NSLog("MemoryService: Pruned procedures to 50 entries")
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
        try? appendToNote(at: "Context/daily-summary.md", text: summaryEntry)
    }
}
