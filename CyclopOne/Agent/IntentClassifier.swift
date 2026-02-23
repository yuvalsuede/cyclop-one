import Foundation

/// The classified intent of a user command.
/// Each case carries a confidence score (0.0-1.0) indicating
/// how certain the classifier is about its determination.
enum Intent: Sendable {

    /// Pure conversational message (greeting, question, banter).
    /// `topic` is a brief label like "greeting", "question", "smalltalk".
    case chat(topic: String, confidence: Double)

    /// Actionable task requiring desktop automation or tool use.
    /// `description` is a normalized summary of what to do.
    /// `complexity` rates the task: .simple (1-3 steps), .moderate (4-8), .complex (9+).
    case task(description: String, complexity: TaskComplexity, confidence: Double)

    /// Input is too ambiguous to classify. The classifier proposes a
    /// clarifying question to send back to the user.
    case clarification(question: String, confidence: Double)

    /// A meta/control command (status check, cancel, screenshot, help).
    /// These bypass the orchestrator entirely.
    case metaCommand(command: MetaCommandType, confidence: Double)

    /// The confidence score regardless of case.
    var confidence: Double {
        switch self {
        case .chat(_, let c), .task(_, _, let c),
             .clarification(_, let c), .metaCommand(_, let c):
            return c
        }
    }
}

/// Task complexity levels for planning decisions.
enum TaskComplexity: String, Sendable, Codable {
    case simple    // 1-3 steps, single app
    case moderate  // 4-8 steps, possibly multi-app
    case complex   // 9+ steps, multi-app, potentially destructive
}

/// Recognized meta-commands that bypass the orchestrator.
enum MetaCommandType: String, Sendable, Codable {
    case status      // "what are you doing", "/status"
    case stop        // "stop", "cancel", "/stop", "x"
    case screenshot  // "screenshot", "show me the screen"
    case help        // "help", "what can you do"
}

