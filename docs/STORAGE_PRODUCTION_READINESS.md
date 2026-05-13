# Storage production-readiness

Status: **shipped through Phase 4**, 2026-05-12. Phase 5 (this
doc itself) refresh below. v3 PR 2 unblocked.

> **2026-05-12 update.** The originally-planned S2 → S7 sequence
> (age-based prune + retention.config + ops surfaces) was
> superseded mid-implementation by a simpler design: the DB
> stores only data with a live consumer, period. Anything
> derivable from "what's running right now" is built up; anything
> historical is not stored at all. The actually-shipped phases
> (S2 + Phases 1–4 below) take the dogfood DB from **2.0 GB to
> 1.2 MB**, with no user-tunable retention knobs and no periodic
> "log rotation" semantics. The S3 / S6 / S7 entries below are
> kept for context; they're no longer needed in practice. The
> remaining open items are S4 (corruption recovery), S5
> (health.json — small, optional), and follow-up cleanup of dead
> code from the old plan.

> Note: an earlier draft of this document scoped only the `transcript_entries`
> bloat. A deeper audit (see "Production-readiness audit" below) found
> the wrapper-disconnect chain has TWO root causes coupled — runaway
> transcript writes are one, an agent-spawn race that singleton-checks
> on the wrong primitive is the other. Both are addressed here. The
> earlier "Three coupled changes" section is preserved but is now one
> piece of a larger production-readiness fix.

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

## Production-readiness audit (2026-05-12)

To answer "is the storage layer production-grade?", I evaluated
the seven dimensions a production data layer must cover. Each is
graded as ✅ ready, ⚠ partial, or ❌ not ready, with the
evidence pulled from the live code.

### 1. Data lifecycle / retention — ❌

There is no retention policy on any table. `transcript_entries`,
`messages`, `terminal_excerpts`, `metric_events`, and even
`sessions` (rows with `run_state = ended` or `disconnected`)
accumulate forever. Concrete evidence from the user's dogfood:

| Table | Row count | Growth source |
|---|---|---|
| `transcript_entries` | 1,171,050 | every PTY chunk written, mostly ANSI repaint |
| `messages` | 1,171,021 | mirrors transcript_entries 1:1 — every chunk also becomes a message row |
| `sessions` | 88 | many `disconnected` / `ended` rows that the UI never reads |
| `metric_events` | 2,111 | session lifecycle markers; no cleanup |

The 1:1 ratio between `messages` and `transcript_entries` is its
own design problem — every PTY chunk creates two rows. We'll
address that in the schema part of this audit.

### 2. Schema migration system — ❌

The schema is applied via `db.exec(schemaSql)` on every startup,
where `schemaSql` is a static string built from `CREATE TABLE IF
NOT EXISTS`. There is a `grdb_migrations` table — clearly carried
over from an earlier Swift/GRDB prototype — but **nothing in the
agent code reads it, and nothing in the agent code defines a
forward migration**. New columns are added by editing the schema
string in place; existing databases skip the column because the
`CREATE TABLE IF NOT EXISTS` is a no-op once the table exists.

Concrete consequence: today's 1.8 GB user DB does NOT have any
columns we might add tomorrow. We've already shipped at least
one ALTER TABLE in the relay's migrations (`0005_aps_environment`)
and have no equivalent mechanism on the Mac agent side.

This is a production blocker independent of the bloat. Without
forward migrations, every future schema change is a "the user
must wipe `~/.steer/steer.sqlite`" operation, which is
unacceptable once the app ships.

### 3. Concurrency / lock model — ⚠ broken in practice, partial in design

There IS a singleton check (`agent.js:299-307` —
`prepareSocketPath` connects to the socket and exits if a peer
answers). The fault is its placement: it fires BEFORE
`createStore`, and the wrapper-side spawn path
(`packages/cli/src/index.js:802` and `agent_link.js:120`) only
checks `fs.existsSync(socketPath)` before spawning. So under
concurrent wrapper startup:

```
wrapper A      wrapper B          agent process X      agent process Y
spawn agent ─────────► [start]                          spawn agent ─────────► [start]
   wait for           wait for                                                  
   socket             socket
                                  prepareSocketPath()  prepareSocketPath()
                                   ↓ no socket          ↓ no socket
                                  createStore()         createStore()
                                   ↓                     ↓
                                  ←── DB LOCK CONTENTION → 
                                   ↓                     ↓
                                  crash                  crash
```

