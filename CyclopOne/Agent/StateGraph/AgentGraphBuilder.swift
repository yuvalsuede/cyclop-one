import Foundation

// MARK: - Agent Graph Builder
// Constructs the default agent state graph with all nodes and conditional edges.
// Sprint 3: Foundation. Sprint 4 wires this into Orchestrator.startRun().

/// Builds and configures the GraphRunner with the standard agent node graph:
///
/// ```
/// PERCEIVE -> PLAN -> ACT -> OBSERVE -> EVALUATE
///                       |                    |
///                       |    (complete) -----> COMPLETE (terminal)
///                       |    (stuck) -------> RECOVER -> PERCEIVE
///                       |    (continue) ----> PERCEIVE
///                       |
///          (no tools) -> EVALUATE
/// ```
enum AgentGraphBuilder {

    /// Build configuration containing all nodes for external reference.
    struct GraphConfig {
        let runner: GraphRunner
        let perceiveNode: PerceiveNode
        let planNode: PlanNode
        let actNode: ActNode
        let observeNode: ObserveNode
        let evaluateNode: EvaluateNode
        let recoverNode: RecoverNode
        let completeNode: CompleteNode
    }

    /// Build the default agent graph with all nodes and edges.
    ///
    /// - Parameters:
    ///   - agentLoop: The agent loop (provides conversation, tools, API).
    ///   - verificationEngine: The verification scoring engine.
    ///   - captureService: Screen capture service.
    ///   - accessibilityService: Accessibility tree reader.
    ///   - brainModel: Model name for brain consultation (stuck recovery).
    ///   - maxIterations: Maximum graph iterations before forced termination.
    ///   - verificationThreshold: Minimum verification score to pass.
    ///   - onStateChange: UI state change callback.
    ///   - onMessage: Chat message callback.
    ///   - onConfirmationNeeded: Destructive action confirmation callback.
    /// - Returns: Configured GraphConfig with runner and all nodes.
    static func build(
        agentLoop: AgentLoop,
        verificationEngine: VerificationEngine,
        captureService: ScreenCaptureService = .shared,
        accessibilityService: AccessibilityService = .shared,
        brainModel: String = AgentConfig.defaultBrainModel,
        maxIterations: Int = 50,
        verificationThreshold: Int = VerificationScore.defaultThreshold,
        onStateChange: @Sendable @escaping (AgentState) -> Void = { _ in },
        onMessage: @Sendable @escaping (ChatMessage) -> Void = { _ in },
        onConfirmationNeeded: @Sendable @escaping (String) async -> Bool = { _ in false }
    ) async -> GraphConfig {
        // Create nodes with injected dependencies

        let observeNode = ObserveNode(
            captureService: captureService,
            accessibilityService: accessibilityService,
            agentLoop: agentLoop
        )

        let perceiveNode = PerceiveNode(
            captureService: captureService,
            accessibilityService: accessibilityService,
            agentLoop: agentLoop
        )

        let planNode = PlanNode(
            agentLoop: agentLoop,
            onStateChange: onStateChange,
            onMessage: onMessage
        )

        let actNode = ActNode(
            agentLoop: agentLoop,
            onStateChange: onStateChange,
            onMessage: onMessage,
            onConfirmationNeeded: onConfirmationNeeded
        )

        let evaluateNode = EvaluateNode(
            observeNode: observeNode
        )

        let recoverNode = RecoverNode(
            agentLoop: agentLoop,
            observeNode: observeNode,
            captureService: captureService,
            accessibilityService: accessibilityService,
            brainModel: brainModel,
            onMessage: onMessage
        )

        let completeNode = CompleteNode(
            verificationEngine: verificationEngine,
            agentLoop: agentLoop,
            verificationThreshold: verificationThreshold,
            onStateChange: onStateChange,
            onMessage: onMessage
        )

        // Build runner
        let runner = GraphRunner()
        await runner.setMaxIterations(maxIterations)

        // Register nodes
        await runner.addNode(perceiveNode)
        await runner.addNode(planNode)
        await runner.addNode(actNode)
        await runner.addNode(observeNode)
        await runner.addNode(evaluateNode)
        await runner.addNode(recoverNode)
        await runner.addNode(completeNode)

        // Define edges

        // PERCEIVE -> PLAN (always)
        await runner.addEdge(GraphEdge(
            from: GraphNodeId.perceive,
            to: GraphNodeId.plan,
            condition: { _ in true }
        ))

        // PLAN -> ACT (when Claude returned tool calls)
        await runner.addEdge(GraphEdge(
            from: GraphNodeId.plan,
            to: GraphNodeId.act,
            condition: { state in await state.hasToolCalls }
        ))

        // PLAN -> EVALUATE (when Claude returned no tool calls — done or text-only)
        await runner.addEdge(GraphEdge(
            from: GraphNodeId.plan,
            to: GraphNodeId.evaluate,
            condition: { state in await !state.hasToolCalls }
        ))

        // ACT -> OBSERVE (always after tool execution)
        await runner.addEdge(GraphEdge(
            from: GraphNodeId.act,
            to: GraphNodeId.observe,
            condition: { _ in true }
        ))

        // OBSERVE -> EVALUATE (always)
        await runner.addEdge(GraphEdge(
            from: GraphNodeId.observe,
            to: GraphNodeId.evaluate,
            condition: { _ in true }
        ))

        // EVALUATE -> COMPLETE (task completed)
        await runner.addEdge(GraphEdge(
            from: GraphNodeId.evaluate,
            to: GraphNodeId.complete,
            condition: { state in await state.taskComplete }
        ))

        // EVALUATE -> RECOVER (agent is stuck)
        await runner.addEdge(GraphEdge(
            from: GraphNodeId.evaluate,
            to: GraphNodeId.recover,
            condition: { state in await state.isStuck }
        ))

        // EVALUATE -> PERCEIVE (continue iterating)
        await runner.addEdge(GraphEdge(
            from: GraphNodeId.evaluate,
            to: GraphNodeId.perceive,
            condition: { state in
                let complete = await state.taskComplete
                let stuck = await state.isStuck
                return !complete && !stuck
            }
        ))

        // RECOVER -> COMPLETE (max recovery attempts exceeded)
        await runner.addEdge(GraphEdge(
            from: GraphNodeId.recover,
            to: GraphNodeId.complete,
            condition: { state in
                let attempts = await state.recoveryAttempts
                let max = await state.maxRecoveryAttempts
                return attempts >= max
            }
        ))

        // RECOVER -> PERCEIVE (retry after recovery)
        await runner.addEdge(GraphEdge(
            from: GraphNodeId.recover,
            to: GraphNodeId.perceive,
            condition: { state in
                let attempts = await state.recoveryAttempts
                let max = await state.maxRecoveryAttempts
                return attempts < max
            }
        ))

        // COMPLETE -> PERCEIVE (verification rejected, retry)
        // When verification rejects, CompleteNode calls clearCompletion() which sets
        // taskComplete=false. This edge catches that case and loops back.
        await runner.addEdge(GraphEdge(
            from: GraphNodeId.complete,
            to: GraphNodeId.perceive,
            condition: { state in
                let complete = await state.taskComplete
                return !complete  // clearCompletion() was called on rejection
            }
        ))

        // No terminal states are registered. Instead, when COMPLETE finishes
        // successfully (verification passed or force-completed), taskComplete
        // remains true and no edge from COMPLETE matches, so GraphRunner
        // exits naturally via "No matching edge" detection.
        // This allows CompleteNode to always execute its verification logic.
        await runner.setTerminalStates([])

        return GraphConfig(
            runner: runner,
            perceiveNode: perceiveNode,
            planNode: planNode,
            actNode: actNode,
            observeNode: observeNode,
            evaluateNode: evaluateNode,
            recoverNode: recoverNode,
            completeNode: completeNode
        )
    }
}
