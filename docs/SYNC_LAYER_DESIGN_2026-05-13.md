# Steer iOS ↔ Mac Sync Layer Design — 2026-05-13

Companion to `docs/SYNC_LAYER_AUDIT_2026-05-13.md`. The audit
diagnoses *what* broke (six regressions in six hours, two of which
literally reverted each other) and prescribes five rules. This
document is the *how*: a deterministic blueprint for landing those
rules without introducing the next regression cluster.

This is not a wish-list. Every section either pins down an exact
function signature, an exact race-tie-breaker, an exact persistence
shape, or an exact merge order. If you cannot turn a paragraph into
code, the paragraph isn't done.

Pinned HEAD: `b737db8` (the same `launch-candidate-2026-05-13`
the audit recommends tagging).

---

## §10. Executive summary (read in 60 seconds)

Option C is one cohesive design with two enabling primitives. The
two primitives are:

1. **A single reducer.** Replace `applyBootstrap`,
   `onCardUpsert`, `onCardResolved`, and `markUserReplied` with a
   pure function `SessionEntryStore.apply(state, event)` whose
   discrimination is over an `Event` enum, where `Event.snapshot`
   carries the relay GET's full card list. The reducer is pure
   Swift in SteerCore; iOS *and* Mac consume it.
2. **A monotonic per-event clock.** Every external event (server
   GET, WS upsert, WS resolve, user reply, response promotion,
   timeout decay) carries an `eventSeq: UInt64` from a single
   local counter. Ties between competing events are broken by
   `eventSeq`, with `responseRevision` from the server as the
   tiebreaker for "same card, which version wins."

Once those two primitives land, the rest of Option C is plumbing:
the Mac funnel is a single `setMacState(reducer-output)` call from
`reload()`; `lastPublishedCardIds` persists by writing a tiny JSON
sidecar to `~/.steer/sync-publish-state.json`; the
`.awaitingResponse` 10-minute timeout becomes a virtual event the
reducer schedules; the WS health watchdog is a separate Task
checking `Date().timeIntervalSince(lastFrameAt) > 60s`.

Six PRs, in strict order: race-matrix tests (locks behaviour) →
`eventSeq` primitive → reducer rewrite (iOS only at first) → Mac
adopts reducer + setMacState → publish-state persistence →
frame-watchdog + `.awaitingResponse` decay. Each PR is independently
revertable. The reducer rewrite ships behind a `STEER_REDUCER_V2`
runtime flag so a regression catches in dogfood before the old code
gets deleted.

What this design does NOT cover: any change to the relay's
`becameActive` semantics, the agent's `responseRevision` bump, or
the v3 event log roll-out. Those are out of scope and constrain
this design — see §8 for the invariants we preserve, and §9 for
deferred items.

---

## §1. The single reducer

Replaces: `applyBootstrap` (L76-157), `onCardUpsert` (L177-235),
`onCardResolved` (L255-262), `markUserReplied` (L270-288),
`markReplyFailed` (L292-306), `cancelFailedReply` (L311-327), and
the cold-start logic currently inlined in `SyncInbox.reload`
(L513-537).

### 1.1 Location: SteerCore, single file

Lives in `packages/SteerCore/Sources/SteerCore/SessionEntryStore.swift`.
The audit's F-4 ("bootstrap vs upsert asymmetric paths") was the
single most expensive regression of the audit window (R-7c → R-8
in 8 minutes). The fix is structural: both code paths reduce to one
function, both clients consume it.

iOS consumes through `SyncInbox.setSessions(reducer.apply(...))`.
Mac consumes through `setMacState` (§3). The reducer holds no
state — callers pass the previous `[SessionEntry]` and an `Event`,
get back a new `[SessionEntry]`. SwiftUI re-renders by virtue of
the caller storing the result in `@Published`.

### 1.2 Exact signature

```swift
public enum SessionEntryStore {

    /// Apply one external event to the previous session list.
    ///
    /// The reducer is pure: same inputs → same output. Callers
    /// hold the `[SessionEntry]` and replace it with the return
    /// value. iOS owns one `[SessionEntry]` per `SyncInbox`; Mac
    /// owns one per `SteerRootView`.
    ///
    /// `now` is injected (real clock at call sites, fixed clock
    /// in tests). Required for `.awaitingResponseTimeout` and
    /// for stamping `eventSeq` consumers. Never read `Date()`
    /// inside the reducer body.
    ///
    /// `eventSeq` is a process-monotonic counter. The caller
    /// increments it once per `apply` call. Within the reducer
    /// it is used only for tie-breaking — see §2.
    public static func apply(
        previous: [SessionEntry],
        event: Event,
        eventSeq: UInt64,
        now: Date
    ) -> [SessionEntry]

    /// Discrete event sources. Closed enum: no caller can
    /// invent a new transition without extending this type,
    /// which forces the corresponding test to be written.
    public enum Event: Equatable {
        /// GET /v1/sync/cards returned. `cards` is the full
        /// authoritative list of active cards the server has
        /// for this user. The reducer drops any prior entry
        /// whose session is not in `cards`, except for entries
        /// whose `lastReplyEventSeq > snapshotStartedAtSeq`
        /// (race tiebreaker §2.A).
        case snapshot(
            cards: [CardPayload],
            snapshotStartedAtSeq: UInt64
        )

        /// WS pushed `card.upsert`. May land before or after
        /// the snapshot that should have included it. The
        /// reducer never trusts arrival order — it uses
        /// `card.updatedAt` and `responseRevision` to decide.
        case upsert(card: CardPayload)

        /// WS pushed `card.resolved`.
        case resolved(cardId: String)

        /// User tapped Send. Optimistic transition; the
        /// `lastReplyEventSeq` stamp on the resulting entry
        /// is `eventSeq` of this call — used to ignore stale
        /// upserts (§2.C) and GETs (§2.B) that were already
        /// in flight when the reply happened.
        case userReplied(
            cardId: String,
            text: String,
            instructionId: String
        )

        /// HTTP POST /v1/sync/instructions failed. Caller
        /// surfaces the reason; the reducer just stamps the
        /// entry as `.failed(reason)`.
        case replyFailed(instructionId: String, reason: String)

        /// User dismissed a `.failed` entry. Returns to
        /// `.awaitingUser`.
        case replyCancelled(instructionId: String)

        /// 10 min elapsed since `.awaitingResponse` was
        /// stamped. Virtual event the host schedules; the
        /// reducer never reads the clock by itself.
        case awaitingResponseTimeout(sessionId: String)
    }
}
```

The `SessionEntry` shape gains two fields to support the
race-matrix:

```swift
public struct SessionEntry: Identifiable, Equatable {
    public var id: String { card.cardId }
    public let sessionId: String
    public var card: CardPayload
    public var stage: SessionStage
    public var lastReplyText: String?
    public var lastInstructionId: String?
    public var instructedRevision: Int?

    /// `eventSeq` at the moment of the most recent user reply on
    /// this entry. Used by `.snapshot` and `.upsert` to ignore
    /// older server events that were already in flight when the
    /// reply happened. nil for entries that never left
    /// `.awaitingUser`.
    public var lastReplyEventSeq: UInt64?

    /// `eventSeq` of the most recent `apply` call that touched
    /// this entry. Pure debug aid (logged in failures); not
    /// load-bearing.
    public var lastTouchedSeq: UInt64
}
```

The `SessionStage` enum gains one case:

```swift
public enum SessionStage: Equatable {
    case awaitingUser
    case awaitingResponse(stampedAt: Date)   // was: bare case
    case failed(String)
}
```

Carrying `stampedAt` inside the case is what lets the host
schedule the 10-min timeout (§5) without the reducer reading the
clock. The stamp is the *injected* `now`, not real wall-clock.

### 1.3 Why fold events one at a time, not snapshot+delta

Considered alternative: `apply(snapshot, deltas) → state`. Rejected
for three reasons:

1. **Asymmetric arrival.** WS upserts and GETs arrive in arbitrary
   order. A reducer that takes "the snapshot plus N deltas" forces
   the host to buffer deltas until the snapshot lands, then replay.
   That's exactly the cold-start race we currently fail (audit F-4).
