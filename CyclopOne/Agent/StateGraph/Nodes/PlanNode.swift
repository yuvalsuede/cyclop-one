import Foundation

// MARK: - Plan Node
// Sends conversation to Claude API and stores the response.
// Maps to: AgentLoop.executeIteration() lines ~119-180 (API call, response handling)

/// Builds the system prompt, sends conversation to Claude, stores response.
/// Reads: preActionScreenshot, uiTreeSummary, command
/// Writes: claudeResponse, hasToolCalls, textContent, token counts
///
/// Sprint 3: Foundation node. Sprint 4 integrates with AgentLoop's
/// conversation history management and full system prompt assembly.
final class PlanNode: StateNode, @unchecked Sendable {

    let nodeId = GraphNodeId.plan

    // MARK: - Dependencies

    /// The agent loop handles conversation history, system prompt building,
    /// and the actual Claude API call with retry logic.
    private weak var agentLoop: AgentLoop?

    /// Callbacks for state change and message forwarding.
    /// Set during graph construction (Sprint 4).
    private let onStateChange: (@Sendable (AgentState) -> Void)?
    private let onMessage: (@Sendable (ChatMessage) -> Void)?

    // MARK: - Init

    init(
        agentLoop: AgentLoop? = nil,
        onStateChange: (@Sendable (AgentState) -> Void)? = nil,
        onMessage: (@Sendable (ChatMessage) -> Void)? = nil
    ) {
        self.agentLoop = agentLoop
        self.onStateChange = onStateChange
        self.onMessage = onMessage
    }

    // MARK: - Execute

    func execute(state: GraphState) async throws {
        try Task.checkCancellation()

        let iter = await state.iteration
        NSLog("CyclopOne [PlanNode]: Starting API call for iteration %d", iter)

        guard let loop = agentLoop else {
            NSLog("CyclopOne [PlanNode]: No AgentLoop available, marking error")
            await state.markError("PlanNode: AgentLoop not available")
            return
        }

        // Notify UI that the agent is thinking
        onStateChange?(.thinking)

        // Sprint 7 Refactoring: Refresh memory context every 10 iterations.
        // Keeps long-running tasks from losing earlier context as the conversation
        // grows and older messages get pruned.
        let lastRefresh = await state.lastMemoryRefreshIteration
        if iter - lastRefresh >= 10 {
            let command = await state.command
            let mem = MemoryService.shared
            let core = await mem.loadCoreContext()
            let relevant = await mem.retrieveRelevantMemories(for: command)
            let history = await mem.loadRecentRunSummaries(limit: 3)
            let refreshedContext = await mem.buildContextString(
                core: core, relevant: relevant, history: history
            )
            await state.setMemoryContext(refreshedContext, atIteration: iter)
            await loop.setMemoryContext(refreshedContext)
            NSLog("CyclopOne [PlanNode]: Memory context refreshed at iteration %d — %d chars",
                  iter, refreshedContext.count)
        }

        // Build system prompt (includes skill context, memory context,
        // step instruction, completion protocol)
        var systemPrompt = await loop.buildIterationSystemPrompt()

        // Sprint 9: When screenshot is unavailable, append guidance to rely on AX tree
        let ssAvailable = await state.screenshotAvailable
        if !ssAvailable {
            systemPrompt += "\n\n[NOTICE: Screenshot is currently unavailable. Rely on the accessibility tree for UI state. Use keyboard navigation (Tab, arrow keys, Enter) when possible instead of mouse coordinates.]"
            NSLog("CyclopOne [PlanNode]: Screenshot unavailable — appended AX-tree guidance to system prompt")
        }

        try Task.checkCancellation()

        // Sprint 6: Validate and repair conversation history before API call
        await loop.validateBeforeSend()

        // Send to Claude API with retry logic (exponential backoff, 429 handling)
        let response: ClaudeResponse
        do {
            response = try await loop.sendAPIWithRetry(
                systemPrompt: systemPrompt,
                onMessage: onMessage ?? { _ in }
            )
        } catch {
            NSLog("CyclopOne [PlanNode]: API call failed: %@", error.localizedDescription)
            await state.markError("API call failed: \(error.localizedDescription)")
            throw error
        }

        // TODO: Sprint 4 — Append assistant message to conversation history.
        // In the current architecture, conversation management is internal to AgentLoop.
        // When the graph is fully wired, PlanNode will use a dedicated method on AgentLoop
        // to append the assistant message without directly accessing the conversation property.

        // Forward text content to chat UI
        let text = response.textContent
        if !text.isEmpty {
            onMessage?(ChatMessage(role: .assistant, content: text))
        }

        // Store response in graph state
        await state.setClaudeResponse(response)
        await state.addTokens(input: response.inputTokens, output: response.outputTokens)

        NSLog("CyclopOne [PlanNode]: API response received — tier=smart, hasToolUse=%d, textLen=%d, tokens=%d/%d",
              response.hasToolUse ? 1 : 0, text.count,
              response.inputTokens, response.outputTokens)
    }
}
