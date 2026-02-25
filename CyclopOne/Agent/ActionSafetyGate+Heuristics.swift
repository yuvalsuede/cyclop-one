import Foundation

// MARK: - Heuristic Evaluation Extension

extension ActionSafetyGate {

    // MARK: - Heuristic Dispatch

    func evaluateHeuristic(toolCall: ToolCall, context: ActionContext) -> HeuristicResult {
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
            // Plugin or unrecognized tool -- moderate risk, log for visibility
            NSLog("CyclopOne [ActionSafetyGate]: Heuristic default for tool '%@' -- treating as plugin-safe (moderate)", toolCall.name)
            return .definite(RiskVerdict(
                level: .moderate,
                reason: "Plugin/unrecognized tool: \(toolCall.name)",
                tool: toolCall.name,
                requiresApproval: false,
                approvalPrompt: nil
            ))
        }
    }

    // MARK: - Per-Tool Evaluation

    func evaluateClick(toolCall: ToolCall, context: ActionContext) -> HeuristicResult {
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

    func evaluateTypeText(toolCall: ToolCall, context: ActionContext) -> HeuristicResult {
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

    func evaluatePressKey(toolCall: ToolCall, context: ActionContext) -> HeuristicResult {
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

    func evaluateShellCommand(toolCall: ToolCall, context: ActionContext) -> HeuristicResult {
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

    func evaluateAppleScript(toolCall: ToolCall, context: ActionContext) -> HeuristicResult {
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

    func evaluateOpenURL(toolCall: ToolCall, context: ActionContext) -> HeuristicResult {
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

    func evaluateOpenClawSend(toolCall: ToolCall, context: ActionContext) -> HeuristicResult {
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
}
