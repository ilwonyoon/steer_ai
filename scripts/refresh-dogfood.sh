#!/usr/bin/env bash
# Re-cut the local Mac dogfood build from a clean slate.
#
# Why this exists: after every Mac PR lands on main, the user's
# still-running dogfood SteerMac process (from a previous main, a
# previous bundle path, a previous entitlement set) holds the menu
# bar and stops responding. Symptom: clicking the menu bar gear
# does nothing. The fix has always been the same five manual
# commands; this script bundles them so a single invocation
# guarantees we're running exactly what's on main.
#
# Usage:
#   bash scripts/refresh-dogfood.sh
#
# Requires:
#   - Apple Development certificate "Apple Development: ILWON YOON
#     (D6YNVHXSDR)" (hash A4BC2672A5DA71AC802506FAC678D5EFFE979D5E)
#     in the login keychain. Lets Sign in with Apple work for
#     iPhone Sync against the matching Development provisioning
#     profile.
#   - ~/Downloads/Steer_Mac_Development*.provisionprofile present
#     (Apple Developer Portal → Profiles).
#   - apps/mac/Steer.dogfood.entitlements (committed) — the
#     dogfood-only entitlements file that re-enables
#     com.apple.developer.applesignin on top of the
#     direct-distribution entitlements set.
#
# Override env vars:
#   APP_VERSION    defaults to <git-tag>-dogfood
#   SIGN_IDENTITY  override the cert hash above
#   PROVISIONING_PROFILE  override the auto-picked Downloads file

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APPLE_DEV_CERT="${SIGN_IDENTITY:-A4BC2672A5DA71AC802506FAC678D5EFFE979D5E}"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT_DIR/apps/mac/Steer.dogfood.entitlements}"
DEFAULT_PROFILE="$(ls -t ~/Downloads/Steer_Mac_Development*.provisionprofile 2>/dev/null | head -1 || true)"
PROVISIONING_PROFILE="${PROVISIONING_PROFILE:-$DEFAULT_PROFILE}"
APP_VERSION="${APP_VERSION:-$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)-dogfood}"
APP_VERSION="${APP_VERSION#v}"

if [ -z "$PROVISIONING_PROFILE" ] || [ ! -f "$PROVISIONING_PROFILE" ]; then
  echo "error: no Development provisioning profile found." >&2
  echo "  Download Steer_Mac_Development.provisionprofile from Apple" >&2
  echo "  Developer Portal → Profiles into ~/Downloads, or pass" >&2
  echo "  PROVISIONING_PROFILE=/abs/path explicitly." >&2
  exit 1
fi

echo "==> Killing every Steer / SteerMac process on the box"
# Both legacy (SteerMac.app) and current (Steer.app) bundle paths
# may have stale processes. Match the binary path, not just the
# name, so we don't catch unrelated executables called "Steer".
pkill -f "/.build/SteerMac.app/Contents/MacOS/SteerMac" 2>/dev/null || true
pkill -f "/.build/Steer.app/Contents/MacOS/SteerMac"   2>/dev/null || true
pkill -f "swift run SteerMac"                          2>/dev/null || true
# Anything that opened our app via launchd
pkill -fl "ai.steer.mac" 2>/dev/null || true
# CRITICAL: also kill the SteerAgent node process. Mac auto-spawns
# it on launch but never reaps it on quit, so a SteerAgent from an
# older main commit can outlive Steer.app and keep serving the
# Unix socket with stale code (stale classifier, stale store,
# stale publishCard wire). Symptom: Steer.app gets the new logic
# but its backend is still the previous build, so cards stop
# regenerating after the first iPhone reply.
pkill -9 -f "packages/agent/src/agent.js"              2>/dev/null || true
# Drop the stale Unix socket so the next SteerAgent can bind. The
# kill above leaves an orphan socket file the next process treats
# as 'already running' and exits.
rm -f "$HOME/.steer/steer.sock"
sleep 2

echo "==> Removing every .app folder under .build/ (old bundle names included)"
# We've renamed the on-disk bundle at least twice. Sweep the lot so
# LaunchServices can't pick up an outdated copy.
find "$ROOT_DIR/.build" -maxdepth 2 -type d -name "*.app" -print0 2>/dev/null \
  | xargs -0 rm -rf 2>/dev/null || true

echo "==> Forgetting LaunchServices registrations for ai.steer.mac"
# Without this the Dock / Spotlight / notification daemon keep
# pointing at the old path and the menu bar item can race with
# itself.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -u -r -domain user "$ROOT_DIR/.build" >/dev/null 2>&1 || true
fi

echo "==> Building dogfood Steer.app (Apple Development cert + applesignin)"
ENTITLEMENTS="$ENTITLEMENTS" \
PROVISIONING_PROFILE="$PROVISIONING_PROFILE" \
SIGN_IDENTITY="$APPLE_DEV_CERT" \
APP_VERSION="$APP_VERSION" \
bash "$ROOT_DIR/scripts/build-mac-app.sh" >/dev/null

APP="$ROOT_DIR/.build/Steer.app"
if [ ! -d "$APP" ]; then
  echo "error: build did not produce $APP" >&2
  exit 1
fi

echo "==> Re-registering the new bundle so LaunchServices knows about it"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
fi

echo "==> Launching $APP"
open "$APP"

# Give launchd a beat, then check the process is alive.
sleep 3
if pgrep -f "$APP/Contents/MacOS/SteerMac" >/dev/null; then
  echo ""
  echo "✅ Steer dogfood is running."
  echo "   Bundle: $APP"
  echo "   Version: $APP_VERSION"
  echo "   Menu bar icon should be live in a second or two."
else
  echo ""
  echo "❌ Steer didn't stay running. Check:" >&2
  echo "   log show --predicate 'process == \"SteerMac\"' --last 30s" >&2
  exit 1
fi
