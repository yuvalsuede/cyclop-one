import Foundation
import AppKit

// MARK: - Perceive Node
// Takes screenshot + reads AX tree. First node in each iteration cycle.
// Maps to: AgentLoop+ConversationBuilder.prepareRun() screenshot logic
//          + Orchestrator+IterationHelpers.runPostIterationProcessing() AX capture

/// Captures the current screen state (screenshot + accessibility tree).
/// Writes: preActionScreenshot, uiTreeSummary
///
/// Sprint 3: Foundation node. Sprint 4 wires into GraphRunner.
final class PerceiveNode: StateNode, @unchecked Sendable {

    let nodeId = GraphNodeId.perceive

    // MARK: - Dependencies

    private let captureService: ScreenCaptureService
    private let accessibilityService: AccessibilityService

    /// Agent loop reference for panel hide/show during capture.
    private weak var agentLoop: AgentLoop?

    /// Screenshot configuration.
    private let maxDimension: Int
    private let jpegQuality: Double

    // MARK: - Init

    init(
        captureService: ScreenCaptureService,
        accessibilityService: AccessibilityService,
        agentLoop: AgentLoop? = nil,
        maxDimension: Int = 1280,
        jpegQuality: Double = 0.85
    ) {
        self.captureService = captureService
        self.accessibilityService = accessibilityService
        self.agentLoop = agentLoop
        self.maxDimension = maxDimension
        self.jpegQuality = jpegQuality
    }

    // MARK: - Execute

    func execute(state: GraphState) async throws {
        try Task.checkCancellation()

        // Reset per-iteration transient state
        await state.resetForNewIteration()
        await state.incrementIteration()

        // Get target PID from agent loop (if available)
        let targetPID: pid_t? = await agentLoop?.targetAppPIDValue

        // Adaptive capture: decide whether to skip screenshot
        let iter = await state.iteration
        let captureDecision = await shouldCaptureScreenshot(state: state, iteration: iter)

        if !captureDecision.shouldCapture {
            // AX-tree-first: verify state via accessibility tree instead of screenshot
            let uiTree = await accessibilityService.getUITreeSummary(targetPID: targetPID)
            await state.setUITreeSummary(uiTree)
            await state.setAdaptiveSkippedScreenshot(true)
            await state.setScreenshotAvailable(false)

            // Carry forward previous screenshot for context
            // (preActionScreenshot stays as-is from previous iteration)
            NSLog("CyclopOne [PerceiveNode]: iteration=%d, SKIPPED screenshot — %@, AX tree=%d chars",
                  iter, captureDecision.reason, uiTree.count)
            return
        }

        // Hide floating panel so it doesn't appear in screenshot
        if let loop = agentLoop {
            await loop.hideForScreenshot()
        }

        // Capture screenshot
        let screenshot: ScreenCapture?
        do {
            screenshot = try await captureService.captureScreen(
                targetPID: targetPID,
                maxDimension: maxDimension,
                quality: jpegQuality
            )
        } catch {
            NSLog("CyclopOne [PerceiveNode]: WARNING — Screenshot capture failed: %@. Agent will rely on AX tree for this iteration.",
                  error.localizedDescription)
            screenshot = nil
        }

        // Show panel again
        if let loop = agentLoop {
            await loop.showAfterScreenshot()
        }

        // Track consecutive screenshots for adaptive capture
        await state.incrementConsecutiveScreenshots()
        await state.setScreenshotAvailable(screenshot != nil)

        // Read accessibility tree (always — cheap and provides text verification)
        let uiTree = await accessibilityService.getUITreeSummary(
            targetPID: targetPID
        )

        // Update shared state via actor setter methods
        await state.setPreActionScreenshot(screenshot)
        await state.setUITreeSummary(uiTree)

        let ssDesc = screenshot.map { "\($0.width)x\($0.height)" } ?? "none"
        let consec = await state.consecutiveScreenshotsWithoutAction
        NSLog("CyclopOne [PerceiveNode]: iteration=%d, screenshot=%@, consecutiveCaptures=%d, AX tree=%d chars",
              iter, ssDesc, consec, uiTree.count)
    }

    // MARK: - Adaptive Capture Decisions

    /// Result of the screenshot decision with a human-readable reason for logging.
    private struct CaptureDecision {
        let shouldCapture: Bool
        let reason: String
    }

    /// Raw tool names where AX tree verification is sufficient (no screenshot needed).
    /// Sprint 8: Must match actual tool names from ToolExecutionManager dispatch.
    /// Includes text input tools (AX tree verifies text), capture tools (already
    /// captured), and all non-visual tools (no screen changes expected).
    private static let axSufficientTools: Set<String> = [
        // Text input — AX tree can verify text appeared
        "type_text",
        // Capture tools — screenshot already taken, redundant to capture again
        "take_screenshot", "read_screen",
        // Non-visual tools — no screen changes (mirrors ToolExecutionManager.nonVisualTools)
        "remember", "recall",
        "vault_read", "vault_write", "vault_search", "vault_list", "vault_append",
        "task_create", "task_update", "task_list", "task_complete",
        "run_shell_command", "shell_exec"
    ]

    /// Maximum consecutive screenshots without an action before skipping.
    /// Two identical captures in a row means the screen hasn't changed.
    private static let maxConsecutiveScreenshots = 2

    /// Determine whether a screenshot is needed based on state signals.
    ///
    /// Skip rules (Sprint 8):
    /// 1. Never skip on first 2 iterations (need visual baseline)
    /// 2. Skip if last tool was type_text or key_press (AX tree suffices)
    /// 3. Skip if 2+ consecutive screenshots already taken without an action
    /// 4. Always capture after clicks, scrolls, navigation, and app launches
    private func shouldCaptureScreenshot(
        state: GraphState,
        iteration: Int
    ) async -> CaptureDecision {
        // Always capture on first 2 iterations (need baseline)
        guard iteration > 2 else {
            return CaptureDecision(shouldCapture: true, reason: "baseline iteration")
        }

        // Check raw tool name for fine-grained skip decision
        let toolName = await state.lastToolName
        if !toolName.isEmpty && Self.axSufficientTools.contains(toolName) {
            return CaptureDecision(
                shouldCapture: false,
                reason: "last action was \(toolName)"
            )
        }

        // Check consecutive screenshot counter
        let consecutive = await state.consecutiveScreenshotsWithoutAction
        if consecutive >= Self.maxConsecutiveScreenshots {
            return CaptureDecision(
                shouldCapture: false,
                reason: "\(consecutive) consecutive screenshots without action"
            )
        }

        return CaptureDecision(shouldCapture: true, reason: "visual action")
    }
}
