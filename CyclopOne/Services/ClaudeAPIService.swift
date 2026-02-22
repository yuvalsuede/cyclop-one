import Foundation

// MARK: - TLS Certificate Pinning
//
// TODO: Implement SPKI certificate pinning for Anthropic's API.
// The previous implementation had an empty pin set which provided no security
// benefit while adding complexity. When real SPKI hashes are available, create
// a URLSessionDelegate that validates the server certificate chain against them.
//
// To obtain SPKI hashes:
//   openssl s_client -connect api.anthropic.com:443 -servername api.anthropic.com 2>/dev/null \
//     | openssl x509 -pubkey -noout \
//     | openssl pkey -pubin -outform DER \
//     | openssl dgst -sha256 -binary | base64
//
// Include at least the leaf and one intermediate CA pin for rotation resilience.
// Until then, standard CA validation (the URLSession default) is used.

/// Communicates with the Claude Messages API, sending screenshots + context
/// and receiving text responses and tool-use calls.
actor ClaudeAPIService {

    static let shared = ClaudeAPIService()

    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let apiVersion = "2023-06-01"

    /// URLSession for communication with Anthropic.
    /// Uses standard CA validation. TODO: Add SPKI pinning when real hashes are available.
    private let pinnedSession: URLSession

    // MARK: - Payload Size Tracking (Sprint 19)

    /// Size of the last request payload in bytes.
    private(set) var lastRequestPayloadBytes: Int = 0

    /// Size of the last response payload in bytes.
    private(set) var lastResponsePayloadBytes: Int = 0

    /// Cumulative request payload bytes for the current session.
    private(set) var totalRequestPayloadBytes: Int64 = 0

    /// Cumulative response payload bytes for the current session.
    private(set) var totalResponsePayloadBytes: Int64 = 0

    /// Number of API calls made in this session.
    private(set) var apiCallCount: Int = 0

    /// Sprint 19: Warning threshold for request payload size (10MB).
    /// Payloads above this size indicate conversation pruning may not be working.
    private let payloadWarningThreshold: Int = 10 * 1024 * 1024

    private init() {
        // Standard CA validation — no custom delegate needed until real SPKI hashes are configured.
        let config = URLSessionConfiguration.default
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        self.pinnedSession = URLSession(configuration: config)
    }

    /// Sprint 19: Reset payload tracking counters. Call at the start of a new run.
    func resetPayloadTracking() {
        lastRequestPayloadBytes = 0
        lastResponsePayloadBytes = 0
        totalRequestPayloadBytes = 0
        totalResponsePayloadBytes = 0
        apiCallCount = 0
    }

    /// Sprint 19: Get a summary of payload statistics for diagnostics.
    func payloadSummary() -> String {
        let avgReq = apiCallCount > 0 ? Int(totalRequestPayloadBytes) / apiCallCount : 0
        return "API calls: \(apiCallCount), Total sent: \(formatBytes(totalRequestPayloadBytes)), Total received: \(formatBytes(totalResponsePayloadBytes)), Avg request: \(formatBytes(Int64(avgReq)))"
    }

    /// Format bytes to human-readable string.
    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024)KB" }
        return String(format: "%.1fMB", Double(bytes) / 1_048_576.0)
    }

    // MARK: - Send Message (single-shot)

    /// Send a conversation to Claude and get a response.
    ///
    /// This is a single-shot call with NO built-in retry logic.
    /// Retry responsibility lies with the caller (AgentLoop.sendAPIWithRetry)
    /// to avoid retry amplification (previously 3 * 3 * 3 = 27 calls per failure).
    func sendMessage(
        messages: [[String: Any]],
        systemPrompt: String,
        tools: [[String: Any]],
        model: String = "claude-sonnet-4-6",
        maxTokens: Int = 8192
    ) async throws -> ClaudeResponse {
        return try await sendMessageOnce(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            model: model,
            maxTokens: maxTokens
        )
    }

    // MARK: - Single Request

    private func sendMessageOnce(
        messages: [[String: Any]],
        systemPrompt: String,
        tools: [[String: Any]],
        model: String,
        maxTokens: Int
    ) async throws -> ClaudeResponse {
        guard let apiKey = KeychainService.shared.getAPIKey() else {
            throw APIError.noAPIKey
        }

        // Build request body
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": messages,
        ]

        if !tools.isEmpty {
            body["tools"] = tools
        }

        // Serialize
        let jsonData = try JSONSerialization.data(withJSONObject: body)

        // Sprint 19: Track request payload size
        let requestSize = jsonData.count
        lastRequestPayloadBytes = requestSize
        totalRequestPayloadBytes += Int64(requestSize)
        apiCallCount += 1

        if requestSize > payloadWarningThreshold {
            print("[ClaudeAPI] Warning: request payload is \(formatBytes(Int64(requestSize))) — conversation pruning may need attention")
        }

        // Build request
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        // Execute using standard CA-validated session
        let (data, response) = try await pinnedSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // Sprint 19: Track response payload size
        lastResponsePayloadBytes = data.count
        totalResponsePayloadBytes += Int64(data.count)

        guard httpResponse.statusCode == 200 else {
            var body = String(data: data, encoding: .utf8) ?? "Unknown error"
            // Capture Retry-After header for 429 responses so the retry layer can parse it
            if httpResponse.statusCode == 429,
               let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After") {
                body += "\n\"retry-after\": \(retryAfter)"
            }
            throw APIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        // Parse response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.parseError("Failed to parse response JSON")
        }

        return try parseResponse(json)
    }

    // MARK: - One-Shot Vision Verification

    /// Make a one-shot vision API call for verification scoring.
    /// Uses claude-haiku-4-5 for cost efficiency. Stateless — does not maintain conversation history.
    ///
    /// - Parameters:
    ///   - prompt: The verification prompt to send alongside the screenshot.
    ///   - screenshot: Raw image data (PNG or JPEG).
    ///   - mediaType: MIME type of the image (default "image/png").
    /// - Returns: The text content of Claude's response.
    func verifyWithVision(
        prompt: String,
        screenshot: Data,
        mediaType: String = "image/png"
    ) async throws -> String {
        guard let apiKey = KeychainService.shared.getAPIKey() else {
            throw APIError.noAPIKey
        }

        let base64Image = screenshot.base64EncodedString()

        let messages: [[String: Any]] = [
            [
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": mediaType,
                            "data": base64Image
                        ] as [String: Any]
                    ] as [String: Any],
                    [
                        "type": "text",
                        "text": prompt
                    ] as [String: Any]
                ] as [[String: Any]]
            ] as [String: Any]
        ]

        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 200,
            "messages": messages
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        // Track payload
        lastRequestPayloadBytes = jsonData.count
        totalRequestPayloadBytes += Int64(jsonData.count)
        apiCallCount += 1

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30  // Short timeout for verification

        let (data, response) = try await pinnedSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        lastResponsePayloadBytes = data.count
        totalResponsePayloadBytes += Int64(data.count)

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]] else {
            throw APIError.parseError("Failed to parse verification response")
        }

        // Extract text from the first text block
        for item in contentArray {
            if let type = item["type"] as? String, type == "text",
               let text = item["text"] as? String {
                return text
            }
        }

        throw APIError.parseError("No text content in verification response")
    }

    // MARK: - Build Messages

    /// Create a user message with text + screenshot + UI tree.
    static func buildUserMessage(text: String, screenshot: ScreenCapture?, uiTreeSummary: String?) -> [String: Any] {
        var content: [[String: Any]] = []

        // Add screenshot if available
        if let screenshot = screenshot {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": screenshot.mediaType,
                    "data": screenshot.base64
                ]
            ])
        }

        // Add UI tree context
        if let uiTree = uiTreeSummary {
            content.append([
                "type": "text",
                "text": "<ui_tree>\n\(uiTree)\n</ui_tree>"
            ])
        }

        // Add user text
        content.append([
            "type": "text",
            "text": text
        ])

        return [
            "role": "user",
            "content": content
        ]
    }

    /// Create an assistant message from Claude's response.
    static func buildAssistantMessage(from response: ClaudeResponse) -> [String: Any] {
        var content: [[String: Any]] = []

        for block in response.contentBlocks {
            switch block {
            case .text(let text):
                content.append(["type": "text", "text": text])
            case .toolUse(let id, let name, let input):
                content.append([
                    "type": "tool_use",
                    "id": id,
                    "name": name,
                    "input": input
                ])
            }
        }

        return ["role": "assistant", "content": content]
    }

    /// Create a tool result message, optionally including a screenshot image.
    static func buildToolResultMessage(toolUseId: String, result: String, isError: Bool = false, screenshot: ScreenCapture? = nil) -> [String: Any] {
        // If there's a screenshot, send it as a rich content block so Claude can SEE the result
        if let ss = screenshot {
            let contentBlocks: [[String: Any]] = [
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": ss.mediaType,
                        "data": ss.base64
                    ] as [String: Any]
                ],
                [
                    "type": "text",
                    "text": result
                ]
            ]

            return [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": contentBlocks,
                        "is_error": isError
                    ] as [String: Any]
                ]
            ]
        }

        // No screenshot — simple text result
        return [
            "role": "user",
            "content": [
                [
                    "type": "tool_result",
                    "tool_use_id": toolUseId,
                    "content": result,
                    "is_error": isError
                ] as [String: Any]
            ]
        ]
    }

    // MARK: - Parse Response

    private func parseResponse(_ json: [String: Any]) throws -> ClaudeResponse {
        guard let contentArray = json["content"] as? [[String: Any]] else {
            throw APIError.parseError("Missing 'content' in response")
        }

        let stopReason = json["stop_reason"] as? String ?? "unknown"

        var blocks: [ResponseBlock] = []

        for item in contentArray {
            guard let type = item["type"] as? String else { continue }

            switch type {
            case "text":
                if let text = item["text"] as? String {
                    blocks.append(.text(text))
                }
            case "tool_use":
                if let id = item["id"] as? String,
                   let name = item["name"] as? String,
                   let input = item["input"] as? [String: Any] {
                    blocks.append(.toolUse(id: id, name: name, input: input))
                }
            default:
                break
            }
        }

        // Parse usage
        let usage = json["usage"] as? [String: Any]
        let inputTokens = usage?["input_tokens"] as? Int ?? 0
        let outputTokens = usage?["output_tokens"] as? Int ?? 0

        return ClaudeResponse(
            contentBlocks: blocks,
            stopReason: stopReason,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }
}

// MARK: - Response Models

struct ClaudeResponse {
    let contentBlocks: [ResponseBlock]
    let stopReason: String
    let inputTokens: Int
    let outputTokens: Int

    /// Get all text content concatenated.
    var textContent: String {
        contentBlocks.compactMap {
            if case .text(let text) = $0 { return text }
            return nil
        }.joined(separator: "\n")
    }

    /// Get all tool use blocks.
    var toolUses: [(id: String, name: String, input: [String: Any])] {
        contentBlocks.compactMap {
            if case .toolUse(let id, let name, let input) = $0 {
                return (id, name, input)
            }
            return nil
        }
    }

    /// Whether the response contains tool calls.
    var hasToolUse: Bool {
        contentBlocks.contains {
            if case .toolUse = $0 { return true }
            return false
        }
    }
}

enum ResponseBlock {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
}

enum APIError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured. Please add your Claude API key in Settings."
        case .invalidResponse:
            return "Received invalid response from API."
        case .httpError(let code, let body):
            return "API error (\(code)): \(body.prefix(200))"
        case .parseError(let msg):
            return "Failed to parse API response: \(msg)"
        }
    }
}
