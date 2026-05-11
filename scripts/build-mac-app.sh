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
#   PROVISIONING_PROFILE optional provisioning profile copied to Contents/embedded.provisionprofile
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
PROVISIONING_PROFILE="${PROVISIONING_PROFILE:-}"

has_entitlement() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1
}

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

if [ -n "$ENTITLEMENTS" ] && [ -f "$ENTITLEMENTS" ] \
  && has_entitlement "$ENTITLEMENTS" "com.apple.developer.applesignin" \
  && [ -z "$PROVISIONING_PROFILE" ]; then
  cat >&2 <<'EOF'
error: com.apple.developer.applesignin requires a provisioning profile.

macOS 26 rejects SwiftPM-built ad-hoc/Developer ID app bundles that carry
this restricted entitlement without Contents/embedded.provisionprofile,
surfacing as RBSRequestErrorDomain Code=5 / errno=163 at open time.

Remove the entitlement for local dogfood builds, or pass:
  PROVISIONING_PROFILE=/path/to/profile.provisionprofile
EOF
  exit 1
fi

swift build --package-path "$MAC_DIR" --configuration "$CONFIGURATION"
SWIFT_BIN_PATH="$(swift build --package-path "$MAC_DIR" --configuration "$CONFIGURATION" --show-bin-path)"
BINARY_PATH="$SWIFT_BIN_PATH/$APP_NAME"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY_PATH" "$MACOS_DIR/$APP_NAME"

# SwiftPM packages an executable's `resources: [.process(...)]` into a
# sibling `${TARGET}_${TARGET}.bundle` directory and the binary loads
# them via Bundle.module. We need to ship that bundle inside the app
# so NSImage(named:) etc. resolve at runtime.
SPM_RESOURCE_BUNDLE="$SWIFT_BIN_PATH/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$SPM_RESOURCE_BUNDLE" ]; then
  cp -R "$SPM_RESOURCE_BUNDLE" "$RESOURCES_DIR/"
fi

if [ -n "$PROVISIONING_PROFILE" ]; then
  if [ ! -f "$PROVISIONING_PROFILE" ]; then
    echo "error: provisioning profile not found: $PROVISIONING_PROFILE" >&2
    exit 1
  fi
  cp "$PROVISIONING_PROFILE" "$CONTENTS_DIR/embedded.provisionprofile"
fi

if [ -f "$MAC_DIR/Resources/AppIcon.icns" ]; then
  cp "$MAC_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
  ICON_KEY_BLOCK=$'\n  <key>CFBundleIconFile</key>\n  <string>AppIcon</string>'
else
  ICON_KEY_BLOCK=""
fi

# Sparkle integration: only emitted if both URL and public key are provided
# via the environment, so dogfood builds quietly skip the update check.
SPARKLE_KEY_BLOCK=""
if [ -n "${SPARKLE_FEED_URL:-}" ] && [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
  SPARKLE_KEY_BLOCK=$'\n  <key>SparkleEnabled</key>\n  <string>YES</string>'
  SPARKLE_KEY_BLOCK+=$'\n  <key>SUFeedURL</key>\n  <string>'"$SPARKLE_FEED_URL"$'</string>'
  SPARKLE_KEY_BLOCK+=$'\n  <key>SUPublicEDKey</key>\n  <string>'"$SPARKLE_PUBLIC_ED_KEY"$'</string>'
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
  <string>Steer reads CLI session metadata when you start sessions from Downloads.</string>${ICON_KEY_BLOCK}${SPARKLE_KEY_BLOCK}
</dict>
</plist>
PLIST

# Bundle Sparkle.framework if SwiftPM emitted one for this configuration. We
# also patch the executable's rpath so the standard Sparkle install name
# (@rpath/Sparkle.framework/...) resolves to Contents/Frameworks at launch.
SPARKLE_BUILT_PATH="$(swift build --package-path "$MAC_DIR" --configuration "$CONFIGURATION" --show-bin-path)/Sparkle.framework"
if [ -d "$SPARKLE_BUILT_PATH" ]; then
  FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
  mkdir -p "$FRAMEWORKS_DIR"
  rm -rf "$FRAMEWORKS_DIR/Sparkle.framework"
  cp -R "$SPARKLE_BUILT_PATH" "$FRAMEWORKS_DIR/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$APP_NAME" 2>/dev/null || true
fi

CODESIGN_FLAGS=("--force" "--timestamp")
if [ "$SIGN_IDENTITY" != "-" ]; then
  CODESIGN_FLAGS+=("--options" "runtime")
fi
if [ -n "$ENTITLEMENTS" ] && [ -f "$ENTITLEMENTS" ]; then
  CODESIGN_FLAGS+=("--entitlements" "$ENTITLEMENTS")
fi

# Hardened runtime is harmless under ad-hoc signing; the timestamp flag is
# silently ignored without a network identity. We only skip the runtime
# option for ad-hoc when explicitly requested via SKIP_HARDENED=1, since
# some sandboxed dev tools dislike it.
if [ "$SIGN_IDENTITY" = "-" ] && [ "${SKIP_HARDENED:-0}" = "1" ]; then
  CODESIGN_FLAGS=("--force")
fi

# Sign nested frameworks first so the outer bundle's signature seals over
# them, then sign the bundle itself. --deep is unreliable for hardened
# runtime, so we walk the framework explicitly.
#
# For ad-hoc dogfood signing we *must not* attach hardened runtime to the
# inner framework Mach-Os — the runtime forces a Team ID match check that
# fails when both layers are ad-hoc. release-mac.sh re-signs everything
# under a real Developer ID later, where hardened runtime is required.
INNER_FLAGS=("--force" "--timestamp" "--options" "runtime")
if [ "$SIGN_IDENTITY" = "-" ]; then
  INNER_FLAGS=("--force" "--timestamp")
fi

if [ -d "$CONTENTS_DIR/Frameworks" ]; then
  for framework in "$CONTENTS_DIR"/Frameworks/*.framework; do
    [ -d "$framework" ] || continue
    while IFS= read -r -d '' xpc; do
      codesign "${INNER_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$xpc" >/dev/null
    done < <(find "$framework" -name '*.xpc' -print0)
    while IFS= read -r -d '' nested_app; do
      codesign --force --deep --timestamp \
        $([ "$SIGN_IDENTITY" != "-" ] && echo "--options runtime") \
        --sign "$SIGN_IDENTITY" "$nested_app" >/dev/null
    done < <(find "$framework" -name '*.app' -print0)
    while IFS= read -r -d '' bin; do
      [ -f "$bin" ] && [ -x "$bin" ] || continue
      file "$bin" | grep -q "Mach-O" || continue
      codesign "${INNER_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$bin" >/dev/null
    done < <(find "$framework/Versions" -maxdepth 2 -type f -print0)
    codesign "${INNER_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$framework" >/dev/null
  done
fi

codesign "${CODESIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null

echo "$APP_DIR"
