# Cyclop One — System Architecture

> **Visual diagram:** [architecture.svg](./architecture.svg)

## Overview

Cyclop One is a vision-first autonomous macOS agent. Each iteration it captures a fresh screenshot, sends it to Claude, and executes the JSON action it receives back — no conversation history, ~2.2K tokens per iteration.

---

## System Diagram (Mermaid)

```mermaid
flowchart TD
    subgraph INPUTS["User Inputs"]
        UI[FloatingDot UI\nEye icon · Popover · Chat]
        HK[Global Hotkey\n⌘⇧A · Esc stop]
        TG[Telegram Bot\n/run · /stop · /screenshot]
        DN[DistributedNotification\nExternal CLI · OpenClaw]
    end

    subgraph GATEWAY["Command Routing"]
        AC[AgentCoordinator\n@MainActor · State · Confirmations]
        CG[CommandGateway\nQueue · LocalReply · TelegramReply]
    end

    subgraph ORCH["Orchestrator"]
        RC[Run Lifecycle\nstartRun · cancelRun]
        RJ[RunJournal\nEvent-sourced · JSONL]
        IC[Intent Classifier\nsimple / multi-step / complex]
        BM[Budget Manager\nMax iterations · Token cap]
    end

    subgraph LOOP["Reactive Loop Actor · DEFAULT"]
        P[① PERCEIVE\nScreenshot + AX tree]
        R[② REASON\nSystem prompt + skill context]
        D[③ DECIDE\nClaude Sonnet → JSON action]
        A[④ ACT\nToolExecutionManager]
        E[⑤ EVALUATE\nDone? Stuck? Budget?]
    end

    subgraph TOOLS["Tool Execution System"]
        SG[ActionSafetyGate\nHeuristic + LLM · safe/moderate/high/critical]
        UI2[UIInput\nclick · type · press_key · scroll]
        SC[ScreenCapture\nscreenshot · open_url · open_app]
        SH[Shell\nrun_applescript · run_shell_command]
        MH[Memory\nvault_read · vault_write · recall]
    end

    subgraph VERIFY["Verification"]
        LLM[LLM Vision\nClaude Haiku · Score 0–100]
        HEU[Heuristic Fallback\n30% visual · 30% struct · 40% output]
    end

    subgraph MEMORY["Memory System"]
        MS[MemoryService\nObsidian vault · 15K tokens\nEpisodic · Semantic · Working]
        PM[ProceduralMemory\nApp step sequences\nTrap patterns · Learning]
    end

    subgraph SKILLS["Skills System"]
        SR[SkillRegistry\nPre-compiled regex triggers]
        SK[Skill Files\n~/.cyclopone/skills/*.md\nTriggers · Steps · MaxIterations]
        PK[Plugin Packages\n~/.cyclopone/plugins/\nnpm packages]
    end

    subgraph SERVICES["External Services"]
        CA[ClaudeAPIService\nHaiku · Sonnet · Opus\nSSE streaming · TLS pinning]
        TS[TelegramService\nLong-poll · Auth · Voice]
        SCS[ScreenCaptureKit\nPID-filtered · 1280px]
        AXS[AccessibilityService\nAX tree · CGEvent]
    end

    UI & HK & TG & DN --> AC
    AC --> CG --> ORCH

    RC --> RJ
    IC --> BM
    ORCH --> LOOP

    P --> R --> D --> A --> E
    E -->|loop| P
    E -->|done| VERIFY

    A --> SG --> UI2 & SC & SH & MH

    VERIFY --> LLM
    LLM -->|fail| HEU
    VERIFY --> MEMORY

    SKILLS -.->|context injection| ORCH
    SR --- SK & PK

    SERVICES -.->|API calls| LOOP
    CA -.-> D
    SCS -.-> P
    AXS -.-> P & A
    TS -.-> TG

    MEMORY -.->|injection| ORCH
```

---

## Component Reference

### Orchestration

