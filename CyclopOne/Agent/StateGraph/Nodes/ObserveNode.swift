import Foundation
import AppKit

// MARK: - Observe Node
// Captures post-action state for verification and stuck detection.
// Maps to: Orchestrator+IterationHelpers.runPostIterationProcessing()
//
// Sprint 8: AX-first verification and visual diff hints.

/// Takes a post-action screenshot and reads the AX tree after tool execution.
/// Records text responses and screenshot data for stuck detection by EvaluateNode.
///
/// Reads: toolCallSummaries, hasVisualToolCalls, lastToolName, preActionScreenshot
/// Writes: postActionScreenshot, uiTreeSummary, screenshotsIdentical,
///         axVerificationSucceeded, stuck detection data
///
/// Sprint 3: Foundation. Sprint 8: AX-first verification + visual diff.
final class ObserveNode: StateNode, @unchecked Sendable {

    let nodeId = GraphNodeId.observe

    // MARK: - Dependencies

    private let captureService: ScreenCaptureService
    private let accessibilityService: AccessibilityService

    /// Agent loop reference for panel hide/show and latest screenshot tracking.
    private weak var agentLoop: AgentLoop?

    /// Screenshot configuration.
    private let maxDimension: Int
    private let jpegQuality: Double

    /// Minimum iteration duration (avoids tight spin loops).
    private let minIterationDuration: TimeInterval

    // MARK: - Stuck Detection Tracking

    /// Recent screenshot hashes for perceptual stuck detection.
    private var recentScreenshotHashes: [UInt64] = []

    /// Recent text responses for text repetition detection.
    private var recentTextResponses: [String] = []

    /// Recent AX tree summaries for change detection.
    private var recentAXSummaries: [String] = []

    /// Threshold: how many similar entries trigger stuck detection.
    private let stuckThreshold: Int

    // MARK: - Init

    init(
        captureService: ScreenCaptureService,
        accessibilityService: AccessibilityService,
        agentLoop: AgentLoop? = nil,
        maxDimension: Int = 1280,
        jpegQuality: Double = 0.85,
        minIterationDuration: TimeInterval = 1.0,
        stuckThreshold: Int = 3
    ) {
        self.captureService = captureService
        self.accessibilityService = accessibilityService
        self.agentLoop = agentLoop
        self.maxDimension = maxDimension
        self.jpegQuality = jpegQuality
        self.minIterationDuration = minIterationDuration
        self.stuckThreshold = stuckThreshold
    }

    // MARK: - Execute

