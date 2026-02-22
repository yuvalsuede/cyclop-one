# AI Architect Review: Feedback Loop & Persistent Memory Design

**Date:** 2026-02-20
**Author:** AI Architect Agent
**Status:** Design Proposal
**Scope:** Feedback loop analysis, memory system design, context injection, self-improvement loop

---

## Part 1: Feedback Loop Analysis

### 1.1 Current Architecture Summary

The agent loop works as follows:

1. **Orchestrator.startRun()** (`Orchestrator.swift:116`) receives a user command
2. **AgentLoop.prepareRun()** (`AgentLoop.swift:244`) captures a screenshot, builds the initial user message with screenshot + UI tree + user text, and stores it in `conversationHistory`
3. **AgentLoop.executeIteration()** (`AgentLoop.swift:337`) sends the full `conversationHistory` to Claude with `ToolDefinitions.systemPrompt` and appended skill context
4. Claude responds with text and/or tool_use blocks; tool calls are executed and results appended to `conversationHistory`
5. The Orchestrator checks for completion token or no-more-work, runs verification via `VerificationEngine.verify()`, and either accepts, rejects (injecting feedback), or continues

### 1.2 What Claude Receives Per Iteration

Each API call to Claude includes:

- **System prompt** (`ToolDefinitions.swift:7-67`): ~1,200 tokens of instructions about being OmniAgent, screenshot interpretation, coordinate system, action guidelines, and on-screen safety
- **Skill context** (if matched): Appended to system prompt via `systemPromptWithSkills()` (`ToolDefinitions.swift:76`)
- **Completion protocol**: Appended dynamically with the token (`AgentLoop.swift:361-367`)
- **Conversation history**: All prior messages in the current run (user messages with screenshots, assistant responses with tool calls, tool results with screenshots)

### 1.3 Critical Problem: Amnesia Between Runs

**The conversation history is wiped at the start of every run.**

In `AgentLoop.prepareRun()` at line 254:
```swift
conversationHistory.removeAll()
```

This means:
- Claude has **zero knowledge** of any previous run
- It does not know what apps the user frequently uses
- It does not know user preferences (e.g., preferred browser, terminal, editor)
- It does not know what tasks it previously completed or failed
- It cannot learn from past verification rejections
- Every run starts from absolute zero, making the agent feel "stupid"

### 1.4 Verification Feedback: Does It Work?

**Within a single run, yes.** The verification feedback loop works correctly:

1. When verification fails, `Orchestrator.runIterationLoop()` at line 624 calls:
   ```swift
   await agentLoop.injectVerificationFeedback(feedbackMsg)
   ```
2. This appends a user-role message to `conversationHistory` (`AgentLoop.swift:631-638`)
3. Claude sees it on the next iteration and can adjust

**The problem:** This feedback is ephemeral. Once the run completes, the rejection reason, the score, and what Claude learned are all lost. If the user asks for the same task tomorrow, Claude will make the same mistakes.

### 1.5 System Prompt Analysis

The current system prompt (`ToolDefinitions.swift:7-67`) is adequate for basic operation but missing critical elements:

**Present:**
- Screenshot interpretation rules (well done)
- Coordinate system explanation
- Action guidelines and tool descriptions
- On-screen content safety (prompt injection defense)

**Missing:**
- Any mention of the user's identity, preferences, or environment
- Prior task context or patterns
- Known failure modes and how to avoid them
- Time awareness (current date, time of day)
- Application-specific knowledge the agent has learned
- Multi-step task planning guidance

### 1.6 Information Lost Between Runs

| Information | Current State | Impact |
|---|---|---|
| User preferences | Lost every run | Agent asks the same questions repeatedly |
| App-specific knowledge | Lost every run | Repeats failed approaches |
| Task outcomes | Stored in RunJournal JSONL but never read back | Cannot learn from success/failure |
| Verification rejections | Lost every run | Makes same mistakes |
| Contact/project info | Never stored | Cannot help with recurring tasks |
| Screen layout knowledge | Lost every run | Slower to navigate |
| Tool execution patterns | Lost every run | Cannot optimize workflows |

### 1.7 RunJournal: Goldmine Being Ignored

