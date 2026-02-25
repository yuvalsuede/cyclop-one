import Foundation

// MARK: - LLM Fallback, Context Assessment, Pattern Detection & Audit Logging Extension

extension ActionSafetyGate {

    // MARK: - LLM Fallback

    func evaluateWithLLM(
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

    func performLLMCall(prompt: String, toolCall: ToolCall) async -> RiskVerdict? {
        do {
            let response = try await ClaudeAPIService.shared.sendMessage(
                messages: [APIMessage.userText(prompt)],
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
                model: AgentConfig.safetyModel
            )

            return parseLLMVerdict(response.textContent, toolCall: toolCall)
        } catch {
            NSLog("CyclopOne [ActionSafetyGate]: LLM evaluation failed: %@, using heuristic fallback", error.localizedDescription)
            return nil
        }
    }

    func timeoutFallback(seconds: UInt64) async -> RiskVerdict? {
        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        // Return nil to signal timeout -- the caller will use the heuristic hint
        return nil
    }

    func parseLLMVerdict(_ text: String, toolCall: ToolCall) -> RiskVerdict? {
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

    func buildLLMEvaluationPrompt(toolCall: ToolCall, context: ActionContext) -> String {
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

    // MARK: - Context Assessment

    func assessAppRisk(_ context: ActionContext) -> RiskLevel {
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

    func isBankingContext(appName: String, bundleID: String, url: String) -> Bool {
        let bankingURLPatterns = [
            "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com",
            "paypal.com", "venmo.com", "schwab.com", "fidelity.com",
            "mint.com", "creditkarma.com"
        ]
        return bankingURLPatterns.contains(where: { url.contains($0) })
    }

    func isSensitiveFormContext(_ context: ActionContext) -> Bool {
        let windowTitle = (context.windowTitle ?? "").lowercased()
        let url = (context.currentURL ?? "").lowercased()

        // Only flag genuinely sensitive form contexts -- financial and credential entry.
        // Removed "account", "register", "login", "sign in", "sign up" -- too broad,
        // triggers false positives on Gmail, account settings pages, etc.
        let formPatterns = [
            "checkout", "payment", "billing", "credit card",
            "transfer funds", "wire transfer"
        ]

        return formPatterns.contains(where: {
            windowTitle.contains($0) || url.contains($0)
        })
    }

    // MARK: - Pattern Detection

    func containsCreditCardPattern(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(of: "[\\s\\-]", with: "", options: .regularExpression)
        let pattern = #"\b\d{13,19}\b"#
        return stripped.range(of: pattern, options: .regularExpression) != nil
    }

    func containsSSNPattern(_ text: String) -> Bool {
        let pattern = #"\b\d{3}[\-\s]?\d{2}[\-\s]?\d{4}\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    func sanitizeInput(_ verdict: RiskVerdict) -> String {
        return "\(verdict.tool): \(verdict.reason)"
    }

    func sanitizeForPrompt(_ input: [String: String]) -> String {
        var sanitized = input
        for key in ["password", "secret", "token", "api_key", "credit_card"] {
            if sanitized[key] != nil {
                sanitized[key] = "[REDACTED]"
            }
        }
        return sanitized.map { "\($0.key)=\($0.value.prefix(100))" }.joined(separator: ", ")
    }

    // MARK: - Audit Logging

    func logAudit(verdict: RiskVerdict, context: ActionContext, method: EvaluationMethod) {
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

    func flushAuditLog() async {
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