The "agent already running" check is socket-based but the agent
hasn't created the socket yet. Both losers crash. Even after the
fix to filter transcripts + shrink the DB (which reduces the
window), the race exists. **We need a real lock primitive — a
filesystem lockfile or `flock` — that's taken BEFORE
`createStore` and held until the listener is bound.**

WAL mode is on. `busy_timeout` is set to 5000ms but only AFTER
`createStore` opens the database — the `createStore` call itself
is what hits the lock, and `busy_timeout` doesn't apply yet at
that point. Subtle order-of-operations bug.

### 4. Failure / partial-failure recovery — ❌

What happens when:

| Event | Today's behavior | Production behavior expected |
|---|---|---|
| Agent crash mid-write | Last batch lost. Wrapper socket closes. Session flips `disconnected`. No card. | Wrapper detects agent gone, reconnects when agent restarts, replays buffered events. |
| SQLite corruption (`SQLITE_CORRUPT`) | Agent crash loops. User has no path forward. | Detect on open. Rename corrupt DB aside, start fresh, surface a "your local history was reset" banner in Settings. |
| Disk full (`SQLITE_FULL`) | Writes start failing silently in the agent. Wrapper continues to send. State drifts. | Agent surfaces disk-full as a system error to wrappers; wrappers stop accepting new instructions until cleared. |
| `~/.steer/steer.sqlite` deleted while agent running | Agent next write fails; later opens recreate the file but lose all in-flight state. | File handle survives the unlink (POSIX semantics); agent should detect deletion at startup and refuse to share state with future agents that opened the recreated file. |
| WAL file orphaned (e.g. forcible OS kill) | Recovers on next open via SQLite's auto-checkpoint. ✅ this one is fine. | Same. |
| Schema mismatch (downgrade) | Statements fail at `prepare` time. No useful error to user. | Agent detects schema-version mismatch, refuses to start, prints "this DB was written by a newer Steer; please update or delete ~/.steer/steer.sqlite". |

Only one of six paths is handled (WAL recovery, which SQLite
does for us). Everything else is silent failure or crash.

### 5. Operational visibility — ❌

There is `~/.steer/agent.log` (line-appended console output) and
`~/.steer/sessions/<id>.log` (per-session transcript copy).
Neither contains:

- DB size or row counts. The user has no way to know they're
  approaching disaster until the agent crashes.
- Slow query warnings. A query that takes 200ms on a 50MB DB
  takes 5s on a 1.8GB DB; the agent doesn't notice.
- Lock-contention events. We had to read raw error stacks.
- Disk-free pressure. No early warning.

A small `~/.steer/health.json` that the agent rewrites every N
seconds with row counts + DB size + WAL size + last-checkpoint
timestamp is the bare minimum a user (or our diagnostics) can
look at. The Mac UI's Settings → Storage section can render
this.

### 6. Performance budget — ⚠ no SLO, indexes present

Indexes are reasonable:
```
idx_sessions_state                  ON sessions(run_state, updated_at)
idx_messages_session_time           ON messages(session_id, timestamp)
idx_instructions_session_status     ON instructions(target_session_id, status)
idx_transcript_entries_session_time ON transcript_entries(session_id, timestamp)
idx_metric_events_session_time      ON metric_events(session_id, timestamp)
idx_action_cards_state_priority     ON action_cards(state, priority, updated_at)
```

What's missing is any measured budget. We don't know the p99
latency of `loadCards()`, `loadLiveSessions()`, or
`appendTranscript()` against a representative DB. The Mac UI runs
these on its 2s reload tick, so a slow query directly degrades
the UX.

Concretely: `appendTranscript` does TWO inserts per chunk (one
into `transcript_entries`, one into `messages`). At 1.17 M chunks
over five days, that's ~5 inserts/sec sustained — each in its own
implicit transaction because there's no explicit batching. On a
1.8 GB DB with WAL replay every reopen, the `BEGIN`/`COMMIT`
overhead alone is 95%+ of the wall time.

### 7. Backup / restore — ❌

