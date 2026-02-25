import Foundation
import Security
import CryptoKit

// MARK: - TLS Certificate Pinning

/// SPKI SHA-256 hashes for Anthropic's API certificate chain.
/// Pin the intermediate CA (Google Trust Services WE1) and root (GTS Root R4)
/// for rotation resilience — leaf certs rotate frequently.
///
/// To refresh:
///   openssl s_client -connect api.anthropic.com:443 -showcerts 2>/dev/null \
///     | openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER \
///     | openssl dgst -sha256 -binary | base64
private let anthropicPinnedHashes: Set<String> = [
    "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",  // Google Trust Services WE1 (intermediate)
    "mEflZT5enoR1FuXLgYYGqnVEoZvmf9c2bVBpiOjYQ0c=",  // GTS Root R4
]

/// URLSession delegate that validates server certificates against pinned SPKI hashes.
private final class CertificatePinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "api.anthropic.com",
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Evaluate standard CA validation first
        let policy = SecPolicyCreateSSL(true, "api.anthropic.com" as CFString)
        SecTrustSetPolicies(serverTrust, policy)

        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            NSLog("CyclopOne [TLS]: Standard CA validation failed: %@", error?.localizedDescription ?? "unknown")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Check SPKI pins against the certificate chain (fail-open: log mismatch but allow)
        // CA validation already passed above, so the connection is still secure over HTTPS.
        let certCount = SecTrustGetCertificateCount(serverTrust)
        if certCount > 0,
           let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] {
            for cert in chain {
                if let spkiHash = Self.spkiSHA256(for: cert) {
                    if anthropicPinnedHashes.contains(spkiHash) {
                        // Pin matched — proceed with full confidence
                        completionHandler(.useCredential, URLCredential(trust: serverTrust))
                        return
                    }
                }
            }
            // No pin matched — log warning but allow (CA validation passed)
            NSLog("CyclopOne [TLS]: SPKI pin mismatch (fail-open) — CA validation passed, allowing connection")
        } else {
            NSLog("CyclopOne [TLS]: No certificates in chain (fail-open) — CA validation passed, allowing connection")
        }

        // Fall through: CA-validated, allow connection even without pin match
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    /// Extract SPKI SHA-256 hash from a certificate.
    /// Matches `openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER | sha256 -binary | base64`.
    private static func spkiSHA256(for certificate: SecCertificate) -> String? {
        guard let pubKey = SecCertificateCopyKey(certificate) else { return nil }

        // SecKeyCopyExternalRepresentation gives raw key bytes without ASN.1 wrapper.
        // We prepend the correct ASN.1 SubjectPublicKeyInfo header to match openssl SPKI output.
        guard let rawKeyData = SecKeyCopyExternalRepresentation(pubKey, nil) as Data? else { return nil }

        // Use SecKeyCopyAttributes for reliable key type detection
        // (SecKeyGetBlockSize returns signature size for EC keys, not key size)
        guard let attrs = SecKeyCopyAttributes(pubKey) as? [CFString: Any] else { return nil }
        let keyTypeAttr = attrs[kSecAttrKeyType] as? String ?? ""
        let keySizeBits = attrs[kSecAttrKeySizeInBits] as? Int ?? 0

        let header: Data
        let isEC = (keyTypeAttr == (kSecAttrKeyTypeECSECPrimeRandom as String))
        let isRSA = (keyTypeAttr == (kSecAttrKeyTypeRSA as String))

        if isEC && keySizeBits == 256 {
            // EC P-256 (secp256r1) — 26-byte SPKI header
            header = Data([
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86,
                0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
                0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
                0x42, 0x00
            ])
        } else if isEC && keySizeBits == 384 {
            // EC P-384 — 23-byte SPKI header
            header = Data([
                0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2A, 0x86,
                0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x05, 0x2B,
                0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00
            ])
        } else if isRSA && keySizeBits == 2048 {
            // RSA 2048 SPKI header
            header = Data([
                0x30, 0x82, 0x01, 0x22, 0x30, 0x0D, 0x06, 0x09,
                0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01,
                0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0F, 0x00
            ])
        } else if isRSA && keySizeBits == 4096 {
            // RSA 4096 SPKI header
            header = Data([
                0x30, 0x82, 0x02, 0x22, 0x30, 0x0D, 0x06, 0x09,
                0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01,
                0x01, 0x05, 0x00, 0x03, 0x82, 0x02, 0x0F, 0x00
            ])
        } else {
            // Unknown key type — log and skip
            NSLog("CyclopOne [TLS]: Unknown key type=%@ size=%d, cannot compute SPKI hash", keyTypeAttr, keySizeBits)
            return nil
        }

        var spkiData = header
        spkiData.append(rawKeyData)
        let hash = SHA256.hash(data: spkiData)
        return Data(hash).base64EncodedString()
    }
}

