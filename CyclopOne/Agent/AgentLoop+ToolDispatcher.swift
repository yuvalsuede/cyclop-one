import Foundation
import AppKit

/// Tool execution context, panel/focus control, coordinate mapping, and API retry.
///
/// These methods implement the `ToolExecutionContext` protocol that
/// `ToolExecutionManager` calls back into during tool dispatch, plus the
/// API retry logic used by `executeIteration`.
extension AgentLoop {

    // MARK: - Panel Setup

    func setPanel(_ panel: NSPanel) {
        self.panel = panel
        Task { await windowManager.setPanel(panel) }
    }

    func setFloatingDot(_ dot: FloatingDot) {
        self.floatingDot = dot
        self.panel = dot  // FloatingDot IS the NSPanel
        Task { await windowManager.setFloatingDot(dot) }
    }

    // MARK: - ToolExecutionContext Protocol

    /// Provide access to the latest screenshot for tool execution.
    var latestScreenshotValue: ScreenCapture? {
        get async { latestScreenshot }
    }

    /// Set the latest screenshot from tool execution.
    func setLatestScreenshot(_ sc: ScreenCapture?) {
        latestScreenshot = sc
    }

    /// Provide target app PID for tool execution.
    var targetAppPIDValue: pid_t? {
        get async { targetAppPID }
    }

    /// Set target app PID from tool execution.
    func setTargetAppPID(_ pid: pid_t?) {
        targetAppPID = pid
    }

    /// Provide agent config for tool execution.
    var agentConfig: AgentConfig {
        get async { config }
    }

    // MARK: - Panel & Focus Control (delegated to WindowManager)

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
        // Keep targetAppPID in sync with WindowManager
        await windowManager.setTargetAppPID(targetAppPID)
        await windowManager.activateTargetApp()
    }

    /// Re-enable the panel for user interaction (called when agent finishes).
    func restorePanelInteraction() async {
        await windowManager.restorePanelInteraction()
    }

    // MARK: - Coordinate Mapping

    func mapToScreen(x: Double, y: Double) -> (x: Double, y: Double) {
        guard let ss = latestScreenshot else { return (x, y) }
        return ss.toScreenCoords(x: x, y: y)
    }

    /// Update targetAppPID from the current frontmost application.
    /// Called after clicks and app launches with a delay to let activation settle.
    func updateTargetPID() async {
        await windowManager.updateTargetPID()
        // Sync back from WindowManager
        if let pid = await windowManager.targetAppPID {
            targetAppPID = pid
        }
    }

    /// Ensure the target application is still the frontmost app before each iteration.
    /// If another app stole focus (e.g. Chrome, Finder), re-activate the target app.
    /// This prevents the agent from interacting with the wrong app mid-task.
    func ensureTargetAppFocused() async {
        guard let targetPID = self.targetAppPID else { return }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }

        // If Cyclop One itself is frontmost, or a different app stole focus, re-activate target
        if let front = frontPID, front != targetPID {
            let frontName = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
            }
            let targetName = await MainActor.run {
                NSRunningApplication(processIdentifier: targetPID)?.localizedName ?? "unknown"
            }

            // Only log and re-focus if a non-Cyclop One app stole focus
            // (Cyclop One steals focus naturally during screenshot/panel operations)
            if front != currentPID {
                NSLog("CyclopOne [AgentLoop]: Focus stolen by '%@' (PID %d), re-activating target '%@' (PID %d)",
                      frontName, front, targetName, targetPID)
            }

            await activateTargetApp()
            // Brief settle time after re-activation
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
        }
    }

    // MARK: - API Retry (Sprint 14)

    /// Send a message to the Claude API with retry logic and error classification.
    ///
    /// - Classifies errors as transient, rate-limited, or permanent.
    /// - For 429 responses, attempts to parse the retry-after value.
    /// - Uses exponential backoff for transient errors.
    /// - Tracks consecutive failures for health monitoring.
    func sendAPIWithRetry(
        systemPrompt: String,
        onMessage: @Sendable @escaping (ChatMessage) -> Void
    ) async throws -> ClaudeResponse {
        let maxRetryAttempts = 3
        var lastError: Error?

        for attempt in 0..<maxRetryAttempts {
            // M6: Check cancellation before each attempt
            try Task.checkCancellation()

            do {
                NSLog("CyclopOne [AgentLoop]: Calling Claude API (model=%@, messages=%d, attempt=%d/%d)",
                      config.modelName, conversation.conversationHistory.count, attempt + 1, maxRetryAttempts)
                let response = try await api.sendMessage(
                    messages: conversation.conversationHistory,
                    systemPrompt: systemPrompt,
                    tools: await ToolExecutionManager.buildToolArray(),
                    model: config.modelName
                )
                NSLog("CyclopOne [AgentLoop]: API success -- %d content blocks, stopReason=%@, tokens=%d/%d",
                      response.contentBlocks.count, response.stopReason, response.inputTokens, response.outputTokens)
                return response
            } catch is CancellationError {
                // M6: Propagate cancellation immediately, no retry
                throw CancellationError()
            } catch {
                NSLog("CyclopOne [AgentLoop]: API error (attempt %d): %@", attempt + 1, error.localizedDescription)
                lastError = error
                consecutiveAPIFailures += 1
                let classification = classifyError(error)

                switch classification {
                case .permanent:
                    // Don't retry permanent errors
                    throw error

                case .rateLimit(let retryAfter):
                    let delay = retryAfter ?? (5.0 * pow(2.0, Double(attempt)))
                    if attempt < maxRetryAttempts - 1 {
                        onMessage(ChatMessage(
                            role: .system,
                            content: "Rate limited. Retrying in \(Int(delay))s (attempt \(attempt + 2)/\(maxRetryAttempts))..."
                        ))
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }

                case .transient:
                    let delay = 2.0 * pow(2.0, Double(attempt))  // 2s, 4s, 8s
                    if attempt < maxRetryAttempts - 1 {
                        onMessage(ChatMessage(
                            role: .system,
                            content: "API error (transient). Retrying in \(Int(delay))s (attempt \(attempt + 2)/\(maxRetryAttempts))..."
                        ))
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }

                case .unknown:
                    let delay = 3.0 * pow(2.0, Double(attempt))  // 3s, 6s, 12s
                    if attempt < maxRetryAttempts - 1 {
                        onMessage(ChatMessage(
                            role: .system,
                            content: "API error (unknown). Retrying in \(Int(delay))s (attempt \(attempt + 2)/\(maxRetryAttempts))..."
                        ))
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                }
            }
        }

        throw lastError ?? APIError.invalidResponse
    }
}
