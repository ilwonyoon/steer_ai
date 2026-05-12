# Storage production-readiness

Status: design draft (2026-05-12). Blocks v3 PR 2.

## Why this exists

User QA on v3 PR 1 surfaced a wrapper regression — iPhone replies
land in Codex, Codex responds, but the new card never publishes
to the relay and the iPhone chip stays "1 running" forever. v3
events table proved sync was healthy; the breakage is on the Mac
agent side.

Root cause traced to a runaway `~/.steer/steer.sqlite`:

| What | Today |
|---|---|
| File size | **1.8 GB** (after 5 days of dogfood) |
| `transcript_entries` rows | **1,171,050** |
| `messages` rows | **1,171,021** |
| Of `transcript_entries`, `pty` stream | 1,168,456 rows / 316 MB |
| Of `transcript_entries`, valuable streams (`stdout`/`report`/`user`/`system`) | 3,140 rows / 0.6 MB |

The agent process opens this DB at startup. With multiple
`steer codex`/`steer claude` wrappers running concurrently, each
tries to spin up a fresh SteerAgent if `~/.steer/steer.sock` is
missing, and only the first one wins. The losers crash with
`SQLITE_ERROR: database is locked` because schema validation +
WAL replay on a 1.8 GB file with 4 MB of WAL takes longer than
SQLite's default busy-timeout window. The crashed agent had a
wrapper socket attached; when the agent dies, the socket closes,
and the surviving agent flips that session's `run_state` to
`disconnected` per `agent.js:66-80`. After that, no card publish
fires for that session — including the answer the user is
waiting on.

So the user-visible symptom (chip stuck on "1 running") is two
hops removed from the actual defect (transcript bloat). This
doc fixes the actual defect.

## Goals

- After this work, a typical user's `~/.steer/steer.sqlite` stays
  under ~50 MB even after months of daily use.
- Agent startup is fast enough that two concurrent wrappers don't
  race the SQLite open. The first agent always wins; the second
  notices the lock and exits cleanly.
- The data the product actually cares about — `report` stream
  (classifier input), card lifecycle, instruction lifecycle,
  session metadata — survives every cleanup pass intact.
- Test coverage proves the cleanup never deletes data the
  classifier or UI reads.

## Non-goals

- Changing how SteerAgent stores cards / sessions / instructions.
  Only the transcript stream is in scope.
- Migrating storage off SQLite. The schema is correct; the rows
  we're storing are wrong.
- Touching the relay-side `events` table. v3 PR 1 already wrote
  it; PR 2+ continues that arc unchanged after this track lands.

## What we actually store today

Per `packages/agent/src/agent.js:188` (`appendTranscript`) every
chunk emitted by a wrapper gets written to `transcript_entries`
with one of these `stream` values:

| stream | producer | actual value to the product |
|---|---|---|
| `pty` | raw PTY bytes from the wrapped child | **near zero** — almost entirely cursor moves, line clears, color escapes, title spinner updates. Classifier does not read it (per `docs/CLASSIFIER_CONTRACT.md` "NOT trusted"). |
| `stdout` | non-PTY child stdout (headless adapters only) | valuable |
| `stderr` | non-PTY child stderr (headless adapters only) | valuable |
| `report` | provider idle reports / Claude Stop hook / Codex `turn/completed` | **critical** — classifier input |
| `user` | user-typed instructions injected | useful audit |
| `system` | wrapper-internal events (register, instruction ack) | useful debugging |

`pty` makes up 99.7 % of rows and 99.8 % of payload bytes. The
classifier contract already says PTY repaint isn't trusted for
card decisions, so we don't read it for product logic — only for
the (currently never-exercised) "look at the raw transcript"
debugging path.

## Three coupled changes

### Change (a) — store-time PTY filter

Skip writing `pty` chunks that we know are pure terminal repaint
and add zero product value. Implemented inside
`appendTranscript` so the savings happen before the row ever
reaches SQLite — no migration cost on existing rows.

Filter rule (conservative on purpose; only drops things we are
sure carry no information):

1. Chunk's `stream` is `pty`, AND
2. After ANSI stripping (lightweight regex), the remaining
   printable text is empty or whitespace only.

Anything with actual printable bytes — the Codex banner,
streaming AI output, error messages, anything a user could
visually read — passes through unchanged. We are throwing
away cursor moves and color escapes, not output.

Two safety nets:

- A test (`packages/agent/test/transcript_filter.test.js`) that
  asserts the filter never drops a chunk containing
  non-whitespace text after ANSI strip.
- An `experimental:transcript-filter` flag in
  `~/.steer/steer.config.json`, default `on`. If the filter
  ever drops something it shouldn't, the user can flip the flag
  off and we recover ground truth from `~/.steer/sessions/<id>.log`
  (per-session log file, written separately, never filtered).

Expected impact: ~99.7 % drop in `transcript_entries` row count
for new sessions.

### Change (b) — periodic prune of old transcript rows

Even with (a) in place, long-running power users will still
accumulate `transcript_entries` over months. Run a daily prune
inside the agent (no separate cron; just a setInterval) that
deletes rows older than 7 days from `transcript_entries`,
`messages`, and `terminal_excerpts`.

