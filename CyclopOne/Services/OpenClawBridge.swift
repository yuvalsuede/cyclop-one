import Foundation
import AppKit

// MARK: - OpenClawBridge

/// Bridge between Cyclop One and the OpenClaw messaging platform.
///
/// OpenClaw is a Node.js gateway that connects to Telegram, WhatsApp,
/// Discord, Slack, Signal, iMessage, and other messaging platforms.
/// This actor wraps the `openclaw` CLI to send messages, read incoming
/// commands, and manage channel configuration.
///
/// Commands from OpenClaw are submitted to the CommandGateway with
/// source `.openClaw` and a dedicated `OpenClawReplyChannel`.
///
/// Architecture:
/// ```
///   Telegram / WhatsApp / Discord ...
///          |
///     OpenClaw Gateway (Node.js)
///          |  CLI calls
///     OpenClawBridge (Swift actor)
///          |
///     CommandGateway.submit()
/// ```
actor OpenClawBridge {

    // MARK: - Singleton

    static let shared = OpenClawBridge()

    // MARK: - Configuration

    struct Config: Sendable {
        /// Path to the openclaw CLI binary.
        /// Resolved dynamically at startup via `which openclaw`.
        var cliPath: String = "/usr/local/bin/openclaw"

        /// Poll interval for checking new messages (seconds).
        var pollInterval: TimeInterval = 5.0

        /// Maximum message age to process (seconds). Ignore messages older than this.
        var maxMessageAge: TimeInterval = 300 // 5 minutes

        /// Channels to listen on. Each entry is (channel, target).
        /// Example: [("telegram", "@mybot"), ("whatsapp", "+15555550123")]
        var listeners: [(channel: String, target: String)] = []
    }

    // MARK: - Properties

    private var config = Config()

    /// Whether the polling loop is active.
    private var isPolling = false

    /// Generation counter — incremented each time start() is called.
    /// Poll loops check this to self-terminate when a newer loop exists.
    private var pollGeneration: Int = 0

    /// The last message ID seen per (channel, target) pair, to avoid re-processing.
    private var lastSeenMessageIds: [String: String] = [:]

    /// Reference to the CommandGateway for submitting incoming commands.
    /// Stored as AnyObject to avoid tight coupling; cast to CommandGateway when used.
    private weak var commandGateway: CommandGateway?

    /// Whether the bridge has been started.
    private(set) var isStarted = false

    private init() {}

    // MARK: - Lifecycle

    /// Configure the bridge and start listening for messages.
    ///
    /// - Parameters:
    ///   - gateway: The CommandGateway to submit incoming commands to.
    ///   - config: Optional bridge configuration. Uses defaults if nil.
    func start(gateway: CommandGateway, config: Config? = nil) async {
        if let config = config {
            self.config = config
        }
        self.commandGateway = gateway
        self.isStarted = true

        // Try to resolve CLI path dynamically
        await resolveCLIPath()

        NSLog("OpenClawBridge: Started with %d listeners, CLI at %@",
              self.config.listeners.count, self.config.cliPath)

        if !self.config.listeners.isEmpty {
            isPolling = true
            pollGeneration += 1
            let gen = pollGeneration
            Task { [weak self] in
                await self?.pollLoop(generation: gen)
            }
        } else {
            NSLog("OpenClawBridge: No listeners configured — polling disabled. " +
                  "Configure channels with `openclaw channels add`.")
        }
    }

    /// Stop the polling loop and clean up.
    func stop() {
        isPolling = false
        isStarted = false
        commandGateway = nil
        NSLog("CyclopOne [OpenClawBridge]: Stopped")
    }

    // MARK: - Send Message

    /// Send a text message through OpenClaw to a messaging platform.
    ///
    /// - Parameters:
    ///   - channel: Platform name (telegram, whatsapp, discord, slack, signal, imessage).
    ///   - target: Recipient identifier (chat ID, phone number, channel ID, etc.).
    ///   - message: The message text to send.
    ///   - media: Optional local file path or URL for media attachment.
    /// - Returns: The CLI output for logging/debugging.
    /// - Throws: `OpenClawError` on failure.
    @discardableResult
    func sendMessage(
        channel: String,
        target: String,
        message: String,
        media: String? = nil
    ) async throws -> String {
        var args = [
            "message", "send",
            "--channel", channel,
            "--target", target,
            "--message", message,
            "--json"
        ]

        if let media = media {
            args.append(contentsOf: ["--media", media])
        }

        let result = try await runCLI(args)
        if !result.isSuccess {
            NSLog("OpenClawBridge: Send failed to %@:%@ — %@", channel, target, result.stderr)
            throw OpenClawError.sendFailed(result.stderr)
        }

        NSLog("OpenClawBridge: Sent message to %@:%@", channel, target)
        return result.stdout
    }

    // MARK: - Read Messages

    /// Read recent messages from a channel.
    ///
    /// - Parameters:
    ///   - channel: Platform name.
    ///   - target: Chat/channel identifier.
    ///   - limit: Maximum messages to retrieve.
    ///   - afterId: Only return messages after this ID.
    /// - Returns: Array of parsed messages.
    /// - Throws: `OpenClawError` on failure.
    func readMessages(
        channel: String,
        target: String,
        limit: Int = 10,
        afterId: String? = nil
    ) async throws -> [OpenClawMessage] {
        var args = [
            "message", "read",
            "--channel", channel,
            "--target", target,
            "--limit", String(limit),
            "--json"
        ]

        if let afterId = afterId {
            args.append(contentsOf: ["--after", afterId])
        }

        let result = try await runCLI(args)
        guard result.isSuccess else {
            throw OpenClawError.readFailed(result.stderr)
        }

        return parseMessages(result.stdout)
    }

    // MARK: - Polling Loop

    /// Main polling loop that checks for new messages on all configured listeners.
    /// Each loop is tagged with a generation number; if a newer generation exists, this loop exits.
    private func pollLoop(generation: Int) async {
        NSLog("CyclopOne [OpenClawBridge]: Polling loop started (gen %d) for %d listeners", generation, config.listeners.count)

        while isPolling && pollGeneration == generation {
            for (channel, target) in config.listeners {
                do {
                    let key = "\(channel):\(target)"
                    let messages = try await readMessages(
                        channel: channel,
                        target: target,
                        limit: 5,
                        afterId: lastSeenMessageIds[key]
                    )

                    for msg in messages {
                        lastSeenMessageIds[key] = msg.id

                        // Skip bot's own messages
                        if msg.isFromBot { continue }

                        // Skip stale messages
                        if let timestamp = msg.timestamp,
                           Date().timeIntervalSince(timestamp) > config.maxMessageAge {
                            continue
                        }

                        // Submit to CommandGateway
                        await submitCommand(from: msg, channel: channel, target: target)
                    }
                } catch {
                    NSLog("OpenClawBridge: Poll error for %@:%@ — %@",
                          channel, target, error.localizedDescription)
                }
            }

            // Check generation after sleep — a newer loop may have started
            try? await Task.sleep(nanoseconds: UInt64(config.pollInterval * 1_000_000_000))
            guard pollGeneration == generation else { break }
        }

        NSLog("CyclopOne [OpenClawBridge]: Polling loop ended (gen %d)", generation)
    }

    /// Submit an incoming OpenClaw message as a Command to the gateway.
    private func submitCommand(
        from message: OpenClawMessage,
        channel: String,
        target: String
    ) async {
        guard let gateway = commandGateway else {
            NSLog("OpenClawBridge: No CommandGateway set, dropping message from %@:%@", channel, target)
            return
        }

        let replyChannel = OpenClawReplyChannel(
            bridge: self,
            channel: channel,
            target: target
        )

        let command = Command(
            text: message.text,
            source: .openClaw,
            replyChannel: replyChannel
        )

        NSLog("OpenClawBridge: Submitting command from %@:%@ — %@",
              channel, target, String(message.text.prefix(100)))

        await gateway.submit(command)
    }

    // MARK: - CLI Execution

    /// Run the openclaw CLI with the given arguments.
    ///
    /// Uses `withCheckedThrowingContinuation` to bridge the Process callback
    /// into Swift concurrency. Inherits environment for Node.js path resolution.
    private func runCLI(_ arguments: [String], timeout: TimeInterval = 30) async throws -> CLIResult {
        let cliPath = config.cliPath

        guard fm.fileExists(atPath: cliPath) else {
            throw OpenClawError.notConfigured
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments

        // Inherit environment with nvm paths
        var env = ProcessInfo.processInfo.environment
        let nvmBin = URL(fileURLWithPath: cliPath).deletingLastPathComponent().path
        if let path = env["PATH"] {
            env["PATH"] = "\(nvmBin):\(path)"
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: OpenClawError.launchFailed(error.localizedDescription))
                return
            }

            // Timeout guard
            let timeoutItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                    NSLog("OpenClawBridge: CLI timed out after %.0fs", timeout)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            process.terminationHandler = { _ in
                timeoutItem.cancel()
                let stdout = String(
                    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let stderr = String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                continuation.resume(returning: CLIResult(
                    stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                    exitCode: process.terminationStatus
                ))
            }
        }
    }

    /// FileManager instance for file existence checks.
    private let fm = FileManager.default

    /// Attempt to resolve the openclaw CLI path dynamically via `which`.
    /// Uses async continuation with terminationHandler instead of synchronous waitUntilExit().
    private func resolveCLIPath() async {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["which", "openclaw"]

            var env = ProcessInfo.processInfo.environment
            // Ensure nvm paths are on PATH for resolution
            let nvmBin = URL(fileURLWithPath: config.cliPath).deletingLastPathComponent().path
            if let path = env["PATH"] {
                env["PATH"] = "\(nvmBin):\(path)"
            }
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            let resolved: String? = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    if proc.terminationStatus == 0 {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let path = String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(returning: (path?.isEmpty == false) ? path : nil)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            if let resolved = resolved {
                config.cliPath = resolved
                NSLog("CyclopOne [OpenClawBridge]: Resolved CLI path to %@", resolved)
            }
        } catch {
            NSLog("CyclopOne [OpenClawBridge]: Could not resolve CLI path dynamically, using default: %@",
                  config.cliPath)
        }
    }

    // MARK: - Message Parsing

    /// Parse JSON output from `openclaw message read --json` into message structs.
    private func parseMessages(_ json: String) -> [OpenClawMessage] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let text = dict["text"] as? String ?? dict["body"] as? String else {
                return nil
            }

            let isFromBot = dict["fromBot"] as? Bool ?? dict["isBot"] as? Bool ?? false

            var timestamp: Date?
            if let ts = dict["timestamp"] as? TimeInterval {
                timestamp = Date(timeIntervalSince1970: ts)
            } else if let ts = dict["timestamp"] as? String {
                timestamp = ISO8601DateFormatter().date(from: ts)
            }

            return OpenClawMessage(
                id: id,
                text: text,
                sender: dict["sender"] as? String ?? dict["from"] as? String,
                isFromBot: isFromBot,
                timestamp: timestamp,
                channel: dict["channel"] as? String,
                mediaURL: dict["media"] as? String ?? dict["mediaUrl"] as? String
            )
        }
    }

    // MARK: - Types

    struct CLIResult: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        var isSuccess: Bool { exitCode == 0 }
    }
}