The RunJournal (`RunJournal.swift`) persists rich data to `~/.omniagent/runs/<runId>/journal.jsonl`:
- `run.created` events with the original command
- `tool.executed` events with tool names and results
- `iteration.end` events with verification scores
- `run.complete` / `run.fail` / `run.stuck` terminal events
- Screenshots at key moments

**This data is only used for crash recovery (`resumeRun`) and cleanup.** It is never mined for learning, pattern detection, or memory formation. This is the single biggest missed opportunity in the codebase.

---

## Part 2: Memory System Design

### 2.1 Architecture Overview

```
~/Documents/Obsidian Vault/OmniAgent-Brain/
  _index.md                    <- Vault metadata, last-updated timestamps
  identity/
    user-profile.md            <- User name, preferences, environment
    preferences.md             <- Learned preferences (browser, editor, etc.)
  tasks/
    task-log.md                <- Chronological task outcomes
    active-tasks.md            <- In-progress / recurring tasks
    task-templates/             <- Reusable task patterns
  knowledge/
    apps/
      {app-name}.md            <- Per-app knowledge (menu paths, quirks, shortcuts)
    contacts.md                <- People the user interacts with
    projects.md                <- Projects the user works on
    locations.md               <- File paths, URLs, bookmarks
  learning/
    failures.md                <- What went wrong and how to avoid it
    corrections.md             <- User corrections and their context
    patterns.md                <- Recurring task patterns and optimal approaches
  context/
    daily-summary.md           <- Auto-generated daily activity summary
    recent-actions.md          <- Last N significant actions (rolling window)
```

### 2.2 Memory Types

#### Type 1: Episodic Memory (What Happened)

Stored in `tasks/task-log.md` as structured entries:

```markdown
## 2026-02-20T14:30:00Z
- **Command:** "Open Chrome and go to github.com"
- **Outcome:** Success (score: 92)
- **Iterations:** 4
- **Key actions:** open_application(Chrome), click(URL bar), type_text(github.com), press_key(return)
- **Duration:** 45s
```

**Source:** RunJournal replay after each completed run.
**Retention:** Last 200 entries. Older entries summarized into `patterns.md`.

#### Type 2: Semantic Memory (What We Know)

Stored in `knowledge/` as structured Markdown with YAML frontmatter:

```markdown
---
type: app-knowledge
app: Google Chrome
updated: 2026-02-20
confidence: high
---
# Google Chrome

## Reliable Approaches
- URL bar is always at the top center; click at y~60 in screenshot space
- Cmd+L focuses the URL bar reliably (better than clicking)
- New tab: Cmd+T
- Tab switching: Cmd+1 through Cmd+9

## Known Issues
- Downloads bar sometimes covers bottom elements; scroll or close it
- Extension popups can steal focus

## User Patterns
- User frequently visits: github.com, localhost:3000, claude.ai
```

**Source:** Extracted from successful task patterns and user corrections.
**Retention:** Permanent, updated incrementally.

#### Type 3: Procedural Memory (How To Do Things)

Stored in `tasks/task-templates/`:

```markdown
---
type: task-template
trigger: "send.*email|compose.*email|write.*email"
app: Mail
confidence: high
avg_iterations: 6
success_rate: 0.85
---
# Send Email

1. open_application("Mail")
2. press_key("n", command: true)  // New message
3. Click "To" field, type recipient
4. Click "Subject" field, type subject
5. Click body, type message
6. press_key("d", command: true, shift: true)  // Send
7. take_screenshot to verify
```

**Source:** Extracted from SkillLoader patterns + successful RunJournal replays.
**Retention:** Permanent, versioned by success rate.

#### Type 4: Working Memory (Current Context)

Stored in `context/recent-actions.md` as a rolling buffer:

```markdown
# Recent Actions (last 2 hours)

1. [14:30] Opened Chrome, navigated to github.com (success)
2. [14:35] Created new repository "my-project" (success)
3. [14:40] Opened Terminal, ran `git clone` (success)
```

**Source:** Written in real-time during runs.
**Retention:** Last 2 hours, then archived to daily summary.

### 2.3 MemoryService: Core Implementation

New file: `OmniAgent/Services/MemoryService.swift`

