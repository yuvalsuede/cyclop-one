<!-- MEMORY:START -->
# OmniAgent

_Last updated: 2026-02-23 | 10 active memories, 10 total_

## Architecture
- Created new files Orchestrator.swift and RunJournal.swift to manage agent run lifecycle and logging, following Babysi... [file-structure, design-pattern]
- Preparing for Sprint 3 which will focus on creating an Orchestrator skeleton using a Babysitter-style run manager [sprint3, architecture]
- 20-sprint roadmap for OmniAgent v2 divided into 6 phases, starting with Foundation sprints focused on fixing critical... [roadmap, project-planning]

## Key Decisions
- Planning to modernize Claude API with retry logic, version updates, max_tokens, and prompt injection defenses [api, security]

## Patterns & Conventions
- Stop button UI accessibility issue when window has hitTest interference, requiring a separate NSWindow overlay or cus... [ui, accessibility]

## Gotchas & Pitfalls
- ScreenCaptureService uses mainDisplay.width/height which returns physical pixels on Retina displays, causing 2x coord... [graphics, display, coordinate-system]
- CheckedContinuation in AgentCoordinator can deadlock if no cancellation handler or timeout is implemented, causing Ag... [concurrency, bug, swift]

## Current Progress
- Completed Sprint 3 skeleton implementation of Orchestrator with refactored AgentLoop, adding RunJournal and integrati... [sprint, implementation]
- Created key files for Sprint 2: PermissionClassifier.swift, updated AgentState.swift, ActionExecutor.swift, and Claud... [development, sprint2]
- Completed Sprint 1 code and initiated Sprint 2 focusing on Tiered Autonomy & API Upgrades [sprint, roadmap]

_For deeper context, use memory_search, memory_related, or memory_ask tools._
<!-- MEMORY:END -->

## Obsidian Vault

**IMPORTANT:** Every session, everything you do, discuss, fix, decide, or discover MUST also be written to the Obsidian vault at:

```
~/Documents/Obsidian Vault/Cyclop One/
```

### Rules
- At the start of each session, create a daily note in `Daily/YYYY-MM-DD.md` with a session summary
- When fixing bugs or making changes, update the relevant component note in `Components/`
- When making architectural decisions, append to `Decisions/Decision Log.md`
- When discovering or fixing issues, update `Known Issues.md`
- When completing milestones, update `Current Status.md`
- All notes should use `[[wikilinks]]` to connect to related pages
- Keep notes concise and factual — this is a living knowledge base, not a journal

### Vault Structure
```
Cyclop One/
  Cyclop One Home.md          <- Hub page
  Current Status.md           <- What works, what's next
  Known Issues.md             <- Active bugs and debt
  Architecture/               <- System design docs
  Components/                 <- Per-file documentation
  Sprints/                    <- Sprint history
  Decisions/                  <- Architectural decision log
  Daily/                      <- Session notes (YYYY-MM-DD.md)
```
