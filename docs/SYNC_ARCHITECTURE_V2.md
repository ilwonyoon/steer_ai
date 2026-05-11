# Sync architecture v2 — push, not poll

Today the Mac↔relay↔iPhone path is a polling loop dressed up as push.
This doc lays out what changes and what we leave alone.

## Golden behavior

What the user actually wants out of this:

1. **Mac and iPhone stay in sync without visible churn.** Open the
   iPhone, the same set of cards the Mac has are there, in the same
   order. No jitter, no carousel shuffling, no twitching text.
2. **Mac connection chip is honest.** It says "Connected" when the
   Mac is reachable, "Stale" when it's been quiet for a few minutes,
   "Offline" when it really is. State changes within a few seconds
   of reality, not on a 30-second polling cadence.
3. **iPhone is responsive at launch, not mid-sync.** Settings is
   tappable from frame zero; the Settings icon doesn't shift; the
   card area shows a clear loading state while the first sync
   completes; nothing reflows in the user's face after the cards land.

Everything in this doc is in service of those three. If a change
doesn't help one of them, it doesn't belong here.

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

### B2. iOS: real cold-start loading state

Today's launch sequence: blank screen → cards appear one by one as
the WebSocket connects and reload() fires. The card carousel
shuffles as cards land out of order, and the Settings icon at the
top is briefly unresponsive because the view is mid-mutation.

V2 introduces an explicit `SyncInbox.LoadPhase`:

- `.cold` — keychain has a token but we haven't loaded anything yet.
  Render a quiet "Syncing…" placeholder in the card area. **Top
  chrome (Settings icon, connection chip) renders from frame zero
  and is fully tappable.** They don't depend on card data.
- `.bootstrapping` — `bootstrapCards()` is in flight. Same placeholder.
- `.ready` — first card list received (either via the GET or the
  WS-accept burst, whichever arrives first). Now the cards appear
  in their final order. No re-shuffling after this point.

Phase transitions: `.cold → .bootstrapping` when bootstrap starts;
`.bootstrapping → .ready` when first non-empty card list lands OR
500ms after the bootstrap GET returns empty (whichever first — so
"genuinely no cards" doesn't sit on a spinner forever).

State below `.ready` does not block the Settings sheet or any other
non-card view. The point is to keep the user in control of the
chrome while the data settles.

### C. Relay: cardUpsert broadcast skips no-ops

`upsertCard` in `store.ts` already returns `{ inserted: boolean }` for
APNS dedupe. Extend it to return `{ inserted, changed }` where
`changed = inserted || the row's hash differs from the previous row`.
Broadcast and APNS both gate on `changed`. So even if Mac somehow
sends a duplicate, the relay won't fan it out. Defense in depth.

### D. iOS top chrome: swap connection chip and Settings positions

Today: Settings (gear) is top-left, Mac connection chip is top-right.

V2: Mac connection chip moves to **top-left**, Settings moves to
**top-right**. Two reasons:

1. The Mac connection chip is *status*, not action. iOS HIG puts
   identifying status on the leading edge (lock screen weather, Maps
   transit summary, etc). Settings is an action (open a sheet) and
   belongs on the trailing edge where Done buttons live.
2. The current layout has the user reading left-to-right past the
   gear before they see whether the Mac is even connected. Flipping
   makes the very first glance answer "is this even working?"

Pure layout change. Functionality (tap chip → MacSyncStatus sheet;
tap gear → Settings sheet) unchanged.

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
4. (iOS) Add `LoadPhase` state machine + "Syncing…" placeholder. Top
   chrome (Settings, chip) renders independent of card data.
5. (iOS) Swap connection-chip and Settings positions in InboxView.

Each step is independently shippable and individually testable
against the on-screen twitch. Steps 1–3 fix the underlying sync;
4–5 fix the launch UX.

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