```swift
actor MemoryService {
    static let shared = MemoryService()

    private let vaultPath: URL  // ~/Documents/Obsidian Vault/OmniAgent-Brain/

    // --- Read Operations ---

    /// Load the user profile for system prompt injection.
    func loadUserProfile() async -> String

    /// Load relevant memories for a given command.
    /// Uses keyword matching + recency weighting.
    func retrieveRelevantMemories(for command: String, tokenBudget: Int) async -> String

    /// Load recent action context (working memory).
    func loadRecentContext(maxEntries: Int) async -> String

    /// Load app-specific knowledge for detected apps in the command.
    func loadAppKnowledge(for appNames: [String]) async -> String

    /// Load task templates matching the command.
    func loadMatchingTemplates(for command: String) async -> [TaskTemplate]

    // --- Write Operations ---

    /// Record a completed run's outcome for episodic memory.
    func recordRunOutcome(_ result: Orchestrator.RunResult, command: String, toolEvents: [(tool: String, result: String?)]) async

    /// Record a verification rejection for learning.
    func recordVerificationRejection(command: String, score: Int, reason: String) async

    /// Record a user correction (when user cancels and retries differently).
    func recordUserCorrection(originalCommand: String, correctedCommand: String) async

    /// Update app knowledge based on successful interactions.
    func updateAppKnowledge(appName: String, insight: String) async

    /// Update user preferences based on observed patterns.
    func updatePreferences(key: String, value: String) async

    // --- Maintenance ---

    /// Consolidate episodic memories into patterns (run periodically).
    func consolidateMemories() async

    /// Generate daily summary from recent actions.
    func generateDailySummary() async
}
```

### 2.4 Memory Retrieval Strategy

Memory retrieval uses a **multi-signal ranking** approach, not full semantic search (to avoid embedding model dependencies):

```
Score = (keyword_match * 0.4) + (recency * 0.3) + (frequency * 0.2) + (success_rate * 0.1)
```

**Keyword matching:** Extract nouns, verbs, and app names from the command. Match against memory entry tags and content. Use the same keyword extraction for task templates.

**Recency weighting:** Memories from the last hour score 1.0, last day 0.7, last week 0.4, older 0.2.

**Frequency:** Memories referenced more often score higher (tracked via access count in YAML frontmatter).

**Success rate:** For task templates, higher success rates score higher.

### 2.5 Token Budget

The total context window for Claude Sonnet 4.6 is 200K tokens. Current system prompt + tools use approximately 2,500 tokens. Screenshot base64 uses ~100K tokens per image.

**Memory token budget: 4,000 tokens**, allocated as:

| Slot | Tokens | Content |
|---|---|---|
| User profile | 300 | Name, environment, top preferences |
| Recent context | 500 | Last 5 significant actions |
| Relevant memories | 1,500 | Top-ranked episodic + semantic memories |
| App knowledge | 800 | Knowledge for apps detected in command |
| Task template | 500 | Best-matching template if found |
| Failure avoidance | 400 | Relevant past failures to avoid |

If the budget is exceeded, items are dropped in reverse priority order (failure avoidance first, user profile last).

---

## Part 3: Context Injection Design

### 3.1 Modified System Prompt Structure

The system prompt should be restructured to include memory sections. Modify `ToolDefinitions.swift`:

```swift
static func systemPromptWithMemory(
    skillContext: String,
    memoryContext: String  // NEW: injected by MemoryService
) -> String {
    var prompt = systemPrompt

    if !memoryContext.isEmpty {
        prompt += """


        ## Your Memory
        You have persistent memory from previous sessions. Use this context to be more helpful.
        Do NOT repeat mistakes listed in your failure memory.

        \(memoryContext)
        """
    }

    if !skillContext.isEmpty {
        prompt += skillContext
    }

    return prompt
}
```

### 3.2 Memory Context Format

The memory context injected into the prompt should be structured for Claude to parse easily:

