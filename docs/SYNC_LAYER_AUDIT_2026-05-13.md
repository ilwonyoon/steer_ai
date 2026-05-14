# Steer iOS ↔ Mac Sync Layer Audit — 2026-05-13

Scope: research-only audit of the WebSocket / state-machine layer that
ferries action cards between Mac and iPhone. Triggered by a multi-hour
launch-eve regression cascade (commits 86f87a3 → b737db8). Goal: explain
the recurrence, prescribe a regression-proof shape, lock down the
current good state.

Pinned HEAD at audit time: `b737db8`.

---

## 1. Sync layer map

The sync layer spans three runtimes (Node agent, Swift Mac app, Swift
iOS app) with Cloudflare Workers as the relay. Below is each file's
single source-of-truth responsibility — boundaries we should not let
new code drift across.

### 1a. Agent side (single SQLite writer)

`packages/agent/src/store.js`
- Owns: `sessions.awaiting_response_since`, `sessions.last_response_revision`, `action_cards`, `transcript_entries`.
- Key invariants:
  - `markSessionAwaitingResponse` (L73-77) is stamped *only* at instruction-route time (called from `createInstruction`, L273).
  - `bumpResponseRevisionIfReady` (L82-94) atomically increments AND clears `awaiting_response_since` in one UPDATE; can't double-bump.
  - `refreshActionCard` (L383-424) bumps revision BEFORE upserting the card row, so a single PUT carries the post-bump revision (L388 → L409). This is the load-bearing ordering — iPhone sees one consistent upsert with the new `responseRevision`.
  - Card row id is hard-coded as `card-${sessionId}` (L410). Every card on a session reuses the same id. (See §3 fragility F-6.)

`packages/agent/src/agent.js`
- Owns: socket dispatch table (L52-93). Maps `register / output / state / send / hook_event / sessions / ack`.
- `case "ack"` (L75-89) calls `resolveActionCardsForSession` only on `injected`, not on `failed`.
- `routeInstruction` (L282-319) drives the trio: store-stamp → wrapper write → transcript append → `runState=running`.

### 1b. Mac side (publisher, single SQLite reader of its own store)

`apps/mac/Sources/SteerMac/SyncClient.swift` (786 lines)
- Owns: relay HTTP + WebSocket plumbing for the Mac client.
- Reconnect: `receiveLoop` (L570-595) + `WSReconnectBackoff`.
- Keepalive: `pingLoop` (L531-563) sends both application-level `WSMessage.ping` AND TCP control-frame `sendPing()` every 20 s. On send error: `cancel(with:.goingAway)` to force receiveLoop to throw and reconnect.
- HTTP helpers: `fetchActiveCards`, `publishCard`, `resolveCard`, `fetchQueuedInstructions`, `markInstructionInjected/Failed`, `sendDeviceHeartbeat`.

`apps/mac/Sources/SteerMac/SteerRootView.swift` (1121 lines)
- Owns: the 2 s publish/drain loop (`refreshLoop`, L305-311 + `reload`, L329-485).
- Two state machines collocated here:
  - **Card publish reconciliation**: `@State lastPublishedCardIds`, `@State lastPublishedCardHashes`, `@State didSeedFromRelay` (L27-37). Cold-start seeds from relay via `fetchActiveCards`; delegates the diff to `CardReconciler.reconcile` (L554).
  - **Instructed-session decay**: `@State instructedSessions: [String: InstructedAt]` (L49). Decay delegated to `InstructedSessionDecay.decay` (L358).
- Critically: this view is BOTH the SQLite reader AND the relay publisher AND the reply drainer AND the device-heartbeat tick. All four loops time-share the 2 s reload tick.

`apps/mac/Sources/SteerMac/LocalSteerStore.swift`
- Owns: SQL queries against `~/.steer/steer.sqlite`. `loadCards` (L11-23), `loadLiveSessions` (L25-37), `send` (L39-64).
- Reads `s.last_response_revision AS response_revision` (L146); plumbs `responseRevision` into `ActionCard` (L312).
- Caveat: shells out to `sqlite3 -json` rather than using `node:sqlite` bindings. Already a known cross-process contract (the Mac is *not* the writer).

`apps/mac/Sources/SteerMac/SteerCardMapping.swift`
- Owns: Mac `ActionCard` → wire `CardPayload` projection. `publishFingerprint` (L58-83) deliberately excludes `createdAt`/`updatedAt` but INCLUDES `responseRevision` — bumping revision forces republish (L72).

### 1c. iOS side (consumer + reply producer)

