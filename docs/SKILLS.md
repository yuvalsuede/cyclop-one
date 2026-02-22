# Cyclop One Skills Authoring Guide

## Overview

Skills are markdown files stored at `~/.cyclopone/skills/*.md` that define reusable
tool sequences triggered by regex patterns against user commands. When a user's command
matches a skill's trigger pattern, the skill's steps are injected into the agent's
system prompt as additional context, guiding the agent through a predefined sequence
of actions.

Skills allow you to:

- Encode repeatable workflows so Cyclop One executes them consistently
- Define permission tier overrides for tools used within a skill
- Set iteration limits to prevent runaway execution
- Share workflows as portable `.md` files

Cyclop One ships with several built-in skills (web-search, file-organizer,
app-launcher). You can extend the system by writing your own.

---

## Skill File Format

Each skill is a single markdown file following a structured format with specific
section headers. The parser reads the file line-by-line, extracting content under
each `## Section` heading.

### Required Structure

```markdown
# SKILL: <name>

## Description
<What the skill does, in one or more lines.>

## Triggers
- `<regex pattern 1>`
- `<regex pattern 2>`

## Steps
1. <First action the agent should take>
2. <Second action>
3. <Third action>

## Permissions
- <tool_name>: <tier>

## MaxIterations
<number>
```

### Section Reference

| Section | Required | Description |
|---------|----------|-------------|
| `# SKILL: <name>` | Yes | The skill name. Must start with `# SKILL:` exactly. |
| `## Description` | No | Human-readable explanation. Displayed in skill listings. |
| `## Triggers` | Yes | One or more regex patterns that activate this skill. |
| `## Steps` | No | Ordered actions for the agent to follow. |
| `## Permissions` | No | Tool-to-tier mappings that override defaults. |
| `## MaxIterations` | No | Maximum agent iterations. Defaults to 20 if omitted. |

**Minimum viable skill:** A file must have a `# SKILL:` header and at least one
trigger pattern. Without both, the parser rejects the file.

### File Naming

The filename should be a kebab-case version of the skill name with a `.md` extension:

```
open-calculator.md
screenshot-annotate.md
deploy-project.md
```

---

## Trigger Regex Guide

Triggers determine when a skill activates. Each trigger is a regular expression
tested against the user's command.

### How Matching Works

1. The user's command is **lowercased** and **trimmed** of whitespace.
2. Each enabled skill's trigger patterns are tested in order.
3. If **any** trigger in a skill matches, the skill is selected.
4. Multiple skills can match a single command; all matched skills are injected.
5. Regex matching uses `NSRegularExpression` with the `.caseInsensitive` option,
   so patterns are always case-insensitive regardless of inline flags.

### Writing Trigger Patterns

Triggers are listed as bullet items under `## Triggers`, optionally wrapped in
backticks:

```markdown
## Triggers
- `(?i)\bopen\s+calculator\b`
- `(?i)\blaunch\s+calc(ulator)?\b`
```

Both of these formats are accepted:

```markdown
- `pattern`      (backtick-wrapped, recommended for readability)
- pattern         (plain text, also valid)
```

The `*` bullet marker also works:

```markdown
* `pattern`
```

### Regex Syntax Quick Reference

| Pattern | Matches |
|---------|---------|
| `\b` | Word boundary |
| `\s+` | One or more whitespace characters |
| `\w+` | One or more word characters |
| `(foo\|bar)` | Either "foo" or "bar" |
| `(?:group)` | Non-capturing group |
| `(?i)` | Inline case-insensitive flag (redundant but harmless) |
| `.+` | One or more of any character |
| `.*` | Zero or more of any character |

### Template Parameter Capture with `{{param}}`

You can use named capture groups in your triggers to extract parameters from the
user's command. While the current SkillLoader does not automatically substitute
captured groups into steps, the convention `{{param}}` documents intent and
prepares for future template expansion:

```markdown
## Triggers
- `(?i)\bdeploy\s+(?<project>\w+)\s+to\s+(?<env>staging|production)\b`
```

This communicates that the skill expects a project name and an environment, which
the agent will extract from the user's natural language command.

### Tips for Effective Triggers

- **Be specific enough** to avoid false positives but broad enough for natural
  phrasing. Test your regex against several example commands.
