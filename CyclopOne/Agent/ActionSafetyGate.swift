import Foundation

/// Risk classification for tool actions.
///
/// Levels are ordered by severity. The gate never downgrades a risk level
/// once assigned -- only the user can override by approving.
enum RiskLevel: Int, Comparable, Sendable {
    /// No risk. Auto-proceed without logging.
    case safe = 0

    /// Low risk. Log the action, proceed automatically.
    case moderate = 1

    /// Elevated risk. Require user confirmation before proceeding.
    case high = 2

    /// Maximum risk. ALWAYS require confirmation, no session caching.
    case critical = 3

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Method used to evaluate the tool call.
enum EvaluationMethod: String, Sendable {
    case heuristic
    case llm
}

/// Audit log entry for gated actions.
struct AuditEntry: Sendable {
    let timestamp: Date
    let runId: String
    let tool: String
    let input: String
    let riskLevel: RiskLevel
    let reason: String
    let method: EvaluationMethod
    let approved: Bool?
    let appContext: String?
}

/// Centralized safety gate for ALL tool calls.
///
/// Evaluates every tool invocation before execution using a two-phase approach:
/// 1. Fast heuristic evaluation (pattern matching, context rules) -- ~0ms
/// 2. LLM evaluation for uncertain cases only -- ~2-5s (rare)
///
/// The gate is an actor to ensure thread-safe access to the audit log
/// and session-level approval cache.
actor ActionSafetyGate {

    // MARK: - Types

    /// The tool call to evaluate, with all relevant parameters.
    struct ToolCall: Sendable {
        let name: String
        let input: [String: String]
        let iteration: Int
        let stepInstruction: String?
    }

    /// Contextual information about the current agent state.
    struct ActionContext: Sendable {
        let activeAppName: String?
        let activeAppBundleID: String?
        let windowTitle: String?
        let focusedElementRole: String?
        let focusedElementLabel: String?
        let recentToolCalls: [(name: String, summary: String)]
        let currentURL: String?
    }

    /// Result of a safety evaluation.
    struct RiskVerdict: Sendable {
        let level: RiskLevel
        let reason: String
        let tool: String
        let requiresApproval: Bool
        let approvalPrompt: String?
        let sessionCacheKey: String?

        init(level: RiskLevel, reason: String, tool: String,
             requiresApproval: Bool, approvalPrompt: String?,
             sessionCacheKey: String? = nil) {
            self.level = level
            self.reason = reason
            self.tool = tool
            self.requiresApproval = requiresApproval
            self.approvalPrompt = approvalPrompt
            self.sessionCacheKey = sessionCacheKey
        }
    }

    /// Intermediate result from heuristic evaluation.
    enum HeuristicResult {
        case definite(RiskVerdict)
        case uncertain(RiskVerdict)
    }

    // MARK: - Configuration

    var sessionApprovals: [String: Bool] = [:]
    var auditLog: [AuditEntry] = []
    var currentRunId: String?
    private let brainModel: String
    let permissionMode: PermissionMode

    // Tool safety sets are defined in ToolDefinitions.alwaysSafeToolNames
    // and ToolDefinitions.lowRiskMutationToolNames (Sprint 6 consolidation).

    init(brainModel: String = AgentConfig.defaultBrainModel, permissionMode: PermissionMode = .standard) {
        self.brainModel = brainModel
        self.permissionMode = permissionMode
    }

    // MARK: - Public API

    func evaluate(toolCall: ToolCall, context: ActionContext) async -> RiskVerdict {
        // Always-safe tools: skip evaluation entirely
        if ToolDefinitions.alwaysSafeToolNames.contains(toolCall.name) {
            return RiskVerdict(level: .safe, reason: "Always-safe tool", tool: toolCall.name,
                               requiresApproval: false, approvalPrompt: nil)
        }

        // Low-risk mutation tools: moderate, logged but auto-approved
        if ToolDefinitions.lowRiskMutationToolNames.contains(toolCall.name) {
            let verdict = RiskVerdict(level: .moderate, reason: "Internal mutation tool",
                                      tool: toolCall.name, requiresApproval: false, approvalPrompt: nil)
            logAudit(verdict: verdict, context: context, method: .heuristic)
            return verdict
        }

        // Phase 1: Fast heuristic evaluation
        let heuristicResult = evaluateHeuristic(toolCall: toolCall, context: context)

        switch heuristicResult {
        case .definite(let verdict):
            logAudit(verdict: verdict, context: context, method: .heuristic)
            return verdict

        case .uncertain(let partialVerdict):
            let llmVerdict = await evaluateWithLLM(
                toolCall: toolCall,
                context: context,
                heuristicHint: partialVerdict
            )
            logAudit(verdict: llmVerdict, context: context, method: .llm)
            return llmVerdict
        }
    }

    func startRun(runId: String) {
        currentRunId = runId
        sessionApprovals.removeAll()
        auditLog.removeAll()
    }

    func endRun() async {
        await flushAuditLog()
        currentRunId = nil
    }

    func isSessionApproved(_ category: String) -> Bool {
        return sessionApprovals[category] == true
    }

    func recordSessionApproval(_ category: String, approved: Bool) {
        sessionApprovals[category] = approved
    }
}
