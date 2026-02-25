import Foundation
import AppKit

/// Vision-First Reactive Loop for Cyclop One.
///
/// Each iteration is completely self-contained — there is NO conversation history.
/// Instead, each call to Claude receives:
///   - A fresh system prompt with goal + rolling 10-line progress log
///   - One screenshot (the current screen state)
///   - A request to output a single JSON action decision
///
/// This keeps token usage dramatically lower (~2.2K vs ~14K per iteration) and
/// eliminates context-pollution from accumulated tool results.
///
/// Claude outputs plain JSON text (no tool_use blocks). The JSON is parsed by
/// `ReactiveActionParser` and the action is dispatched via `ToolExecutionManager`.
actor ReactiveLoopActor: ToolExecutionContext {

    // MARK: - Constants

    let maxIterations: Int = 35
    /// How many consecutive identical action fingerprints trigger an escape note injection.
    private let repetitionThreshold: Int = 1
    /// How many consecutive API/tool failures before giving up.
    private let maxConsecutiveFailures: Int = 3
    /// Pause between iterations (100 ms) to avoid hammering the system.
    private let iterationPauseNanoseconds: UInt64 = 100_000_000

    // MARK: - Services (ToolExecutionContext requirements)

    let captureService: ScreenCaptureService = ScreenCaptureService.shared
    let accessibilityService: AccessibilityService = AccessibilityService.shared
    let actionExecutor: ActionExecutor = ActionExecutor.shared

    // MARK: - Agent State

    private var config: AgentConfig = AgentConfig()
    private var toolExec: ToolExecutionManager

    /// Latest screenshot from the current iteration (used by tool handlers for coordinate mapping).
    var latestScreenshot: ScreenCapture? = nil

    /// PID of the application the agent is currently interacting with.
    var targetAppPID: pid_t? = nil

    /// Window manager for panel hide/show and focus management.
    private let windowManager = WindowManager()

    // MARK: - ToolExecutionContext Protocol

    var latestScreenshotValue: ScreenCapture? {
        get async { latestScreenshot }
    }

    func setLatestScreenshot(_ sc: ScreenCapture?) {
        latestScreenshot = sc
    }

    var targetAppPIDValue: pid_t? {
        get async { targetAppPID }
    }

    func setTargetAppPID(_ pid: pid_t?) {
        targetAppPID = pid
    }

    var agentConfig: AgentConfig {
        get async { config }
    }

    func hideForScreenshot() async {
        await windowManager.hideForScreenshot()
    }

    func showAfterScreenshot() async {
        await windowManager.showAfterScreenshot()
    }

    func letClicksThrough() async {
        await windowManager.letClicksThrough()
    }

    func stopClicksThrough() async {
        await windowManager.stopClicksThrough()
    }

    func activateTargetApp() async {
        await windowManager.setTargetAppPID(targetAppPID)
        await windowManager.activateTargetApp()
    }

    func updateTargetPID() async {
        await windowManager.updateTargetPID()
        if let pid = await windowManager.targetAppPID {
            targetAppPID = pid
        }
    }

    func mapToScreen(x: Double, y: Double) -> (x: Double, y: Double) {
        guard let ss = latestScreenshot else { return (x, y) }
        return ss.toScreenCoords(x: x, y: y)
    }

    // MARK: - Init

    init() {
        let gate = ActionSafetyGate(
            brainModel: AgentConfig.defaultBrainModel,
            permissionMode: .standard
        )
        self.toolExec = ToolExecutionManager(safetyGate: gate)
    }

    // MARK: - Main Entry Point

    /// Run the reactive loop for the given goal.
    ///
    /// - Parameters:
    ///   - goal: The user's task description.
    ///   - targetPID: Optional PID of the target application.
    ///   - onStateChange: Callback for UI state updates.
    ///   - onMessage: Callback for chat message display.
    ///   - onConfirmationNeeded: Callback for destructive action approval.
    /// - Returns: A `ReactiveRunResult` describing the outcome.
    func run(
        goal: String,
        targetPID: pid_t?,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void,
        onConfirmationNeeded: @Sendable @escaping (String) async -> Bool
    ) async -> ReactiveRunResult {

        // Generate a run ID
        let runId = "reactive-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 1000...9999))"

        var state = ReactiveAgentState(
            goal: goal,
            runId: runId,
            startedAt: Date()
        )

        // Store the target PID on the actor for ToolExecutionContext use
        self.targetAppPID = targetPID

        NSLog("CyclopOne [ReactiveLoop]: Starting run=%@ goal=%@", runId, goal)
        onMessage(ChatMessage(role: .system, content: "Starting reactive loop: \(goal)"))
        onStateChange(.thinking)

        // Main iteration loop
        while state.iteration < maxIterations && !state.isComplete && !state.isFailed {
            guard !Task.isCancelled else {
                state.isFailed = true
                state.completionReason = "Cancelled by user."
                break
            }

            state.iteration += 1
            NSLog("CyclopOne [ReactiveLoop]: Iteration %d/%d", state.iteration, maxIterations)

            // --- Step 1: Take screenshot ---
            onStateChange(.capturing)
            let screenshot: ScreenCapture
            do {
                screenshot = try await captureService.captureScreen(
                    targetPID: targetAppPID,
                    maxDimension: config.screenshotMaxDimension,
                    quality: config.screenshotJPEGQuality
                )
                latestScreenshot = screenshot
            } catch {
                NSLog("CyclopOne [ReactiveLoop]: Screenshot failed: %@", error.localizedDescription)
                state.consecutiveFailures += 1
                if state.consecutiveFailures >= maxConsecutiveFailures {
                    state.isFailed = true
                    state.completionReason = "Screen capture failed \(maxConsecutiveFailures) times: \(error.localizedDescription)"
                }
                onMessage(ChatMessage(role: .system, content: "Screenshot error: \(error.localizedDescription)"))
                continue
            }

            // --- Step 2: Determine if we need an escape note (anti-repetition) ---
            // Check both consecutive repetition AND rolling-window frequency.
            // Rolling window catches interleaved repetition like: click(x)→Tab→click(x)→Tab
            // where the consecutive counter resets on each Tab but the stuck click keeps happening.
            let windowRepeatCount = state.recentFingerprints.filter { $0 == state.lastActionFingerprint }.count
            let isStuck = state.consecutiveSameActions >= repetitionThreshold || windowRepeatCount >= 3

            let forceEscapeNote: String?
            if isStuck {
                let lastTool = state.lastAction?.toolName ?? "the same action"
                forceEscapeNote = """
STOP: You have repeated \(lastTool) with the same parameters multiple times — this is NOT working.
Mandatory alternatives to try:
1. If trying to focus a text field: use type_text directly WITHOUT clicking first.
2. If a click on a field doesn't work: press Tab key to navigate to the next field instead.
3. If pressing Tab doesn't help: try clicking at a completely different location, or scroll to find the element.
4. If in Gmail compose and stuck on a field: press Escape to close compose, reopen it, and retry.
5. If nothing works after trying all alternatives: set "done": true and explain the blocker.
Do NOT repeat the same action again. Do NOT use osascript or JavaScript injection.
"""
            } else {
                forceEscapeNote = nil
            }

            // --- Step 3: Build system prompt ---
            let systemPrompt = buildSystemPrompt(state: state, escapeNote: forceEscapeNote)

            // --- Step 4: Build the user message (screenshot + minimal context) ---
            let userMessage = APIMessage.user([
                .image(mediaType: screenshot.mediaType, data: screenshot.base64)
            ])

            // --- Step 5: Call Claude API (stateless, no tool schemas, small output) ---
            onStateChange(.thinking)
            let response: ClaudeResponse
            do {
                response = try await ClaudeAPIService.shared.sendMessage(
                    messages: [userMessage],
                    systemPrompt: systemPrompt,
                    tools: [],  // No tool schemas — Claude outputs raw JSON text
                    model: ModelTier.smart.modelName,
                    maxTokens: 512
                )
                state.consecutiveFailures = 0  // Reset on success
            } catch {
                NSLog("CyclopOne [ReactiveLoop]: API error (iter=%d): %@", state.iteration, error.localizedDescription)
                state.consecutiveFailures += 1
                if state.consecutiveFailures >= maxConsecutiveFailures {
                    state.isFailed = true
                    state.completionReason = "API failed \(maxConsecutiveFailures) consecutive times: \(error.localizedDescription)"
                }
                onMessage(ChatMessage(role: .system, content: "API error: \(error.localizedDescription)"))
                try? await Task.sleep(nanoseconds: iterationPauseNanoseconds * 10)
                continue
            }

            // Track tokens
            state.totalInputTokens += response.inputTokens
            state.totalOutputTokens += response.outputTokens

            let responseText = response.textContent
            NSLog("CyclopOne [ReactiveLoop]: Response (iter=%d, tokens=%d/%d): %@",
                  state.iteration, response.inputTokens, response.outputTokens,
                  String(responseText.prefix(200)))

            // --- Step 6: Parse JSON action from response ---
            guard let action = ReactiveActionParser.parse(responseText) else {
                NSLog("CyclopOne [ReactiveLoop]: Failed to parse JSON from response (iter=%d)", state.iteration)
                onMessage(ChatMessage(role: .system, content: "Could not parse action from Claude response."))
                state.consecutiveFailures += 1
                if state.consecutiveFailures >= maxConsecutiveFailures {
                    state.isFailed = true
                    state.completionReason = "Failed to parse valid JSON action \(maxConsecutiveFailures) times."
                }
                continue
            }

            // --- Step 7: Check if done ---
            if action.done {
                NSLog("CyclopOne [ReactiveLoop]: Claude signalled done at iteration %d", state.iteration)
                state.isComplete = true
                state.completionReason = action.progressNote.isEmpty
                    ? "Goal achieved: \(goal)"
                    : action.progressNote
                onStateChange(.done)
                onMessage(ChatMessage(role: .assistant, content: "Done: \(state.completionReason)"))
                break
            }

            // --- Step 8: Anti-repetition fingerprint check ---
            let fingerprint = ReactiveActionParser.buildFingerprint(action: action.action, params: action.params)
            if fingerprint == state.lastActionFingerprint {
                state.consecutiveSameActions += 1
            } else {
                state.consecutiveSameActions = 0
            }
            state.lastActionFingerprint = fingerprint

            // Update rolling window (max 8 entries)
            state.recentFingerprints.append(fingerprint)
            if state.recentFingerprints.count > 8 {
                state.recentFingerprints.removeFirst()
            }

            // --- Step 9: Execute the action via ToolExecutionManager ---
            let paramPreview = String(String(describing: action.params).prefix(200))
            NSLog("CyclopOne [ReactiveLoop]: Executing action=%@ params=%@ (iter=%d)",
                  action.action, paramPreview, state.iteration)
            onStateChange(.executing(action.action))

            let toolResult = await toolExec.executeToolCall(
                name: action.action,
                input: action.params,
                context: self,
                iterationCount: state.iteration,
                currentStepInstruction: goal,
                confirmDestructiveActions: config.confirmDestructiveActions,
                onStateChange: onStateChange,
                onMessage: onMessage,
                onConfirmationNeeded: onConfirmationNeeded
            )

            // --- Step 10: Update state after execution ---
            let succeeded = !toolResult.isError

            if toolResult.isError {
                NSLog("CyclopOne [ReactiveLoop]: Tool error (iter=%d): %@", state.iteration, toolResult.result)
                state.consecutiveFailures += 1
            } else {
                state.consecutiveFailures = 0
            }

            // Update screenshot after visual tool execution
            if let ss = toolResult.screenshot {
                latestScreenshot = ss
            }

            // Record last action for next prompt
            state.lastAction = ReactiveLastAction(
                toolName: action.action,
                summary: toolResult.isError
                    ? "ERROR: \(toolResult.result.prefix(100))"
                    : action.progressNote,
                succeeded: succeeded,
                fingerprint: fingerprint
            )

            // Append progress note to rolling log (max 10 lines)
            let progressEntry: String
            if toolResult.isError {
                progressEntry = "[\(state.iteration)] \(action.action) FAILED: \(toolResult.result.prefix(80))"
            } else {
                progressEntry = "[\(state.iteration)] \(action.progressNote)"
            }
            state.progressLines.append(progressEntry)
            if state.progressLines.count > 10 {
                state.progressLines.removeFirst(state.progressLines.count - 10)
            }

            // Surface tool result to chat UI
            let resultDisplay = toolResult.isError
                ? "Tool error (\(action.action)): \(toolResult.result)"
                : "\(action.action): \(action.progressNote)"
            onMessage(ChatMessage(role: .system, content: resultDisplay))

            // Brief pause before next iteration
            try? await Task.sleep(nanoseconds: iterationPauseNanoseconds)
        }

        // Handle exhausting the iteration budget without completion
        if !state.isComplete && !state.isFailed {
            state.isFailed = true
            state.completionReason = "Reached maximum iterations (\(maxIterations)) without completing goal."
            onStateChange(.error(state.completionReason))
            onMessage(ChatMessage(role: .system, content: "Max iterations reached."))
        }

        let result = ReactiveRunResult.fromState(state)
        NSLog("CyclopOne [ReactiveLoop]: Run %@ finished — success=%d, iterations=%d, tokens=%d/%d",
              runId, result.success ? 1 : 0, result.iterations,
              result.totalInputTokens, result.totalOutputTokens)

        onStateChange(result.success ? .done : .error(result.summary))
        return result
    }

    // MARK: - System Prompt Builder

    /// Build a compact system prompt targeting under 600 tokens.
    /// Includes: goal, rolling progress log (max 10 lines), last action, rules, and available actions.
    private func buildSystemPrompt(state: ReactiveAgentState, escapeNote: String?) -> String {
        let progressSection: String
        if state.progressLines.isEmpty {
            progressSection = "Nothing yet."
        } else {
            progressSection = state.progressLines.joined(separator: "\n")
        }

        let lastActionSection: String
        if let last = state.lastAction {
            let status = last.succeeded ? "succeeded" : "FAILED"
            lastActionSection = "\(last.toolName) (\(status)): \(last.summary)"
        } else {
            lastActionSection = "None"
        }

        let escapeSection = escapeNote.map { "\n\n## URGENT — BREAK THE LOOP\n\($0)" } ?? ""

        return """
You are Cyclop One, a macOS desktop automation agent.
Iteration: \(state.iteration)/\(maxIterations)

## GOAL
\(state.goal)

## WHAT YOU'VE DONE SO FAR
\(progressSection)

## LAST ACTION
\(lastActionSection)\(escapeSection)

## YOUR JOB
Look at the screenshot. Then output ONLY this JSON (no markdown, no explanation):
{
  "screen": "1 sentence describing exactly what you see",
  "blocker": null,
  "action": "tool_name",
  "params": {},
  "progress_note": "what you just accomplished (past tense)",
  "done": false
}

## RULES
- Describe ONLY what you actually see. Never hallucinate UI elements.
- If an unexpected popup/dialog is visible: handle it FIRST before anything else.
- Set "done": true only when the goal is fully achieved.
- Never repeat a failed action — try a different approach.
- Coordinates: click the CENTER of elements.
- Web services: Chrome only (Gmail=mail.google.com, WhatsApp=web.whatsapp.com, X=x.com).
- CRITICAL — browser rule: If a browser is ALREADY open and showing the correct site, NEVER open_application to launch another browser. Use the browser that is already on screen. Only open_application for a browser if NO browser is visible at all.
- CRITICAL — app rule: If the target app (e.g. Chrome with x.com, Mail, Notes) is already visible on screen, DO NOT open_application — it is already open. Start interacting with it directly.

## GMAIL COMPOSE RULES (follow precisely)
- Do NOT click the "To:" label text — type email directly into the To field
- If "Select contacts" overlay appears: do NOT press Escape (Escape closes the compose window).
  Instead press Tab to navigate past it — Tab will dismiss the popup and move to the next field.
- After typing email address: press Enter to confirm it (wait for tag/chip to appear)
- After the recipient chip is confirmed (or a contact card appears), press Tab to navigate.
  Do NOT press Escape inside compose — it closes the entire compose window.
- Tab order in Gmail compose: To → CC → Subject → Body
- To reach Subject from To: press Tab key TWICE — each Tab is a SEPARATE press_key call:
    Step A: press_key {"key": "tab"}   ← moves to CC field (dismisses any popup)
    Step B: press_key {"key": "tab"}   ← moves to Subject field
  Then type the subject.
- To reach Body from Subject: press Tab key ONCE — one more press_key {"key": "tab"} call
  Then type the body.
- IMPORTANT: press_key only accepts ONE key per call. "Tab Tab" is NOT valid. Use two separate calls.
- NEVER click field coordinates in the compose window — use Tab navigation only
- NEVER press Escape inside a compose window — it will close compose entirely
- After typing body: click the blue Send button at the bottom-left

## WHATSAPP RULES
- Use native WhatsApp app, NOT web.whatsapp.com
- ALWAYS search for the target name FIRST — even if a chat is already visible, do NOT use it unless you verified it matches
- Step 1: Click the search bar at top of the chat list, type the EXACT name given in the command
- Step 2: Wait for results, then click the matching result
- Do NOT assume the currently visible chat is the target — verify the chat title matches the name in the command
- Do NOT assume any name refers to "saved messages" or self-chat — always search for the exact name
- If search returns no results: try the New Chat button (pencil icon) and search there
- Once the CORRECT chat is open: type_text directly (input is focused) without clicking first
- If type_text fails: click the input area once, then retry
- After typing: press Enter or Return to send

## X/TWITTER RULES
- Open x.com in Chrome
- Click compose button ("+" button or "What is happening?" field)
- If click doesn't focus: use type_text directly anyway — it often works
- Type message, click Post button

## TEXT INPUT PRINCIPLE
In compose windows and chat inputs: try type_text DIRECTLY first.
Clicking coordinates often misses in floating/nested windows.
If type_text shows nothing in the screenshot: then click the field and try again.

## AVAILABLE ACTIONS
click(x,y) | type_text(text) | press_key(key) | open_url(url) | open_application(name) | scroll(x,y,direction,amount) | right_click(x,y) | take_screenshot() | run_shell_command(command)
- press_key supports modifier combos: {"key": "cmd+l"}, {"key": "cmd+shift+s"}, {"key": "ctrl+a"}
- run_shell_command requires {"command": "..."} — the parameter is named "command" not "cmd"
"""
    }
}
