import Foundation

/// Updates the FloatingDot UI during agent execution.
/// Mostly formalizes what the existing `onStateChange` / `onMessage`
/// callbacks already do, but through the observer interface.
final class LocalAgentObserver: AgentObserver, @unchecked Sendable {

    private let onStateChange: @Sendable (AgentState) -> Void
    private let onMessage: @Sendable (ChatMessage) -> Void

    init(
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void
    ) {
        self.onStateChange = onStateChange
        self.onMessage = onMessage
    }

    func onStepStart(stepIndex: Int, totalSteps: Int, title: String) async {
        onMessage(ChatMessage(
            role: .system,
            content: "Step \(stepIndex + 1)/\(totalSteps): \(title)"
        ))
    }

    func onToolExecution(toolName: String, summary: String, isError: Bool) async {
        // Local UI already gets tool execution feedback via onStateChange(.executing(toolName))
        // from inside AgentLoop.executeToolCall. No additional work needed here.
    }

    func onScreenshot(imageData: Data, context: String) async {
        // Local UI doesn't display inline screenshots. No-op.
    }

    func onStepComplete(stepIndex: Int, totalSteps: Int, title: String,
                        outcome: String, screenshot: Data?) async {
        onMessage(ChatMessage(
            role: .system,
            content: "Step \(stepIndex + 1)/\(totalSteps) complete: \(title)"
        ))
    }

    func onError(error: String, screenshot: Data?, isFatal: Bool) async {
        if isFatal {
            onStateChange(.error(error))
        }
        onMessage(ChatMessage(role: .system, content: "Error: \(error)"))
    }

    func onCompletion(success: Bool, summary: String, score: Int?, iterations: Int) async {
        onStateChange(.done)
    }

    func onIterationStart(iteration: Int, maxIterations: Int) async {
        // Could be used to update a progress indicator on the dot.
        // For now, a no-op since the dot already pulses during execution.
    }
}
