# Cyclop One Plugin Authoring Guide

## Overview

Plugins extend Cyclop One with executable code. Unlike skills (which are markdown files injected into the agent's prompt), plugins are standalone programs that run as child processes. The agent calls a plugin tool the same way it calls built-in tools -- Cyclop One handles the plumbing.

Any language that reads stdin and writes stdout works: Bash, Python, Node.js, Ruby, Go, Rust, compiled Swift, or a static binary. Plugins add new tools the agent can call during a run, and each plugin can expose one or more tools.

Plugins live in `~/.cyclopone/plugins/`. Cyclop One discovers them on launch and hot-reloads when the directory changes.

---

## Quick Start: Hello World Plugin

This walkthrough creates a minimal plugin that adds a `hello_greet` tool.

### Step 1: Create the plugin directory

```bash
mkdir -p ~/.cyclopone/plugins/hello-world
```

The directory name must match the `name` field in your manifest.

### Step 2: Create `plugin.json`

```bash
cat > ~/.cyclopone/plugins/hello-world/plugin.json << 'EOF'
{
  "name": "hello-world",
  "version": "1.0.0",
  "description": "A minimal example plugin that greets the user.",
  "author": "you",
  "entrypoint": "main.sh",
  "permissions": [],
  "tools": [
    {
      "name": "hello_greet",
      "description": "Returns a greeting for the given name.",
      "input_schema": {
        "type": "object",
        "properties": {
          "name": {
            "type": "string",
            "description": "The name to greet"
          }
        },
        "required": ["name"]
      }
    }
  ]
}
EOF
```

### Step 3: Create the entrypoint script

```bash
cat > ~/.cyclopone/plugins/hello-world/main.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail

# Read the full JSON request from stdin
REQUEST=$(cat)

# Extract the input name using python3 (available on macOS)
NAME=$(/usr/bin/python3 -c "
import sys, json
req = json.loads(sys.stdin.read())
print(req['input'].get('name', 'World'))
" <<< "$REQUEST")

# Write JSON response to stdout
/usr/bin/python3 -c "
import json
print(json.dumps({'result': 'Hello, $NAME!', 'is_error': False}))
"
SCRIPT
```

### Step 4: Make it executable

```bash
chmod +x ~/.cyclopone/plugins/hello-world/main.sh
```

### Step 5: Test from the terminal

```bash
echo '{"tool":"hello_greet","input":{"name":"Alice"},"context":{}}' | \
  ~/.cyclopone/plugins/hello-world/main.sh
```

Expected output:

```json
{"result": "Hello, Alice!", "is_error": false}
```

### Step 6: Load into Cyclop One

Restart Cyclop One, or simply wait -- the PluginLoader watches `~/.cyclopone/plugins/` and hot-reloads when it detects changes. You will need to approve the plugin on first discovery before its tools become available to the agent.

---

## plugin.json Reference

The manifest file is the only required file (besides the entrypoint it references). It tells Cyclop One what the plugin does, what tools it provides, and what permissions it needs.

### Top-Level Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | `string` | Yes | Unique plugin identifier. Must match the directory name. Lowercase with hyphens, no spaces. Pattern: `^[a-z0-9][a-z0-9-]*$` |
| `version` | `string` | Yes | SemVer version string (e.g., `"1.0.0"`). |
| `description` | `string` | Yes | Human-readable description. Included in the tool definition sent to the agent. |
| `author` | `string` | No | Author name for attribution. |
| `entrypoint` | `string` | Yes | Relative path to the executable within the plugin directory. Can be a script or compiled binary. |
| `permissions` | `[string]` | Yes | Array of permission strings the plugin requires. Use `[]` if none are needed. See [Permissions](#permissions). |
| `tools` | `[Tool]` | Yes | Array of tool declarations. At least one tool is required. |

### Tool Declaration Fields

Each entry in the `tools` array describes one tool the agent can call.

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | `string` | Yes | Tool name exposed to the agent. Must be globally unique across all plugins and built-in tools. Convention: `snake_case`, prefixed with plugin context (e.g., `weather_forecast`). |
| `description` | `string` | Yes | Description sent to the agent. Explain what the tool does, when to use it, and what it returns. |
| `input_schema` | `object` | Yes | JSON Schema object describing the tool's input parameters. Follows standard JSON Schema format with `type`, `properties`, and `required` fields. |

### Example: Multi-Tool Manifest

```json
{
  "name": "note-manager",
  "version": "2.1.0",
  "description": "Create, search, and list notes stored as local files.",
  "author": "suede",
  "entrypoint": "main.py",
  "permissions": ["filesystem:read", "filesystem:write"],
  "tools": [
    {
      "name": "note_create",
      "description": "Create a new note with a title and body. Returns the file path.",
      "input_schema": {
        "type": "object",
        "properties": {
          "title": { "type": "string", "description": "Note title (used as filename)" },
          "body": { "type": "string", "description": "Note content in plain text or markdown" }
        },
        "required": ["title", "body"]
      }
    },
    {
      "name": "note_search",
      "description": "Full-text search across all notes. Returns matching titles and snippets.",
      "input_schema": {
        "type": "object",
        "properties": {
          "query": { "type": "string", "description": "Search term" },
          "limit": { "type": "integer", "description": "Max results. Default: 10" }
        },
        "required": ["query"]
      }
    }
  ]
}
```

---

## Execution Protocol

When the agent calls a plugin tool, Cyclop One launches the plugin's entrypoint as a child process, passes a JSON request to stdin, and reads a JSON response from stdout. That is the entire protocol.

### Request Format (stdin)

Cyclop One writes this JSON object to your process's stdin, then closes stdin:

```json
{
  "tool": "hello_greet",
  "input": {
    "name": "Alice"
  },
  "context": {
    "plugin_dir": "/Users/you/.cyclopone/plugins/hello-world",
    "data_dir": "/Users/you/.cyclopone/plugin-data/hello-world"
  }
}
```

| Field | Description |
|---|---|
| `tool` | The name of the tool being called (from your `tools` array). |
| `input` | The arguments the agent provided, matching your `input_schema`. |
| `context.plugin_dir` | Absolute path to your plugin's directory. |
| `context.data_dir` | Absolute path to a persistent data directory for your plugin. Created automatically. |

### Response Format (stdout)

Your process must write a single JSON object to stdout:

```json
{
  "result": "Hello, Alice!",
  "is_error": false
}
```

| Field | Type | Description |
|---|---|---|
| `result` | `string` | The text returned to the agent. This is what the agent sees as the tool result. |
| `is_error` | `bool` | Set to `true` if the tool call failed. The agent sees the error and can adapt. |

### Error Response

```json
{
  "result": "File not found: notes/todo.md",
  "is_error": true
}
```

Returning `is_error: true` does not crash anything. The agent receives the error message and can decide what to do next.

### Execution Constraints

| Constraint | Value | Notes |
|---|---|---|
| Timeout | 30 seconds | Process is terminated if it exceeds this. |
| Max stdout | 1 MB | Process is terminated if stdout exceeds this. |
| Max stderr | 64 KB | Captured for diagnostics but not returned to the agent. |
| Working directory | Plugin directory | Your process runs with cwd set to its own directory. |
| Exit code | 0 = success | Non-zero exit codes are reported as errors to the agent. |

### Environment Variables

Your process inherits the user's full environment, plus two plugin-specific variables:

| Variable | Value |
|---|---|
| `CYCLOPONE_PLUGIN_DIR` | Absolute path to the plugin's directory (same as `context.plugin_dir`). |
| `CYCLOPONE_DATA_DIR` | Absolute path to the plugin's persistent data directory (same as `context.data_dir`). |

---

## Permissions

Plugins declare their required permissions in the `permissions` array. This is an advisory declaration -- the user reviews and approves permissions when they first enable a plugin. In the current version, permissions are trust-based (not sandboxed at the kernel level).

### Permission Strings

| Permission | Grants | Examples |
|---|---|---|
| `filesystem:read` | Read files from disk | Config files, databases, caches |
| `filesystem:write` | Create or modify files on disk | Logs, data files, generated content |
| `network` | Make HTTP or socket connections | API calls, webhooks, downloads |
| `shell:exec` | Execute shell subcommands | Running `pbpaste`, `jq`, `sqlite3` |
| `clipboard` | Read or write the system clipboard | Clipboard manager plugins |
| `notifications` | Post macOS notifications | Alert the user of plugin events |

### How Approval Works

1. Cyclop One discovers a new plugin directory.
2. The PluginLoader reads the `permissions` array from `plugin.json`.
3. The user is presented with an approval dialog listing the requested permissions.
4. If approved, the plugin is enabled and its tools become available to the agent.
5. If denied, the plugin stays disabled. The user can approve it later.

Approval state is persisted -- you only approve a plugin once (unless you revoke and re-approve).

### Permission Tier Mapping

Plugins integrate with Cyclop One's existing permission tier system:

| Plugin Permissions | Tier |
|---|---|
| Only `filesystem:read` | Tier 1 (auto-approved) |
| `filesystem:write`, `clipboard`, `notifications` | Tier 2 (approve once per session) |
| `shell:exec`, `network` | Tier 2 (approve once per session) |
| `shell:exec` + `network` combined | Tier 2 with extra warning |

---

## Examples

### Bash Plugin (Simple)

A plugin that returns the current system uptime.

**`~/.cyclopone/plugins/system-uptime/plugin.json`**

```json
{
  "name": "system-uptime",
  "version": "1.0.0",
  "description": "Reports the current system uptime.",
  "entrypoint": "main.sh",
  "permissions": ["shell:exec"],
  "tools": [
    {
      "name": "system_uptime",
      "description": "Returns the current system uptime as a human-readable string.",
      "input_schema": {
        "type": "object",
        "properties": {},
        "required": []
      }
    }
  ]
}
```

**`~/.cyclopone/plugins/system-uptime/main.sh`**

```bash
#!/bin/bash
set -euo pipefail

UPTIME=$(uptime)

/usr/bin/python3 -c "
import json, sys
print(json.dumps({'result': sys.stdin.read().strip(), 'is_error': False}))
" <<< "$UPTIME"
```

### Python Plugin (Medium)

A plugin that generates random passwords.

**`~/.cyclopone/plugins/password-gen/plugin.json`**

```json
{
  "name": "password-gen",
  "version": "1.0.0",
  "description": "Generates random passwords with configurable length and character sets.",
  "entrypoint": "main.py",
  "permissions": [],
  "tools": [
    {
      "name": "password_generate",
      "description": "Generate a random password. Returns the password string.",
      "input_schema": {
        "type": "object",
        "properties": {
          "length": {
            "type": "integer",
            "description": "Password length. Default: 16"
          },
          "include_symbols": {
            "type": "boolean",
            "description": "Include special characters. Default: true"
          }
        },
        "required": []
      }
    }
  ]
}
```

**`~/.cyclopone/plugins/password-gen/main.py`**

```python
#!/usr/bin/env python3
import json
import sys
import string
import secrets

def main():
    request = json.load(sys.stdin)
    params = request.get("input", {})

    length = params.get("length", 16)
    include_symbols = params.get("include_symbols", True)

    chars = string.ascii_letters + string.digits
    if include_symbols:
        chars += string.punctuation

    password = "".join(secrets.choice(chars) for _ in range(length))

    json.dump({"result": password, "is_error": False}, sys.stdout)
    print()  # trailing newline

if __name__ == "__main__":
    main()
```

### Node.js Plugin (Advanced, Multiple Tools)

A plugin that manages a simple key-value store backed by a JSON file.

**`~/.cyclopone/plugins/kv-store/plugin.json`**

```json
{
  "name": "kv-store",
  "version": "1.0.0",
  "description": "A persistent key-value store. Set, get, delete, and list entries.",
  "author": "suede",
  "entrypoint": "main.js",
  "permissions": ["filesystem:read", "filesystem:write"],
  "tools": [
    {
      "name": "kv_set",
      "description": "Store a value under a key. Overwrites if the key exists.",
      "input_schema": {
        "type": "object",
        "properties": {
          "key": { "type": "string", "description": "The key to set" },
          "value": { "type": "string", "description": "The value to store" }
        },
        "required": ["key", "value"]
      }
    },
    {
      "name": "kv_get",
      "description": "Retrieve the value for a key. Returns an error if the key does not exist.",
      "input_schema": {
        "type": "object",
        "properties": {
          "key": { "type": "string", "description": "The key to retrieve" }
        },
        "required": ["key"]
      }
    },
    {
      "name": "kv_delete",
      "description": "Delete a key and its value. Returns an error if the key does not exist.",
      "input_schema": {
        "type": "object",
        "properties": {
          "key": { "type": "string", "description": "The key to delete" }
        },
        "required": ["key"]
      }
    },
    {
      "name": "kv_list",
      "description": "List all keys in the store.",
      "input_schema": {
        "type": "object",
        "properties": {},
        "required": []
      }
    }
  ]
}
```

**`~/.cyclopone/plugins/kv-store/main.js`**

```javascript
#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

function main() {
  let raw = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => (raw += chunk));
  process.stdin.on("end", () => {
    const request = JSON.parse(raw);
    const dataDir = request.context?.data_dir || process.env.CYCLOPONE_DATA_DIR || ".";
    const storePath = path.join(dataDir, "store.json");

    // Load existing store
    let store = {};
    if (fs.existsSync(storePath)) {
      store = JSON.parse(fs.readFileSync(storePath, "utf8"));
    }

    const { tool, input } = request;
    let result;
    let isError = false;

    switch (tool) {
      case "kv_set":
        store[input.key] = input.value;
        fs.mkdirSync(dataDir, { recursive: true });
        fs.writeFileSync(storePath, JSON.stringify(store, null, 2));
        result = `Set "${input.key}" = "${input.value}"`;
        break;

      case "kv_get":
        if (input.key in store) {
          result = store[input.key];
        } else {
          result = `Key not found: "${input.key}"`;
          isError = true;
        }
        break;

      case "kv_delete":
        if (input.key in store) {
          delete store[input.key];
          fs.writeFileSync(storePath, JSON.stringify(store, null, 2));
          result = `Deleted "${input.key}"`;
        } else {
          result = `Key not found: "${input.key}"`;
          isError = true;
        }
        break;

      case "kv_list":
        const keys = Object.keys(store);
        result = keys.length > 0 ? keys.join("\n") : "(empty store)";
        break;

      default:
        result = `Unknown tool: ${tool}`;
        isError = true;
    }

    console.log(JSON.stringify({ result, is_error: isError }));
  });
}

main();
```

---

## Testing

You can test any plugin from the terminal without running Cyclop One. The protocol is just JSON piped through stdin/stdout.

### Basic Pattern

```bash
echo '<JSON request>' | /path/to/entrypoint
```

### Test a Single Tool

```bash
echo '{"tool":"hello_greet","input":{"name":"World"},"context":{}}' | \
  ~/.cyclopone/plugins/hello-world/main.sh
```

### Test with Context

Supply realistic `context` values to test data directory behavior:

```bash
echo '{
  "tool": "kv_set",
  "input": {"key": "color", "value": "blue"},
  "context": {
    "plugin_dir": "'$HOME'/.cyclopone/plugins/kv-store",
    "data_dir": "/tmp/kv-store-test"
  }
}' | ~/.cyclopone/plugins/kv-store/main.js
```

### Validate JSON Output

Pipe through `jq` to confirm the response is valid JSON:

```bash
echo '{"tool":"system_uptime","input":{},"context":{}}' | \
  ~/.cyclopone/plugins/system-uptime/main.sh | jq .
```

### Test Error Handling

Send invalid or missing inputs to verify your error path:

```bash
echo '{"tool":"kv_get","input":{"key":"nonexistent"},"context":{}}' | \
  ~/.cyclopone/plugins/kv-store/main.js
# Expected: {"result":"Key not found: \"nonexistent\"","is_error":true}
```

### Check Executable Permission

```bash
ls -la ~/.cyclopone/plugins/hello-world/main.sh
# Should show -rwxr-xr-x or similar with execute bit set
```

---

## Troubleshooting

### Plugin not showing up

**Symptom:** Cyclop One does not list your plugin or its tools.

**Checks:**
1. Verify the directory is in the right place: `ls ~/.cyclopone/plugins/your-plugin/plugin.json`
2. Confirm the directory name matches the `name` field in `plugin.json` exactly.
3. Check that `plugin.json` is valid JSON: `python3 -m json.tool ~/.cyclopone/plugins/your-plugin/plugin.json`
4. Confirm all required fields are present: `name`, `version`, `description`, `entrypoint`, `permissions`, `tools`.
5. Confirm the `tools` array has at least one entry with `name`, `description`, and `input_schema`.
6. Check that you have approved the plugin. Unapproved plugins are discovered but not loaded.

### "Plugin entrypoint is not executable"

**Symptom:** Tool call returns an error about the entrypoint.

**Fix:**
```bash
chmod +x ~/.cyclopone/plugins/your-plugin/main.sh
```

For scripts, also verify the shebang line is correct (e.g., `#!/bin/bash`, `#!/usr/bin/env python3`, `#!/usr/bin/env node`).

### "Plugin returned invalid JSON"

**Symptom:** Tool call returns an error about invalid JSON.

**Checks:**
1. Run the plugin manually and inspect the raw output:
   ```bash
   echo '{"tool":"your_tool","input":{},"context":{}}' | ./main.sh
   ```
2. Make sure nothing else writes to stdout. Debug logging, print statements, and warnings must go to stderr, not stdout.
3. Confirm the output is a single JSON object with `result` (string) and `is_error` (boolean).
4. Check for trailing commas, unescaped characters, or encoding issues in the JSON.

### "Plugin timed out after 30s"

**Symptom:** Tool call returns a timeout error.

**Causes:**
- The script is waiting for user input (e.g., `read` without redirected stdin). Make sure you read all of stdin immediately (e.g., `REQUEST=$(cat)`).
- The script is doing something slow (large network request, heavy computation). Consider optimizing or breaking the work into smaller steps.
- The script hangs on a subprocess that never exits.

**Debugging:** Run the plugin manually with `time` to measure:
```bash
time echo '{"tool":"your_tool","input":{},"context":{}}' | ./main.sh
```

### "Plugin process failed (exit N)"

**Symptom:** Tool call returns a non-zero exit code error.

**Debugging:**
1. Run the plugin manually and check stderr:
   ```bash
   echo '{"tool":"your_tool","input":{},"context":{}}' | ./main.sh 2>/tmp/plugin_stderr.log
   cat /tmp/plugin_stderr.log
   ```
2. Common causes: missing dependencies (`python3`, `node`, `jq`), syntax errors in the script, file permission issues.

### Tool name collision

**Symptom:** Plugin loads but one or more tools are skipped.

**Fix:** Tool names must be globally unique across all plugins and built-in tools. Prefix your tool names with the plugin's context (e.g., `myplugin_action` instead of just `action`). Check Cyclop One's logs for collision warnings.

### Hot-reload not triggering

**Symptom:** Changes to plugin files are not picked up automatically.

**Workaround:** Restart Cyclop One. The file system watcher monitors the top-level `~/.cyclopone/plugins/` directory. Changes to files deep within a plugin subdirectory may not trigger a reload in all cases. Creating, renaming, or deleting the plugin directory itself will always trigger a reload.