| Component | File | Responsibility |
|---|---|---|
| **Orchestrator** | `Agent/Orchestrator.swift` | Run lifecycle, intent classification, routing |
| **RunLifecycleManager** | `Agent/RunLifecycleManager.swift` | Cancellation, timing guards, budget warnings |
| **RunJournal** | `Agent/RunJournal.swift` | Event-sourced JSONL log → crash recovery |
| **CommandGateway** | `Agent/CommandGateway.swift` | Unified entry point, command queue, reply routing |
| **AgentCoordinator** | `AgentCoordinator.swift` | @MainActor bridge, SwiftUI state, confirmations |

### Core Agent Loop

| Component | File | Responsibility |
|---|---|---|
| **ReactiveLoopActor** | `Agent/ReactiveLoop/ReactiveLoopActor.swift` | **Default mode** — vision-first, no history, JSON actions |
| **ReactiveActionParser** | `Agent/ReactiveLoop/ReactiveActionParser.swift` | JSON parse, coord validation, fingerprint (10px rounding) |
| **ReactiveAgentState** | `Agent/ReactiveLoop/ReactiveAgentState.swift` | Progress log, fingerprint ring (8-window), stuck detection |
| **AgentLoop** | `AgentLoop.swift` | Legacy state-graph mode (non-default) |

### Tool System

| Component | File | Responsibility |
|---|---|---|
| **ToolExecutionManager** | `Agent/ToolExecutionManager.swift` | Dispatch, repetition detection, tool history |
| **ActionSafetyGate** | `Agent/ActionSafetyGate.swift` | Risk classification — heuristic → LLM fallback |
| **UIInputToolHandler** | `Agent/ToolHandlers/UIInputToolHandler.swift` | click, type_text, press_key (modifier combos), scroll, drag |
| **ScreenCaptureToolHandler** | `Agent/ToolHandlers/ScreenCaptureToolHandler.swift` | take_screenshot, open_application, open_url |
| **ShellToolHandler** | `Agent/ToolHandlers/ShellToolHandler.swift` | run_applescript, run_shell_command |
| **MemoryToolHandler** | `Agent/ToolHandlers/MemoryToolHandler.swift` | vault_read, vault_write, task_complete, recall |

### Safety Gate — Risk Levels

```
safe      → auto-proceed, no log
moderate  → auto-proceed, audit log
high      → user confirmation required
critical  → ALWAYS confirm, no session cache
```

Two-phase evaluation:
1. **Heuristic** (~0ms) — pattern matching on tool name + context
2. **LLM fallback** (~3s) — Claude Haiku vision scoring for uncertain cases

### Verification Engine

```
Post-action → Claude Haiku vision score (0–100)
  ≥70 → pass
  <70 → inject feedback, continue iteration

LLM failure → heuristic fallback:
  30% visual diff (pixel changes)
  30% structural diff (AX tree changes)
  40% output diff (tool result keywords)
```

---

## Skills System

### Skill File Format

```markdown
# SKILL: twitter-post

## Description
Post a tweet on X via the web.

## Triggers
- `(?i)\btweet\b`
- `(?i)\bpost\s+on\s+(x|twitter)\b`

## Steps
1. Take a screenshot to see current state.
2. If x.com is already open, skip to step 5.
3. Call open_url("https://x.com") — do NOT call open_application first.
4. Wait for the page to load.
5. Click the blue "Post" button in the left sidebar.
6. Type the tweet content.
7. Click "Post" to publish.

## Permissions
- network
- browser

## MaxIterations
20
```

### How Skills Are Loaded

```
App launch
  └─ SkillRegistry.loadAll()
       ├─ Built-in skills (13 packages)
       ├─ ~/.cyclopone/skills/*.md  (user skills)
       └─ ~/.cyclopone/plugins/*/   (plugin packages)
           └─ Pre-compile trigger regexes

User command arrives
  └─ SkillRegistry.match(command)
       └─ Matched skill context injected into system prompt
            ├─ Steps → guidance for the agent
            ├─ Permissions → override safety gate defaults
            └─ MaxIterations → cap the run budget
```

### Skill Storage Paths

| Path | Contents |
|---|---|
| `~/.cyclopone/skills/*.md` | User-authored markdown skill files |
| `~/.cyclopone/plugins/<name>/` | npm plugin packages with bundled skills |
| `~/.cyclopone/skills/<name>/skills/*.md` | Skills from installed packages |