```
<memory>
<user_profile>
Name: [user name]. Prefers Chrome over Safari. Uses VS Code for coding.
Primary terminal: iTerm2. macOS 15.3, MacBook Pro M3.
</user_profile>

<recent_context>
Last session (2h ago): Opened Chrome, created GitHub repo, cloned in Terminal.
Before that (yesterday): Sent email to Alex about project deadline.
</recent_context>

<relevant_knowledge>
Chrome: Use Cmd+L to focus URL bar (more reliable than clicking).
GitHub: User's username is "suede". Repos at github.com/suede.
</relevant_knowledge>

<task_template match="0.85">
To open a website: Cmd+L to focus URL bar, type URL, press Return.
Average: 3 iterations. Success rate: 95%.
</task_template>

<avoid_mistakes>
- Do NOT click the bookmark bar when trying to reach the URL bar (failed 2026-02-19, score 45)
- In Terminal, always check pwd before running git commands (failed 2026-02-18)
</avoid_mistakes>
</memory>
```

### 3.3 Integration Points

#### 3.3.1 At Run Start: Load Memories

Modify `Orchestrator.startRun()` after skill matching (around line 142):

```swift
// Sprint 21: Load memory context for the system prompt
let memoryService = MemoryService.shared
let memoryContext = await memoryService.retrieveRelevantMemories(
    for: command,
    tokenBudget: 4000
)
await agentLoop.setMemoryContext(memoryContext)
```

#### 3.3.2 At Run End: Record Outcome

Modify `Orchestrator.runIterationLoop()` after the `RunResult` is created (around line 643):

```swift
// Sprint 21: Record run outcome for persistent memory
Task {
    await MemoryService.shared.recordRunOutcome(
        result,
        command: command,
        toolEvents: [] // Extract from journal
    )
}
```

#### 3.3.3 At Verification Rejection: Record Failure

Modify `Orchestrator.runIterationLoop()` at line 621:

```swift
// Sprint 21: Record verification failure for learning
Task {
    await MemoryService.shared.recordVerificationRejection(
        command: command, score: score, reason: reason
    )
}
```

#### 3.3.4 In AgentLoop: Use Memory Context

Add a new property and modify `executeIteration()`:

```swift
// In AgentLoop:
private var memoryContext: String = ""

func setMemoryContext(_ context: String) {
    self.memoryContext = context
}

// In executeIteration(), modify system prompt construction (line 359):
var systemPrompt = ToolDefinitions.systemPromptWithMemory(
    skillContext: skillContext,
    memoryContext: memoryContext
)
```

---

## Part 4: Self-Improvement Loop

### 4.1 Learning From Verification Rejections

When a verification rejection occurs, the system should:

1. **Record the failure** with command, score, reason, and the actions that led to it
2. **Extract a lesson** by analyzing the failure pattern
3. **Store as avoidance rule** in `learning/failures.md`

Implementation in `MemoryService`:

```swift
func recordVerificationRejection(command: String, score: Int, reason: String) async {
    let entry = """
    ## \(ISO8601DateFormatter().string(from: Date()))
    - **Command:** \(command)
    - **Score:** \(score)/100
    - **Reason:** \(reason)
    - **Lesson:** [auto-extracted or "Review needed"]
    """
    appendToFile("learning/failures.md", content: entry)
}
```

For automatic lesson extraction, after accumulating 3+ failures with similar commands, the system can use a lightweight Claude Haiku call to synthesize a lesson:

```
Given these failures:
1. "Open Chrome and go to github" - score 45 - "Wrong element clicked, ended up on bookmark bar"
2. "Navigate to github.com in Chrome" - score 38 - "URL bar not focused, typed into page"
3. "Go to github" - score 52 - "Clicked address bar but missed, hit tab bar"

What is the common failure pattern? Write a 1-sentence avoidance rule.
```

Result: "Always use Cmd+L keyboard shortcut to focus Chrome's URL bar instead of clicking, as click targeting on the URL bar is unreliable."

### 4.2 Learning From User Corrections

Track when a user cancels a run and immediately issues a modified command:

```swift
// In CommandGateway.submit(), detect correction patterns:
if let lastCommand = lastCompletedCommand,
   let lastResult = lastRunResult,
   !lastResult.success,
   Date().timeIntervalSince(lastResult.timestamp) < 120 {
    // User retried within 2 minutes of a failure
    await MemoryService.shared.recordUserCorrection(
        originalCommand: lastCommand,
        correctedCommand: command.text
    )
}
```

### 4.3 Learning From Repeated Similar Tasks

The SkillLoader already tracks repeated commands (line 159 in `Orchestrator.swift`). Enhance this:

