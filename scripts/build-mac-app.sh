#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_DIR="$ROOT_DIR/apps/mac"
CONFIGURATION="${CONFIGURATION:-debug}"
APP_NAME="SteerMac"
APP_DIR="$ROOT_DIR/.build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

swift build --package-path "$MAC_DIR" --configuration "$CONFIGURATION"

BINARY_PATH="$(swift build --package-path "$MAC_DIR" --configuration "$CONFIGURATION" --show-bin-path)/$APP_NAME"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY_PATH" "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
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
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSUserNotificationAlertStyle</key>
  <string>alert</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "$APP_DIR"