---

## Memory System

### MemoryService (Obsidian Vault)

```
~/Documents/CyclopOne/
  Identity/user-profile.md    ← Always loaded
  Current Status.md           ← Always loaded
  Active Tasks.md             ← Always loaded
  Knowledge/apps/*.md         ← App-specific knowledge
  Tasks/task-log.md           ← Run history (episodic)
  Memory/*.md                 ← Facts & preferences (semantic)
  Context/recent-actions.md   ← Rolling window (working)
  Daily/YYYY-MM-DD.md         ← Session notes
```

**15K token budget** injected before each run. Core files always included; others retrieved by keyword relevance.

### ProceduralMemoryService

```
~/.cyclopone/procedural/<app_key>/<task_type>.json
```

**Lifecycle:**
1. `bootstrap()` at app launch
2. `setRunContext(app:, taskType:)` when run starts
3. `bufferLearningEvent()` during run (fire-and-forget)
4. `retrieveAndFormatForPrompt(command:)` → injected into system prompt
5. `consolidate(command:, success:, iterations:)` after run completes

**Learns:** step sequences, trap patterns, timing quirks per app.

---

## Data Flow: Command → Result

```
User: "tweet hello world"
  │
  ├─ CommandGateway receives command
  ├─ Orchestrator.startRun()
  │   ├─ RunJournal: log run.created
  │   ├─ SkillRegistry.match() → twitter-post skill found
  │   └─ MemoryService.inject() → 15K token context
  │
  └─ ReactiveLoopActor.run() [max 35 iterations]
      │
      ├─ Iter 1: Screenshot → "Chrome open, x.com home feed visible"
      │          Action: click Post button at (205, 688)
      │          SafetyGate: moderate (social site click) → auto-proceed
      │
      ├─ Iter 2: Screenshot → "Compose box open"
      │          Action: type_text "hello world"
      │
      ├─ Iter 3: Screenshot → "Text in compose box"
      │          Action: click Post button inside compose
      │
      └─ Iter 4: Screenshot → "Tweet posted, visible in feed"
                 Output: <complete>TOKEN</complete>
                 VerificationEngine: score 92/100 → PASS
                 ProceduralMemory: consolidate twitter step sequence
```

---

## External Services

| Service | Protocol | Models Used |
|---|---|---|
| **ClaudeAPIService** | SSE streaming · TLS SPKI pinning | Haiku (safety/verify) · Sonnet (agent) · Opus (planning) |
| **TelegramService** | Bot API long-poll | — |
| **ScreenCaptureKit** | macOS framework | — |
| **AccessibilityService** | AX API + CGEvent | — |
| **NSWorkspace** | macOS framework | open_url, open_application |
| **NSAppleScript** | AppleScript bridge | run_applescript |

---

## Storage Paths

```
~/Documents/CyclopOne/           ← Obsidian memory vault
~/.cyclopone/runs/<runId>/       ← Event-sourced run journals
~/.cyclopone/skills/             ← User skill files (.md)
~/.cyclopone/plugins/            ← Plugin packages
~/.cyclopone/procedural/         ← App-specific step memory
~/Library/Logs/CyclopOne/        ← Debug logs
```

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| **Vision-first reactive loop** | ~87% token reduction vs. state graph; simpler; more robust |
| **No conversation history** | Each iteration stateless; avoids context drift; cheaper |
| **aHash fingerprinting** | Catches ±2px coordinate drift; 8-window ring prevents false stuck |
| **Dual-mode verification** | LLM primary for accuracy; heuristic fallback ensures always succeeds |
| **Skills as markdown** | Human-readable; user-editable; no code required; regex-matched |
| **ProceduralMemory separate** | App-specific learning at `~/.cyclopone/` vs. general knowledge in vault |
| **NSWorkspace for open_url** | No Automation permission needed; avoids new Chrome windows |
| **agentIsPressingKeys flag** | CGEvent Escape synthesis would otherwise trigger emergency stop |