There is no backup path. If `~/.steer/steer.sqlite` is lost
(disk fail, accidental rm, brewing dual-boot), the user loses:

- The classifier's prior context for every session.
- All metric history.
- All transcript history for any session they want to revisit.

Cards / sessions / instructions are also lost, but the Mac app
recovers gracefully (no-cards empty state). The other four,
however, just vanish.

For v1, "no backup, by design" is an acceptable answer **if it's
called out in product copy and in the Settings → Storage panel**.
Today there is no such surface. Users won't know they have no
backup until they need one.

---

## What this changes about the plan

The earlier "three coupled changes" (PTY filter, 7-day prune,
busy_timeout + singleton check) are necessary but not sufficient.
The audit makes the actual fix scope larger:

| Audit dimension | Plan addition |
|---|---|
| 1. Retention | PTY filter at write + 7-day prune of transcripts/messages/metric_events + retention for `disconnected`/`ended` sessions > 30 days. **Plus drop the messages↔transcripts duplication so we stop writing two rows per chunk.** |
| 2. Migrations | Introduce a real `schema_version` table + ordered numbered migration files mirroring the relay's `packages/relay/migrations/000N_*.sql` pattern. PR S0 ahead of everything else. |
| 3. Concurrency | `flock`-based lockfile at `~/.steer/agent.lock` taken before `createStore`. Wrappers also acquire it before spawning. `busy_timeout` reorder. |
| 4. Recovery | Corrupt-DB detection at open with quarantine-and-start-fresh, plus a Settings UI banner. Disk-full → wrapper-side circuit-breaker. Schema-mismatch → refuse-to-start with actionable message. |
| 5. Observability | `~/.steer/health.json` written every 30s. Mac UI Settings → Storage panel that reads it. |
| 6. Performance budget | Microbenchmarks in `packages/agent/test/store_perf.test.js` (already exists — extend) covering `appendTranscript`, `loadCards`, `loadLiveSessions` at a representative DB size. SLO: p99 < 50ms each. Batch `appendTranscript` writes into 250ms windows. |
| 7. Backup | Settings → Storage exposes an "Export local history" button that produces a `.steer-export.tar.gz` of the DB + per-session logs. No automatic backup until v2. |

That's seven PR-shaped pieces of work. Sequencing below.

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

## Actually-shipped design (supersedes S2–S7 below)

The audit answered "what state should this DB hold?" and the
honest answer was: just the state of currently-live and
currently-actionable work. The user's mental model is right —
*answering today's cards* is the entire purpose of the app.
Nothing the user does requires us to keep yesterday's
transcripts, last week's session metadata, or instrumentation
events nobody reads.

### Final data model

| Table | Lifetime | Why it's kept |
|-------|----------|---------------|
| `sessions` | until 1 h after `ended` or 24 h after `disconnected` | wrapper metadata; pruned by Phase 4 |
| `action_cards` (state='active') | until resolved by user | the inbox |
| `action_cards` (state='done') | until parent session prunes | history kept short for debug; cascades on session prune |
| `instructions` | until parent session prunes | retry path needs it; cascades |
| `terminal_excerpts` | 1:1 with active card | dropped by Phase 1 trigger when card → done |
| `transcript_entries` | per-session capped at 100 rows; full drop on `ended/disconnected` | Phase 2 trigger + ended-cascade |
| `schema_version` | forever | migration bookkeeping |
| ~~`messages`~~ | dropped in S2 | no consumer |
| ~~`metric_events`~~ | dropped in Phase 3 | no consumer |

### Why this beats the original S3 design

The original S3 ("age-based prune + retention.config") would have
kept a week's worth of transcript per session per day per Mac.
The new design keeps roughly the *classifier's working window* —
~100 rows per active session, period. Concretely:

- Steady-state DB size: ~1–2 MB regardless of usage age.
- No `retention.config` exposed to users; nothing to tune.
- No periodic "log rotation" job; mutations are O(1) per write
  via the cap trigger.
- DB size as an SLO becomes trivial: anything over ~10 MB is a
  bug.

### Migrations actually shipped

