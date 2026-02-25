import Foundation
import AppKit

/// Protocol that provides the AgentLoop's capabilities to the ToolExecutionManager.
///
/// The ToolExecutionManager needs access to certain AgentLoop actor state
/// (panel hiding, screenshot capture, target app management) to execute tools.
/// This protocol decouples the two types and avoids circular dependencies.
protocol ToolExecutionContext: AnyObject, Sendable {
    func hideForScreenshot() async
    func showAfterScreenshot() async
    func letClicksThrough() async
    func stopClicksThrough() async
    func activateTargetApp() async
    func updateTargetPID() async
    var latestScreenshotValue: ScreenCapture? { get async }
    func setLatestScreenshot(_ sc: ScreenCapture?) async
    var targetAppPIDValue: pid_t? { get async }
    func setTargetAppPID(_ pid: pid_t?) async
    var agentConfig: AgentConfig { get async }
    var captureService: ScreenCaptureService { get }
    var accessibilityService: AccessibilityService { get }
    var actionExecutor: ActionExecutor { get }
    func mapToScreen(x: Double, y: Double) async -> (x: Double, y: Double)
}

/// Manages tool dispatch, fingerprinting, repetition detection, and safety gates.
///
/// Sprint 2 refactor: Extracted from AgentLoop to separate tool execution
/// concerns from the main agent loop. This is a plain struct (not an actor)
/// that lives inside the AgentLoop actor.
///
/// Tool execution is delegated to focused handler structs:
/// - UIInputToolHandler: click, type_text, press_key, move_mouse, drag, scroll
/// - ScreenCaptureToolHandler: take_screenshot, open_application, open_url
/// - ShellToolHandler: run_applescript, run_shell_command
/// - MemoryToolHandler: vault_*, task_*, remember, recall, openclaw_*
struct ToolExecutionManager {

    /// Tools that do not produce visual changes on screen.
    /// Used to determine whether verification scoring should be skipped.
    static let nonVisualTools: Set<String> = [
        "remember", "recall",
        "vault_read", "vault_write", "vault_search", "vault_list", "vault_append",
        "task_create", "task_update", "task_list", "task_complete",
        "take_screenshot", "read_screen",
        "shell_exec", "run_shell_command"
    ]

    /// Tool names handled by each handler, for dispatch routing.
    private static let uiInputTools: Set<String> = [
        "click", "right_click", "type_text", "press_key", "move_mouse", "drag", "scroll"
    ]
    private static let captureTools: Set<String> = [
        "take_screenshot", "open_application", "open_url"
    ]
    private static let shellTools: Set<String> = [
        "run_applescript", "run_shell_command"
    ]
    private static let memoryTools: Set<String> = [
        "vault_read", "vault_write", "vault_append", "vault_search", "vault_list",
        "task_create", "task_update", "task_list",
        "remember", "recall",
        "openclaw_send", "openclaw_check"
    ]

    // MARK: - Properties

    let safetyGate: ActionSafetyGate

    /// Sliding window of recent tool calls for context-aware safety evaluation.
    var recentToolCallHistory: [(name: String, summary: String)] = []

    /// Sprint 7: Complete tool call history for the current run (not pruned).
    /// Used for procedural memory recording after successful runs.
    var runToolCallHistory: [(name: String, summary: String)] = []

    /// Sliding window of recent tool calls (name + serialized input) for repetition detection.
    var recentToolCallFingerprints: [String] = []

    /// Number of consecutive identical tool calls that triggers a warning injection.
    let repetitionWarningThreshold: Int = 3

    // MARK: - Handlers

    private let uiInputHandler = UIInputToolHandler()
    private let captureHandler = ScreenCaptureToolHandler()
    private let shellHandler = ShellToolHandler()
    private let memoryHandler = MemoryToolHandler()

    // MARK: - Init

    init(safetyGate: ActionSafetyGate) {
        self.safetyGate = safetyGate
    }

    // MARK: - Repetition Detection

