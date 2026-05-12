#!/usr/bin/env bash
# Sweep every stale build artifact from this repo + the system caches
# that point at it. Run before a fresh dogfood cycle to guarantee
# nothing on disk has a chance to override what we're about to build.
#
# This is intentionally aggressive — it deletes:
#   - .build/*.app (every bundle SwiftPM emitted, regardless of name)
#   - apps/mac/build/   (an older Xcode shell, no longer used)
#   - apps/ios/build/   (iOS xcodebuild output for device installs)
#   - ~/Library/Developer/Xcode/DerivedData/Steer-* + SteerMac-*
#   - LaunchServices registrations under .build/ and apps/*/build/
#
# What it does NOT touch:
#   - .build/checkouts, .build/artifacts, .build/release  (real
#     SwiftPM caches + already-notarized DMGs)
#   - any installed copy in /Applications  (would surprise the user)
#   - the iPhone's installed Steer  (use devicectl uninstall manually)
#
# Usage:
#   bash scripts/wipe-builds.sh
#
# Pair with:
#   bash scripts/refresh-dogfood.sh   # rebuild + relaunch Mac dogfood

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Killing every Steer/SteerMac process spawned from this repo"
pkill -f "$ROOT_DIR/.build/.*/Contents/MacOS/SteerMac" 2>/dev/null || true
pkill -f "swift run SteerMac"                          2>/dev/null || true
# Same reason as in refresh-dogfood.sh: kill the auto-spawned
# SteerAgent so a stale node process doesn't serve old code on
# the next start.
pkill -9 -f "packages/agent/src/agent.js"              2>/dev/null || true
rm -f "$HOME/.steer/steer.sock"
sleep 1

echo "==> Wiping .build/*.app"
find "$ROOT_DIR/.build" -maxdepth 2 -type d -name "*.app" -print0 2>/dev/null \
  | xargs -0 rm -rf 2>/dev/null || true

echo "==> Wiping apps/mac/build/ (Xcode shell from earlier prototype, not used)"
rm -rf "$ROOT_DIR/apps/mac/build" 2>/dev/null || true

echo "==> Wiping apps/ios/build/ (xcodebuild device-install output)"
rm -rf "$ROOT_DIR/apps/ios/build" 2>/dev/null || true

echo "==> Wiping Xcode DerivedData for Steer / SteerMac"
DD="$HOME/Library/Developer/Xcode/DerivedData"
if [ -d "$DD" ]; then
  for dir in "$DD"/Steer-* "$DD"/SteerMac-*; do
    [ -d "$dir" ] && rm -rf "$dir"
  done
fi

echo "==> Forgetting LaunchServices registrations under the repo"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -u -r -domain user "$ROOT_DIR/.build"      >/dev/null 2>&1 || true
  "$LSREGISTER" -u -r -domain user "$ROOT_DIR/apps/mac"    >/dev/null 2>&1 || true
  "$LSREGISTER" -u -r -domain user "$ROOT_DIR/apps/ios"    >/dev/null 2>&1 || true
fi

echo ""
echo "✅ wipe complete. Next:"
echo "   bash scripts/refresh-dogfood.sh    # Mac dogfood"
echo "   (iOS: re-run xcodebuild + devicectl install if you want a fresh iPhone build)"