- **Use word boundaries** (`\b`) to prevent partial word matches (e.g., `\bopen\b`
  won't match "reopen").
- **Provide multiple triggers** for different phrasings: "open calculator",
  "launch calculator", "start calculator".
- **Avoid overly greedy patterns** like `.*` at the start; they match everything.

---

## Step Writing Guide

Steps define the sequence of actions the agent should follow when a skill is
triggered. They are injected into the system prompt under a structured
`## Available Skills` section.

### Format

Steps are written as a numbered list under `## Steps`:

```markdown
## Steps
1. Open the Calculator app using the open_application tool
2. Wait for the app to finish launching
3. Take a screenshot to verify Calculator is visible
```

Bullet-style steps are also accepted:

```markdown
## Steps
- Open the Calculator app using the open_application tool
- Wait for the app to finish launching
```

Numbered steps are recommended for clarity since order matters.

### Writing Effective Steps

**Be specific about tools.** Name the exact tool the agent should use:

```markdown
1. Open Safari using the open_application tool
```

Not:

```markdown
1. Open Safari
```

**Be specific about targets.** Describe what to click, where to type, what to look for:

```markdown
2. Click the address bar at the top center of the Safari window
3. Type the search query using type_text
4. Press Return using press_key
```

**Include verification steps.** Screenshots let the agent confirm each action succeeded:

```markdown
5. Take a screenshot to verify the search results are displayed
```

**Keep steps atomic.** Each step should describe one action. Don't combine multiple
actions into a single step.

**Reference the user's command.** When a step depends on user input, phrase it
generically:

```markdown
3. Type the user's search query using type_text
```

The agent will infer the actual value from the user's original command.

---

## Permissions Section

The Permissions section lets you override the default permission tier for tools
used within a skill. This controls how much autonomy the agent has when executing
specific tool calls.

### Permission Tiers

| Tier | Behavior |
|------|----------|
| `tier1` | Auto-approved. The agent executes without asking. |
| `tier2` | Requires one-time approval. The user is prompted once per session. |
| `tier3` | Always requires approval. The user must confirm every execution. |

### Format

```markdown
## Permissions
- open_application: tier1
- run_shell_command: tier2
- run_applescript: tier3
```

Each line maps one tool name to one tier. Use the exact tool name as registered
in the action executor.

### When to Use Permission Overrides

- **Escalate to tier1** for tools that are safe in context. For example, if a
  skill only opens Calculator, `open_application: tier1` avoids a confirmation
  prompt for something benign.
- **Restrict to tier3** for destructive operations. A skill that deletes files
  should use `run_shell_command: tier3` to force explicit approval on every call.
- **Omit if defaults are fine.** If you don't list a tool, it uses the system
  default tier.

If the skill uses no tools that need overrides, use:

```markdown
## Permissions
- (none)
```

---

## MaxIterations

The `## MaxIterations` section sets an upper bound on how many perceive-reason-act
loops the agent may execute for this skill. This prevents runaway execution.

```markdown
## MaxIterations
15
```

- If omitted, defaults to **20**.
- Set lower for simple skills (5-10 for quick tasks).
- Set higher for complex multi-step workflows (up to 25).
- The value must be a single integer on its own line under the heading.

---

## Examples

### Simple: Open Calculator

A minimal skill that opens Calculator and verifies it launched.

**File:** `~/.cyclopone/skills/open-calculator.md`

```markdown
# SKILL: open-calculator

## Description
Open the macOS Calculator application.

## Triggers
- `(?i)\bopen\s+calculator\b`

## Steps
1. Open Calculator using the open_application tool
2. Take a screenshot to verify Calculator is visible on screen

## Permissions
- open_application: tier1

## MaxIterations
5
```

### Medium: Screenshot and Annotate

A skill that captures the current screen and opens it in Preview for annotation.

**File:** `~/.cyclopone/skills/screenshot-annotate.md`

```markdown
# SKILL: screenshot-annotate

## Description
Take a screenshot of the current screen and open it in Preview for annotation.

## Triggers
- `(?i)\bscreenshot\s+(and\s+)?(annotate|mark\s*up|edit)\b`
- `(?i)\bcapture\s+screen\s+(and\s+)?(annotate|edit)\b`
- `(?i)\btake\s+a?\s*screenshot.*(annotate|mark\s*up)\b`

## Steps
1. Take a screenshot of the full screen using the screenshot tool
2. Save the screenshot to ~/Desktop/screenshot-temp.png
3. Open the saved screenshot in Preview using: open -a Preview ~/Desktop/screenshot-temp.png
4. Wait for Preview to finish launching and take a screenshot to verify
5. Activate the Markup toolbar in Preview by clicking the markup icon or using Cmd+Shift+A

## Permissions
- screenshot: tier1
- run_shell_command: tier2
- open_application: tier1

## MaxIterations
15
```

### Advanced: Deploy Project

A skill with template parameter capture, multiple triggers, and restrictive
permission overrides for a deployment workflow.

**File:** `~/.cyclopone/skills/deploy-project.md`

```markdown
# SKILL: deploy-project

## Description
Build and deploy the current project to the specified environment. Supports
staging and production targets with safety checks.

## Triggers
- `(?i)\bdeploy\s+(\w+)\s+to\s+(staging|production|prod)\b`
- `(?i)\bship\s+(\w+)\s+to\s+(staging|production|prod)\b`
- `(?i)\bpush\s+(\w+)\s+to\s+(staging|production|prod)\b`
- `(?i)\brelease\s+(\w+)\b`

## Steps
1. Identify the project name and target environment from the user's command
2. Run the project's test suite using run_shell_command to verify all tests pass
3. If tests fail, report the failures and stop execution — do not deploy broken code
4. Run the build command for the project using run_shell_command
5. If the target is production, ask the user to confirm before proceeding
6. Execute the deployment command for the target environment
7. Take a screenshot or read command output to verify the deployment succeeded
8. Report the deployment status including environment, version, and any warnings

## Permissions
- run_shell_command: tier3
- run_applescript: tier3

## MaxIterations
25
```

In this example, all shell commands require explicit approval (`tier3`) because
deployments are high-stakes operations.

---

## Self-Authoring

Cyclop One includes an automatic pattern detection system that watches your
commands and suggests new skills when it detects repeated behavior.

### How It Works

1. **Command recording.** Every command you send is stored in a rolling history
   of the last 100 commands.
2. **Similarity detection.** The system compares recent commands using word-overlap
   similarity (Jaccard index). It examines a window of the 30 most recent commands.
3. **Threshold check.** When 3 or more commands within that window share at least
   60% word overlap, a pattern is detected.
4. **Existing skill check.** If an existing enabled skill already matches the
   command, no suggestion is made.
5. **Suggestion generation.** The system extracts common words across the similar
   commands, builds a trigger regex from them, and proposes a skill with a
   generated name, description, and starter steps.

### What You See

When a pattern is detected, Cyclop One presents a suggestion like:

> "I've noticed you frequently run commands like: 'open Safari and search for...',
> 'search the web for...'. Would you like me to create a skill for this?"

If you approve, the skill file is written to `~/.cyclopone/skills/` and
immediately loaded via hot-reload.

### Tuning Self-Authored Skills

Auto-generated skills are intentionally minimal:

- **Triggers** are built from common words using lookahead patterns.
- **Steps** default to generic "execute the command" + "verify with screenshot".
- **MaxIterations** defaults to 10.

After a skill is created, open the `.md` file and refine:

- Add more specific triggers
- Write detailed, tool-specific steps
- Set appropriate permission tiers
- Adjust MaxIterations for the task complexity

---

## Installation

### Adding a New Skill

1. Create a `.md` file following the format described above.
2. Save it to `~/.cyclopone/skills/`.
3. Skills are loaded at app startup. They are also hot-reloaded when files change,
   so new skills take effect without restarting the app.

### Verifying a Skill Loaded

After adding a skill, you can confirm it loaded by checking the skill list in the
app. The listing shows each skill's name, status (ON/OFF), source (built-in or
custom), description, and triggers.

