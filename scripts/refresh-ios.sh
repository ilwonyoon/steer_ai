#!/usr/bin/env bash
# Wipe stale iOS build output, rebuild Steer for the connected
# iPhone, and reinstall. Sister to refresh-dogfood.sh — the iPhone
# also drifts behind main when we forget to re-deploy after a PR,
# and a stale install carries old SyncInbox / WS reconnect / cache
# behavior that gives misleading bug reports.
#
# Requires:
#   - An iPhone connected via USB (Developer Mode enabled)
#   - Apple Development cert in the keychain (xcodebuild picks it
#     up automatically with -allowProvisioningUpdates)
#
# Usage:
#   bash scripts/refresh-ios.sh
#   bash scripts/refresh-ios.sh <device-id>   # if multiple devices
#
# What it sweeps before building:
#   - apps/ios/build/  (xcodebuild output)
#   - the previously installed ai.steer.ios on the device
#     (uninstall — guarantees no cached UserDefaults / WS state)
#   - Xcode DerivedData/Steer-*

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$ROOT_DIR/apps/ios"

# Resolve target device. If the caller passes one, use it; otherwise
# pick the first connected (non-Watch, non-paired-only) iOS device.
DEVICE_ID="${1:-}"
if [ -z "$DEVICE_ID" ]; then
  DEVICE_ID="$(xcrun devicectl list devices --json-output - 2>/dev/null \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for dev in data.get('result', {}).get('devices', []):
    props = dev.get('deviceProperties', {})
    if props.get('platformIdentifier', '').startswith('com.apple.platform.iphoneos') \
       and dev.get('connectionProperties', {}).get('tunnelState') == 'connected':
        print(dev.get('identifier'))
        break
" 2>/dev/null || true)"
fi

if [ -z "$DEVICE_ID" ]; then
  echo "error: no connected iPhone found. Plug one in, unlock it," >&2
  echo "  trust this Mac if prompted, then re-run." >&2
  echo "  Or pass an explicit device id:" >&2
  echo "    bash scripts/refresh-ios.sh <device-id>" >&2
  exit 1
fi
echo "==> Targeting device: $DEVICE_ID"

echo "==> Wiping apps/ios/build/"
rm -rf "$IOS_DIR/build"

echo "==> Wiping Xcode DerivedData/Steer-*"
DD="$HOME/Library/Developer/Xcode/DerivedData"
if [ -d "$DD" ]; then
  for dir in "$DD"/Steer-*; do
    [ -d "$dir" ] && rm -rf "$dir"
  done
fi

echo "==> Uninstalling existing Steer on the device (best-effort)"
xcrun devicectl device uninstall app --device "$DEVICE_ID" ai.steer.ios 2>&1 | tail -1 || true

echo "==> Building Steer for $DEVICE_ID"
xcodebuild \
  -project "$IOS_DIR/Steer.xcodeproj" \
  -scheme Steer \
  -configuration Debug \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$IOS_DIR/build/DerivedData" \
  -allowProvisioningUpdates \
  build 2>&1 | tail -3

APP="$IOS_DIR/build/DerivedData/Build/Products/Debug-iphoneos/Steer.app"
if [ ! -d "$APP" ]; then
  echo "error: build did not produce $APP" >&2
  exit 1
fi

echo "==> Installing $APP"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" 2>&1 | tail -3

echo "==> Launching"
xcrun devicectl device process launch --device "$DEVICE_ID" ai.steer.ios 2>&1 | tail -2

echo ""
echo "✅ iOS Steer is on $DEVICE_ID with the current main."
