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
2. Confirm the Mac app opens a live session card.
3. Send text from Steer and confirm the current action card closes.
4. Wait for the AI to stop/report and confirm a new readable card opens.
5. Close the terminal and confirm disconnected cards disappear without repeated notifications.
EOF