/// Classifies user commands into intents before orchestration.
///
/// Uses a single focused API call to Opus 4.6 with structured JSON output.
/// No tools are provided — this is a text-only classification call.
/// The classifier is stateless: each call is independent.
actor IntentClassifier {

    /// The model used for classification. Defaults to Opus for accuracy
    /// on nuanced inputs. Could be swapped to Sonnet for cost savings
    /// once the prompt is well-tuned.
    private let model: String

    /// Confidence threshold below which the classifier returns .clarification.
    private let confidenceThreshold: Double

    init(model: String = "claude-opus-4-6", confidenceThreshold: Double = 0.7) {
        self.model = model
        self.confidenceThreshold = confidenceThreshold
    }

    /// Recent run context for follow-up awareness.
    /// Stores the last command + outcome so the classifier can interpret follow-ups.
    private var lastRunContext: String?

    /// Update the classifier with the most recent run's context.
    func setLastRunContext(command: String, outcome: String, activeApp: String?) {
        var ctx = "Previous command: \"\(command)\" → \(outcome)"
        if let app = activeApp, !app.isEmpty {
            ctx += " (active app: \(app))"
        }
        lastRunContext = ctx
    }

    /// Clear the run context (e.g., on session reset).
    func clearContext() {
        lastRunContext = nil
    }

    /// Classify a user command into an intent.
    ///
    /// - Parameters:
    ///   - command: The raw user input text.
    ///   - source: Where the command came from (affects meta-command detection).
    /// - Returns: The classified `Intent` with confidence score.
    func classify(command: String, source: CommandSource = .localUI) async -> Intent {
        // Step 1: Check for explicit meta-commands (no API call needed)
        if let meta = detectMetaCommand(command) {
            return meta
        }

        // Step 2: Check for empty/whitespace-only input
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .clarification(
                question: "It looks like you sent an empty message. What would you like me to do?",
                confidence: 1.0
            )
        }

        // Step 3: Call the LLM for nuanced classification
        do {
            let intent = try await classifyWithLLM(command: trimmed)

            // Step 4: Apply confidence threshold
            if intent.confidence < confidenceThreshold {
                return .clarification(
                    question: buildClarificationQuestion(command: trimmed, rawIntent: intent),
                    confidence: intent.confidence
                )
            }

            return intent
        } catch {
            NSLog("CyclopOne [IntentClassifier]: Classification failed: %@, defaulting to task",
                  error.localizedDescription)
            // Fail-open as task — better to attempt the command than ignore it
            return .task(
                description: trimmed,
                complexity: .moderate,
                confidence: 0.5
            )
        }
    }

    // MARK: - Meta-Command Detection (Local, No API Call)

    /// Detect explicit meta-commands from well-known patterns.
    /// These are unambiguous and don't need LLM classification.
    private func detectMetaCommand(_ command: String) -> Intent? {
        let lower = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // /status or natural-language equivalents
        if lower == "/status" || lower == "status" ||
           lower == "what are you doing" || lower == "what's happening" {
            return .metaCommand(command: .status, confidence: 1.0)
        }

        // /stop or natural-language equivalents
        if lower == "/stop" || lower == "stop" || lower == "cancel" || lower == "x" {
            return .metaCommand(command: .stop, confidence: 1.0)
        }

        // /screenshot
        if lower == "/screenshot" || lower == "screenshot" ||
           lower == "show me the screen" || lower == "show screen" {
            return .metaCommand(command: .screenshot, confidence: 1.0)
        }

        // /help
        if lower == "/help" || lower == "help" ||
           lower == "what can you do" {
            return .metaCommand(command: .help, confidence: 1.0)
        }

        return nil
    }

    // MARK: - LLM Classification

    /// Call the classification model with a structured JSON output prompt.
    private func classifyWithLLM(command: String) async throws -> Intent {
        // Build the user message with context if available
        var userContent = command
        if let ctx = lastRunContext {
            userContent = "[Context: \(ctx)]\n\nNew message: \(command)"
        }

        let messages: [[String: Any]] = [
            ["role": "user", "content": userContent]
        ]

        let response = try await ClaudeAPIService.shared.sendMessage(
            messages: messages,
            systemPrompt: Self.classificationSystemPrompt,
            tools: [],
            model: model,
            maxTokens: 256
        )

        return try parseClassificationResponse(response.textContent)
    }

    // MARK: - Response Parsing

    /// Parse the JSON response from the classification model into an Intent.
    private func parseClassificationResponse(_ text: String) throws -> Intent {
        // Extract JSON from the response (model may wrap it in markdown code blocks)
        let jsonString = extractJSON(from: text)

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let intentType = json["intent"] as? String,
              let confidence = json["confidence"] as? Double else {
            throw ClassificationError.parseFailure(text)
        }

        switch intentType {
        case "chat":
            let topic = json["topic"] as? String ?? "general"
            return .chat(topic: topic, confidence: confidence)

        case "task":
            let description = json["description"] as? String ?? ""
            let complexityRaw = json["complexity"] as? String ?? "moderate"
            let complexity = TaskComplexity(rawValue: complexityRaw) ?? .moderate
            return .task(description: description, complexity: complexity, confidence: confidence)

        case "clarification":
            let question = json["question"] as? String ?? "Could you clarify what you'd like me to do?"
            return .clarification(question: question, confidence: confidence)

        case "meta":
            let cmdRaw = json["command"] as? String ?? "help"
            let cmd = MetaCommandType(rawValue: cmdRaw) ?? .help
            return .metaCommand(command: cmd, confidence: confidence)

        default:
            throw ClassificationError.unknownIntent(intentType)
        }
    }

    /// Extract JSON object from text that may be wrapped in markdown code fences.
    private func extractJSON(from text: String) -> String {
        // Try to find JSON between code fences
        if let start = text.range(of: "```json"),
           let end = text.range(of: "```", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = text.range(of: "```"),
           let end = text.range(of: "```", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Try to find a raw JSON object
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Clarification Builder

    /// Build a user-friendly clarification question when confidence is low.
    private func buildClarificationQuestion(command: String, rawIntent: Intent) -> String {
        switch rawIntent {
        case .chat(let topic, _):
            return "I'm not sure if you want me to do something or if you're just chatting about \"\(topic)\". Could you clarify?"
        case .task(let desc, _, _):
            return "I think you might want me to: \(desc). Is that right, or were you just mentioning it?"
        default:
            return "I'm not sure what you'd like me to do with: \"\(command)\". Could you rephrase?"
        }
    }

    // MARK: - Classification System Prompt

    /// The system prompt used for intent classification.
    /// Designed for structured JSON output with confidence scoring.
    static let classificationSystemPrompt = """
    You are an intent classifier for a macOS desktop automation agent called Cyclop One.

    Your ONLY job is to classify the user's message into one of four intents. Output ONLY a JSON object, no other text.

    ## Intents

    1. **task** — The user wants the agent to DO something on their computer.
       Actions include: opening apps, clicking things, typing text, sending messages, \
    creating files, browsing the web, filling forms, taking screenshots of specific things, \
    running commands, automating workflows.

    2. **chat** — The user is making conversation, asking a general knowledge question, \
    or greeting the agent. No computer action is needed.

    3. **clarification** — The input is genuinely ambiguous and you cannot determine \
    intent with reasonable confidence. Provide a short clarifying question.

    4. **meta** — The user wants to control the agent itself (check status, stop a task, \
    get help). Only use this for: status, stop, screenshot, help.

    ## Context Awareness

    Messages may include a [Context: ...] prefix showing the previous command, its outcome, \
    and the currently active app. Use this to interpret follow-up messages:

    - If context says "Previous command: open WhatsApp" and new message is "look for John", \
    interpret as **task**: "Search for contact John in WhatsApp" (not ambiguous!)
    - If context says "Previous command: open Safari" and new message is "go to google", \
    interpret as **task**: "Navigate to google.com in Safari"
    - Short follow-ups like "now type hello", "click send", "search for X" are almost always \
    **task** continuations of the previous command's context.
    - Even single words like a person's name can be a task if the context implies a search \
    or navigation action in the active app.

    ## Critical Rules

    - "Tell X to Y" or "message X about Y" or "send X a message" = **task** (agent must open a messaging app and send it). NOT chat.
    - "What time is it" = **task** (agent checks the clock on screen). NOT chat.
    - "Remind me to X" = **task** (agent creates a reminder). NOT chat.
    - "How do I X on my Mac" = **chat** (general knowledge question). NOT task.
    - "Open Safari" = **task**
    - "What is Safari" = **chat**
    - "Hey" / "Hello" / "What's up" = **chat**
    - "Search for X" = **task** (agent opens browser and searches)
    - "What do you think about X" = **chat**
    - "Make a note that says X" = **task**
    - "Tell me about X" = **chat** (unless it implies an action like "tell me about the files in my Downloads folder")
    - "Stop" / "Cancel" / "x" = **meta** (command: stop)
    - "What are you doing" / "Status" = **meta** (command: status)

    ## Complexity (for tasks only)
    - **simple**: 1-3 steps, single application (e.g., "open Calculator")
    - **moderate**: 4-8 steps, may involve multiple apps (e.g., "search for flights to Tokyo")
    - **complex**: 9+ steps, multi-app, potentially destructive (e.g., "reorganize my Desktop files by type")

    ## Confidence Scoring
    - 0.9-1.0: Unambiguous intent (greetings, direct commands)
    - 0.7-0.89: Clear intent with minor ambiguity
    - 0.5-0.69: Genuinely ambiguous, could go either way
    - Below 0.5: Very unclear, probably needs clarification

    ## Output Format (JSON only, no markdown fences)

    For task:
    {"intent": "task", "description": "<what to do>", "complexity": "simple|moderate|complex", "confidence": 0.95}

    For chat:
    {"intent": "chat", "topic": "<brief topic>", "confidence": 0.9}

    For clarification:
    {"intent": "clarification", "question": "<clarifying question>", "confidence": 0.4}

    For meta:
    {"intent": "meta", "command": "status|stop|screenshot|help", "confidence": 1.0}
    """
}

// MARK: - Classification Errors

enum ClassificationError: LocalizedError {
    case parseFailure(String)
    case unknownIntent(String)

    var errorDescription: String? {
        switch self {
        case .parseFailure(let raw):
            return "Failed to parse classification response: \(raw.prefix(200))"
        case .unknownIntent(let type):
            return "Unknown intent type: \(type)"
        }
    }
}