    func execute(state: GraphState) async throws {
        try Task.checkCancellation()

        let iter = await state.iteration
        let iterStartTime = Date()
        let targetPID: pid_t? = await agentLoop?.targetAppPIDValue

        // If adaptive capture skipped pre-action screenshot, skip post too
        let adaptiveSkipped = await state.adaptiveSkippedScreenshot
        if adaptiveSkipped {
            let uiTree = await accessibilityService.getUITreeSummary(targetPID: targetPID)
            await state.setUITreeSummary(uiTree)
            trackAXForStuck(uiTree)

            NSLog("CyclopOne [ObserveNode]: iteration=%d, adaptive skip — AX-only",
                  iter)
            await enforceMinDuration(since: iterStartTime)
            return
        }

        // Sprint 8: Try AX-first verification before taking a screenshot.
        // If AX tree alone can confirm the action succeeded, skip the screenshot.
        let lastTool = await state.lastToolName
        let axVerified = await verifyViaAXTree(
            lastTool: lastTool,
            targetPID: targetPID,
            state: state
        )

        if axVerified {
            // AX verification succeeded — skip post-action screenshot
            let uiTree = await accessibilityService.getUITreeSummary(targetPID: targetPID)
            await state.setUITreeSummary(uiTree)
            await state.setAXVerificationSucceeded(true)
            trackAXForStuck(uiTree)
            await recordStepOutcome(state: state, iter: iter)

            NSLog("CyclopOne [ObserveNode]: iteration=%d, AX verified '%@' — skipped post screenshot",
                  iter, lastTool)
            await enforceMinDuration(since: iterStartTime)
            return
        }

        // Full observation: screenshot + AX tree
        if let loop = agentLoop { await loop.hideForScreenshot() }

        let screenshot: ScreenCapture?
        do {
            screenshot = try await captureService.captureScreen(
                targetPID: targetPID,
                maxDimension: maxDimension,
                quality: jpegQuality
            )
        } catch {
            NSLog("CyclopOne [ObserveNode]: Post-action screenshot failed: %@",
                  error.localizedDescription)
            screenshot = nil
        }

        if let loop = agentLoop { await loop.showAfterScreenshot() }

        let uiTree = await accessibilityService.getUITreeSummary(targetPID: targetPID)

        await state.setPostActionScreenshot(screenshot)
        await state.setUITreeSummary(uiTree)

        // Sprint 8: Visual diff — compare pre and post screenshots
        let preScreenshot = await state.preActionScreenshot
        if let pre = preScreenshot, let post = screenshot {
            let (diffDesc, identical) = computeVisualDiff(pre: pre, post: post)
            await state.setVisualDiffDescription(diffDesc)
            await state.setScreenshotsIdentical(identical)
        }

        // Stuck detection tracking
        if let ss = screenshot {
            let hash = StepStateMachine.perceptualHash(ss.imageData) ?? 0
            recentScreenshotHashes.append(hash)
            if recentScreenshotHashes.count > stuckThreshold {
                recentScreenshotHashes.removeFirst()
            }
        }
        trackAXForStuck(uiTree)
        trackTextForStuck(await state.textContent)
        await recordStepOutcome(state: state, iter: iter)
        await enforceMinDuration(since: iterStartTime)

        let ssDesc = screenshot.map { "\($0.width)x\($0.height)" } ?? "none"
        let identical = await state.screenshotsIdentical
        NSLog("CyclopOne [ObserveNode]: iteration=%d, postScreenshot=%@, identical=%d, AX=%d chars",
              iter, ssDesc, identical ? 1 : 0, uiTree.count)
    }

    // MARK: - AX-First Verification (Sprint 8)

    /// Attempt to verify the last action's success using only the AX tree.
    /// Returns true if verification succeeds and screenshot can be skipped.
    ///
    /// - type_text: Check if the focused element's value contains new text
    /// - click: Check if focused element role changed (e.g., menu opened)
    private func verifyViaAXTree(
        lastTool: String,
        targetPID: pid_t?,
        state: GraphState
    ) async -> Bool {
        guard let pid = targetPID else { return false }

        switch lastTool {
        case "type_text":
            // After typing, check if the focused text field has non-empty value
            let detail = await accessibilityService.getFocusedElementDetail(targetPID: pid)
            guard let d = detail else { return false }
            // Text fields should have a value after typing
            let isTextField = d.role == "AXTextField" || d.role == "AXTextArea"
                || d.role == "AXComboBox" || d.role == "AXSearchField"
            if isTextField, let val = d.value, !val.isEmpty {
                NSLog("CyclopOne [ObserveNode]: AX verified type_text — %@ has value (%d chars)",
                      d.role, val.count)
                return true
            }
            return false

        case "click", "right_click":
            // After click, check if focused element changed (role or selection)
            let detail = await accessibilityService.getFocusedElementDetail(targetPID: pid)
            guard let d = detail else { return false }
            // If a menu, popover, or list appeared (selectedChildren > 0), verified
            if d.selectedChildren > 0 {
                NSLog("CyclopOne [ObserveNode]: AX verified click — %@ has %d selected children",
                      d.role, d.selectedChildren)
                return true
            }
            return false

        default:
            return false
        }
    }

    // MARK: - Stuck Detection (exposed for EvaluateNode)