| Version | What | Live DB effect |
|---------|------|----------------|
| 0001 | initial schema | — (backstamp on pre-S0 DBs) |
| 0002 | `responseRevision` column + bump trigger | enables iPhone atomic chip-clear |
| 0003 | drop `messages` table + recreate FK-bearing tables without `source_message_id` | 1.28 M rows gone |
| 0004 | `terminal_excerpts` cascade triggers (card state='done' / DELETE / excerpt swap) | excerpt count tracks active card count |
| 0005 | `transcript_entries` per-session cap (100) + ended-cascade | 1.28 M → 200 rows |
| 0006 | drop `metric_events` | ~6 KB; eliminates one write per state change |
| 0007 | partial index on `sessions(run_state, ended_at)` | O(log n) prune predicate |

### Live DB recovery (dogfood, 2026-05-12)

A 2.0 GB DB compressed to 1.2 MB through this sequence:

1. Migration 0003 dropped `messages` → 654 MB.
2. Migration 0005 + the ended-cascade dropped 1.28 M transcript rows → 200 rows.
3. One-off `VACUUM` → **1.2 MB**.

`scripts/storage-recovery.sh` was no longer needed; the
migrations are the recovery script.

### Open items vs the original plan

- **S4 (corruption / disk-full)** — still useful, not yet shipped.
  The plan in §4 below still applies; the smaller DB makes it
  more tractable.
- **S5 (health.json)** — optional. With a 1.2 MB ceiling and no
  growth pattern, ops visibility is less interesting than it was
  in the 1.8 GB world. A one-shot diag command beats a recurring
  health file.
- **S6 (perf SLOs)** — implicit. Pre-S2 numbers (p95 < 10 ms,
  500 writes/s sustained) hold without measurement on a 1.2 MB
  DB.
- **S7 (backup / export)** — pre-existing `cp ~/.steer/steer.sqlite`
  is now a real backup option (small enough to copy in <1 s),
  but nothing automatic.

The remaining work is documentation cleanup (this section is the
canonical spec; the §S2–§S7 below are kept for history) and one
follow-up to drop `ChipReconciler` / `SessionSnapshot.runState`
publish-side dead code once a few weeks of telemetry confirm no
straggler client is hitting `/v1/sync/sessions`.

## PR sequencing (revised after audit)

> **Superseded.** The S2–S7 descriptions below are the original
> 2026-05-12 plan. Most of them did not ship as written — see
> the "Actually-shipped design" section above for what made it
> in. The headers stay so cross-references in older issues /
> commits still resolve.

Seven PRs, sequenced so each one independently unbreaks
production. Each has its own validation gate; users can stop the
train at any PR and ship from there if needed.

### PR S0 — schema_version + migration runner

The foundation everything else needs. Adds a `schema_version`
table, a `packages/agent/migrations/000N_*.sql` directory, and a
runner in `createStore()` that applies pending migrations in
order at startup. Existing DBs get version=1 backstamped to
match today's schema string. No behavior change.

Why this comes first: PR S1's lockfile + busy_timeout reorder is
small SQL touching pragmas only, but PR S2's "drop the messages
table mirror" requires an actual ALTER + backfill, and PR S5
adds new columns to `sessions` for retention status. Without a
migration system, we can't ship those.

### PR S1 — concurrency hardening (the immediate unbreak)

- Lockfile at `~/.steer/agent.lock` acquired via `flock` BEFORE
  `createStore`. Released on graceful shutdown; OS reclaims on
  crash.
- Wrapper-side: same lockfile contention check in
  `cli/src/index.js` and `cli/src/agent_link.js` before spawning
  an agent. If the lock is held, wait + poll for the socket
  instead of spawning a second agent.
- `busy_timeout` and other PRAGMAs moved into a connection
  factory that runs them before any DDL, so the schema apply
  itself benefits from the timeout.
- Singleton check at `prepareSocketPath` keeps its current
  socket-based dedupe as a second line of defense.

This is the smallest PR that stops the chain that produced
today's regression. Ships first; the rest can take longer.

### PR S2 — PTY filter + drop messages↔transcripts mirror

Two coupled changes:

1. `appendTranscript` filters `pty` chunks at write time. Any
   chunk whose post-ANSI-strip content is whitespace-only is
   dropped. Other streams (`stdout`/`stderr`/`report`/`user`/
   `system`) always pass through.
