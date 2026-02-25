import Foundation
import AppKit

/// Conversation management: run setup, system prompt assembly, message injection,
/// resume support, and testing accessors.
///
/// These methods handle building the conversation context sent to Claude,
/// including initial message assembly in `prepareRun` and per-iteration
/// system prompt construction.
extension AgentLoop {

    // MARK: - Run Setup

    /// Prepare a new run: capture target PID, take initial screenshot, build first message.
    /// Called by the Orchestrator at the start of each run.
    /// Returns the initial screenshot (or nil if capture failed).
    func prepareRun(
        userMessage: String,
        completionToken: String,
        targetPID suppliedPID: pid_t? = nil,
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void
    ) async -> ScreenCapture? {
        NSLog("CyclopOne [AgentLoop]: prepareRun -- start, completionToken=%@, model=%@, suppliedPID=%@",
              String(completionToken.prefix(8)), config.modelName,
              suppliedPID.map { String($0) } ?? "nil")

        isCancelled = false
        conversation.conversationHistory.removeAll()
        latestScreenshot = nil
        self.completionToken = completionToken
        consecutiveAPIFailures = 0
        conversation.iterationCount = 0
        toolExec.clearTracking()

        // -- Determine the target app --
        // If a PID was supplied (captured when the popover opened), use it.
        // Otherwise fall back to detecting the current frontmost app.
        if let pid = suppliedPID {
            targetAppPID = pid
            NSLog("CyclopOne [prepareRun]: Using supplied target PID %d", pid)

            // Bring the target app AND its windows to the front.
            // NSRunningApplication.activate() alone only activates the menu bar --
            // it doesn't raise windows. We use AppleScript as the most reliable
            // way to bring an app's windows to the front on macOS.
            let appName = await MainActor.run { () -> String? in
                NSRunningApplication(processIdentifier: pid)?.localizedName
            }
            if let name = appName {
                // Sanitize app name to prevent AppleScript injection
                let sanitized = ActionExecutor.escapeAppleScriptString(name)
                let script = "tell application \"\(sanitized)\" to activate"
                if let appleScript = NSAppleScript(source: script) {
                    var errorInfo: NSDictionary?
                    appleScript.executeAndReturnError(&errorInfo)
                    if let err = errorInfo {
                        NSLog("CyclopOne [prepareRun]: AppleScript activate failed: %@", err)
                    } else {
                        NSLog("CyclopOne [prepareRun]: AppleScript activated '%@' (PID %d)", name, pid)
                    }
                }
            }
            // Give the app time to bring its windows to the front and render
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
        } else {
            targetAppPID = await MainActor.run { () -> pid_t? in
                let currentPID = ProcessInfo.processInfo.processIdentifier
                if let front = NSWorkspace.shared.frontmostApplication,
                   front.processIdentifier != currentPID {
                    return front.processIdentifier
                }
                return NSWorkspace.shared.runningApplications.first(where: {
                    $0.activationPolicy == .regular &&
                    $0.processIdentifier != currentPID &&
                    !$0.isTerminated
                })?.processIdentifier
            }
        }

        // -- Capture screenshot (hide panel so it's not in the image) --
        await hideForScreenshot()
        onStateChange(.capturing)

        let screenshot: ScreenCapture?
        do {
            screenshot = try await captureService.captureScreen(
                targetPID: targetAppPID,
                maxDimension: config.screenshotMaxDimension,
                quality: config.screenshotJPEGQuality
            )
            latestScreenshot = screenshot
        } catch {
            screenshot = nil
            onMessage(ChatMessage(role: .system, content: "Warning: Screen capture failed: \(error.localizedDescription)"))
        }

        await showAfterScreenshot()

        // Read the UI tree for the TARGET app (not Cyclop One, which may now be frontmost)
        let uiTree = await accessibilityService.getUITreeSummary(targetPID: targetAppPID)

        // -- Debug: log what Claude will receive and save diagnostic copy --
        if let ss = screenshot {
            NSLog("CyclopOne [prepareRun]: Screenshot for Claude -- %dx%d px, mediaType=%@, base64 length=%d chars, data=%d bytes, screen frame=%.0fx%.0f pts",
                  ss.width, ss.height, ss.mediaType,
                  ss.base64.count, ss.imageData.count,
                  ss.screenFrame.width, ss.screenFrame.height)
            // Diagnostic screenshots saved to run journal directory (not /tmp)
        } else {
            NSLog("CyclopOne [prepareRun]: No screenshot available for Claude")
        }

        // -- Build initial user message --
        var enhancedMessage = userMessage
        if let ss = screenshot {
            enhancedMessage += "\n\n[Screenshot: \(ss.width)x\(ss.height)px. Actual screen: \(ss.screenWidth)x\(ss.screenHeight) points. Provide coordinates in screenshot pixel space -- auto-mapped to screen.]"
        } else {
            enhancedMessage += "\n\n[No screenshot available -- screen capture was blocked or failed. You can still help with this request using conversation, shell commands, AppleScript, and open_application. Use take_screenshot later if you need visual context.]"
        }

        let userMsg = APIMessage.userWithScreenshot(
            text: enhancedMessage,
            screenshot: screenshot,
            uiTreeSummary: uiTree
        )
        conversation.appendMessage(userMsg)

        NSLog("CyclopOne [AgentLoop]: prepareRun -- end, messageCount=%d, hasScreenshot=%d",
              conversation.conversationHistory.count, screenshot != nil ? 1 : 0)

        return screenshot
    }

