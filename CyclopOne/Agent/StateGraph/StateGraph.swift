import Foundation

// MARK: - State Graph Framework
// LangGraph-style state machine for agent execution.
// Sprint 3: Foundation only — not yet wired into the main loop.

// MARK: - Node Protocol

/// A single node in the agent's state graph.
/// Each node reads from and writes to the shared GraphState.
protocol StateNode: Sendable {
    /// Unique identifier for this node (matches GraphNodeId constants).
    var nodeId: String { get }

    /// Execute this node's logic, reading/writing the shared state.
    /// Throws on unrecoverable errors (API failure, cancellation).
    func execute(state: GraphState) async throws
}

// MARK: - Node Identifiers

/// String constants for graph node IDs. Using an enum namespace
/// to avoid typos and enable autocomplete.
enum GraphNodeId {
    static let perceive  = "PERCEIVE"
    static let plan      = "PLAN"
    static let act       = "ACT"
    static let observe   = "OBSERVE"
    static let evaluate  = "EVALUATE"
    static let recover   = "RECOVER"
    static let complete  = "COMPLETE"
}

// MARK: - Edge

/// A conditional transition between two nodes.
/// Edges are evaluated in order — first match wins.
struct GraphEdge: Sendable {
    let from: String
    let to: String
    /// Condition evaluated against current state. Return true to take this edge.
    let condition: @Sendable (GraphState) async -> Bool
}

// MARK: - Transition Result

/// Outcome of a single node execution + edge evaluation.
struct GraphTransition: Sendable {
    let fromNode: String
    let toNode: String
    let iteration: Int
    let timestamp: Date
}

// MARK: - Graph Runner

/// Executes a graph of StateNodes until a terminal state is reached
/// or the iteration limit is exceeded.
///
/// Usage:
/// ```
/// let runner = GraphRunner()
/// runner.addNode(perceiveNode)
/// runner.addNode(planNode)
/// // ... add edges ...
/// let result = await runner.run(state: graphState)
/// ```
actor GraphRunner {

    // MARK: - Properties

    /// Registered nodes keyed by nodeId.
    private var nodes: [String: any StateNode] = [:]

    /// Edges grouped by source node for fast lookup.
    private var edgesBySource: [String: [GraphEdge]] = [:]

    /// Terminal states — graph stops when reaching one of these.
    private var terminalStates: Set<String> = []

    /// Maximum iterations before forced termination.
    var maxIterations: Int = 50

    /// Transition log for debugging and journal recording.
    private(set) var transitionLog: [GraphTransition] = []

    /// Optional hook called before each iteration at the PERCEIVE node.
    /// Allows the Orchestrator to inject cancellation, timeout, network, and budget
    /// checks without coupling graph nodes to Orchestrator concerns.
    private var preIterationHook: (@Sendable () async throws -> Void)?

    // MARK: - Configuration

    /// Register a node in the graph.
    func addNode(_ node: any StateNode) {
        nodes[node.nodeId] = node
    }

    /// Add a conditional edge between two nodes.
    /// Edges from the same source are evaluated in order — first match wins.
    func addEdge(_ edge: GraphEdge) {
        edgesBySource[edge.from, default: []].append(edge)
    }

    /// Mark node IDs as terminal (graph exits when reaching these).
    func setTerminalStates(_ states: Set<String>) {
        terminalStates = states
    }

    /// Set the maximum number of iterations.
    func setMaxIterations(_ value: Int) {
        maxIterations = value
    }

    /// Set the pre-iteration hook called before each PERCEIVE execution.
    func setPreIterationHook(_ hook: (@Sendable () async throws -> Void)?) {
        preIterationHook = hook
    }

    // MARK: - Execution

    /// Run the graph from the given start node until a terminal state
    /// is reached or maxIterations is exceeded.
    ///
    /// Returns the final node ID (terminal state or last node before limit).
    func run(
        state: GraphState,
        startNode: String = GraphNodeId.perceive
    ) async throws -> String {
        transitionLog.removeAll()
        var currentNodeId = startNode
        var iteration = 0

        while !terminalStates.contains(currentNodeId) {
            iteration += 1
            if iteration > maxIterations {
                NSLog("CyclopOne [GraphRunner]: Max iterations (%d) reached at node %@",
                      maxIterations, currentNodeId)
                break
            }

            // Pre-iteration hook: called at the top of each cycle when at PERCEIVE.
            // Allows Orchestrator to check cancellation, timeout, network, budget.
            if currentNodeId == GraphNodeId.perceive, let hook = preIterationHook {
                try await hook()
            }

            // Execute current node
            guard let node = nodes[currentNodeId] else {
                NSLog("CyclopOne [GraphRunner]: No node registered for '%@'", currentNodeId)
                break
            }

            try Task.checkCancellation()

            NSLog("CyclopOne [GraphRunner]: Executing node %@ (iteration %d)",
                  currentNodeId, iteration)
            try await node.execute(state: state)

            // Evaluate edges to find next node
            guard let nextNodeId = await evaluateEdges(from: currentNodeId, state: state) else {
                NSLog("CyclopOne [GraphRunner]: No matching edge from %@, stopping",
                      currentNodeId)
                break
            }

            // Record transition
            let transition = GraphTransition(
                fromNode: currentNodeId,
                toNode: nextNodeId,
                iteration: iteration,
                timestamp: Date()
            )
            transitionLog.append(transition)

            NSLog("CyclopOne [GraphRunner]: Transition %@ → %@ (iteration %d)",
                  currentNodeId, nextNodeId, iteration)

            currentNodeId = nextNodeId
        }

        NSLog("CyclopOne [GraphRunner]: Graph finished at node %@ after %d iterations",
              currentNodeId, iteration)
        return currentNodeId
    }

    // MARK: - Edge Evaluation

    /// Evaluate edges from a source node, returning the first matching target.
    private func evaluateEdges(
        from sourceId: String,
        state: GraphState
    ) async -> String? {
        guard let edges = edgesBySource[sourceId] else { return nil }

        for edge in edges {
            if await edge.condition(state) {
                return edge.to
            }
        }

        return nil
    }

    // MARK: - Introspection

    /// Returns all registered node IDs.
    func registeredNodeIds() -> [String] {
        Array(nodes.keys).sorted()
    }

    /// Returns edge count for a given source node.
    func edgeCount(from sourceId: String) -> Int {
        edgesBySource[sourceId]?.count ?? 0
    }
}