`apps/ios/SteerIOS/SyncInbox.swift` (1147 lines)
- Owns: the iPhone's single source-of-truth `@Published sessions: [SessionEntry]` (L27). All projections (`cards`, `pendingReplies`, `activeSessionIds`) flow through `setSessions` (L642-649).
- Network handlers: `reload()` (L513-537, applies bootstrap), `handleWSText` (L894-931, applies `cardUpsert` / `cardResolved`), `sendReply` (L676-706, optimistic + POST).
- Keepalive: `pingLoop` (L821-861) — same shape as Mac's.
- `reconnectWebSocketIfNeeded` (L508-511) is the foreground-reconnect entry point. Called from `InboxView` scenePhase observer.
- `loadPhase` (L52) — `.idle / .bootstrapping / .ready`. Drives the cold-start placeholder.

`apps/ios/SteerIOS/DevicePresenceObserver.swift` (244 lines)
- Owns: the Mac-connection chip state machine (`.connecting / .connected / .stale / .offline / .neverConnected / .error / .demo`).
- Polls `/v1/sync/presence` every 3 s while `.connecting`, every 15 s steady-state (L97-100, L102-107).
- Pauses polling while backgrounded (L109-135) — APNS still wakes for new cards, so background polls are pure waste.
- `connectingStartedAt`/`connectingTimeout=10s`/`connectingMinimumVisibleSeconds=1.5s` (L49-59).

`apps/ios/SteerIOS/InboxView.swift` (844 lines)
- Owns: scenePhase observer (L174-187). On `.active`: `inbox.reconnectWebSocketIfNeeded()` + `setBadgeCount(0)` + `await inbox.reload()` + `await devicePresence.refresh()`.
- Memoizes `cards` projection (L188-197) — recomputes only when `inbox.$cards` changes, not on every render.

### 1d. Shared (SteerCore — Swift package, pure logic)

| File | Owns | Lines |
|------|------|-------|
| `SessionEntryStore.swift` | `SessionStage` enum + pure transition functions: `applyBootstrap`, `onCardUpsert`, `onCardResolved`, `markUserReplied`, `markReplyFailed`, `cancelFailedReply`, derived views | 362 |
| `CardReconciler.swift` | `reconcile(currentLocal:, lastPublished:, changed:)` → `{publishIds, resolveIds, nextPublishedIds}` | 101 |
| `ChipReconciler.swift` | Sibling of CardReconciler for the legacy chip-publish path | 91 |
| `WSReconnectBackoff.swift` | Pure exponential-backoff cadence (1,2,4,8,16,30s cap, ±20% jitter) | 91 |
| `SyncProtocol.swift` | Wire types: `CardPayload`, `WSMessage` (with `responseRevision` on CardPayload, L39), `DeviceSnapshot`, `InstructionRequestV2`, `PresenceResponse`, etc. | 379 |
| `InstructedSessionDecay.swift` | Mac-side decay: drop session-id when (not in live set) OR (card `updatedAt > instructedAtMs`) | 97 |

### 1e. Relay (Cloudflare Workers + D1 + Durable Object)

`packages/relay/src/index.ts` (691 lines)
- Hono routes: auth, cards (GET/PUT/DELETE), instructions (POST queue/list/status), devices (POST/GET/DELETE), presence (GET), events (POST/GET), snapshot (GET), stream (WebSocket).
- Card PUT (L191-268): calls `upsertCard`, fans out APNS *only* if `becameActive` AND category ∈ {blocker, decision, question, waiting}.
- Card DELETE (L352-370): marks state='done', broadcasts `card.resolved`.
- WebSocket: routed to per-user Durable Object via `USER_HUB.idFromName(userId)`.

`packages/relay/src/store.ts` (594 lines)
- D1 wrapper. `upsertCard` (L103-176) returns `{inserted, changed, becameActive}`. `becameActive = state==="active" AND (inserted OR previousState !== "active")`.
- `pruneStaleDevices` (L363-371) — 24 h GC, runs inside fanout to keep APNS target list lean.

`packages/relay/src/apns.ts`
- Single-shot ES256-signed JWT to `api.push.apple.com` (or sandbox per-device). Sends `badge: 1` on every fanout (L125-127 of index.ts → req.badge=1 → apns.ts L125-127).

`packages/relay/src/userHub.ts`
- Durable Object: per-user WebSocket fanout. In-memory `Set<WebSocket>`. Cloudflare hibernates idle sockets after 5–10 min — that's the entire reason the clients need a 20 s keepalive.

---

## 2. Today's regression inventory (2026-05-12 → 2026-05-13)

Walking `git log --since="2026-05-12 00:00"` for sync-layer files,
in chronological order. Each entry: **what broke / what fixed it /
why it was possible**.

### R-0. b6b8d67 — `feat(sync): responseRevision — atomic chip↔card transition signal` (2026-05-12 15:46)

*Not a regression, but the load-bearing primitive everything below depends on.*
Introduces `sessions.last_response_revision` (agent), wires it through
`CardPayload.responseRevision`, and makes iPhone's `onCardUpsert`
decide chip-vs-card by `incoming > stamp`. Before this, the iPhone was
guessing via `updatedAt` timestamp comparisons, which were flaky.

