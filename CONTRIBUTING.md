# Contributing to Cyclop One

Thanks for your interest in contributing to Cyclop One. This guide covers everything you need to get started.

## Development Setup

### Prerequisites

- macOS 14.0+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A Claude API key from [console.anthropic.com](https://console.anthropic.com)

### Build and Run

```bash
git clone https://github.com/cyclop-one/cyclop-one.git
cd cyclop-one
xcodegen generate
open CyclopOne.xcodeproj
```

Press **Cmd+R** to build and run. On first launch, you will be prompted to enter your Claude API key and grant Accessibility and Screen Recording permissions.

### Running Tests

```bash
xcodebuild -scheme CyclopOne -configuration Debug test
```

## Code Style

Cyclop One is built entirely with Apple frameworks. No third-party dependencies are allowed.

### Swift Conventions

- **Actors for concurrency** — all shared state lives in Swift actors. Never use `@unchecked Sendable` as a workaround for synchronization.
- **Logging** — use `NSLog("CyclopOne [ComponentName]: message")` for consistent, filterable logs.
- **Error handling** — propagate errors through `Result` or `ActionResult` types. Never silently swallow failures.
- **Naming** — follow Swift API Design Guidelines. Types are `PascalCase`, functions and variables are `camelCase`.

### Architecture Rules

- Each major component is a Swift actor with a clearly defined public interface.
- The Orchestrator owns the run lifecycle. Individual components do not decide when a run starts or stops.
- Screen coordinates must account for Retina scaling (`CGDisplayPixelsWide` vs `frame.size.width`).

## Creating Skills

Skills are markdown files placed in `~/.cyclopone/skills/`. Each file defines a reusable task.

### Skill Format

```markdown
# Skill Name

## Triggers
- "phrase that activates this skill"
- "another phrase with {{parameter}}"

## Steps
1. Description of first action
2. Description of second action using {{parameter}}

## Permissions
- filesystem
- app_launch
- network
```

### Fields

| Field | Required | Description |
|---|---|---|
| **Triggers** | Yes | Natural language phrases that activate the skill. Use `{{name}}` for parameters. |
| **Steps** | Yes | Ordered list of actions the agent should take. |
| **Permissions** | No | Required permission tiers. If omitted, defaults to the lowest tier. |

### Tips

- Keep triggers conversational. The agent uses fuzzy matching.
- Steps should be concrete and unambiguous. Think of them as instructions for a capable but literal assistant.
- Test your skill by saying one of the trigger phrases to the agent.

## Creating Plugins

Plugins extend Cyclop One with external executables that communicate over JSON-over-stdio.

### Plugin Structure

```
~/.cyclopone/plugins/my-plugin/
  plugin.json
  my-plugin         # or my-plugin.py, my-plugin.js, etc.
```

### plugin.json Format

```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "description": "What this plugin does",
  "entrypoint": "./my-plugin",
  "triggers": ["keyword", "another keyword"],
  "permissions": ["filesystem"]
}
```

### JSON-over-stdio Protocol

The agent launches your plugin executable and communicates via newline-delimited JSON on stdin/stdout.

**Request** (agent sends to plugin stdin):

```json
{"type": "invoke", "action": "run", "params": {"query": "user input"}}
```

**Response** (plugin writes to stdout):

```json
{"type": "result", "status": "success", "data": {"output": "result text"}}
```

**Error response**:

```json
{"type": "result", "status": "error", "message": "what went wrong"}
```

Your plugin must read one JSON line from stdin, process it, write one JSON line to stdout, and exit. The agent handles lifecycle management.

## Pull Request Process

1. **Fork** the repository and create a feature branch from `main`.
2. **Make your changes.** Keep commits focused and well-described.
3. **Test** — the project must build successfully (`xcodebuild -scheme CyclopOne build`). If you are changing agent behavior, manually test with a real run.
4. **Open a PR** with a clear description of what changed and why. Include screenshots or logs if the change affects UI or agent behavior.
5. A maintainer will review your PR. Address any feedback, then it will be merged.

### PR Checklist

- [ ] Build succeeds with no new warnings
- [ ] No third-party dependencies added
- [ ] Logging uses `NSLog("CyclopOne [Component]: ...")` format
- [ ] Actors used for any new shared state
- [ ] Skill or plugin documentation updated (if applicable)

## Issues

### Bug Reports

Please include:

- macOS version
- Steps to reproduce
- Expected vs. actual behavior
- Relevant logs from Console.app (filter by `CyclopOne`)

### Feature Requests

Feature requests are welcome. Open an issue describing the use case, not just the solution. We value understanding the problem before jumping to implementation.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
