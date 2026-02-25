import Foundation

// MARK: - Evaluate Node
// Checks progress, completion, and stuck state after each iteration.
// Maps to: Orchestrator+IterationLoops completion/stuck detection block (lines ~138-178)

/// Examines the current iteration's results to determine whether the agent:
/// 1. Has completed the task (completion token or no tool calls)
/// 2. Is stuck (repeated screenshots/text)
/// 3. Should continue iterating
///
/// Sets flags in GraphState that the edge conditions use to route
/// to COMPLETE, RECOVER, or back to PERCEIVE.
///
/// Reads: textContent, hasToolCalls, iteration, anyToolCallsExecuted, toolCallSummaries
/// Writes: taskComplete, completionSource, isStuck, stuckReason, lastErrorClass
///
/// Sprint 3: Foundation node. Sprint 4 integrates with StepStateMachine.
/// Sprint 9: Error classification -- annotates GraphState with ErrorClass.
final class EvaluateNode: StateNode, @unchecked Sendable {

    let nodeId = GraphNodeId.evaluate

    // MARK: - Dependencies

    /// The observe node owns stuck detection state. EvaluateNode queries it.
    private let observeNode: ObserveNode

    /// Minimum iteration before stuck detection kicks in (avoid false positives
    /// during early iterations when the agent is still ramping up).
    private let stuckMinIteration: Int

    // MARK: - Init

    init(
        observeNode: ObserveNode,
        stuckMinIteration: Int = 2
    ) {
        self.observeNode = observeNode
        self.stuckMinIteration = stuckMinIteration
    }

    // MARK: - Execute

    func execute(state: GraphState) async throws {
        try Task.checkCancellation()

        let iter = await state.iteration
        let text = await state.textContent
        let hasTools = await state.hasToolCalls

        NSLog("CyclopOne [EvaluateNode]: Evaluating iteration %d -- hasToolCalls=%d, textLen=%d",
              iter, hasTools ? 1 : 0, text.count)

        // Check 1: Completion token in Claude's text response
        let completionTokenFound = containsCompletionToken(text)

        // Check 2: Claude indicated done (no tool calls returned)
        let claudeIndicatedDone = !hasTools

        if completionTokenFound || claudeIndicatedDone {
            let source = completionTokenFound ? "token match" : "Claude indicated done"
            await state.markComplete(source: source)

            NSLog("CyclopOne [EvaluateNode]: Completion signal detected -- source=%@, iteration=%d",
                  source, iter)
            return
        }

        // Sprint 9: Classify tool errors and annotate state for RecoverNode
        let summaries = await state.toolCallSummaries
        let failedCount = await state.failedToolCount
        let toolCount = summaries.count
        let errorClass = ErrorClassifier.classify(summaries: summaries)
        await state.setLastErrorClass(errorClass)

        if errorClass != .none && failedCount > 0 {
            NSLog("CyclopOne [EvaluateNode]: Error classification=%@, failedTools=%d/%d",
                  errorClass.rawValue, failedCount, toolCount)
        }

        // Sprint 9: For permanent errors, log prominently (cannot succeed by retrying)
        if errorClass == .permanent {
            NSLog("CyclopOne [EvaluateNode]: PERMANENT error detected -- agent should skip this action")
        }

        // Sprint 9: For resource errors, force complete to avoid wasting tokens
        if errorClass == .resource {
            await state.markComplete(source: "resource limit error detected")
            NSLog("CyclopOne [EvaluateNode]: Resource error -- force-completing, iteration=%d", iter)
            return
        }

        // Check 3: Stuck detection (only after minimum iterations)
        // Skip when the agent has more work to do AND tools succeeded this iteration.
        // Sprint 9: Also skip stuck detection for transient errors (retriable).
        let moreWork = await state.hasMoreWork
        let allToolsFailed = toolCount > 0 && failedCount == toolCount
        let isTransientOnly = errorClass == .transient && failedCount > 0

        if iter >= stuckMinIteration && (!moreWork || allToolsFailed) && !isTransientOnly {
            if let stuckReason = observeNode.detectStuck() {
                await state.markStuck(reason: stuckReason)
                NSLog("CyclopOne [EvaluateNode]: Stuck detected -- reason=%@, iteration=%d",
                      stuckReason, iter)
                return
            }
        }

        // Check 4: Global recovery limit exceeded -- force complete
        let totalRecoveries = await state.totalRecoveryAttempts
        let maxTotal = await state.maxTotalRecoveryAttempts
        if totalRecoveries >= maxTotal {
            await state.markComplete(source: "max total recovery attempts exceeded (\(totalRecoveries))")
            NSLog("CyclopOne [EvaluateNode]: Force-completing -- total recovery attempts %d >= %d",
                  totalRecoveries, maxTotal)
            return
        }

        // Log tool failure warning if most tools failed
        if toolCount > 0 && failedCount > toolCount / 2 {
            NSLog("CyclopOne [EvaluateNode]: WARNING -- %d/%d tools failed this iteration (errorClass=%@)",
                  failedCount, toolCount, errorClass.rawValue)
        }

        // Sprint 9: Agent is making progress -- reset recovery strategies
        // so the next stuck episode starts from strategy 0 (rephrase).
        let currentStrategy = await state.currentRecoveryStrategy
        if currentStrategy > 0 {
            await state.resetRecoveryStrategies()
            NSLog("CyclopOne [EvaluateNode]: Progress detected, reset recovery strategies")
        }

        // No completion, no stuck -- continue iterating
        NSLog("CyclopOne [EvaluateNode]: No completion or stuck signal, continuing (errorClass=%@)",
              errorClass.rawValue)
    }

    // MARK: - Completion Token Detection

    /// Detect the `<task_complete/>` marker in Claude's text response.
    /// Robust against whitespace variations, case differences, and minor formatting.
    private func containsCompletionToken(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
        return normalized.contains("<task_complete/>")
            || normalized.contains("<task_complete>")
    }
}
