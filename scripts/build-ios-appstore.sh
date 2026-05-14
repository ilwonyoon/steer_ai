#!/usr/bin/env bash
# Build and export a signed iOS .ipa for App Store Connect submission.
#
# Usage:
#   bash scripts/build-ios-appstore.sh
#
# Prerequisites (one-time):
#   - Xcode with an Apple Distribution certificate in the keychain
#   - Signed into Xcode with the Apple ID for team LG7667PAS6
#   - apps/ios/Steer.xcodeproj generated from project.yml
#     (run: cd apps/ios && xcodegen generate)
#
# Output:
#   .build/ios-appstore/Steer.ipa  ← upload this to App Store Connect
#
# After this script succeeds, upload via:
#   xcrun altool --upload-app -f .build/ios-appstore/Steer.ipa \
#     --type ios --apiKey <key> --apiIssuer <issuer>
# OR open Xcode Organizer → Window → Organizer → Distribute App

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$ROOT_DIR/apps/ios"
ARCHIVE_PATH="$ROOT_DIR/.build/ios-appstore/Steer.xcarchive"
EXPORT_DIR="$ROOT_DIR/.build/ios-appstore/export"
EXPORT_OPTIONS="$IOS_DIR/ExportOptions-AppStore.plist"
SCHEME="Steer"
PROJECT="$IOS_DIR/Steer.xcodeproj"

echo "▸ iOS App Store build"
echo "  Project : $PROJECT"
echo "  Scheme  : $SCHEME"
echo "  Archive : $ARCHIVE_PATH"
echo ""

# ── 0. Preflight ────────────────────────────────────────────────────────────
if [ ! -d "$PROJECT" ]; then
  echo "error: $PROJECT not found." >&2
  echo "  Run: cd apps/ios && xcodegen generate" >&2
  exit 1
fi

mkdir -p "$(dirname "$ARCHIVE_PATH")"

# ── 1. Archive ───────────────────────────────────────────────────────────────
echo "▸ Step 1/2: xcodebuild archive …"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -configuration Release \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=LG7667PAS6 \
  | xcpretty 2>/dev/null || true

# xcpretty is optional — fall back to raw output if not installed
if [ ! -d "$ARCHIVE_PATH" ]; then
  echo ""
  echo "  xcpretty may have swallowed the error. Re-running with raw output…"
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    -configuration Release \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM=LG7667PAS6
fi

echo "  ✓ Archive: $ARCHIVE_PATH"

# ── 2. Export IPA ────────────────────────────────────────────────────────────
echo ""
echo "▸ Step 2/2: xcodebuild -exportArchive …"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

IPA_PATH=$(find "$EXPORT_DIR" -name "*.ipa" | head -1)

echo ""
echo "✅  Done."
echo "   IPA → $IPA_PATH"
echo ""
echo "Next: upload to App Store Connect"
echo "  Option A (Xcode Organizer): Window → Organizer, pick the archive, Distribute App"
echo "  Option B (CLI with API key):"
echo "    xcrun altool --upload-app -f \"$IPA_PATH\" \\"
echo "      --type ios --apiKey <KEY_ID> --apiIssuer <ISSUER_UUID>"