    func buildToolCallFingerprint(name: String, input: [String: Any]) -> String {
        let sortedKeys = input.keys.sorted()
        let paramParts = sortedKeys.map { key -> String in
            let value: String
            if let str = input[key] as? String {
                value = str
            } else if let num = input[key] as? NSNumber {
                value = num.stringValue
            } else if let bool = input[key] as? Bool {
                value = bool ? "true" : "false"
            } else {
                value = String(describing: input[key] ?? "nil")
            }
            return "\(key)=\(value)"
        }
        return "\(name)|\(paramParts.joined(separator: "&"))"
    }

    func detectToolCallRepetition() -> Bool {
        guard recentToolCallFingerprints.count >= repetitionWarningThreshold else { return false }
        let recent = Array(recentToolCallFingerprints.suffix(repetitionWarningThreshold))
        let first = recent[0]
        return recent.dropFirst().allSatisfy { $0 == first }
    }

    mutating func trackToolCallFingerprint(_ fingerprint: String) {
        recentToolCallFingerprints.append(fingerprint)
        if recentToolCallFingerprints.count > repetitionWarningThreshold + 2 {
            recentToolCallFingerprints.removeFirst()
        }
    }

    mutating func trackToolCall(name: String, summary: String) {
        recentToolCallHistory.append((name: name, summary: summary))
        if recentToolCallHistory.count > 5 {
            recentToolCallHistory.removeFirst()
        }
        // Sprint 7: Also track in full run history (not pruned)
        runToolCallHistory.append((name: name, summary: summary))
    }

    mutating func clearTracking() {
        recentToolCallHistory.removeAll()
        recentToolCallFingerprints.removeAll()
        runToolCallHistory.removeAll()
    }

    // MARK: - Safety Gate Interface

    func startSafetyGateRun(runId: String) async {
        await safetyGate.startRun(runId: runId)
    }

    func endSafetyGateRun() async {
        await safetyGate.endRun()
    }

    // MARK: - Action Context

    func gatherActionContext(
        targetAppPID: pid_t?,
        accessibility: AccessibilityService
    ) async -> ActionSafetyGate.ActionContext {
        let appInfo = await MainActor.run { () -> (name: String?, bundleID: String?) in
            guard let pid = targetAppPID,
                  let app = NSRunningApplication(processIdentifier: pid) else {
                return (nil, nil)
            }
            return (app.localizedName, app.bundleIdentifier)
        }

        let focusInfo = await MainActor.run { () -> (role: String, label: String)? in
            return accessibility.getFocusedElementInfo(targetPID: targetAppPID)
        }

        let windowTitle = await MainActor.run { () -> String? in
            return accessibility.getWindowTitle(targetPID: targetAppPID)
        }

        let currentURL: String?
        if let bundleID = appInfo.bundleID,
           ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
            "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser"]
            .contains(bundleID) {
            currentURL = await MainActor.run { () -> String? in
                return accessibility.getBrowserURL(targetPID: targetAppPID)
            }
        } else {
            currentURL = nil
        }