    // MARK: - System Prompt Assembly

    /// Build the system prompt for an iteration, including skill context, memory context,
    /// current step instruction, and completion protocol.
    ///
    /// SECURITY: The actual completion token is NOT embedded in the prompt to prevent
    /// prompt injection attacks. Claude outputs a canonical marker; the Orchestrator
    /// validates it independently using the secret token.
    func buildIterationSystemPrompt() -> String {
        var systemPrompt = ToolDefinitions.buildSystemPrompt(
            memoryContext: conversation.memoryContext,
            skillContext: conversation.skillContext
        )

        // Inject current step instruction if available (set by Orchestrator per-step)
        if !conversation.currentStepInstruction.isEmpty {
            systemPrompt += """

            ## Current Task
            \(conversation.currentStepInstruction)

            Focus ONLY on this specific task. When you have completed it and can see the \
            expected result on screen, output <task_complete/> to signal completion.
            Do NOT proceed to other tasks. Do NOT take actions beyond this instruction.
            """
        }

        if let token = completionToken, !token.isEmpty {
            systemPrompt += """

            ## Completion Protocol -- YOU MUST FOLLOW THIS
            When you have completed the user's task, output exactly: <task_complete/>

            ### When to declare completion (do it IMMEDIATELY when any of these are true):
            - Task was to open an app -> it is open and visible -> output <task_complete/>
            - Task was to type text -> the text is visible in the field -> output <task_complete/>
            - Task was to click something -> you clicked it and saw the result -> output <task_complete/>
            - Task was to navigate to a URL -> the page loaded -> output <task_complete/>
            - Task was to send a message -> you pressed Enter/Send -> output <task_complete/>
            - Multi-step task -> you completed the LAST step -> output <task_complete/>

            ### Mandatory rules:
            - Do NOT keep iterating after the core action is done. One verification screenshot is enough.
            - Do NOT output <task_complete/> before actually performing the action.
            - Do NOT repeat the same tool call with identical parameters. If an action failed, \
              try a COMPLETELY different approach.
            - If you have tried 3 different approaches without success, output <task_complete/> \
              with a failure explanation. Do NOT keep trying the same thing.
            - If you are on iteration 10+, you MUST either complete the task or output <task_complete/> \
              with a summary of what you accomplished and what remains.
            - NEVER take more than 2 consecutive screenshots without performing an action between them.

            ### Current iteration: \(conversation.iterationCount) of \(config.maxIterations)
            """
        }

        // Consume pending brain guidance and prepend to system prompt.
        // This avoids injecting guidance as a user message (which broke
        // conversation role alternation and caused orphaned tool_use blocks).
        if let brainGuidance = conversation.consumePendingBrainGuidance() {
            systemPrompt = brainGuidance + "\n\n" + systemPrompt
            NSLog("CyclopOne [AgentLoop]: Prepended brain guidance to system prompt (%d chars)", brainGuidance.count)
        }

        return systemPrompt
    }

