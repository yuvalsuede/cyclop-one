import Foundation

// MARK: - Orchestrator Iteration Loops
// Main iteration loop dispatcher and flat iteration loop.
// Extracted from Orchestrator.swift in Sprint 1 (Refactoring).

extension Orchestrator {

    // MARK: - Shared Iteration Loop Dispatcher

    /// Dispatch to either the step-driven loop (when a plan exists) or
    /// the flat iteration loop (legacy behavior, simple tasks, failed parsing).
    func runIterationLoop(
        runId: String,
        command: String,
        completionToken: String,
        startIteration: Int,
        totalInput: Int,
        totalOutput: Int,
        journal: RunJournal,
        agentLoop: AgentLoop,
        replyChannel: (any ReplyChannel)?,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void,
        onConfirmationNeeded: @Sendable @escaping (String) async -> Bool,
        observer: (any AgentObserver)? = nil
    ) async -> RunResult {
        // M5: Start safety gate session for this run
        await agentLoop.startSafetyGateRun(runId: runId)

        let result: RunResult
        // If we have a non-empty plan, use the step-driven loop
        if let plan = stepMachine.currentPlan, !plan.isEmpty {
            result = await runStepDrivenLoop(
                runId: runId, command: command, completionToken: completionToken,
                plan: plan, startIteration: startIteration,
                totalInput: totalInput, totalOutput: totalOutput,
                journal: journal, agentLoop: agentLoop,
                replyChannel: replyChannel,
                onStateChange: onStateChange, onMessage: onMessage,
                onConfirmationNeeded: onConfirmationNeeded, observer: observer
            )
        } else {
            // No plan -- fall back to flat iteration loop (legacy behavior)
            result = await runFlatIterationLoop(
                runId: runId, command: command, completionToken: completionToken,
                startIteration: startIteration,
                totalInput: totalInput, totalOutput: totalOutput,
                journal: journal, agentLoop: agentLoop,
                replyChannel: replyChannel,
                onStateChange: onStateChange, onMessage: onMessage,
                onConfirmationNeeded: onConfirmationNeeded, observer: observer
            )
        }

        // M5: End safety gate session -- flush audit log
        await agentLoop.endSafetyGateRun()
        return result
    }

    // MARK: - Flat Iteration Loop

    /// Flat iteration loop -- now delegates to the graph-based execution.
    /// Sprint 4: The graph replaces the original flat while loop.
    /// The step-driven loop (runStepDrivenLoop) remains unchanged.
    func runFlatIterationLoop(
        runId: String,
        command: String,
        completionToken: String,
        startIteration: Int,
        totalInput: Int,
        totalOutput: Int,
        journal: RunJournal,
        agentLoop: AgentLoop,
        replyChannel: (any ReplyChannel)?,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void,
        onConfirmationNeeded: @Sendable @escaping (String) async -> Bool,
        observer: (any AgentObserver)? = nil
    ) async -> RunResult {
        return await runFlatLoopViaGraph(
            runId: runId,
            command: command,
            completionToken: completionToken,
            startIteration: startIteration,
            totalInput: totalInput,
            totalOutput: totalOutput,
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
