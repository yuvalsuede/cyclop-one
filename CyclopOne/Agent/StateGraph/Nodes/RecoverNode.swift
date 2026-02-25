import Foundation

// MARK: - Recover Node
// Attempts to break the agent out of a stuck state using escalating strategies.
// Sprint 3: Foundation. Sprint 9: Structured recovery strategy chain.

/// When the agent is stuck (repeated screenshots or text), this node:
/// 1. Reads the current recovery strategy index from GraphState
/// 2. Executes the corresponding strategy
/// 3. Injects guidance into the conversation
/// 4. Clears stuck tracking for a fresh attempt
/// 5. Increments recovery attempts and strategy index
///
/// The strategy chain tries cheap approaches first, escalates to expensive:
/// - Strategy 0: Rephrase (free — no API call)
/// - Strategy 1: Haiku suggestion (cheap API call via ModelTier.fast)
/// - Strategy 2: Backtrack (free — Escape/Cmd+Z instruction)
/// - Strategy 3: Brain consultation (expensive — Opus via brainModel)
/// - Strategy 4: Force complete (free — instructs agent to output task_complete)
///
/// If max recovery attempts are exceeded, the edge routing will
/// send the graph to COMPLETE instead of back to PERCEIVE.
///
/// Reads: command, stuckReason, iteration, preActionScreenshot,
///        hasEscalatedToBrain, currentRecoveryStrategy
/// Writes: recoveryAttempts, hasEscalatedToBrain, recoveryStrategyIndex,
///         clears stuck state
final class RecoverNode: StateNode, @unchecked Sendable {

    let nodeId = GraphNodeId.recover

    // MARK: - Dependencies

    /// Agent loop for injecting guidance into conversation.
    private weak var agentLoop: AgentLoop?

    /// Observe node for clearing stuck detection state.
    private let observeNode: ObserveNode

    /// Screen capture service (retained for future strategies).
    private let captureService: ScreenCaptureService

    /// Accessibility service (retained for future strategies).
    private let accessibilityService: AccessibilityService

    /// Brain model name (e.g. Opus) for Strategy 3.
    private let brainModel: String

    /// Chat message callback.
    private let onMessage: (@Sendable (ChatMessage) -> Void)?

    /// Total number of recovery strategies in the chain (0-4).
    private static let strategyCount = 5

    // MARK: - Init

    init(
        agentLoop: AgentLoop? = nil,
        observeNode: ObserveNode,
        captureService: ScreenCaptureService,
        accessibilityService: AccessibilityService = .shared,
        brainModel: String = AgentConfig.defaultBrainModel,
        onMessage: (@Sendable (ChatMessage) -> Void)? = nil
    ) {
        self.agentLoop = agentLoop
        self.observeNode = observeNode
        self.captureService = captureService
        self.accessibilityService = accessibilityService
        self.brainModel = brainModel
        self.onMessage = onMessage
    }

    // MARK: - Execute

    func execute(state: GraphState) async throws {
        try Task.checkCancellation()

        let command = await state.command
        let stuckReason = await state.stuckReason
        let iter = await state.iteration
        let strategyIndex = await state.currentRecoveryStrategy
        let attempts = await state.incrementRecoveryAttempts()

        // Clamp strategy index to valid range (0-4)
        let strategy = min(strategyIndex, Self.strategyCount - 1)
        let strategyName = Self.strategyLabel(strategy)

        NSLog(
            "CyclopOne [RecoverNode]: Recovery attempt %d — strategy %d: %@, reason=%@, iteration=%d",
            attempts, strategy, strategyName, stuckReason, iter
        )

        onMessage?(ChatMessage(
            role: .system,
            content: "Agent stuck (\(stuckReason)) — trying recovery strategy \(strategy): \(strategyName)..."
        ))

        // Execute the selected strategy (0=rephrase, 1=haiku, 2=backtrack, 3=brain, 4=force)
        let guidance: String
        switch strategy {
        case 0:
            guidance = executeRephrase()
        case 1:
            guidance = await executeHaikuSuggestion(
                command: command, stuckReason: stuckReason, state: state
            )
        case 2:
            guidance = executeBacktrack()
        case 3:
            guidance = await executeBrainConsult(
                command: command, stuckReason: stuckReason,
                iteration: iter, state: state
            )
            await state.setEscalatedToBrain(true)
        default:
            guidance = executeForceComplete()
        }

        // Inject guidance into the conversation
        if let loop = agentLoop, !guidance.isEmpty {
            await loop.injectBrainGuidance(guidance)
            NSLog(
                "CyclopOne [RecoverNode]: Strategy %d (%@) guidance injected (%d chars)",
                strategy, strategyName, guidance.count
            )
        }

        // Advance to the next strategy for the next RECOVER invocation
        await state.incrementRecoveryStrategy()

        // Clear stuck state and tracking so the agent gets a fresh attempt
        await state.clearStuck()
        observeNode.clearStuckTracking()

        NSLog(
            "CyclopOne [RecoverNode]: Recovery attempt %d (%@) complete, stuck tracking cleared",
            attempts, strategyName
        )
    }

