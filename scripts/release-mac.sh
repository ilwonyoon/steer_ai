#!/usr/bin/env bash
# Build, sign, notarize, staple, and package SteerMac as a distributable .dmg.
#
# Required environment:
#   STEER_SIGN_IDENTITY    Developer ID Application identity, e.g. "Developer ID Application: Ilwon Yoon (TEAMID)"
#   STEER_NOTARY_PROFILE   notarytool keychain profile, e.g. "steer-notary"
#                          (created once via: xcrun notarytool store-credentials steer-notary)
#
# Optional environment:
#   APP_VERSION            CFBundleShortVersionString. Defaults to the current git tag.
#   APP_BUILD              CFBundleVersion. Defaults to git rev-list --count HEAD.
#   ENTITLEMENTS           defaults to apps/mac/Steer.entitlements
#   DMG_VOLNAME            DMG volume name. Defaults to "Steer".
#
# Output:
#   .build/SteerMac.app          stapled signed bundle
#   .build/release/Steer-<v>.dmg signed + stapled installer
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "${STEER_SIGN_IDENTITY:-}" ]; then
  echo "error: STEER_SIGN_IDENTITY is not set" >&2
  echo "  example: export STEER_SIGN_IDENTITY=\"Developer ID Application: Ilwon Yoon (TEAMID)\"" >&2
  exit 1
fi
if [ -z "${STEER_NOTARY_PROFILE:-}" ]; then
  echo "error: STEER_NOTARY_PROFILE is not set" >&2
  echo "  create one with: xcrun notarytool store-credentials steer-notary --apple-id <id> --team-id <TEAMID> --password <app-specific-pw>" >&2
  exit 1
fi

if [ -z "${APP_VERSION:-}" ]; then
  if APP_VERSION="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null)"; then
    APP_VERSION="${APP_VERSION#v}"
  else
    echo "error: no git tag found and APP_VERSION not set" >&2
    echo "  either tag the release (e.g. git tag v0.1.0) or run with APP_VERSION=0.1.0" >&2
    exit 1
  fi
fi

OUT_DIR="$ROOT_DIR/.build/release"
DMG_NAME="Steer-${APP_VERSION}.dmg"
DMG_PATH="$OUT_DIR/$DMG_NAME"
DMG_VOLNAME="${DMG_VOLNAME:-Steer}"
mkdir -p "$OUT_DIR"

echo "==> Building release bundle (Steer ${APP_VERSION})"
APP_DIR="$(
  CONFIGURATION=release \
  APP_VERSION="$APP_VERSION" \
  APP_BUILD="${APP_BUILD:-}" \
  SIGN_IDENTITY="$STEER_SIGN_IDENTITY" \
  ENTITLEMENTS="${ENTITLEMENTS:-$ROOT_DIR/apps/mac/Steer.entitlements}" \
  bash "$ROOT_DIR/scripts/build-mac-app.sh" | tail -1
)"

if [ ! -d "$APP_DIR" ]; then
  echo "error: build did not produce an app bundle at $APP_DIR" >&2
  exit 1
fi

echo "==> Verifying signature"
codesign --verify --strict --deep --verbose=2 "$APP_DIR" >&2

echo "==> Submitting bundle for notarization"
NOTARY_ZIP="$OUT_DIR/SteerMac-${APP_VERSION}.zip"
rm -f "$NOTARY_ZIP"
ditto -c -k --keepParent "$APP_DIR" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" \
  --keychain-profile "$STEER_NOTARY_PROFILE" \
  --wait
rm -f "$NOTARY_ZIP"

echo "==> Stapling notarization ticket to bundle"
xcrun stapler staple "$APP_DIR"
spctl --assess --type execute --verbose=2 "$APP_DIR" || {
  echo "warning: spctl assessment failed; the user will see a Gatekeeper warning" >&2
}

echo "==> Building DMG"
rm -f "$DMG_PATH"
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "$DMG_VOLNAME" \
    --window-size 540 360 \
    --icon-size 96 \
    --icon "SteerMac.app" 140 180 \
    --app-drop-link 400 180 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_DIR"
else
  STAGE_DIR="$(mktemp -d)"
  cp -R "$APP_DIR" "$STAGE_DIR/"
  ln -s /Applications "$STAGE_DIR/Applications"
  hdiutil create -volname "$DMG_VOLNAME" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"
  rm -rf "$STAGE_DIR"
fi

echo "==> Signing DMG"
codesign --force --sign "$STEER_SIGN_IDENTITY" --timestamp "$DMG_PATH"

echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$STEER_NOTARY_PROFILE" \
  --wait

echo "==> Stapling notarization ticket to DMG"
xcrun stapler staple "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH" || {
  echo "warning: DMG spctl assessment failed" >&2
}

echo
echo "Done."
echo "  app: $APP_DIR"
echo "  dmg: $DMG_PATH"
