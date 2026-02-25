import Foundation

// MARK: - Act Node
// Executes tool calls from Claude's response.
// Maps to: AgentLoop.executeIteration() tool execution loop (lines ~186-311)

/// Iterates over tool_use blocks from the Claude response, executes each via
/// the AgentLoop's tool execution infrastructure, collects results, and stores
/// them in GraphState.
///
/// If Claude returned no tool calls, this node is a no-op (the edge from PLAN
/// routes directly to EVALUATE when hasToolCalls is false).
///
/// Reads: claudeResponse, hasToolCalls
/// Writes: toolCallSummaries, hasVisualToolCalls, anyToolCallsExecuted, lastErrorClass
///
/// Sprint 3: Foundation node. Sprint 4 wired delegation.
/// Sprint 9: Error classification — transient errors retry once (1s delay),
/// permanent errors skip, stuck errors trigger recovery flow.
final class ActNode: StateNode, @unchecked Sendable {

    let nodeId = GraphNodeId.act

    // MARK: - Dependencies

    /// The agent loop provides tool execution and conversation management.
    /// Tool execution is delegated to AgentLoop because ToolExecutionManager is
    /// a value type (struct) owned by the actor -- it cannot be safely accessed
    /// from outside the actor isolation boundary.
    private weak var agentLoop: AgentLoop?

    /// Callbacks injected at graph construction time.
    private let onStateChange: (@Sendable (AgentState) -> Void)?
    private let onMessage: (@Sendable (ChatMessage) -> Void)?
    private let onConfirmationNeeded: (@Sendable (String) async -> Bool)?

    // MARK: - Init

    init(
        agentLoop: AgentLoop? = nil,
        onStateChange: (@Sendable (AgentState) -> Void)? = nil,
        onMessage: (@Sendable (ChatMessage) -> Void)? = nil,
        onConfirmationNeeded: (@Sendable (String) async -> Bool)? = nil
    ) {
        self.agentLoop = agentLoop
        self.onStateChange = onStateChange
        self.onMessage = onMessage
        self.onConfirmationNeeded = onConfirmationNeeded
    }

    // MARK: - Execute