// MARK: - OpenClawMessage

/// A message received from or sent through OpenClaw.
struct OpenClawMessage: Sendable {
    let id: String
    let text: String
    let sender: String?
    let isFromBot: Bool
    let timestamp: Date?
    let channel: String?
    let mediaURL: String?
}

// MARK: - OpenClawError

/// Errors from OpenClaw CLI operations.
enum OpenClawError: LocalizedError {
    case launchFailed(String)
    case readFailed(String)
    case sendFailed(String)
    case notConfigured
    case timeout

    var errorDescription: String? {
        switch self {
        case .launchFailed(let msg):
            return "OpenClaw launch failed: \(msg)"
        case .readFailed(let msg):
            return "OpenClaw read failed: \(msg)"
        case .sendFailed(let msg):
            return "OpenClaw send failed: \(msg)"
        case .notConfigured:
            return "OpenClaw CLI not found. Ensure openclaw is installed and the path is correct."
        case .timeout:
            return "OpenClaw CLI command timed out."
        }
    }
}

// MARK: - OpenClawReplyChannel

/// ReplyChannel implementation that sends responses back through OpenClaw.
///
/// When a command arrives via OpenClaw (e.g., from Telegram), this channel
/// routes responses back to the same platform and chat. Conforms to the
/// `ReplyChannel` protocol defined in `CommandGateway.swift`.
final class OpenClawReplyChannel: ReplyChannel, @unchecked Sendable {

