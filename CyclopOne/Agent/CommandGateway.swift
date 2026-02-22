import Foundation
import AppKit

// MARK: - ReplyChannel Protocol

/// Protocol for sending results back to the command source.
/// Each input surface (local UI, hotkey, OpenClaw) provides
/// its own implementation so responses flow back to the right place.
protocol ReplyChannel: AnyObject, Sendable {
    /// Send a text response back to the command source.
    func sendText(_ text: String) async

    /// Send a screenshot back to the command source.
    func sendScreenshot(_ data: Data) async

    /// Request approval from the user for a potentially destructive action.
    /// Returns `true` if approved, `false` if denied or timed out.
    func requestApproval(_ prompt: String) async -> Bool
}

// MARK: - Command Source

/// Identifies where a command originated.
enum CommandSource: String, Sendable {
    case localUI
    case hotkey
    case openClaw
}

// MARK: - Command

/// A unified command from any input surface.
struct Command: Sendable {
    let text: String
    let source: CommandSource
    let replyChannel: any ReplyChannel
    let timestamp: Date

    init(text: String, source: CommandSource, replyChannel: any ReplyChannel, timestamp: Date = Date()) {
        self.text = text
        self.source = source
        self.replyChannel = replyChannel
        self.timestamp = timestamp
    }
}

// MARK: - CommandGateway

/// Unified command entry point for all input sources.
///
/// The gateway accepts commands from any surface (local UI, hotkey,
/// OpenClaw), queues them if the orchestrator is busy, and routes
/// them through the Orchestrator for supervised execution. Results flow
/// back through the command's ReplyChannel.
actor CommandGateway {

    private let orchestrator: Orchestrator
    private let agentLoop: AgentLoop

    /// Queued commands waiting for the orchestrator to become available.
    private var pendingCommands: [Command] = []

    /// Whether a command is currently being executed.
    private var isBusy: Bool = false

    init(orchestrator: Orchestrator, agentLoop: AgentLoop) {
        self.orchestrator = orchestrator
        self.agentLoop = agentLoop
    }

    /// Submit a command from any input source.
    ///
    /// If the orchestrator is busy, the command is queued and will be
    /// processed when the current run completes. The reply channel
    /// receives a queued notification in that case.
    func submit(_ command: Command) async {
        if isBusy {
            pendingCommands.append(command)
            await command.replyChannel.sendText("Command queued — another task is in progress.")
            return
        }

        await executeCommand(command)

        // Process any queued commands
        await drainQueue()
    }

    /// Execute a single command through the orchestrator.
    private func executeCommand(_ command: Command) async {
        isBusy = true

        let result = await orchestrator.startRun(
            command: command.text,
            source: command.source.rawValue,
            agentLoop: agentLoop,
            replyChannel: command.replyChannel,
            onStateChange: { _ in },
            onMessage: { message in
                Task {
                    await command.replyChannel.sendText(message.content)
                }
            },
            onConfirmationNeeded: { prompt in
                await command.replyChannel.requestApproval(prompt)
            },
            onProgress: { iteration, action in
                // Send progress updates every 3 iterations to avoid flooding
                if iteration % 3 == 0 || iteration == 1 {
                    let update = "Iteration \(iteration): \(action)"
                    Task {
                        await command.replyChannel.sendText(update)
                    }
                }
            }
        )

        // Ensure panel is restored after the run
        await agentLoop.finishRun()

        isBusy = false

        // Send the run result through the reply channel
        let statusLabel = result.success ? "Complete" : "Failed"
        let formattedResult = "Task \(statusLabel) — \(result.iterations) iterations, \(result.summary)"
        await command.replyChannel.sendText(formattedResult)

        // Send final screenshot if available
        if let screenshotData = await captureFinaleScreenshot() {
            await command.replyChannel.sendScreenshot(screenshotData)
        }
    }

    /// Capture a final screenshot to send alongside the run result.
    private func captureFinaleScreenshot() async -> Data? {
        let capture = ScreenCaptureService.shared
        do {
            let screenshot = try await capture.captureScreen(maxDimension: 1280, quality: 0.7)
            return screenshot.imageData
        } catch {
            return nil
        }
    }

    /// Process queued commands one at a time.
    private func drainQueue() async {
        while !pendingCommands.isEmpty {
            let next = pendingCommands.removeFirst()
            await executeCommand(next)
        }
    }

    /// Whether the gateway is currently processing a command.
    var busy: Bool { isBusy }

    /// Number of commands waiting in the queue.
    var queueDepth: Int { pendingCommands.count }

    // MARK: - Status & Cancel (Sprint 11)

    /// Returns a snapshot of the current gateway and orchestrator state.
    func getStatus() async -> GatewayStatus {
        let orchStatus = await orchestrator.getStatus()
        return GatewayStatus(
            isRunning: isBusy,
            currentCommand: orchStatus.currentCommand,
            iterationCount: orchStatus.iterationCount,
            startTime: orchStatus.startTime,
            lastAction: orchStatus.lastAction,
            queueDepth: pendingCommands.count,
            runId: orchStatus.runId
        )
    }

    /// Cancel the currently running command by requesting cooperative cancellation
    /// on both the Orchestrator and the AgentLoop.
    func cancelCurrentRun() async {
        guard isBusy else { return }
        await orchestrator.cancel()
        await agentLoop.cancel()
    }
}