1. After a task succeeds, extract the **action sequence** from the RunJournal
2. Compare with existing task templates for the same command pattern
3. If a template exists, update its success rate and refine steps
4. If no template exists and the pattern has succeeded 3+ times, create one

```swift
func maybeCreateTemplate(command: String, toolEvents: [(tool: String, result: String?)], score: Int) async {
    guard score >= 80 else { return }

    // Check if we have 3+ similar successful runs
    let similarRuns = findSimilarSuccessfulRuns(command: command, minScore: 80)
    guard similarRuns.count >= 3 else { return }

    // Extract common action sequence
    let commonSteps = extractCommonSteps(from: similarRuns)

    // Write template
    let template = buildTemplateMarkdown(
        trigger: extractTriggerPattern(from: similarRuns.map(\.command)),
        steps: commonSteps,
        successRate: Double(similarRuns.filter { $0.score >= 80 }.count) / Double(similarRuns.count)
    )

    writeFile("tasks/task-templates/\(slugify(command)).md", content: template)
}
```

### 4.4 Learning From Failed Attempts

When a run ends with `run.fail` or `run.stuck`:

1. Replay the journal to identify where things went wrong
2. Check if the failure mode matches a known pattern
3. If new, record it in `learning/failures.md` with context
4. If recurring (3+ times), escalate to a prominent avoidance rule

### 4.5 Periodic Consolidation

Run on app launch and every 4 hours:

1. **Episodic -> Semantic:** Scan `task-log.md` for patterns, extract app knowledge, update `knowledge/apps/`
2. **Failures -> Rules:** Cluster similar failures, generate avoidance rules
3. **Templates -> Skills:** When a template has 90%+ success rate over 10+ runs, suggest promoting it to a SkillLoader skill
4. **Prune stale memories:** Remove entries older than 90 days that haven't been accessed

---

## Part 5: Implementation Plan

### Phase 1: Foundation (Sprint 21)

**Files to create:**
- `OmniAgent/Services/MemoryService.swift` - Core memory service actor
- `OmniAgent/Services/MemoryRetrieval.swift` - Keyword extraction and ranking

**Files to modify:**
- `OmniAgent/Agent/AgentLoop.swift` - Add `memoryContext` property and `setMemoryContext()` method; modify `executeIteration()` to pass memory to system prompt
- `OmniAgent/Agent/ToolDefinitions.swift` - Add `systemPromptWithMemory()` static method
- `OmniAgent/Agent/Orchestrator.swift` - Load memories at run start, record outcomes at run end, record rejections

**Vault bootstrap:** On first launch, create the vault directory structure at `~/Documents/Obsidian Vault/OmniAgent-Brain/` with empty template files.

### Phase 2: Recording (Sprint 22)

- Record run outcomes after every run
- Record verification rejections
- Record user corrections via CommandGateway timing analysis
- Write daily summaries

### Phase 3: Retrieval & Injection (Sprint 23)

- Implement keyword-based memory retrieval
- Build memory context within token budget
- Inject into system prompt
- Validate that Claude uses the memory effectively

### Phase 4: Self-Improvement (Sprint 24)

- Failure pattern clustering
- Automatic lesson extraction via Haiku
- Task template generation from successful patterns
- Template-to-skill promotion pipeline
- Periodic consolidation daemon

---

## Part 6: Specific Code Changes

### 6.1 AgentLoop.swift Changes

Add new property at line 31:
```swift
/// Sprint 21: Memory context injected by the Orchestrator.
/// Included in the system prompt for the current run.
private var memoryContext: String = ""
```

Add setter after `setSkillContext()` at line 777:
```swift
/// Sprint 21: Set memory context to inject into the system prompt for this run.
func setMemoryContext(_ context: String) {
    self.memoryContext = context
}
```

Modify `executeIteration()` at line 359:
```swift
// Replace:
var systemPrompt = ToolDefinitions.systemPromptWithSkills(skillContext)
// With:
var systemPrompt = ToolDefinitions.systemPromptWithMemory(
    skillContext: skillContext,
    memoryContext: memoryContext
)
```

### 6.2 ToolDefinitions.swift Changes

Add new method after `systemPromptWithSkills()` at line 81:

