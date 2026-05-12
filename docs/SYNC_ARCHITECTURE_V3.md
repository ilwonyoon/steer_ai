# Sync architecture v3 — event-sourced single source of truth

Status: design draft (2026-05-12), not yet implemented.
Supersedes: `docs/SYNC_ARCHITECTURE_V2.md` (kept for historical context).

This document is the master plan for the next sync rewrite. It
exists because v2 fixed the worst polling cost but left two
architectural defects that keep producing regressions:

1. **Two consistency models coexist.** Polling claims "the relay's
   current state is what I just got back"; WebSocket push claims
   "the next event is what I just received". When they disagree —
   and they always do, somewhere in the window — the UI flickers,
   chips stay stale, replies arrive late, or cards reappear after
   being resolved.
2. **Cost is proportional to time-online, not activity.** A user
   sitting on the iPhone home screen with the app closed is fine
   (no traffic). An idle user with the iPhone unlocked is not (15s
   presence polls forever). We want cost proportional to events
   that actually happen.

The fix in v3 is to remove polling entirely and treat the relay's
event log as the single source of truth.

---

## Goals + non-goals

### Goals

- One source of truth for "current sync state": the relay's
  append-only event log in D1.
- Latency target for state propagation Mac → iPhone (or
  iPhone → Mac) under normal conditions: **≤ 2 seconds** end-to-end.
- Idle-user cost target: **≤ 5 HTTP requests / hour / device**
  (heartbeat + occasional snapshot). Down from the current
  ~240/hour/device.
- Zero polling on the iPhone except for an initial bootstrap
  snapshot on cold launch and on every WebSocket reconnect.
- A `since=<cursor>` API that lets either client catch up after
  any disconnect (network drop, app backgrounded long, server
  rolled) without dropping events.

### Non-goals

- Multi-user fan-out, room sharing, multi-tenant isolation
  beyond per-Apple-user — out of scope for v3, addressed
  separately if the product reaches multi-user.
- Replacing the local SQLite store on the Mac side. The Mac stays
  authoritative for its own sessions and writes through the agent.
  We are only changing the wire between Mac, relay, and iPhone.
- E2E encryption — separate workstream. Today's "encrypted in
  transit" copy stays accurate (HTTPS / WSS). Payload encryption
  is a v1.x feature.
- Migrating off Cloudflare. Workers + D1 + Durable Objects is the
  target deployment surface. v3 is designed around their cost +
  consistency model.
- Sparkle / iOS NSE / SignInPrompt redesign / App Store assets —
  unrelated tracks.

---

## Mental model