2. The `messages` insert that currently fires on every chunk
   gets removed. The classifier + UI both read state from
   `action_cards` + `transcript_entries` + `sessions`; the
   `messages` table is an unused vestige. Migration drops the
   table; backfill is unnecessary because nothing references
   it.

Expected impact: row growth drops by ~99.7%; daily transcript
write IOPS drops to <1/s sustained.

`experimental:transcript-filter` config flag is the kill-switch
if the filter ever drops something valuable. Default `on`.

### PR S3 — retention prune + one-time 1.8 GB recovery

- Daily prune (setInterval inside the agent, idempotent via
  `prune_state` sentinel row): delete `transcript_entries`
  older than 7 days, `metric_events` older than 30 days,
  `sessions` with `run_state IN ('ended','disconnected')` and
  `updated_at` older than 30 days.
- `terminal_excerpts` get pruned cascade-style when their
  parent session is deleted (FK ON DELETE CASCADE migration).
- Cards / instructions are never pruned.
- One-shot cleanup script at `scripts/storage-recovery.sh`:
  stops wrappers + agent, runs the new prune against the live
  DB, `VACUUM`s, restarts the agent. Exists for users like
  today's 1.8GB-on-disk state.

`storage.transcriptRetentionDays`, `storage.metricRetentionDays`,
`storage.endedSessionRetentionDays` all live in
`~/.steer/steer.config.json`, tunable per user.

### PR S4 — failure / corruption recovery paths

- `createStore` wraps `db.prepare(schemaSql)` in a try/catch
  that detects `SQLITE_CORRUPT` / `SQLITE_NOTADB` and renames
  the file to `~/.steer/steer.sqlite.corrupt.<ts>` before
  starting fresh.
- Schema-version mismatch (DB is from a newer Steer than this
  binary) → exit with actionable message, do NOT start fresh.
- Disk-full → agent surfaces a `system.error: disk_full` to all
  wrappers; wrappers stop accepting instructions until the
  agent's next health check reports green.
- Settings → Storage UI surface (small, just one row in
  Settings) shows current health state. When corrupt-quarantine
  triggered, a one-time banner appears.

### PR S5 — observability + health.json

Agent writes `~/.steer/health.json` every 30s with:

```jsonc
{
  "ts": 1778603467,
  "dbBytes": 47_321_088,
  "walBytes": 1_048_576,
  "rowCounts": { "sessions": 12, "transcript_entries": 4_201, ... },
  "lastCheckpoint": 1778603450,
  "pendingPrune": false,
  "lastError": null
}
```

Mac UI Settings → Storage section reads this. Users see DB size
trend. Future telemetry (opt-in) can summarize this.

### PR S6 — performance budgets + measured SLOs

Extend `packages/agent/test/store_perf.test.js` to bench:

- `appendTranscript` p99 across 10k chunks, on both empty + 50MB
  pre-seeded DBs. SLO: p99 < 10ms.
- `loadCards`, `loadLiveSessions`, `listQueuedInstructions` —
  SLO: p99 < 50ms.
- `prune` end-to-end SLO: < 5s on a 200MB DB.

Plus a 250ms-window batched write path for `appendTranscript`
(buffers chunks in memory, flushes in a single transaction).
This reduces the per-chunk transaction overhead from 5 inserts
of 1KB each to one insert of 5KB.

### PR S7 — backup / export

Settings → Storage → "Export local history" produces a
`steer-export-<date>.tar.gz` containing the DB file + per-session
log files. v1 manual; v2 can add scheduled / iCloud Drive.

Also adds Settings copy explaining "Steer keeps your history
only on this Mac. Use Export to keep a copy." So new users know
the durability story up front.

### Sequencing rationale + train-stop options

```
S0 (migration runner)  ─► S1 (concurrency)  ─► [v3 PR 2 can resume here, optional]
                              │
                              ├─► S2 (PTY filter + messages drop)
                              │       │
                              │       └─► S3 (retention + recovery)
                              │             │
                              │             └─► S4 (corruption / disk-full)
                              │                   │
                              │                   ├─► S5 (health.json)
                              │                   ├─► S6 (perf budgets)
                              │                   └─► S7 (export)
                              │
                              └─► [or stop here for the App Store launch
                                   if S2/S3 prove stable on their own]
```

