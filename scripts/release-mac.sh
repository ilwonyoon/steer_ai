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
  # Prefer the SHA1 fingerprint when there is more than one cert with the
  # same human-readable name (codesign refuses an ambiguous match by name).
  STEER_SIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk '/Developer ID Application:/ && $0 !~ /REVOKED/ { print $2; exit }'
  )"
fi
if [ -z "${STEER_SIGN_IDENTITY}" ]; then
  echo "error: no valid 'Developer ID Application' certificate in the keychain" >&2
  echo "  install one (Apple Developer → Certificates → Developer ID Application)" >&2
  echo "  or set STEER_SIGN_IDENTITY explicitly" >&2
  exit 1
fi

STEER_NOTARY_PROFILE="${STEER_NOTARY_PROFILE:-steer-notary}"
if ! xcrun notarytool history --keychain-profile "$STEER_NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "error: notarytool keychain profile '$STEER_NOTARY_PROFILE' is missing or invalid" >&2
  echo "  create it once with:" >&2
  echo "  xcrun notarytool store-credentials $STEER_NOTARY_PROFILE \\" >&2
  echo "    --apple-id <your apple-id> --team-id LG7667PAS6 --password <app-specific-pw>" >&2
  exit 1
fi

echo "==> Signing identity: $STEER_SIGN_IDENTITY"
echo "==> Notary profile:   $STEER_NOTARY_PROFILE"

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
  ENTITLEMENTS="${ENTITLEMENTS:-$ROOT_DIR/apps/mac/Steer.release.entitlements}" \
  bash "$ROOT_DIR/scripts/build-mac-app.sh" | tail -1
)"

if [ ! -d "$APP_DIR" ]; then
  echo "error: build did not produce an app bundle at $APP_DIR" >&2
  exit 1
fi

# Embed the Developer ID provisioning profile that asserts the iCloud
# entitlements. Without this, notarized direct-distribution Macs hit
# CKError 9 ('Not Authenticated') the moment they try to access the
# CloudKit container. We pick up the first .provisionprofile under
# ~/Library/MobileDevice/Provisioning Profiles/ that names ai.steer.mac;
# tests can pin a specific path via STEER_PROVISIONING_PROFILE.
PROFILE_PATH="${STEER_PROVISIONING_PROFILE:-}"
if [ -z "$PROFILE_PATH" ]; then
  for candidate in "$HOME/Library/MobileDevice/Provisioning Profiles"/*.provisionprofile; do
    [ -f "$candidate" ] || continue
    if security cms -D -i "$candidate" 2>/dev/null \
      | grep -q "ai\.steer\.mac"; then
      PROFILE_PATH="$candidate"
      break
    fi
  done
fi

if [ -z "$PROFILE_PATH" ] || [ ! -f "$PROFILE_PATH" ]; then
  echo "error: no Developer ID provisioning profile found for ai.steer.mac" >&2
  echo "  follow docs/IOS_DEVELOPER_CONSOLE_SETUP.md → step 4 to create one" >&2
  exit 1
fi

echo "==> Embedding provisioning profile: $(basename "$PROFILE_PATH")"
cp "$PROFILE_PATH" "$APP_DIR/Contents/embedded.provisionprofile"

# Sparkle.framework ships with its own signature. Apple notarization rejects
# anything signed with a non-Developer-ID identity, so we re-sign every nested
# binary inside the framework before signing the framework itself.
SPARKLE_FW="$APP_DIR/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  echo "==> Re-signing Sparkle framework with $STEER_SIGN_IDENTITY"
  while IFS= read -r -d '' xpc; do
    codesign --force --options runtime --timestamp --sign "$STEER_SIGN_IDENTITY" "$xpc"
  done < <(find "$SPARKLE_FW" -name '*.xpc' -print0)
  while IFS= read -r -d '' nested_app; do
    codesign --force --deep --options runtime --timestamp --sign "$STEER_SIGN_IDENTITY" "$nested_app"
  done < <(find "$SPARKLE_FW" -name '*.app' -print0)
  while IFS= read -r -d '' bin; do
    [ -f "$bin" ] && [ -x "$bin" ] || continue
    file "$bin" | grep -q "Mach-O" || continue
    codesign --force --options runtime --timestamp --sign "$STEER_SIGN_IDENTITY" "$bin"
  done < <(find "$SPARKLE_FW/Versions" -maxdepth 2 -type f -print0)
  codesign --force --options runtime --timestamp --sign "$STEER_SIGN_IDENTITY" "$SPARKLE_FW"
  # Re-sign the outer app once Sparkle is settled, otherwise the bundle's
  # CodeResources hash drifts.
  codesign --force --deep --options runtime --timestamp \
    --entitlements "${ENTITLEMENTS:-$ROOT_DIR/apps/mac/Steer.entitlements}" \
    --sign "$STEER_SIGN_IDENTITY" "$APP_DIR"
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
