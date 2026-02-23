import Foundation
import SwiftUI
import AppKit

/// The main coordinator that bridges the UI with the agent loop.
@MainActor
class AgentCoordinator: ObservableObject {

    @Published var messages: [ChatMessage] = []
    @Published var state: AgentState = .idle
    @Published var isRunning: Bool = false
    @Published var totalTokensUsed: Int = 0

    /// The PID of the app that was frontmost BEFORE Cyclop One's popover stole focus.
    /// Captured in togglePopover() and used by prepareRun() to target the correct app.
    var previousFrontmostPID: pid_t?

    private let agentLoop: AgentLoop
    private let orchestrator: Orchestrator
    private var pendingConfirmation: CheckedContinuation<Bool, Never>?
    private var confirmationTimeoutTask: Task<Void, Never>?

    /// Atomic flag ensuring CheckedContinuation is resumed exactly once.
    /// Prevents double-resume crash when onCancel races with timeout/approve/deny.
    private var confirmationResumed = false

    /// The command gateway — unified entry point for all input sources.
    /// External surfaces (hotkey, OpenClaw) submit commands here.
    let gateway: CommandGateway

    /// Timeout for destructive action confirmations (seconds).
    private let confirmationTimeout: TimeInterval = 60

    init() {
        let config = AgentConfig()
        let loop = AgentLoop(config: config)
        let orch = Orchestrator()

        self.agentLoop = loop
        self.orchestrator = orch
        self.gateway = CommandGateway(orchestrator: orch, agentLoop: loop)

        messages.append(ChatMessage(
            role: .assistant,
            content: "Hi! I'm Cyclop One. I can see your screen and control your Mac. What would you like me to do?"
        ))
    }

    /// Reference to the floating dot for direct status updates.
    private weak var floatingDot: FloatingDot?

    /// Give the agent loop a direct reference to the panel window.
    func setPanel(_ panel: NSPanel) {
        Task {
            await agentLoop.setPanel(panel)
        }
    }

    /// Set the floating dot reference for status updates and screenshot exclusion.
    /// Also passes the dot to the AgentLoop so it can hide the popover before captures.
    func setFloatingDot(_ dot: FloatingDot) {
        self.floatingDot = dot
        Task {
            await agentLoop.setFloatingDot(dot)
        }
    }

    /// Update the floating dot to reflect the current agent state.
    private func updateDotStatus() {
        let dotStatus = DotStatus.from(state)
        floatingDot?.updateDotStatus(dotStatus)
    }

    func handleUserMessage(_ text: String) async {
        // CONC-H4: Set isRunning synchronously on @MainActor BEFORE creating
        // the async work. This prevents double-invocation if the user taps
        // Send twice quickly.
        guard !isRunning else {
            NSLog("CyclopOne [Coordinator]: Already running, ignoring: %@", text)
            return
        }
        NSLog("CyclopOne [Coordinator]: handleUserMessage — starting run for: %@", text)
        isRunning = true

        messages.append(ChatMessage(role: .user, content: text))
        messages.append(ChatMessage(role: .assistant, content: "", isLoading: true))

        // Sprint 6: Create a LocalReplyChannel so the Orchestrator can
        // route results back to the dot UI via the gateway protocol.
        let replyChannel = LocalReplyChannel(coordinator: self)

        // Sprint 3: Route through the Orchestrator for supervised runs
        // (journal, timing guards, stuck detection, completion token).
        // The replyChannel is passed alongside the existing callbacks.
        // Pass the previously captured frontmost PID so prepareRun targets the right app
        let savedPID = previousFrontmostPID
        previousFrontmostPID = nil  // Reset for next run

        NSLog("CyclopOne [Coordinator]: Calling orchestrator.startRun... (targetPID: %@)",
              savedPID.map { String($0) } ?? "nil")
        let result = await orchestrator.startRun(
            command: text,
            source: "chat",
            agentLoop: agentLoop,
            replyChannel: replyChannel,
            targetPID: savedPID,
            onStateChange: { [weak self] newState in
                Task { @MainActor in self?.state = newState }
            },
            onMessage: { [weak self] message in
                Task { @MainActor in
                    self?.messages.removeAll { $0.isLoading }
                    self?.messages.append(message)
                }
            },
            onConfirmationNeeded: { [weak self] action in
                guard let self else { return false }
                return await self.requestConfirmation(for: action)
            }
        )

        NSLog("CyclopOne [Coordinator]: Run finished — success=%d, iterations=%d, score=%@, summary=%@, tokens=%d/%d (verify: %d/%d)",
              result.success, result.iterations,
              result.finalScore.map { String($0) } ?? "nil",
              result.summary,
              result.totalInputTokens, result.totalOutputTokens,
              result.verificationInputTokens, result.verificationOutputTokens)

        // Ensure panel is restored after the run
        await agentLoop.finishRun()

        messages.removeAll { $0.isLoading }

        // Surface run failure to the user if no error message was already shown.
        // The onMessage callback may have already added an error, so check
        // whether the last message is already a system error to avoid duplicates.
        if !result.success {
            let lastIsSystemError = messages.last.map { $0.role == .system && $0.content.hasPrefix("Error") } ?? false
            if !lastIsSystemError {
                messages.append(ChatMessage(role: .system, content: "Run failed: \(result.summary)"))
            }
            if case .error = state {} else { state = .error(result.summary) }
        } else {
            if case .error = state {} else { state = .idle }
        }
        isRunning = false

        // Update token count from the run result
        totalTokensUsed += result.totalInputTokens + result.totalOutputTokens
    }