2. **Idempotency cost.** A streaming reducer is naturally idempotent
   per-event (same event seq → same result). A snapshot+delta
   reducer has to dedupe deltas against the snapshot's cursor — a
   class of bug we don't need.
3. **Test surface.** Per-event reducers are trivial to test with
   table-driven cases. Snapshot+delta reducers need fixtures for
   "snapshot landed first" vs "snapshot landed after the delta."

The `.snapshot` event is conceptually equivalent to "drop every
entry not in `cards`, then upsert each card in `cards`." The
reducer expands it that way internally (§1.5).

### 1.4 Idempotency

Each of these MUST produce identical state when applied twice:

| Event | Idempotency rule |
|-------|------------------|
| `.snapshot` | Pure function of `previous` and `cards`. The same `cards` set yields the same result. `snapshotStartedAtSeq` is the *only* parameter that changes between retries of the same logical GET — and it only matters when a write happens between snapshot start and snapshot land (§2.B), so re-applying the same `.snapshot` with the same `snapshotStartedAtSeq` is a no-op. |
| `.upsert` | Two identical upserts: if `responseRevision` is unchanged, the second upsert refreshes `card.updatedAt`/content but leaves stage untouched (current behaviour, preserved). If `responseRevision` is greater than `instructedRevision`, the first upsert already promoted to `.awaitingUser`; the second finds the entry already in `.awaitingUser` and just refreshes content. |
| `.resolved` | Drops the entry. Second resolve finds no matching entry; no-op. |
| `.userReplied` | The entry's `lastReplyEventSeq` is stamped to the new `eventSeq` on every call. A double-tap of Send (UI shouldn't allow but defensive) re-stamps and re-generates a fresh `instructionId`. We accept that retrying the same `instructionId` is the caller's problem (`SyncInbox.sendReply` generates a fresh UUID per call). |
| `.replyFailed` | Reducer only flips stage when the current stage is `.awaitingResponse` and `lastInstructionId == instructionId`. A duplicate failed-ack against `.failed` is a no-op (current behaviour). |
| `.replyCancelled` | Reducer only acts when stage is `.failed`. Duplicate cancel is a no-op. |
| `.awaitingResponseTimeout` | Reducer only acts when the entry exists, stage is `.awaitingResponse`, and the stamp is older than 10 min before `now`. Late delivery (entry already transitioned out) is a no-op. |

### 1.5 The `.snapshot` expansion

In English:

1. Index `cards` by sessionId.
2. For every entry in `previous`:
   - If the session is in `cards`: apply the upsert rules to merge
     in the new payload.
   - Else: if `entry.lastReplyEventSeq > snapshotStartedAtSeq`, the
     user replied AFTER the GET went out — the server's "no card
     for this session" is stale; keep the entry. Otherwise drop.
3. For every card in `cards` whose session was NOT in `previous`:
   - Insert as `.awaitingUser`.
4. Sort by `card.updatedAt`.

### 1.6 The `.awaitingResponse → .awaitingUser` promotion

Three signals can drive this; the reducer evaluates in order:

1. **`responseRevision` strictly greater** than `entry.instructedRevision`.
   This is the load-bearing primitive (R-0, b6b8d67). The agent bumps
   it *before* upserting the card row in one write transaction
   (`store.js:refreshActionCard` L383-424); iPhone sees one consistent
   upsert with the new revision. Use this whenever the incoming card
   has a non-nil `responseRevision`.

2. **`card.cardId` differs** from `entry.card.cardId` AND the
   incoming `updatedAt > entry.card.updatedAt`. This catches the case
   where a future provider issues a fresh `cardId` per turn (we don't
   today — see invariant §8.1 — but the reducer doesn't hard-code
   `card-${sessionId}`; it just observes the wire).

3. **Snapshot says so.** A `.snapshot` containing a card for this
   session, where the entry was `.awaitingResponse(stampedAt:)` and
   `card.updatedAt > stampedAt.ms` AND `card.responseRevision == nil`
   (legacy / mid-rollout). Same content-promotion rule as today's
   `applyBootstrap` (L86-109).

The reducer does NOT promote if every signal is silent — the entry
stays `.awaitingResponse` until either signal fires or the 10-min
timeout decays it (§5).

---

## §2. Race matrix — GET vs WS, with timestamps

Every cell here is a real race we either hit (cited in audit) or
will hit on the next idle-window reconnect. The "tiebreaker" column
is the field the reducer reads to pick the winner. If a row's
tiebreaker doesn't already exist on the wire, the design adds it
(currently we add only one: `snapshotStartedAtSeq`).

The convention is: the *higher* value wins for monotonic counters
(eventSeq, responseRevision, updatedAt), the more-recent decision
wins where there is one.

### 2.A. GET returns card with `updatedAt = T1`. WS upsert arrives with `updatedAt = T2`.

```
                 T0           T1            T2
GET fired ──────┤
GET returns ────────────────┤
WS upsert ──────────────────────────────┤
```

Three sub-cases by arrival order at the client:

| Arrival | Winner | Tiebreaker |
|---------|--------|------------|
| GET lands first, then WS | WS overwrites (later `updatedAt`) | `card.updatedAt` |
| WS lands first, then GET | If GET's `updatedAt < WS's`, GET is stale — GET DOES NOT downgrade content; reducer keeps WS card. If GET's ≥ WS's, GET wins (it has the newer view). | `card.updatedAt` |
| Concurrent (same tick) | Process in arrival order; whichever wrote last wins | n/a |

Implementation: every time the reducer would replace `card`, it
checks `incoming.updatedAt >= existing.card.updatedAt`. If not,
skip the content swap but still consider stage promotion (e.g. a
stale GET might still legitimately bump `responseRevision`, though
this should not happen given the agent's bump-then-upsert ordering
in `store.js:refreshActionCard` L388 → L409).

**Where `updatedAt` is bumped:** agent side. `store.js:refreshActionCard`
L409 writes `now` (ISO string of `Date()`) for both `created_at` and
`updated_at` columns. Mac's `SteerCardMapping.payload` L31-32 stamps
ms-since-epoch on every call. Both monotonic against wall clock; OK
to use for ordering.

### 2.B. WS upsert arrives. GET response lands 200 ms later, doesn't include that card.

```
GET fired ──────┐
                │       WS upsert (new card C)
                │              ↓
GET returns ────┤   (server's view didn't see C yet)
                │              ↓
GET applied at client (would clobber C)
```

**Rule:** GET's "this session has no card" is suspect when an upsert
for that session arrived between GET-fire and GET-land. The reducer
sees `event.snapshot(cards, snapshotStartedAtSeq)`. For each entry
not in `cards`, it checks: did a higher-seq event touch this entry
after `snapshotStartedAtSeq`? If yes, keep the entry.

The host (`SyncInbox.reload()`) is responsible for capturing the
seq at GET-fire time:

```swift
public func reload() async {
    guard isSignedIn else { return }
    let snapshotStartedSeq = nextEventSeq()  // capture BEFORE GET fires
    do {
        let resp: CardListResponse = try await getJSON("/v1/sync/cards")
        applyEvent(.snapshot(
            cards: resp.cards,
            snapshotStartedAtSeq: snapshotStartedSeq
        ))
    } catch { ... }
}
```

Any `.upsert` / `.userReplied` / `.resolved` event that gets a
higher seq between those two lines stamps its entry with
`lastTouchedSeq > snapshotStartedSeq`, which the snapshot rule
preserves.

This is a strictly stronger guarantee than today's bespoke
`applyBootstrap` — which preserves any `.awaitingResponse`
unconditionally (current logic at L150-153 of
SessionEntryStore.swift) and which the audit's R-7c then over-
corrected to "drop unconditionally." The eventSeq rule is exactly
the discrimination R-7c lacked.

### 2.C. User taps Send → markUserReplied stamps `.awaitingResponse`. Old WS broadcast (pre-reply card) arrives.

```
markUserReplied (eventSeq = 100)
   ↓
entry.lastReplyEventSeq = 100
   ↓