### R-1. 9e98fbb — `chip and card are the same data — one array, one mutation` (2026-05-12 15:16)

- **Broke**: chip and card had been separate `@Published` arrays (`cards`, `pendingReplies`); transitions had to be hand-synced.
- **Fix**: collapse to one `[SessionEntry]` with a stage enum. All three projections derive.
- **Why possible**: no invariant said "chip count and carousel count come from the same row." Two arrays + two network channels (WebSocket for cards, HTTP poll for chip) = different latencies; user saw chip and card disagree.

### R-2. 3dd5b65 — `chip derives from local pending replies, not relay poll` (2026-05-12 15:04)

- **Broke**: chip lagged carousel because chip data flowed via 15 s HTTP poll while card data flowed via ~1 s WebSocket push.
- **Fix**: derive chip locally from in-memory `PendingReply` rows the iPhone already owns.
- **Why possible**: two latency channels for one invariant. (R-2 and R-1 are the same fragility seen from different sides.)

### R-3. 1a0cce1 — `mac: chip = "I-replied & terminal-still-working"` (2026-05-12 13:44)

- **Broke**: Mac's chip publisher used `loadedChips` = (live − cards), which excluded any session with an active card — so a session mid-reply was indistinguishable from "no one running."
- **Fix**: pass raw `loadedLive` set to `InstructedSessionDecay`; decay only on (a) not-in-live-set OR (b) new card `updatedAt > instructedAtMs`.
- **Why possible**: the chip set was over-filtered by a Mac-UI dedupe rule that didn't belong in the inter-device contract.

### R-4. 86f87a3 — `cardResolved holds .awaitingResponse entries until next upsert` (2026-05-12 15:18)

- **Broke**: `card.resolved` and the next `card.upsert` arrive on separate ticks. Between them, chip cleared but no card had landed → user saw "Mac" with empty carousel for several seconds.
- **Fix**: `onCardResolved` keeps `.awaitingResponse` entries; only `.awaitingUser/.failed` drop on resolve.
- **Why possible**: client trusted "two consecutive WS messages will arrive coherently" — they don't.

### R-5. 79a2f24 — `drop awaitingResponse on resolve + force WS reconnect on foreground` (2026-05-13 14:45)

