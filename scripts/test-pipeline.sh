#!/bin/bash
# Cyclop One Pipeline Diagnostic
# Tests each component independently

echo "=== Cyclop One Pipeline Test ==="
echo ""

# 1. Test screen capture
echo "[1/5] Testing screen capture..."
screencapture -x /tmp/cyclopone_test.png
if [ -f /tmp/cyclopone_test.png ]; then
    SIZE=$(stat -f%z /tmp/cyclopone_test.png)
    echo "  OK - Screenshot captured ($SIZE bytes)"
    rm /tmp/cyclopone_test.png
else
    echo "  FAIL - No screenshot captured. Check Screen Recording permissions."
fi

# 2. Test cliclick
echo "[2/5] Testing cliclick..."
if command -v cliclick &> /dev/null; then
    echo "  OK - cliclick found at $(which cliclick)"
else
    echo "  FAIL - cliclick not found. Run: brew install cliclick"
fi

# 3. Test Claude API
echo "[3/5] Testing Claude API key..."
API_KEY=$(security find-generic-password -s "com.cyclop.one.apikey" -a "claude-api-key" -w 2>/dev/null)
if [ -n "$API_KEY" ]; then
    echo "  OK - API key found in Keychain (${#API_KEY} chars)"
    # Quick API test
    RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "x-api-key: $API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d '{"model":"claude-haiku-4-5-20251001","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}' \
        https://api.anthropic.com/v1/messages)
    if [ "$RESPONSE" = "200" ]; then
        echo "  OK - Claude API responding (HTTP 200)"
    else
        echo "  WARN - Claude API returned HTTP $RESPONSE"
    fi
else
    echo "  FAIL - No API key in Keychain. Set it in Cyclop One Settings."
fi

# 4. Test OpenClaw
echo "[4/5] Testing OpenClaw..."
if command -v openclaw &> /dev/null; then
    VERSION=$(openclaw --version 2>/dev/null)
    echo "  OK - OpenClaw $VERSION"
    if [ -f ~/.openclaw/skills/cyclopone/SKILL.md ]; then
        echo "  OK - Cyclop One skill installed"
    else
        echo "  WARN - Cyclop One skill not found at ~/.openclaw/skills/cyclopone/SKILL.md"
    fi
else
    echo "  FAIL - OpenClaw not found. Run: npm i -g openclaw"
fi

# 5. Test accessibility
echo "[5/5] Testing accessibility permissions..."
# Try to read the frontmost app via osascript
APP=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)
if [ -n "$APP" ]; then
    echo "  OK - Accessibility working (frontmost app: $APP)"
else
    echo "  WARN - Accessibility may not be granted. Check System Settings."
fi

echo ""
echo "=== Done ==="