WS upsert (eventSeq = 101, card has same responseRevision as before)
```

**Rule:** if `incoming.responseRevision <= entry.instructedRevision`
AND entry is `.awaitingResponse`, the upsert is a re-publish of the
*pre-reply* card (the 2 s reload tick). The reducer refreshes
content but does NOT downgrade stage. Current behaviour at
SessionEntryStore.swift L194-224 already does this — locked in by
`test_sameRevisionReUpsert_keepsAwaitingResponse`. No change.

If `responseRevision > instructedRevision`, the upsert IS the
response and we promote (current L206-211 behaviour). No change.

`lastReplyEventSeq` is not the tiebreaker here; `responseRevision`
is. `lastReplyEventSeq` only matters in (2.B) where the server has
no `responseRevision` signal to offer.

### 2.D. `.awaitingResponse` entry hits its 10-min timeout. Response upsert arrives 200 ms later.

```
T-10m   userReplied stamp
T0      awaitingResponseTimeout virtual event fires
T0+200ms WS upsert (responseRevision = stamp + 1)
```

**Rule:** timeout wins if it fires first; the upsert then
*re-creates* the entry as `.awaitingUser` because the timeout
already removed the entry. The user sees:

- T-10m → "running" chip lit
- T0    → chip clears, "reply timeout — your reply may not have
  been delivered. retry?" banner appears
- T0+200ms → banner disappears, carousel gains the response card

This is intentional. The timeout is the user-visible safety net for
when the response *truly* never arrives; if it then *does* arrive,
we don't pretend the timeout never happened (that would silently
restore the entry and the user has just seen a banner that retried
itself; confusing). The banner clears the moment the new card
appears.

Concrete: when `.awaitingResponseTimeout` fires, the reducer
transitions to `.failed("response timeout")` rather than dropping
the entry outright. A subsequent `.upsert` with
`responseRevision > instructedRevision` then promotes via the
`.failed` branch (current L110-119 logic), refreshing the card and
moving to `.awaitingUser`. The "timeout banner" UI is a derived
projection of `failedEntries(in:)` filtered by reason ==
"response timeout".

### 2.E. Concurrent `.userReplied` and `.upsert` (response landed during typing)

```
User typing reply...
                         WS upsert (responseRevision = N+1)
                            ↓
                            entry now .awaitingUser, card is the response
User taps Send
                            entry was just promoted ↑, now sent against the
                            NEW card → wrong target session timestamp
```

**Rule:** `.userReplied(cardId:)` looks up the entry by **cardId**,
not by sessionId (current L277 logic). If the entry has been
replaced with a different cardId (i.e. promoted), the cardId in
`.userReplied` no longer matches and the reducer no-ops. The host
catches this and shows the user "the reply target moved — review the
new card" — but since today we reuse `card-${sessionId}` for every
card on a session (invariant §8.1), this branch is *defensive
only*: cardId matches across response turns. Test pins it.

### 2.F. Two WS upserts arrive out of order (rare, but possible across reconnect)

```
WS upsert (responseRevision = 3)  ← arrives second
WS upsert (responseRevision = 4)  ← arrives first (after reconnect resync)
```

**Rule:** the reducer uses `max(incoming.responseRevision,
existing.card.responseRevision ?? 0)` to decide promotion. The
later-but-lower-revision upsert refreshes content if its
`updatedAt > existing.updatedAt` (which it won't, because the
agent bumps both together at L388, L409, L412 of store.js); else
it's silently dropped.

### 2.G. Tiebreaker summary

| Decision | Tiebreaker | Server-side bump site |
|----------|------------|------------------------|
| Same session, different cards: which content wins | `card.updatedAt` | `packages/agent/src/store.js` `refreshActionCard` L412 (passes `now` to `upsertActionCard`) → relay `store.ts:upsertCard` L172 |
| `.awaitingResponse → .awaitingUser` promotion | `responseRevision` (strictly greater) | `packages/agent/src/store.js` `bumpResponseRevisionIfReady` L82-94 (called at L388 of `refreshActionCard`, before the card upsert at L409) |
| Stale GET vs recent user write | `lastReplyEventSeq` (entry) vs `snapshotStartedAtSeq` (event) | client-only; no server bump |
| `.replyFailed` matches against entry | `instructionId` (exact match) | iOS POST `/v1/sync/instructions` returns the same id on echo |
| `.awaitingResponseTimeout` matches entry | `sessionId` AND stage is `.awaitingResponse` AND stamp is ≥ 10 min old | client-only; scheduled by host on transition into `.awaitingResponse` |

### 2.H. The race we accept

Mid-reply WS death + GET that happened to fire 100 ms before the
relay observed the new response card. The GET returns the *pre-reply*
card. eventSeq doesn't save us here: the user reply was a different
event from a different device; the GET pre-dates nothing local.

Outcome with this design: the `.snapshot` reducer step sees a card
for the session (the pre-reply one), the entry is `.awaitingResponse`,
and the snapshot's card has `responseRevision == entry.instructedRevision`
(the bump hasn't happened on the agent yet). Following §1.6 rule 3,
we DO NOT promote — `updatedAt` is older than `stampedAt`. Entry
stays `.awaitingResponse`. Next WS upsert (200 ms later) carries
`responseRevision + 1` and promotes correctly.

Lock this with a test: `test_snapshot_preReplyCardDoesNotDowngrade`.

---

## §3. setMacState funnel — does it fit Mac's architecture?

The audit calls out that Mac has no setSessions equivalent. The
question is whether to bolt one on, or to admit Mac and iOS have
fundamentally different shapes.

### 3.1 What Mac is doing today

`SteerRootView.reload()` (L329-485) runs every 2 s on a Task tick.
Per tick it:

1. Reads local SQLite via `store.loadCards()` → `[ActionCard]`.
2. Reads live sessions via `store.loadLiveSessions(excluding: [])` → `[LiveSessionChip]`.
3. Mutates seven pieces of `@State`: `cards`, `liveChips`,
   `instructedSessions`, `lastPublishedCardIds`, `lastPublishedCardHashes`,
   `didSeedFromRelay`, `focusedSessionId`.
4. Diffs against the last-published baseline → `diffCardsForPublish`.
5. PUTs / DELETEs to the relay via `syncToiPhone`.
6. Drains queued instructions via `drainQueuedInstructions`.
7. Heartbeats device + iPhone presence.

Mac is the *producer* of cards on the relay; the relay is the
*authoritative source* for iOS. The two roles look mirror-symmetric
but they're not: Mac never *receives* card state from the relay
(the WS handler at L597-610 of SyncClient just nudges the UI via
NotificationCenter — see §3.4).

### 3.2 The funnel: diff between two SQLite snapshots

The natural shape for Mac is **diff-based**, not event-based.
SQLite is the source of truth, polled every 2 s. A "delta stream"
synthesised from snapshots gives us nothing the diff doesn't.

Proposed funnel signature:

```swift
@MainActor
struct MacSyncState {
    var cards: [ActionCard]
    var liveChips: [LiveSessionChip]
    var instructedSessions: [String: InstructedAt]
    var lastPublishedCardIds: Set<String>
    var lastPublishedCardHashes: [String: Int]
    var didSeedFromRelay: Bool
    var focusedSessionId: String?
}

extension SteerRootView {
    /// Single mutation point. Computes `next` from the previous
    /// snapshot + a freshly-loaded `LocalSteerStore` read. Returns
    /// the side effects to apply (publish queue, resolve queue,
    /// state to write back). The view stores `next.state` and runs
    /// `next.effects`.
    private func setMacState(
        previous: MacSyncState,
        loadedCards: [ActionCard],
        loadedLive: [LiveSessionChip],
        now: Date,
        signedIn: Bool,
        toggleOn: Bool
    ) -> (state: MacSyncState, effects: MacSyncEffects)
}

