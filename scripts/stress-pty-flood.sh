#!/usr/bin/env bash
# G15 PTY-flood stress smoke. Verifies the session-snapshot fix
# end-to-end against a real wrapped PTY session in an isolated
# ~/.steer dir, without touching the user's dogfood state.
#
# What it does:
#   1. Spawn a fake provider (`yes` piped into a slow loop) under
#      `steer wrap` so PTY stdout streams ~60 chunks/sec — same
#      shape as codex/claude status-bar repaint flood.
#   2. Inject one user instruction via `steer send`.
#   3. Manually push a synthetic "trusted report" line via the
#      agent socket (mimics codex turn/completed / Stop hook).
#   4. Let PTY flood for FLOOD_SECONDS (default 30 — 1800 chunks,
#      well over the 100-row cap).
#   5. Tear down. Inspect SQLite directly:
#        - action_cards.summary must NOT match the stub strings.
#        - sessions.last_user_text / last_trusted_text must
#          retain the original values.
#
# Run:
#   bash scripts/stress-pty-flood.sh
#
# Exit code: 0 on PASS, non-zero on FAIL with a diagnostic dump.

set -euo pipefail

FLOOD_SECONDS="${FLOOD_SECONDS:-30}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STEER_HOME="$(mktemp -d -t steer-stress.XXXXXX)"
export STEER_HOME

cleanup() {
  set +e
  if [ -n "${WRAP_PID:-}" ] && kill -0 "$WRAP_PID" 2>/dev/null; then
    kill "$WRAP_PID" 2>/dev/null
    sleep 0.5
    kill -9 "$WRAP_PID" 2>/dev/null
  fi
  if [ -n "${AGENT_PID:-}" ] && kill -0 "$AGENT_PID" 2>/dev/null; then
    kill "$AGENT_PID" 2>/dev/null
    sleep 0.5
    kill -9 "$AGENT_PID" 2>/dev/null
  fi
  # Print artifacts only on failure (set in trap below).
  if [ "${FAILED:-0}" = "1" ]; then
    echo ""
    echo "─── DUMP (STEER_HOME=$STEER_HOME) ───"
    echo ""
    echo "sessions:"
    sqlite3 "$STEER_HOME/steer.sqlite" \
      "SELECT id, run_state, last_user_text, last_trusted_text FROM sessions;" \
      2>/dev/null || true
    echo ""
    echo "action_cards:"
    sqlite3 "$STEER_HOME/steer.sqlite" \
      "SELECT id, category, state, summary FROM action_cards;" \
      2>/dev/null || true
    echo ""
    echo "agent.log tail:"
    tail -n 30 "$STEER_HOME/agent.log" 2>/dev/null || true
  fi
  rm -rf "$STEER_HOME"
}
trap 'FAILED=1; cleanup' ERR INT TERM
trap 'cleanup' EXIT

cd "$ROOT_DIR"

echo "▸ G15 PTY-flood stress smoke"
echo "  STEER_HOME : $STEER_HOME"
echo "  flood     : ${FLOOD_SECONDS}s"
echo ""

# ── 1. Start the agent ──────────────────────────────────────────
node packages/agent/src/agent.js >"$STEER_HOME/agent-stdout.log" 2>>"$STEER_HOME/agent.log" &
AGENT_PID=$!

# Wait for the socket to come up (max 5 s).
for _ in $(seq 1 50); do
  [ -S "$STEER_HOME/steer.sock" ] && break
  sleep 0.1
done
[ -S "$STEER_HOME/steer.sock" ] || {
  echo "FAIL: agent socket never appeared at $STEER_HOME/steer.sock" >&2
  exit 1
}

# ── 2. Spawn the wrapper around a fake PTY-flooding provider ────
# `yes` produces ~60–600 chunks/s — well beyond codex's idle rate
# of ~60 chunks/min. We pipe via stdbuf to keep it line-buffered
# at a sane rate (~50 lines/s) so the test stays observable.
FAKE_PROVIDER='for i in $(seq 1 100000); do printf "\033[41;2HR%d\n" $i; sleep 0.02; done'

