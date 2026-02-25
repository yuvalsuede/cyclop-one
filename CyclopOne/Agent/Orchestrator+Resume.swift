import Foundation

// MARK: - Orchestrator Run Resume
// Resume incomplete runs from crash recovery journal.
// Extracted from Orchestrator.swift in Sprint 1 (Refactoring).

extension Orchestrator {

    // MARK: - Sprint 16: Resume Run

    /// Resume an incomplete run detected on launch.
    ///
    /// Replays the JSONL journal to reconstruct state (command, iteration count,
    /// tool history), takes a fresh screenshot, restores conversation history
    /// in the AgentLoop, and resumes execution from the last committed iteration.
    ///
    /// - Parameters:
    ///   - runId: The ID of the incomplete run to resume.
    ///   - agentLoop: The agent loop instance to execute iterations with.
    ///   - replyChannel: Optional reply channel for routing results.
    ///   - onStateChange: Callback for state transitions.
    ///   - onMessage: Callback for chat messages.
    ///   - onConfirmationNeeded: Callback for destructive action approval.
    ///   - observer: Optional AgentObserver for real-time feedback.
    /// - Returns: The run result, or `nil` if the run could not be resumed.
    func resumeRun(
        runId: String,
        agentLoop: AgentLoop,
        replyChannel: (any ReplyChannel)? = nil,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void,
        onConfirmationNeeded: @Sendable @escaping (String) async -> Bool,
        observer: (any AgentObserver)? = nil
    ) async -> RunResult? {
        // Replay the journal to get the run state
        guard let replayedState = RunJournal.replayRunState(runId: runId) else {
            onMessage(ChatMessage(role: .system, content: "Cannot resume run \(runId): journal replay failed."))
            return nil
        }

        // Check if the run is too old to resume (> 1 hour)
        if RunJournal.isRunStale(runId: runId) {
            RunJournal.markAbandoned(runId: runId)
            let msg = "Abandoned stale task: \(replayedState.command). It was interrupted over an hour ago."
            onMessage(ChatMessage(role: .system, content: msg))
            if let channel = replyChannel {
                await channel.sendText(msg)
            }
            return nil
        }

        // Set up run tracking via lifecycle manager (startTracking resets all per-run state)
        lifecycle.startTracking(runId: runId, command: replayedState.command)
        lifecycle.currentIteration = replayedState.iterationCount

        stepMachine.resetForNewRun()
        stepMachine.stuckThreshold = runConfig.stuckThreshold
        await apiCircuitBreaker.reset()

        // Open the journal for appending (resume writing to the same file)
        let journal = RunJournal(runId: runId)
        do {
            try await journal.open()
        } catch {
            lifecycle.endRun()
            onMessage(ChatMessage(role: .system, content: "Cannot resume run: journal open failed."))
            return nil
        }

        await journal.append(RunEvent(type: .iterationStart, timestamp: Date(), iteration: replayedState.iterationCount + 1, reason: "Resumed after crash"))

        // Generate a new completion token for the resumed run
        let completionToken = lifecycle.generateCompletionToken()

        // Take a fresh screenshot to assess current state
        let freshScreenshot = await agentLoop.prepareRun(
            userMessage: replayedState.command,
            completionToken: completionToken,
            onStateChange: onStateChange,
            onMessage: onMessage
        )

        // Instead of using prepareRun's conversation (which starts clean),
        // restore the conversation with journal context
        await agentLoop.restoreForResume(
            command: replayedState.command,
            completionToken: completionToken,
            toolEvents: replayedState.toolEvents,
            screenshot: freshScreenshot
        )

        if let ssData = freshScreenshot?.imageData {
            await journal.saveScreenshot(ssData, name: "resume_pre.jpg")
        }
        stepMachine.preActionScreenshot = freshScreenshot

        // Notify about the resume
        let resumeMsg = "Resumed task: \(replayedState.command). Continuing from step \(replayedState.iterationCount + 1)."
        onMessage(ChatMessage(role: .system, content: resumeMsg))
        if let channel = replyChannel {
            await channel.sendText(resumeMsg)
        }

        // Continue the iteration loop from where we left off
        return await runIterationLoop(
            runId: runId,
            command: replayedState.command,
            completionToken: completionToken,
            startIteration: replayedState.iterationCount,
            totalInput: 0,
            totalOutput: 0,
            journal: journal,
            agentLoop: agentLoop,
            replyChannel: replyChannel,
            onStateChange: onStateChange,
            onMessage: onMessage,
            onConfirmationNeeded: onConfirmationNeeded,
            observer: observer
        )
    }
}