### Disabling a Skill

Skills can be toggled on or off at runtime without deleting the file. Disabled
skills are remembered across sessions.

### Directory Structure

```
~/.cyclopone/
  skills/
    web-search.md          (built-in, auto-installed)
    file-organizer.md      (built-in, auto-installed)
    app-launcher.md        (built-in, auto-installed)
    open-calculator.md     (your custom skill)
    deploy-project.md      (your custom skill)
```

Built-in skill files are installed to disk on first launch so you can inspect and
learn from them. However, editing a built-in skill file has no effect -- the app
loads built-in skills from code and skips disk files with the same name. To
customize a built-in skill, copy it to a new file with a different `# SKILL:` name.

### Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| Skill not loading | Missing `# SKILL:` header | Ensure the first heading is exactly `# SKILL: name` |
| Skill not loading | No triggers defined | Add at least one trigger under `## Triggers` |
| Skill not triggering | Regex too specific | Test your pattern against the lowercased, trimmed command |
| Skill not triggering | Skill is disabled | Check the skill list and re-enable it |
| Wrong skill triggers | Regex too broad | Use word boundaries and be more specific |
| Too many iterations | MaxIterations too high | Lower the value in `## MaxIterations` |
| Permission prompts | Tier not overridden | Add the tool to `## Permissions` with the desired tier |
