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

## Decision log

| Date | Decision | Why |
|---|---|---|
| 2026-05-12 | Pick architecture A (full event-sourced rewrite) over B (quick wins). | User wants regressions under control. The architecture itself, not patch density, is the bottleneck. |
| 2026-05-12 | Keep HTTP for writes. | D1 audit trail value > write latency value. WS for writes adds replay / ordering complexity for marginal gain. |
| 2026-05-12 | Don't migrate off Cloudflare. | Deployment cost + ops surface is well within targets after v3. |
| 2026-05-12 | Four sequenced PRs, not big-bang. | Each PR is verifiable in isolation; PR 4 can hold until iOS release-train ready. |
