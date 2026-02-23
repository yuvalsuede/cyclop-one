import Foundation

/// Events emitted during agent execution. Each input surface
/// implements this to provide appropriate user feedback.
///
/// All methods are `async` because Telegram I/O is async.
/// All methods are nonisolated requirements so observers can
/// be passed across actor boundaries.
protocol AgentObserver: AnyObject, Sendable {

    /// A new plan step is starting execution.
    /// - Parameters:
    ///   - stepIndex: 0-based index of the current step.
    ///   - totalSteps: Total number of steps in the plan.
    ///   - title: Human-readable step title (e.g., "Open Calculator").
    func onStepStart(stepIndex: Int, totalSteps: Int, title: String) async

    /// A tool was executed within the current iteration.
    /// - Parameters:
    ///   - toolName: The tool name (e.g., "click", "type_text", "open_application").
    ///   - summary: Human-readable summary (e.g., "Clicked Send button at (340, 220)").
    ///   - isError: Whether the tool execution failed.
    func onToolExecution(toolName: String, summary: String, isError: Bool) async

    /// A meaningful screenshot was captured (after click, after navigation, etc.).
    /// NOT called for every screenshot -- only "interesting" ones.
    /// - Parameters:
    ///   - imageData: JPEG image data.
    ///   - context: Why this screenshot was taken (e.g., "After opening Calculator").
    func onScreenshot(imageData: Data, context: String) async

    /// A plan step completed.
    /// - Parameters:
    ///   - stepIndex: 0-based index of the completed step.
    ///   - totalSteps: Total steps in the plan.
    ///   - title: Step title.
    ///   - outcome: Brief outcome description.
    ///   - screenshot: Optional screenshot of the final state.
    func onStepComplete(stepIndex: Int, totalSteps: Int, title: String,
                        outcome: String, screenshot: Data?) async

    /// An error occurred during execution.
    /// - Parameters:
    ///   - error: Description of what went wrong.
    ///   - screenshot: Optional screenshot showing the error state.
    ///   - isFatal: Whether this error terminates the run.
    func onError(error: String, screenshot: Data?, isFatal: Bool) async

    /// The entire run completed.
    /// - Parameters:
    ///   - success: Whether the run was considered successful.
    ///   - summary: Brief result summary.
    ///   - score: Verification score (0-100), if available.
    ///   - iterations: Total iterations used.
    func onCompletion(success: Bool, summary: String, score: Int?, iterations: Int) async

    /// An iteration started (lightweight event, mainly for local UI).
    /// - Parameters:
    ///   - iteration: Current iteration number (1-based).
    ///   - maxIterations: Maximum iterations allowed.
    func onIterationStart(iteration: Int, maxIterations: Int) async
}

/// Default implementations -- observers only override what they care about.
extension AgentObserver {
    func onIterationStart(iteration: Int, maxIterations: Int) async {}
}
