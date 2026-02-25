import Foundation

// MARK: - ProceduralMemoryService

/// Learns and retrieves step sequences and failure traps for each app/task type.
///
/// Storage layout:
///   `~/.cyclopone/procedural/<app_key>/<task_type>.json`
///
/// Lifecycle:
///   1. `bootstrap()` — called once at app startup; creates dirs, seeds defaults.
///   2. `setRunContext(app:taskType:)` — called when a run starts.
///   3. `bufferLearningEvent(_:)` — called during the run (fire-and-forget).
///   4. `retrieveAndFormatForPrompt(command:)` — called before building the system prompt.
///   5. `consolidate(command:appName:success:iterations:runId:)` — called after run completes.
actor ProceduralMemoryService {

    // MARK: - Singleton

    static let shared = ProceduralMemoryService()

    // MARK: - Properties

    /// Root directory for all procedural JSON files.
    private let proceduralDir: URL

    /// In-memory cache: "<app_key>/<task_type>" -> ProceduralMemory
    private var cache: [String: ProceduralMemory] = [:]

    /// Buffered events collected during the current run.
    private var learningBuffer: [LearningEvent] = []

    /// App key inferred for the current run (e.g. "gmail", "whatsapp", "twitter").
    private var currentRunApp: String?

    /// Task type inferred for the current run (e.g. "compose_email").
    private var currentRunTaskType: String?

    /// ISO8601 encoder/decoder shared across all serialisation calls.
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Init

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.proceduralDir = home.appendingPathComponent(".cyclopone/procedural")
    }

    // MARK: - Bootstrap

    /// Create directory structure and seed default memories if they don't exist.
    func bootstrap() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: proceduralDir.path) {
            try? fm.createDirectory(at: proceduralDir, withIntermediateDirectories: true)
            NSLog("ProceduralMemoryService: Created directory at %@", proceduralDir.path)
        }

        seedDefaultsIfNeeded()
        NSLog("ProceduralMemoryService: Bootstrap complete")
    }

    // MARK: - Run Context

    /// Set the app and task context for the upcoming run, and flush the learning buffer.
    func setRunContext(app: String?, taskType: String?) {
        currentRunApp = app
        currentRunTaskType = taskType
        learningBuffer = []
        NSLog("ProceduralMemoryService: Run context set — app=%@, task=%@",
              app ?? "nil", taskType ?? "nil")
    }

    // MARK: - Learning Buffer

    /// Append a learning event to the buffer. Call from inside a run.
    func bufferLearningEvent(_ event: LearningEvent?) {
        guard let event = event else { return }
        learningBuffer.append(event)
    }

    // MARK: - Retrieval

    /// Detect the relevant procedural memory for a command and return a formatted string
    /// suitable for injection into the system prompt (~250 tokens).
    /// Returns "" if no memory exists or none matches.
    func retrieveAndFormatForPrompt(command: String) -> String {
        let lower = command.lowercased()

        // Detect the app from the command string
        let candidates: [(appKey: String, taskType: String)] = detectAppAndTask(from: lower)

        for (appKey, taskType) in candidates {
            if let memory = loadMemory(appKey: appKey, taskType: taskType), memory.hasValidData {
                let formatted = memory.formatForPrompt()
                NSLog("ProceduralMemoryService: Injecting memory for %@/%@", appKey, taskType)
                return "\n--- PROCEDURAL MEMORY ---\n\(formatted)\n---\n"
            }
        }

        return ""
    }

    // MARK: - Consolidation

    /// After a run completes, extract learnings with Haiku and merge them into the JSON file.
    func consolidate(command: String, appName: String?, success: Bool, iterations: Int, runId: String) async {
        let lower = command.lowercased()
        let candidates = detectAppAndTask(from: lower)

        guard let (appKey, taskType) = candidates.first else {
            NSLog("ProceduralMemoryService: No app/task match — skipping consolidation for: %@",
                  String(command.prefix(80)))
            return
        }

        // Load or create memory
        var memory = loadMemory(appKey: appKey, taskType: taskType)
            ?? makeEmptyMemory(appKey: appKey, taskType: taskType, command: command)

        // Update run statistics
        if success {
            memory.successCount += 1
        } else {
            memory.failureCount += 1
        }
        let totalRuns = Double(memory.successCount + memory.failureCount)
        memory.avgIterations = ((memory.avgIterations * (totalRuns - 1)) + Double(iterations)) / totalRuns
        memory.reliabilityScore = totalRuns > 0 ? Double(memory.successCount) / totalRuns : 0.5
        memory.lastUpdated = Date()

        // Record episodic entry
        let episode = ProceduralEpisodicEntry(
            runId: runId,
            timestamp: Date(),
            success: success,
            iterations: iterations,
            approachSummary: buildApproachSummary(from: learningBuffer),
            failureEncountered: extractFailureFromBuffer()
        )
        memory.episodicHistory.append(episode)
        // Keep episodic history bounded to last 20 entries
        if memory.episodicHistory.count > 20 {
            memory.episodicHistory = Array(memory.episodicHistory.suffix(20))
        }

        // Extract learnings from Haiku (only if we have buffered events or a meaningful run)
        if !learningBuffer.isEmpty || iterations >= 3 {
            let learnings = await extractLearningsWithLLM(
                command: command,
                memory: memory,
                success: success,
                iterations: iterations
            )
            memory = applyLearnings(learnings, to: memory)
        }

        // Persist
        saveMemory(memory, appKey: appKey, taskType: taskType)

        NSLog("ProceduralMemoryService: Consolidated %@/%@ — success=%d, reliability=%.0f%%",
              appKey, taskType, success, memory.reliabilityScore * 100)
    }

    // MARK: - Private: App/Task Detection

    private func detectAppAndTask(from lower: String) -> [(appKey: String, taskType: String)] {
        var results: [(String, String)] = []

        // Gmail
        if lower.contains("gmail") || lower.contains("mail.google")
            || lower.contains("send email") || lower.contains("compose")
            || lower.contains("email to") || lower.contains("draft") {
            results.append(("gmail", "compose_email"))
        }

        // WhatsApp
        if lower.contains("whatsapp") || lower.contains("send whatsapp")
            || lower.contains("web.whatsapp") || lower.contains("לעצמי") {
            results.append(("whatsapp", "send_message"))
        }

        // Twitter / X
        if lower.contains("twitter") || lower.contains("tweet")
            || lower.contains("x.com") || lower.contains("post to x")
            || lower.contains("post on x") {
            results.append(("twitter", "post_tweet"))
        }

        return results
    }

    // MARK: - Private: LLM Extraction

    private func extractLearningsWithLLM(
        command: String,
        memory: ProceduralMemory,
        success: Bool,
        iterations: Int
    ) async -> [ConsolidationLearning] {
        let bufferSummary = learningBuffer.map { describeEvent($0) }.joined(separator: "\n")
        let existingSteps = memory.steps.map { "  \($0.stepIndex + 1). \($0.action)" }.joined(separator: "\n")

        let prompt = """
        You are updating procedural memory for: \(memory.app) / \(memory.taskType)
        Command: "\(command)"
        Run result: \(success ? "SUCCESS" : "FAILED") in \(iterations) iterations

        Current steps:
        \(existingSteps.isEmpty ? "  (none yet)" : existingSteps)

        Events observed during the run:
        \(bufferSummary.isEmpty ? "  (no events buffered)" : bufferSummary)

        Output a JSON array of learnings. Each item must have:
          - "type": one of "step_update" | "trap_discovered" | "shortcut_found" | "step_failed"
          - "step_index": (int, 0-based) for step_update/step_failed
          - "description": what was learned
          - "detection_signal": (for trap_discovered) what UI signal triggers the trap
          - "recovery": (for trap_discovered) how to recover

        Return ONLY valid JSON array, no markdown, max 5 items.
        Example: [{"type":"step_update","step_index":2,"description":"Press Enter to confirm address — do not click elsewhere"}]
        """

        do {
            let response = try await ClaudeAPIService.shared.sendMessage(
                messages: [APIMessage.userText(prompt)],
                systemPrompt: "You are a memory consolidation assistant. Return only valid JSON arrays.",
                tools: [],
                tier: .fast,
                maxTokens: 512
            )
            let text = response.textContent.trimmingCharacters(in: .whitespacesAndNewlines)

            // Strip markdown code fence if present
            let stripped = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let data = stripped.data(using: .utf8) else { return [] }
            let learnings = try decoder.decode([ConsolidationLearning].self, from: data)
            NSLog("ProceduralMemoryService: Extracted %d learnings via LLM", learnings.count)
            return learnings
        } catch {
            NSLog("ProceduralMemoryService: LLM extraction failed: %@", error.localizedDescription)
            return []
        }
    }

    // MARK: - Private: Apply Learnings

    private func applyLearnings(_ learnings: [ConsolidationLearning], to memory: ProceduralMemory) -> ProceduralMemory {
        var memory = memory

        for learning in learnings {
            switch learning.type {
            case "step_update":
                let idx = learning.stepIndex ?? -1
                if idx >= 0, idx < memory.steps.count {
                    memory.steps[idx].action = learning.description
                    memory.steps[idx].confirmedWorking = true
                } else if idx == memory.steps.count || idx == -1 {
                    // Append a new step
                    let newStep = ProceduralMemoryStep(
                        stepIndex: memory.steps.count,
                        action: learning.description,
                        rationale: nil,
                        alternativeIfFails: nil,
                        confirmedWorking: true,
                        failureCount: 0
                    )
                    memory.steps.append(newStep)
                }

            case "step_failed":
                let idx = learning.stepIndex ?? -1
                if idx >= 0, idx < memory.steps.count {
                    memory.steps[idx].failureCount += 1
                    if let alt = learning.recovery {
                        memory.steps[idx].alternativeIfFails = alt
                    }
                }

            case "trap_discovered":
                let trapId = "trap_\(memory.knownTraps.count + 1)"
                // Avoid duplicates
                let exists = memory.knownTraps.contains {
                    $0.detectionSignal.lowercased() == (learning.detectionSignal ?? "").lowercased()
                }
                if !exists {
                    let trap = KnownTrap(
                        trapId: trapId,
                        description: learning.description,
                        detectionSignal: learning.detectionSignal ?? learning.description,
                        recovery: learning.recovery ?? "See description"
                    )
                    memory.knownTraps.append(trap)
                }

            case "shortcut_found":
                // Add as a step if not already present
                let alreadyHas = memory.steps.contains {
                    $0.action.lowercased().contains(learning.description.lowercased().prefix(30))
                }
                if !alreadyHas {
                    let shortcut = ProceduralMemoryStep(
                        stepIndex: memory.steps.count,
                        action: "[SHORTCUT] \(learning.description)",
                        rationale: "Discovered shortcut",
                        alternativeIfFails: nil,
                        confirmedWorking: true,
                        failureCount: 0
                    )
                    memory.steps.append(shortcut)
                }

            default:
                break
            }
        }

        return memory
    }

    // MARK: - Private: Disk I/O

    private func cacheKey(appKey: String, taskType: String) -> String {
        "\(appKey)/\(taskType)"
    }

    private func fileURL(appKey: String, taskType: String) -> URL {
        proceduralDir
            .appendingPathComponent(appKey)
            .appendingPathComponent("\(taskType).json")
    }

    private func loadMemory(appKey: String, taskType: String) -> ProceduralMemory? {
        let key = cacheKey(appKey: appKey, taskType: taskType)
        if let cached = cache[key] { return cached }

        let url = fileURL(appKey: appKey, taskType: taskType)
        guard let data = try? Data(contentsOf: url),
              let memory = try? decoder.decode(ProceduralMemory.self, from: data) else {
            return nil
        }
        cache[key] = memory
        return memory
    }

    private func saveMemory(_ memory: ProceduralMemory, appKey: String, taskType: String) {
        let key = cacheKey(appKey: appKey, taskType: taskType)
        cache[key] = memory

        let url = fileURL(appKey: appKey, taskType: taskType)
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        guard let data = try? encoder.encode(memory) else {
            NSLog("ProceduralMemoryService: Failed to encode memory for %@/%@", appKey, taskType)
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("ProceduralMemoryService: Failed to save %@/%@: %@", appKey, taskType, error.localizedDescription)
        }
    }

    // MARK: - Private: Helpers

    private func buildApproachSummary(from events: [LearningEvent]) -> String {
        let descs = events.prefix(5).map { describeEvent($0) }
        return descs.isEmpty ? "No events captured." : descs.joined(separator: "; ")
    }

    private func extractFailureFromBuffer() -> String? {
        for event in learningBuffer {
            if case .stepFailed(_, _, let desc, let err) = event {
                return "\(desc): \(err)"
            }
        }
        return nil
    }

    private func describeEvent(_ event: LearningEvent) -> String {
        switch event {
        case .trapEncountered(_, _, let signal, let action, let recovery):
            return "TRAP[\(signal)] during \(action)" + (recovery.map { " — recovery: \($0)" } ?? "")
        case .stepSucceeded(_, _, let desc, let idx):
            return "Step \(idx) OK: \(desc)"
        case .stepFailed(_, _, let desc, let err):
            return "Step FAILED: \(desc) — \(err)"
        case .shortcutDiscovered(_, let desc):
            return "Shortcut: \(desc)"
        }
    }

    private func makeEmptyMemory(appKey: String, taskType: String, command: String) -> ProceduralMemory {
        return ProceduralMemory(
            schemaVersion: 1,
            app: appKey,
            appURL: nil,
            taskType: taskType,
            triggerPatterns: [command],
            lastUpdated: Date(),
            successCount: 0,
            failureCount: 0,
            avgIterations: 0,
            reliabilityScore: 0.5,
            steps: [],
            knownTraps: [],
            screenStatePatterns: [],
            episodicHistory: []
        )
    }

    // MARK: - Private: Seed Defaults

    private func seedDefaultsIfNeeded() {
        seedGmailComposeEmail()
        seedWhatsAppSendMessage()
        seedTwitterPost()
    }

    private func seedGmailComposeEmail() {
        let appKey = "gmail"
        let taskType = "compose_email"
        let url = fileURL(appKey: appKey, taskType: taskType)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        let memory = ProceduralMemory(
            schemaVersion: 1,
            app: "Gmail",
            appURL: "https://mail.google.com",
            taskType: taskType,
            triggerPatterns: ["send email", "compose", "email to", "draft", "gmail"],
            lastUpdated: Date(),
            successCount: 0,
            failureCount: 0,
            avgIterations: 0,
            reliabilityScore: 0.5,
            steps: [
                ProceduralMemoryStep(stepIndex: 0, action: "Open mail.google.com in Chrome using shell: open -a 'Google Chrome' https://mail.google.com", rationale: "Navigate to Gmail", alternativeIfFails: "Type mail.google.com directly in Chrome address bar", confirmedWorking: true, failureCount: 0),
                ProceduralMemoryStep(stepIndex: 1, action: "Wait for Gmail to load, then click the Compose button (pencil/pen icon, bottom-left of sidebar)", rationale: "Open compose window", alternativeIfFails: "Use keyboard shortcut C to open compose", confirmedWorking: true, failureCount: 0),
                ProceduralMemoryStep(stepIndex: 2, action: "Click inside the To: input text area — do NOT click the 'To:' label itself", rationale: "Focus recipient field", alternativeIfFails: "Tab to the input after clicking near it", confirmedWorking: true, failureCount: 0),
                ProceduralMemoryStep(stepIndex: 3, action: "Type the recipient email address directly", rationale: "Enter recipient", alternativeIfFails: nil, confirmedWorking: true, failureCount: 0),
                ProceduralMemoryStep(stepIndex: 4, action: "Press Enter or Tab to confirm the address — wait for it to become a blue chip before proceeding", rationale: "Confirm recipient so it is accepted by Gmail", alternativeIfFails: "Press Tab to move to Subject field which also confirms the address", confirmedWorking: true, failureCount: 0),
                ProceduralMemoryStep(stepIndex: 5, action: "Click the Subject field and type the email subject", rationale: "Enter subject line", alternativeIfFails: nil, confirmedWorking: true, failureCount: 0),
                ProceduralMemoryStep(stepIndex: 6, action: "Click the message body area below the subject and type the email body", rationale: "Write the message", alternativeIfFails: nil, confirmedWorking: true, failureCount: 0),
                ProceduralMemoryStep(stepIndex: 7, action: "Click the Send button (blue button, bottom-left of compose window)", rationale: "Send the email", alternativeIfFails: "Use Cmd+Enter keyboard shortcut to send", confirmedWorking: true, failureCount: 0),
            ],
            knownTraps: [
                KnownTrap(trapId: "trap_1", description: "Contact suggestions overlay appears blocking input", detectionSignal: "Select contacts overlay visible", recovery: "Press Escape to dismiss the overlay, then type in the To text area directly"),
                KnownTrap(trapId: "trap_2", description: "Email address not confirmed as chip before moving on", detectionSignal: "Typed address is plain text with no blue chip around it", recovery: "Click on the address text and press Enter to confirm it as a chip"),
                KnownTrap(trapId: "trap_3", description: "Compose window not open", detectionSignal: "No compose popup window visible on screen", recovery: "Click the Compose button on the left sidebar, or press C if Gmail is focused"),
            ],
            screenStatePatterns: [
                ScreenStatePattern(stateId: "gmail_inbox", discriminators: ["Primary", "Compose", "Inbox"], description: "Gmail inbox loaded and ready"),
                ScreenStatePattern(stateId: "compose_open", discriminators: ["To:", "Subject:", "Send"], description: "Compose window is open"),
            ],
            episodicHistory: []
        )

        saveMemory(memory, appKey: appKey, taskType: taskType)
        NSLog("ProceduralMemoryService: Seeded Gmail compose_email memory")
    }

    private func seedWhatsAppSendMessage() {
        let appKey = "whatsapp"
        let taskType = "send_message"
        let url = fileURL(appKey: appKey, taskType: taskType)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        let memory = ProceduralMemory(
            schemaVersion: 1,
            app: "WhatsApp",
            appURL: "https://web.whatsapp.com",
            taskType: taskType,
            triggerPatterns: ["whatsapp", "send whatsapp", "message to", "לעצמי"],
            lastUpdated: Date(),
            successCount: 0,
            failureCount: 0,
            avgIterations: 0,
            reliabilityScore: 0.5,
            steps: [
                ProceduralMemoryStep(stepIndex: 0, action: "Open web.whatsapp.com in Chrome using shell: open -a 'Google Chrome' https://web.whatsapp.com", rationale: "Navigate to WhatsApp Web", alternativeIfFails: "Type web.whatsapp.com in Chrome address bar", confirmedWorking: true, failureCount: 0),
                ProceduralMemoryStep(stepIndex: 1, action: "Wait for chat list to load. If QR code shows, stop and inform the user they must scan it to log in.", rationale: "Ensure logged in", alternativeIfFails: nil, confirmedWorking: true, failureCount: 0),
                ProceduralMemoryStep(stepIndex: 2, action: "Use the search bar at the top-left to find the contact or group — click it and type the EXACT name given in the command", rationale: "Find the target chat quickly without scrolling", alternativeIfFails: "Try the New Chat (pencil) button and search there", confirmedWorking: true, failureCount: 0),
                ProceduralMemoryStep(stepIndex: 3, action: "Click on the EXACT matching contact/group in the search results — do NOT assume any name is a self-chat", rationale: "Open the correct conversation", alternativeIfFails: nil, confirmedWorking: true, failureCount: 0),
                ProceduralMemoryStep(stepIndex: 4, action: "Click the message input box at the bottom of the chat and type the message", rationale: "Compose the message", alternativeIfFails: nil, confirmedWorking: true, failureCount: 0),
                ProceduralMemoryStep(stepIndex: 5, action: "Press Enter or click the Send button (arrow icon) to send the message", rationale: "Send the message", alternativeIfFails: nil, confirmedWorking: true, failureCount: 0),
            ],
            knownTraps: [
                KnownTrap(trapId: "trap_1", description: "User is not logged into WhatsApp Web", detectionSignal: "QR code visible on screen", recovery: "Inform the user they need to scan the QR code with their phone to log in. Do not proceed until the chat list is visible."),
                KnownTrap(trapId: "trap_2", description: "Emoji/attachment panel opened instead of typing", detectionSignal: "Emoji panel or attachment options are visible", recovery: "Click elsewhere to close the panel, then click the text input box"),
                KnownTrap(trapId: "trap_3", description: "Opened self-chat (saved messages) instead of the group", detectionSignal: "Chat title is your own name or 'You' — not the group/contact name", recovery: "Go back to chat list, search again for the EXACT group name from the command"),
            ],
            screenStatePatterns: [
                ScreenStatePattern(stateId: "wa_logged_in", discriminators: ["New chat", "Search or start new chat"], description: "WhatsApp Web logged in and showing chat list"),
                ScreenStatePattern(stateId: "wa_qr_code", discriminators: ["QR", "Keep your phone connected"], description: "QR code login screen — user must log in"),
                ScreenStatePattern(stateId: "wa_chat_open", discriminators: ["Type a message"], description: "A chat is open and ready for input"),
            ],
            episodicHistory: []
        )

        saveMemory(memory, appKey: appKey, taskType: taskType)
        NSLog("ProceduralMemoryService: Seeded WhatsApp send_message memory")
    }

    private func seedTwitterPost() {
        let appKey = "twitter"
        let taskType = "post_tweet"
        let url = fileURL(appKey: appKey, taskType: taskType)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        let memory = ProceduralMemory(
            schemaVersion: 1,
            app: "Twitter / X",
            appURL: "https://x.com",
            taskType: taskType,
            triggerPatterns: ["post to x", "tweet", "twitter", "x.com", "post on x"],
            lastUpdated: Date(),
            successCount: 0,
            failureCount: 0,
            avgIterations: 0,
            reliabilityScore: 0.5,
            steps: [
                ProceduralMemoryStep(stepIndex: 0, action: "Open x.com in Chrome using shell: open -a 'Google Chrome' https://x.com", rationale: "Navigate to X/Twitter", alternativeIfFails: "Type x.com in Chrome address bar", confirmedWorking: true, failureCount: 0),
                ProceduralMemoryStep(stepIndex: 1, action: "Wait for the home timeline to load. If login page shows, stop and inform user they must log in.", rationale: "Ensure logged in and on home page", alternativeIfFails: nil, confirmedWorking: true, failureCount: 0),
                ProceduralMemoryStep(stepIndex: 2, action: "Click the 'What is happening?!' text field (left sidebar, below navigation) OR click the compose button (pencil icon, top-right area on mobile layout)", rationale: "Open the post compose area", alternativeIfFails: "Click the blue Post/Tweet button if compose field is not visible", confirmedWorking: true, failureCount: 0),
                ProceduralMemoryStep(stepIndex: 3, action: "Type the post content in the compose area", rationale: "Write the post", alternativeIfFails: nil, confirmedWorking: true, failureCount: 0),
                ProceduralMemoryStep(stepIndex: 4, action: "Click the blue 'Post' button to publish", rationale: "Publish the post", alternativeIfFails: "Look for 'Tweet' button if UI shows older label", confirmedWorking: true, failureCount: 0),
            ],
            knownTraps: [
                KnownTrap(trapId: "trap_1", description: "Not logged in to X/Twitter", detectionSignal: "Login or sign-in page visible", recovery: "Inform the user they need to log in manually. Do not attempt to enter credentials."),
                KnownTrap(trapId: "trap_2", description: "Post button not enabled — character limit exceeded", detectionSignal: "Post button greyed out or character counter showing negative number", recovery: "Shorten the post text to under 280 characters before clicking Post"),
            ],
            screenStatePatterns: [
                ScreenStatePattern(stateId: "x_home", discriminators: ["What is happening", "For you", "Following"], description: "X home timeline, logged in"),
                ScreenStatePattern(stateId: "x_login", discriminators: ["Sign in", "Log in to X", "Create account"], description: "Login page — user must authenticate"),
                ScreenStatePattern(stateId: "x_compose", discriminators: ["What is happening", "Post", "Everyone can reply"], description: "Compose modal open"),
            ],
            episodicHistory: []
        )

        saveMemory(memory, appKey: appKey, taskType: taskType)
        NSLog("ProceduralMemoryService: Seeded Twitter post_tweet memory")
    }
}
