#!/usr/bin/env bash
# Build the SteerMac .app bundle. By default produces an ad-hoc-signed debug
# bundle for local dogfooding. For releases, see scripts/release-mac.sh which
# wraps this script with Developer ID signing and notarization.
#
# Environment overrides:
#   CONFIGURATION   debug | release (default: debug)
#   APP_VERSION     CFBundleShortVersionString (default: derived from `git describe --tags --always`)
#   APP_BUILD       CFBundleVersion (default: commit count `git rev-list --count HEAD`)
#   SIGN_IDENTITY   codesign identity (default: "-", i.e. ad-hoc)
#   ENTITLEMENTS    path to entitlements plist (default: apps/mac/Steer.entitlements)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_DIR="$ROOT_DIR/apps/mac"
CONFIGURATION="${CONFIGURATION:-debug}"
APP_NAME="SteerMac"
APP_DIR="$ROOT_DIR/.build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ENTITLEMENTS="${ENTITLEMENTS:-$MAC_DIR/Steer.entitlements}"

if [ -z "${APP_VERSION:-}" ]; then
  if APP_VERSION="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null)"; then
    APP_VERSION="${APP_VERSION#v}"
  else
    APP_VERSION="0.0.0"
  fi
fi
if [ -z "${APP_BUILD:-}" ]; then
  if APP_BUILD="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null)"; then
    :
  else
    APP_BUILD="1"
  fi
fi

swift build --package-path "$MAC_DIR" --configuration "$CONFIGURATION"
BINARY_PATH="$(swift build --package-path "$MAC_DIR" --configuration "$CONFIGURATION" --show-bin-path)/$APP_NAME"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY_PATH" "$MACOS_DIR/$APP_NAME"

if [ -f "$MAC_DIR/Resources/AppIcon.icns" ]; then
  cp "$MAC_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
  ICON_KEY_BLOCK=$'\n  <key>CFBundleIconFile</key>\n  <string>AppIcon</string>'
else
  ICON_KEY_BLOCK=""
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>SteerMac</string>
  <key>CFBundleIdentifier</key>
  <string>ai.steer.mac</string>
  <key>CFBundleName</key>
  <string>Steer</string>
  <key>CFBundleDisplayName</key>
  <string>Steer</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD}</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSUserNotificationAlertStyle</key>
  <string>alert</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Steer reads your wrapped CLI session metadata to surface action cards.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Steer reads CLI session metadata when you start sessions from your Desktop.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Steer reads CLI session metadata when you start sessions from Downloads.</string>${ICON_KEY_BLOCK}
</dict>
</plist>
PLIST

CODESIGN_FLAGS=("--force" "--deep" "--timestamp" "--options" "runtime")
if [ -n "$ENTITLEMENTS" ] && [ -f "$ENTITLEMENTS" ]; then
  CODESIGN_FLAGS+=("--entitlements" "$ENTITLEMENTS")
fi

# Hardened runtime is harmless under ad-hoc signing; the timestamp flag is
# silently ignored without a network identity. We only skip the runtime
# option for ad-hoc when explicitly requested via SKIP_HARDENED=1, since
# some sandboxed dev tools dislike it.
if [ "$SIGN_IDENTITY" = "-" ] && [ "${SKIP_HARDENED:-0}" = "1" ]; then
  CODESIGN_FLAGS=("--force" "--deep")
fi

codesign "${CODESIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null

echo "$APP_DIR"
