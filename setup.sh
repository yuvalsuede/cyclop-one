#!/bin/bash
# ──────────────────────────────────────────
# CyclopOne — Xcode Project Setup Script
# ──────────────────────────────────────────
#
# This script creates the Xcode project using xcodegen.
# If xcodegen is not installed, it offers to install it via Homebrew.

set -e

echo "👁️ Cyclop One Setup"
echo "─────────────────────────"

# Check for xcodegen
if ! command -v xcodegen &> /dev/null; then
    echo ""
    echo "⚠️  xcodegen is not installed."
    echo ""
    echo "xcodegen generates the .xcodeproj file from project.yml."
    echo ""
    read -p "Install xcodegen via Homebrew? (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if ! command -v brew &> /dev/null; then
            echo "❌ Homebrew not found. Please install Homebrew first:"
            echo "   https://brew.sh"
            exit 1
        fi
        echo "Installing xcodegen..."
        brew install xcodegen
    else
        echo ""
        echo "You can also create the project manually in Xcode:"
        echo "  1. Open Xcode → File → New → Project → macOS → App"
        echo "  2. Name it 'CyclopOne', set language to Swift, UI to SwiftUI"
        echo "  3. Drag all files from CyclopOne/ folder into the project"
        echo "  4. Disable App Sandbox in Signing & Capabilities"
        echo "  5. Set deployment target to macOS 14.0"
        echo "  6. Add Info.plist entries from CyclopOne/App/Info.plist"
        exit 0
    fi
fi

# Generate Xcode project
echo ""
echo "Generating Xcode project..."
cd "$(dirname "$0")"
xcodegen generate

echo ""
echo "✅ CyclopOne.xcodeproj created successfully!"
echo ""
echo "Next steps:"
echo "  1. Open CyclopOne.xcodeproj in Xcode"
echo "  2. Select your development team in Signing & Capabilities"
echo "  3. Build and run (⌘+R)"
echo "  4. Grant Screen Recording and Accessibility permissions when prompted"
echo "  5. Enter your Claude API key in the onboarding flow"
echo ""
echo "Hotkey: ⌘+Shift+A to toggle the agent panel"
echo ""