// MARK: - GatewayStatus

/// Snapshot of the gateway + orchestrator state, used by /status command.
struct GatewayStatus: Sendable {
    let isRunning: Bool
    let currentCommand: String?
    let iterationCount: Int
    let startTime: Date?
    let lastAction: String?
    let queueDepth: Int
    let runId: String?

    /// Formatted duration string (e.g. "1m 23s") or nil if not running.
    var durationString: String? {
        guard let start = startTime else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

// MARK: - LocalReplyChannel

/// ReplyChannel implementation for the local dot UI.
///
/// Bridges command results back into the AgentCoordinator's published
/// state so the SwiftUI views update. Uses @MainActor since it
/// updates UI-bound properties on AgentCoordinator.
///
/// When the local UI path routes through `AgentCoordinator.handleUserMessage`,
/// the existing `onConfirmationNeeded` callback handles approval. This
/// channel's `requestApproval` is used when commands arrive via the
/// gateway from external surfaces that still want to show a local dialog.
/// ReplyChannel implementation for the local dot UI with proper @MainActor isolation.
///
/// All methods dispatch to MainActor explicitly. The class itself is Sendable
/// because it only holds a weak reference to the @MainActor-isolated coordinator,
/// and all property access is gated through MainActor.run.
@MainActor
final class LocalReplyChannel: ReplyChannel, Sendable {

    private weak var coordinator: AgentCoordinator?

    init(coordinator: AgentCoordinator) {
        self.coordinator = coordinator
    }

    nonisolated func sendText(_ text: String) async {
        await MainActor.run { [weak self] in
            guard let self, let coordinator = self.coordinator else { return }
            coordinator.messages.removeAll { $0.isLoading }
            coordinator.messages.append(ChatMessage(role: .assistant, content: text))
        }
    }

    nonisolated func sendScreenshot(_ data: Data) async {
        await MainActor.run { [weak self] in
            guard let self, let coordinator = self.coordinator else { return }
            coordinator.messages.append(
                ChatMessage(role: .system, content: "[Screenshot captured (\(data.count) bytes)]")
            )
        }
    }

    nonisolated func requestApproval(_ prompt: String) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Cyclop One: Action Approval"
            alert.informativeText = prompt
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Approve")
            alert.addButton(withTitle: "Deny")
            let response = alert.runModal()
            return response == .alertFirstButtonReturn
        }
    }
}