# Run `steer wrap` in the background. It will create the session,
# register with the agent, and stream PTY.
script -q /dev/null node packages/cli/src/index.js wrap -- bash -c "$FAKE_PROVIDER" \
  >"$STEER_HOME/wrap-stdout.log" 2>"$STEER_HOME/wrap-stderr.log" &
WRAP_PID=$!

# Wait until the wrapper registers a session.
SESSION_ID=""
for _ in $(seq 1 100); do
  SESSION_ID=$(sqlite3 "$STEER_HOME/steer.sqlite" \
    "SELECT id FROM sessions ORDER BY rowid DESC LIMIT 1;" 2>/dev/null || true)
  [ -n "$SESSION_ID" ] && break
  sleep 0.1
done
[ -n "$SESSION_ID" ] || {
  echo "FAIL: wrapper never registered a session" >&2
  exit 1
}
echo "▸ session: $SESSION_ID"

# Give PTY a moment to flow before sending.
sleep 0.5

# ── 3. Inject a user instruction ────────────────────────────────
node packages/cli/src/index.js send "$SESSION_ID" "please answer 42" \
  >>"$STEER_HOME/send.log" 2>&1 || true

# ── 4. Inject a synthetic trusted "report" so the snapshot has
#       both user + trusted populated. We push it through the
#       agent socket the same way a Claude Stop hook would.
node -e "
const net = require('net');
const sock = process.env.STEER_HOME + '/steer.sock';
const c = net.createConnection(sock);
c.on('connect', () => {
  c.write(JSON.stringify({
    type: 'hook_event',
    sessionId: process.argv[1],
    provider: 'codex',
    eventName: 'Stop',
    lastAssistantMessage: 'The answer is 42.'
  }) + '\n');
  setTimeout(() => c.end(), 200);
});
" "$SESSION_ID"

# ── 5. Flood ────────────────────────────────────────────────────
echo "▸ flooding PTY for ${FLOOD_SECONDS}s …"
sleep "$FLOOD_SECONDS"

# ── 6. Verify ───────────────────────────────────────────────────
echo ""
echo "▸ verifying SQLite state"

ROW=$(sqlite3 "$STEER_HOME/steer.sqlite" \
  "SELECT printf('%s|%s|%s', coalesce(last_user_text,''), coalesce(last_trusted_text,''), run_state) FROM sessions WHERE id='$SESSION_ID';")
USER_TEXT=$(echo "$ROW" | awk -F'|' '{print $1}')
TRUSTED_TEXT=$(echo "$ROW" | awk -F'|' '{print $2}')
RUN_STATE=$(echo "$ROW" | awk -F'|' '{print $3}')

CARD_SUMMARY=$(sqlite3 "$STEER_HOME/steer.sqlite" \
  "SELECT summary FROM action_cards WHERE session_id='$SESSION_ID' ORDER BY rowid DESC LIMIT 1;")

echo "  sessions.last_user_text    : $USER_TEXT"
echo "  sessions.last_trusted_text : $TRUSTED_TEXT"
echo "  sessions.run_state         : $RUN_STATE"
echo "  action_cards.summary       : $CARD_SUMMARY"
echo ""

FAIL=0

if ! echo "$USER_TEXT" | grep -q "42"; then
  echo "FAIL: last_user_text lost — expected 'please answer 42', got: $USER_TEXT" >&2
  FAIL=1
fi
if ! echo "$TRUSTED_TEXT" | grep -q "42"; then
  echo "FAIL: last_trusted_text lost — expected 'The answer is 42.', got: $TRUSTED_TEXT" >&2
  FAIL=1
fi
if echo "$CARD_SUMMARY" | grep -qi "session opened\|send your first instruction\|just opened"; then
  echo "FAIL: action_cards.summary regressed to stub: $CARD_SUMMARY" >&2
  FAIL=1
fi

if [ "$FAIL" = "1" ]; then
  FAILED=1
  exit 1
fi

echo "PASS: snapshot columns survived ${FLOOD_SECONDS}s PTY flood and card stayed real."