    /// Check if the agent appears stuck based on recent observations.
    func detectStuck() -> String? {
        if isScreenshotStuck() {
            return "Last \(stuckThreshold) screenshots are perceptually identical"
        }
        if isTextStuck() {
            return "Last \(stuckThreshold) text responses are repeating"
        }
        return nil
    }

    /// Clear stuck tracking data (called after recovery or step transition).
    func clearStuckTracking() {
        recentScreenshotHashes.removeAll()
        recentTextResponses.removeAll()
        recentAXSummaries.removeAll()
    }

    // MARK: - Visual Diff Detection (Sprint 8)

    /// Compare pre and post screenshots using perceptual hash.
    /// Returns (description, isIdentical) tuple.
    private func computeVisualDiff(
        pre: ScreenCapture,
        post: ScreenCapture
    ) -> (description: String, identical: Bool) {
        guard let preHash = StepStateMachine.perceptualHash(pre.imageData),
              let postHash = StepStateMachine.perceptualHash(post.imageData) else {
            return ("", false)
        }

        let distance = StepStateMachine.hammingDistance(preHash, postHash)

        if distance == 0 {
            return ("No visual change detected", true)
        } else if distance <= 5 {
            return ("Minor visual change (distance: \(distance))", true)
        } else if distance <= 15 {
            return ("Moderate visual change (distance: \(distance))", false)
        } else if distance <= 30 {
            return ("Significant visual change (distance: \(distance))", false)
        } else {
            return ("Major visual change (distance: \(distance))", false)
        }
    }

    // MARK: - Private Helpers

    private func trackAXForStuck(_ uiTree: String) {
        recentAXSummaries.append(uiTree)
        if recentAXSummaries.count > stuckThreshold {
            recentAXSummaries.removeFirst()
        }
    }

    private func trackTextForStuck(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentTextResponses.append(trimmed)
        if recentTextResponses.count > stuckThreshold {
            recentTextResponses.removeFirst()
        }
    }

    /// Record step outcome for task-scoped memory (Sprint 7).
    private func recordStepOutcome(state: GraphState, iter: Int) async {
        let summaries = await state.toolCallSummaries
        guard !summaries.isEmpty else { return }
        let command = await state.command
        let actionDesc = summaries.map { $0.toolName }.joined(separator: ", ")
        let anyFailed = summaries.contains { $0.isError }
        await MemoryService.shared.recordStepOutcome(
            command: command,
            step: "iteration \(iter)",
            action: actionDesc,
            success: !anyFailed
        )
    }

    private func enforceMinDuration(since start: Date) async {
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < minIterationDuration {
            let remaining = minIterationDuration - elapsed
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }

    // MARK: - Private Stuck Detection

    private func isScreenshotStuck() -> Bool {
        guard recentScreenshotHashes.count >= stuckThreshold else { return false }
        let recent = Array(recentScreenshotHashes.suffix(stuckThreshold))
        let first = recent[0]
        let tolerance = 10

        let allSimilar = recent.dropFirst().allSatisfy { hash in
            StepStateMachine.hammingDistance(first, hash) <= tolerance
        }
        guard allSimilar else { return false }

        if recentAXSummaries.count >= stuckThreshold {
            let recentAX = Array(recentAXSummaries.suffix(stuckThreshold))
            let firstAX = recentAX[0]
            if !recentAX.dropFirst().allSatisfy({ $0 == firstAX }) {
                return false // AX tree changed, not truly stuck
            }
        }
        return true
    }

    private func isTextStuck() -> Bool {
        guard recentTextResponses.count >= stuckThreshold else { return false }
        let recent = Array(recentTextResponses.suffix(stuckThreshold))
        let normalized = recent.map { normalizeForComparison($0) }
        let first = normalized[0]
        return normalized.dropFirst().allSatisfy { $0 == first }
    }

    private func normalizeForComparison(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
