import Foundation

/// How critical a step is. Critical steps abort the entire plan on failure.
enum StepCriticality: String, Codable, Sendable {
    /// Step failure aborts the plan. Auto-assigned to text-input steps.
    case critical
    /// Step failure is logged but execution continues.
    case normal
    /// Step failure is ignored entirely (cleanup, best-effort).
    case optional
}

/// A single step in an execution plan produced by the brain model.
struct PlanStep: Codable, Sendable {
    /// Unique identifier for this step (0-indexed position in the plan).
    let id: Int

    /// Human-readable title (e.g., "Open Safari").
    let title: String

    /// Detailed instruction for the executor model. This is what gets
    /// injected into the system prompt -- NOT the full plan.
    let action: String

    /// Description of what the screen/state should look like after this step
    /// completes successfully. Used for outcome validation.
    let expectedOutcome: String

    /// If true, the user must approve this step before the executor acts.
    /// Mapped from the [CONFIRM] tag in the old plan format.
    let requiresConfirmation: Bool

    /// Maximum iterations the executor should spend on this step before
    /// the Orchestrator considers it stuck. Defaults to 3.
    let maxIterations: Int

    /// How critical this step is. Critical steps abort the plan on failure.
    let criticality: StepCriticality

    /// The target application, website, or tool for this step.
    /// Examples: "Safari", "Messages", "Calculator", "Terminal", "google.com"
    /// Helps the executor know WHERE to perform the action, preventing
    /// misinterpretation (e.g., "tell X to do Y" should target Messages, not Safari).
    let targetApp: String?

    /// Optional: which agent tool(s) this step is expected to use.
    /// Helps the Orchestrator distinguish "wrong tool" from "right tool, wrong result."
    let expectedTools: [String]?

    init(id: Int, title: String, action: String, expectedOutcome: String,
         requiresConfirmation: Bool = false, maxIterations: Int = 3,
         targetApp: String? = nil, expectedTools: [String]? = nil,
         criticality: StepCriticality = .normal) {
        self.id = id
        self.title = title
        self.action = action
        self.expectedOutcome = expectedOutcome
        self.requiresConfirmation = requiresConfirmation
        self.maxIterations = maxIterations
        self.targetApp = targetApp
        self.expectedTools = expectedTools
        self.criticality = criticality
    }
}

/// A structured plan returned by the brain model (Opus) and tracked
/// by the Orchestrator during execution.
struct ExecutionPlan: Codable, Sendable {
    /// The original user command this plan addresses.
    let command: String

    /// Ordered steps to execute.
    let steps: [PlanStep]

    /// Brief summary of the overall approach (for user display and logging).
    let summary: String

    /// Total estimated iterations across all steps.
    /// Used to set a tighter maxIterations on the run config.
    var estimatedTotalIterations: Int {
        steps.reduce(0) { $0 + $1.maxIterations }
    }

    /// Whether this plan is empty (0 steps). Indicates the brain could not
    /// or chose not to decompose the task. Execution falls back to
    /// single-instruction mode (current behavior).
    var isEmpty: Bool { steps.isEmpty }
}

/// Result of validating whether a plan step's expected outcome was achieved.
enum StepOutcome: Sendable {
    /// Step completed successfully. Advance to next step.
    case succeeded(confidence: Double, evidence: String)

    /// Step outcome is uncertain. Proceed but log for review.
    case uncertain(confidence: Double, evidence: String)

    /// Step clearly failed or deviated.
    case failed(reason: String)

    /// Step was skipped (user denied confirmation, or brain revised it away).
    case skipped(reason: String)
}

/// Instructions from the brain model when a step deviation is detected.
enum PlanRevision: Codable, Sendable {
    /// Replace remaining steps with a new sequence.
    case replaceRemaining(steps: [PlanStep])

    /// Insert additional steps before the current position.
    case insertBefore(steps: [PlanStep])

    /// Retry the current step with modified instructions.
    case retryStep(revisedAction: String)

    /// Abort the plan. The task cannot be completed.
    case abort(reason: String)
}
