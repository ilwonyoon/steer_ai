# Sync architecture v2 — push, not poll

Today the Mac↔relay↔iPhone path is a polling loop dressed up as push.
This doc lays out what changes and what we leave alone.

## What today actually does

```
Mac SteerRootView
  └─ every 2s: load active cards from SQLite into the SwiftUI view
       └─ side effect: publishCard() for every active card on every tick
            └─ relay PUT /v1/sync/cards/:id
                 └─ relay broadcast WS card.upsert to user's iPhones

Mac SteerAppDelegate
  └─ every 15s: POST /v1/sync/devices (heartbeat)

iOS SyncInbox
  ├─ WebSocket (always-on): receives card.upsert / card.resolved
  ├─ reload() (ad-hoc): GET /v1/sync/cards
  └─ DevicePresenceObserver every 5s:
       ├─ GET /v1/sync/devices
       └─ GET /v1/sync/sessions
```

Two structural problems fall out:

1. **Mac has no change-detection layer.** The 2s SwiftUI reload tick is
   doubling as the publisher. Every active card gets PUT every tick
   regardless of whether anything changed. We added a payload-equality
   dedupe inside `SyncClient.publishCard` (committed 2026-05-11), but
   that's a band-aid — the upstream caller is still spamming.

2. **iOS has two channels racing.** The WebSocket is the design-time
   primary, but the 5s `DevicePresenceObserver` poll re-fetches devices
   + live sessions on a timer and reassigns `@Published` arrays. Those
   reassignments tear down the bottom carousel even when nothing
   changed. We added equality guards (also 2026-05-11), but again,
   downstream of the actual problem.

The user-visible symptom is the iPhone card stack and bottom carousel
visibly twitching every few seconds — the polling cadence leaks
through every level of the UI.

## What v2 looks like

```
Mac SQLite write hook (single writer)
  └─ enqueue cards that changed since last publish
       └─ publishCard() — diff-based, only changed payloads
            └─ relay PUT
                 └─ relay broadcast WS card.upsert (already deduped server-side)

Mac SteerRootView
  └─ every 2s: load active cards into SwiftUI view (unchanged — local UI loop)
       └─ no publish side effect

Mac SteerAppDelegate
  └─ every 15s: POST /v1/sync/devices (unchanged)

iOS SyncInbox
  ├─ WebSocket (always-on, primary): receives card.upsert / card.resolved
  └─ reload() (cold start + WS reconnect only): GET /v1/sync/cards

iOS DevicePresenceObserver
  └─ every 5s: GET /v1/sync/devices  (chip label only — does not touch cards)
       └─ GET /v1/sync/sessions      (running count only)
```

Three concrete changes:

### A. Mac: separate "load for UI" from "publish to relay"

`SteerRootView` keeps its 2s `loadActiveCards` for local SwiftUI
refresh. The `syncToiPhone(cards:)` side effect moves out of the tick
and into a `MacRelayPublisher` that watches `LocalSteerStore` for
actual row mutations (insert / update / delete on `action_cards`).

The store is the single writer, so a thin observer at the
write boundary catches every real change. Publisher gets the
*delta* (changed IDs since last cycle) and PUTs only those. If
nothing changed, the publisher sleeps.

### B. iOS: WS is the only card-state source; polling is for the chip

`DevicePresenceObserver.refresh` stops touching anything card-shaped.
It already had `liveSessions` which only feeds the chip's running-count
— that stays. Card mutations come from the WebSocket; the only HTTP
GET on `/v1/sync/cards` is on cold start and after a WS reconnect.

`reload()` is renamed `bootstrapCards()` and called from exactly
two sites:

- `init` when a session token is present in keychain
- WebSocket `connectWebSocket` post-success, after the first ping

Anywhere else that called `reload()` is moved to react to WS
messages instead.

### C. Relay: cardUpsert broadcast skips no-ops

`upsertCard` in `store.ts` already returns `{ inserted: boolean }` for
APNS dedupe. Extend it to return `{ inserted, changed }` where
`changed = inserted || the row's hash differs from the previous row`.
Broadcast and APNS both gate on `changed`. So even if Mac somehow
sends a duplicate, the relay won't fan it out. Defense in depth.

## What stays the same

- Wire protocol (CardPayload, WSMessage shapes) — no breaking change.
- Mac SwiftUI's 2s reload tick — only its side effect changes.
- iOS WebSocket reconnect/backoff — unchanged.
- iOS DevicePresence 5s poll cadence — same number, different scope.
- APNS fanout, deep-linking, sign-in, keychain — untouched.

## Migration order

1. (Relay) Add `changed` to `upsertCard` result. Gate broadcast on
   it. Cheap, no client impact.
2. (Mac) Move publish out of the SwiftUI tick into a store-observer.
   Keep the existing publishCard dedupe as a safety net.
3. (iOS) Remove `reload()` from anywhere except cold-start and
   WS-reconnect. Narrow DevicePresence to chip-only data.

Each step is independently shippable and individually testable
against the on-screen twitch.

## What this doesn't fix

- The Mac's local SwiftUI render loop is still 2s. If the *view itself*
  flickers locally, that's a separate concern not addressed here.
- Cold-start ordering races (Mac comes up after iPhone) — same as
  today; iPhone gets cards via the WS connection-accept burst.

## Why not push everything through WebSocket from the Mac side too?

Considered. Today Mac writes via REST PUT, which has nice
properties: relay can persist before broadcasting, retries are
trivial, the same endpoint serves the iPhone's cold-start GET. A WS
write channel from Mac would duplicate that plumbing and force the
relay into a write-buffer pattern. The REST PUT path is fine; the
problem was the *cadence*, not the transport.