    // MARK: - Run Lifecycle

    /// Restore panel interaction after a run completes.
    /// Called by the Orchestrator (or legacy run()) when the run is done.
    func finishRun() async {
        completionToken = nil
        conversation.currentStepInstruction = ""
        await restorePanelInteraction()
    }

    func cancel() {
        isCancelled = true
    }

    // MARK: - Orchestrator Wrapper Methods (Thin Delegates)

    /// Inject strategic guidance from the brain model into the conversation.
    /// Called by the Orchestrator when the agent is stuck and Opus provides advice.
    func injectBrainGuidance(_ guidance: String) {
        conversation.injectBrainGuidance(guidance)
    }

    /// Inject a verification rejection message into the conversation history.
    func injectVerificationFeedback(_ feedback: String) {
        conversation.injectVerificationFeedback(feedback)
    }

    /// Inject an iteration budget warning into the conversation history.
    func injectIterationWarning(_ warning: String) {
        conversation.injectIterationWarning(warning)
    }

    /// Inject a step transition message into the conversation history.
    func injectStepTransitionMessage(stepIndex: Int, totalSteps: Int, stepTitle: String) {
        conversation.injectStepTransitionMessage(stepIndex: stepIndex, totalSteps: totalSteps, stepTitle: stepTitle)
    }

    /// Sprint 18: Set skill context to inject into the system prompt for this run.
    func setSkillContext(_ context: String) {
        conversation.skillContext = context
    }

    /// Set memory context to inject into the system prompt for this run.
    func setMemoryContext(_ context: String) {
        conversation.memoryContext = context
    }

    /// Set the current step instruction for this run.
    /// Called by the Orchestrator at the start of each plan step.
    func setCurrentStepInstruction(_ instruction: String) {
        conversation.currentStepInstruction = instruction
    }

    func clearHistory() {
        conversation.clearHistory()
        latestScreenshot = nil
        completionToken = nil
        consecutiveAPIFailures = 0
        toolExec.clearTracking()
    }

    // MARK: - Testing Accessors

    /// Returns the current number of messages in the conversation history.
    func getConversationHistoryCount() -> Int {
        return conversation.getConversationHistoryCount()
    }

    /// Returns the current iteration count. Exposed for testing.
    func getIterationCount() -> Int {
        return conversation.getIterationCount()
    }

    /// Set the iteration count directly. Exposed for testing via @testable import.
    func setIterationCountForTesting(_ count: Int) {
        conversation.setIterationCountForTesting(count)
    }

    /// Prune conversation history. Exposed for Orchestrator / testing.
    func pruneConversationHistory() {
        conversation.pruneConversationHistory()
    }

    /// Sprint 6: Validate and repair conversation history. Exposed for Orchestrator / testing.
    @discardableResult
    func validateBeforeSend() -> Bool {
        return conversation.validateBeforeSend()
    }

    /// Legacy redirect to validateBeforeSend(). Kept for callers that haven't been updated.
    @discardableResult
    func repairAndValidateConversationHistory() -> Bool {
        return conversation.validateBeforeSend()
    }

    /// Check if a message contains image data.
    func messageContainsImage(_ message: APIMessage) -> Bool {
        return message.containsImage
    }

    /// Get approximate payload size.
    func conversationPayloadSize() -> Int {
        return conversation.conversationPayloadSize()
    }

    /// Append a typed APIMessage to conversation history. Exposed for testing via @testable import.
    func appendMessageForTesting(_ message: APIMessage) {
        conversation.appendMessageForTesting(message)
    }

    /// Get a conversation history message at the given index. Exposed for testing.
    func getMessageForTesting(at index: Int) -> APIMessage? {
        return conversation.getMessageForTesting(at: index)
    }

    // MARK: - M5: Safety Gate Interface

    func startSafetyGateRun(runId: String) async {
        await toolExec.startSafetyGateRun(runId: runId)
    }

    func endSafetyGateRun() async {
        await toolExec.endSafetyGateRun()
    }

    // MARK: - Sprint 16: Resume Support