The cleanest analogue is **an event-sourced inbox** (think Gmail's
IMAP IDLE, not Slack's WebSocket app).

```
producers (Mac wrapper, iPhone reply input)
    │
    │  HTTP POST writes one event row to D1
    ▼
[ Relay : single event log per user ]
    │
    │  fan out a tiny "new event id N" nudge over WS to all
    │  connected sockets for that user
    ▼
consumers (Mac SyncClient, iPhone SyncInbox)
    │  on receiving the nudge, GET /v1/sync/events?since=cursor
    │  to fetch any events they haven't seen, replay them into
    │  local state, advance cursor
    ▼
[ local cached state per device ]
```

Three properties fall out of this shape:

1. **Idempotent replay.** Every event has a monotonic `id` and
   replay-on-cursor is deterministic. Reconnect, restart, or
   missed nudge — same path. No race conditions to debug.
2. **Cost = activity.** No event, no traffic. A user staring at
   the iPhone with no Mac changes produces zero relay calls
   between heartbeats.
3. **One consistency model.** State = `apply(events[0..cursor])`.
   The relay never needs to "know" what the iPhone thinks state
   is; the iPhone derives it from events alone.

---

## Event taxonomy

Every state change is one of a small set of events. This is the
exhaustive list for v3.

| Event type | Producer | Effect |
|---|---|---|
| `session.upsert` | Mac | Live session appeared / its `run_state` or `cwd` changed. Carries the full session row. |
| `session.remove` | Mac | Session ended / disconnected / fell off the live cutoff. Carries `sessionId` only. |
| `card.upsert` | Mac | New card or active card mutated (title / summary / terminal lines / category). Carries the full card payload. |
| `card.resolved` | Mac or relay | Card no longer active (user replied, session closed, dedupe). Carries `cardId`. |
| `instruction.queued` | iPhone | User sent a reply from iPhone. Carries `instructionId`, `targetSessionId`, `text`. |
| `instruction.injected` | Mac | Mac confirmed it injected the instruction into the wrapped CLI. Carries `instructionId`, success/failure. |
| `device.heartbeat` | either | "I'm online" pulse. Carries `deviceId`, `kind` (mac / ios), timestamp. Used only to derive "Mac connection chip" state on iPhone. |

Each event row in D1:

```sql
CREATE TABLE events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  type TEXT NOT NULL,
  payload TEXT NOT NULL,        -- JSON, schema per type
  created_at INTEGER NOT NULL,  -- ms epoch
  producer_device_id TEXT NOT NULL
);
CREATE INDEX events_user_since ON events(user_id, id);
```

Cursor = `MAX(id)` the consumer has applied. `GET /v1/sync/events?since=N`
returns `events WHERE user_id = ? AND id > N ORDER BY id LIMIT 500`.

---

## Instruction lifecycle — optimistic UI from send-frame

We can't make the network fast. We *can* make the user not notice
it. The architectural answer is: the moment the user taps send,
treat that as the canonical event horizon and drive a visible
status pipeline forward from there. The UI never blocks on a
network response.

This is the same mental model as iMessage / WhatsApp delivery
states — the user sees their message immediately, the status
indicator advances as the system catches up.

### The pipeline

Every instruction the user produces (Mac card reply, iPhone card
reply, future quick-action chips) travels through this status
machine. The internal pipeline has several technical stages —
POST sent, server id assigned, Mac wrapper injected, session
`run_state` flipped — but the **user only ever sees two visible
states**:

```
┌─────────────┐
│   queued    │  user tapped send, their reply text shows in the
│             │  card area with a quiet pulse. internally this
│             │  covers: POSTing → server-assigned id → Mac fetch
│             │  via nudge → PTY inject → session.run_state running.
└──────┬──────┘
       │
       │  success path: wrapper hits its next stop, a new card
       │  arrives in the stack. the queued pill simply fades as
       │  the new card slides in. no separate "done" state — the
       │  new card IS the completion signal.
       │
       │  failure path: POST 4xx, Mac never injects within
       │  timeout, wrapper exits unexpectedly. flip to "failed".
       ▼
┌─────────────┐
│   failed    │  same spot in the UI shows "Tap to retry". one tap
│             │  re-enters the pipeline at queued.
└─────────────┘
```

Why we collapse the technical stages into one user-visible
`queued`:

- **`sent` vs `injected` vs `running` are all "your message is
  on its way"** from the user's perspective. Splitting them
  into separate pills creates rapid flicker (sent → injected
  → running within ~1s) that's more distracting than
  informative.
- **The completion signal is the new card itself.** A separate
  "Done" pill that appears next to a fresh card and immediately
  fades is noise — the card's arrival IS the done state. We
  don't render redundant signals.
- **Failure is the only branch worth distinguishing.** And it
  takes over the same UI slot, so there's no extra surface to
  learn — the queued pill becomes the retry affordance.

The internal status field still tracks the full technical
sequence (queued, sent, injected, running, failed) because
that's what lets the data layer know when to advance and when
to time out. The UI just renders two buckets: "pending" (any
non-failed state before card arrival) and "failed".

### Why we draw the pipeline this way

- **The user's commit point is `queued`, not `sent`.** As soon
  as they hit send, the UI shows their message *in the
  conversation* with a faint status indicator. We never show a
  spinner *blocking* the message. The producer's send button is
  immediately reusable.
- **Status flows are visible, not implicit.** A pill near the
  message text reads `Sending…` → `Sent` → `Running` → fades out
  on the new card. The user can always look at it and know where
  their request is. This is the same trust signal SMS read
  receipts provide — visible progress is calming even when total
  duration is identical.
- **Failure has a single, in-line affordance.** A failed status
  becomes a tappable "Retry" right where the user typed. No
  modal, no toast, no "something went wrong" — just a single
  tap to re-enter the pipeline. Failed events are not
  auto-retried; user judgment governs.
- **The pipeline is identical on Mac and iPhone.** The Mac card
  composer surface gets the same status pill iPhone does. Code
  reuse is high; mental model is one. (Today the Mac composer
  has no status feedback at all — replies disappear into a void;
  v3 fixes this side effect of "Mac is the producer".)

### Status persistence

Each producer device keeps a small local table of in-flight
instructions:

```sql
CREATE TABLE inflight_instructions (
  client_uuid TEXT PRIMARY KEY,    -- our idempotency key
  target_session_id TEXT,
  text TEXT,
  status TEXT,                     -- queued | sent | injected | running | done | failed
  failure_reason TEXT,             -- nullable
  created_at INTEGER,
  last_status_at INTEGER,
  server_event_id INTEGER          -- nullable until 'sent'
);
```

Why we need this: an instruction can be in `queued` while the
device is offline (airplane mode). It must survive app restart
so the user sees their pending request the next time they open
the app. Status persistence lets the network be genuinely
asynchronous from the UI.

### Status transitions and the event log

Producer-local status advancement is **derived from the event
log**, not stored on the relay. The internal flow advances
through several technical stages even though the UI only
renders two:

1. User taps send → producer writes a row with status=`queued`,
   immediately shows the pending pill in the UI.
2. Producer POSTs `instruction.queued` event. On 200, advance
   internal status to `sent` and record `server_event_id`.
   UI does not change — still showing the queued pill.
3. Producer listens on its event stream. When it sees
   `instruction.injected` (matching idempotency key), advance
   internal status to `injected`. UI unchanged.
4. When it sees `session.upsert` with `run_state="running"`
   for the targeted session, advance internal status to
   `running`. UI unchanged.
5. When `card.upsert` arrives for the targeted session, the
   inflight row is **removed** entirely as the new card
   animates in. The new card itself is the completion signal;
   no separate "done" state is rendered.

Any of those steps can fail and transition to `failed`:
- step 2 fails → POST 4xx or final retry exhaustion
- step 3 fails → no `instruction.injected` within timeout
- step 4 fails → session reports failed run_state, or wrapper
  exits abnormally
- step 5 fails → no `card.upsert` within a longer timeout
  (configurable per session — some compute genuinely takes
  minutes)

On `failed`, the same inflight row stays in the UI with the
failed pill ("Tap to retry") swapped in. Retry resets the
internal status to `queued` with the same `client_uuid` so
the idempotency key carries over and prevents double-execution
if the original POST actually succeeded.

The local row is the source of truth for "what does my UI show
right now". The event log is the source of truth for "what
actually happened". They reconcile via `server_event_id` +
idempotency.

### Crash / quit / network drop behavior

- **Quit during `queued`.** Row persists. On next launch, the
  producer notices a pending row with no `server_event_id`,
  retries the POST. Idempotency key (the `client_uuid`)
  dedupes if the previous POST actually succeeded.
- **Quit during `sent`.** Row has `server_event_id` already.
  The producer's next snapshot/event fetch will surface
  `instruction.injected` etc. and advance the row.
- **Network drop between `queued` and `sent`.** UI shows
  "Sending…" with a quiet pulse. After ~10s the pill advances
  to "Will retry when online" but doesn't fail — only an
  explicit server 4xx fails. Retries follow normal backoff.
- **Mac never injects.** The event log will not produce an
  `instruction.injected` event. After a configurable wait
  (default 60s after `sent`), producer shows "Waiting on Mac"
  with a tappable "Send anyway" / "Cancel" affordance. This
  is the rare path; most of the time the WS nudge gets there
  in under a second.

### Why this belongs in the architecture, not the UI layer

A common reaction is "this is just how we render send buttons,
not architecture." It's actually architecture for two reasons:

1. The event-stream design *enables* clean optimistic UI. Without
   server-assigned ids + idempotency + producer cursor, every
   producer would have to track its own "did this actually
   happen" state, and reconciliation after disconnect would be
   custom code per surface. With the event log, the rule is
   simply "advance my row when the matching event arrives."
2. Failure handling has architecture-level invariants. A failed
   POST that the server actually processed must be detectable
   (idempotency by `client_uuid`); a successful POST that the
   server lost must be retryable. Both are properties of the
   event log + idempotency key shape, not of the UI.

The UI layer's only job is to *visually represent* the status
field. Everything that makes the status correct lives in the
data layer.

---

## API surface

The full HTTP surface after v3:

| Route | Method | Used by | Notes |
|---|---|---|---|
| `/v1/auth/apple` | POST | both | unchanged |
| `/v1/me` | GET / DELETE | both | unchanged |
| `/v1/sync/events` | GET | both | `?since=N&limit=500`. Catch-up replay. |
| `/v1/sync/events` | POST | both | Append one event. Server assigns `id`. |
| `/v1/sync/snapshot` | GET | iPhone | One-shot "active cards + live sessions + presence". Returned on cold launch and after every reconnect with `since` cursor — gives a stable starting point so the client never replays from id=0. |
| `/v1/sync/devices` | POST | both | Heartbeat / APNS token write. Cadence dropped to **5 min**, not 15 s. |
| `/v1/sync/devices/:id` | DELETE | both | Sign out, unchanged. |
| `/v1/stream` | WS | both | Receives `{type: "nudge", lastEventId: N}`. Nothing else. |

Routes deleted in v3:

- `GET /v1/sync/cards` — replaced by `snapshot` + event replay.
- `GET /v1/sync/sessions` — same.
- `GET /v1/sync/presence` — derived from `device.heartbeat` events.
- `GET /v1/sync/instructions/queued` — replaced by `instruction.queued` events Mac listens for.
- `PUT /v1/sync/cards/:id`, `DELETE /v1/sync/cards/:id` — replaced
  by `card.upsert` / `card.resolved` events.
- `POST /v1/sync/sessions` — replaced by `session.upsert` /
  `session.remove` events.
- `POST /v1/sync/instructions` — replaced by `instruction.queued`
  events posted via `POST /v1/sync/events`.
- `POST /v1/sync/instructions/:id/status` — replaced by
  `instruction.injected` events.

Note that the *write* still goes through HTTP. We do not accept
state writes over the WebSocket. This keeps the audit trail
intact (every event row has a server-side timestamp and the
producer's device id) and lets us reason about the system as
"WS is a nudge channel; D1 is the storage; HTTP POST is the
write".

---

## Client architecture

### Mac

```
SteerRootView                            SyncClient
  reload(every 2s)                         |
    └─ load local SQLite                   |
    └─ compute diff vs lastPublishedState ─┘
                                            └─ POST /v1/sync/events (one per diff)
                                            └─ on success, advance lastPublishedCursor

                                          WS receive
                                            └─ {type: "nudge", lastEventId: N}
                                            └─ if N > localCursor, GET /v1/sync/events?since=localCursor
                                            └─ for each event, route:
                                                 - instruction.queued → drainInstruction(event)
                                                 - card.resolved      → no-op (we're authoritative)
                                                 - session.*          → no-op
                                                 - device.heartbeat   → no-op
                                            └─ advance localCursor

                                          WS reconnect
                                            └─ same flow as above; nudge always arrives on accept
                                              with relay's MAX(id) so we catch up immediately.
```

Mac's only consumer responsibility is `instruction.queued`. Every
other event type is one Mac produces; replay of own events is a
no-op. We don't apply `card.resolved` to local SQLite because the
Mac is the producer of those — the local store already has the
truth.

### iPhone

```
SyncInbox                                NetworkClient
  cold launch
    └─ GET /v1/sync/snapshot ─────────────┘
    └─ apply snapshot → state, cursor

  background → foreground
    └─ check WS connection
    └─ if reconnected, snapshot path runs again

                                          WS receive
                                            └─ {type: "nudge", lastEventId: N}
                                            └─ GET /v1/sync/events?since=cursor
                                            └─ for each event, route:
                                                 - card.upsert    → upsert card in state
                                                 - card.resolved  → remove card
                                                 - session.upsert → upsert chip
                                                 - session.remove → remove chip
                                                 - instruction.*  → no-op
                                                 - device.heartbeat (kind=mac)
                                                                  → update Mac presence
                                            └─ advance cursor

                                          WS reconnect
                                            └─ GET /v1/sync/snapshot
                                            └─ rebase state, advance cursor

  user replies
    └─ POST /v1/sync/events {type: "instruction.queued", ...}
    └─ optimistic local apply
    └─ server-assigned id → confirm
```

iPhone holds the cursor in a property; never reads from disk
between launches. Cold launch always starts at snapshot anyway.

### What we delete

- `DevicePresenceObserver` timer (was 5s, then 15s). Gone.
- `GET /v1/sync/presence`, `GET /v1/sync/cards`, `GET /v1/sync/sessions`
  in `SyncInbox`. Gone.
- Mac `publishCard`, `resolveCard`, `publishSession`. All become
  `appendEvent(type: …)`.
- Mac `fetchQueuedInstructions` + `markInstructionInjected` +
  `markInstructionFailed`. Same — folded into events.
- `lastPublishedCardIds`, `lastPublishedCardHashes`,
  `lastPublishedChipFingerprints` snapshot maps in SteerRootView.
  Replaced by a single `lastPublishedCursor` integer.

---

## Cost model after v3

Per active user-pair (one Mac + one iPhone), assuming a typical
work session of 4 sessions running with 10 messages exchanged:

| Operation | Frequency | HTTP/hour | WS msgs/hour |
|---|---|---|---|
| Mac heartbeat | every 5 min | 12 | — |
| iPhone heartbeat | every 5 min | 12 | — |
| Event POSTs (Mac → relay) | per actual state change | ~30-100 | — |
| Event POSTs (iPhone → relay) | per reply sent | ~5-20 | — |
| WS nudges (relay → Mac) | per event | — | ~30 |
| WS nudges (relay → iPhone) | per event | — | ~30 |
| WS keepalive ping (client) | every 30 s | — | 120 |
| Snapshot fetch (iPhone) | on cold launch + reconnect | ~5 | — |
| Event-since fetches (iPhone, Mac) | per nudge that misses cache | ~30 | — |

**~150 HTTP / hour / user-pair**, down from 900–3,600. Activity
proportional. Idle user with no events: heartbeats only = 24 / hour.

WS message count rises but Cloudflare Workers paid plan prices WS
messages at roughly an order of magnitude cheaper than HTTP
requests, and the free plan doesn't meter them at all.

---

## Failure modes + how we handle each

### WS drops during an event burst

- Cloudflare idle close, transient cellular outage, Mac suspend.
- Client reconnects (existing backoff loop).
- On reconnect, relay's first WS message is `{type: "nudge", lastEventId: MAX}` automatically.
- Client compares to local cursor → calls `GET /v1/sync/events?since=cursor` → catches up.
- Maximum missed events: bounded by the time window the WS was
  down. Cost: at most one extra GET per reconnect.

### Client clock skew, duplicate events

- Server assigns `id` and `created_at`. Client trusts both.
- `id` is monotonic so reorder is impossible. Replay of the same
  cursor twice is idempotent (we apply by id, not by content).

### Network partition during event POST

- Mac POSTs an event, network fails mid-flight.
- Client retries with the same idempotency key (one we add per
  POST). Relay dedupes by `(producer_device_id, idempotency_key)`.
- If the original POST actually succeeded but the response was
  lost, the retry returns the same `id` and is a no-op server-side.

### Mac quits with unpushed local state

- Mac restarts. SteerRootView's first `reload()` rebuilds diff vs
  `lastPublishedCursor` (persisted to `~/.steer/sync-state.json`).
- Any state Mac had locally that the relay hasn't seen gets posted
  as fresh events.
- iPhone catches up via its own nudge / cursor flow next time it
  receives a nudge or reconnects.

### iPhone backgrounded for hours

- WS dies (Apple kills background WS after a few minutes).
- iPhone foreground: connectWebSocket runs → WS accept sends nudge
  with current MAX(id) → iPhone catches up. If catch-up window is
  > 500 events (limit), `GET /v1/sync/snapshot` overrides — both
  routes exist and the client picks based on event-count gap.

### Relay D1 outage / event table corruption

- We don't try to make this transparent. iPhone shows "Sync
  unavailable" banner if `/v1/sync/events` returns 5xx for > 30s.
- Mac queues events in local SQLite (`pending_relay_events` table)
  and replays them when D1 returns. This is the only persistence
  Mac maintains for sync state — everything else is derived.

---

## Process + validation

A rewrite of this size has burned us once already. The pattern
was always the same: builds pass, tests pass, I declare the PR
"done", the user opens the app, and a regression we never wrote a
test for shows up — chip flicker, late reply, sign-in error flash,
generic icon. v3 cannot ship that way. The architectural changes
are real, but the *process* around shipping them is what
determines whether they actually land cleanly.

### Roles

Stated explicitly because the prior failure mode was assuming the
user would catch what I missed:

- **User (product owner + QA).** Defines the golden behavior set,
  delivers it as concrete user-facing scenarios, runs those
  scenarios against each build I ship, and reports `pass` /
  `fail` per item. Does *not* need to read code, write tests,
  or diagnose stack traces.
- **Me (engineer + QA).** Owns all technical validation before a
  build reaches the user. Builds pass, tests pass, *new tests
  exist for every new behavior*, *regression tests exist for
  every bug ever reported*, the golden set runs green
  end-to-end. Diagnoses every failure the user reports without
  asking the user technical questions.

If the user has to ask "why is this broken" or "how do I check
this", I failed at my half.

### Validation gate per PR

A PR is not "done" by my declaration. It's done when the user
returns the golden-set checklist with all items green. The gate
in order:

1. **My pre-build checks.** All of:
   - `swift build --package-path apps/mac` passes
   - `npm test` passes
   - `bash scripts/verify-steer-regression.sh` passes (the full
     gate from `docs/REGRESSION_CONTRACT.md`)
   - New tests added for every new behavior in this PR
   - Regression tests added for any bug the user reported during
     this PR's cycle
   - Manual smoke of the golden set: I run each item myself with
     `STEER_HOME=/tmp/steer-pr-N` to isolate state. Any fail at
     this stage → I fix before the user sees the build.

2. **Build delivery.** I run `bash scripts/refresh-dogfood.sh`
   so the Mac side is fresh; iOS gets a `bash scripts/refresh-ios.sh`
   (or the explicit Xcode flow if device auto-detect fails). I
   tell the user the build is ready *and* attach the golden-set
   checklist as a copy-pasteable list of "do X → see Y" items.

3. **User QA.** User runs through the checklist on a real Mac +
   real iPhone, marks each item. They can mark anything as
   `unclear` or `couldn't reproduce` — that's a signal the item
   isn't well-specified and I need to rewrite it, not a sign the
   user failed at QA.

4. **Failure path.** Any `fail` or `unclear`:
   - I do not touch code.
   - I diagnose. Quote the exact line / log / behavior.
   - I propose a fix. User says yes/no.
   - On yes, I fix in a *new commit* (never amend) so the diff
     of "what broke and what I changed to fix it" is preserved.
   - Back to step 1 for the same PR. The PR doesn't advance
     until the full checklist is green.

5. **Advance.** When the user returns the full checklist green,
   I merge the PR, regenerate the golden set if any items were
   refined during QA, and only then start the next PR.

### What I will NOT do during v3

These all caused regressions in the prior cycle. They are off
limits:

- "While I'm in here, let me also clean up X." Scope creep is
  the single biggest source of regressions. v3 is sync layer
  only. Chip semantics, icon resolution, notification permission,
  Sparkle, etc. are all separate tickets that wait.
- Declare a PR done because the build compiles. Compilation
  proves type-correctness, not behavior. I declare done only
  after the golden set runs green.
- Skip the manual smoke because "tests passed." Tests cover
  what I thought to write. The golden set covers what the user
  actually does. They are not substitutes.
- Squeeze multiple structural changes into one commit. One
  commit, one change. If I'm tempted to write a 5-bullet commit
  message, that's the warning sign — split it.
- Treat "user got a build and didn't complain" as a pass. A
  pass is the user *actively confirming* each golden-set line.
- Touch the wrapper / agent / classifier layer. Those have
  their own regression contract (`docs/REGRESSION_CONTRACT.md`)
  and are explicitly *not* part of v3. If a sync change requires
  changing the wrapper, that's a flag — re-scope, don't reach.

### Feature flag

`STEER_SYNC_V3` env var, read at process start on both Mac and
iOS:

| Value | Behavior |
|---|---|
| `0` (default through PR 1–3) | Legacy path runs; v3 code paths are gated off. Relay still dual-writes events into D1 (PR 1) but no client consumes them. |
| `1` | v3 path runs end-to-end. Mac POSTs events; iPhone consumes via nudge + cursor. Legacy paths in clients are dead code in this branch. |

PR 1 introduces the flag, defaults to 0. PR 2 + PR 3 add v3 code
behind the flag but keep flag off. PR 3.5 (a deliberate dogfood
checkpoint) flips the flag to 1 on my dev machine + user's
device for 24–48 h. Only if the golden set stays green through
that period does PR 4 (legacy deletion) ship.

Rollback during the v3=1 dogfood window: user toggles
`STEER_SYNC_V3=0` in Steer's Settings → restarts → instantly
back on legacy. No build needed.

### Metrics I will report per PR

Per PR completion, I report objective numbers in the PR
description so we're not arguing about subjective "feels fast":

- HTTP requests/hour against the relay (measured from
  `wrangler tail` over 10 min while exercising the app)
- iPhone reply → card-arrival latency, p50 and p95 (from a small
  in-app timer I'll log in `~/.steer/relay-client.log`)
- WS reconnect frequency over a 1 h dogfood window
- Test count delta (`npm test` summary before vs after)

If a number moves in the wrong direction, the PR is not green
regardless of behavior.

### Golden behavior set — seed list

This is the live test ledger. It grows as we surface new
behaviors and never shrinks. The user provides item descriptions;
I write the reproducible steps + expected outcome. Each item is
"do X, see Y, within Z seconds."

Initial seed, derived from regressions we've already fought:

| # | What to verify | Steps | Expected | Source |
|---|---|---|---|---|
| G1 | iPhone reply arrives on Mac quickly | iPhone → tap card → type "hi" → send | Mac wrapper receives within 3 s; no error banner on either device | "엄청 늦게 오네" 2026-05-11 |
| G2 | Mac card replies surface chip on Mac | Mac card → type reply → send | "1 running" pill appears on Mac while session runs; fades when next card arrives | "reply 쳐서는 칩 잘 뜬다" 2026-05-12 |
| G3 | New card after reply | Either side reply | A new card appears in the carousel on both Mac and iPhone within 5 s of CLI stop | base case |
| G4 | Sign in with Apple is silent | Mac Settings → Sign in with Apple → complete | No red error banner flashes during or after; status row goes "Not signed in" → "Signed in as …" cleanly | "에러 메세지들이 잠깐씩 나타남" 2026-05-12 |
| G5 | Sign in with Apple icon | Mac Settings → Sign in with Apple click | Real Steer app icon in the system dialog, not a generic placeholder | "아이콘이 없네" 2026-05-12 (open) |
| G6 | Reply 4–5 times in a row stays connected | iPhone → reply N=1..5 with 20 s gap between | Every reply arrives; no "session connection dropped" or extended (>10 s) delay on any reply | "한 4-5번 메세지 보냈더니 세션 연결이 끊김" 2026-05-12 |
| G7 | Chip count = my outstanding sends only | iPhone reply twice in 10 s | Mac chip reads "2 running" while both sessions are still running, drops as each new card arrives | "내가 reply 보낸 그래서 instruction queued/in-flight인 건 표시" 2026-05-12 |
| G8 | Reply 후 즉시 visible status | Tap send on either side | The reply text becomes visible on the card area immediately with a quiet "queued" indicator; doesn't wait for network | v3 design lifecycle |
| G9 | Failed reply shows inline retry | Reply while in airplane mode | Status flips to "Tap to retry"; tapping with network restored sends successfully | v3 design lifecycle |
| G10 | WS reconnect catches up missed events | Disable iPhone wifi for 30 s while Mac produces 2 new cards, then re-enable | All 2 cards appear within 5 s of re-enable; no missing card; no duplicate | v3 design failure modes |
| G11 | Cost graph dropped | After PR 3.5 dogfood window | `wrangler tail` shows ≤ 20 HTTP req/min during steady state vs current ~60 req/min | v3 cost model |

Items G1–G7 are *backfilled* from past regressions — they
existed before v3 and must continue to pass through every PR.
Items G8–G11 are *new* targets v3 unlocks. Anything failing on
the backfilled set means we regressed; anything failing on the
new set means v3 isn't done.

The user owns the right to add to this list. Anything they ship
to me as "X is broken" gets added as a new line and is checked
on every subsequent PR.

### Work log

Each PR has a daily one-paragraph status update in
`docs/SYNC_V3_LOG.md` (created in PR 1). Format:

```
2026-05-NN — PR N status: in-progress | awaiting-user | green
  - shipped: <commit titles>
  - my checks: <pass/fail per pre-build check>
  - user QA: <pending / N green out of M>
  - blockers: <anything stuck on user input or external dep>
  - next: <single concrete next action>
```

Short, easy for the user to skim once per day, no need for them
to read code. It also forces me to surface blockers immediately
rather than silently spinning.

---

## Migration plan

Big-bang is too risky. We ship in four sequenced PRs.

### PR 1 — relay event log + dual-write

- D1 migration: add `events` table.
- Add `POST /v1/sync/events`, `GET /v1/sync/events?since=N`,
  `GET /v1/sync/snapshot`.
- Existing routes (`PUT /v1/sync/cards/:id` etc) **also** insert
  an event row alongside the old behavior. Dual-write.
- Existing WS broadcasts continue to fire as before.
- Clients unchanged. We're only proving the event log captures
  every state change observed during normal use.
- Verification: tail D1 events while exercising the app; confirm
  every old broadcast has a matching event row.

### PR 2 — Mac switches to event POSTs

- `SyncClient.publishCard` / `resolveCard` / `publishSession` /
  `fetchQueuedInstructions` are rewritten to POST events.
- Relay's old routes are deprecated but still exist.
- Mac still consumes via the old polling/WS path; events are
  only on the producer side.
- Verification: cards appear on iPhone exactly as before (still
  via legacy WS broadcasts from the dual-write); but cost graphs
  show Mac HTTP traffic dropping ~40%.

### PR 3 — iPhone switches to event consumption

- `SyncInbox` cold-launch path becomes `GET /v1/sync/snapshot`.
- WS handler changes to `nudge` + `GET /v1/sync/events?since=`.
- `DevicePresenceObserver` deleted; presence derived from
  `device.heartbeat` events arriving in the stream.
- Legacy WS messages (`card.upsert` etc) still arrive — iPhone
  ignores them (event stream is the truth).
- Verification: iPhone with airplane-mode toggle reproduces
  reconnect → snapshot → catch-up correctly; cost graphs show
  presence-polling HTTP traffic at zero.

### PR 4 — delete legacy routes + dual-write

- Remove `PUT /v1/sync/cards/:id`, `DELETE /v1/sync/cards/:id`,
  `POST /v1/sync/sessions`, `GET /v1/sync/cards`,
  `GET /v1/sync/sessions`, `GET /v1/sync/presence`,
  `GET /v1/sync/instructions/queued`,
  `POST /v1/sync/instructions`,
  `POST /v1/sync/instructions/:id/status`.
- Remove legacy WS broadcasts (`card.upsert`, etc); only
  `nudge` remains.
- Verification: full regression of the golden behaviors above.
  Old clients (anyone who didn't update) lose sync gracefully —
  the Settings panel shows "Update Steer to continue syncing"
  since their POSTs 404.

Each PR ships independently. PR 3 can stay deployed alongside
legacy routes indefinitely if PR 4 needs to wait for an iOS
release-train cycle.

---

## Test surface

Tests we keep adding before / during the PRs above:

1. **Event log idempotency.** Posting the same event twice (same
   idempotency key) returns the same id; no duplicate row.
2. **Cursor catchup correctness.** Start with N events. Apply
   k=0..N as cursor. For each k, `GET /v1/sync/events?since=k`
   returns events k+1..N in id order.
3. **Snapshot consistency.** Snapshot returned at cursor C is
   exactly `apply(events[0..C])`. Property-based test against
   the event-replay function.
4. **Reconnect catchup.** Drop iOS WS mid-event-burst. After
   reconnect, every event that was emitted while disconnected
   appears in iOS state exactly once.
5. **Producer no-op.** Mac posting `card.upsert` and then
   receiving the same event back via its own `nudge` does not
   double-apply locally.

Existing regression contracts (`docs/REGRESSION_CONTRACT.md`)
remain authoritative for terminal / classifier / wrapper. v3
is strictly above that layer.

---

## What we're not changing

For sanity:

- Classifier behavior. `docs/CLASSIFIER_CONTRACT.md` unchanged.
- Wrapper / PTY / agent socket. Unchanged.
- Local SQLite schema on the Mac side. Unchanged.
- iOS UI shell, card visuals, reply input. Unchanged.
- Sign in with Apple, deviceId derivation, APNS fanout. Unchanged.
- Sparkle, iOS NSE, App Store assets. Unchanged.

---

## Open questions

1. **Idempotency key shape.** UUID generated client-side, or
   `(producer_device_id, sequence_number)` where sequence is
   per-device monotonic? Latter is smaller in D1, former is
   simpler in client code. Default to UUID; revisit if cost
   matters.
2. **Snapshot freshness vs. cursor mismatch.** If
   `GET /v1/sync/snapshot` returns cursor C but events C+1, C+2
   were already published mid-fetch, the client immediately
   replays them. Is the snapshot endpoint atomic relative to the
   event log? Default yes (snapshot returns `MAX(id)` as the
   cursor and computes from `events WHERE id <= cursor`).
3. **Mac's `pending_relay_events` table — how big can it get?**
   Cap at last 1000 entries; older drops on the floor with a
   logged warning. Re-snapshot on next iPhone connect.
4. **Multiple Macs for one user.** Two Macs both producing
   `card.upsert` for two different sessions — fine, distinct
   `producer_device_id`. Two Macs producing for the *same* session
   — undefined product behavior; today the wrapper ownership model
   excludes this case. Mark as "won't fix in v3" unless feedback
   says otherwise.
5. **Instruction lifecycle timeouts.** Default proposals:
   queued → sent retry-on-failure with 1/2/4/8s backoff; sent →
   injected "Waiting on Mac" affordance at 60s; running → done
   no timeout (genuine compute can take minutes). Confirm or
   tune before PR 2 lands the producer-side status machine.

## Decision log

| Date | Decision | Why |
|---|---|---|
| 2026-05-12 | Pick architecture A (full event-sourced rewrite) over B (quick wins). | User wants regressions under control. The architecture itself, not patch density, is the bottleneck. |
| 2026-05-12 | Keep HTTP for writes. | D1 audit trail value > write latency value. WS for writes adds replay / ordering complexity for marginal gain. |
| 2026-05-12 | Don't migrate off Cloudflare. | Deployment cost + ops surface is well within targets after v3. |
| 2026-05-12 | Four sequenced PRs, not big-bang. | Each PR is verifiable in isolation; PR 4 can hold until iOS release-train ready. |
| 2026-05-12 | Instruction lifecycle is part of the architecture, not the UI. | User insight: latency stops being visible when the send-frame is the event horizon and a status pipeline runs against the local row. The event-log design enables this with minimal code; the UI is only the rendering of a derived status. |
| 2026-05-12 | UI surfaces TWO states (queued / failed), not five. | User: "Done은 없지 — done하면 카드가 생성되서 돌아오잖아". The new card's arrival is itself the completion signal; rendering a separate "Done" pill alongside a fresh card is redundant. sent / injected / running are all "on its way" from the user's perspective and would only flicker. Internal status field still tracks all stages for timeout + retry logic; the UI just renders two buckets. |
| 2026-05-12 | Validation is gated on a user-owned golden set, not my declaration. | User isn't a developer — they can't read the diff to verify safety. Process section now defines explicit roles (user = golden set + QA, me = all technical validation including writing new tests + regression tests for every reported bug) and a per-PR validation gate that doesn't advance until the user marks the golden set green. |
| 2026-05-12 | Feature flag `STEER_SYNC_V3` gates the new path. | One-toggle rollback. v3 code paths sit behind the flag through PR 1–3, get flipped on for a deliberate 24–48 h dogfood checkpoint (PR 3.5), and only after that window stays green does PR 4 delete legacy code. |
