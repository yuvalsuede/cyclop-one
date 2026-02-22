# Cyclop One

**An autonomous macOS desktop agent. The eye sees your screen, thinks with Claude, and acts.**

---

## What is Cyclop One?

Cyclop One is an AI-powered desktop automation agent for macOS. It uses Claude's vision capabilities to see your screen via ScreenCaptureKit, reasons about what it observes, and takes real actions — clicking buttons, typing text, running commands, and more. It is fully open source and built with zero third-party dependencies, relying entirely on Apple frameworks and the Claude API.

## Features

- **Vision-powered** — Claude sees your screen via ScreenCaptureKit
- **Full desktop control** — click, type, drag, scroll, keyboard shortcuts
- **Skills system** — extend with simple markdown files
- **Plugin architecture** — extend with any language via JSON-over-stdio
- **Memory system** — learns patterns across sessions
- **Voice input** — push-to-talk with local speech recognition
- **OpenClaw compatible** — control from Telegram, WhatsApp, Slack
- **Zero dependencies** — 100% Apple frameworks + Claude API

## Quick Start

```bash
# 1. Clone and build
git clone https://github.com/cyclop-one/cyclop-one.git
cd cyclop-one
xcodegen generate
open CyclopOne.xcodeproj
# Build and run (Cmd+R)

# 2. Set your Claude API key in the onboarding flow
# 3. Grant Accessibility + Screen Recording permissions
# 4. Start automating!
```

## Requirements

- macOS 14.0+
- Xcode 16+
- Claude API key from [console.anthropic.com](https://console.anthropic.com)

## Architecture

Cyclop One uses a Swift actor-based architecture for safe concurrency throughout the system:

| Component | Role |
|---|---|
| **AgentLoop** | Core perceive-reason-act cycle. Captures the screen, sends it to Claude, and executes the returned actions. |
| **Orchestrator** | Manages run lifecycle, exit lock, stuck detection, and verification. The agent cannot self-terminate — the Orchestrator decides when a run is complete. |
| **VerificationEngine** | Scores task completion using LLM vision with heuristic fallback. |
| **PluginLoader** | Discovers and runs external plugins via JSON-over-stdio. |
| **SkillLoader** | Injects skill definitions from markdown files into the agent's context. |
| **FloatingDot** | The circular on-screen indicator — the "eye" that shows agent state (idle, thinking, acting). |

## Skills

Skills are markdown files that teach Cyclop One how to perform specific tasks. Place them in `~/.cyclopone/skills/`:

```markdown
# Open Project

## Triggers
- "open project"
- "start working on {{project}}"

## Steps
1. Open Terminal
2. Run `cd ~/Projects/{{project}}`
3. Run `code .`

## Permissions
- filesystem
- app_launch
```

Cyclop One matches user intent against skill triggers and follows the defined steps, filling in parameters from context.

## Plugins

Plugins let you extend Cyclop One with any language. A plugin is an executable with a `plugin.json` manifest:

```json
{
  "name": "weather",
  "version": "1.0.0",
  "description": "Get current weather",
  "entrypoint": "./weather.py",
  "triggers": ["weather", "forecast"]
}
```

The plugin communicates over stdin/stdout using newline-delimited JSON. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full protocol specification.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code conventions, and how to submit changes.

## License

[MIT](LICENSE) — Copyright 2026, Cyclop One Contributors.
