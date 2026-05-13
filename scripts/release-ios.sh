#!/usr/bin/env bash
# Build, archive, and export Steer for the App Store.
#
# Usage:
#   bash scripts/release-ios.sh
#
# What it does:
#   1. Clean any prior archive.
#   2. xcodebuild archive Release/iOS, sign with the default account.
#   3. xcodebuild -exportArchive with ExportOptions-AppStore.plist.
#
# What it does NOT do (you do these yourself, one time):
#   - Create the App Store Distribution profile in Apple Developer
#     Portal. The export step asks Xcode to find a profile named
#     'iOS Team Provisioning Profile: ai.steer.ios' — it must
#     exist with method=app-store. Until then export fails with
#     "No profiles for 'ai.steer.ios' were found", which is the
#     signal to go to:
#       https://developer.apple.com/account/resources/profiles
#     and add an App Store Distribution profile for ai.steer.ios.
#
#   - Upload the resulting .ipa. That's altool's job — see the
#     end of this script for the command. Needs ASC_API_KEY_ID +
#     ASC_API_ISSUER_ID environment variables.
#
# Output: apps/ios/build/Steer-AppStore/Steer.ipa

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$REPO_ROOT/apps/ios"
ARCHIVE_PATH="$IOS_DIR/build/Steer.xcarchive"
EXPORT_PATH="$IOS_DIR/build/Steer-AppStore"
EXPORT_OPTIONS="$IOS_DIR/ExportOptions-AppStore.plist"

echo "==> Cleaning previous archive + export"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

echo "==> Archiving Steer (Release, iOS)"
xcodebuild -project "$IOS_DIR/Steer.xcodeproj" \
  -scheme Steer \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  archive | tail -40

if [ ! -d "$ARCHIVE_PATH" ]; then
  echo "error: archive did not land at $ARCHIVE_PATH"
  exit 1
fi
echo "    ✅ archive at $ARCHIVE_PATH"

echo "==> Exporting App Store .ipa"
set +e
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" 2>&1 | tee /tmp/steer-export.log
export_status=${PIPESTATUS[0]}
set -e

if [ $export_status -ne 0 ]; then
  echo ""
  echo "❌ Export failed. The most common cause is a missing App Store"
  echo "   Distribution provisioning profile. Steps to fix:"
  echo ""
  echo "   1. Open https://developer.apple.com/account/resources/profiles"
  echo "   2. + → App Store Connect → iOS → Distribution"
  echo "   3. App ID: ai.steer.ios"
  echo "   4. Distribution Certificate: your team's"
  echo "   5. Name: 'Steer iOS Distribution'"
  echo "   6. Generate, download, double-click to install in Xcode."
  echo "   7. Re-run this script."
  exit $export_status
fi

ipa="$EXPORT_PATH/Steer.ipa"
if [ -f "$ipa" ]; then
  size_mb=$(( $(stat -f%z "$ipa") / 1024 / 1024 ))
  echo "    ✅ .ipa at $ipa (${size_mb} MB)"
else
  echo "error: export succeeded but no .ipa found at $ipa"
  ls -la "$EXPORT_PATH/"
  exit 1
fi

echo ""
echo "==> Next: upload to App Store Connect"
echo ""
echo "   Make sure ASC_API_KEY_ID, ASC_API_ISSUER_ID are set and the"
echo "   API key .p8 is at ~/.appstoreconnect/private_keys/."
echo ""
echo "   xcrun altool --upload-app \\"
echo "     -f \"$ipa\" -t ios \\"
echo "     --apiKey \"\$ASC_API_KEY_ID\" \\"
echo "     --apiIssuer \"\$ASC_API_ISSUER_ID\""
echo ""
echo "   Then check App Store Connect → TestFlight for processing."
