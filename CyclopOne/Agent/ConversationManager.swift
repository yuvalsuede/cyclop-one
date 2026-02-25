import Foundation

/// Manages conversation history and message manipulation for the AgentLoop.
///
/// Sprint 2 refactor: Extracted from AgentLoop to separate conversation
/// management concerns from the main agent loop. This is a plain struct
/// (not an actor) -- it lives inside the AgentLoop actor and uses `mutating`
/// methods for state changes.
///
/// Sprint 4 refactor: Replaced `[[String: Any]]` conversation history with
/// typed `[APIMessage]`. All message inspection now uses pattern matching
/// on `ContentBlock` instead of `as?` casts.
///
/// Sprint 6 refactor: Split into extensions to keep each file under 400 lines.
/// - ConversationManager.swift (this file): Coordinator -- properties, message
///   access, clear/reset, and payload size.
/// - ConversationManager+Pruning.swift: Cycle eviction, screenshot pruning,
///   tool-result compression, old-message compression, summarization, and
///   the single-pass validateBeforeSend() validation.
/// - ConversationManager+Injection.swift: Brain guidance, verification feedback,
///   iteration warnings, step transitions, ensureConversationEndsWithUserMessage.
struct ConversationManager {

    // MARK: - Properties

    /// The full conversation history sent to the Claude API.
    /// Sprint 4: Now uses typed APIMessage instead of [String: Any].
    var conversationHistory: [APIMessage] = []

    /// Current iteration count for conversation pruning.
    var iterationCount: Int = 0

    /// Sprint 18: Skill context injected by the Orchestrator when skills match.
    /// Appended to the system prompt for the current run.
    var skillContext: String = ""

    /// Memory context injected by the Orchestrator from MemoryService.
    /// Included in the system prompt for persistent memory across runs.
    var memoryContext: String = ""

    /// Current step instruction from the Orchestrator's plan.
    /// Replaces the old `brainPlan` property. Set by the Orchestrator
    /// before each plan step begins. Contains only the current step's
    /// action + context, NOT the full plan.
    var currentStepInstruction: String = ""

    /// Pending brain guidance to be prepended to the next system prompt.
    /// Set by injectBrainGuidance(), consumed by consumePendingBrainGuidance().
    var pendingBrainGuidance: String?

    /// Number of most-recent screenshots to keep in conversation history.
    /// Only the latest screenshot is kept; older ones are replaced with "[screenshot removed]".
    let screenshotPruneThreshold: Int = 1

    /// Maximum number of messages in conversation history before oldest are evicted.
    /// Prevents unbounded memory growth. The first 2 messages (initial user prompt +
    /// first assistant response) are always kept for task context.
    /// Sprint 6: Raised from 40 to 60. Compression of old messages (stripping images,
    /// truncating verbose tool results) means we can keep more history without bloating
    /// the payload. 60 messages = ~30 turns, enough for complex multi-step web tasks.
    let maxConversationMessages: Int = 60

    // MARK: - Message Access

    /// Returns the current number of messages in the conversation history.
    /// Exposed for testing via @testable import.
    func getConversationHistoryCount() -> Int {
        return conversationHistory.count
    }

    /// Returns the current iteration count. Exposed for testing.
    func getIterationCount() -> Int {
        return iterationCount
    }

    /// Set the iteration count directly. Exposed for testing via @testable import.
    mutating func setIterationCountForTesting(_ count: Int) {
        iterationCount = count
    }

    /// Append a typed APIMessage to conversation history.
    mutating func appendMessage(_ message: APIMessage) {
        conversationHistory.append(message)
    }

    /// Append a typed APIMessage to conversation history. Exposed for testing via @testable import.
    mutating func appendMessageForTesting(_ message: APIMessage) {
        conversationHistory.append(message)
    }

    /// Get a conversation history message at the given index. Exposed for testing.
    func getMessageForTesting(at index: Int) -> APIMessage? {
        guard index >= 0, index < conversationHistory.count else { return nil }
        return conversationHistory[index]
    }

    // MARK: - Clear / Reset

    /// Clear all conversation state for a fresh run.
    mutating func clearAll() {
        conversationHistory.removeAll()
        iterationCount = 0
        skillContext = ""
        memoryContext = ""
        currentStepInstruction = ""
        pendingBrainGuidance = nil
    }

    /// Clear conversation history and reset iteration state.
    mutating func clearHistory() {
        conversationHistory.removeAll()
        iterationCount = 0
        skillContext = ""
        memoryContext = ""
    }

    // MARK: - Payload Size

    /// Sprint 19: Get the approximate payload size of the current conversation history in bytes.
    /// Useful for monitoring and debugging payload growth.
    func conversationPayloadSize() -> Int {
        guard let data = try? JSONSerialization.data(withJSONObject: conversationHistory.toDicts()) else {
            return 0
        }
        return data.count
    }
}