    // MARK: - Strategy 0: Rephrase (free)

    /// Inject a simple instruction to try a different approach. No API call.
    private func executeRephrase() -> String {
        return """
        Your previous approach isn't working. Try a completely different method \
        to accomplish the goal. Do NOT repeat any actions you have already tried. \
        Consider alternative UI paths, keyboard shortcuts, menu items, or different \
        applications that could achieve the same result.
        """
    }

    // MARK: - Strategy 1: Haiku Suggestion (cheap API call)

    /// Ask Haiku for one alternative approach. Much cheaper than the brain model.
    private func executeHaikuSuggestion(
        command: String,
        stuckReason: String,
        state: GraphState
    ) async -> String {
        let prompt = """
        The agent is stuck doing: "\(command)". \
        Reason: \(stuckReason). \
        Suggest one specific alternative approach in 2-3 sentences.
        """

        do {
            let response = try await ClaudeAPIService.shared.sendMessage(
                messages: [APIMessage.userText(prompt)],
                systemPrompt: "You suggest alternative approaches for a stuck desktop automation agent. Be concise.",
                tools: [],
                model: ModelTier.fast.modelName,
                maxTokens: 512
            )

            let suggestion = response.textContent
            await state.addTokens(
                input: response.inputTokens, output: response.outputTokens
            )

            NSLog("CyclopOne [RecoverNode]: Haiku suggestion received (%d chars)",
                  suggestion.count)
            return suggestion.isEmpty ? executeRephrase() : suggestion
        } catch {
            NSLog("CyclopOne [RecoverNode]: Haiku suggestion failed: %@",
                  error.localizedDescription)
            return executeRephrase()
        }
    }

    // MARK: - Strategy 2: Backtrack (free)

    /// Instruct the agent to undo recent actions and try a different path.
    private func executeBacktrack() -> String {
        return """
        Press Escape or Cmd+Z to undo the last action, then try a different approach. \
        Dismiss any open menus, dialogs, or popups first. After clearing the current \
        state, take a fresh screenshot to see where you are. Consider using: \
        - The menu bar instead of right-clicking \
        - Spotlight (Cmd+Space) to open applications \
        - Keyboard shortcuts instead of mouse clicks \
        - A completely different starting point
        """
    }

    // MARK: - Strategy 3: Brain Consultation (expensive, Opus)

    /// Full brain model consultation with screenshot context.
    /// Only reached after strategies 0-2 have been tried.
    private func executeBrainConsult(
        command: String,
        stuckReason: String,
        iteration: Int,
        state: GraphState
    ) async -> String {
        let brainPrompt = """
        The agent executing the task "\(command)" is stuck. \
        Reason: \(stuckReason). \
        The agent has completed \(iteration) iterations so far. \
        Three cheaper recovery strategies (rephrase, haiku suggestion, backtrack) \
        have already been tried and failed. \
        Look at the current screenshot and assess: \
        1. What is the current state of the screen? \
        2. What progress has been made toward the task? \
        3. Provide 2-3 concise, specific suggestions for what the agent should try. \
        Focus on alternative approaches, not repeating what failed.
        """

        do {
            let preScreenshot = await state.preActionScreenshot
            let brainMessage: APIMessage
            if let ss = preScreenshot {
                brainMessage = APIMessage.userWithScreenshot(
                    text: brainPrompt, screenshot: ss, uiTreeSummary: nil
                )
            } else {
                brainMessage = APIMessage.userText(brainPrompt)
            }

            let response = try await ClaudeAPIService.shared.sendMessage(
                messages: [brainMessage],
                systemPrompt: "You are a strategic advisor helping an autonomous desktop agent get unstuck. You can see the current screen state. Be concise and actionable.",
                tools: [],
                model: brainModel,
                maxTokens: 1024
            )

            let advice = response.textContent
            await state.addTokens(
                input: response.inputTokens, output: response.outputTokens
            )

            NSLog("CyclopOne [RecoverNode]: Brain response received (%d chars)",
                  advice.count)
            return advice
        } catch {
            NSLog("CyclopOne [RecoverNode]: Brain consultation failed: %@",
                  error.localizedDescription)
            onMessage?(ChatMessage(
                role: .system,
                content: "Brain consultation failed: \(error.localizedDescription)"
            ))
            return ""
        }
    }

    // MARK: - Strategy 4: Force Complete (free)

    /// All strategies exhausted. Instruct the agent to give up gracefully.
    private func executeForceComplete() -> String {
        return """
        You have exhausted all recovery strategies. Output <task_complete/> now \
        with a summary of what you accomplished and what could not be completed.
        """
    }

    // MARK: - Helpers

    /// Human-readable label for a strategy index.
    private static func strategyLabel(_ index: Int) -> String {
        switch index {
        case 0: return "Rephrase"
        case 1: return "Haiku suggestion"
        case 2: return "Backtrack"
        case 3: return "Brain consultation"
        case 4: return "Force complete"
        default: return "Unknown (\(index))"
        }
    }
}