struct MacSyncEffects {
    var publishCards: [ActionCard]
    var resolveCardIds: [String]
    var heartbeatDue: Bool
    var drainDue: Bool
    var refreshDevicesDue: Bool
}
```

The funnel takes the loaded SQLite snapshot, runs the existing
`CardReconciler.reconcile` decision, runs `InstructedSessionDecay.decay`,
and returns the new state plus what to do over the network. The
view body of `reload()` becomes:

```swift
private func reload() async {
    let loadedCards = await store.loadCards()
    let loadedLive = await store.loadLiveSessions(excluding: [])
    await notifyForNewCards(loadedCards)

    let (next, effects) = setMacState(
        previous: currentMacState(),
        loadedCards: loadedCards,
        loadedLive: loadedLive,
        now: Date(),
        signedIn: SyncClient.shared.isSignedIn,
        toggleOn: SteerSettings.shared.iPhoneSyncEnabled
    )
    applyMacState(next)               // assigns @State fields
    await runEffects(effects)         // PUT/DELETE/heartbeat/drain
}
```

### 3.3 Owns publishing, or just in-memory `cards`?

The funnel owns **deciding** what to publish. It does NOT own
**doing** the publish (that's `runEffects`). The split exists so
the funnel is unit-testable: pass a `MacSyncState` and a SQLite
snapshot, assert on the returned `MacSyncEffects`. No need to mock
URLSession.

### 3.4 Interaction with the existing reducer (§1)

Currently Mac's `SyncClient.handleWSText` (L597-610) processes WS
messages by posting `.syncDidReceiveUpdate`, which triggers a drain
but otherwise no-ops. The view doesn't react to inbound `card.upsert`
broadcasts because the local SQLite is the authoritative source.

This stays the same. The §1 reducer is for iOS, where the *relay*
is authoritative. Mac's funnel is its own reducer, with different
inputs (SQLite snapshot, not WS events). Sharing the SessionEntryStore
across Mac and iOS was attractive but the data flow is different
enough that one shape doesn't fit both.

Concrete decision: keep §1 reducer iOS-only at the SessionEntry
abstraction level. Mac uses `ActionCard` (its own UI model) plus
`CardReconciler` (which is already in SteerCore and is the actual
shared piece). The funnel is a Mac-side wrapper, not a SteerCore
type.

### 3.5 Which functions move, which stay

| Function | Today | After |
|----------|-------|-------|
| `SteerRootView.reload()` | 156 lines, mutates 7 states | 25 lines: load → funnel → applyState → effects |
| `SteerRootView.diffCardsForPublish` | private to view | private to funnel; signature unchanged |
| `SteerRootView.syncToiPhone` | called from reload | called from `runEffects(effects)` |
| `SteerRootView.maybeHeartbeat` | called from reload | called from `runEffects(effects)` only when `effects.heartbeatDue` |
| `SteerRootView.maybeDrainQueuedInstructions` | called from reload | called from `runEffects(effects)` only when `effects.drainDue` |
| `SyncClient.publishCard` / `resolveCard` | called direct from view | unchanged |
| `SyncClient.connectWebSocket` / `pingLoop` / `receiveLoop` | unchanged | unchanged (the §6 watchdog goes here, not in the funnel) |

The funnel is ~120 lines of pure logic in a new file
`apps/mac/Sources/SteerMac/MacSyncFunnel.swift`. The view body
shrinks accordingly.

---

## §4. `lastPublishedCardIds` persistence

Audit F-3: Mac's publish baseline is `@State`. Every cold-start
re-seeds from the relay; if `fetchActiveCards` returns nothing or
errors, `didSeedFromRelay` flips true anyway (L429-442) and the
diff ships with an empty baseline. Orphans slip through.

### 4.1 Storage choice: small JSON sidecar

`~/.steer/sync-publish-state.json`. Format:

```json
{
  "version": 1,
  "userId": "<sha256-of-userId>",
  "publishedAt": 1747156800000,
  "ids": {
    "card-sess-1": { "fingerprint": 1234567890 },
    "card-sess-2": { "fingerprint": 9876543210 }
  }
}
```

NOT SQLite. Reasons:

1. `~/.steer/steer.sqlite` is the agent's exclusive writer
   (invariant §8.4). The Mac app deliberately uses `sqlite3 -json`
   for reads. Writing the publish state to that DB violates the
   single-writer rule for *the very table* that already has
   migration-runner contention. A separate file is correctly
   scoped to the Mac app.
2. UserDefaults is sandbox-friendly but its sync model (defaults
   write happens on a Foundation queue, atomicity depends on the
   OS) is worse than a single-process JSON file for our case.
3. The Mac app is the only writer (it's a per-user-per-machine
   piece of state), so contention is not a concern. A `.lock`
   sidecar isn't needed — the 2 s reload loop is the only writer.

### 4.2 What gets persisted

Both the set of ids AND the per-id fingerprint, because:

- IDs alone let us decide DELETEs after a crash mid-publish.
- Fingerprints let us decide whether to re-PUT on cold start
  (otherwise we'd re-publish every card on every launch).

`userId` is a sha256 hash, so the file is harmless if it gets
shared (paste in a bug report, etc.). The sync code only reads
this on launch when the same user is signed in; if `userId`
doesn't match, the file is treated as missing.

### 4.3 First-launch / migration

If the file is absent at the first `reload()` after sign-in, the
funnel falls back to the **current** cold-start path: call
`fetchActiveCards`, treat the result as the published baseline,
write the file. This is a one-time migration; subsequent launches
load the file directly.

If the file exists but `userId` doesn't match the current
`SyncClient.shared.status` user (account switch on the same Mac),
discard it and re-seed from relay.

### 4.4 Race: Mac restarts mid-publish

```
T0    funnel decides to PUT card X
T1    PUT in flight
T2    Mac process killed (SIGKILL, panic, crash)
T3    Mac relaunches
T4    funnel reads sync-publish-state.json
```

Question: was the PUT completed?

We don't know from the local file. The PUT either landed (relay
has the card) or didn't (relay doesn't). The next `reload()` tick
will reconcile:

- Card X is in local SQLite (it was generated by the local
  classifier, that's why we were publishing it).
- Card X is in `lastPublishedCardIds` (we persisted *before* the
  PUT, per below).
- Result: `changedIds` excludes X (fingerprint matches), no
  publish.

Wait — that means a Mac that crashed before the PUT lands will
have the card sitting in local SQLite but NOT on the relay, and
the reconcile pass won't re-publish.

**Decision: persist AFTER the PUT, not before.** The current
in-memory code in `SteerRootView.diffCardsForPublish` (L570-576)
already updates the snapshot optimistically *before* the PUT
completes; that's wrong for the persistent version. The funnel
will:

1. Compute `(publishCards, resolveIds, nextPublishedIds)`.
2. Execute the PUTs in `runEffects`. For each successful PUT,
   write the (id, fingerprint) pair to the in-memory candidate
   set.
3. Execute the DELETEs. For each successful DELETE, remove the
   id from the candidate set.
4. After all effects complete, atomically replace the JSON file
   with the candidate set as the new persisted state.

If the process dies between steps 2 and 4, the next launch reads
the *old* persisted state, runs reconcile against fresh SQLite,
and the now-published-but-not-persisted card looks "changed" (its
fingerprint differs from absent). Result: idempotent re-PUT. Relay
absorbs it (`upsertCard` `changed === false` path; no broadcast,
no APNS). Cost: one wasted PUT per Mac crash. Correctness preserved.

The atomic file write is `Data.write(to:options: .atomic)` — the
foundation primitive that writes to a temp file in the same
directory and renames. Standard, robust.

### 4.5 Why not extend the v3 event log (§9)

Tempting: the relay is gaining an authoritative event log
(`docs/SYNC_ARCHITECTURE_V3.md`). Why not just consume that?

Out of scope for this design. The event log is mid-rollout; v3 PR 1
landed dual-write, PR 4 will delete the legacy routes. Coupling
the Mac's publish-baseline persistence to v3 means we can't ship
the audit fix until v3 ships, and v3's own schedule is
independent. Decoupled.

---

## §5. Max lifetime on cache entries

### 5.1 `.awaitingResponse` 10-minute timeout

**Clock: real wall-clock, injected.** Not monotonic. We need to
survive iOS background suspend — `mach_absolute_time()` pauses while
the device sleeps, so a monotonic clock would never fire if the
user backgrounds for an hour.

Implementation:

- The reducer's `.userReplied` event stamps `now` into
  `.awaitingResponse(stampedAt: now)`.
- The host (`SyncInbox`) keeps a single `Task` per `SyncInbox`
  instance that wakes every 30 s and asks: "any entry where
  `Date().timeIntervalSince(stampedAt) > 600`?" If yes, fire
  `.awaitingResponseTimeout(sessionId:)` events through the reducer.

```swift
private func startTimeoutWatcher() {
    timeoutTask?.cancel()
    timeoutTask = Task { [weak self] in
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            guard let self else { return }
            await self.checkAwaitingResponseTimeouts()
        }
    }
}