    func execute(state: GraphState) async throws {
        try Task.checkCancellation()

        // If no tool calls in the response, skip execution entirely.
        let hasTools = await state.hasToolCalls
        guard hasTools else {
            NSLog("CyclopOne [ActNode]: No tool calls, skipping execution")
            return
        }

        guard let loop = agentLoop else {
            NSLog("CyclopOne [ActNode]: No AgentLoop available, marking error")
            await state.markError("ActNode: AgentLoop not available")
            return
        }

        guard let response = await state.claudeResponse else {
            NSLog("CyclopOne [ActNode]: No Claude response in state")
            return
        }

        let iter = await state.iteration
        let toolUses = response.toolUses
        NSLog("CyclopOne [ActNode]: Executing %d tool calls for iteration %d",
              toolUses.count, iter)

        // Delegate tool execution to AgentLoop which owns the ToolExecutionManager.
        // This calls executeToolsForGraph() which is an actor-isolated method that
        // handles tool dispatch, conversation append, and fingerprint tracking.
        //
        // Sprint 4: Add AgentLoop.executeToolsForGraph() method that accepts
        // the tool uses array and returns summaries. For now, execute via
        // the existing executeIteration path in a simplified manner.
        let result = await executeToolsViaLoop(
            loop: loop,
            toolUses: toolUses,
            state: state
        )

        // Store results in graph state
        await state.setToolCallResults(
            summaries: result.summaries,
            hasVisual: result.hasVisual
        )

        // Classify the last action type for adaptive capture in the next iteration
        let lastType = classifyActionType(summaries: result.summaries)
        await state.setLastActionType(lastType)

        // Sprint 8: Track raw tool name and reset consecutive screenshot counter.
        // PerceiveNode uses lastToolName for fine-grained skip decisions,
        // and resetConsecutiveScreenshots signals that an action occurred.
        if let lastTool = result.summaries.last {
            await state.setLastToolName(lastTool.toolName)
        }
        await state.resetConsecutiveScreenshots()

        NSLog("CyclopOne [ActNode]: Executed %d tool calls, hasVisual=%d, lastTool=%@",
              result.summaries.count, result.hasVisual ? 1 : 0,
              result.summaries.last?.toolName ?? "none")

        // Brief pause between iterations to avoid tight spin
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - Tool Execution Delegation

    /// Result of tool execution via the agent loop.
    private struct ToolExecutionResult {
        let summaries: [ToolCallSummary]
        let hasVisual: Bool
    }

    /// Execute tools through the AgentLoop actor boundary.
    ///
    /// Sprint 3: Uses a simplified execution path that iterates tool uses
    /// and delegates each to the agent loop. Sprint 4 wired batch method.
    /// Sprint 9: Added error classification with transient retry, permanent skip,
    /// and stuck detection for recovery flow.
    private func executeToolsViaLoop(
        loop: AgentLoop,
        toolUses: [(id: String, name: String, input: [String: Any])],
        state: GraphState
    ) async -> ToolExecutionResult {
        var hasVisualToolCalls = false
        var summaries: [ToolCallSummary] = []

        for toolUse in toolUses {
            // Check cancellation before each tool
            if Task.isCancelled {
                await state.markCancelled()
                break
            }

            // Track visual tool calls
            if !ToolExecutionManager.nonVisualTools.contains(toolUse.name) {
                hasVisualToolCalls = true
            }

            // Execute via AgentLoop actor (crosses isolation boundary safely)
            let toolResult: ToolResult
            do {
                toolResult = await loop.executeToolForGraph(
                    name: toolUse.name,
                    toolUseId: toolUse.id,
                    input: toolUse.input,
                    onStateChange: onStateChange ?? { _ in },
                    onMessage: onMessage ?? { _ in },
                    onConfirmationNeeded: onConfirmationNeeded ?? { _ in false }
                )
            } catch {
                // Sprint 9: Classify the exception and decide on retry vs skip
                let errorClass = ErrorClassifier.classify(error)

                if errorClass == .transient {
                    // Transient error — retry once after 1 second
                    NSLog("CyclopOne [ActNode]: Tool '%@' transient error, retrying in 1s: %@",
                          toolUse.name, error.localizedDescription)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)

                    do {
                        let retryResult = await loop.executeToolForGraph(
                            name: toolUse.name,
                            toolUseId: toolUse.id,
                            input: toolUse.input,
                            onStateChange: onStateChange ?? { _ in },
                            onMessage: onMessage ?? { _ in },
                            onConfirmationNeeded: onConfirmationNeeded ?? { _ in false }
                        )
                        // Retry succeeded — use the retry result
                        summaries.append(ToolCallSummary(
                            toolName: toolUse.name,
                            resultText: String(retryResult.result.prefix(500)),
                            isError: retryResult.isError
                        ))
                        if retryResult.isError {
                            onMessage?(ChatMessage(
                                role: .system,
                                content: "Tool retry error (\(toolUse.name)): \(retryResult.result)"
                            ))
                        }
                        continue
                    } catch {
                        // Retry also failed — fall through to record error
                        NSLog("CyclopOne [ActNode]: Tool '%@' retry also failed: %@",
                              toolUse.name, error.localizedDescription)
                    }
                }

                // Permanent or retry-exhausted — record error and continue
                NSLog("CyclopOne [ActNode]: Tool '%@' %@ error: %@",
                      toolUse.name, errorClass.rawValue, error.localizedDescription)
                onMessage?(ChatMessage(
                    role: .system,
                    content: "Tool exception (\(toolUse.name), \(errorClass.rawValue)): \(error.localizedDescription)"
                ))
                summaries.append(ToolCallSummary(
                    toolName: toolUse.name,
                    resultText: "Exception: \(error.localizedDescription)",
                    isError: true
                ))
                continue
            }

            // Sprint 9: Classify tool error results for downstream recovery
            if toolResult.isError {
                let errorClass = ErrorClassifier.classify(toolError: toolResult.result)

                if errorClass == .transient {
                    // Transient tool error — retry once after 1 second
                    NSLog("CyclopOne [ActNode]: Tool '%@' returned transient error, retrying: %@",
                          toolUse.name, String(toolResult.result.prefix(100)))
                    try? await Task.sleep(nanoseconds: 1_000_000_000)

                    let retryResult = await loop.executeToolForGraph(
                        name: toolUse.name,
                        toolUseId: toolUse.id,
                        input: toolUse.input,
                        onStateChange: onStateChange ?? { _ in },
                        onMessage: onMessage ?? { _ in },
                        onConfirmationNeeded: onConfirmationNeeded ?? { _ in false }
                    )
                    summaries.append(ToolCallSummary(
                        toolName: toolUse.name,
                        resultText: String(retryResult.result.prefix(500)),
                        isError: retryResult.isError
                    ))
                    if retryResult.isError {
                        onMessage?(ChatMessage(
                            role: .system,
                            content: "Tool retry error (\(toolUse.name)): \(retryResult.result)"
                        ))
                    }
                    continue
                }

                // Permanent or stuck — log and continue
                onMessage?(ChatMessage(
                    role: .system,
                    content: "Tool error (\(toolUse.name), \(errorClass.rawValue)): \(toolResult.result)"
                ))
            }

            // Collect summary
            summaries.append(ToolCallSummary(
                toolName: toolUse.name,
                resultText: String(toolResult.result.prefix(500)),
                isError: toolResult.isError
            ))
        }

        // Sprint 9: Classify the overall error class from all tool results
        // and store it in GraphState for RecoverNode to read
        let overallErrorClass = ErrorClassifier.classify(summaries: summaries)
        if overallErrorClass != .none {
            await state.setLastErrorClass(overallErrorClass)
            NSLog("CyclopOne [ActNode]: Overall error class: %@", overallErrorClass.rawValue)

            // If classified as stuck, mark state so EvaluateNode triggers recovery
            if overallErrorClass == .stuck {
                await state.markStuck(reason: "Tool errors indicate stuck state")
            }
        }

        return ToolExecutionResult(summaries: summaries, hasVisual: hasVisualToolCalls)
    }

    // MARK: - Action Type Classification

    /// Classify the dominant action type from tool call summaries.
    /// Used by PerceiveNode to decide whether to skip screenshot next iteration.
    private func classifyActionType(summaries: [ToolCallSummary]) -> String {
        guard let last = summaries.last else { return "other" }

        switch last.toolName {
        case "type_text":
            return "type_text"
        case "key_press", "hotkey", "press_key":
            return "key_press"
        case "click", "double_click", "right_click", "move_mouse", "drag":
            return "click"
        case "open_url", "open_app", "open_application", "run_applescript":
            return "navigation"
        case "screenshot", "take_screenshot", "read_screen":
            return "screenshot"
        case "shell", "run_shell":
            return "shell"
        default:
            return "other"
        }
    }
}
