import Foundation

// MARK: - Complete Node
// Runs verification and finalizes the run.
// Maps to: Orchestrator+IterationLoops verification block (lines ~184-273)

/// Terminal node that runs VerificationEngine to score task completion.
///
/// Flow:
/// 1. If no visual tool calls were executed, auto-pass (score 100)
/// 2. Otherwise, run LLM verification with screenshot comparison
/// 3. If verification fails and rejections under limit, reject and loop back
/// 4. If passed or max rejections reached, finalize
///
/// Reads: command, anyToolCallsExecuted, anyVisualToolCallsExecuted,
///        postActionScreenshot, preActionScreenshot, textContent, toolCallSummaries
/// Writes: verificationScore, verificationPassed, verificationReason,
///         rejectedCompletions
///
/// Sprint 3: Foundation node. Sprint 4 wires journal recording and observer events.
final class CompleteNode: StateNode, @unchecked Sendable {

    let nodeId = GraphNodeId.complete

    // MARK: - Dependencies

    private let verificationEngine: VerificationEngine

    /// Agent loop for injecting verification feedback on rejection.
    private weak var agentLoop: AgentLoop?

    /// Verification threshold (0-100).
    private let verificationThreshold: Int

    /// Chat message callback.
    private let onMessage: (@Sendable (ChatMessage) -> Void)?

    /// State change callback.
    private let onStateChange: (@Sendable (AgentState) -> Void)?

    // MARK: - Init

    init(
        verificationEngine: VerificationEngine,
        agentLoop: AgentLoop? = nil,
        verificationThreshold: Int = VerificationScore.defaultThreshold,
        onStateChange: (@Sendable (AgentState) -> Void)? = nil,
        onMessage: (@Sendable (ChatMessage) -> Void)? = nil
    ) {
        self.verificationEngine = verificationEngine
        self.agentLoop = agentLoop
        self.verificationThreshold = verificationThreshold
        self.onStateChange = onStateChange
        self.onMessage = onMessage
    }

    // MARK: - Execute

    func execute(state: GraphState) async throws {
        try Task.checkCancellation()

        let command = await state.command
        let iter = await state.iteration
        let anyTools = await state.anyToolCallsExecuted
        let anyVisual = await state.anyVisualToolCallsExecuted
        let completionSource = await state.completionSource

        NSLog("CyclopOne [CompleteNode]: Running verification — iteration=%d, source=%@, anyTools=%d, anyVisual=%d",
              iter, completionSource, anyTools ? 1 : 0, anyVisual ? 1 : 0)

        // Determine verification score
        let score: Int
        let passed: Bool
        let reason: String

        let anySucceeded = await state.anyToolCallsSucceeded

        if !anyTools {
            // Text-only run: auto-pass
            score = 100
            passed = true
            reason = "Text-only run, auto-pass"
            NSLog("CyclopOne [CompleteNode]: Text-only run, auto-pass")
        } else if !anyVisual && anySucceeded {
            // Non-visual tools only and at least one succeeded: auto-pass
            score = 100
            passed = true
            reason = "Non-visual tools only, auto-pass"
            NSLog("CyclopOne [CompleteNode]: Non-visual tools, auto-pass")
        } else if !anySucceeded {
            // All tools failed: do NOT auto-pass, run verification
            let textContent = await state.textContent
            let postSS = await state.postActionScreenshot
            let preSS = await state.preActionScreenshot
            let toolResults = await state.toolCallSummaries

            let result = await verificationEngine.verify(
                command: command,
                textContent: textContent,
                postScreenshot: postSS,
                preScreenshot: preSS,
                toolResults: toolResults,
                threshold: verificationThreshold
            )
            score = result.overall
            passed = result.passed
            reason = result.reason
            NSLog("CyclopOne [CompleteNode]: All tools failed, verification — score=%d", score)
        } else {
            // Full LLM verification with screenshots
            let textContent = await state.textContent
            let postSS = await state.postActionScreenshot
            let preSS = await state.preActionScreenshot
            let toolResults = await state.toolCallSummaries

            let result = await verificationEngine.verify(
                command: command,
                textContent: textContent,
                postScreenshot: postSS,
                preScreenshot: preSS,
                toolResults: toolResults,
                threshold: verificationThreshold
            )

            score = result.overall
            passed = result.passed
            reason = result.reason

            // Track verification token usage
            let vInput = await verificationEngine.lastVerificationInputTokens
            let vOutput = await verificationEngine.lastVerificationOutputTokens
            await state.addVerificationTokens(input: vInput, output: vOutput)

            NSLog("CyclopOne [CompleteNode]: Verification — score=%d, passed=%d, reason=%@",
                  score, passed ? 1 : 0, reason)
        }

        // Handle verification result
        if !passed {
            let maxExceeded = await state.incrementRejectedCompletions()
            let rejections = await state.rejectedCompletions

            if !maxExceeded {
                // Rejection: clear completion, inject feedback, loop will route back
                await state.clearCompletion()

                let feedbackMsg = "Verification check: your completion was rejected. Score: \(score)/100. Reason: \(reason). Please try again."
                if let loop = agentLoop {
                    await loop.injectVerificationFeedback(feedbackMsg)
                }

                onMessage?(ChatMessage(
                    role: .system,
                    content: "Completion rejected -- verification score \(score)/100: \(reason) (attempt \(rejections)/\(await state.maxRejectedCompletions))"
                ))

                NSLog("CyclopOne [CompleteNode]: Completion rejected — score=%d, attempt=%d",
                      score, rejections)
                return
            }

            // Max rejections exceeded: force-complete
            NSLog("CyclopOne [CompleteNode]: Force-completing after %d rejected completions (score: %d)",
                  rejections, score)
        }

        // Accept completion
        await state.setVerificationResult(score: score, passed: passed, reason: reason)

        // Sprint 7 Refactoring: Persist task-scoped memory at run end.
        // Moves incremental step data to procedures (success) or failures (failure).
        await MemoryService.shared.persistCurrentRunContext(
            command: command, success: passed
        )

        NSLog("CyclopOne [CompleteNode]: Run complete — score=%d, passed=%d, iterations=%d",
              score, passed ? 1 : 0, iter)

        onStateChange?(.done)
    }
}
