import Foundation
import AppKit

// MARK: - Orchestrator Helpers
// Meta-command handling, chat replies, memory recording, and utility methods.
// Extracted from Orchestrator.swift in Sprint 1 (Refactoring).

extension Orchestrator {

    // MARK: - Meta-Command Handling

    /// Handle meta-commands (status, stop, screenshot, help) directly.
    /// These bypass planning and the agent loop entirely.
    func handleMetaCommand(
        _ command: MetaCommandType,
        replyChannel: (any ReplyChannel)?,
        onMessage: @Sendable @escaping (ChatMessage) -> Void
    ) async -> String {
        switch command {
        case .status:
            let status = getStatus()
            let msg = status.isRunning
                ? "Running: \(status.currentCommand ?? "unknown") — iteration \(status.iterationCount), \(status.durationString ?? "?")"
                : "Idle — no active task."
            if let rc = replyChannel { await rc.sendText(msg) }
            onMessage(ChatMessage(role: .assistant, content: msg))
            return msg

        case .stop:
            cancelCurrentRun()
            let msg = "Cancellation requested."
            if let rc = replyChannel { await rc.sendText(msg) }
            onMessage(ChatMessage(role: .assistant, content: msg))
            return msg

        case .screenshot:
            do {
                let capture = try await ScreenCaptureService.shared.captureScreen(maxDimension: 1280, quality: 0.7)
                if let rc = replyChannel { await rc.sendScreenshot(capture.imageData) }
                onMessage(ChatMessage(role: .system, content: "[Screenshot captured]"))
                return "Screenshot sent"
            } catch {
                let msg = "Screenshot failed: \(error.localizedDescription)"
                if let rc = replyChannel { await rc.sendText(msg) }
                return msg
            }

        case .help:
            let msg = """
            I'm Cyclop One, your desktop automation agent. I can:
            - Open and control apps on your Mac
            - Click, type, drag, and scroll
            - Search the web, fill forms, send messages
            - Take screenshots and read screen content

            Just tell me what to do in plain language.
            Say "stop" to cancel, "status" to check progress.

            Privacy: Screenshots of your screen are sent to Anthropic's Claude API \
            during active tasks only. No telemetry, no tracking, no background capture.
            """
            if let rc = replyChannel { await rc.sendText(msg) }
            onMessage(ChatMessage(role: .assistant, content: msg))
            return msg
        }
    }

    // MARK: - Chat Reply

    /// Generate a quick conversational reply for non-task messages (greetings, questions).
    /// Uses fast tier (Haiku) for speed — no tools, no screenshots, just a text response.
    func generateChatReply(command: String) async -> String {
        do {
            let response = try await ClaudeAPIService.shared.sendMessage(
                messages: [APIMessage.userText(command)],
                systemPrompt: "You are Cyclop One. Reply like a chill friend over text — super short, no introductions, no explaining what you are. Never say your name or what you do unless asked. Just vibe.",
                tools: [],
                tier: .fast,
                maxTokens: 256
            )
            return response.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            NSLog("CyclopOne [Orchestrator]: Chat reply failed: %@", error.localizedDescription)
            return "Hey! What's up?"
        }
    }

    // MARK: - Post-Run Memory Recording

    /// Record run outcome in memory service. Consolidated from duplicate blocks
    /// in both flat and step-driven loops.
    func recordRunCompletion(runId: String, command: String, passed: Bool, score: Int, reason: String, iteration: Int, agentLoop: AgentLoop? = nil) async {
        let outcome = RunOutcome(
            runId: runId, command: command, success: passed,
            score: score, iterations: iteration
        )
        await memoryService.recordRunOutcome(outcome)
        await memoryService.updateCurrentStatus(
            lastCommand: command,
            lastOutcome: passed ? "Success (score: \(score))" : "Failed (score: \(score))",
            timestamp: Date()
        )
        if !passed {
            await memoryService.recordFailure(
                command: command, reason: reason, iterations: iteration
            )
        }

        // Sprint 7: Record procedural memory for successful runs with decent scores.
        // Saves the step-by-step approach for future similar tasks.
        if passed && score >= 70, let agentLoop = agentLoop {
            let toolCalls = await agentLoop.getRunToolCallHistory()
            if !toolCalls.isEmpty {
                // Detect primary app from command
                let appNames = await memoryService.detectAppNames(in: command)
                let primaryApp = appNames.first
                await memoryService.recordProceduralMemory(
                    command: command,
                    toolCalls: toolCalls,
                    appName: primaryApp
                )
            }
        }

        // Consolidate procedural learnings from this run
        let capturedCommand = command
        let capturedApp: String? = await memoryService.detectAppNames(in: command).first
        let capturedSuccess = passed
        let capturedIterations = iteration
        let capturedRunId = runId
        Task {
            await ProceduralMemoryService.shared.consolidate(
                command: capturedCommand,
                appName: capturedApp,
                success: capturedSuccess,
                iterations: capturedIterations,
                runId: capturedRunId
            )
        }

        // Sprint 7 Refactoring: Track last run for correction detection
        lastRunCommand = command
        lastRunSuccess = passed
    }

    // MARK: - Classifier Context Update

    /// Update the intent classifier with the outcome of a completed run,
    /// so follow-up messages have context.
    func updateClassifierContext(command: String, result: RunResult) {
        let outcome = result.success ? "Success" : "Failed"
        let activeApp = NSWorkspace.shared.frontmostApplication?.localizedName
        Task {
            await intentClassifier.setLastRunContext(
                command: command, outcome: outcome, activeApp: activeApp
            )
        }
    }

    /// Forward the last assistant message to the intent classifier so short
    /// follow-ups like "yes", "no", "ok" can be resolved in context.
    func setLastAssistantMessage(_ message: String) {
        Task {
            await intentClassifier.setLastAssistantMessage(message)
        }
    }

    // MARK: - User Correction Detection (Sprint 7 Refactoring)

    /// Detect if the new command is a user correction of the last failed run.
    /// Heuristic: if the last run failed AND the new command shares 2+ keywords
    /// with the old one, the user is likely retrying with a different approach.
    func detectAndRecordUserCorrection(newCommand: String) async {
        guard let previousCommand = lastRunCommand, !lastRunSuccess else { return }

        let prevKeywords = Set(await memoryService.extractKeywords(from: previousCommand))
        let newKeywords = Set(await memoryService.extractKeywords(from: newCommand))

        // Need at least 2 shared keywords to count as a correction
        let overlap = prevKeywords.intersection(newKeywords)
        guard overlap.count >= 2 else { return }

        // Commands must be different (not an exact retry)
        guard previousCommand != newCommand else { return }

        await memoryService.recordUserCorrection(
            originalCommand: previousCommand,
            correctedCommand: newCommand
        )
        NSLog("CyclopOne [Orchestrator]: Detected user correction — '%@' -> '%@'",
              String(previousCommand.prefix(60)), String(newCommand.prefix(60)))
    }

    // MARK: - Utilities

    /// Check if a step outcome is a skip.
    func isSkipped(_ outcome: StepOutcome) -> Bool {
        if case .skipped = outcome { return true }
        return false
    }
}