    /// Sprint 16: Restore conversation history from a replayed run state.
    ///
    /// Called by `Orchestrator.resumeRun(runId:)` to set up the agent's
    /// conversation context before resuming from the last committed iteration.
    /// Builds a synthetic conversation from the original user command and
    /// any tool calls/results recorded in the journal.
    func restoreForResume(
        command: String,
        completionToken: String,
        toolEvents: [(tool: String, result: String?)],
        screenshot: ScreenCapture?
    ) async {
        isCancelled = false
        conversation.conversationHistory.removeAll()
        self.completionToken = completionToken
        consecutiveAPIFailures = 0
        conversation.iterationCount = 0
        toolExec.clearTracking()
        latestScreenshot = screenshot

        // Build the initial user message with the fresh screenshot
        var enhancedMessage = command
        if let ss = screenshot {
            enhancedMessage += "\n\n[Resumed after crash. Screenshot: \(ss.width)x\(ss.height)px. Actual screen: \(ss.screenWidth)x\(ss.screenHeight) points. Provide coordinates in screenshot pixel space.]"
        } else {
            enhancedMessage += "\n\n[Resumed after crash. No screenshot available.]"
        }

        // Read UI tree for the target app, not Cyclop One
        let uiTree = await accessibilityService.getUITreeSummary(targetPID: targetAppPID)

        let userMsg = APIMessage.userWithScreenshot(
            text: enhancedMessage,
            screenshot: screenshot,
            uiTreeSummary: uiTree
        )
        conversation.appendMessage(userMsg)

        // Reconstruct tool call/result pairs from journal events
        // This gives Claude context about what was already done before the crash
        if !toolEvents.isEmpty {
            // Build a synthetic assistant message summarizing previous work
            var summaryParts: [String] = ["[Previous actions before interruption:]"]
            for (i, event) in toolEvents.enumerated() {
                let resultText = event.result ?? "completed"
                summaryParts.append("\(i + 1). \(event.tool): \(resultText)")
            }
            let summaryText = summaryParts.joined(separator: "\n")

            let assistantMsg = APIMessage.assistant([.text(summaryText)])
            conversation.appendMessage(assistantMsg)

            // Add a user message indicating resume
            let resumeMsg = APIMessage.userWithScreenshot(
                text: "The task was interrupted. Please continue from where you left off. Take a fresh screenshot to assess the current state before proceeding.",
                screenshot: screenshot,
                uiTreeSummary: uiTree
            )
            conversation.appendMessage(resumeMsg)
        }
    }

    func updateConfig(_ newConfig: AgentConfig) {
        self.config = newConfig
    }

    // MARK: - Sprint 3: Graph Node Delegation

    /// Execute a single tool call on behalf of ActNode.
    ///
    /// This method runs inside the AgentLoop actor boundary, so it can safely
    /// access `toolExec`, `conversation`, and `config`. The result is returned
    /// across the isolation boundary to the calling node.
    ///
    /// Sprint 4: May evolve into a batch execution method.
    func executeToolForGraph(
        name: String,
        toolUseId: String,
        input: [String: Any],
        onStateChange: @Sendable @escaping (AgentState) -> Void,
        onMessage: @Sendable @escaping (ChatMessage) -> Void,
        onConfirmationNeeded: @Sendable @escaping (String) async -> Bool
    ) async -> ToolResult {
        let toolResult = await toolExec.executeToolCall(
            name: name,
            input: input,
            context: self,
            iterationCount: conversation.iterationCount,
            currentStepInstruction: conversation.currentStepInstruction,
            confirmDestructiveActions: config.confirmDestructiveActions,
            onStateChange: onStateChange,
            onMessage: onMessage,
            onConfirmationNeeded: onConfirmationNeeded
        )

        // Track fingerprint and recent calls
        let fingerprint = toolExec.buildToolCallFingerprint(name: name, input: input)
        toolExec.trackToolCallFingerprint(fingerprint)
        toolExec.trackToolCall(name: name, summary: String(toolResult.result.prefix(200)))

        // Append tool result to conversation
        let resultMsg = APIMessage.toolResult(
            toolUseId: toolUseId,
            result: toolResult.result,
            isError: toolResult.isError,
            screenshot: toolResult.screenshot
        )
        conversation.appendMessage(resultMsg)

        // Update latest screenshot if tool returned one
        if let ss = toolResult.screenshot {
            latestScreenshot = ss
        }

        return toolResult
    }
}