        return ActionSafetyGate.ActionContext(
            activeAppName: appInfo.name,
            activeAppBundleID: appInfo.bundleID,
            windowTitle: windowTitle,
            focusedElementRole: focusInfo?.role,
            focusedElementLabel: focusInfo?.label,
            recentToolCalls: Array(recentToolCallHistory.suffix(3)),
            currentURL: currentURL
        )
    }

    // MARK: - Tool Array (includes plugins)

    static func buildToolArray() async -> [[String: Any]] {
        var tools = ToolDefinitions.tools
        let pluginTools = await SkillRegistry.shared.toolDefinitions()
        tools.append(contentsOf: pluginTools)
        return tools
    }

    // MARK: - Observer Helpers

    static func fireAndForgetObserver(
        timeout: TimeInterval,
        body: @Sendable @escaping () async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await body()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Tool Execution (Dispatcher)

    func executeToolCall(
        name: String,
        input: [String: Any],
        context: ToolExecutionContext,
        iterationCount: Int,
        currentStepInstruction: String,
        confirmDestructiveActions: Bool,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void,
        onConfirmationNeeded: @Sendable @escaping (String) async -> Bool
    ) async -> ToolResult {

        // Early cancellation check
        guard !Task.isCancelled else {
            return ToolResult(result: "Cancelled", isError: false)
        }

        // Reject unknown tools before safety gate
        let isBuiltIn = ToolDefinitions.allToolNames.contains(name)
        let isPlugin = await SkillRegistry.shared.isSkillTool(name)
        guard isBuiltIn || isPlugin else {
            NSLog("CyclopOne [ToolExecutionManager]: Unknown tool rejected: %@", name)
            return ToolResult(result: "Unknown tool: \(name)", isError: true)
        }

        onStateChange(.executing(name))

        // Safety gate evaluation
        if confirmDestructiveActions {
            let safetyResult = await evaluateSafetyGate(
                name: name, input: input, context: context,
                iterationCount: iterationCount,
                currentStepInstruction: currentStepInstruction,
                onStateChange: onStateChange,
                onConfirmationNeeded: onConfirmationNeeded
            )
            if let denied = safetyResult { return denied }
        }

        // Dispatch to the appropriate handler
        if Self.uiInputTools.contains(name) {
            return await uiInputHandler.execute(name: name, input: input, context: context)
        }
        if Self.captureTools.contains(name) {
            return await captureHandler.execute(name: name, input: input, context: context)
        }
        if Self.shellTools.contains(name) {
            return await shellHandler.execute(name: name, input: input, context: context, onMessage: onMessage)
        }
        if Self.memoryTools.contains(name) {
            return await memoryHandler.execute(name: name, input: input)
        }

        // Skill tool fallback
        if await SkillRegistry.shared.isSkillTool(name) {
            do {
                let skillResult = try await SkillRegistry.shared.executeSkillTool(name: name, input: input)
                return ToolResult(result: skillResult.result, isError: skillResult.isError)
            } catch {
                return ToolResult(result: "Skill tool error: \(error.localizedDescription)", isError: true)
            }
        }

        return ToolResult(result: "Unknown tool: \(name)", isError: true)
    }

    // MARK: - Safety Gate Evaluation

    /// Evaluates the safety gate for a tool call. Returns a ToolResult if the action was denied, nil if approved.
    private func evaluateSafetyGate(
        name: String,
        input: [String: Any],
        context: ToolExecutionContext,
        iterationCount: Int,
        currentStepInstruction: String,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onConfirmationNeeded: @Sendable @escaping (String) async -> Bool
    ) async -> ToolResult? {
        let targetPID = await context.targetAppPIDValue
        let actionContext = await gatherActionContext(
            targetAppPID: targetPID,
            accessibility: context.accessibilityService
        )
        let stringInput = input.reduce(into: [String: String]()) { result, pair in
            if let str = pair.value as? String {
                result[pair.key] = str
            } else if let num = pair.value as? NSNumber {
                result[pair.key] = num.stringValue
            } else {
                result[pair.key] = String(describing: pair.value)
            }
        }
        let toolCall = ActionSafetyGate.ToolCall(
            name: name,
            input: stringInput,
            iteration: iterationCount,
            stepInstruction: currentStepInstruction.isEmpty ? nil : currentStepInstruction
        )
        let verdict = await safetyGate.evaluate(toolCall: toolCall, context: actionContext)

        switch verdict.level {
        case .safe:
            return nil
        case .moderate:
            NSLog("CyclopOne [SafetyGate]: MODERATE -- %@ -- %@", name, verdict.reason)
            return nil
        case .high:
            onStateChange(.awaitingConfirmation(verdict.reason))
            let approved = await onConfirmationNeeded(verdict.approvalPrompt ?? "Approve \(name)?")
            if !approved {
                await safetyGate.recordSessionApproval("denied:\(name)", approved: false)
                return ToolResult(result: "Action denied by user: \(verdict.reason)", isError: false)
            }
            if let cacheKey = verdict.sessionCacheKey {
                await safetyGate.recordSessionApproval(cacheKey, approved: true)
            }
            return nil
        case .critical:
            onStateChange(.awaitingConfirmation("CRITICAL: \(verdict.reason)"))
            let approved = await onConfirmationNeeded(
                verdict.approvalPrompt ?? "CRITICAL ACTION: \(name)\n\n\(verdict.reason)"
            )
            if !approved {
                return ToolResult(result: "Critical action denied by user: \(verdict.reason)", isError: false)
            }
            return nil
        }
    }
}