    // MARK: - Confirmation (CONC-1 Fix)

    /// Request user confirmation with cancellation safety and timeout.
    ///
    /// Uses `withTaskCancellationHandler` to ensure the continuation is
    /// always resumed — even if the parent task is cancelled. A 60-second
    /// timeout auto-denies if the user doesn't respond.
    private func requestConfirmation(for action: String) async -> Bool {
        await MainActor.run { self.state = .awaitingConfirmation(action) }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    // Reset the exactly-once flag for this new confirmation
                    self.confirmationResumed = false

                    // Store the continuation so approve/deny can resume it
                    self.pendingConfirmation = continuation

                    // Start a timeout that auto-denies after 60 seconds
                    self.confirmationTimeoutTask?.cancel()
                    self.confirmationTimeoutTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(self.confirmationTimeout * 1_000_000_000))
                        if !Task.isCancelled {
                            self.timeoutConfirmation()
                        }
                    }
                }
            }
        } onCancel: {
            // If the parent task is cancelled (e.g., user hit stop),
            // resume the continuation immediately to avoid deadlock.
            // Guard with confirmationResumed to prevent double-resume crash.
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.confirmationResumed else { return }
                guard let continuation = self.pendingConfirmation else { return }
                self.confirmationResumed = true
                self.pendingConfirmation = nil
                self.confirmationTimeoutTask?.cancel()
                self.confirmationTimeoutTask = nil
                continuation.resume(returning: false)
            }
        }
    }

    /// Called when the 60-second timeout expires without a response.
    private func timeoutConfirmation() {
        guard !confirmationResumed else { return }
        guard let continuation = pendingConfirmation else { return }
        confirmationResumed = true
        pendingConfirmation = nil
        confirmationTimeoutTask = nil
        state = .idle
        messages.append(ChatMessage(role: .system, content: "Confirmation timed out — action denied."))
        continuation.resume(returning: false)
    }

    func approveConfirmation() {
        guard !confirmationResumed else { return }
        guard let continuation = pendingConfirmation else { return }
        confirmationResumed = true
        pendingConfirmation = nil
        confirmationTimeoutTask?.cancel()
        confirmationTimeoutTask = nil
        continuation.resume(returning: true)
    }

    func denyConfirmation() {
        guard !confirmationResumed else { return }
        guard let continuation = pendingConfirmation else { return }
        confirmationResumed = true
        pendingConfirmation = nil
        confirmationTimeoutTask?.cancel()
        confirmationTimeoutTask = nil
        continuation.resume(returning: false)
    }

    func cancel() {
        // Resume any pending confirmation so the agent loop can exit
        if !confirmationResumed, let continuation = pendingConfirmation {
            confirmationResumed = true
            pendingConfirmation = nil
            confirmationTimeoutTask?.cancel()
            confirmationTimeoutTask = nil
            continuation.resume(returning: false)
        }

        Task { await agentLoop.cancel() }
        messages.removeAll { $0.isLoading }
        state = .idle
        isRunning = false
        messages.append(ChatMessage(role: .system, content: "Stopped."))
    }

    // MARK: - Sprint 16: Resume Incomplete Run

    /// Resume an incomplete run detected on launch (crash recovery).
    ///
    /// Called by AppDelegate when it finds incomplete runs in the journal.
    /// Routes through the Orchestrator's `resumeRun(runId:)` method.
    ///
    /// - Parameters:
    ///   - runId: The ID of the incomplete run to resume.
    ///   - replyChannel: The reply channel to deliver results through.
    /// - Returns: The run result, or `nil` if the run could not be resumed.
    func resumeIncompleteRun(
        runId: String,
        replyChannel: (any ReplyChannel)?
    ) async -> Orchestrator.RunResult? {
        guard !isRunning else {
            messages.append(ChatMessage(role: .system, content: "Cannot resume run \(runId) — another task is in progress."))
            return nil
        }

        isRunning = true

        let result = await orchestrator.resumeRun(
            runId: runId,
            agentLoop: agentLoop,
            replyChannel: replyChannel,
            onStateChange: { [weak self] newState in
                Task { @MainActor in self?.state = newState }
            },
            onMessage: { [weak self] message in
                Task { @MainActor in
                    self?.messages.removeAll { $0.isLoading }
                    self?.messages.append(message)
                }
            },
            onConfirmationNeeded: { [weak self] action in
                guard let self else { return false }
                return await self.requestConfirmation(for: action)
            }
        )

        // Restore panel after run
        await agentLoop.finishRun()

        messages.removeAll { $0.isLoading }

        // Surface resume run failure to the user
        if let result = result, !result.success {
            let lastIsSystemError = messages.last.map { $0.role == .system && $0.content.hasPrefix("Error") } ?? false
            if !lastIsSystemError {
                messages.append(ChatMessage(role: .system, content: "Run failed: \(result.summary)"))
            }
            if case .error = state {} else { state = .error(result.summary) }
        } else {
            if case .error = state {} else { state = .idle }
        }
        isRunning = false

        if let result = result {
            totalTokensUsed += result.totalInputTokens + result.totalOutputTokens
        }

        return result
    }

    func clearConversation() {
        messages.removeAll()
        Task { await agentLoop.clearHistory() }
        totalTokensUsed = 0
        state = .idle
        isRunning = false
        messages.append(ChatMessage(
            role: .assistant,
            content: "Conversation cleared. What would you like me to do?"
        ))
    }
}
