import Foundation
import AppKit

/// Handles screen capture and app/URL opening tools that produce screenshots.
struct ScreenCaptureToolHandler {

    /// Reset state between runs (called by Orchestrator at run start).
    static func resetRunState() {
        lastOpenedURL = nil
    }

    func execute(
        name: String,
        input: [String: Any],
        context: ToolExecutionContext
    ) async -> ToolResult {
        let config = await context.agentConfig
        let accessibility = context.accessibilityService
        let capture = context.captureService
        let executor = context.actionExecutor

        switch name {
        case "take_screenshot":
            return await handleTakeScreenshot(context: context, config: config, accessibility: accessibility, capture: capture)
        case "open_application":
            return await handleOpenApplication(input: input, context: context, config: config, accessibility: accessibility, capture: capture, executor: executor)
        case "open_url":
            return await handleOpenURL(input: input, context: context, config: config, accessibility: accessibility, capture: capture, executor: executor)
        default:
            return ToolResult(result: "Unknown capture tool: \(name)", isError: true)
        }
    }

    // MARK: - Take Screenshot

    private func handleTakeScreenshot(
        context: ToolExecutionContext,
        config: AgentConfig,
        accessibility: AccessibilityService,
        capture: ScreenCaptureService
    ) async -> ToolResult {
        NSLog("CyclopOne [ToolExecutionManager]: take_screenshot -- hiding panel for capture (maxDim=%d, quality=%.2f)",
              config.screenshotMaxDimension, config.screenshotJPEGQuality)
        await context.hideForScreenshot()

        do {
            let ss = try await capture.captureScreen(
                maxDimension: config.screenshotMaxDimension,
                quality: config.screenshotJPEGQuality
            )
            await context.setLatestScreenshot(ss)

            NSLog("CyclopOne [take_screenshot]: %dx%d px, %@, base64=%d chars, data=%d bytes",
                  ss.width, ss.height, ss.mediaType, ss.base64.count, ss.imageData.count)

            let targetPID = await context.targetAppPIDValue
            let uiTree = await accessibility.getUITreeSummary(targetPID: targetPID)

            await context.showAfterScreenshot()

            return ToolResult(
                result: "Screenshot (\(ss.width)x\(ss.height), \(ss.mediaType), screen \(ss.screenWidth)x\(ss.screenHeight)).\nUI:\n\(uiTree)",
                isError: false,
                screenshot: ss
            )
        } catch {
            await context.showAfterScreenshot()
            return ToolResult(result: "Screenshot failed: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Open Application

    private func handleOpenApplication(
        input: [String: Any],
        context: ToolExecutionContext,
        config: AgentConfig,
        accessibility: AccessibilityService,
        capture: ScreenCaptureService,
        executor: ActionExecutor
    ) async -> ToolResult {
        guard let appName = input["name"] as? String else {
            return ToolResult(result: "Error: missing 'name'", isError: true)
        }
        do {
            let result = try await executor.openApplication(appName)
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            let newPID = await MainActor.run { () -> pid_t? in
                let currentPID = ProcessInfo.processInfo.processIdentifier
                if let app = NSWorkspace.shared.runningApplications.first(where: {
                    $0.localizedName?.lowercased() == appName.lowercased() &&
                    $0.processIdentifier != currentPID
                }) {
                    return app.processIdentifier
                }
                if let front = NSWorkspace.shared.frontmostApplication,
                   front.processIdentifier != currentPID {
                    return front.processIdentifier
                }
                return nil
            }
            if let pid = newPID { await context.setTargetAppPID(pid) }

            let postScreenshot = await captureAfterAction(context: context, config: config, capture: capture)

            let targetPID = await context.targetAppPIDValue
            let uiTree = await accessibility.getUITreeSummary(targetPID: targetPID)
            let screenshotInfo = postScreenshot.map { "Screenshot: \($0.width)x\($0.height)px" } ?? "No screenshot"
            return ToolResult(
                result: "Opened \(appName): \(result). \(screenshotInfo)\nUI:\n\(uiTree)",
                isError: false,
                screenshot: postScreenshot
            )
        } catch {
            return ToolResult(result: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Open URL

    /// Track the last URL opened to prevent duplicate tab creation.
    private static var lastOpenedURL: String?

    private func handleOpenURL(
        input: [String: Any],
        context: ToolExecutionContext,
        config: AgentConfig,
        accessibility: AccessibilityService,
        capture: ScreenCaptureService,
        executor: ActionExecutor
    ) async -> ToolResult {
        guard let urlString = input["url"] as? String else {
            return ToolResult(result: "Error: missing 'url'", isError: true)
        }
        guard URL(string: urlString) != nil, urlString.contains("://") else {
            return ToolResult(result: "Error: invalid URL '\(urlString)'. Must include protocol (https:// or http://).", isError: true)
        }

        // Guard: if we already opened this URL in this run, don't open another tab.
        // Just take a screenshot to show current state.
        if Self.lastOpenedURL == urlString {
            NSLog("CyclopOne [open_url]: Duplicate URL '%@' — skipping open, just taking screenshot", urlString)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let postScreenshot = await captureAfterAction(context: context, config: config, capture: capture)
            let targetPID = await context.targetAppPIDValue
            let uiTree = await accessibility.getUITreeSummary(targetPID: targetPID)
            let screenshotInfo = postScreenshot.map { "Screenshot: \($0.width)x\($0.height)px" } ?? "No screenshot"
            return ToolResult(
                result: "URL \(urlString) is already open in the browser. Do NOT call open_url again. Use click/type_text to interact with the page. \(screenshotInfo)\nUI:\n\(uiTree)",
                isError: false,
                screenshot: postScreenshot
            )
        }
        Self.lastOpenedURL = urlString

        do {
            // Use plain `open URL` — macOS routes to the default/running browser.
            // No AppleScript. No browser detection. One tab, one time.
            let safeURL = ActionExecutor.escapeShellArgument(urlString)
            _ = try await executor.runShellCommand("open \(safeURL)", timeout: 10)

            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await context.updateTargetPID()

            let postScreenshot = await captureAfterAction(context: context, config: config, capture: capture)

            let targetPID = await context.targetAppPIDValue
            let uiTree = await accessibility.getUITreeSummary(targetPID: targetPID)
            let screenshotInfo = postScreenshot.map { "Screenshot: \($0.width)x\($0.height)px" } ?? "No screenshot"
            return ToolResult(
                result: "Opened URL \(urlString) in default browser. \(screenshotInfo)\nUI:\n\(uiTree)",
                isError: false,
                screenshot: postScreenshot
            )
        } catch {
            return ToolResult(result: "Error opening URL: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Helpers

    /// Capture a screenshot after an action (open_application, open_url).
    private func captureAfterAction(
        context: ToolExecutionContext,
        config: AgentConfig,
        capture: ScreenCaptureService
    ) async -> ScreenCapture? {
        await context.hideForScreenshot()
        var postScreenshot: ScreenCapture? = nil
        if let ss = try? await capture.captureScreen(
            maxDimension: config.screenshotMaxDimension,
            quality: config.screenshotJPEGQuality
        ) {
            await context.setLatestScreenshot(ss)
            postScreenshot = ss
        }
        await context.showAfterScreenshot()
        return postScreenshot
    }
}
