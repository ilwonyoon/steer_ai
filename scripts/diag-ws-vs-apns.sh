#!/bin/bash
# diag-ws-vs-apns.sh
#
# Measures WS recipients vs APNS reach for the iPhone sync path.
# Sets up two parallel log streams the operator can watch while
# opening Mac sessions / replying from iPhone, then writes a
# correlated CSV row per card publish event.
#
# Output: docs/diag/ws-vs-apns-<TIMESTAMP>.log (raw) and
#         docs/diag/ws-vs-apns-<TIMESTAMP>.csv (correlated rows)
#
# Usage:
#   bash scripts/diag-ws-vs-apns.sh             # streams until Ctrl-C
#   bash scripts/diag-ws-vs-apns.sh --duration 600   # 10 min then stop
#
# What to do while it runs:
#   1. Have iPhone in known state (foreground/background/locked)
#   2. Open `steer claude` on Mac
#   3. Type a question that makes Claude stop with a prompt
#   4. Record iPhone state + visible-at time in the CSV (manual)
#   5. Repeat across 3 iPhone states × N sessions
#
# Each row in the CSV captures:
#   timestamp, card_id, ws_recipients, apns_status, iphone_state, visible_lag_ms

set -e

DIAG_DIR="$(cd "$(dirname "$0")/.." && pwd)/docs/diag"
mkdir -p "$DIAG_DIR"

TIMESTAMP="$(date +%Y-%m-%d-%H%M%S)"
RAW_LOG="$DIAG_DIR/ws-vs-apns-$TIMESTAMP.log"
CSV_LOG="$DIAG_DIR/ws-vs-apns-$TIMESTAMP.csv"

DURATION_SEC=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION_SEC="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

echo "Diag started at $(date)"
echo "Raw log : $RAW_LOG"
echo "CSV log : $CSV_LOG"
echo ""
echo "timestamp,card_id,ws_recipients,apns_targets,apns_status,iphone_state,note" > "$CSV_LOG"

# Stream wrangler tail in the background and parse correlated lines.
cd "$(dirname "$0")/../packages/relay"

TAIL_LOG_PID=""
cleanup() {
  if [[ -n "$TAIL_LOG_PID" ]]; then
    kill "$TAIL_LOG_PID" 2>/dev/null || true
  fi
  echo ""
  echo "Stopped at $(date)"
  echo "Lines captured: $(wc -l < "$RAW_LOG" | tr -d ' ')"
  echo ""
  echo "Quick summary:"
  if [[ -f "$RAW_LOG" ]]; then
    echo "  [broadcast] lines: $(grep -c '\[broadcast\]' "$RAW_LOG" || true)"
    echo "  recipients=0    : $(grep -c 'recipients=0' "$RAW_LOG" || true)"
    echo "  recipients>0    : $(grep -E 'recipients=[1-9]' "$RAW_LOG" -c || true)"
    echo "  [apns] sent ok=true : $(grep -c '\[apns\] sent.*ok=true' "$RAW_LOG" || true)"
    echo "  [apns] sent ok=false: $(grep -c '\[apns\] sent.*ok=false' "$RAW_LOG" || true)"
  fi
}
trap cleanup EXIT INT TERM

# wrangler tail with --format pretty so [broadcast]/[apns] lines come
# through legibly. We tee into both the raw log and stdout for live
# observation.
npx wrangler tail --format pretty 2>&1 | tee "$RAW_LOG" &
TAIL_LOG_PID=$!

if [[ $DURATION_SEC -gt 0 ]]; then
  sleep "$DURATION_SEC"
else
  # Wait indefinitely until Ctrl-C
  wait
fi