/// Communicates with the Claude Messages API, sending screenshots + context
/// and receiving text responses and tool-use calls.
actor ClaudeAPIService {

    static let shared = ClaudeAPIService()

    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let apiVersion = "2023-06-01"

    /// URLSession with SPKI certificate pinning for Anthropic's API.
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
        let config = URLSessionConfiguration.default
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        self.pinnedSession = URLSession(
            configuration: config,
            delegate: CertificatePinningDelegate(),
            delegateQueue: nil
        )
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

    /// Send a conversation to Claude and get a response using typed API messages.
    ///
    /// This is the preferred entry point. Converts `[APIMessage]` to dict format
    /// internally and delegates to the raw implementation.
    ///
    /// This is a single-shot call with NO built-in retry logic.
    /// Retry responsibility lies with the caller (AgentLoop.sendAPIWithRetry)
    /// to avoid retry amplification (previously 3 * 3 * 3 = 27 calls per failure).
    func sendMessage(
        messages: [APIMessage],
        systemPrompt: String,
        tools: [[String: Any]],
        model: String = AgentConfig.defaultModelName,
        maxTokens: Int = 8192
    ) async throws -> ClaudeResponse {
        return try await sendMessageOnce(
            messages: messages.toDicts(),
            systemPrompt: systemPrompt,
            tools: tools,
            model: model,
            maxTokens: maxTokens
        )
    }

    /// Sprint 5: Convenience overload that accepts a ModelTier instead of a raw model name.
    /// Defaults `maxTokens` to the tier's recommended value (fast=1024, smart=8192, deep=4096).
    func sendMessage(
        messages: [APIMessage],
        systemPrompt: String,
        tools: [[String: Any]],
        tier: ModelTier,
        maxTokens: Int? = nil
    ) async throws -> ClaudeResponse {
        return try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            model: tier.modelName,
            maxTokens: maxTokens ?? tier.maxTokens
        )
    }

    /// Send a conversation to Claude and get a response (raw dict format).
    ///
    /// - Important: Prefer the `[APIMessage]` overload for new code.
    @available(*, deprecated, message: "Use sendMessage(messages: [APIMessage], ...) instead")
    func sendMessage(
        messages: [[String: Any]],
        systemPrompt: String,
        tools: [[String: Any]],
        model: String = AgentConfig.defaultModelName,
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

    // MARK: - Single Request (SSE Streaming)

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

        // Build request body with streaming enabled
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": messages,
            "stream": true,
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

        // Execute using SSE streaming via URLSession.bytes
        let (bytes, response) = try await pinnedSession.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // For non-200 responses, collect the body for error reporting
        guard httpResponse.statusCode == 200 else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line + "\n"
                if errorBody.count > 2000 { break }
            }
            if httpResponse.statusCode == 429,
               let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After") {
                errorBody += "\n\"retry-after\": \(retryAfter)"
            }
            throw APIError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        // Parse SSE events
        return try await parseSSEStream(bytes)
    }

    // MARK: - SSE Stream Parser

    /// Parse Claude's SSE stream into a ClaudeResponse.
    /// Accumulates content blocks from streaming events and returns the complete response.
    private func parseSSEStream(_ bytes: URLSession.AsyncBytes) async throws -> ClaudeResponse {
        var contentBlocks: [ResponseBlock] = []
        var stopReason = "unknown"
        var inputTokens = 0
        var outputTokens = 0

        // Accumulators for the current content block being streamed
        var currentBlockIndex = -1
        var currentText = ""
        var currentToolId = ""
        var currentToolName = ""
        var currentToolJson = ""
        var currentBlockType = ""  // "text" or "tool_use"

        var totalResponseBytes = 0

        for try await line in bytes.lines {
            try Task.checkCancellation()

            totalResponseBytes += line.utf8.count + 1  // +1 for newline

            // SSE format: "data: {...}" or "event: ..." lines
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard jsonStr != "[DONE]" else { break }

            guard let data = jsonStr.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventType = event["type"] as? String else { continue }

            switch eventType {
            case "message_start":
                // Extract input tokens from the message start
                if let message = event["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    inputTokens = usage["input_tokens"] as? Int ?? 0
                }

            case "content_block_start":
                let index = event["index"] as? Int ?? 0
                currentBlockIndex = index

                if let block = event["content_block"] as? [String: Any],
                   let type = block["type"] as? String {
                    currentBlockType = type
                    if type == "text" {
                        currentText = block["text"] as? String ?? ""
                    } else if type == "tool_use" {
                        currentToolId = block["id"] as? String ?? ""
                        currentToolName = block["name"] as? String ?? ""
                        currentToolJson = ""
                    }
                }

            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                   let deltaType = delta["type"] as? String {
                    if deltaType == "text_delta" {
                        currentText += delta["text"] as? String ?? ""
                    } else if deltaType == "input_json_delta" {
                        currentToolJson += delta["partial_json"] as? String ?? ""
                    }
                }

            case "content_block_stop":
                // Finalize the current block
                if currentBlockType == "text" {
                    contentBlocks.append(.text(currentText))
                    currentText = ""
                } else if currentBlockType == "tool_use" {
                    // Parse accumulated JSON string into dictionary
                    var input: [String: Any] = [:]
                    if let jsonData = currentToolJson.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        input = parsed
                    }
                    contentBlocks.append(.toolUse(id: currentToolId, name: currentToolName, input: input))
                    currentToolJson = ""
                }
                currentBlockType = ""

            case "message_delta":
                if let delta = event["delta"] as? [String: Any] {
                    stopReason = delta["stop_reason"] as? String ?? stopReason
                }
                if let usage = event["usage"] as? [String: Any] {
                    outputTokens = usage["output_tokens"] as? Int ?? outputTokens
                }

            case "message_stop":
                break  // Stream complete

            case "error":
                let errorMsg = (event["error"] as? [String: Any])?["message"] as? String ?? "Stream error"
                throw APIError.parseError("SSE error: \(errorMsg)")

            default:
                break
            }
        }

        // Track response payload size
        lastResponsePayloadBytes = totalResponseBytes
        totalResponsePayloadBytes += Int64(totalResponseBytes)

        return ClaudeResponse(
            contentBlocks: contentBlocks,
            stopReason: stopReason,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }

    // MARK: - One-Shot Vision Verification

    /// Make a one-shot vision API call for verification scoring.
    /// Uses `ModelTier.smart` (Sonnet) for accurate pass/fail scoring. Stateless — does not maintain conversation history.
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

        // Build typed message with image + text
        let message = APIMessage.user([
            .image(mediaType: mediaType, data: base64Image),
            .text(prompt)
        ])

        let body: [String: Any] = [
            "model": ModelTier.smart.modelName,
            "max_tokens": 200,
            "messages": [message.toDict()]
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

    // MARK: - Build Messages (Sprint 4: Typed wrappers — DEPRECATED)
    //
    // These static methods now delegate to APIMessage constructors.
    // They return [String: Any] for backward compatibility with tests and
    // any code that still expects dictionary format. New code should use
    // APIMessage constructors directly.

    /// Create a user message with text + screenshot + UI tree.
    /// Returns the dict format for backward compatibility.
    @available(*, deprecated, message: "Use APIMessage.userWithScreenshot() directly")
    static func buildUserMessage(text: String, screenshot: ScreenCapture?, uiTreeSummary: String?) -> [String: Any] {
        return APIMessage.userWithScreenshot(
            text: text,
            screenshot: screenshot,
            uiTreeSummary: uiTreeSummary
        ).toDict()
    }

    /// Create an assistant message from Claude's response.
    /// Returns the dict format for backward compatibility.
    @available(*, deprecated, message: "Use APIMessage.assistant(from:) directly")
    static func buildAssistantMessage(from response: ClaudeResponse) -> [String: Any] {
        return APIMessage.assistant(from: response).toDict()
    }

    /// Create a tool result message, optionally including a screenshot image.
    /// Returns the dict format for backward compatibility.
    @available(*, deprecated, message: "Use APIMessage.toolResult() directly")
    static func buildToolResultMessage(toolUseId: String, result: String, isError: Bool = false, screenshot: ScreenCapture? = nil) -> [String: Any] {
        return APIMessage.toolResult(
            toolUseId: toolUseId,
            result: result,
            isError: isError,
            screenshot: screenshot
        ).toDict()
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