    private let bridge: OpenClawBridge
    private let channel: String
    private let target: String

    init(bridge: OpenClawBridge, channel: String, target: String) {
        self.bridge = bridge
        self.channel = channel
        self.target = target
    }

    func sendText(_ text: String) async {
        do {
            try await bridge.sendMessage(
                channel: channel,
                target: target,
                message: text
            )
        } catch {
            NSLog("OpenClawReplyChannel: Failed to send text to %@:%@ — %@",
                  channel, target, error.localizedDescription)
        }
    }

    func sendScreenshot(_ data: Data) async {
        let tempPath = NSTemporaryDirectory() + "cyclopone_screenshot_\(UUID().uuidString).jpg"
        let tempURL = URL(fileURLWithPath: tempPath)
        do {
            try data.write(to: tempURL)
            try await bridge.sendMessage(
                channel: channel,
                target: target,
                message: "Screenshot",
                media: tempPath
            )
            try? FileManager.default.removeItem(at: tempURL)
        } catch {
            NSLog("OpenClawReplyChannel: Failed to send screenshot to %@:%@ — %@",
                  channel, target, error.localizedDescription)
        }
    }

    func requestApproval(_ prompt: String) async -> Bool {
        // Send the approval request
        do {
            try await bridge.sendMessage(
                channel: channel,
                target: target,
                message: "Approval needed: \(prompt)\n\nReply 'yes' to approve or 'no' to deny."
            )
        } catch {
            NSLog("OpenClawReplyChannel: Failed to send approval request — %@",
                  error.localizedDescription)
            return false
        }

        // Poll for response (up to 5 minutes at 5-second intervals)
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            do {
                let messages = try await bridge.readMessages(
                    channel: channel,
                    target: target,
                    limit: 3
                )
                for msg in messages {
                    if msg.isFromBot { continue }
                    let lower = msg.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if lower == "yes" || lower == "approve" || lower == "y" {
                        return true
                    }
                    if lower == "no" || lower == "deny" || lower == "n" {
                        return false
                    }
                }
            } catch {
                continue
            }
        }

        NSLog("OpenClawReplyChannel: Approval timed out for %@:%@", channel, target)
        return false // Timeout defaults to deny
    }
}
