#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

npm test
npm run test:integration
swift build --package-path apps/mac
# G15 — PTY flood durability stress smoke. Real wrapper, real
# PTY, isolated STEER_HOME. Fails fast if the session snapshot
# can't survive ~500 PTY chunks alongside a real user + report.
FLOOD_SECONDS="${FLOOD_SECONDS:-10}" bash scripts/stress-pty-flood.sh
scripts/build-mac-app.sh

cat <<'EOF'

Steer regression checks passed.

Manual dogfood contract:
1. Start a wrapped session: steer codex or steer claude.
2. Confirm the Mac app does not open a card just because the session is running.
3. Wait for the AI to stop/report and confirm one readable card opens.
4. Send text from Steer and confirm the card closes while the AI runs.
5. Wait for the next stopped report and confirm a new readable card opens.
6. Close the terminal and confirm disconnected cards disappear without repeated notifications.
EOF