Hard stop options for the user:
- After S1 only — the immediate unbreak. Storage still bloats but
  agent crashes stop. Acceptable for a quick App Store ship if
  needed.
- After S3 — bloat fixed too. The DB stays bounded forever. Most
  realistic launch-readiness point.
- After S7 — full production-grade. Where we're aiming.

Each PR has a dogfood checkpoint with the full golden set. Any ❌
stops the train at that PR.

## Updated golden set additions

Adds to `docs/SYNC_ARCHITECTURE_V3.md` G1-G14:

| # | What to verify | Steps | Expected |
|---|---|---|---|
| G15 | Migration runner works on existing DB | Apply S0 to a copy of the user's 1.8 GB DB | Agent starts; `schema_version` row present; no data loss; same query results as before |
| G16 | Two agents can't race | Start two `steer codex` simultaneously in different terminals | Exactly one agent process is alive afterward; both wrappers attach to the same socket; no "database is locked" lines |
| G17 | sqlite stays bounded over a week | 7-day soak (or simulated equivalent in tests) | DB size growth slope is < 1 MB/day at steady normal use |
| G18 | Corrupt DB doesn't brick the app | `dd if=/dev/urandom of=~/.steer/steer.sqlite bs=1024 count=10 conv=notrunc` then start agent | Agent quarantines the file, starts fresh, Settings shows banner explaining the reset |
| G19 | Disk-full surfaces to user | `truncate -s $(df ~/.steer | awk 'NR==2{print $4}')K /tmp/fill` (simulated) | Agent reports system error to wrappers; UI shows storage banner; existing cards remain readable |
| G20 | Export produces a restorable tarball | Settings → Export, then on a fresh machine: untar to `~/.steer/`, start agent | Same cards / sessions / transcripts visible |

G14 (the Codex-answer-after-reply that broke today) stays in
`SYNC_ARCHITECTURE_V3.md` since it's the user-observable shape;
G15-G20 here are the storage-track-specific gates.

## Decision log

| Date | Decision | Why |
|---|---|---|
| 2026-05-12 | Pause v3 PR 2 to fix storage first. | User: 안정성과 최적화가 런칭보다 중요. Wrapper disconnect after iPhone reply is unshippable. v3 PR 1's events table is harmless to leave running. |
| 2026-05-12 | Filter `pty` at write time rather than only pruning later. | 99.7 % of rows are pure ANSI repaint with no product value. Filtering at the write boundary is cheaper than write+prune and avoids a single multi-GB file ever existing in production. |
| 2026-05-12 | 7-day retention for `transcript_entries`. | Long enough for "what happened yesterday" debugging, short enough to keep total size bounded. Tunable in config for power users who want longer. |
| 2026-05-12 | Cards / sessions / instructions never pruned. | Those are the product state. The UI and v3 event log both depend on them being durable. Transcripts are debugging only after the classifier has consumed them. |
| 2026-05-12 | Adopt a real migration runner (S0). | Per audit dimension 2: the agent has no forward-migration mechanism today. Without it every future schema change forces users to wipe their DB. Carrying over the relay's numbered-migration pattern. |
| 2026-05-12 | Drop the `messages` table (S2). | Per audit dimension 6: `appendTranscript` writes TWO rows per chunk (one transcript, one message) and neither the UI nor the classifier reads `messages`. Removing it halves the write IOPS and the row count. |
| 2026-05-12 | Filesystem `flock` lockfile, not socket-only singleton (S1). | The current singleton check is socket-based, but `createStore` runs before the socket binds. Two agents can race past the singleton check and both crash on the SQLite open. `flock` is taken before `createStore` and held until shutdown. |
| 2026-05-12 | Settings → Storage UI as the observability + recovery surface (S4 + S5 + S7). | Audit dimensions 4, 5, 7 all need a user-facing surface. One Settings panel handles all three: shows DB size, surfaces corruption / disk-full banners, hosts the Export button. |
| 2026-05-12 | App Store ship can happen after S3 if needed. | Audit-grade fix is S0–S7; the smallest "stop the bleed AND fix the bloat" is S0–S3. User can decide at S3 whether to ship or continue to S7. |