@MainActor
private func checkAwaitingResponseTimeouts() {
    let now = Date()
    for entry in sessions {
        guard case .awaitingResponse(let stamp) = entry.stage else { continue }
        guard now.timeIntervalSince(stamp) > 600 else { continue }
        applyEvent(.awaitingResponseTimeout(sessionId: entry.sessionId))
    }
}
```

### 5.2 Why not in SyncInbox via Timer/Combine

Timer is fine in principle but: (a) we already have a structured
Task for `pingLoop`; (b) Combine adds a publisher dependency we
don't otherwise need; (c) `Task.sleep(nanoseconds:)` is the same
mechanism the ping uses, so the test harness can drive both with
the same `Clock` abstraction in the future.

Foregrounding cost: the 30 s check is *upper-bound* on the timeout
detection latency. Worst case the user sees "11 min stuck" instead
of "10 min stuck" before the banner appears. Acceptable.

### 5.3 What happens after timeout

Transition to `.failed("response timeout — your reply may not have
been delivered")`. The user sees the same UI as a POST failure:
the chip goes from running to "1 failed," and the failed-replies
sheet exposes retry / cancel.

Why not silent drop: the audit's lesson from R-4 ↔ R-5 was
exactly that we kept guessing the right tradeoff (flicker forever
vs flicker briefly) when the user-visible cost was high. A failed
banner is the *correct* user-visible signal — "we don't know if
your reply arrived; here's the retry button."

### 5.4 iOS-only or also Mac

**iOS only.** Mac uses `InstructedSessionDecay` instead (current
behaviour, unchanged). The decay rules there are richer (live
session set check, card-updatedAt comparison) and the Mac never
hits the "awaitingResponse stuck forever" failure mode the same way
iOS does — Mac's reply path goes through the local agent, not a
relay round-trip. When the wrapper dies, `InstructedSessionDecay`
removes the entry on the next tick because `liveSessionIds` no
longer contains it.

The two concepts coexist. They serve different stack levels:

- `InstructedSessionDecay` (Mac): "session is no longer live, drop
  the chip."
- `awaitingResponseTimeout` (iOS): "remote reply has not produced a
  card response in 10 min, surface as failed."

### 5.5 Other cache lifetimes worth bounding

The audit's Rule 2 names `.awaitingResponse` and
`pendingFocusSessionId`. The latter clears in `clearPendingFocus`
already (SyncInbox.swift L402), called when the UI honors the deep
link. The risk case is "deep link fired, card never lands" — same
shape, but the user-visible cost is just a dud tap, not a stuck
chip. Add a 30 s timeout via the same Task: clear
`pendingFocusSessionId` if a card with that sessionId hasn't appeared
in 30 s.

`apnsRegistrationError` has no expiry today; OK because the user
clears it explicitly in Settings. Defer.

---

## §6. Frame-based WS health

### 6.1 N seconds: 60 s for both platforms

Both clients today send a ping every 20 s (SyncInbox L832,
SyncClient L542). The watchdog should be loose enough that a normal
ping cycle is not on the boundary; 60 s gives us 3 expected ping
windows of headroom and is still well inside Cloudflare's 5-10 min
DO idle close.

### 6.2 What counts as a frame

**Any received WebSocket frame.** The watchdog cares only about
"have we received bytes from the server" — that's the only signal
that survives Cloudflare's silent half-close. Pings, pongs, upserts,
resolves all count.

Implementation: in `receiveLoop` (SyncInbox L869-892, SyncClient
L570-595), the first line inside the `do` block, on every successful
`task.receive()`, stamps:

```swift
self.lastFrameReceivedAt = Date()
```

The watchdog Task wakes every 15 s and checks:

```swift
if let last = self.lastFrameReceivedAt,
   Date().timeIntervalSince(last) > 60.0 {
    // Force-cancel; receiveLoop throws, backoff reconnect.
    self.webSocketTask?.cancel(with: .goingAway, reason: nil)
}
```

### 6.3 Where the watchdog lives

A new Task, sibling to `pingTask` and `receiveTask`. Three reasons:

1. Putting it inside `receiveLoop` means it can't fire — the loop
   is blocked on `task.receive()` until the watchdog itself unblocks
   it. Chicken-and-egg.
2. Putting it inside `pingLoop` means a slow ping cycle (which
   itself blocks on the network) can starve the watchdog. The whole
   point is to be independent of send-side blocking.
3. URLSession's TCP-level watchdog is not exposed — `URLSessionWebSocketTask`
   has no "if no frame received in N seconds" property. Apple's
   only knob is `URLSessionConfiguration.timeoutIntervalForRequest`,
   which applies to the initial connect, not the post-handshake
   socket.

So: a separate `Task` in both `SyncInbox` and Mac `SyncClient`.

```swift
private var watchdogTask: Task<Void, Never>?
private var lastFrameReceivedAt: Date?

private func startWatchdog(task: URLSessionWebSocketTask) {
    watchdogTask?.cancel()
    watchdogTask = Task { [weak self] in
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.checkFrameWatchdog(task: task)
        }
    }
}

@MainActor
private func checkFrameWatchdog(task: URLSessionWebSocketTask) {
    guard task === webSocketTask else { return }  // stale
    guard let last = lastFrameReceivedAt else { return }
    if Date().timeIntervalSince(last) > 60 {
        task.cancel(with: .goingAway, reason: nil)
    }
}
```

`lastFrameReceivedAt` is reset to `Date()` inside `connectWebSocket()`
on successful connect (the relay sends a `ping` frame on accept —
`userHub.ts` L57 — so the first frame lands within the RTT). If no
ping arrives within 60 s of connect, we tear down.

### 6.4 Backoff suppression

If the watchdog fires while exponential backoff is already in flight
(no frames yet on a newly-reconnected socket), do NOT escalate the
attempt counter. The check:

```swift
@MainActor
private func checkFrameWatchdog(task: URLSessionWebSocketTask) {
    guard task === webSocketTask else { return }
    guard let last = lastFrameReceivedAt else { return }
    if Date().timeIntervalSince(last) > 60 {
        // Don't fire the watchdog while a fresh connect is still
        // expecting its first frame. The fresh-connect grace is
        // tracked by setting lastFrameReceivedAt = Date() at
        // connectWebSocket entry.
        task.cancel(with: .goingAway, reason: nil)
    }
}
```

The "set lastFrameReceivedAt = Date() at connectWebSocket entry"
line is what gives the new socket 60 s to receive its first frame.
A connect that doesn't see *any* frame in 60 s is dead and deserves
the cancel — but exponential backoff will then kick in normally via
`receiveLoop`'s catch block, which already increments
`reconnectAttempt`.

The suppression rule is therefore: **don't increment
`reconnectAttempt` separately from `receiveLoop`'s existing
mechanism.** The watchdog's job is to *unblock* `receiveLoop`, not
to drive the reconnect itself. This composes cleanly.

---

## §7. Migration order

Six PRs. Each is independently revertable. Each ships green tests
before the next merges. The "ship-checked" gate between PRs is:
the prior PR's tests stay green after the new PR lands.

### PR-1: Race-matrix tests, locked behaviour-equivalent

**Goal:** lock today's behaviour with the race tests from §2 *before*
touching production code. If the existing code doesn't pass these
tests, that itself is a bug we want surfaced now, not after the
reducer rewrite.

**Files touched:**
- `packages/SteerCore/Tests/SteerCoreTests/SessionEntryStoreTests.swift` (extend)
- new: `packages/SteerCore/Tests/SteerCoreTests/SessionEntryRaceMatrixTests.swift`

**Tests added:**
- `test_get_then_ws_widerUpdatedAtWins` (§2.A)
- `test_ws_then_get_doesNotDowngrade` (§2.A)
- `test_get_doesNotClobberCardWrittenDuringFlight` (§2.B; will fail
  on today's code — that's expected, it's documenting the gap)
- `test_userReplied_thenStaleUpsert_keepsAwaitingResponse` (§2.C)
- `test_userReplied_thenResponseUpsert_promotes` (§2.C)
- `test_timeout_thenLateResponse_promotesThroughFailed` (§2.D; will
  fail until PR-6 adds the timeout)
- `test_concurrent_replyAndPromotion_byCardId` (§2.E)
- `test_outOfOrder_revisions_useMax` (§2.F)
- `test_snapshot_preReplyCardDoesNotDowngrade` (§2.H)

**Gates before merging:**
- `swift test --package-path packages/SteerCore` — all tests pass
  except the three explicitly XCTSkip'd as "PR-3+ work."
- `swift build --package-path apps/mac` — clean.
- `npm test` — green.

**Revert breaks:** nothing user-facing. Just removes tests.

**Dogfood signal:** none — this PR is mechanical.

**Independent:** yes.

### PR-2: `eventSeq` primitive + per-event stamping

**Goal:** wire a `nextEventSeq()` counter into `SyncInbox` and
stamp every external-event call site with the resulting seq. The
reducer is NOT changed yet — every site that calls
`SessionEntryStore.applyBootstrap/onCardUpsert/etc` now ALSO records
a `lastReplyEventSeq` on the relevant entry. The current reducer
ignores this stamp (it has no field for it yet); the field is added
to `SessionEntry` and threaded through.

**Files touched:**
- `packages/SteerCore/Sources/SteerCore/SessionEntryStore.swift`
  (add `lastReplyEventSeq`, `lastTouchedSeq` to `SessionEntry`;
  existing transitions zero-default them)
- `apps/ios/SteerIOS/SyncInbox.swift` (add `private var _nextSeq:
  UInt64 = 0`; stamp at `reload`, `handleWSText.cardUpsert`,
  `handleWSText.cardResolved`, `sendReply`, `postReply` callbacks)

**Tests:**
- `test_sessionEntry_defaultLastReplyEventSeq_nil`
- `test_markUserReplied_stampsCurrentSeq` (passed in as an arg)
- New tests file: `packages/SteerCore/Tests/SteerCoreTests/EventSeqTests.swift`

**Gates:**
- All PR-1 tests stay green.
- `npm test` green.
- `swift build --package-path apps/mac` clean.

**Revert breaks:** adds a field nobody reads yet. Reverting requires
re-removing the field, ~30 lines.

**Dogfood signal:** none.

**Independent:** depends on PR-1.

### PR-3: Reducer rewrite, iOS-only, behind `STEER_REDUCER_V2` flag

**Goal:** introduce `SessionEntryStore.apply(previous:event:eventSeq:now:)`
alongside the existing functions. iOS conditionally routes through
the new path under env var `STEER_REDUCER_V2=1` (or a debug build
default). The old `applyBootstrap` / `onCardUpsert` / etc remain
in place.

**Files touched:**
- `packages/SteerCore/Sources/SteerCore/SessionEntryStore.swift`
  (add `apply`, `Event`; old functions stay for now)
- `apps/ios/SteerIOS/SyncInbox.swift` (add branched call sites:
  `if FeatureFlags.reducerV2 { applyEvent(...) } else { setSessions(
  SessionEntryStore.applyBootstrap(...)) }`)
- `apps/ios/SteerIOS/FeatureFlags.swift` (new, single file, 20
  lines; reads env + UserDefaults)

**Tests:**
- All PR-1 race tests must pass against the new `apply` function.
- Old `applyBootstrap` tests stay green (they call the legacy path).

**Gates:**
- `swift test` green.
- `STEER_REDUCER_V2=1 swift test` green (same tests, new path).
- iOS XCUITest fixture-mode smoke (the existing `--uitest` flag).

**Revert breaks:** without `STEER_REDUCER_V2=1`, behaviour identical.
With it, the new path is exercised — if the new path has a bug not
covered by tests, dogfood catches it before launch. Reverting strips
the new `apply` function.

**Dogfood signal:** user-visible:
- Cold start with phone backgrounded for 1 hour, then open the app:
  the carousel must populate within 5 s with whatever the relay's
  authoritative card set says. Same as today on the happy path.
- User taps reply on Mac while iPhone is open: chip transitions
  awaitingUser → awaitingResponse → awaitingUser in one frame each.
  Same as today.
- The audit's R-7c scenario: reply from iPhone, lock phone for 11
  min, unlock. Card must be promoted (this is what R-7c+R-8 fixed;
  the new reducer must preserve).

**Independent:** depends on PR-2.

### PR-4: Mac funnel + setMacState

**Goal:** extract `MacSyncFunnel.computeState` from `SteerRootView.reload`.
No behaviour change. Pure refactor with new tests at the funnel
boundary.

**Files touched:**
- new: `apps/mac/Sources/SteerMac/MacSyncFunnel.swift` (~120 lines)
- `apps/mac/Sources/SteerMac/SteerRootView.swift` (shrink `reload`
  to ~25 lines; helper methods now read from funnel output)
- new: `apps/mac/Tests/MacSyncFunnelTests.swift` (if there's a test
  target for the Mac app; otherwise add the tests under
  `packages/SteerCore/Tests/...` against a Mac-shaped fixture)

**Tests:**
- `test_funnel_coldStart_seedFromRelay`
- `test_funnel_steadyState_noPublishWhenIdle`
- `test_funnel_publishesOnChangedFingerprint`
- `test_funnel_resolvesDisappearedCardId`
- `test_funnel_signOut_clearsBaseline`

**Gates:**
- `swift build --package-path apps/mac` clean.
- `scripts/build-mac-app.sh` succeeds (the dogfood `.app` builds).
- `scripts/verify-steer-regression.sh` green.

**Revert breaks:** the view goes back to the inlined version. The
existing tests still pass.

**Dogfood signal:**
- Mac cold-start with iPhone signed in: relay-orphan cleanup runs
  within 2 s of launch, iPhone stops seeing yesterday's card.
- 2 s reload tick continues to NOT spam the relay (current
  fingerprint-dedupe behaviour preserved).

**Independent:** depends on PR-2 (uses `eventSeq` for its own
ordering decisions; reusing the primitive).

### PR-5: `lastPublishedCardIds` persistence

**Goal:** write the publish state to
`~/.steer/sync-publish-state.json` on every successful effect run.
Read on launch.

**Files touched:**
- `apps/mac/Sources/SteerMac/MacSyncFunnel.swift` (or a sibling
  `PublishStatePersistence.swift`)
- `apps/mac/Tests/PublishStatePersistenceTests.swift`

**Tests:**
- `test_persistence_writeRead_roundtrip`
- `test_persistence_userIdMismatch_treatedAsAbsent`
- `test_persistence_corruptFile_treatedAsAbsent`
- `test_persistence_atomicWriteSurvivesCrashSimulation`
  (simulate by truncating the file mid-write, assert old contents
  preserved)

**Gates:**
- All previous PR tests green.
- `swift build --package-path apps/mac` clean.
- Manual dogfood: kill `Steer.app` mid-publish (`pkill -9 SteerMac`),
  relaunch, observe the publish state is consistent on the next
  reload.

**Revert breaks:** behaviour reverts to in-memory baseline; the
file on disk gets stale but never read. Cleanup is a one-liner
(`rm ~/.steer/sync-publish-state.json`).

**Dogfood signal:**
- Kill Mac process while iPhone is showing 3 cards. Relaunch.
- iPhone still shows 3 cards (no flicker, no DELETE-then-PUT).
- Resolve a card on Mac. iPhone drops the resolved card normally.

**Independent:** depends on PR-4 (uses the funnel hook).

### PR-6: Frame watchdog + `.awaitingResponse` decay

**Goal:** add the WS health watchdog (§6) on both clients, and the
10-min `.awaitingResponse` timeout (§5) on iOS.

**Files touched:**
- `apps/ios/SteerIOS/SyncInbox.swift` (add `watchdogTask`,
  `lastFrameReceivedAt`, `checkAwaitingResponseTimeouts`)
- `apps/mac/Sources/SteerMac/SyncClient.swift` (add `watchdogTask`,
  `lastFrameReceivedAt`)
- `packages/SteerCore/Sources/SteerCore/SessionEntryStore.swift`
  (`.awaitingResponseTimeout` event)

**Tests:**
- `test_apply_awaitingResponseTimeout_failsEntry`
- `test_apply_awaitingResponseTimeout_thenLateResponse_promotes`
- `test_apply_awaitingResponseTimeout_ignoredOnFreshEntry`
- New non-reducer test: `test_watchdog_firesAfter60sSilence`
  (uses a `URLProtocol` stub that accepts a WebSocket and then
  goes silent — the test asserts `webSocketTask?.cancel` is called
  within 70 s of last frame).

**Gates:**
- All previous PR tests green.
- `STEER_INTEGRATION=1 npm test` green.
- iOS XCUITest fixture flow still green.

**Revert breaks:** the watchdog stops firing; `.awaitingResponse`
goes back to no-timeout. iOS regression risk is *exactly* the audit's
R-5 ("stuck N running") returning.

**Dogfood signal:**
- iPhone reply, then immediately power off Wi-Fi and cellular.
- Wait 11 minutes.
- Re-enable network. Open Steer.
- Expected: chip showed "1 failed" by the time you unlock (timeout
  fired); banner says "response timeout — your reply may not have
  been delivered, retry?"
- Tap retry. Reply re-sends. Once Mac comes back online and
  publishes the response, banner clears, carousel shows the response.

**Independent:** depends on PR-3 (uses the reducer's `.awaitingResponseTimeout`
event).

### Optional PR-7: Delete legacy reducer code paths

**Goal:** after PR-3 has shipped to dogfood for 7+ days without
regressions, remove the legacy `applyBootstrap`/`onCardUpsert`/etc
functions and the `STEER_REDUCER_V2` feature flag.

**Files touched:**
- `packages/SteerCore/Sources/SteerCore/SessionEntryStore.swift`
  (delete legacy functions)
- `apps/ios/SteerIOS/SyncInbox.swift` (delete branch points)
- `apps/ios/SteerIOS/FeatureFlags.swift` (delete reducerV2 flag)

**Gates:** all PR-1 through PR-6 tests green.

**Revert breaks:** if a previously-undetected bug shows up in the
new reducer, we can no longer fall back. Reverting is a non-trivial
re-introduction of ~200 lines.

**Dogfood signal:** none new; the new path has been hot for 7+
days.

**Independent:** depends on PR-3, and a soak window.

### Sequencing graph

```
PR-1 (tests)
  │
  ↓
PR-2 (eventSeq primitive)
  │           ↘
  ↓            ↘
PR-3 (reducer  PR-4 (Mac funnel)
  iOS,           │
  flagged)       ↓
  │            PR-5 (persistence)
  ↓              │
PR-6 (watchdog + decay)
  │  (depends on PR-3)
  ↓
PR-7 (delete legacy)
  (after dogfood soak)
```

PRs 3 and 4 can ship in parallel after PR-2 (different platforms).
PR-5 needs PR-4. PR-6 needs PR-3. PR-7 is gated by time.

Total wall-clock: PR-1 + PR-2 same day (mechanical). PR-3 + PR-4
two days each, in parallel. PR-5 one day. PR-6 two days. PR-7 a
week after PR-3 lands. Worst-case 12 days from start to delete-the-
legacy, but the user-visible improvements all land by day 5
(PR-3 ships the reducer; PR-6 ships the watchdog + timeout).

---

## §8. Invariants the design must preserve

Cross-component contracts and behaviours that MUST survive. Each
has a regression test (existing or proposed) that locks it.

### 8.1 `card_id == "card-${sessionId}"` for agent-generated cards

Referenced in 12+ places:
- `packages/agent/src/store.js:410` (the literal)
- `packages/relay/src/store.ts:88-94` (becameActive rationale)
- `packages/relay/src/index.ts:232-237` (PUT route comment)
- `apps/mac/Sources/SteerMac/SteerCardMapping.swift:11` (cardId =
  card.id)
- `apps/ios/SteerIOS/SyncInbox.swift:680-684` (lookup by cardId)
- `packages/SteerCore/Sources/SteerCore/SessionEntryStore.swift:182`
  (firstIndex(where: sessionId match))
- `docs/REGRESSION_CONTRACT.md` (proposed addition per audit §5b)

The reducer is *agnostic* to the literal — it never hard-codes
`card-${sessionId}`. But callers (Mac publish, iOS reply target)
assume one card per session. Test:
`packages/relay/test/store_upsert_dedupe.test.ts` already exists
(664518c). Lock in `REGRESSION_CONTRACT.md`.

### 8.2 One active card per session

Enforced agent-side in `packages/agent/src/store.js:upsertActionCard`
(uses `card-${sessionId}` as the primary key, so a second active
card on the same session overwrites the first). The reducer
preserves this by indexing entries by `sessionId` (single firstIndex
lookup per upsert).

Test: `packages/agent/test/classifier.test.js` (already pinned in
REGRESSION_CONTRACT.md).

### 8.3 `responseRevision` monotonic per session

Enforced agent-side at `packages/agent/src/store.js:bumpResponseRevisionIfReady`
(L82-94): single UPDATE statement increments and clears the
`awaiting_response_since` marker atomically; a concurrent second
caller finds the marker null and is a no-op.

Test: `packages/agent/test/instruction_response_revision.test.js`
(if not already present, add). The reducer relies on this with the
strict-greater comparison in §1.6.

### 8.4 Single SQLite writer (Mac agent only)

`packages/agent/src/agent.js` uses `proper-lockfile` (per fefc3bc)
to enforce singleton. Mac app reads via `sqlite3 -json` shell-out
in `LocalSteerStore.swift`. The new publish-state file
(`~/.steer/sync-publish-state.json`) is NOT in the SQLite DB and
does NOT touch the writer.

Test: `packages/agent/test/lockfile.test.js` (existing).

### 8.5 WS payload contract

`packages/SteerCore/Sources/SteerCore/SyncProtocol.swift` is the
single Codable definition. The reducer uses only the fields
`cardId`, `sessionId`, `updatedAt`, `responseRevision`. Adding new
fields to `CardPayload` is safe (Codable tolerant); removing
existing ones breaks both clients.

Test: `WSMessage` round-trip in `SyncProtocolTests` (add one if
absent — `test_wsMessage_cardUpsert_roundTrip`).

### 8.6 `becameActive` APNS gate

`packages/relay/src/store.ts:upsertCard` returns `becameActive`,
which `packages/relay/src/index.ts:247-249` reads to decide APNS
fanout. The Mac's 2 s reload republish is state-stable (active →
active) so it never trips becameActive. The reducer doesn't touch
relay-side logic — preserved by not changing relay code.

Test: `packages/relay/test/store_upsert_dedupe.test.ts` (664518c).

### 8.7 Mac re-publishes idempotently

`CardReconciler.reconcile` returns `(publishIds, resolveIds,
nextPublishedIds)` based on a fingerprint diff. The new
publish-state file persists `fingerprint` per id; the next launch's
diff against fresh SQLite is identical to the in-memory steady
state.

Test: `CardReconcilerTests` (existing) + new
`test_persistence_loadedBaseline_matchesInMemorySteadyState`.

### 8.8 Wire format for `pendingReplies` projection

iOS surfaces `pendingReplies` from `setSessions` (SyncInbox L645-648).
Several UI sites depend on its shape (`MacSyncStatusView`,
`InboxView.failedRepliesCount`). The new reducer must keep
`pendingReplies` non-nil and computed identically (same filter,
same compactMap signature). Locked by test:
`test_pendingReplies_projection_unchangedAcrossReducerVersions`.

---

## §9. What this doc does NOT cover

Open questions deferred to execution time.

### 9.1 iPad multi-window state

The iOS app has not been audited for iPad's multi-window /
state-restoration model. If a user has two windows open and one
goes background while the other stays foreground, scenePhase fires
on the backgrounded window only — but both windows share the
`SyncInbox.shared` singleton. The watchdog's "force reconnect on
foreground" trigger may double-fire.

Defer: PR-6's testing only covers iPhone single-window.

### 9.2 Apple Sign In re-auth race

If the JWT expires between `connectWebSocket` and the first frame,
the relay closes the socket. Today's reconnect loop handles this
(`refreshMe` reissues, then `connectWebSocket` runs). The reducer
is unaffected — it sees an idle period, the watchdog fires at 60 s,
backoff kicks in.

Defer: covered by existing tests.

### 9.3 iOS background → foreground APNS deep-link race

If APNS payload sets `pendingFocusSessionId` BEFORE the bootstrap
GET lands, `InboxView.swift:188-197` retries when `inbox.$cards`
publishes. The reducer flow preserves this (`@Published cards`
updates whenever `setSessions` runs, which the new `applyEvent`
calls on every state change). New 30 s timeout for
`pendingFocusSessionId` (§5.5) bounds the failure case.

Defer: golden-set check 7 from audit §6.

### 9.4 v3 event log adoption

`docs/SYNC_ARCHITECTURE_V3.md` describes the relay's eventual
event-log model. This design intentionally does not couple to it.
When v3's `POST /v1/sync/events` is consumer-ready, the iOS reducer
can reduce *over events* directly (each event has a server-assigned
monotonic id, which obsoletes the client-side eventSeq for cross-
device ordering).

Defer: §1.2's `Event` enum is shaped to allow a future migration
to server events without a second reducer rewrite.

### 9.5 The Mac WS handler's "I should do something with `card.upsert`"

`SyncClient.handleWSText` (L597-610) currently only posts a
NotificationCenter event. With the agent owning the SQLite DB,
Mac doesn't *consume* its own broadcast — the reload loop sees the
change in SQLite. But: if a future feature lets the iPhone
publish a card (audit F-7), the Mac would need a real handler.

Defer: out of scope until F-7 is on the roadmap.

### 9.6 Wrapper-side instruction acknowledgement

When `steer send` injects an instruction, the agent's `ack` handler
calls `resolveActionCardsForSession` only on `injected` (not
`failed`). The reducer doesn't see acks — iOS only sees
`POST /v1/sync/instructions` HTTP status. A wrapper-side failure
manifests as a card that doesn't resolve; the user is forced into
the 10-min timeout path.

Defer: an iOS-visible "your reply failed at the Mac wrapper" signal
would require the relay to forward `instruction.status` events to
iOS (today they stay server-side). Separate PR.

### 9.7 Test-clock injection across the whole app

The reducer takes `now: Date` injected. The host (`SyncInbox`,
`SteerRootView`) reads `Date()` at call sites. A full
test-clock abstraction would need a `Clock` protocol threaded
through every layer. Deferred — for now, the reducer is testable
because it's pure; the host's timer wakes are robust against
inaccuracy (30 s tolerance on `.awaitingResponseTimeout` detection).

### 9.8 Wire-shape evolution: `eventSeq` on the server

§2.B uses a client-only `snapshotStartedAtSeq` to dedupe stale
GETs against fresh user writes. A future server-side event id
(per §9.4) would obsolete this. Until then, the client-only
solution is sufficient.

---

## Appendix A — concrete tie-breaker examples

A walkthrough of three audit-cited races against the new design,
proving the rules in §2 actually work.

### A.1 The R-7c → R-8 oscillation

**R-7c (b6fe8fe):** `applyBootstrap` drops `.awaitingResponse`
entries whose sessions aren't in the GET. **Broke:** cold-launch
from APNS where the GET returns the *response card* (different
session-card relationship), entry was dropped before promotion.
**R-8 (069cb4e):** apply bootstrap promotes `.awaitingResponse` to
`.awaitingUser` when the GET returns a fresh card for that session.

Under the new design, this becomes one rule:

> `.snapshot` for session-S where `previous` has entry-S in
> `.awaitingResponse(stampedAt:)`:
> - server's card for session-S has `responseRevision > entry.instructedRevision`
>   → promote to `.awaitingUser` (this is what R-8 needed)
> - server has no card for session-S AND `entry.lastReplyEventSeq
>   <= snapshotStartedAtSeq` → drop (this is what R-7c needed)
> - server has no card for session-S AND `entry.lastReplyEventSeq
>   > snapshotStartedAtSeq` → keep (race protection — user replied
>   *after* the GET fired, server hasn't caught up yet)

Test: `test_snapshot_drops_or_promotes_or_keeps_per_revision_and_seq`
exercises all three branches.

### A.2 The R-4 → R-5 oscillation

**R-4 (86f87a3):** `onCardResolved` held `.awaitingResponse` entries
through the resolve → upsert gap, on theory of "next upsert is
coming." **R-5 (79a2f24):** R-4 was unbounded; entries stuck
forever when no upsert came. Reverted to drop on resolve.

Under the new design:
- `.resolved` drops the entry unconditionally (matches R-5).
- `.awaitingResponseTimeout` after 10 min provides the upper bound
  R-4 was trying to give us. The flicker between `.resolved` and
  the next `.upsert` is unchanged (one frame); the unbounded stick
  is fixed by the timeout *in the case where no upsert ever comes*.

Test: `test_resolved_dropsAwaitingResponse` + `test_timeout_decaysStaleAwaitingResponse`.

### A.3 The R-6 → R-7a oscillation

**R-6 (0e062c8):** iOS `pingLoop` force-cancels WS on send error
so receive loop unblocks. **R-7a (b6fe8fe):** Mac had the same
bug; same fix. Both client-only.

Under the new design, both fixes stay, AND the watchdog (§6)
covers the case where `send` succeeds but the socket is silently
half-closed downstream. Test: `test_watchdog_firesAfter60sSilence`
exercises the path R-6/R-7a couldn't (silent half-close where
`send` doesn't error).

---

## Appendix B — Files this design will touch

For change-tracking. Each PR sees a subset.

```
packages/SteerCore/Sources/SteerCore/
  SessionEntryStore.swift           PR-2, PR-3, PR-6
  SyncProtocol.swift                PR-3 (no breaking changes)
  (new) MacSyncEffects.swift        PR-4 (optional shared types)

packages/SteerCore/Tests/SteerCoreTests/
  SessionEntryStoreTests.swift              PR-1 (extend)
  (new) SessionEntryRaceMatrixTests.swift   PR-1
  (new) EventSeqTests.swift                 PR-2
  CardReconcilerTests.swift                 PR-4 (no change), PR-5 (extend)

apps/ios/SteerIOS/
  SyncInbox.swift                   PR-2, PR-3, PR-6
  (new) FeatureFlags.swift          PR-3
  InboxView.swift                   PR-6 (banner UI for timeout)

apps/mac/Sources/SteerMac/
  SteerRootView.swift               PR-4 (shrink reload)
  (new) MacSyncFunnel.swift         PR-4
  (new) PublishStatePersistence.swift PR-5
  SyncClient.swift                  PR-6 (watchdog)
  LocalSteerStore.swift             unchanged
  SteerCardMapping.swift            unchanged

apps/mac/Tests/  (if test target exists, else under SteerCore tests)
  (new) MacSyncFunnelTests.swift    PR-4
  (new) PublishStatePersistenceTests.swift PR-5

packages/agent/                      UNCHANGED
packages/cli/                        UNCHANGED
packages/relay/                      UNCHANGED
```

Zero changes to relay, agent, CLI, or wrapper layers. The fix
lives entirely in the two client apps and SteerCore. That's the
correct scope — the audit's root cause was client-side state
machine drift, not server-side semantics.
