#!/bin/bash
# codesign-and-notarize.sh — Code sign, package, and notarize Cyclop One for distribution.
#
# Prerequisites:
#   1. Apple Developer account enrolled in the Developer Program
#   2. Developer ID Application certificate installed in Keychain
#   3. App-specific password stored in Keychain:
#      xcrun notarytool store-credentials "CyclopOneNotarize" \
#        --apple-id "YOUR_APPLE_ID" \
#        --team-id "YOUR_TEAM_ID" \
#        --password "APP_SPECIFIC_PASSWORD"
#
# Usage:
#   ./scripts/codesign-and-notarize.sh [--skip-build] [--skip-notarize]
#
# Environment variables:
#   SIGNING_IDENTITY  — Code signing identity (default: auto-detect "Developer ID Application")
#   NOTARY_PROFILE    — Notarytool keychain profile (default: "CyclopOneNotarize")
#   TEAM_ID           — Apple Team ID (required for notarization if not in profile)

set -euo pipefail

# Configuration
APP_NAME="Cyclop One"
BUNDLE_ID="com.cyclop.one.app"
SCHEME="CyclopOne"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/CyclopOne"
BUILD_DIR="$DERIVED_DATA/Build/Products/Release"
APP_PATH="$BUILD_DIR/${APP_NAME}.app"
DMG_NAME="CyclopOne.dmg"
OUTPUT_DIR="$(pwd)/dist"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-CyclopOneNotarize}"
ENTITLEMENTS="CyclopOne/CyclopOne.entitlements"

SKIP_BUILD=false
SKIP_NOTARIZE=false

for arg in "$@"; do
    case $arg in
        --skip-build) SKIP_BUILD=true ;;
        --skip-notarize) SKIP_NOTARIZE=true ;;
    esac
done

echo "=== Cyclop One Code Signing & Notarization ==="
echo "Bundle ID: $BUNDLE_ID"
echo "Signing Identity: $SIGNING_IDENTITY"
echo ""

# Step 1: Build Release
if [ "$SKIP_BUILD" = false ]; then
    echo ">>> Step 1: Building Release..."
    xcodebuild -scheme "$SCHEME" \
        -configuration Release \
        -derivedDataPath "$DERIVED_DATA" \
        clean build \
        CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
        CODE_SIGN_STYLE=Manual \
        ENABLE_HARDENED_RUNTIME=YES \
        2>&1 | tail -5

    if [ ! -d "$APP_PATH" ]; then
        echo "ERROR: Build failed — $APP_PATH not found"
        exit 1
    fi
    echo "    Build OK: $APP_PATH"
else
    echo ">>> Step 1: Skipped (--skip-build)"
fi

# Step 2: Code Sign with Hardened Runtime
echo ""
echo ">>> Step 2: Code signing with hardened runtime..."

# Sign all nested frameworks/dylibs first
find "$APP_PATH/Contents/Frameworks" -name "*.dylib" -o -name "*.framework" 2>/dev/null | while read -r item; do
    codesign --force --options runtime \
        --sign "$SIGNING_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        --timestamp \
        "$item" 2>/dev/null || true
done

# Sign the main app bundle
codesign --force --options runtime \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    "$APP_PATH"

echo "    Signed: $APP_PATH"

# Verify signature
codesign --verify --verbose=2 "$APP_PATH"
echo "    Verification OK"

# Check hardened runtime
codesign -d --entitlements - "$APP_PATH" 2>/dev/null | head -20
echo ""

# Step 3: Create DMG
echo ">>> Step 3: Creating DMG..."
mkdir -p "$OUTPUT_DIR"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
rm -f "$DMG_PATH"

# Create a temporary DMG folder
DMG_STAGE="$OUTPUT_DIR/dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP_PATH" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create -volname "Cyclop One" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_STAGE"

# Sign the DMG
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
echo "    DMG created: $DMG_PATH"

# Step 4: Notarize
if [ "$SKIP_NOTARIZE" = false ]; then
    echo ""
    echo ">>> Step 4: Submitting for notarization..."
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo ""
    echo ">>> Step 5: Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"
    echo "    Stapled: $DMG_PATH"

    # Verify Gatekeeper acceptance
    echo ""
    echo ">>> Step 6: Gatekeeper verification..."
    spctl --assess --type open --context context:primary-signature -v "$DMG_PATH"
    echo "    Gatekeeper: ACCEPTED"
else
    echo ""
    echo ">>> Steps 4-6: Skipped (--skip-notarize)"
fi

echo ""
echo "=== Done ==="
echo "Output: $DMG_PATH"
echo ""
echo "To test on a clean machine:"
echo "  1. Copy $DMG_NAME to the test machine"
echo "  2. Open the DMG and drag to Applications"
echo "  3. Launch — Gatekeeper should not block it"
echo "  4. Grant Accessibility and Screen Capture permissions when prompted"
