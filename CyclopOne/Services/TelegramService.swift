import Foundation
import AppKit

// MARK: - TelegramService

/// Native Telegram Bot API integration for Cyclop One.
///
/// Uses URLSession to communicate directly with the Telegram Bot HTTP API
/// (no external dependencies). Long-polls for messages via `getUpdates`,
/// routes commands through CommandGateway, and sends responses back via
/// `sendMessage` / `sendPhoto`.
///
/// Commands:
///   /start     — Register this chat for control
///   /run <task> — Submit a task (or just send plain text)
///   /stop      — Cancel the current run
///   /status    — Get current agent status
///   /screenshot — Capture and send current screen
actor TelegramService {

    // MARK: - Singleton

    static let shared = TelegramService()

    // MARK: - Properties

    /// Bot token from Keychain.
    private var botToken: String?

    /// Authorized chat ID (only this chat can control the agent).
    private var authorizedChatID: Int64?

    /// Pending continuation for approval flow — resumed when callback query arrives.
    private var pendingApprovalContinuation: CheckedContinuation<Bool, Never>?

    /// Whether the polling loop is active.
    private var isPolling = false

    /// Generation counter — incremented each time start() is called.
    /// Poll loops check this to self-terminate when a newer loop exists.
    private var pollGeneration: Int = 0

    /// Offset for getUpdates (tracks last processed update).
    private var updateOffset: Int64 = 0

    /// Reference to the CommandGateway for submitting commands.
    private weak var commandGateway: CommandGateway?

    /// Whether the service has been started.
    private(set) var isStarted = false

    /// Bot username (populated from getMe).
    private(set) var botUsername: String?

    /// URLSession for API calls (long-polling needs longer timeout).
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    private let baseURL = "https://api.telegram.org/bot"

    private static let chatIDKeychainKey = "com.cyclop.one.telegram.chatid"

    private init() {
        // Load saved chat ID from Keychain (secure storage, not UserDefaults)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.chatIDKeychainKey,
            kSecReturnData as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let str = String(data: data, encoding: .utf8),
           let id = Int64(str), id != 0 {
            authorizedChatID = id
        }
    }

    // MARK: - Persistence Helpers

    /// Persist the authorized chat ID to Keychain (not UserDefaults — security sensitive).
    private func persistAuthorizedChatID(_ id: Int64) {
        let data = "\(id)".data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.chatIDKeychainKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        // Delete existing, then add
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("CyclopOne [Telegram]: Failed to persist chat ID to Keychain: %d", status)
        }
    }

    // MARK: - Network Validation

    /// Validate the bot token via getMe and return the bot username.
    /// Extracted to keep start() focused on lifecycle orchestration.
    private func validateAndConnect(token: String) async throws -> String {
        self.botToken = token
        let username = try await getMe()
        return username
    }

    // MARK: - Lifecycle

    /// Start the Telegram bot. Loads token from Keychain, validates via getMe,
    /// then begins long-polling.
    /// Start the Telegram bot.
    /// - Parameters:
    ///   - gateway: CommandGateway for routing commands.
    ///   - token: Bot token. If nil, Telegram is disabled. Caller should load
    ///     token from KeychainService BEFORE calling this (outside the actor)
    ///     to avoid blocking the actor with SecItemCopyMatching.
    func start(gateway: CommandGateway, token: String?) async {
        NSLog("CyclopOne [Telegram]: start() entered, isPolling=%d, hasToken=%@",
              isPolling ? 1 : 0, token != nil ? "yes" : "no")

        // Stop any existing polling loop first
        if isPolling {
            NSLog("CyclopOne [Telegram]: Stopping existing poll loop")
            isPolling = false
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        self.commandGateway = gateway

        guard let token = token, !token.isEmpty else {
            NSLog("CyclopOne [Telegram]: No bot token configured — Telegram disabled.")
            return
        }

        // Validate token via network call
        do {
            let me = try await validateAndConnect(token: token)
            self.botUsername = me
            NSLog("CyclopOne [Telegram]: Connected as @%@", me)
        } catch {
            NSLog("CyclopOne [Telegram]: getMe failed — %@", error.localizedDescription)
            self.botToken = nil
            return
        }

        isStarted = true
        isPolling = true
        pollGeneration += 1
        let gen = pollGeneration

        Task { [weak self] in
            await self?.pollLoop(generation: gen)
        }
    }

    /// Stop polling and clean up.
    func stop() {
        isPolling = false
        isStarted = false
        NSLog("CyclopOne [Telegram]: Stopped")
    }

    // MARK: - Telegram Bot API

    /// Validate a bot token without starting polling. Returns the bot username.
    /// Used by the onboarding wizard to test a token before saving it.
    func validateToken(_ token: String) async throws -> String {
        let url = URL(string: "\(baseURL)\(token)/getMe")!
        let (data, response) = try await session.data(for: URLRequest(url: url))

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
            throw TelegramError.apiError("getMe returned error: \(bodyStr)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true,
              let result = json["result"] as? [String: Any],
              let username = result["username"] as? String else {
            throw TelegramError.invalidResponse("getMe returned no username")
        }

        return username
    }

    /// Validate the bot token and get bot info.
    private func getMe() async throws -> String {
        let data = try await apiCall("getMe")
        guard let result = data["result"] as? [String: Any],
              let username = result["username"] as? String else {
            throw TelegramError.invalidResponse("getMe returned no username")
        }
        return username
    }

    /// Send a text message to a chat.
    func sendMessage(chatID: Int64, text: String, parseMode: String? = nil, replyMarkup: [String: Any]? = nil) async throws {
        var params: [String: Any] = [
            "chat_id": chatID,
            "text": text
        ]
        if let mode = parseMode {
            params["parse_mode"] = mode
        }
        if let markup = replyMarkup {
            params["reply_markup"] = markup
        }
        _ = try await apiCall("sendMessage", params: params)
    }

    /// Send a photo to a chat (multipart upload).
    func sendPhoto(chatID: Int64, imageData: Data, caption: String? = nil) async throws {
        guard let token = botToken else { throw TelegramError.notConfigured }

        let boundary = "CyclopOne-\(UUID().uuidString)"
        let url = URL(string: "\(baseURL)\(token)/sendPhoto")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // chat_id field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(chatID)\r\n".data(using: .utf8)!)

        // caption field
        if let caption = caption {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(caption)\r\n".data(using: .utf8)!)
        }

        // photo file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"screenshot.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let bodyStr = String(data: responseData, encoding: .utf8) ?? "no body"
            throw TelegramError.apiError("sendPhoto failed: \(bodyStr)")
        }
    }

    /// Answer a callback query (inline keyboard button press).
    private func answerCallbackQuery(queryID: String, text: String? = nil) async throws {
        var params: [String: Any] = ["callback_query_id": queryID]
        if let text = text {
            params["text"] = text
        }
        _ = try await apiCall("answerCallbackQuery", params: params)
    }

    /// Generic API call helper.
    private func apiCall(_ method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        guard let token = botToken else { throw TelegramError.notConfigured }

        let url = URL(string: "\(baseURL)\(token)/\(method)")!
        var request = URLRequest(url: url)

        if let params = params {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: params)
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TelegramError.invalidResponse("Not an HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
            throw TelegramError.apiError("\(method) returned \(httpResponse.statusCode): \(bodyStr)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TelegramError.invalidResponse("Cannot parse JSON from \(method)")
        }

        guard json["ok"] as? Bool == true else {
            let desc = json["description"] as? String ?? "unknown error"
            throw TelegramError.apiError("\(method): \(desc)")
        }

        return json
    }

    // MARK: - Long Polling

    /// Main polling loop — calls getUpdates with long-polling (30s timeout).
    /// Each loop is tagged with a generation number; if a newer generation exists, this loop exits.
    private func pollLoop(generation: Int) async {
        NSLog("CyclopOne [Telegram]: Polling loop started (gen %d)", generation)

        while isPolling && pollGeneration == generation {
            do {
                let params: [String: Any] = [
                    "offset": updateOffset,
                    "timeout": 30,
                    "allowed_updates": ["message", "callback_query"]
                ]

                let data = try await apiCall("getUpdates", params: params)

                // Check generation after await — a newer loop may have started
                guard pollGeneration == generation else { break }

                guard let updates = data["result"] as? [[String: Any]] else {
                    continue
                }

                for update in updates {
                    guard let updateID = update["update_id"] as? Int64 else { continue }
                    updateOffset = updateID + 1

                    if let message = update["message"] as? [String: Any] {
                        await handleMessage(message)
                    } else if let callbackQuery = update["callback_query"] as? [String: Any] {
                        await handleCallbackQuery(callbackQuery)
                    }
                }
            } catch {
                // Check generation before backoff
                guard pollGeneration == generation else { break }
                if isPolling {
                    NSLog("CyclopOne [Telegram]: Poll error — %@", error.localizedDescription)
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }

        NSLog("CyclopOne [Telegram]: Polling loop ended (gen %d)", generation)
    }

    // MARK: - Message Handling

    /// Process an incoming Telegram message.
    private func handleMessage(_ message: [String: Any]) async {
        guard let chat = message["chat"] as? [String: Any],
              let chatID = chat["id"] as? Int64,
              let text = message["text"] as? String else {
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // /start always works — it registers the chat
        if trimmed.lowercased() == "/start" {
            authorizedChatID = chatID
            persistAuthorizedChatID(chatID)
            NSLog("CyclopOne [Telegram]: Chat %lld authorized via /start", chatID)
            do {
                try await sendMessage(
                    chatID: chatID,
                    text: "Connected to Cyclop One.\n\nCommands:\n/run <task> — Run a task\n/stop — Cancel current task\n/status — Get current status\n/screenshot — Capture screen\n\nOr just send any message to run it as a task."
                )
            } catch {
                NSLog("CyclopOne [Telegram]: Failed to send welcome — %@", error.localizedDescription)
            }
            return
        }

        // All other commands require authorization
        guard chatID == authorizedChatID else {
            NSLog("CyclopOne [Telegram]: Ignoring message from unauthorized chat %lld", chatID)
            do {
                try await sendMessage(chatID: chatID, text: "Not authorized. Send /start to connect.")
            } catch {}
            return
        }

        // Route commands
        let lower = trimmed.lowercased()

        if lower == "/stop" || lower == "stop" || lower == "x" {
            await handleStop(chatID: chatID)
        } else if lower == "/status" || lower == "status" {
            await handleStatus(chatID: chatID)
        } else if lower == "/screenshot" || lower == "screenshot" {
            await handleScreenshot(chatID: chatID)
        } else if lower.hasPrefix("/run ") {
            let task = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if !task.isEmpty {
                await submitToGateway(text: task, chatID: chatID)
            }
        } else if !trimmed.hasPrefix("/") {
            // Plain text = treat as a task
            await submitToGateway(text: trimmed, chatID: chatID)
        }
    }

    /// Handle a callback query (inline keyboard button press).
    /// Resumes the pending approval continuation if one exists.
    private func handleCallbackQuery(_ query: [String: Any]) async {
        guard let queryID = query["id"] as? String,
              let data = query["data"] as? String else { return }

        let approved = data == "approve"

        // Answer the callback query on Telegram
        do {
            try await answerCallbackQuery(
                queryID: queryID,
                text: approved ? "Approved" : "Denied"
            )
        } catch {}

        // Resume pending approval continuation if present
        if let continuation = pendingApprovalContinuation {
            pendingApprovalContinuation = nil
            continuation.resume(returning: approved)
        }
    }

    // MARK: - Command Handlers

    /// Submit a task to the CommandGateway.
    private func submitToGateway(text: String, chatID: Int64) async {
        guard let gateway = commandGateway else {
            NSLog("CyclopOne [Telegram]: No CommandGateway — dropping message")
            return
        }

        let replyChannel = TelegramReplyChannel(service: self, chatID: chatID)
        let command = Command(
            text: text,
            source: .telegram,
            replyChannel: replyChannel
        )

        NSLog("CyclopOne [Telegram]: Submitting command from chat %lld: %@",
              chatID, String(text.prefix(100)))

        await gateway.submit(command)
    }

    /// Handle /stop command.
    /// M6: Sends immediate "Stopping..." response, then awaits actual stop.
    private func handleStop(chatID: Int64) async {
        guard let gateway = commandGateway else { return }

        // M6: Respond IMMEDIATELY -- don't wait for cancel to complete
        do {
            try await sendMessage(chatID: chatID, text: "Stopping...")
        } catch {}

        // Now trigger the hard cancel
        await gateway.cancelCurrentRun()

        // M6: After cancel completes (or watchdog fires), send confirmation.
        do {
            try await sendMessage(chatID: chatID, text: "Stopped.")
        } catch {}
    }

    /// Handle /status command.
    private func handleStatus(chatID: Int64) async {
        guard let gateway = commandGateway else { return }

        let status = await gateway.getStatus()
        var lines: [String] = []

        if status.isRunning {
            lines.append("Running: \(status.currentCommand ?? "unknown")")
            lines.append("Iterations: \(status.iterationCount)")
            if let dur = status.durationString {
                lines.append("Duration: \(dur)")
            }
            if let action = status.lastAction {
                lines.append("Last action: \(action)")
            }
            if status.queueDepth > 0 {
                lines.append("Queued: \(status.queueDepth)")
            }
        } else {
            lines.append("Idle — ready for commands.")
        }

        do {
            try await sendMessage(chatID: chatID, text: lines.joined(separator: "\n"))
        } catch {}
    }

    /// Handle /screenshot command.
    private func handleScreenshot(chatID: Int64) async {
        do {
            let capture = ScreenCaptureService.shared
            let screenshot = try await capture.captureScreen(maxDimension: 1280, quality: 0.7)
            try await sendPhoto(chatID: chatID, imageData: screenshot.imageData, caption: "Current screen")
        } catch {
            do {
                try await sendMessage(chatID: chatID, text: "Screenshot failed: \(error.localizedDescription)")
            } catch {}
        }
    }

    // MARK: - Approval Support

    /// Send an approval request with inline keyboard buttons and wait for response.
    /// Uses CheckedContinuation instead of busy-polling. Times out after 300 seconds.
    func requestApproval(chatID: Int64, prompt: String) async -> Bool {
        // Cancel any stale pending continuation
        if let stale = pendingApprovalContinuation {
            pendingApprovalContinuation = nil
            stale.resume(returning: false)
        }

        let markup: [String: Any] = [
            "inline_keyboard": [[
                ["text": "Approve", "callback_data": "approve"],
                ["text": "Deny", "callback_data": "deny"]
            ]]
        ]

        do {
            try await sendMessage(
                chatID: chatID,
                text: "Approval needed:\n\(prompt)",
                replyMarkup: markup
            )
        } catch {
            NSLog("CyclopOne [Telegram]: Failed to send approval request — %@", error.localizedDescription)
            return false
        }

        // Wait for callback via continuation, with 300s timeout
        let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.pendingApprovalContinuation = continuation

            // Timeout task: resume with false after 300 seconds if not already resumed
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000_000) // 300s
                guard let self = self else { return }
                if let pending = await self.pendingApprovalContinuation {
                    // Still waiting — timeout
                    await self.clearAndResumeApprovalContinuation(approved: false)
                    NSLog("CyclopOne [Telegram]: Approval timed out for chat %lld", chatID)
                    do {
                        try await self.sendMessage(chatID: chatID, text: "Approval timed out — action denied.")
                    } catch {}
                }
            }
        }

        do {
            try await sendMessage(
                chatID: chatID,
                text: approved ? "Action approved." : "Action denied."
            )
        } catch {}

        return approved
    }

    /// Helper to clear the pending approval continuation and resume it with a value.
    private func clearAndResumeApprovalContinuation(approved: Bool) {
        if let continuation = pendingApprovalContinuation {
            pendingApprovalContinuation = nil
            continuation.resume(returning: approved)
        }
    }
}

// MARK: - TelegramError

enum TelegramError: LocalizedError {
    case notConfigured
    case invalidResponse(String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Telegram bot token not configured."
        case .invalidResponse(let msg):
            return "Invalid Telegram response: \(msg)"
        case .apiError(let msg):
            return "Telegram API error: \(msg)"
        }
    }
}

// MARK: - TelegramReplyChannel

/// ReplyChannel implementation that routes responses back through Telegram.
final class TelegramReplyChannel: ReplyChannel, @unchecked Sendable {

    private let service: TelegramService
    let chatID: Int64

    init(service: TelegramService, chatID: Int64) {
        self.service = service
        self.chatID = chatID
    }

    func sendText(_ text: String) async {
        do {
            try await service.sendMessage(chatID: chatID, text: text)
        } catch {
            NSLog("CyclopOne [TelegramReply]: Failed to send text — %@", error.localizedDescription)
        }
    }

    func sendScreenshot(_ data: Data) async {
        do {
            try await service.sendPhoto(chatID: chatID, imageData: data, caption: "Screenshot")
        } catch {
            NSLog("CyclopOne [TelegramReply]: Failed to send screenshot — %@", error.localizedDescription)
        }
    }

    func requestApproval(_ prompt: String) async -> Bool {
        return await service.requestApproval(chatID: chatID, prompt: prompt)
    }
}