- **Broke**: R-4's hold was unbounded. When the wrapper died / user signed out / response card raced through a different path, the `.awaitingResponse` entry stuck FOREVER and the chip pinned to dead sessions.
- **Fix**: drop on resolve regardless of stage (revert R-4's hold). Accept the brief chip flicker. Add `reconnectWebSocketIfNeeded` for foreground.
- **Why possible**: R-4's invariant ("the next upsert is always coming") was false in the failure modes that matter most. No timeout, no test, no escape hatch — exactly the "time-bound cache with no expiry" fragility.

### R-6. 0e062c8 — `force-cancel WS on ping failure so receive loop unblocks` (2026-05-13 14:51)

- **Broke**: iPhone's `task.send(ping)` correctly caught Cloudflare DO idle-close, but the handler just `return`'d — `task.receive()` in receiveLoop stayed blocked forever waiting for the next frame on a dead socket.
- **Fix**: `task.cancel(with: .goingAway, reason: nil)` after a failed ping so receiveLoop throws and the backoff reconnect kicks in.
- **Why possible**: implicit assumption "if send fails, receive will fail too." With WebSocket half-close that's not true; you have to actively poison the receive side.

### R-7. b6fe8fe — `cure WS idle-drop on both clients + GET authoritative bootstrap` (2026-05-13 15:19)

Three fixes bundled — itself a sign of how interwoven these fragilities are:
- **R-7a**: Mac's `pingLoop` had the same half-closed-socket bug as iPhone (R-6); the iOS-only fix had left Mac with the same flaw. Now both clients use the dual-ping (application + TCP control-frame).
- **R-7b**: ping cadence 30 s → 20 s, comfortably inside Cloudflare's 5–10 min idle window.
- **R-7c**: `applyBootstrap` previously preserved `.awaitingResponse / .failed` indefinitely on the theory that a future upsert would replace them. When the upsert never came, the entry stuck forever.  **New rule: treat the relay GET as authoritative — if the server has no card for this session, drop the entry.**
- **Why possible**: an "optimistic in-memory state beats authoritative server" pattern. The bootstrap GET is the ONE moment we *know* what the server has; ignoring it was the bug.

### R-8. 069cb4e — `applyBootstrap promotes awaitingResponse on response card` (2026-05-13 15:27)

- **Broke**: After R-7c made the GET authoritative for dropping entries, it was *over*-authoritative for promotion: when the user replied while backgrounded → APNS banner → tap → cold-launch → bootstrap GET returns the NEW response card, but `applyBootstrap` did `continue` on the `.awaitingResponse` entry, throwing away the freshly-arrived card. UI: "1 running" + empty carousel.
- **Fix**: when bootstrap finds a card for a session that's `.awaitingResponse` (or `.failed`), promote to `.awaitingUser` with the new card payload.
- **Why possible**: the cold-start path is the *only* code path that surfaces this. WS upsert handles it correctly; bootstrap GET didn't. The two paths weren't symmetric. Two trips into the same state machine; the integration test only covered one.

### R-9. b737db8 — `set aps.badge = 1 on fanout + clear it on iOS foreground` (2026-05-13 15:32)

- **Broke**: APNS payload had `alert` + `sound` but no `badge`. iOS only paints the unread dot when the server explicitly sets it.
- **Fix**: send `badge: 1` on every card fanout; clear with `setBadgeCount(0)` on foreground.
- **Why possible**: APNS contract assumption ("alert is enough to show the dot") was just wrong.

### R-10. 664518c — `push on becameActive, not just first insert` (2026-05-13 07:32)

- **Broke**: every card on a session uses the same `card_id = card-${sessionId}` (agent store L410). After the user replied to the FIRST card, every subsequent stop/blocker on that session was an UPDATE not an INSERT — APNS fanout gated on `inserted` alone, so users heard the first card and nothing else.
- **Fix**: relay returns `becameActive = inserted OR (previousState !== "active")`. Fanout gates on `becameActive` AND notifiable category. Mac's 2 s republish tick is `active → active` so it doesn't trip.
- **Why possible**: a wire-shape invariant ("card_id is `card-${sessionId}`") that the relay didn't know about — a cross-component contract documented only in source comments.

### Earlier groundwork (referenced for completeness)

- **b28bf18 (2026-05-12 00:14)** — Mac top chip semantics: rolled-up live sessions → "pending iPhone replies in flight." Same fragility as R-2/R-3 but on the Mac side.
- **2a261d2** — Mac cold-start reconciliation: seeded `lastPublishedCardIds` from `fetchActiveCards` so the diff at boot DELETEs orphan rows (relay had cards from yesterday's process). The CardReconciler test for this is the only thing keeping that fix locked.
- **9789d01** — Explicit "ended" publish: Mac dropped `ended`/`disconnected` sessions from `loadLiveSessions` silently → relay kept stale "running" snapshot until its 90 s cutoff. Same shape as the cards-reconciler bug but for the chip channel.
- **fefc3bc** — `proper-lockfile` agent singleton + migration runner. Adjacent but relevant: the agent assumes single-writer; the lockfile is the only thing enforcing it across cold starts.

### Pattern across R-1 through R-10

| Fragility class | Hits |
|---|---|
| Two arrays / two channels for one invariant | R-1, R-2, R-3 |
| Time-bound cache with no expiry | R-4, R-5, R-7c |
| Implicit WebSocket health assumption | R-6, R-7a, R-7b |
| Asymmetric cold-start vs steady-state code paths | R-7c, R-8 |
| Cross-component contract documented in source comments only | R-9, R-10 |

**Six bug-fix commits hit `SessionEntryStore.swift` alone in 6 hours.**
Two of them (86f87a3 then 79a2f24) directly *reverted* each other.
That's the structural signal: a regression cluster, not isolated bugs.

---

## 3. Structural fragilities

For each fragility: file + line cite, evidence from the regression
inventory, and the smallest test or rule that would have caught it.

### F-1. State machine is split across three files; ownership unclear

- **Files**: `SyncInbox.swift` (L513-537 `reload`, L676-706 `sendReply`, L894-931 `handleWSText`, L777-789 `resolveCard`) and `SessionEntryStore.swift` (transitions) and `InboxView.swift` (L188-197 `cards` projection, L424-438 `send`).
- **Why fragile**: three places react to or mutate state derived from `sessions`. `SyncInbox.setSessions` (L642-649) is the chokepoint, but `InboxView` reads `inbox.cards` through Combine and projects to `[ActionCard]` separately — and `InboxView.send` does the demo-vs-real branch *before* calling `inbox.sendReply`. A future contributor who adds a new mutation has at least three plausible places to put it.
- **Symptom in inventory**: R-1 and R-9 explicitly cite the proliferation problem; R-1's fix was structural (`SessionEntry`), R-9's was just slap a setting on at one of the three sites (`setBadgeCount(0)` in `InboxView.scenePhase` L182).
- **Smallest fix**: keep `SessionEntryStore` as the only place transitions live; make `SyncInbox` an absolutely thin adapter that calls those transitions and publishes the result. Move the demo branch (currently in `InboxView.send` L432-437) into `SyncInbox.sendReply` so views never decide which network path runs.
- **Smallest test**: a "no direct mutation" test — grep `SyncInbox.swift` for any assignment to `sessions =` outside `setSessions`; CI fails if found. (Linting-level guardrail; trivial to add.)

### F-2. WebSocket "is it healthy?" relies on implicit Apple SDK behavior

- **Files**: `SyncInbox.swift` L821-861 (`pingLoop`), `SyncClient.swift` L531-563.
- **Why fragile**: the only signal that the socket is dead is `task.send(...)` throwing OR `task.sendPing(...)` invoking its pongHandler with an error. There's NO assertion that "if I sent N pings and got no frames back in M*N seconds, the socket must be dead." A scenario where Cloudflare drops half-close *silently* (no TCP RST, no FIN delivered) leaves both `send` and `receive` blocked. Today's R-6 fix is "if send fails, cancel the receive side" — but receive can fail without send ever firing.
- **Symptom in inventory**: R-6 was supposed to fix this; R-7a found the Mac side STILL had the same bug five days after the iOS fix, because nothing tested cross-platform that the keepalive contract held.
- **Smallest fix**: add a `lastFrameReceivedAt` watchdog. If `now - lastFrameReceivedAt > 60 s` and we should be connected, force-cancel and reconnect — independent of send/ping outcomes. This is the only test that survives Cloudflare's half-close.
- **Smallest test**: integration test using a `URLProtocol` stub that accepts a WebSocket upgrade and then goes silent. Assert reconnect-attempt fires within 60 s.

### F-3. `lastPublishedCardIds` is in-memory only — cold-start orphans

- **Files**: `SteerRootView.swift` L27-37, L429-442. `CardReconciler.swift` L56-100.
- **Why fragile**: Mac's publish baseline lives in `@State`. Every process restart starts from empty. The cold-start seed (L429-442) papers over this by calling `fetchActiveCards()` once and adopting whatever the relay claims. If `fetchActiveCards` fails (transient 401, network down, server slow), `didSeedFromRelay` is never set true — but the loop *might* still call `diffCardsForPublish` afterwards and ship a partial reconciliation.
- **Symptom in inventory**: 2a261d2 is the explicit cold-start orphan fix; 9789d01 is the same bug for the chip channel; both required a SteerCore extraction + tests to lock down.
- **Smallest fix**: guard the publish loop entirely on `didSeedFromRelay`. Don't ship a single PUT/DELETE until the seed call succeeded. Currently the code is best-effort: read `if !didSeedFromRelay { ... seed; didSeedFromRelay = true }` at L429 — if `fetchActiveCards` returns `[]` because of a 401, we set `didSeedFromRelay = true` (L438) anyway and proceed with an empty baseline. That's how an orphan slips through.
- **Smallest test**: `CardReconcilerTests` already has the cold-start case (ChipReconcilerTests too). Add ONE more: `test_reconcile_skipsWhenSeedFailed` — when seed-fetch returns nil/error, the next reconcile must be a no-op.

### F-4. Bootstrap GET vs WebSocket upsert are asymmetric code paths

- **Files**: `SyncInbox.swift` `reload` L513-537 → `SessionEntryStore.applyBootstrap` L76-157, and `SyncInbox.swift` `handleWSText` L894-931 → `SessionEntryStore.onCardUpsert` L177-235.
- **Why fragile**: these handle the same logical event (server says "here is a card for session X") but through different transitions. Different rules for what happens when an existing `.awaitingResponse` entry sees a card.
- **Symptom in inventory**: R-7c said "drop on bootstrap if not present" — correct. R-8 IMMEDIATELY had to add "promote on bootstrap if present and was awaitingResponse" — because the asymmetric paths each needed their own fix.
- **Smallest fix**: unify. Both paths should reduce to the same transition function with a flag "is this a bootstrap snapshot or a delta?" — and apply a single rule set. Easiest: `applyBootstrap` should iterate over server cards and call `onCardUpsert` for each, then call `onCardResolved` for every prior session not in the GET. That's it. Today `applyBootstrap` is 80 lines of bespoke logic; that's the surface area where R-7c and R-8 disagreed.
- **Smallest test**: property test — for any sequence of (initial state, server-snapshot), the result of `applyBootstrap(prev, snapshot)` must equal the result of applying `onCardResolved` to all missing sessions then `onCardUpsert` for each card in the snapshot. If they diverge, the new bespoke logic is suspicious.

### F-5. `.awaitingResponse` has no maximum lifetime

- **Files**: `SessionEntryStore.swift` L255-262 (`onCardResolved`), L177-235 (`onCardUpsert`).
- **Why fragile**: the only ways to exit `.awaitingResponse` are (a) WS `cardResolved` (R-5 added this), (b) a strictly-greater `responseRevision` on upsert (R-0 added this), or (c) bootstrap GET decides — drop or promote (R-7c + R-8). None of these is guaranteed to fire. The pre-R-5 state literally pinned chips forever when the response card never arrived. R-5 traded "pinned forever" for "1 s flicker"; that's a degraded trade-off, not a real fix.
- **Symptom in inventory**: R-4 and R-5 are the same fragility seen as a back-and-forth fix.
- **Smallest fix**: hard timeout. If an entry has been `.awaitingResponse` for > 10 minutes with no upsert, force-decay to `.failed("response timeout — your reply may not have been delivered")`. That gives the user an actionable cue AND guarantees no entry is stuck forever.
- **Smallest test**: `SessionEntryStoreTests.test_awaitingResponse_decaysAfterTimeout` — clock-injectable transition fixture proving that after T minutes the entry exits.

### F-6. Cross-client contract "card_id = `card-${sessionId}`" is undocumented except in comments

- **Files**: `packages/agent/src/store.js` L410 (the literal). `packages/relay/src/store.ts` L88-94 + L139-142 (the becameActive rationale). `apps/mac/Sources/SteerMac/SteerCardMapping.swift` L9-37 (the mapping). `apps/ios/SteerIOS/SyncInbox.swift` L894-931 (consumer behavior).
- **Why fragile**: an agent-side change to make card_id include a turn counter or timestamp would silently break the relay's `becameActive` logic (every card would be a fresh INSERT, so APNS would push for the same logical card twice). The relay's L237 ("SteerAgent reuses `card-${sessionId}`") is the only place that contract is recorded.
- **Symptom in inventory**: R-10 is literally about discovering that this contract had implications the relay hadn't internalized.
- **Smallest fix**: codify in `docs/REGRESSION_CONTRACT.md` and add an integration test: the relay should accept a sequence of `[upsert(card-X, active), DELETE(card-X), upsert(card-X, active)]` and produce `becameActive=true` twice.
- **Smallest test**: `packages/relay/test/store_upsert_dedupe.test.ts` already has it (added in 664518c). Pin it in `REGRESSION_CONTRACT.md`'s required-tests list.

### F-7. Mac is the SQLite writer of the local store; iPhone is the relay reader — but the relay state is also writeable from both sides

- **Files**: `SteerRootView.swift` L581-600 (Mac publish path), `SyncInbox.swift` L676-706 (iPhone reply), `relay/src/index.ts` L377-412 (POST instructions).
- **Why fragile**: the documented invariant ("Mac is the only writer of local SQLite") is sometimes confused with the relay invariant ("only one client writes a given card row"). The relay accepts PUTs for any card from any device authorized by the JWT. If a future feature lets the iPhone publish a card (e.g., a "draft reply" type), the relay model breaks silently.
- **Symptom in inventory**: not directly hit today, but R-9 (badge) and the device-DELETE path (3649bfd) live next door — same kind of write asymmetry.
- **Smallest fix**: add to `REGRESSION_CONTRACT.md`: "Only Mac PUTs `/v1/sync/cards/:id`. iOS only POSTs `/v1/sync/instructions` and DELETEs its own device." Enforce server-side via the JWT's `did` claim + platform check on PUT.
- **Smallest test**: `connection_contract.test.ts` should add a case: PUT `/v1/sync/cards/X` with an iOS-platform device JWT returns 403.

### F-8. The "happy path" tests don't exercise the recovery paths

- **Files**: `SessionEntryStoreTests.swift` (16 tests). `CardReconcilerTests.swift`. `WSReconnectBackoffTests.swift`.
- **Why fragile**: most R-* fixes added a test for the bug they fixed. There's no fixture covering "WS dies in the middle of a reply sequence." The recovery paths (foreground reconnect, half-close, bootstrap promotes) each got their own test post-hoc.
- **Smallest fix**: add ONE integration test that exercises the full bad path:
  1. Open iOS sync. Connect WS.
  2. Mac publishes card. iOS sees it.
  3. User taps reply. POST goes through. Entry is `.awaitingResponse`.
  4. **Force-cancel iOS WS** (simulate background-induced kill).
  5. Mac publishes the response card (new responseRevision).
  6. iOS receives no WS upsert (it's dead).
  7. iOS app comes to foreground → `reconnectWebSocketIfNeeded` + `reload`.
  8. **Assert: within 5 s the carousel shows the new card; chip drops to 0.**

  If this test had existed last week, R-4, R-5, R-7c, R-8 would have all been one fix.

---

## 4. Recommended design discipline

Not a rewrite. Five rules to lock the current good state down.

### Rule 1: Treat the relay GET as authoritative on every transition

`SessionEntryStore.applyBootstrap` should be **the canonical reducer**.
WebSocket events are an optimization. If a WS message and a GET disagree,
the GET wins. Concrete shape:

```swift
// Pseudocode for the unified transition:
static func applyServerSnapshot(
    previous: [SessionEntry],
    serverCards: [CardPayload],
    sessionIdsToResolve: Set<String> // optional, from cardResolved WS events
) -> [SessionEntry] {
    // 1. For every server card: apply onCardUpsert (already handles
    //    .awaitingResponse → .awaitingUser via responseRevision).
    // 2. For every prior session NOT in serverCards: apply
    //    onCardResolved.
    // 3. Sessions in sessionIdsToResolve: redundant with (2) if the
    //    set comes from the snapshot; useful when the WS resolves a
    //    card the snapshot hasn't reflected yet.
}
```

Then both `reload()` and `handleWSText(cardUpsert)` route through this
function. The bespoke `applyBootstrap` logic dies. No more asymmetric
paths.

### Rule 2: Every cache entry has a maximum lifetime

`.awaitingResponse` decays to `.failed("response timeout")` after 10 min.
`pendingFocusSessionId` clears after 30 s. `connectingStartedAt` already
has `connectingTimeout=10s`; keep that pattern.

### Rule 3: WS health = "frame received within N seconds"

Add `var lastFrameReceivedAt: Date?` to both `SyncInbox` and Mac's
`SyncClient`. In `pingLoop`: if `Date().timeIntervalSince(last) > 60`, force-cancel.
This is the ONLY check that survives Cloudflare's silent half-close.
The current "send error → cancel" plus "ping pong error → cancel"
double-net was supposed to cover this, but R-6 and R-7a both prove
the assumption was incomplete on one client or the other.

### Rule 4: One mutation funnel per published source

`SyncInbox.setSessions` (L642-649) is the funnel for iOS. Mac doesn't
have one — `SteerRootView.reload` mutates `cards`, `liveChips`,
`instructedSessions`, `lastPublishedCardIds`, `lastPublishedCardHashes`
directly. Wrap those in `private func setMacState(...)` so future
"add a new field" PRs land in the funnel and stay testable.

### Rule 5: Cross-component contracts in `REGRESSION_CONTRACT.md`, not in code comments

Add a section "Wire-Shape Invariants" listing:
- `card_id == "card-${sessionId}"` for agent-generated cards.
- Only Mac PUTs cards; only iOS POSTs instructions.
- `responseRevision` is monotonic per session; iPhone uses strictly-greater as the "new response" signal.
- Mac is the only writer of `~/.steer/steer.sqlite`.

Each gets a regression test in the contract's "required-tests" list.

---

## 5. Freeze plan

Concrete steps to lock down launch.

### 5a. Files to mark "do not touch without an integration test"

Add header comment + an entry in `REGRESSION_CONTRACT.md`:

| File | Reason |
|------|--------|
| `packages/SteerCore/Sources/SteerCore/SessionEntryStore.swift` | Six fixes in 6 hours; six different bugs lived here. Single most fragile file. |
| `apps/ios/SteerIOS/SyncInbox.swift` (WS section L791-931, sendReply L676-706, applyBootstrap caller L513-537) | Each path was a separate regression. |
| `apps/mac/Sources/SteerMac/SyncClient.swift` (pingLoop L531-563, receiveLoop L570-595) | Mac diverged from iOS twice in 24 h. |
| `packages/agent/src/store.js` (`refreshActionCard` L383-424 + `bumpResponseRevisionIfReady` L82-94 + `markSessionAwaitingResponse` L73-77) | The `responseRevision` atomicity guarantee lives here. |
| `packages/relay/src/store.ts` `upsertCard` L103-176 | `becameActive` semantics; R-10 hung off this. |
| `packages/relay/src/apns.ts` PushRequest contract | R-9 changed the payload shape. |

### 5b. Regression tests that should land *today* before launch

Each is < 30 lines.

| Test | File | What it pins |
|------|------|--------------|
| `test_applyBootstrap_promotesAwaitingResponseWhenServerHasNewCard` | SessionEntryStoreTests | R-8 fix (069cb4e) |
| `test_cardResolved_dropsAwaitingResponseEntry` | SessionEntryStoreTests | R-5 fix (79a2f24, replacing 86f87a3) |
| `test_applyBootstrap_dropsEntriesNotInSnapshot` | SessionEntryStoreTests | R-7c fix (b6fe8fe) |
| `test_onCardUpsert_responseRevisionStrictGreaterFlipsStage` | SessionEntryStoreTests | R-0 primitive (b6b8d67) |
| `test_pingLoop_forceCancelsOnSendError` | New (would need URLProtocol stub) | R-6 + R-7a |
| `test_pingLoop_reconnectsAfter60SecondsOfSilence` | New (watchdog) | F-2 — DOES NOT EXIST today and should before launch |
| `test_awaitingResponse_decaysAfterTimeout` | SessionEntryStoreTests | F-5 — DOES NOT EXIST today |
| `relay: test_upsertCard_becameActiveOnTransitionToActive` | store_upsert_dedupe.test.ts (already exists per 664518c) | R-10 |
| `relay: test_fanout_setsBadge1` | New (1-liner against apns.ts mock) | R-9 |
| `relay: ownership check rejects card PUT from iOS device JWT` | connection_contract.test.ts | F-7 |
| `iOS scenario: WS dies mid-reply, foreground recovers carousel within 5 s` | New integration test | F-8 — the integration test that would have prevented half this incident |

Of these, the **three that didn't exist today** (F-2 watchdog, F-5 timeout, F-8 mid-reply WS death) are the highest leverage. The others are already in tree from the regression cascade itself and just need to be enumerated in REGRESSION_CONTRACT.md as required.

### 5c. Tag the current commit

```sh
git tag -a launch-candidate-2026-05-13 b737db8 \
  -m "Launch-candidate sync layer. Audit: docs/SYNC_LAYER_AUDIT_2026-05-13.md"
git push --tags
```

Any future regression has a clean rollback target. If iPhone build N+1
breaks sync, `git checkout launch-candidate-2026-05-13 -- apps/ios apps/mac packages/SteerCore packages/relay/src` is the escape hatch.

Suggested cadence: tag a new `launch-candidate-YYYY-MM-DD` whenever
`SessionEntryStoreTests` + `STEER_INTEGRATION=1 npm test` are both
green AND a real-device golden-set check passed. Today qualifies.

---

## 6. What you cannot answer from code alone

Be explicit about the gaps a code audit cannot close — the user has
been bitten by "I read the diff, looks fine" today.

1. **iOS background suspend timing.** Simulator behavior diverges from real device. Real iPhone running iOS 18+ on real cellular vs simulator on a Mac wired to Ethernet — the WS socket survival profile and APNS wake latency are different. Today's R-5/R-6/R-7 fixes assume specific Cloudflare DO idle behavior and iOS suspend behavior. **Must verify on real device**: lock iPhone for 5/15/60 minutes, then open. Card should land within 5 s.
2. **Cloudflare DO idle window in production load.** The 5–10 min "ish" comes from wrangler tail observation. Production DO can be more aggressive under cost pressure. Watch `wrangler tail` for `Canceled @` markers during the actual launch window.
3. **APNS delivery reliability under DND / Focus.** R-9's badge fix assumes Focus filters don't strip `badge`. iOS HIG suggests they don't, but the testing matrix needs a real-device pass with Focus modes (Sleep, Work, Do Not Disturb).
4. **WebSocket survival across iOS upgrades during a session.** If iOS auto-updates during a backgrounded period, the socket dies AND APNS goes through a re-registration window. Behavior post-upgrade-first-launch is not covered.
5. **Multi-iPhone / multi-Mac per Apple ID.** The fanout iterates `devices.filter(d => d.platform === 'ios')` (relay index.ts L283-285) — every iOS device gets the push. If a user has two iPhones signed in, both will badge. Acceptable? Verify with user.
6. **Network class transitions (WiFi → cellular → captive portal).** The backoff handles disconnect, but a captive portal returns 200 OK with HTML that fails `JSONDecoder` — the error path is `lastError = "Failed to load cards..."` (SyncInbox.swift L535) but the user might be on a hotel WiFi and see the inbox empty.
7. **Cold-launch order with `pendingFocusSessionId` from a notification tap.** APNS deep link sets `pendingFocusSessionId` (SyncInbox.swift L389-400). If the cold-start bootstrap hasn't completed yet, `cards.contains(where: ...)` is empty and the deep link no-ops. There's a retry hook via `.onReceive(inbox.$cards)` (InboxView L188-197) that re-honors it. **Must verify on real device**: cold-launch from a notification, the tapped card is what's focused.
8. **Real-time correctness of `instructedSessions` across Mac sleep/wake.** The decay tick is the 2 s reload loop; if the Mac slept for hours with a session "instructed," wake-up may show the chip lit for one tick before decay runs. Visual artifact, but verifiable only on a real Mac.

---

## Executive summary (read in 60 seconds)

The sync layer's recurrent regressions all share one root cause: the
iPhone state machine is split across `SyncInbox.swift`, `InboxView.swift`,
and `SessionEntryStore.swift` — three files that each mutate or react to
the same `sessions` array, with no enforced funnel. Compounded by two
asymmetric paths into the same state (`applyBootstrap` vs `onCardUpsert`)
that disagreed on `.awaitingResponse` handling, and a WebSocket
"is-it-healthy?" heuristic that depends on send/ping erroring (which
they don't when Cloudflare silently half-closes). Net: six bug-fix
commits in six hours, two of which directly reverted each other
(86f87a3 ↔ 79a2f24).

The smallest discipline that locks this down: **treat the relay GET as
authoritative on every transition** (unify `applyBootstrap` and
`onCardUpsert` into one reducer), **give every cache entry a maximum
lifetime** (`.awaitingResponse` → `.failed` after 10 min), and **judge
WS health by "frame received within N seconds," not by send/ping
outcomes**. Add three integration tests (mid-reply WS death,
`.awaitingResponse` timeout, frame-watchdog reconnect) and tag b737db8
as `launch-candidate-2026-05-13` for a clean rollback target. Real-
device verification remains required for iOS suspend timing, APNS
under Focus, and cold-launch from notification tap — none of those
can be answered from code alone.
