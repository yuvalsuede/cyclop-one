import Foundation

// MARK: - Orchestrator Brain Planning
// Brain model (Opus) consultation for structured execution plans.
// Extracted from Orchestrator.swift in Sprint 1 (Refactoring).

extension Orchestrator {

    // MARK: - Planning System Prompt

    /// Planning system prompt for structured JSON output.
    static let planningSystemPrompt = """
    You are a planning agent for a macOS desktop automation agent called Cyclop One.

    Your job is to decompose the user's command into a step-by-step execution plan.
    The plan will be executed by a fast but less capable model (Haiku) that follows
    instructions literally.

    ## Planning Principles

    ### Use Loaded Preferences
    The user's preferences are provided in the memory context. Read them before planning.
    If a preference applies (e.g., "always use Gmail in Chrome"), follow it in the plan.

    ### Ask, Don't Assume
    If the task is ambiguous — multiple valid approaches exist and no preference is saved —
    output a single clarification question INSTEAD of a plan:
    { "clarify": "I can do this via Gmail in Chrome or the Mail app. Which do you prefer?" }
    Only do this when genuinely ambiguous. For clear tasks, plan directly.

    Output ONLY a JSON object. No other text, no markdown fences.

    ## Output Format

    {
      "summary": "Brief description of the approach",
      "steps": [
        {
          "title": "Short step name",
          "action": "Detailed instruction for the executor. Be specific about what to click, what to type. The executor sees ONLY this instruction plus a screenshot -- it does not see the full plan.",
          "targetApp": "The app, website, or tool to use for this step (e.g., 'Safari', 'Messages', 'Terminal', 'google.com'). null if no specific app is needed.",
          "expectedOutcome": "What the screen should show after this step. Be specific: 'Safari is open with google.com loaded' not 'browser is open'.",
          "requiresConfirmation": false,
          "maxIterations": 3,
          "expectedTools": ["open_application"],
          "alternativeApproaches": ["Fallback action if the primary approach fails. e.g., 'Use keyboard shortcut Cmd+N instead of clicking New button'"],
          "dependsOn": [0]
        }
      ]
    }

    ## Rules

    1. Each step must be independently executable from a screenshot + the action text.
       Do NOT write "continue from previous step" -- describe the full context.
       The action MUST specify the EXACT UI element by its visible label or position
       (e.g., "the text area to the right of the To: label"). Generic instructions like
       "enter the email" are NOT specific enough.
    2. Mark steps IRREVERSIBLE with "requiresConfirmation": true. Examples:
       - Sending email/messages
       - Deleting files
       - Submitting forms
       - Making purchases
       - Publishing content
    3. maxIterations per step:
       - Pure text input (type into focused field, press Tab/Enter): maxIterations = 8
       - Single click or navigate to app/URL: maxIterations = 8
       - Multi-field form fill (Tab between fields): maxIterations = 10
       - Complex multi-action (search, scroll, select, email compose): maxIterations = 15
       NEVER set maxIterations above 20 for any single step.
       NOTE: Web apps (Gmail, Outlook, etc.) often need extra iterations for autocomplete
       popups, verification screenshots, and UI state changes. Err on giving MORE iterations.
    4. expectedOutcome must be verifiable from a screenshot. Avoid abstract outcomes
       like "task is done" -- describe what is VISIBLE on screen.
    5. Maximum 10 steps. If the task needs more, break it into phases and plan phase 1.
    6. alternativeApproaches: optional array of 1-2 fallback actions if the primary approach fails.
       Add alternatives for critical steps or steps that use UI elements that might not be visible.
       Examples: "Use keyboard shortcut Cmd+N instead of clicking New button",
       "Right-click and select 'New Message' from context menu",
       "Use spotlight (Cmd+Space) to open the app instead".
       Only include alternatives that use a genuinely different approach, not minor variations.
    7. dependsOn: optional array of 0-indexed step IDs that must succeed before this step runs.
       Most steps depend implicitly on the previous step. Only set dependsOn when a step has
       non-obvious dependencies (e.g., step 5 needs BOTH step 1 and step 3 to have succeeded).
       Omit for simple sequential flows.
    8. expectedTools: list the tool names the executor will likely need.
       Available tools: click, right_click, type_text, press_key, take_screenshot,
       open_application, open_url, run_shell_command, run_applescript, move_mouse,
       drag, scroll, vault_read, vault_write, vault_search, vault_list, vault_append,
       remember, recall, task_create, task_update, task_list, openclaw_send, openclaw_check
    9. For form-filling or email steps, instruct the executor to use Tab to navigate
       between fields instead of clicking each one separately. This is faster and
       more reliable.

    ## Web Services — ALWAYS Use Browser, NEVER Native Apps
    - "gmail" / "email" / "send email" → use `open_url` with `https://mail.google.com` — NEVER Mail.app
    - "calendar" / "schedule" → use `open_url` with `https://calendar.google.com` — NEVER Calendar.app
    - "google docs/sheets/drive" → use `open_url` — NEVER a native app
    - Any web service (Slack, Notion, GitHub, Linear, etc.) → browser — NEVER the desktop app
    - ONLY use a native desktop app if the user explicitly says "open the app" or "use desktop app"

    ## Email Task Planning (via Gmail in Chrome)
    - ALWAYS send email via Gmail in the browser (https://mail.google.com)
    - NEVER use Mail.app, NEVER use AppleScript to compose email
    - Step 1 "Open Gmail": If the screenshot already shows Gmail open in Chrome, SKIP this step entirely.
      Only add it if Gmail is NOT visible.
    - Click the "Compose" button (bottom-left white button), then fill fields.
    - The To field is at the TOP of the compose window. Subject is below it. Body is below Subject.
    - GMAIL TO FIELD CRITICAL: After clicking Compose, the To field is auto-focused.
      DO NOT click the "To:" label — it opens a contacts picker popup.
      Instead: take a screenshot first. If a compose window is open, immediately type the email
      address without clicking anything. Gmail auto-focuses the To input.
      If a contacts picker popup appeared (shows "Select contacts" overlay), press Tab (NOT Escape)
      to dismiss it — pressing Escape inside Gmail compose closes the entire compose window.
    - After typing the email address, press Enter to confirm it as a recipient (not Tab — Tab in
      Gmail's To field can trigger autocomplete selection).
    - Then use Tab navigation to reach Subject (two Tab presses: To → CC → Subject) and Body (one more Tab).
      NEVER click field coordinates inside compose. NEVER press Escape inside compose (closes it).
      Each Tab press must be a separate press_key call — "Tab Tab" in a single call is invalid.
    - The Send step MUST have "requiresConfirmation": true.

    ## Form Field Planning
    - Always specify field position relative to the window (top/middle/bottom).
    - For sequential fields, use Tab navigation instead of clicking each field.
    - Each step action must be unambiguous — the executor only sees the action text + a screenshot.

    ## Example: Send an email
    User command: "Send an email to user@example.com saying hello"

    {
      "summary": "Open Gmail in Chrome, compose email to user@example.com",
      "steps": [
        {
          "title": "Open Gmail and click Compose",
          "action": "Use open_url to open https://mail.google.com in the browser. Once Gmail inbox is visible, click the white 'Compose' button in the bottom-left sidebar.",
          "targetApp": "Google Chrome",
          "expectedOutcome": "A compose window appears in the bottom-right with To, Subject, and Body fields.",
          "requiresConfirmation": false,
          "maxIterations": 8,
          "expectedTools": ["open_url", "take_screenshot", "click"]
        },
        {
          "title": "Type email address in To field",
          "action": "The To field should be focused after clicking Compose. Do NOT click the 'To:' label — that opens a contacts picker. If a popup is visible, press Tab (NOT Escape — Escape closes compose) to dismiss it. Then type: user@example.com directly. Press Enter to confirm the recipient.",
          "targetApp": "Google Chrome",
          "expectedOutcome": "The To field shows user@example.com as a blue chip/tag.",
          "requiresConfirmation": false,
          "maxIterations": 8,
          "expectedTools": ["take_screenshot", "type_text", "press_key"]
        },
        {
          "title": "Fill Subject and Body, then Send",
          "action": "Use Tab navigation to reach Subject (two separate press_key tab calls: first goes to CC, second to Subject). Type the subject. Then one more press_key tab to reach body. Type the body. Then click the blue 'Send' button at the bottom-left of the compose window. NEVER click field coordinates in compose. NEVER press Escape in compose.",
          "targetApp": "Google Chrome",
          "expectedOutcome": "The compose window closes, email sent confirmation visible.",
          "requiresConfirmation": true,
          "maxIterations": 8,
          "expectedTools": ["click", "type_text", "press_key"]
        }
      ]
    }
    """