```swift
/// Build the full system prompt with memory context and optional skill context.
static func systemPromptWithMemory(
    skillContext: String,
    memoryContext: String
) -> String {
    var prompt = systemPrompt

    if !memoryContext.isEmpty {
        prompt += """


        ## Your Memory
        You have persistent memory from previous interactions. Use this context to work more \
        efficiently and avoid repeating past mistakes. If the memory contains a task template \
        for this type of request, follow its steps as a starting point.

        \(memoryContext)
        """
    }

    if !skillContext.isEmpty {
        prompt += skillContext
    }

    return prompt
}
```

### 6.3 Orchestrator.swift Changes

In `startRun()`, after skill context injection (around line 156):

```swift
// Sprint 21: Load memory context
let memoryContext = await MemoryService.shared.retrieveRelevantMemories(
    for: command, tokenBudget: 4000
)
await agentLoop.setMemoryContext(memoryContext)
```

In `runIterationLoop()`, after successful completion (around line 643):

```swift
// Sprint 21: Record run outcome for persistent learning
Task.detached {
    await MemoryService.shared.recordRunOutcome(
        RunOutcome(
            runId: runId,
            command: command,
            success: passed,
            score: score,
            iterations: iteration,
            reason: reason
        )
    )
}
```

In `runIterationLoop()`, after verification rejection (around line 621):

```swift
// Sprint 21: Record verification failure
Task.detached {
    await MemoryService.shared.recordVerificationRejection(
        command: command, score: score, reason: reason
    )
}
```

### 6.4 MemoryService.swift (New File)

Core structure:

