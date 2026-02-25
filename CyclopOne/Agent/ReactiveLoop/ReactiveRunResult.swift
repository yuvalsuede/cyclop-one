import Foundation

/// The result of a completed ReactiveLoopActor run.
/// Mirrors the shape of `Orchestrator.RunResult` so callers can treat them uniformly.
struct ReactiveRunResult {
    let runId: String
    let success: Bool
    let summary: String
    let iterations: Int
    let finalScore: Int?
    let totalInputTokens: Int
    let totalOutputTokens: Int

    // MARK: - Conversion

    /// Convert to an `Orchestrator.RunResult` for use with any existing infrastructure
    /// that consumes that type (journal, reply channels, etc.).
    func toOrchestratorRunResult() -> Orchestrator.RunResult {
        return Orchestrator.RunResult(
            runId: runId,
            success: success,
            summary: summary,
            iterations: iterations,
            finalScore: finalScore,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            verificationInputTokens: 0,
            verificationOutputTokens: 0
        )
    }

    // MARK: - Convenience Constructors

    static func fromState(_ state: ReactiveAgentState) -> ReactiveRunResult {
        return ReactiveRunResult(
            runId: state.runId,
            success: state.isComplete && !state.isFailed,
            summary: state.completionReason.isEmpty
                ? (state.isComplete ? "Task completed successfully." : "Task did not complete.")
                : state.completionReason,
            iterations: state.iteration,
            finalScore: state.isComplete && !state.isFailed ? 100 : nil,
            totalInputTokens: state.totalInputTokens,
            totalOutputTokens: state.totalOutputTokens
        )
    }

    static func failed(runId: String, reason: String, iterations: Int,
                       inputTokens: Int, outputTokens: Int) -> ReactiveRunResult {
        return ReactiveRunResult(
            runId: runId,
            success: false,
            summary: reason,
            iterations: iterations,
            finalScore: nil,
            totalInputTokens: inputTokens,
            totalOutputTokens: outputTokens
        )
    }
}