    // MARK: - Brain Plan Consultation

    /// Result from the planner — either a plan or a clarification question.
    enum PlanResult {
        case plan(ExecutionPlan)
        case clarify(String)
    }

    /// Consult the brain model for a structured execution plan.
    /// Passes memory context so the planner can apply saved preferences.
    /// Returns a PlanResult — either a plan or a clarification question.
    func consultBrainForPlan(
        command: String,
        model: String,
        complexity: TaskComplexity,
        memoryContext: String = ""
    ) async -> PlanResult {
        let memorySection = memoryContext.isEmpty ? "" : """

        ## User Preferences & Memory
        <memory>
        \(memoryContext)
        </memory>
        Apply any relevant preferences from memory when building the plan.
        """

        let planPrompt = """
        The user's command is:

        "\(command)"

        Task complexity: \(complexity.rawValue)\(memorySection)
        """
        do {
            let response = try await ClaudeAPIService.shared.sendMessage(
                messages: [APIMessage.userText(planPrompt)],
                systemPrompt: Self.planningSystemPrompt,
                tools: [],
                model: model,
                maxTokens: 1024
            )
            let responseText = response.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("CyclopOne [Orchestrator]: Brain plan response from %@ (%d chars)", model, responseText.count)

            // Check if planner is asking for clarification
            if let data = responseText.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let question = json["clarify"] as? String {
                NSLog("CyclopOne [Orchestrator]: Planner needs clarification: %@", question)
                return .clarify(question)
            }

            return .plan(parseBrainPlanResponse(responseText, command: command))
        } catch {
            NSLog("CyclopOne [Orchestrator]: Brain planning failed: %@", error.localizedDescription)
            return .plan(ExecutionPlan(command: command, steps: [], summary: ""))
        }
    }

