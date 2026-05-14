# Steer Regression Contract

These checks define the minimum product loop that must keep working before any UI, wrapper, or classifier change ships.

## Required Lifecycle

1. When a wrapped CLI session merely starts or runs, Steer does not show a live terminal mirror card.
2. When the AI stops and reports completion, question, blocker, or waiting state, Steer opens one card with the last relevant message.
3. When the user sends text from Steer, the current action card for that session is resolved/closed.
4. When the AI resumes/runs, Steer keeps the card closed until the next stopped report.
5. The reopened card shows the completed message with readable formatting, stable line breaks, and no transient repaint/status noise.
6. Disconnected terminal cards disappear automatically and never keep notifying.

## Instruction Delivery Contract (G14)

An injected instruction MUST produce a `last_response_revision` bump within
a reasonable window of its `injected_at` timestamp. Specifically:

- An instruction ack'd as `status: "injected"` signals that the PTY received
  the input. The next trusted output (`report`, `stdout`, `stderr`) from the
  provider after `awaiting_response_since` MUST bump `last_response_revision`.
- `steer send` MUST NOT silently discard an instruction when the agent returns
  a transient "session not found" or "session is disconnected" error. It must
  retry for up to `SEND_RECONNECT_RETRY_MS` (8 s) to absorb wrapper socket
  bounce / agent restart windows before failing hard. This budget intentionally
  exceeds the agent lock stale-reclaim window after SIGKILL.
- The PTY instruction payload and its submit keystroke (`\r`) MUST be written
  as **two separate `ptyProcess.write` calls separated by at least 50 ms**.
  Concretely: `ptyProcess.write(input)` first, then
  `setTimeout(() => ptyProcess.write('\r'), 50)`. See
  `packages/cli/src/index.js:253-268` (`submitPtyInstruction`).

  Rationale. Commit `e0b25c0` introduced the atomic-write variant
  (single `ptyProcess.write(input + '\r')`) on the theory that splitting
  across a timeout could race against providers rejecting paste during
  streaming. Commit `b832acc` reverted it after a dogfood regression:
  codex / claude TUIs need a small gap between the bracketed-paste END
  sequence (`\x1B[201~`) and the submit keystroke. When both arrive in
  the same `ptyProcess.write` call, the TUI treats the carriage return
  as part of the paste payload, so the line lands in the input box but
  is never submitted. Symptom on iPhone: reply text appears in the
  codex/claude prompt and just sits there with no submit.

  DO NOT change this rule without verifying with a real codex AND a
  real claude interactive session. The fake-PTY tests cannot catch the
  TUI parser behaviour — only a live dogfood pass against the actual
  provider TUIs proves the gap is doing its job. If you believe atomic
  writes are correct again (e.g. provider parser changes), add a
  fixture that mirrors the bracketed-paste END handling and verify
  both providers submit before relaxing the rule.

Regression tests: `packages/cli/test/instruction_delivery_invariant.test.js`
(run with `STEER_INTEGRATION=1 npm test`).

## PTY Flood Durability (G15)

A wrapped session that has already received a user instruction and produced
a trusted reply MUST keep both signals visible to the classifier indefinitely,
regardless of PTY status-bar repaint volume.

Concretely: the most recent `user` chunk and the most recent
`report`/`stdout`/`stderr` chunk MUST remain queryable for the lifetime of the
session, even if the per-session `transcript_entries` row cap evicts them
under PTY flood.

Source of truth: `sessions.last_user_at` / `last_user_text` /
`last_trusted_at` / `last_trusted_text` (migration `0008_session_snapshot.sql`).
`store.appendTranscript` updates the snapshot columns on every trusted/user
chunk. `store.refreshActionCard` reads the classifier input from these
columns, not from `transcript_entries`.

Why. The 5/13 dogfood regression: codex PTY status-bar repaint flushes
~60 chunks/min in idle. The 100-row `transcript_entries` cap
(`migration 0005_transcript_cap.sql`) is stream-agnostic, so within ~2 min
of the user's reply both the user row and the report row are evicted. The
classifier then sees `latestUserIndex === null` and `latestOutputIndex === null`
and emits a "session just opened; send your first instruction" stub waiting
card that overwrites the real one. iPhone shows the stub, ~50 min after the
real answer.

DO NOT remove the snapshot columns or route the classifier back through
`transcript_entries` without first redesigning the cap to be stream-aware
(separate budgets per stream) and proving the budget survives a 5000-chunk
PTY flood.

Regression tests:
- `packages/agent/test/transcript_pty_flood.test.js`
- `packages/agent/test/classifier_stub_card_regression.test.js`
- `scripts/stress-pty-flood.sh` — end-to-end PTY stress against a real
  wrapped session in an isolated `STEER_HOME`.

## Source Rules

- `report`, provider-native stdout/stderr, and hook/app-server events are trusted action-card sources.
- Raw `pty` output is not a trusted action-card source and must not drive visible action cards.
- The Mac app is not a live terminal preview; it shows stopped/actionable reports only.
- Notifications are only for notifiable stopped/action cards.
- Notification identity is stable per card id; changing repaint summaries must not create repeated notifications.

## Verification Commands

Run before committing changes that touch wrappers, classification, Mac app card loading, notifications, or terminal rendering:

```sh
npm test
swift build --package-path apps/mac
scripts/build-mac-app.sh
```

Manual dogfood check:

```sh
steer codex
steer send <sessionId> "Say READY and wait."
```

Expected result: session start/running does not create a card, stopped reports open one readable card, sending from Steer closes it, the next stopped report reopens it, and no repeated notifications fire while the terminal is only repainting progress.
