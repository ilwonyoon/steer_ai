#!/usr/bin/env bash
# Interactive helper that loads the six GitHub Actions secrets the Release
# workflow needs. Run this once on a machine where the certificate, the
# notary password, and the provisioning profile already live.
#
# Required local prerequisites:
#   * gh CLI authenticated against this repo (`gh auth status` must be green)
#   * Developer ID Application certificate available either as a .p12 file
#     path you can supply, or already imported into the login keychain so it
#     can be exported on the fly
#   * A .provisionprofile exported from Apple Developer or downloaded by Xcode
#     that grants com.apple.developer.applesignin to ai.steer.mac
#   * An app-specific password for the Apple ID used for notarization
#
# This script never writes secrets to disk in plain text; every value is
# piped straight into `gh secret set` over stdin.
set -euo pipefail

REQUIRED_SECRETS=(
  DEVELOPER_ID_CERT_P12
  DEVELOPER_ID_CERT_PASSWORD
  PROVISIONING_PROFILE_BASE64
  NOTARY_APPLE_ID
  NOTARY_TEAM_ID
  NOTARY_APP_SPECIFIC_PASSWORD
)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found. install it from https://cli.github.com/" >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh CLI is not authenticated. run 'gh auth login' first" >&2
  exit 1
fi

prompt() {
  local prompt_text="$1"
  local var
  read -r -p "$prompt_text" var
  printf '%s' "$var"
}

prompt_secret() {
  local prompt_text="$1"
  local var
  read -r -s -p "$prompt_text" var
  echo >&2
  printf '%s' "$var"
}

set_secret() {
  local name="$1"
  local value="$2"
  printf '%s' "$value" | gh secret set "$name" --body-
  echo "  -> $name set"
}

confirm() {
  local prompt_text="$1"
  local answer
  read -r -p "$prompt_text [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

echo "==> Repository: $(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "==> Existing secrets:"
gh secret list || true
echo

if ! confirm "Continue and (re)load the six release secrets?"; then
  echo "aborted"
  exit 0
fi

echo
echo "--- DEVELOPER_ID_CERT_P12 ---"
echo "Provide the .p12 export of your Developer ID Application certificate."
echo "If you don't have one yet, export it from Keychain Access:"
echo "  1. Keychain Access -> login -> Certificates"
echo "  2. Right-click 'Developer ID Application: ILWON YOON (LG7667PAS6)'"
echo "  3. Export -> Personal Information Exchange (.p12) -> set a password"
echo
P12_PATH="$(prompt 'Path to .p12 file: ')"
if [ ! -f "$P12_PATH" ]; then
  echo "error: file not found: $P12_PATH" >&2
  exit 1
fi
P12_BASE64="$(base64 < "$P12_PATH" | tr -d '\n')"
set_secret DEVELOPER_ID_CERT_P12 "$P12_BASE64"

echo
echo "--- DEVELOPER_ID_CERT_PASSWORD ---"
P12_PASSWORD="$(prompt_secret 'Password used during .p12 export: ')"
set_secret DEVELOPER_ID_CERT_PASSWORD "$P12_PASSWORD"

echo
echo "--- PROVISIONING_PROFILE_BASE64 ---"
echo "Provide the .provisionprofile that includes Sign in with Apple for ai.steer.mac."
echo "You can fetch one from Apple Developer -> Profiles, or let Xcode generate it."
PROFILE_PATH="$(prompt 'Path to .provisionprofile: ')"
if [ ! -f "$PROFILE_PATH" ]; then
  echo "error: file not found: $PROFILE_PATH" >&2
  exit 1
fi
PROFILE_BASE64="$(base64 < "$PROFILE_PATH" | tr -d '\n')"
set_secret PROVISIONING_PROFILE_BASE64 "$PROFILE_BASE64"

echo
echo "--- NOTARY_APPLE_ID ---"
NOTARY_APPLE_ID="$(prompt 'Apple ID email used for notarization: ')"
set_secret NOTARY_APPLE_ID "$NOTARY_APPLE_ID"

echo
echo "--- NOTARY_TEAM_ID ---"
DEFAULT_TEAM_ID="LG7667PAS6"
NOTARY_TEAM_ID="$(prompt "Apple Team ID [default $DEFAULT_TEAM_ID]: ")"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-$DEFAULT_TEAM_ID}"
set_secret NOTARY_TEAM_ID "$NOTARY_TEAM_ID"

echo
echo "--- NOTARY_APP_SPECIFIC_PASSWORD ---"
echo "Create one at https://account.apple.com/account/manage if you don't have one."
NOTARY_PW="$(prompt_secret 'App-specific password (format abcd-efgh-ijkl-mnop): ')"
set_secret NOTARY_APP_SPECIFIC_PASSWORD "$NOTARY_PW"

echo
echo "==> All six secrets stored."
echo "==> Trigger the release with:"
echo "    git tag v0.1.0 && git push origin v0.1.0"
echo "==> Or manually:"
echo "    gh workflow run release.yml -f tag=v0.1.0"