```swift
import Foundation

actor MemoryService {
    static let shared = MemoryService()

    private let vaultBase: URL
    private let maxTokenBudget = 4000
    private let tokenEstimateRatio = 4.0  // ~4 chars per token

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.vaultBase = home
            .appendingPathComponent("Documents/Obsidian Vault/OmniAgent-Brain")
    }

    // MARK: - Bootstrap

    /// Create the vault directory structure if it doesn't exist.
    func bootstrap() async {
        let fm = FileManager.default
        let dirs = [
            "", "identity", "tasks", "tasks/task-templates",
            "knowledge", "knowledge/apps", "learning", "context"
        ]
        for dir in dirs {
            let path = vaultBase.appendingPathComponent(dir)
            try? fm.createDirectory(at: path, withIntermediateDirectories: true)
        }
        // Create empty template files if they don't exist
        ensureFile("identity/user-profile.md", default: "# User Profile\n\n_No profile yet. Will be learned over time._\n")
        ensureFile("identity/preferences.md", default: "# Preferences\n\n_No preferences recorded yet._\n")
        ensureFile("tasks/task-log.md", default: "# Task Log\n\n")
        ensureFile("learning/failures.md", default: "# Failure Log\n\n")
        ensureFile("learning/corrections.md", default: "# User Corrections\n\n")
        ensureFile("learning/patterns.md", default: "# Learned Patterns\n\n")
        ensureFile("context/recent-actions.md", default: "# Recent Actions\n\n")
        ensureFile("context/daily-summary.md", default: "# Daily Summary\n\n")
    }

    // MARK: - Retrieval

    func retrieveRelevantMemories(for command: String, tokenBudget: Int = 4000) async -> String {
        var sections: [(priority: Int, label: String, content: String)] = []
        let charBudget = Int(Double(tokenBudget) * tokenEstimateRatio)

        // 1. User profile (highest priority)
        if let profile = readFile("identity/user-profile.md") {
            sections.append((priority: 1, label: "user_profile", content: truncate(profile, maxChars: 300)))
        }

        // 2. Recent context
        if let recent = readFile("context/recent-actions.md") {
            let lastEntries = extractLastEntries(recent, count: 5)
            if !lastEntries.isEmpty {
                sections.append((priority: 2, label: "recent_context", content: truncate(lastEntries, maxChars: 500)))
            }
        }

        // 3. App-specific knowledge (based on command keywords)
        let appNames = detectAppNames(in: command)
        for app in appNames {
            if let knowledge = readFile("knowledge/apps/\(app.lowercased()).md") {
                sections.append((priority: 3, label: "app_knowledge_\(app)", content: truncate(knowledge, maxChars: 400)))
            }
        }

        // 4. Matching task templates
        let templates = findMatchingTemplates(for: command)
        if let best = templates.first {
            sections.append((priority: 4, label: "task_template", content: truncate(best, maxChars: 500)))
        }

        // 5. Relevant failures to avoid
        if let failures = readFile("learning/failures.md") {
            let relevant = extractRelevantFailures(failures, for: command)
            if !relevant.isEmpty {
                sections.append((priority: 5, label: "avoid_mistakes", content: truncate(relevant, maxChars: 400)))
            }
        }

        // Assemble within budget
        var result = "<memory>\n"
        var usedChars = 20  // overhead for tags

        for section in sections.sorted(by: { $0.priority < $1.priority }) {
            let sectionText = "<\(section.label)>\n\(section.content)\n</\(section.label)>\n\n"
            if usedChars + sectionText.count <= charBudget {
                result += sectionText
                usedChars += sectionText.count
            }
        }

        result += "</memory>"
        return usedChars > 40 ? result : ""  // Return empty if no meaningful content
    }

    // MARK: - Recording

    func recordRunOutcome(_ outcome: RunOutcome) async {
        let entry = """

        ## \(ISO8601DateFormatter().string(from: Date()))
        - **Command:** \(outcome.command)
        - **Outcome:** \(outcome.success ? "Success" : "Failed") (score: \(outcome.score ?? 0))
        - **Iterations:** \(outcome.iterations)
        - **RunId:** \(outcome.runId)
        """
        appendToFile("tasks/task-log.md", content: entry)

        // Update recent actions
        let recentEntry = "- [\(timeString())] \(outcome.command) (\(outcome.success ? "success" : "failed"))\n"
        appendToFile("context/recent-actions.md", content: recentEntry)
    }

    func recordVerificationRejection(command: String, score: Int, reason: String) async {
        let entry = """

        ## \(ISO8601DateFormatter().string(from: Date()))
        - **Command:** \(command)
        - **Score:** \(score)/100
        - **Reason:** \(reason)
        """
        appendToFile("learning/failures.md", content: entry)
    }

    // MARK: - File Operations (private)

    private func readFile(_ relativePath: String) -> String? {
        let url = vaultBase.appendingPathComponent(relativePath)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func appendToFile(_ relativePath: String, content: String) {
        let url = vaultBase.appendingPathComponent(relativePath)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(content.utf8))
            try? handle.close()
        }
    }

    private func ensureFile(_ relativePath: String, default content: String) {
        let url = vaultBase.appendingPathComponent(relativePath)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // Helper stubs for the retrieval logic
    private func truncate(_ text: String, maxChars: Int) -> String { ... }
    private func extractLastEntries(_ text: String, count: Int) -> String { ... }
    private func detectAppNames(in command: String) -> [String] { ... }
    private func findMatchingTemplates(for command: String) -> [String] { ... }
    private func extractRelevantFailures(_ failures: String, for command: String) -> String { ... }
    private func timeString() -> String { ... }
}

struct RunOutcome {
    let runId: String
    let command: String
    let success: Bool
    let score: Int?
    let iterations: Int
}
```

---

## Part 7: Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Memory context bloats token usage | Hard 4,000-token budget with priority-based truncation |
| Stale/wrong memories mislead Claude | Confidence scoring + recency weighting + user can edit vault |
| Vault I/O slows down run start | Async loading; cache hot memories in MemoryService actor |
| Obsidian vault conflicts if user edits | Use append-only writes; read-then-write with file locks |
| Privacy: sensitive data in vault | Vault is local-only; never sent anywhere except Claude API (same as screenshots) |
| LLM consolidation calls add cost | Use Haiku for consolidation; batch and run infrequently |

---

## Part 8: Success Metrics

1. **Reduced repeated failures:** Same command should not fail the same way twice after memory records the failure
2. **Fewer iterations for known tasks:** Tasks the agent has done before should complete in fewer iterations
3. **User preference adherence:** After learning preferences, agent should use preferred apps without being told
4. **Template accuracy:** Task templates should have >85% success rate after 10+ executions
5. **Memory retrieval relevance:** >80% of injected memories should be relevant to the current command (measured by whether Claude references them in its reasoning)
