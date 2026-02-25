import Foundation

/// Tracks the current state of the agent.
enum AgentState: Equatable {
    case idle
    case listening            // Panel open, waiting for user input
    case capturing            // Taking screenshot / reading accessibility tree
    case thinking             // Waiting for Claude API response
    case executing(String)    // Running a tool (description)
    case awaitingConfirmation(String) // Waiting for user to approve action
    case error(String)        // Something went wrong
    case done                 // Task completed

    var displayText: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening…"
        case .capturing: return "Observing screen…"
        case .thinking: return "Thinking…"
        case .executing(let action): return "Executing: \(action)"
        case .awaitingConfirmation(let action): return "Confirm: \(action)?"
        case .error(let msg): return "Error: \(msg)"
        case .done: return "Done"
        }
    }

    var isActive: Bool {
        switch self {
        case .idle, .listening, .done, .error: return false
        default: return true
        }
    }
}

// MARK: - Model Tiers (Sprint 5)

/// Tiered model usage — each tier maps to a Claude model with different
/// cost/capability trade-offs. Nodes select the tier appropriate for their task.
///
/// | Tier  | Model        | Use Case                                             |
/// |-------|-------------|------------------------------------------------------|
/// | fast  | Haiku 4.5   | Safety classification, simple eval, screenshot desc   |
/// | smart | Sonnet 4.6  | Agent actions, verification scoring, tool dispatch    |
/// | deep  | Opus 4.6    | Complex planning, recovery strategies, brain consult  |
enum ModelTier: String, CaseIterable, Sendable {
    case fast
    case smart
    case deep

    /// Resolve to the concrete model name.
    var modelName: String {
        switch self {
        case .fast:  return "claude-haiku-4-5-20251001"
        case .smart: return "claude-sonnet-4-6"
        case .deep:  return "claude-opus-4-6"
        }
    }

    /// Default max tokens for this tier. Callers can override per-request.
    var maxTokens: Int {
        switch self {
        case .fast:  return 1024
        case .smart: return 8192
        case .deep:  return 4096
        }
    }
}

/// Configuration for the agent's behavior.
struct AgentConfig {

    // MARK: - Model Name Constants (Single Source of Truth)

    /// Default agent model — used for the main agent loop conversations.
    /// Sprint 5: Upgraded from Haiku to Sonnet (smart tier) for much better
    /// tool selection and fewer stuck situations.
    static let defaultModelName: String = {
        let saved = UserDefaults.standard.string(forKey: "selectedModel")
        return (saved?.isEmpty == false) ? saved! : ModelTier.smart.modelName
    }()

    /// Higher-reasoning model for stuck recovery and planning.
    static let defaultBrainModel: String = ModelTier.deep.modelName

    /// Model for verification scoring — Sprint 5: upgraded from Haiku to Sonnet
    /// for more accurate pass/fail scoring.
    static let verificationModel: String = ModelTier.smart.modelName

    /// Fast model for safety gate LLM evaluation.
    static let safetyModel: String = ModelTier.fast.modelName

    // MARK: - Instance Properties

    var maxIterations: Int = 15
    var toolTimeout: TimeInterval = 30
    var shellTimeout: TimeInterval = 60
    /// Max pixel dimension for screenshot scaling. 1280 balances text readability
    /// with payload size. JPEG at 0.85 quality keeps text sharp while keeping
    /// screenshots ~200KB (vs ~900KB with PNG at 2048px).
    var screenshotMaxDimension: Int = 1280
    var screenshotJPEGQuality: Double = 0.85
    var confirmDestructiveActions: Bool = true
    var modelName: String = AgentConfig.defaultModelName

    /// The "brain" model used when the agent is stuck or needs higher reasoning.
    var brainModel: String = AgentConfig.defaultBrainModel

    var permissionMode: PermissionMode = .standard

    /// Click down/up delay in microseconds. Default 150ms (GFX-H2 fix: was 50ms).
    var clickDelayMicroseconds: useconds_t = 150_000

    /// Drag intermediate steps (GFX-H3 fix: was 10, now 30 for smoother drags).
    var dragSteps: Int = 30

    /// Drag dwell time per step in microseconds.
    var dragDwellMicroseconds: useconds_t = 20_000

}
