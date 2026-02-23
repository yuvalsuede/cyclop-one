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
    private enum HeuristicResult {
        case definite(RiskVerdict)
        case uncertain(RiskVerdict)
    }

    // MARK: - Configuration

    private var sessionApprovals: [String: Bool] = [:]
    private var auditLog: [AuditEntry] = []
    private var currentRunId: String?
    private let brainModel: String
    private let permissionMode: PermissionMode

    private static let alwaysSafeTools: Set<String> = [
        "take_screenshot", "read_screen",
        "vault_read", "vault_search", "vault_list",
        "task_list",
        "recall",
        "openclaw_check",
        "move_mouse", "scroll"
    ]

    private static let lowRiskMutationTools: Set<String> = [
        "vault_write", "vault_append",
        "task_create", "task_update", "task_complete",
        "remember"
    ]

    init(brainModel: String = "claude-opus-4-6", permissionMode: PermissionMode = .standard) {
        self.brainModel = brainModel
        self.permissionMode = permissionMode
    }

    // MARK: - Public API

    func evaluate(toolCall: ToolCall, context: ActionContext) async -> RiskVerdict {
        // Always-safe tools: skip evaluation entirely
        if Self.alwaysSafeTools.contains(toolCall.name) {
            return RiskVerdict(level: .safe, reason: "Always-safe tool", tool: toolCall.name,
                               requiresApproval: false, approvalPrompt: nil)
        }

        // Low-risk mutation tools: moderate, logged but auto-approved
        if Self.lowRiskMutationTools.contains(toolCall.name) {
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

    // MARK: - Heuristic Dispatch

    private func evaluateHeuristic(toolCall: ToolCall, context: ActionContext) -> HeuristicResult {
        switch toolCall.name {
        case "click", "right_click":
            return evaluateClick(toolCall: toolCall, context: context)
        case "type_text":
            return evaluateTypeText(toolCall: toolCall, context: context)
        case "press_key":
            return evaluatePressKey(toolCall: toolCall, context: context)
        case "run_shell_command":
            return evaluateShellCommand(toolCall: toolCall, context: context)
        case "run_applescript":
            return evaluateAppleScript(toolCall: toolCall, context: context)
        case "open_url":
            return evaluateOpenURL(toolCall: toolCall, context: context)
        case "openclaw_send":
            return evaluateOpenClawSend(toolCall: toolCall, context: context)
        default:
            // Unknown tools get moderate risk
            return .definite(RiskVerdict(
                level: .moderate,
                reason: "Unknown tool: \(toolCall.name)",
                tool: toolCall.name,
                requiresApproval: false,
                approvalPrompt: nil
            ))
        }
    }

    // MARK: - Per-Tool Evaluation

    private func evaluateClick(toolCall: ToolCall, context: ActionContext) -> HeuristicResult {
        let elementDesc = (toolCall.input["element_description"] ?? "").lowercased()

        let criticalPatterns = [
            "purchase", "buy now", "place order", "checkout", "pay",
            "confirm payment", "authorize", "wire transfer", "send money",
            "subscribe", "confirm purchase"
        ]
        if criticalPatterns.contains(where: { elementDesc.contains($0) }) {
            return .definite(RiskVerdict(
                level: .critical,
                reason: "Financial action: \(elementDesc)",
                tool: toolCall.name,
                requiresApproval: true,
                approvalPrompt: "FINANCIAL ACTION: Click \"\(elementDesc)\"?\n\nApp: \(context.activeAppName ?? "unknown")\nWindow: \(context.windowTitle ?? "unknown")"
            ))
        }

        let highPatterns = [
            "send", "submit", "post", "publish", "delete", "remove",
            "trash", "confirm", "sign out", "log out", "unsubscribe",
            "cancel subscription", "transfer", "approve", "execute",
            "empty trash", "permanently delete", "revoke"
        ]
        if highPatterns.contains(where: { elementDesc.contains($0) }) {
            return .definite(RiskVerdict(
                level: .high,
                reason: "Irreversible UI action: \(elementDesc) in \(context.activeAppName ?? "unknown")",
                tool: toolCall.name,
                requiresApproval: true,
                approvalPrompt: "Click \"\(elementDesc)\" in \(context.activeAppName ?? "unknown app")?"
            ))
        }

        if assessAppRisk(context) >= .high {
            return .definite(RiskVerdict(
                level: .moderate,
                reason: "Click in sensitive app: \(context.activeAppName ?? "unknown")",
                tool: toolCall.name,
                requiresApproval: false,
                approvalPrompt: nil
            ))
        }

        return .definite(RiskVerdict(
            level: .safe, reason: "Normal click", tool: toolCall.name,
            requiresApproval: false, approvalPrompt: nil
        ))
    }

    private func evaluateTypeText(toolCall: ToolCall, context: ActionContext) -> HeuristicResult {
        let text = toolCall.input["text"] ?? ""

        if containsCreditCardPattern(text) || containsSSNPattern(text) {
            return .definite(RiskVerdict(
                level: .critical,
                reason: "Text contains sensitive data pattern (credit card / SSN)",
                tool: "type_text",
                requiresApproval: true,
                approvalPrompt: "SENSITIVE DATA DETECTED: The text to type appears to contain a credit card number or SSN. This action is blocked for safety."
            ))
        }

        if context.focusedElementRole == "AXSecureTextField" {
            return .definite(RiskVerdict(
                level: .high,
                reason: "Typing into password/secure field in \(context.activeAppName ?? "unknown")",
                tool: "type_text",
                requiresApproval: true,
                approvalPrompt: "Type into secure field (\(context.focusedElementLabel ?? "password")) in \(context.activeAppName ?? "unknown app")?"
            ))
        }

        if isSensitiveFormContext(context) {
            return .definite(RiskVerdict(
                level: .high,
                reason: "Typing in sensitive form context: \(context.windowTitle ?? "unknown")",
                tool: "type_text",
                requiresApproval: true,
                approvalPrompt: "Type \"\(text.prefix(50))\" into form in \(context.activeAppName ?? "unknown")?\nWindow: \(context.windowTitle ?? "unknown")"
            ))
        }

        let sensitiveLabels = ["password", "credit card", "card number", "cvv", "ssn",
                               "social security", "routing number", "account number",
                               "bank", "pin", "secret", "token", "api key"]
        let label = (context.focusedElementLabel ?? "").lowercased()
        if sensitiveLabels.contains(where: { label.contains($0) }) {
            return .definite(RiskVerdict(
                level: .high,
                reason: "Typing into field labeled '\(context.focusedElementLabel ?? "")'",
                tool: "type_text",
                requiresApproval: true,
                approvalPrompt: "Type into field \"\(context.focusedElementLabel ?? "")\" in \(context.activeAppName ?? "unknown")?"
            ))
        }

        return .definite(RiskVerdict(
            level: .safe, reason: "Normal text input", tool: "type_text",
            requiresApproval: false, approvalPrompt: nil
        ))
    }

    private func evaluatePressKey(toolCall: ToolCall, context: ActionContext) -> HeuristicResult {
        let key = (toolCall.input["key"] ?? "").lowercased()
        let hasCmd = toolCall.input["command"] == "true" || toolCall.input["command"] == "1"

        let isConfirmKey = (key == "return" || key == "enter")

        if isConfirmKey {
            let recentActions = context.recentToolCalls
            let lastAction = recentActions.last

            let windowTitle = (context.windowTitle ?? "").lowercased()
            let confirmationDialogPatterns = [
                "confirm", "are you sure", "delete", "remove", "send",
                "transfer", "payment", "purchase", "unsubscribe"
            ]
            if confirmationDialogPatterns.contains(where: { windowTitle.contains($0) }) {
                return .definite(RiskVerdict(
                    level: .high,
                    reason: "Enter pressed in confirmation dialog: \(context.windowTitle ?? "")",
                    tool: "press_key",
                    requiresApproval: true,
                    approvalPrompt: "Press Enter in \"\(context.windowTitle ?? "dialog")\"?\n\nApp: \(context.activeAppName ?? "unknown")"
                ))
            }

            let messagingApps = ["messages", "telegram", "whatsapp", "slack", "discord",
                                 "signal", "microsoft teams", "mail"]
            let appName = (context.activeAppName ?? "").lowercased()
            if messagingApps.contains(where: { appName.contains($0) }) {
                if let last = lastAction, last.name == "type_text" {
                    return .definite(RiskVerdict(
                        level: .high,
                        reason: "Enter in messaging app after typing -- will send message",
                        tool: "press_key",
                        requiresApproval: true,
                        approvalPrompt: "Press Enter to send message in \(context.activeAppName ?? "messaging app")?\nLast typed: \(last.summary.prefix(80))"
                    ))
                }
            }

            if assessAppRisk(context) >= .high {
                return .definite(RiskVerdict(
                    level: .high,
                    reason: "Enter pressed in sensitive app: \(context.activeAppName ?? "unknown")",
                    tool: "press_key",
                    requiresApproval: true,
                    approvalPrompt: "Press Enter in \(context.activeAppName ?? "unknown app")?\nWindow: \(context.windowTitle ?? "unknown")"
                ))
            }
        }

        if hasCmd && (key == "delete" || key == "backspace") {
            return .definite(RiskVerdict(
                level: .high,
                reason: "Destructive shortcut: Cmd+Delete in \(context.activeAppName ?? "unknown")",
                tool: "press_key",
                requiresApproval: true,
                approvalPrompt: "Press Cmd+Delete in \(context.activeAppName ?? "unknown app")?"
            ))
        }

        return .definite(RiskVerdict(
            level: .safe, reason: "Normal key press", tool: "press_key",
            requiresApproval: false, approvalPrompt: nil
        ))
    }

    private func evaluateShellCommand(toolCall: ToolCall, context: ActionContext) -> HeuristicResult {
        let command = toolCall.input["command"] ?? ""

        let tier = PermissionClassifier.classify(command)

        switch tier {
        case .tier3(let reason):
            return .definite(RiskVerdict(
                level: .critical,
                reason: "Tier 3 shell command: \(reason)",
                tool: "run_shell_command",
                requiresApproval: true,
                approvalPrompt: "DANGEROUS COMMAND:\n\n\(command)\n\nReason: \(reason)"
            ))

        case .tier2(let category):
            if category == .uncategorized {
                return .uncertain(RiskVerdict(
                    level: .high,
                    reason: "Unrecognized command -- needs LLM evaluation",
                    tool: "run_shell_command",
                    requiresApproval: true,
                    approvalPrompt: "Unrecognized command:\n\n\(command)"
                ))
            }

            let cacheKey = "shell:\(category.rawValue)"
            if sessionApprovals[cacheKey] == true && permissionMode != .standard {
                return .definite(RiskVerdict(
                    level: .moderate,
                    reason: "Tier 2 shell (\(category.rawValue)) -- session-approved",
                    tool: "run_shell_command",
                    requiresApproval: false,
                    approvalPrompt: nil
                ))
            }
            return .definite(RiskVerdict(
                level: .high,
                reason: "Tier 2 shell command: \(category.approvalPrompt)",
                tool: "run_shell_command",
                requiresApproval: true,
                approvalPrompt: "\(category.approvalPrompt)\n\n\(command)",
                sessionCacheKey: cacheKey
            ))

        case .tier1:
            return .definite(RiskVerdict(
                level: .safe,
                reason: "Tier 1 read-only command",
                tool: "run_shell_command",
                requiresApproval: false,
                approvalPrompt: nil
            ))
        }
    }

    private func evaluateAppleScript(toolCall: ToolCall, context: ActionContext) -> HeuristicResult {
        let script = toolCall.input["script"] ?? ""

        let tier = PermissionClassifier.classifyAppleScript(script)

        switch tier {
        case .tier3(let reason):
            return .definite(RiskVerdict(
                level: .critical,
                reason: "Tier 3 AppleScript: \(reason)",
                tool: "run_applescript",
                requiresApproval: true,
                approvalPrompt: "DANGEROUS APPLESCRIPT:\n\n\(script.prefix(200))\n\nReason: \(reason)"
            ))

        case .tier2(let category):
            return .definite(RiskVerdict(
                level: .moderate,
                reason: "Tier 2 AppleScript: \(category.rawValue)",
                tool: "run_applescript",
                requiresApproval: false,
                approvalPrompt: nil
            ))

        case .tier1:
            return .definite(RiskVerdict(
                level: .safe,
                reason: "Read-only AppleScript",
                tool: "run_applescript",
                requiresApproval: false,
                approvalPrompt: nil
            ))
        }
    }

    private func evaluateOpenURL(toolCall: ToolCall, context: ActionContext) -> HeuristicResult {
        let urlString = toolCall.input["url"] ?? ""
        let url = URL(string: urlString)
        let host = url?.host?.lowercased() ?? ""

        let bankingDomains = [
            "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com",
            "capitalone.com", "usbank.com", "pnc.com", "tdbank.com",
            "schwab.com", "fidelity.com", "vanguard.com", "etrade.com",
            "paypal.com", "venmo.com", "zelle.com", "wise.com",
            "coinbase.com", "binance.com", "kraken.com"
        ]
        if bankingDomains.contains(where: { host.contains($0) }) {
            return .definite(RiskVerdict(
                level: .critical,
                reason: "Opening banking/financial site: \(host)",
                tool: "open_url",
                requiresApproval: true,
                approvalPrompt: "FINANCIAL SITE: Open \(urlString)?\n\nNote: Cyclop One will NOT enter any credentials or financial data."
            ))
        }

        let socialDomains = [
            "twitter.com", "x.com", "facebook.com", "instagram.com",
            "linkedin.com", "reddit.com", "tiktok.com", "youtube.com",
            "mail.google.com", "outlook.live.com", "mail.yahoo.com"
        ]
        if socialDomains.contains(where: { host.contains($0) }) {
            return .definite(RiskVerdict(
                level: .moderate,
                reason: "Opening social/email site: \(host)",
                tool: "open_url",
                requiresApproval: false,
                approvalPrompt: nil
            ))
        }

        return .definite(RiskVerdict(
            level: .safe,
            reason: "Normal URL navigation",
            tool: "open_url",
            requiresApproval: false,
            approvalPrompt: nil
        ))
    }

    private func evaluateOpenClawSend(toolCall: ToolCall, context: ActionContext) -> HeuristicResult {
        let message = toolCall.input["message"] ?? ""
        let channel = toolCall.input["channel"] ?? "default"

        return .definite(RiskVerdict(
            level: .high,
            reason: "Sending message via OpenClaw (\(channel))",
            tool: "openclaw_send",
            requiresApproval: true,
            approvalPrompt: "Send message via \(channel)?\n\nMessage: \(message.prefix(200))"
        ))
    }

    // MARK: - Context Assessment

    private func assessAppRisk(_ context: ActionContext) -> RiskLevel {
        let appName = (context.activeAppName ?? "").lowercased()
        let bundleID = (context.activeAppBundleID ?? "").lowercased()
        let url = (context.currentURL ?? "").lowercased()

        if isBankingContext(appName: appName, bundleID: bundleID, url: url) {
            return .critical
        }

        let commApps = ["mail", "outlook", "gmail", "thunderbird",
                        "messages", "telegram", "whatsapp", "slack", "discord"]
        if commApps.contains(where: { appName.contains($0) }) {
            let windowTitle = (context.windowTitle ?? "").lowercased()
            if windowTitle.contains("compose") || windowTitle.contains("new message")
                || windowTitle.contains("reply") {
                return .high
            }
            return .moderate
        }

        if appName.contains("system preferences") || appName.contains("system settings")
            || bundleID == "com.apple.systempreferences" {
            return .high
        }

        if appName.contains("terminal") || appName.contains("iterm")
            || bundleID.contains("terminal") {
            return .moderate
        }

        return .safe
    }

    private func isBankingContext(appName: String, bundleID: String, url: String) -> Bool {
        let bankingURLPatterns = [
            "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com",
            "paypal.com", "venmo.com", "schwab.com", "fidelity.com",
            "mint.com", "creditkarma.com"
        ]
        return bankingURLPatterns.contains(where: { url.contains($0) })
    }

    private func isSensitiveFormContext(_ context: ActionContext) -> Bool {
        let windowTitle = (context.windowTitle ?? "").lowercased()
        let url = (context.currentURL ?? "").lowercased()

        let formPatterns = [
            "checkout", "payment", "billing", "credit card",
            "login", "sign in", "sign up", "register",
            "transfer", "wire", "account"
        ]

        return formPatterns.contains(where: {
            windowTitle.contains($0) || url.contains($0)
        })
    }

    // MARK: - Pattern Detection

    private func containsCreditCardPattern(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(of: "[\\s\\-]", with: "", options: .regularExpression)
        let pattern = #"\b\d{13,19}\b"#
        return stripped.range(of: pattern, options: .regularExpression) != nil
    }

    private func containsSSNPattern(_ text: String) -> Bool {
        let pattern = #"\b\d{3}[\-\s]?\d{2}[\-\s]?\d{4}\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private func sanitizeInput(_ verdict: RiskVerdict) -> String {
        return "\(verdict.tool): \(verdict.reason)"
    }

    private func sanitizeForPrompt(_ input: [String: String]) -> String {
        var sanitized = input
        for key in ["password", "secret", "token", "api_key", "credit_card"] {
            if sanitized[key] != nil {
                sanitized[key] = "[REDACTED]"
            }
        }
        return sanitized.map { "\($0.key)=\($0.value.prefix(100))" }.joined(separator: ", ")
    }

    // MARK: - LLM Fallback

    private func evaluateWithLLM(
        toolCall: ToolCall,
        context: ActionContext,
        heuristicHint: RiskVerdict
    ) async -> RiskVerdict {
        let prompt = buildLLMEvaluationPrompt(toolCall: toolCall, context: context)
        let toolCallCopy = toolCall
        let hintCopy = heuristicHint

        // Race the LLM call against a 10-second timeout using a task group
        let result = await withTaskGroup(of: RiskVerdict?.self, returning: RiskVerdict.self) { group in
            group.addTask {
                return await self.performLLMCall(prompt: prompt, toolCall: toolCallCopy)
            }
            group.addTask {
                return await self.timeoutFallback(seconds: 10)
            }
            // First non-nil result wins; nil means timeout
            for await value in group {
                if let v = value {
                    group.cancelAll()
                    return v
                }
            }
            return hintCopy
        }

        return result
    }

    private func performLLMCall(prompt: String, toolCall: ToolCall) async -> RiskVerdict? {
        do {
            let response = try await ClaudeAPIService.shared.sendMessage(
                messages: [[
                    "role": "user",
                    "content": [["type": "text", "text": prompt]] as [[String: Any]]
                ] as [String: Any]],
                systemPrompt: """
                You are a safety classifier for an AI desktop agent. Evaluate the risk of a tool call.
                Respond with EXACTLY one line in this format:
                RISK: safe|moderate|high|critical -- <reason>

                Rules:
                - safe: No risk, proceed automatically (reading, observing, safe navigation)
                - moderate: Low risk, log but proceed (file writes to safe paths, normal clicks)
                - high: Needs user approval (sending messages, destructive UI actions, network writes)
                - critical: ALWAYS needs approval (financial, credential entry, system modification, data deletion)
                """,
                tools: [],
                model: "claude-haiku-4-5-20251001"
            )

            return parseLLMVerdict(response.textContent, toolCall: toolCall)
        } catch {
            NSLog("CyclopOne [ActionSafetyGate]: LLM evaluation failed: %@, using heuristic fallback", error.localizedDescription)
            return nil
        }
    }

    private func timeoutFallback(seconds: UInt64) async -> RiskVerdict? {
        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        // Return nil to signal timeout -- the caller will use the heuristic hint
        return nil
    }

    private func parseLLMVerdict(_ text: String, toolCall: ToolCall) -> RiskVerdict? {
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.uppercased().hasPrefix("RISK:") else { continue }

            let rest = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            let parts = rest.components(separatedBy: "--").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let levelStr = parts.first?.lowercased() else { continue }

            let reason = parts.count > 1 ? parts[1] : "LLM classified"

            let level: RiskLevel
            switch levelStr {
            case "safe": level = .safe
            case "moderate": level = .moderate
            case "high": level = .high
            case "critical": level = .critical
            default: continue
            }

            return RiskVerdict(
                level: level,
                reason: reason,
                tool: toolCall.name,
                requiresApproval: level >= .high,
                approvalPrompt: level >= .high ? "\(reason)\n\nTool: \(toolCall.name)" : nil
            )
        }
        return nil
    }

    private func buildLLMEvaluationPrompt(toolCall: ToolCall, context: ActionContext) -> String {
        return """
        Evaluate this tool call for risk:

        Tool: \(toolCall.name)
        Input: \(sanitizeForPrompt(toolCall.input))

        Context:
        - Active App: \(context.activeAppName ?? "unknown")
        - Window Title: \(context.windowTitle ?? "unknown")
        - Focused Element: \(context.focusedElementRole ?? "none") -- "\(context.focusedElementLabel ?? "none")"
        - Browser URL: \(context.currentURL ?? "N/A")
        - Recent Actions: \(context.recentToolCalls.map { "\($0.name): \($0.summary)" }.joined(separator: ", "))

        What is the risk level?
        """
    }

    // MARK: - Audit Logging

    private func logAudit(verdict: RiskVerdict, context: ActionContext, method: EvaluationMethod) {
        guard verdict.level >= .moderate else { return }

        let entry = AuditEntry(
            timestamp: Date(),
            runId: currentRunId ?? "unknown",
            tool: verdict.tool,
            input: sanitizeInput(verdict),
            riskLevel: verdict.level,
            reason: verdict.reason,
            method: method,
            approved: nil,
            appContext: "\(context.activeAppName ?? "?") -- \(context.windowTitle ?? "?")"
        )
        auditLog.append(entry)
    }

    private func flushAuditLog() async {
        guard !auditLog.isEmpty else { return }

        let dateFormatter = ISO8601DateFormatter()
        let dateStr = String(dateFormatter.string(from: Date()).prefix(10))
        let path = "Audit/\(dateStr).md"

        var content = "\n## Run: \(currentRunId ?? "unknown") (\(Date()))\n\n"
        content += "| Time | Tool | Risk | Method | Reason | App | Approved |\n"
        content += "|------|------|------|--------|--------|-----|----------|\n"

        for entry in auditLog {
            let time = DateFormatter.localizedString(from: entry.timestamp, dateStyle: .none, timeStyle: .medium)
            let approved = entry.approved.map { $0 ? "Yes" : "No" } ?? "N/A"
            let riskStr: String
            switch entry.riskLevel {
            case .safe: riskStr = "safe"
            case .moderate: riskStr = "moderate"
            case .high: riskStr = "high"
            case .critical: riskStr = "critical"
            }
            content += "| \(time) | \(entry.tool) | \(riskStr) | \(entry.method.rawValue) | \(entry.reason.prefix(60)) | \(entry.appContext ?? "?") | \(approved) |\n"
        }

        do {
            try await MemoryService.shared.appendToNote(at: path, text: content)
        } catch {
            NSLog("CyclopOne [ActionSafetyGate]: Failed to flush audit log: %@", error.localizedDescription)
        }
    }
}