Cards, sessions, and instructions are NOT pruned. They're the
authoritative state that the UI reads and that the v3 event log
mirrors; deleting them would break product behavior.

Tunable in the same `steer.config.json`:

```jsonc
{
  "storage": {
    "transcriptRetentionDays": 7,   // 0 = disabled
    "vacuumAfterPrune": true
  }
}
```

The prune runs at most once per 24 h based on a `prune_state`
sentinel row, so a flapping agent doesn't kick off the same
work repeatedly. Vacuums after pruning to actually reclaim disk
space (SQLite leaves freelist pages otherwise).

### Change (c) — SQLite reliability hardening

Three small settings on the store open path
(`packages/agent/src/store.js`):

```js
db.exec("PRAGMA busy_timeout = 5000;");
db.exec("PRAGMA journal_mode = WAL;");        // already on, asserts the mode
db.exec("PRAGMA wal_autocheckpoint = 1000;"); // pages
```

`busy_timeout` is the direct fix for the lock-contention crash:
SQLite will retry for 5 seconds before giving up, which lets the
losing agent gracefully back off and exit instead of crashing.

A guard at agent startup: if `~/.steer/steer.sock` is present
AND the listening process is alive AND responds to a ping,
exit immediately with a "another agent is running" log line.
This is the real fix for the "multiple agents crashing each
other" pattern — `busy_timeout` is the safety net.

### One-time cleanup of the existing 1.8 GB file

The above three changes prevent future bloat but don't shrink
today's file. Ship a one-shot cleanup script that:

1. Stops every running wrapper and the agent (we already
   do this in `scripts/refresh-dogfood.sh`).
2. Runs the new prune on the existing DB.
3. `VACUUM`s.
4. Re-launches the agent.

Expected outcome: 1.8 GB → ~50 MB based on the row counts above
(sessions + cards + instructions + last-week transcripts only).

## Tests added

- `packages/agent/test/transcript_filter.test.js` — filter
  preserves printable content, drops pure ANSI repaint.
- `packages/agent/test/transcript_prune.test.js` — prune
  deletes only `transcript_entries`/`messages`/`terminal_excerpts`
  older than the configured retention, leaves
  cards/sessions/instructions intact.
- `packages/agent/test/agent_singleton.test.js` — second agent
  startup against an active socket exits cleanly, doesn't crash
  on the DB lock path.

All three are gating on the validation checklist below; PR
doesn't ship without them green.

## Validation gate

Per `docs/SYNC_ARCHITECTURE_V3.md` "Process + validation" — same
shape, scoped to this storage track. PR is green when:

Automated:
- [ ] `npm test` passes including the three new test files.
- [ ] Manual: spin up 4 `steer codex` sessions concurrently
  (one per project the user typically has open), confirm no
  "database is locked" lines in `~/.steer/agent.log`.

User-facing golden set — same items, but new line added:

| # | Item | Pass criteria |
|---|---|---|
| G1–G7 | Existing | All still green. Storage fix must not regress them. |
| G12 | sqlite stays small | After a 1-h dogfood session with 4 wrappers active, `~/.steer/steer.sqlite` grows by < 5 MB. |
| G13 | No agent crashes | Tail `~/.steer/agent.log` during the 1-h session; zero "database is locked" lines. |
| G14 | Codex answer arrives after reply | The exact scenario from today's regression: iPhone reply → Codex answers → new card publishes to relay → iPhone chip clears → carousel updates. Within 10 s. |

G14 is the gate. If it doesn't pass, the storage fix didn't
actually resolve the wrapper-disconnect chain, and we haven't
found the right root cause.

## PR sequencing

Three PRs, each independently mergeable:

1. **PR S1 — change (c) + agent singleton check + busy_timeout.**
   Smallest risk. Fixes lock contention without touching data.
2. **PR S2 — change (a) PTY filter + the experimental flag.**
   Stops future growth. Compatible with PR S1.
3. **PR S3 — change (b) prune + cleanup script + one-time
   1.8 GB recovery.** Recovers existing disk. Compatible with
   S1 + S2.

Each PR carries its own dogfood checkpoint; G14 is the gate for
S3 (the only PR that touches the user-observable chain).

Once S3 ships green, v3 PR 2 resumes.

## Decision log

| Date | Decision | Why |
|---|---|---|
| 2026-05-12 | Pause v3 PR 2 to fix storage first. | User: 안정성과 최적화가 런칭보다 중요. Wrapper disconnect after iPhone reply is unshippable. v3 PR 1's events table is harmless to leave running. |
| 2026-05-12 | Filter `pty` at write time rather than only pruning later. | 99.7 % of rows are pure ANSI repaint with no product value. Filtering at the write boundary is cheaper than write+prune and avoids a single multi-GB file ever existing in production. |
| 2026-05-12 | 7-day retention for `transcript_entries`. | Long enough for "what happened yesterday" debugging, short enough to keep total size bounded. Tunable in config for power users who want longer. |
| 2026-05-12 | Cards / sessions / instructions never pruned. | Those are the product state. The UI and v3 event log both depend on them being durable. Transcripts are debugging only after the classifier has consumed them. |