    /// Parse the brain model's JSON response into an ExecutionPlan.
    /// Falls back to an empty plan if parsing fails.
    func parseBrainPlanResponse(_ responseText: String, command: String) -> ExecutionPlan {
        // Step 1: Extract JSON from potential markdown wrapping
        let jsonString = extractJSON(from: responseText)

        // Step 2: Parse JSON
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stepsArray = json["steps"] as? [[String: Any]],
              !stepsArray.isEmpty else {
            NSLog("CyclopOne [Orchestrator]: Failed to parse brain plan JSON, falling back to empty plan")
            return ExecutionPlan(command: command, steps: [], summary: "")
        }

        let summary = json["summary"] as? String ?? ""

        // Step 3: Parse each step with defensive defaults
        let steps: [PlanStep] = stepsArray.enumerated().compactMap { index, stepDict in
            guard let title = stepDict["title"] as? String,
                  let action = stepDict["action"] as? String,
                  let expectedOutcome = stepDict["expectedOutcome"] as? String else {
                NSLog("CyclopOne [Orchestrator]: Skipping malformed step at index %d", index)
                return nil
            }
            let targetApp = stepDict["targetApp"] as? String
            let critStr = stepDict["criticality"] as? String
            let criticality = critStr.flatMap { StepCriticality(rawValue: $0) } ?? .normal
            return PlanStep(
                id: index,
                title: title,
                action: action,
                expectedOutcome: expectedOutcome,
                requiresConfirmation: stepDict["requiresConfirmation"] as? Bool ?? false,
                maxIterations: max(stepDict["maxIterations"] as? Int ?? 10, 8),
                targetApp: targetApp,
                expectedTools: stepDict["expectedTools"] as? [String],
                criticality: criticality,
                alternativeApproaches: stepDict["alternativeApproaches"] as? [String],
                dependsOn: (stepDict["dependsOn"] as? [Int])
            )
        }

        // Enforce maximum step count to prevent runaway plans
        let cappedSteps = Array(steps.prefix(10))
        if steps.count > 10 {
            NSLog("CyclopOne [Orchestrator]: Brain plan had %d steps, truncated to 10", steps.count)
        }
        NSLog("CyclopOne [Orchestrator]: Parsed %d plan steps from brain response", cappedSteps.count)
        return ExecutionPlan(command: command, steps: cappedSteps, summary: summary)
    }

