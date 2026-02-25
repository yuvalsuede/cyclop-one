#!/bin/bash
# create-dmg.sh — Package Cyclop One into a distributable DMG.
#
# Usage:
#   ./scripts/create-dmg.sh                    # Build Release + package
#   ./scripts/create-dmg.sh --debug            # Package from Debug build
#   ./scripts/create-dmg.sh --skip-build       # Package existing build
#   ./scripts/create-dmg.sh --app /path/to.app # Package specific .app
#
# Output: dist/CyclopOne-<version>.dmg

set -euo pipefail

APP_NAME="Cyclop One"
SCHEME="CyclopOne"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/CyclopOne"
OUTPUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/dist"
CONFIG="Release"
SKIP_BUILD=false
CUSTOM_APP=""

for arg in "$@"; do
    case $arg in
        --debug) CONFIG="Debug" ;;
        --skip-build) SKIP_BUILD=true ;;
        --app)
            shift
            CUSTOM_APP="$1"
            SKIP_BUILD=true
            ;;
    esac
    shift 2>/dev/null || true
done

BUILD_DIR="$DERIVED_DATA/Build/Products/$CONFIG"
APP_PATH="${CUSTOM_APP:-$BUILD_DIR/${APP_NAME}.app}"

echo "=== Cyclop One DMG Packager ==="

# Step 1: Build
if [ "$SKIP_BUILD" = false ]; then
    echo ">>> Building ($CONFIG)..."
    xcodebuild -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -derivedDataPath "$DERIVED_DATA" \
        build 2>&1 | tail -3

    if [ ! -d "$APP_PATH" ]; then
        echo "ERROR: Build failed — $APP_PATH not found"
        exit 1
    fi
fi

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App not found at $APP_PATH"
    exit 1
fi

# Extract version from Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0.1.0")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1")
DMG_NAME="CyclopOne-${VERSION}.dmg"

echo "    App: $APP_PATH"
echo "    Version: $VERSION (build $BUILD)"
echo ""

# Step 2: Create staging directory
echo ">>> Staging DMG contents..."
mkdir -p "$OUTPUT_DIR"
STAGE_DIR="$OUTPUT_DIR/.dmg-stage"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

# Copy app
cp -R "$APP_PATH" "$STAGE_DIR/"

# Create Applications symlink
ln -s /Applications "$STAGE_DIR/Applications"

# Step 3: Create DMG
echo ">>> Creating DMG..."
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
rm -f "$DMG_PATH"

# Create compressed DMG
hdiutil create \
    -volname "Cyclop One" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

# Cleanup staging
rm -rf "$STAGE_DIR"

# Step 4: Report
DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo ""
echo "=== DMG Created ==="
echo "  Path: $DMG_PATH"
echo "  Size: $DMG_SIZE"
echo "  Volume: Cyclop One"
echo "  Version: $VERSION"
echo ""
echo "To install: Open DMG, drag Cyclop One to Applications"
echo "To sign: ./scripts/codesign-and-notarize.sh --skip-build"
