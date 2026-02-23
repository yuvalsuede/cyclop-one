import Foundation

/// Sends real-time progress to Telegram during agent execution.
///
/// Rate-limits photo sending to avoid flooding the chat.
/// Text messages are sent immediately (Telegram handles text well).
///
/// Uses actor isolation for thread-safe mutable state instead of NSLock.
/// Implements exponential backoff on HTTP 429 (rate-limit) errors.
actor TelegramAgentObserver: AgentObserver {

    private let service: TelegramService
    private let chatID: Int64

    /// Timestamp of the last photo sent. Used for rate limiting.
    /// Photos are sent at most once every `photoIntervalSeconds`.
    private var lastPhotoSentTime: Date = .distantPast
    private let photoIntervalSeconds: TimeInterval = 3.0

    /// Latest screenshot data, sent only on completion or error.
    private var latestScreenshot: Data?

    /// Exponential backoff state for 429 rate-limit errors.
    private var backoffDelay: TimeInterval = 1.0
    private let maxBackoffDelay: TimeInterval = 60.0
    private var backoffUntil: Date = .distantPast

    /// Tools that are internal bookkeeping -- no need to notify the user.
    private static let silentTools: Set<String> = [
        "take_screenshot", "read_screen",
        "remember", "recall",
        "vault_read", "vault_write", "vault_search", "vault_list", "vault_append",
        "task_create", "task_update", "task_list", "task_complete"
    ]

    init(service: TelegramService, chatID: Int64) {
        self.service = service
        self.chatID = chatID
    }

    // MARK: - AgentObserver

    nonisolated func onStepStart(stepIndex: Int, totalSteps: Int, title: String) async {
        let msg = "Step \(stepIndex + 1)/\(totalSteps): \(title)..."
        await sendMessageWithBackoff(msg)
    }

    nonisolated func onToolExecution(toolName: String, summary: String, isError: Bool) async {
        // Only send tool updates for "interesting" tools.
        guard !Self.silentTools.contains(toolName) else { return }

        let prefix = isError ? "Error: " : ""
        let marker = isError ? "x" : ">"
        let msg = "\(marker) \(prefix)\(summary)"
        await sendMessageWithBackoff(msg)
    }

    nonisolated func onScreenshot(imageData: Data, context: String) async {
        // Don't send mid-run screenshots automatically -- too noisy.
        // Users can request screenshots explicitly via /screenshot.
        // We still store the latest screenshot data for onCompletion.
        await storeScreenshot(imageData)
    }

    nonisolated func onStepComplete(stepIndex: Int, totalSteps: Int, title: String,
                        outcome: String, screenshot: Data?) async {
        let msg = "Step \(stepIndex + 1)/\(totalSteps) complete: \(title)\n\(outcome)"
        await sendMessageWithBackoff(msg)

        // Store screenshot for potential use at completion, don't send mid-run
        if let ssData = screenshot {
            await storeScreenshot(ssData)
        }
    }

    nonisolated func onError(error: String, screenshot: Data?, isFatal: Bool) async {
        let severity = isFatal ? "FATAL" : "ERROR"
        let msg = "[\(severity)] \(error)"
        await sendMessageWithBackoff(msg)

        // Always try to send error screenshots (bypass rate limit for errors)
        if let ssData = screenshot {
            do {
                try await service.sendPhoto(
                    chatID: chatID, imageData: ssData,
                    caption: "Error state"
                )
                await recordPhotoSent()
            } catch {
                await handleSendError(error, context: "error screenshot")
            }
        }
    }

    nonisolated func onCompletion(success: Bool, summary: String, score: Int?, iterations: Int) async {
        var msg = success ? "Done" : "Failed"
        msg += " — \(summary)"
        if let s = score { msg += " (score: \(s)/100)" }
        msg += "\n\(iterations) iterations"

        // Send final screenshot if we have one
        let finalScreenshot = await consumeLatestScreenshot()

        if let ssData = finalScreenshot {
            let caption = success ? "Final result" : "Final state (failed)"
            do {
                try await service.sendPhoto(chatID: chatID, imageData: ssData, caption: caption)
            } catch {
                await handleSendError(error, context: "completion screenshot")
            }
        }

        await sendMessageWithBackoff(msg)
    }

    // MARK: - Actor-isolated State Helpers

    private func storeScreenshot(_ data: Data) {
        latestScreenshot = data
    }

    private func consumeLatestScreenshot() -> Data? {
        let data = latestScreenshot
        latestScreenshot = nil
        return data
    }

    // MARK: - Rate Limiting

    private func canSendPhoto() -> Bool {
        return Date().timeIntervalSince(lastPhotoSentTime) >= photoIntervalSeconds
    }

    private func recordPhotoSent() {
        lastPhotoSentTime = Date()
    }

    // MARK: - Backoff & Error Handling

    /// Send a text message with exponential backoff on rate-limit (429) errors.
    private func sendMessageWithBackoff(_ text: String) async {
        // Respect backoff window
        let now = Date()
        if now < backoffUntil {
            let waitTime = backoffUntil.timeIntervalSince(now)
            NSLog("CyclopOne [TelegramObserver]: Rate-limited, waiting %.1fs before sending", waitTime)
            do {
                try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            } catch {
                NSLog("CyclopOne [TelegramObserver]: Backoff sleep interrupted: %@", error.localizedDescription)
                return
            }
        }

        do {
            try await service.sendMessage(chatID: chatID, text: text)
            // Reset backoff on success
            backoffDelay = 1.0
        } catch {
            handleSendError(error, context: "message")
        }
    }

    /// Handle a Telegram send error, applying exponential backoff on 429 rate-limit responses.
    private func handleSendError(_ error: Error, context: String) {
        let description = error.localizedDescription

        if description.contains("returned 429") {
            // Rate limited -- apply exponential backoff
            backoffUntil = Date().addingTimeInterval(backoffDelay)
            NSLog("CyclopOne [TelegramObserver]: Rate-limited (429) sending %@. Backing off %.1fs",
                  context, backoffDelay)
            backoffDelay = min(backoffDelay * 2, maxBackoffDelay)
        } else {
            NSLog("CyclopOne [TelegramObserver]: Failed to send %@ — %@",
                  context, description)
        }
    }
}