    /// Extract JSON from potential markdown wrapping (```json...``` or raw JSON).
    func extractJSON(from text: String) -> String {
        // Try to find JSON between code fences
        if let start = text.range(of: "```json"),
           let end = text.range(of: "```", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = text.range(of: "```"),
           let end = text.range(of: "```", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Try to find a raw JSON object
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text
    }

    // MARK: - Plan Display

    /// Format an ExecutionPlan for human display.
    func formatPlanForUser(_ plan: ExecutionPlan) -> String {
        var lines: [String] = []
        lines.append("Plan: \(plan.summary)")
        lines.append("")
        for step in plan.steps {
            let confirmTag = step.requiresConfirmation ? " [CONFIRM]" : ""
            let targetTag = step.targetApp.map { " [\($0)]" } ?? ""
            lines.append("\(step.id + 1). \(step.title)\(confirmTag)\(targetTag)")
            lines.append("   \(step.action)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Brain Stuck Consultation

    /// Handle brain consultation when stuck is detected.
    /// Called from both flat and step-driven iteration loops.
    ///
    /// - Parameters:
    ///   - command: The original user command.
    ///   - stuckReason: Description of why the agent is stuck.
    ///   - iteration: Current iteration number.
    ///   - stepInfo: Optional step context string (e.g. " at step 3: Open Mail").
    ///   - journal: The run journal for logging.
    ///   - agentLoop: The agent loop to inject guidance into.
    ///   - onMessage: Callback for chat messages.
    func consultBrainForStuck(
        command: String,
        stuckReason: String,
        iteration: Int,
        stepInfo: String?,
        journal: RunJournal,
        agentLoop: AgentLoop,
        onMessage: @Sendable @escaping (ChatMessage) -> Void
    ) async {
        let brainModel = AgentConfig().brainModel
        let stepContext = stepInfo ?? ""
        NSLog("CyclopOne [Orchestrator]: Stuck detected (%@)%@, consulting brain (%@)",
              stuckReason, stepContext, brainModel)
        await journal.append(.stuck(reason: "\(stuckReason)\(stepContext) — consulting \(brainModel)"))

        let brainPrompt = """
        The agent executing the task "\(command)" is stuck\(stepContext). \
        Reason: \(stuckReason). \
        The agent has completed \(iteration) iterations so far. \
        Recent actions have not made progress. \
        Look at the current screenshot and assess: \
        1. What is the current state of the screen? \
        2. What progress has been made toward the task? \
        3. Provide 2-3 concise, specific suggestions for what the agent should try differently. \
        Focus on alternative approaches, not repeating what failed.
        """
        do {
            let brainMessage: APIMessage
            if let lastSS = stepMachine.preActionScreenshot {
                brainMessage = APIMessage.userWithScreenshot(
                    text: brainPrompt,
                    screenshot: lastSS,
                    uiTreeSummary: nil
                )
            } else {
                brainMessage = APIMessage.userText(brainPrompt)
            }
            let brainResponse = try await ClaudeAPIService.shared.sendMessage(
                messages: [brainMessage],
                systemPrompt: "You are a strategic advisor helping an autonomous desktop agent get unstuck. You can see the current screen state. Be concise and actionable.",
                tools: [],
                model: brainModel,
                maxTokens: 1024
            )
            let advice = brainResponse.textContent
            NSLog("CyclopOne [Orchestrator]: Brain advice received (%d chars)", advice.count)
            let displayMsg = stepInfo.map { "Agent stuck\($0)" } ?? "Agent stuck"
            onMessage(ChatMessage(role: .system, content: "\(displayMsg) — consulting brain model for guidance..."))
            await agentLoop.injectBrainGuidance(advice)
        } catch {
            NSLog("CyclopOne [Orchestrator]: Brain consultation failed: %@", error.localizedDescription)
            onMessage(ChatMessage(role: .system, content: "Error: Brain consultation failed — \(error.localizedDescription)"))
        }
    }
}
