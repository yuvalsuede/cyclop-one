# Cyclop One — Privacy Policy

**Last updated:** February 24, 2026

Cyclop One is a macOS desktop automation agent that runs locally on your computer. This document explains what data is collected, how it is used, and what is sent to external services.

## What Data Is Collected

### Screenshots
Cyclop One captures screenshots of your screen to understand what is visible and take actions on your behalf. Screenshots are:
- Captured only during active task execution (never in the background)
- Compressed to JPEG (max 1280px) before transmission
- Sent to the Anthropic Claude API for visual analysis
- **Not stored permanently** — screenshots exist only in memory during the active run

### Accessibility Data
Cyclop One reads the accessibility tree (window titles, button labels, text fields) of the active application to understand the UI structure. This data is:
- Sent to the Anthropic Claude API as part of the task context
- Truncated to a maximum size before transmission
- Not stored permanently

### API Key
Your Anthropic API key is stored in the macOS Keychain and transmitted only to the Anthropic API endpoint (`api.anthropic.com`).

### Voice Input (Optional)
If push-to-talk is enabled, audio is captured only while the key is held and transcribed locally using Apple's Speech framework. Audio data is **never** sent to external servers.

## What Is Sent Externally

All external communication is with **Anthropic's Claude API** (`api.anthropic.com`) via HTTPS:
- Screenshots of your screen (JPEG, max 1280px)
- Accessibility tree summaries of active applications
- Your task commands and conversation history
- Tool call results (click coordinates, typed text, etc.)

**No data is sent to any other service.**

## What Is NOT Collected

- **No telemetry or analytics** — Cyclop One does not phone home
- **No crash reports** — crashes are logged locally only
- **No user tracking** — no cookies, no device IDs, no fingerprinting
- **No background capture** — screenshots only during active tasks
- **No persistent storage of screenshots** — they exist in memory only during the run
- **No data sharing with third parties** — only Anthropic receives task data

## Local Storage

Cyclop One stores the following data locally on your Mac:
- **Run journals** (`~/Library/Application Support/CyclopOne/runs/`) — task execution logs (text only, no screenshots)
- **Obsidian vault notes** (`~/Documents/Obsidian Vault/Cyclop One/`) — task summaries and memory (optional)
- **API key** — stored in macOS Keychain
- **Plugin data** (`~/.cyclopone/plugins/`) — user-installed plugin configurations

## Data Retention

- Run journals are automatically capped (oldest removed when limit exceeded)
- No screenshot data persists after a run completes
- Conversation history is held in memory only during the app session

## Your Control

- **Stop any task** at any time via the Stop button or Escape key
- **Revoke permissions** in System Settings > Privacy & Security
- **Delete all local data** by removing `~/Library/Application Support/CyclopOne/`
- **View all API calls** in the run journal logs

## Third-Party Services

| Service | Data Sent | Purpose |
|---------|-----------|---------|
| Anthropic Claude API | Screenshots, UI tree, commands | Task understanding and planning |

Review Anthropic's privacy policy at: https://www.anthropic.com/privacy

## Contact

For privacy questions: https://github.com/cyclop-one/cyclop-one/issues
