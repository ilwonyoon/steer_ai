#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

npm test
swift build --package-path apps/mac
scripts/build-mac-app.sh

cat <<'EOF'

Steer regression checks passed.

Manual dogfood contract:
1. Start a wrapped session: steer codex or steer claude.
2. Confirm the Mac app does not open a card just because the session is running.
3. Type directly in the terminal and confirm Steer does not mirror or sync that interaction.
4. Wait for a Stop hook/provider-native report and confirm one readable card opens.
5. Send text from Steer and confirm the card closes while the AI runs.
6. Wait for the next stopped report and confirm a new readable card opens with the full final block.
7. Close the terminal and confirm disconnected cards disappear without repeated notifications.
EOF
