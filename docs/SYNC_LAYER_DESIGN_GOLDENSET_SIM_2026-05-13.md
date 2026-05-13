# Sync Layer Design — Golden-Set Simulation (2026-05-13)

Companion to:
- `docs/SYNC_LAYER_AUDIT_2026-05-13.md` — what broke
- `docs/SYNC_LAYER_DESIGN_2026-05-13.md` — the proposed redesign

Purpose. The audit prescribes five rules; the design pins them down as
six PRs (single reducer, eventSeq primitive, race matrix tiebreakers,
Mac funnel, JSON sidecar, frame watchdog + 10-min decay). Nobody walked
the golden set through that design on paper. This file is that walk —
twelve scenarios from `docs/LAUNCH_CHECKLIST.md` Phase 1 + Phase 9 +
`docs/REGRESSION_CONTRACT.md`, each traced event-by-event through the
design doc's reducer + tiebreakers + funnels, with verdicts.

Method. For each scenario: list the events with relative timestamps,
apply the reducer rule that the design says applies, name the §X of
the design doc the rule comes from, end with the user-visible state
and a PASS / PASS-WITH-RISK / FAIL verdict. If a scenario hits a race
the design doc's §2.A-2.H matrix doesn't enumerate, that's flagged
explicitly as a coverage gap.

Conventions in the walk-throughs:
- `T0`, `T1`, ... are real-clock instants. `seq=N` is the client-local
  `eventSeq` value (§1.2 design doc); per §9.4/§9.8 it is per-process
  per-device, NOT global.
- `RR` = `responseRevision` (per §1.6/§2.G).
- "iOS reducer" = `SessionEntryStore.apply` (§1.2). "Mac funnel" =
  `MacSyncFunnel.computeState` (§3.2).
- "Trusted card source" rules from `docs/CLASSIFIER_CONTRACT.md` still
  apply on the Mac side; the design changes only the sync layer
  downstream of card production.

---

## S-1. Fresh install → Sign in with Apple → first card from Mac codex stops

**User-visible expectation.** Within ~5 s of the AI emitting its first
trusted stop (`report` / Codex `turn/completed`), the iPhone shows: one
card in the carousel, chip = "0 running", an APNS banner, badge = 1.

**Inputs.**
1. T0 — App launch, signed-out. Reducer state = `[]`. `eventSeq = 0`.
2. T1 — User completes Sign in with Apple. JWT issued, `connectWebSocket()` fires,
   `lastFrameReceivedAt = Date()` (§6.3 — set at connect entry).
3. T2 — Mac codex session stops; classifier upserts row in
   `~/.steer/steer.sqlite`. `bumpResponseRevisionIfReady` sets
   `last_response_revision = 1` (§1.6 design citation, §8.3 invariant);
   `refreshActionCard` then publishes the card with `responseRevision=1`,
   `updatedAt=T2_ms` (agent `store.js:refreshActionCard` L388 → L409).
4. T2+~2s — Mac's 2 s funnel tick picks up the new SQLite row,
   `MacSyncFunnel.computeState` (§3.2) returns `effects.publishCards = [card]`,
   `runEffects` does HTTP PUT `/v1/sync/cards/card-${sessionId}`.
   Relay's `upsertCard` returns `becameActive=true` (state was absent →
   active, §8.6), broadcasts `card.upsert`, fans out APNS with
   `badge:1` (R-9 fix, audit §2). Relay also writes the durable card row.
5. T2+~2.2s — Two things race to the iPhone:
   - WS `card.upsert` arriving on the open socket, AND
   - APNS payload going to lock screen / banner / badge.
   - (Plus the iPhone's own `reload()` will run on next foreground
     trigger; not relevant here since the app is foregrounded.)

**Walk-through.**
- T1: `SyncInbox.refreshMe` → `connectWebSocket()` → `receiveLoop` blocks
  on `task.receive()`. PR-6's `lastFrameReceivedAt = Date()` sets at
  connect entry (§6.3). `watchdogTask` armed.
- T1+RTT: relay sends initial `ping` frame on accept (per
  `userHub.ts` L57, cited at §6.3). `receiveLoop` stamps
  `lastFrameReceivedAt = T1+RTT`. `reconnectAttempt = 0`.
- T1+ε: `refreshMe` also calls `await reload()` (current
  SyncInbox.swift:474). With PR-3 wired,
  `reload()` captures `snapshotStartedAtSeq = nextEventSeq()` (§2.B),
  fires GET `/v1/sync/cards` — relay returns no cards yet because
  Mac hasn't published. `applyEvent(.snapshot(cards: [], snapshotStartedAtSeq: seq=1))`.
  Reducer expands per §1.5: `previous = []`, so no entries to drop,
  no entries to insert. State stays `[]`. `loadPhase = .ready`.
- T2+~2.2s — WS frame lands. `receiveLoop` stamps
  `lastFrameReceivedAt`. iOS reducer sees
  `.upsert(card with RR=1, updatedAt=T2_ms)`. §1.4 idempotency table:
  no entry for sessionId yet → §1.5 step 3 "insert as `.awaitingUser`"
  applies (the upsert path treats new sessionId the same way).
  `eventSeq=2`. State = `[ SessionEntry(stage: .awaitingUser, card: ..., lastReplyEventSeq: nil) ]`.
  `setSessions` runs (§1.1 funnel for iOS), `cards` projection picks
  up the new card. Carousel populates.
- APNS arrives in parallel; iOS shows banner + badge. `setBadgeCount(0)`
  fires when app becomes active in foreground (but app is already foreground
  here, so badge = 1 stays briefly). Note: the design doc doesn't change
  R-9 behavior, OK.

**Final state.** Carousel: 1 card. Chip: "0 running"
(`activeSessionIds.isEmpty` because stage is `.awaitingUser`).
APNS banner: shown. Badge: 1 (cleared on foreground per R-9; if user
is already foreground, the design preserves R-9's
`setBadgeCount(0)` call in `InboxView.scenePhase`).

**Verdict.** **PASS.** Race matrix doesn't actually fire — there's
nothing in `previous` to fight with. §1.5 step 3 is uncontested.

**Race-matrix coverage.** None of §2.A-2.H needed; trivial path.

---

## S-2. User replies on iPhone, app foreground, WS healthy

**User-visible expectation.** Tap Send → chip animates to "1 running"
≤200 ms. Card disappears from carousel (one card → empty carousel).
Within ≤10 s of Mac receiving the instruction, response card lands;
chip drops to "0 running", carousel shows new card.

**Inputs.**
1. T0 — State = `[entry-S(stage: .awaitingUser, card RR=1, updatedAt=T_old)]`.
   `eventSeq` counter at some value, say 10.
2. T1 — User taps Send. `SyncInbox.sendReply(cardId: ..., text: "...")`
   fires. Design says: §1.2 `.userReplied(cardId, text, instructionId)`
   event. Reducer stamps `lastReplyEventSeq = eventSeq=11`, stage →
   `.awaitingResponse(stampedAt: T1)`. Host kicks off
   POST `/v1/sync/instructions` and starts the timeout watcher (§5.1).
3. T1+RTT — POST 200. Relay queues the instruction; agent's drain loop
   picks it up via Mac's `drainQueuedInstructions` tick (every 2 s).
4. T2 — Agent receives instruction; writes to wrapper stdin; codex starts
   processing. `markSessionAwaitingResponse` stamps
   `awaiting_response_since` (audit §1a).
5. T2+~5s — codex emits trusted stop; agent's
   `bumpResponseRevisionIfReady` increments to RR=2 atomically AND
   clears `awaiting_response_since` (§8.3). `refreshActionCard`
   upserts SQLite with RR=2, updatedAt=T2+5_ms.
6. T2+~7s — Mac funnel tick publishes; relay broadcasts `card.upsert`
   with RR=2 over WS.

**Walk-through.**
- T1: `.userReplied` (§1.2). Reducer: §1.4 idempotency row "userReplied"
  → stamp `lastReplyEventSeq=11`, stage = `.awaitingResponse(T1)`.
  `setSessions` re-runs; `cards` projection drops entry-S (filter is
  `.awaitingUser` only); `pendingReplies` gains the entry. UI: carousel
  empties, chip → 1. Within one SwiftUI tick.
- T1..T2: 2 s funnel tick on Mac eventually drains the instruction (the
  funnel's `effects.drainDue` per §3.2). Wrapper writes the keystroke.
  Codex starts working. No state change on iPhone.
- T2+~5s: agent flips RR=1 → RR=2. Note RR is monotonic per §8.3 and
  the bump happens *before* the card upsert (§8.3 again).
- T2+~7s: Mac publishes. Relay broadcasts. WS frame lands on iPhone;
  `lastFrameReceivedAt` stamps fresh (watchdog won't fire).
  Reducer: `.upsert(card with RR=2, updatedAt=T2+5_ms)`. Lookup by
  sessionId finds entry-S, stage = `.awaitingResponse`. §2.C rule:
  `incoming.RR=2 > existing.instructedRevision=1` → promote to
  `.awaitingUser` (§1.6 rule 1). New entry: `stage=.awaitingUser, card=RR=2`.
  `setSessions` runs: cards gains the new card, pendingReplies clears.
  Chip → 0 in the same frame.

**Final state.** Carousel: 1 card (the response). Chip: 0. Reply text
no longer relevant (entry returned to `.awaitingUser`; `lastReplyText`
left in place defensively but not surfaced because filter is on
`.awaitingResponse`/`.failed` per §1.1's projections).

**Verdict.** **PASS.** Clean traversal through §2.C → §1.6 rule 1.
Timeout watcher (§5.1) is armed at T1 but the response arrives well
before the 10-min decay. Watchdog (§6) gets stamped on every WS frame
incl. ping; never fires.

**Race-matrix coverage.** §2.C exactly. §2.A doesn't fire because the
pre-reply card from §2.C "re-publish during typing" doesn't happen here
(no 2 s tick between T1 and the response publish — Mac's funnel
drained the instruction before its next reload tick).

---

## S-3. User replies on iPhone, app backgrounded — Mac publishes response while WS is dead → APNS tap → cold launch

**This is the audit's R-7c/R-8 oscillation scenario.** The most
expensive bug of the audit window. The design's §1.6 rule 1 +
§A.1 explicitly target this. Walk it.

**User-visible expectation.** User opens app from APNS banner →
within 5 s the response card is visible, chip = "0 running", no
flash of stuck "1 running" state.

**Inputs.**
1. T0 — Foreground state: `[entry-S(stage: .awaitingUser, card RR=1)]`.
   Send tapped at T0. State immediately:
   `[entry-S(stage: .awaitingResponse(T0), instructedRevision=1, lastReplyEventSeq=seq=10)]`.
   POST `/v1/sync/instructions` 200.
2. T0+ε — User backgrounds the app. iOS scenePhase = .background.
   `pingLoop` keeps trying at 20 s cadence; for ~30-60 s iOS lets
   the WS keep frames flowing, then suspends. Cloudflare DO closes
   the socket somewhere between 5 and 10 min idle.
3. T0+~7s — agent injects instruction, codex emits response, agent
   bumps RR=1 → RR=2, refreshes card, Mac funnel publishes.
   Relay accepts PUT, `becameActive=true` because... wait — actually
   no. The card was already `active` (the original card was up). Per
   §8.6 / audit R-10, this is the "every subsequent stop on the same
   session is an UPDATE, not an INSERT" path. Relay returns
   `becameActive = inserted || previousState !== "active"` → previous
   was active → false. **APNS does NOT fire on this transition.**

   Wait — re-check. The user *replied*, which means at some prior
   moment the Mac did `DELETE /v1/sync/cards/card-${sessionId}` on
   the iOS reply path? Let's trace. Looking at the audit §1b:
   the Mac's reply path is iPhone POST instruction → relay queue →
   Mac drain → wrapper write. The card itself: when iPhone reply
   leaves, does the Mac DELETE the card?

   Per `apps/agent/src/agent.js` `routeInstruction` path: the agent's
   `resolveActionCardsForSession` is called from `case "ack"` on
   `injected` (audit §1a L75-89). That writes `state = "done"` on the
   local SQLite row, which the Mac funnel sees on the next 2 s tick
   and translates to `resolveCardIds: [...]`. So at T0+~2s, Mac DELETEs
   the relay card. State on relay: "done". Then at T0+~7s, the agent's
   `refreshActionCard` inserts the new card (fresh INSERT — agent re-
   uses `card-${sessionId}` per §8.1, but the relay's `upsertCard` sees
   previousState != "active" → `becameActive=true`. **APNS fires with
   badge=1.**

   OK good — R-10 fix (664518c, cited in §8.6) covers this. Bad
   reading on my part. Continuing:

4. T0+~7.2s — APNS lands on iPhone lock screen with banner + badge.
   WS upsert may or may not arrive, depending on whether iOS has
   suspended the WS yet. Worst case: WS is dead, broadcast missed.

5. T0+~15s — User taps the banner. iOS wakes the app.
   `scenePhase = .active`. `InboxView.scenePhase` observer fires:
   `inbox.reconnectWebSocketIfNeeded()` + `setBadgeCount(0)` +
   `await inbox.reload()` + APNS deep link sets `pendingFocusSessionId`.

**Walk-through.**
- T0+~15s — `reconnectWebSocketIfNeeded()` opens a new WS.
  `lastFrameReceivedAt = T+15s` (§6.3). `connectWebSocket` returns,
  `reload()` begins.
- T+15s — `reload()`: `snapshotStartedAtSeq = nextEventSeq()` = some
  value, say seq=20 (§2.B). GET `/v1/sync/cards` fires. Relay returns
  `[card with RR=2, updatedAt=T0+5s_ms]` (the response card, because
  that's what the agent last published).
- T+15.2s — GET returns. `applyEvent(.snapshot(cards: [card RR=2], snapshotStartedAtSeq: 20))`.
  Reducer expansion (§1.5):
  - Index `cards` by sessionId: `{sessionId: card-RR=2}`.
  - For `entry-S` in `previous`: session IS in `cards`. Apply upsert
    rules per §1.5 step 2.
    Existing entry stage: `.awaitingResponse(T0)`, instructedRevision=1.
    Per §1.6 rule 1: `card.responseRevision = 2 > instructedRevision = 1`
    → promote to `.awaitingUser`. New entry: `stage=.awaitingUser, card=RR=2`.
  - No new sessions to insert.
- T+15.2s — `setSessions` runs. `cards` projection picks up the new card.
  `pendingReplies` clears. Chip → 0 in same frame as carousel populates.
- T+15.2s — APNS deep link's `pendingFocusSessionId` was set by the
  banner-tap path; `InboxView` `onReceive(inbox.$cards)` (audit §1c
  L188-197) detects the card now exists and honors the focus.
  `clearPendingFocus()` runs.
- Watchdog: stamped at every received frame; the initial connect's
  ping arrives within ~RTT (§6.3); never fires.

**Final state.** Carousel: 1 card (response). Chip: 0. Focus: scrolled
to the new card. Badge: cleared. No flash of "1 running" — the
`.awaitingResponse` entry was rewritten in the same `setSessions` call
that populated `cards`. SwiftUI renders the post-state in one frame.

**Verdict.** **PASS.** This is exactly the R-7c → R-8 path the design's
§A.1 promises to handle. §1.6 rule 1 is the load-bearing rule.

**Race-matrix coverage.** §2.B applies marginally — the snapshot
`cards` set INCLUDES the card, so the "snapshot has no card for this
session" branch (the source of the §2.B rule) doesn't activate.

**Risk note.** The design's §1.6 rule 1 promotes ANY card with
`RR > instructedRevision`. This is correct when the snapshot's card is
the *response* card. But what if the agent has gone through 2 reply
cycles offline (RR=1 → RR=2 → RR=3) and the GET returns RR=3 — does
the reducer correctly promote past the missed intermediate? Yes,
trivially, because `3 > 1`. Good.

---

## S-4. User replies; wrapper dies before response can be produced

**User-visible expectation.** After 10 min wall clock, the
`.awaitingResponse` entry decays to `.failed("response timeout")`. Chip
drops to 0; a retry banner / failed-row appears; user can retry. Chip
is NOT stuck forever.

**Inputs.**
1. T0 — `[entry-S(.awaitingResponse(T0), instructedRevision=1, lastReplyEventSeq=10)]`.
2. T0+~3s — agent gets instruction. Writes to wrapper. Wrapper's PTY
   gets the keystroke but the codex child process panics / crashes /
   loses network — codex never emits a trusted stop. Agent never bumps
   RR. The Mac's local SQLite stays at RR=1.
3. T0+~5s — Mac funnel sees the card is still `active` in SQLite
   (the agent never resolved it — wait, did it?). Per audit §1a L75-89,
   `resolveActionCardsForSession` runs on ack `injected` from the
   wrapper. If the wrapper *successfully wrote the keystroke* but the
   child died after, ack was `injected`, so the card is resolved
   server-side. Then no new card lands. iPhone gets `card.resolved`
   over WS.

   Per design §1.4 idempotency table row `.resolved`: drops the entry.
   But wait — the entry is `.awaitingResponse`. R-5's lesson (audit
   §2 R-5) was: drop `.awaitingResponse` on resolve regardless of stage.
   Does the new design preserve that?

   Per §1.4 row `.resolved`: "Drops the entry. Second resolve finds no
   matching entry; no-op." So yes — drops unconditionally. Per audit
   §A.2 the new design preserves R-5's behaviour.

   That means: at T0+~5s, the entry is dropped. Chip drops to 0. Empty
   carousel. No card to retry against.

   **THIS IS A REGRESSION FROM THE USER PERSPECTIVE.** The audit's F-5
   prescribed: "Hard timeout. If an entry has been `.awaitingResponse`
   for > 10 minutes with no upsert, force-decay to `.failed(\"response
   timeout — your reply may not have been delivered\")`. That gives the
   user an actionable cue AND guarantees no entry is stuck forever."

   The design's §5.3 honors this — but only if the entry survives 10
   minutes. If `.resolved` arrives at T0+~5s, the entry is dropped *before*
   the timeout can fire, and the user sees nothing actionable.

   Let me re-examine. Looking at the actual wrapper behaviour: when
   the wrapper crashes mid-turn, does `steer codex` ack as `injected` or
   `failed`? Per audit §1a:
   > `case "ack"` (L75-89) calls `resolveActionCardsForSession` only on
   > `injected`, not on `failed`.

   So if the wrapper-PTY write throws (because the child died and the
   PTY went EOF), ack is `failed`, the card is NOT resolved, no
   `card.resolved` broadcast goes out. The entry stays
   `.awaitingResponse` for the full 10 min, then the design's §5.1
   timeout watcher fires `.awaitingResponseTimeout(sessionId)`. Reducer
   transitions to `.failed("response timeout — your reply may not have
   been delivered")`. User sees the failed banner.

   If the wrapper-PTY write succeeds but the child dies in the middle
   of producing output, ack is `injected`, the card IS resolved, and
   the entry is dropped at T0+~5s. The user sees an empty inbox with
   chip = 0 and no actionable retry. The reply silently vanishes.

**Walk-through (Case A — PTY write fails, ack=failed).**
- T0..T0+10m: entry stays `.awaitingResponse(T0)`. Watcher checks
  every 30 s (§5.1). No event arrives — no `.upsert`, no `.resolved`.
- T0+10m: watcher computes `Date().timeIntervalSince(T0) > 600`. Fires
  `.awaitingResponseTimeout(sessionId)` (§5.1). Reducer §1.4 row
  `.awaitingResponseTimeout`: "Reducer only acts when the entry exists,
  stage is `.awaitingResponse`, and the stamp is older than 10 min
  before `now`. Late delivery (entry already transitioned out) is a
  no-op." All three conditions met. Transition to
  `.failed("response timeout")` per §5.3.
- `setSessions` runs. `pendingReplies` projection now contains a
  `.failed` row. UI surfaces retry banner.

**Walk-through (Case B — PTY write succeeds, child dies mid-output, ack=injected).**
- T0..T0+~5s: entry stays `.awaitingResponse(T0)`.
- T0+~5s — agent's ack handler calls `resolveActionCardsForSession`
  (audit §1a). Mac funnel sees `state = done` on next 2 s tick,
  emits `resolveCardIds = [card-${sessionId}]`. Relay deletes the
  card, broadcasts `card.resolved`.
- T0+~5.2s — iPhone WS receives `.resolved(cardId)`. Reducer §1.4
  row `.resolved`: drops entry unconditionally.
  Chip → 0. Carousel empty. **No banner. No retry. User's reply is
  silently gone.**

**Final state.**
- Case A: Carousel empty, chip 0, "response timeout" banner with retry.
  USER-FRIENDLY OUTCOME.
- Case B: Carousel empty, chip 0, NO banner. USER HAS NO IDEA THEIR
  REPLY WAS LOST.

**Verdict.** **PASS-WITH-RISK for Case A, FAIL for Case B.** The
design's 10-min timeout works *only* if no `.resolved` arrives. The
audit's §F-5 was about "no upsert ever comes," but the design's §1.4
rule for `.resolved` is "drop unconditionally" — which the audit's R-5
explicitly required for the *user-signed-out / Mac-killed* case. Both
cases (resolve-then-no-upsert and timeout) overlap in scope; the
design's §2.D rule for "timeout fires first, late upsert
re-creates as `.awaitingUser`" handles the case where neither resolve
nor upsert happens but the response *does* eventually arrive. **It
doesn't handle the case where resolve arrives without a follow-up
upsert.**

**Proposed design tweak.** §1.4 row `.resolved` should NOT drop
`.awaitingResponse` entries. Instead, on `.resolved` against an
`.awaitingResponse` entry: keep the entry in `.awaitingResponse`,
*scoped to the timeout watcher*, until either (a) a `.upsert` with
RR > instructedRevision lands and promotes, OR (b) the 10-min timeout
fires and transitions to `.failed`. This is essentially R-4 (the
audit's reverted commit 86f87a3) — but bounded by the timeout R-5
demanded, which the design now provides via §5.1. R-4's *original*
sin was "unbounded preservation"; the design's bounded timeout
removes that sin.

**Race-matrix coverage.** §2.D covers "timeout then late response,"
not "resolve then nothing." The latter is a **gap in §2**.

---

## S-5. iPhone backgrounded 12+ min; Cloudflare DO half-closes the socket; user foregrounds

**User-visible expectation.** Within ≤5 s of `.active`, WS reconnects,
GET refresh fires, any cards published while offline appear, chip
reflects reality. Watchdog has NOT artificially escalated
`reconnectAttempt` while the silent-frame window was in progress.

**Inputs.**
1. T0 — Foreground state: `[]` (no cards). User locks the phone /
   switches apps. `scenePhase = .background`.
2. T0..T0+~30s — pingLoop still runs (iOS lets it complete a few
   cycles). 20 s ping arrives at relay, pong returns.
   `lastFrameReceivedAt = T0+pong`.
3. T0+~30..60s — iOS suspends the app. pingLoop's Task is suspended
   alongside. The WS socket is still open at the relay (Cloudflare
   thinks the client is alive).
4. T0+~6m — Cloudflare DO closes the half-side after 5-10 min idle.
   iPhone doesn't know.
5. T0+~6m+δ — Mac publishes a new card while iPhone is dark. Relay
   broadcasts to WS; the WS task is queued (DO buffers a bit) but
   eventually the broadcast may be dropped on the dead socket.
6. T0+~12m — User taps Steer on the home screen. iOS resumes the
   app. `scenePhase = .active`.

**Walk-through.**
- T0+~12m: `InboxView.scenePhase` observer fires (audit §1c L174-187):
  `inbox.reconnectWebSocketIfNeeded()` + `setBadgeCount(0)` +
  `await inbox.reload()` + `await devicePresence.refresh()`.
- `reconnectWebSocketIfNeeded()` calls `connectWebSocket()` (current
  SyncInbox L508). New WS task spins up; `lastFrameReceivedAt = T+12m`
  per §6.3. `receiveLoop` starts. `pingLoop` starts.
- In parallel: `await reload()` fires GET `/v1/sync/cards`. Per §2.B,
  `snapshotStartedAtSeq = seq=15` is captured before HTTP fires.
- T+12m+RTT: WS handshake completes. Relay sends initial `ping` frame.
  `receiveLoop` stamps `lastFrameReceivedAt`. Reconnect attempt
  counter stays 0 (this was a healthy connect, not after a failure).
  Watchdog (§6.2) checks every 15 s; first check at T+12m+15s sees
  `lastFrameReceivedAt` is fresh, no action.
- T+12m+~50ms: GET returns with the new card(s). `applyEvent(.snapshot)`.
  Reducer §1.5: insert new cards as `.awaitingUser`. `loadPhase = .ready`.
- The card that may also arrive via WS broadcast (replay or new push
  during the connect window) — reducer §1.4 row `.upsert`: same RR →
  refresh content, no stage change. Idempotent.

**Final state.** Carousel: any cards published during offline period.
Chip: 0. UI fully recovered within ~50ms of GET return, comfortably
inside the 5 s expectation.

**Verdict.** **PASS.** The flow uses the EXISTING `scenePhase.active`
handler, which the design doesn't change. Watchdog (§6) is *additive*
— protects against the unusual case where the user does NOT background
but the socket goes silent in-foreground.

**Race-matrix coverage.** §2.A (GET then WS, same updatedAt sub-case).
Both arrive in seconds of each other. Reducer §1.4 row `.upsert` for a
session already inserted from snapshot: same RR → refresh content. OK.

**Risk note.** The design's §6.4 talks about "watchdog suppression
during initial connect grace." The grace window is "60 s after connect
entry, watchdog ignores until the first frame arrives." Read carefully:
the design sets `lastFrameReceivedAt = Date()` at connectWebSocket
entry (§6.3 last paragraph), and the watchdog fires if
`Date().timeIntervalSince(last) > 60`. That means a fresh connect that
takes 60+ s for the first frame to arrive WILL trigger watchdog cancel,
which is correct. But the wording in §6.4 ("Don't fire the watchdog
while a fresh connect is still expecting its first frame") is
contradictory with the §6.3 timer reset. The design needs to clarify:
either grace is implicit (the first frame arrives within RTT, well
under 60s, so the timer doesn't fire) or grace is explicit (a separate
flag). I read §6.3's behavior — grace is implicit. §6.4's paragraph is
poorly worded but doesn't change behavior. Note as **doc-clarity risk**,
not a design bug.

---

## S-6. Mac sign-out while iPhone has a card visible

**User-visible expectation.** Within ~60 s, iPhone's "Mac connected"
chip drops to offline; the device card it had been showing is gone
from the carousel (the Mac DELETE'd its presence row AND its cards).

**Inputs.**
1. T0 — iPhone state: `[entry-S(.awaitingUser, card-X)]`,
   `DevicePresenceObserver.status = .connected`.
2. T0 — User on Mac clicks "Sign out". Per audit §1b: Mac's SyncClient
   issues `DELETE /v1/sync/devices/<deviceId>` (the device row). Also,
   per audit referenced commit 3649bfd cited in `LAUNCH_CHECKLIST` 1D,
   sign-out should also DELETE any cards the Mac had published OR the
   Mac stops publishing (the funnel just stops because the toggle is
   off / signed out).

**Walk-through.**
- T0 — Mac SyncClient signs out. Two effects on relay:
  - `devices` row for Mac is deleted.
  - The Mac funnel stops publishing. Existing cards stay on relay
    until either (a) the Mac re-publishes a different state (no longer
    happening), (b) Mac DELETEs them explicitly, or (c) the 24 h prune
    sweeps them.

  Reading audit §1e L93-94: "Card DELETE (L352-370): marks state='done',
  broadcasts `card.resolved`." Does the Mac DELETE cards on sign-out?
  Looking at the audit §1b, it doesn't say explicitly. From the
  LAUNCH_CHECKLIST 1D ("Sign-out presence stale — commit 3649bfd"),
  the fix appears to be on the *presence* row only, not cards.

  So the cards STAY on relay until the next thing happens.

- T0+~3s — iPhone's `DevicePresenceObserver` polls `/v1/sync/presence`
  (audit §1c every 3 s while connecting, 15 s steady-state). It now
  sees no Mac device. Transitions to `.offline`. UI: chip changes to
  "Mac disconnected".
- T0+~60s — iPhone state per the design: the carousel still shows
  card-X because the relay still has it (no DELETE happened).

   Hmm. Does this match the user-visible expectation? Going back: the
   expectation as written was "card list refreshes (the Mac DELETE'd
   its presence row)." The phrasing implies "presence row gone → chip
   updates" *not* "cards disappear." So:

  - Chip changes to "Mac disconnected" within 15-60 s: **YES**.
  - Cards stay visible: **YES** (and arguably correct — the Mac being
    signed out doesn't invalidate cards the user can still see /
    interact with; what reply path is open if Mac is signed out is a
    separate concern).

**Final state.** Carousel: card-X still visible (no DELETE). Chip:
"Mac disconnected." Reply attempt against card-X would POST to relay,
relay queues it, no Mac to drain it → after 10 min the entry decays
to `.failed("response timeout")` per §5.3.

**Verdict.** **PASS.** Chip presence is governed by
`DevicePresenceObserver`, which the design doesn't touch. The design's
race matrix doesn't apply — no card state mutation happens here.

**Race-matrix coverage.** N/A.

**Note.** The user-visible expectation says "card list refreshes" — if
the user means *cards disappear*, this would FAIL. The design as
written doesn't DELETE cards on Mac sign-out, and there's no rule in
§2 that the iPhone reducer should drop cards based on Mac presence.
This is a question for product, not for sync architecture.

---

## S-7. Two iPhones signed in to the same Apple ID; Mac publishes a card; both reply

**User-visible expectation.** Both phones get the card via APNS + WS
fanout. Both can tap reply. Whichever reply POST hits the relay first
gets injected; the second reply 409s or is a no-op. The design's
`eventSeq` MUST be local per-device, not global.

**Inputs.**
1. T0 — Both iPhones: state = `[entry-S(.awaitingUser, card-X RR=1)]`.
2. T0 — User taps Send on Phone A. `eventSeq_A = 50`. Phone B does the
   same ~50ms later. `eventSeq_B = 50` (Phone B has its own counter).
3. T0+RTT — Phone A's POST `/v1/sync/instructions` reaches relay. Relay
   queues. Returns 200.
4. T0+RTT+50ms — Phone B's POST reaches relay. Relay queues. Returns
   200 (the relay accepts both into its instruction queue —
   `/v1/sync/instructions` is a write-only queue and doesn't check for
   duplicates).
5. T0+~2s — Mac drains queued instructions, picks up Phone A's first
   (FIFO), writes to PTY. Codex starts processing. Phone B's
   instruction sits in queue.
6. T0+~7s — codex finishes Phone A's reply, RR=1 → RR=2. Card upsert
   broadcast.
7. T0+~9s — Mac drains Phone B's instruction. Writes to PTY against
   the NEW card (the response card from Phone A's reply). Whatever
   prompt was on Phone B's reply, it's now executing in the context of
   Phone A's response. RR=2 → RR=3. New broadcast.

**Walk-through.**
- T0+RTT — Phone A: `.userReplied(cardId, text_A, instructionId_A)`.
  `eventSeq_A=50`, state → `.awaitingResponse(T0)`,
  `instructedRevision=1`.
- T0+RTT+50ms — Phone B: same; `eventSeq_B=50`.
- T0+~7s — both phones receive WS `.upsert(card RR=2, updatedAt=T0+5s)`.
  - Phone A's reducer: §1.6 rule 1 promotes (`RR=2 > 1`). New state:
    `[entry-S(.awaitingUser, card RR=2)]`.
  - Phone B's reducer: same.
- Now both phones see the card from Phone A's reply. Phone B's instruction
  is still in the relay queue (Mac hasn't drained it yet).
- T0+~9s — Mac drains B's instruction. Writes prompt. Codex processes
  in the context of Phone A's response. RR=2 → RR=3 upsert broadcast.
  Both phones receive it; both reducers see `incoming.RR=3 > existing
  RR=2`, but stage is `.awaitingUser` not `.awaitingResponse`. §1.4
  row `.upsert` for `.awaitingUser`: "refreshes content but leaves
  stage untouched." OK; the card content updates.

**Final state.**
- Both phones: `[entry-S(.awaitingUser, card RR=3)]`. Carousel shows
  the latest card; both replies have been delivered.
- Phone A's `eventSeq` differs from Phone B's. Per §1.2,
  "process-monotonic counter" — per device. Per §9.4, server-side
  eventSeq is deferred to v3. **The design implicitly assumes per-device
  counters, but §1.2's wording is "process-monotonic," which is
  per-device by accident-of-implementation, not by contract.**

**Verdict.** **PASS-WITH-RISK.**

The functional path works because:
1. eventSeq is used by the reducer ONLY for `.snapshot` (§2.B
   "snapshotStartedAtSeq vs lastReplyEventSeq"), which is a comparison
   between two values *on the same device*. Cross-device, eventSeq is
   meaningless.
2. Promotion via `responseRevision` is cross-device by design (§1.6
   rule 1).

The risk is wording: the design never SAYS "eventSeq is per-device
local." A future reader could try to make it cross-device (push it
through the relay as a global cursor) and break §2.B's semantics. The
design's §9.8 alludes to this ("§2.B uses a client-only
`snapshotStartedAtSeq`... A future server-side event id... would
obsolete this") but should state explicitly in §1.2.

**Proposed design tweak.** Add to §1.2: "eventSeq is per-process,
per-device. It is never serialized to the wire. Cross-device tie-
breaking is exclusively via `responseRevision` and `updatedAt` on the
card." One sentence.

**Race-matrix coverage.** Not in §2.A-2.H. Multi-device contention is
implicit in the "both ends use the same reducer" framing but never
called out. **Gap.**

---

## S-8. Network flap; WiFi briefly drops and reconnects

**User-visible expectation.** WS reconnects within bounded backoff
(≤250 ms + jitter cap), no card data loss. GET on reconnect fills the
gap.

**Inputs.**
1. T0 — Steady state, WS open, state = some cards.
2. T1 — WiFi drops. `task.send(ping)` throws (or `task.receive()` does)
   at next attempt.
3. T1+RTT — Reconnect triggered.
4. T1+~3s — WiFi back.

**Walk-through.**
- T1 — `pingLoop` send fails or `receiveLoop` recv throws (whichever
  fires first per audit R-6). Either way, the task is cancelled
  (R-6 fix preserved per §A.3) and `receiveLoop` exits with
  `reconnectAttempt += 1`, `delay = backoff.delaySeconds(1) ≈ 1s ±
  jitter`. Task sleeps.
- T1+~1s — `connectWebSocket()` runs. New WS task spins up.
- T1+~1.2s (if WiFi back) — handshake succeeds, first frame stamps
  `lastFrameReceivedAt`, `reconnectAttempt → 0` (per current
  `receiveLoop` L875 logic, preserved by design).
- T1+~1.3s — `scenePhase.active` will not fire (phone never
  backgrounded), so `reload()` is not auto-triggered. Cards that
  arrived during the down window are missed by WS but...

  Wait. The design says PR-6 adds a watchdog independent of WS sends.
  Does anything trigger a GET refresh after a transient WS drop? Per
  current code, `reconnectWebSocketIfNeeded()` is only called from
  `InboxView.scenePhase` (foreground transition) and from the
  WS path itself (`receiveLoop` catches → `connectWebSocket()` again).
  There's no automatic `reload()` after a reconnect.

  This means: if a card was broadcast during the 1.5 s outage window,
  the relay's WS layer DOES queue some broadcasts (Cloudflare DO
  buffers, but only briefly; the relay's `upsertCard` fans out
  synchronously to all connected sockets). If the iPhone's socket is
  closed at the moment of `upsertCard`, the broadcast is silently
  dropped on the floor — the relay doesn't store a "delivery queue."

  The user has to wait until the *next* `scenePhase.active` for a
  refresh to fire, OR rely on APNS push to bring them back to active
  (which then auto-fires `reload()`).

  **This is the gap the design's §2.H "race we accept" hints at.** The
  audit's §F-8 integration test ("WS dies mid-reply, foreground
  recovers carousel within 5 s") covers the case where the user
  backgrounds during the failure — but a brief WiFi flap *with the app
  still foregrounded* is uncovered.

**Final state.** WS back online within ~1.2 s. If a card arrived during
the gap, it's missed until next foreground or APNS-driven event.
Carousel may show stale data. Chip not affected (chip is local
state).

**Verdict.** **PASS-WITH-RISK.** The fundamental reconnect path works
(R-6/R-7a preserved per §A.3), but there's no auto-GET on reconnect.
The user-visible expectation says "GET on reconnect fills the gap" —
the design as written does NOT call `reload()` automatically after a
WS reconnect.

**Proposed design tweak.** Add to §6.4 or §6.3: "On every successful
WS (re)connect — when `connectWebSocket` returns and the first frame
has been received — automatically call `reload()` to backfill any
broadcasts missed during the down window." One line added to the
existing reconnect path. This is the "GET-on-reconnect" backfill the
audit's R-7c+R-8 implicitly assumed but never formalized for the in-
foreground reconnect case.

**Race-matrix coverage.** Implicit in §2.B but only in the cold-start
sense. **Gap** for in-foreground reconnect.

---

## S-9. Mac process restart mid-publish

**User-visible expectation.** On next Mac launch, sidecar load either
(a) loads prior good state and re-PUTs the in-flight card idempotently,
or (b) loads empty and the next reload tick re-publishes. No flicker
to iPhone, no DELETE-then-PUT cycle, no orphan cards.

**Inputs.**
1. T0 — Mac is mid-publish: it has decided to PUT card-X, the PUT is
   in flight, the sidecar file has *not yet* been atomically rewritten
   (per §4.4 design: "persist AFTER the PUT").
2. T1 — Mac process killed (SIGKILL / panic / OOM).
3. T2 — Mac relaunches.

**Walk-through (sub-case A: PUT completed before kill).**
- T0..T1 — PUT 200; relay has the card. Sidecar file write was about
  to happen (or just did, depending on timing).
- T1 — process dies. Sidecar may be in either pre-PUT or post-PUT state.
- T2 — `MacSyncFunnel` initializes. Read sidecar (§4.4):
  - If sidecar has card-X with fingerprint matching SQLite: no
    re-publish needed.
  - If sidecar doesn't have card-X (pre-PUT state): fingerprint diff
    against fresh SQLite shows card-X is "new". Funnel publishes.
    Relay's `upsertCard` returns `inserted=false, changed=false`
    (card content unchanged), `becameActive=false` (still active).
    No APNS, no broadcast. Idempotent. Sidecar rewritten.

**Walk-through (sub-case B: PUT did NOT complete before kill).**
- T0..T1 — PUT in flight; process dies before HTTP response.
- T1 — relay either got the request and applied it, OR didn't.
- T2 — Funnel reads sidecar. Sidecar is in old state (per §4.4 design:
  "persist AFTER the PUT"). Compare fingerprint:
  - SQLite says card-X has fingerprint F.
  - Sidecar lacks card-X. Funnel sees card-X as "new" → publishes.
  - Relay: if it already accepted the previous PUT, returns
    `changed=false` → no broadcast. If it didn't, applies cleanly.
  - Either way, the iPhone sees one consistent state.

**Walk-through (sub-case C: sidecar write itself was mid-progress).**
- §4.4 says `Data.write(to:options: .atomic)` — temp file in the same
  directory, then rename. POSIX rename is atomic on local filesystems.
- If process dies between "tempfile written" and "rename": original
  file is still there, unchanged. Loaded as old state on relaunch. OK.
- If process dies between "rename" and... nothing else; rename
  *is* the commit. OK.

**Final state.** On relaunch within ~5 s (Mac funnel's 2 s reload):
the iPhone sees no observable transient. At most one wasted PUT per
crash (idempotent re-publish per §4.4).

**Verdict.** **PASS.** The design's §4.4 protocol (sidecar persist
*after* successful PUT, atomic rename) is correct.

**Race-matrix coverage.** N/A; this is a Mac-side persistence concern
not in the iOS reducer's matrix.

**Risk note.** §4.4 hand-waves "the relay's `upsertCard` `changed ===
false` path; no broadcast, no APNS. Cost: one wasted PUT per Mac
crash. Correctness preserved." This assumes the relay correctly
identifies idempotent re-PUTs. Per audit §1e L93, relay's `upsertCard`
returns `(inserted, changed, becameActive)`. `becameActive` won't fire
on an idempotent re-PUT (state is still `active`). So APNS won't fire.
But: the relay DOES still broadcast `card.upsert` to other WS
listeners on every PUT — that's the current behaviour. The iPhone's
reducer §1.4 row `.upsert` for same-RR will be a no-op refresh. OK.

---

## S-10. Duplicate event: same WS card.upsert delivered twice

**User-visible expectation.** Design §1 promised idempotency. Two
identical upserts produce identical state.

**Inputs.**
1. T0 — State: `[entry-S(.awaitingUser, card RR=2)]`.
2. T1 — WS `.upsert(card RR=2, updatedAt=T1_ms)` arrives.
3. T1+50ms — Same upsert arrives again (relay retry, reconnect replay,
   etc).

**Walk-through.**
- T1 — Reducer §1.4 row `.upsert` for `.awaitingUser` entry, same RR:
  "if `responseRevision` is unchanged, the second upsert refreshes
  `card.updatedAt`/content but leaves stage untouched." Apply: stage
  stays `.awaitingUser`, card refreshed (same content). `setSessions`
  runs but produces same outputs.
- T1+50ms — Same. State identical.

**Final state.** Identical to T0+ε; UI doesn't flicker.

**Verdict.** **PASS.** §1.4 idempotency table covers this row
explicitly.

**Race-matrix coverage.** §2.F covers out-of-order revisions; §1.4
covers exact duplicates. Both apply.

**Risk note.** The design uses `responseRevision` for idempotency
discrimination. If the relay ever sent two upserts with DIFFERENT
`updatedAt` but same `responseRevision`, the reducer would treat both
as "same revision, just refresh content." Per audit §8.3 the
agent's `bumpResponseRevisionIfReady` is atomic — RR is monotonic per
session. So differing-updatedAt-same-RR would only happen on Mac's
2 s tick re-publishing identical content twice. Not harmful, just
verbose; relay-side dedup via §8.6 `becameActive=false` suppresses
the broadcast anyway. OK.

---

## S-11. User taps notification while app is foreground and response card already arrived

**User-visible expectation.** APNS deep-link logic: `requestFocus` +
the reducer end up in the right cardId. No oscillation between stages.

**Inputs.**
1. T0 — Foreground state: `[entry-S(.awaitingUser, card RR=2)]`. User
   already saw the response card.
2. T1 — APNS push arrives (the system may surface it as a banner; on
   iOS 17+ foreground banner suppression depends on user settings).
3. T2 — User taps the banner (or the notification triggers
   `userNotificationCenter(_:didReceive:withCompletionHandler:)`).
4. `pendingFocusSessionId` is set per audit §1c L389-400.

**Walk-through.**
- T0 — State: card-X is `.awaitingUser`.
- T1 — APNS arrives. iOS may or may not show banner (foreground). No
  state mutation.
- T2 — User taps banner. `requestFocus(cardId, sessionId)` runs.
  `pendingFocusSessionId = sid`. `setSessions` is NOT called by
  `requestFocus`.
- T2+ε — `InboxView.onReceive(inbox.$pendingFocusSessionId)` (or
  whichever observer wires this; audit §1c says
  `onReceive(inbox.$cards)` re-checks the deep link when cards land,
  L188-197 of InboxView). UI scrolls to card-X.
- `clearPendingFocus()` runs — `pendingFocusSessionId = nil`.

  Stage oscillation: card-X stage stays `.awaitingUser` throughout. No
  reducer call triggered by the focus path. Good.

**Final state.** Carousel scrolled to card-X. Stage unchanged. No
flicker.

**Verdict.** **PASS.** The design doesn't change the focus path; it
remains an out-of-band UI mechanism that operates on already-populated
`cards`.

**Race-matrix coverage.** N/A.

**Note.** §9.3 of the design explicitly defers
"iOS background → foreground APNS deep-link race" — but S-11 is the
foreground case, which is a no-op path.

---

## S-12. APNS arrives before the WS card.upsert (push faster than DO broadcast)

**User-visible expectation.** User taps banner. `applyBootstrap`-via-
GET accepts the new card per §1.5; no WS event needed first.

**Inputs.**
1. T0 — Foreground state: `[]`. WS connected, but the relay's DO
   broadcast queue is "ahead" of the APNS dispatch? Actually no — per
   relay/src/index.ts L247-249 (audit §1e), `becameActive` triggers
   APNS *and* DO broadcast in the same handler. They are concurrent
   but APNS goes through Apple's edge while DO goes direct over the
   open WS. Empirically APNS lands first sometimes — especially when
   the WS is busy or the device's WS task hasn't drained the receive
   buffer.
2. T1 — Mac publishes card-Y. Relay accepts, returns
   `becameActive=true`, fires both APNS and DO broadcast.
3. T1+~50ms — APNS lands on iPhone (which is backgrounded). Lock
   screen banner appears. WS broadcast: relay handed it to DO;
   either delivered (and ignored by suspended iOS task) or queued.
4. T1+~3s — User taps banner. App resumes. `scenePhase = .active`.

**Walk-through.**
- T1+~3s — `InboxView.scenePhase.active`:
  - `inbox.reconnectWebSocketIfNeeded()` — new WS task spins up.
  - `setBadgeCount(0)`.
  - `await inbox.reload()` — fires GET.
  - `await devicePresence.refresh()`.
  - APNS payload deep-link: `requestFocus(cardId, sessionId)` →
    `pendingFocusSessionId = sid`.
- T1+~3s+RTT — GET returns. Relay has card-Y persisted. `applyEvent(.snapshot(cards: [Y], ...))`.
  Reducer §1.5: `previous = []`, no entries to drop, insert Y as
  `.awaitingUser`. State = `[Y(.awaitingUser)]`. `setSessions` runs.
  `cards` projection picks up Y. `loadPhase = .ready`.
- T1+~3s+RTT — Carousel renders Y. `InboxView.onReceive($cards)`
  detects Y's session matches `pendingFocusSessionId`, scrolls,
  `clearPendingFocus()`.
- WS may also deliver Y on the new connection (relay's DO replay or a
  new broadcast); reducer §1.4 row `.upsert` is idempotent. No-op.

**Final state.** Carousel: card-Y. Focused. Chip: 0.

**Verdict.** **PASS.** The design's §2.B "snapshotStartedAtSeq" rule
isn't strictly needed here (no in-flight write contention), but the
underlying flow — GET is authoritative on cold start — applies. §A.1
of the design pins this case via the R-7c+R-8 rule
("server has a card for session in `.awaitingResponse(stampedAt)`,
`RR > instructedRevision`, promote"). For this fresh-insert case,
the simpler rule "session not in `previous`, insert as `.awaitingUser`"
applies.

**Race-matrix coverage.** §2.A "GET lands first, then WS" sub-case
(WS arriving on a fresh socket can be considered "after" the GET in
terms of reducer order).

---

## S-13 (added). User signs out and signs back in on the same iPhone

**User-visible expectation.** Sign-out clears all local state. Sign-in
restores via cold-start cycle (S-1 plus S-12 if there's a pending
APNS).

**Inputs.**
1. T0 — State = `[entry-S(.awaitingUser), entry-T(.awaitingResponse(T_old), instructedRevision=1)]`.
2. T1 — User taps Sign Out.

**Walk-through.**
- T1 — `SyncInbox.signOut()` (audit §1c L416-448): `setSessions([])`,
  `webSocketTask?.cancel()`, `tokenStore.clear()`, `status = .signedOut`,
  `loadPhase = .idle`.
- All in-memory state is wiped. **But**: per §5.1 design, the
  10-min timeout watcher (`timeoutTask`) is still running. Does
  signOut() cancel it? The design's §5.1 code shows
  `startTimeoutWatcher()` but never shows it being cancelled. Looking
  at the design — `timeoutTask?.cancel()` happens in
  `startTimeoutWatcher` (called from sign-in or `connectWebSocket`?).

  This is **unspecified in the design**. The watcher Task captures
  `self` via `[weak self]`; if `SyncInbox` is a singleton (which it is
  per audit), `self` doesn't dealloc, so the task keeps running with
  `sessions = []`, and the `for entry in sessions` loop does nothing.
  No actual harm — the loop is a no-op when `sessions` is empty.

- T1+30s — Timeout watcher wakes, iterates `sessions = []`, finds
  nothing, sleeps.
- T2 — User signs back in. `refreshMe()` runs → `reload()` → state
  rebuilt from GET. State recovers cleanly.

**Final state.** Post sign-in, state matches relay's snapshot.

**Verdict.** **PASS-WITH-RISK.** The design's §5.1 doesn't explicitly
specify the watcher lifecycle on sign-out / sign-in. The implicit
behavior (singleton survives, empty-sessions loop is no-op) works but
is fragile to future refactors.

**Proposed design tweak.** §5.1: add "`startTimeoutWatcher()` is
called on `connectWebSocket()` and cancelled in `signOut()` /
`webSocketTask?.cancel()`. Idempotent. The watcher's
`for entry in sessions` loop is also no-op-safe for `sessions = []`,
providing belt-and-suspenders."

**Race-matrix coverage.** N/A.

---

## S-14 (added). 11+ minute background → unlock → APNS-driven cold start with both `pendingFocusSessionId` AND a snapshot containing pre-reply card

**This is the second-order R-7c+R-8 scenario.** User's reply was sent
before the long lock; the response landed during lock; the deep-link
on unlock should bring up the *response card*, not the pre-reply one.

**Inputs.**
1. T0 — Foreground state: `[entry-S(.awaitingResponse(T0), instructedRevision=1)]`.
   Phone is foregrounded; the user just sent the reply.
2. T0+ε — User locks phone. App is suspended within ~30 s.
3. T0+~8s — Mac publishes response card RR=2. Relay broadcasts
   `card.upsert(card-X RR=2)` — iOS WS may receive it OR may already
   be suspended.
4. T0+~12m — User unlocks. APNS banner already on lock screen. User
   taps it. `scenePhase = .active`.

**Walk-through.**
- T0+~12m — Same as S-3 + S-12. Reload fires GET, reducer §1.6 rule 1
  promotes `.awaitingResponse → .awaitingUser` because GET returns
  `card RR=2`. Watchdog: new WS connect, first frame stamps
  `lastFrameReceivedAt`. Timeout watcher: still running; `sessions[0]`
  was `.awaitingResponse(T0)`, T0 was 12 min ago. **The watcher could
  fire BEFORE the reload completes**, transitioning the entry to
  `.failed("response timeout")`.

  Let's think. The watcher's `checkAwaitingResponseTimeouts()` is
  `@MainActor` (§5.1). `reload()` is also `@MainActor`. Both can't
  run simultaneously on the main actor — one will be serialized
  after the other. Which goes first?

  `scenePhase = .active` triggers (in `InboxView`):
  1. `inbox.reconnectWebSocketIfNeeded()` — sync, returns immediately.
  2. `setBadgeCount(0)` — sync.
  3. `await inbox.reload()` — async; suspends main actor while HTTP
     fires.
  4. `await devicePresence.refresh()`.

  The watcher's Task is also waiting on `Task.sleep`. When the sleep
  expires, the Task tries to acquire the main actor. If `reload()`
  is in flight (suspended on HTTP), the main actor is *free* between
  the suspension points. The watcher can interrupt.

  If the watcher wins (fires at T0+10m before unlock; remember it's
  on a `Task.sleep(30s)` cadence regardless of foreground/background —
  but iOS suspends background Tasks too, so the watcher's sleep
  doesn't tick while backgrounded; it resumes on `.active`):
  - On `.active`, the watcher Task resumes; sleep expires almost
    immediately; `checkAwaitingResponseTimeouts` runs.
  - Sees entry-S with stage `.awaitingResponse(T0)`, T0 was 12 min ago,
    `Date().timeIntervalSince(T0) > 600` → TRUE.
  - Fires `.awaitingResponseTimeout(sessionId: S)`.
  - Reducer: entry → `.failed("response timeout")`.
  - `setSessions` runs. `pendingReplies` shows the failed banner.

  Then `reload()` completes, applies snapshot with card RR=2.
  Reducer §1.5 step 2: existing entry is `.failed`,
  §1.6 doesn't enumerate `.failed` directly. But §1.5 says "apply
  upsert rules to merge." §1.4 row `.upsert` for `.failed` entries:
  "refresh content but leaves stage untouched" (carryover from
  current `onCardUpsert`'s `.failed` branch — which actually
  *promotes* to `.awaitingUser` per current SessionEntryStore L114-119).
  In design §1.6 there's a special branch for `.failed` "refresh and
  surface for retry" but it's not enumerated as `.failed → .awaitingUser`.

  Looking at the current code (verified above):
  `applyBootstrap`'s `.failed` branch (L110-119) → promotes to
  `.awaitingUser`. The design's §1.6 should presumably preserve this.
  §A.1's rule "server has a card for session-S where `previous` has
  entry-S in `.awaitingResponse`..." doesn't mention `.failed` and
  the rule for `.failed` isn't explicitly stated in §1.5/§1.6.

  If the design preserves the current `.failed → .awaitingUser`
  behavior (likely; §1.4 row `.replyFailed` only says how to enter
  `.failed`, not how to exit on snapshot), then the user-visible flow
  is:
  - User unlocks → 1 frame: "response timeout" banner appears.
  - Next frame: banner clears, card appears, focus scrolls to it.
  - Net visible: maybe a 200ms flicker of the banner, then the card.

  **The flicker is the user-visible issue.** §5.3 promises: "the
  user-visible cost is the banner appears, then disappears when the
  card lands; that's intentional." But here, the banner appears for
  one frame because the response card was already on the relay before
  the user unlocked — there's no "real" timeout, just a serialization
  race between the watcher and the reload.

**Final state.** Carousel: card-X RR=2. Chip: 0. Banner: appeared
briefly during the 1-frame race; gone after `reload()` completes.

**Verdict.** **PASS-WITH-RISK.** Functional but flickery in the cold-
start-from-long-lock case. The design's §2.D promises this is
acceptable ("the banner clears the moment the new card appears"),
but I would argue: a banner that's only visible for 200ms is worse
than no banner — it looks like a glitch to the user.

**Proposed design tweak.** §5.1: when the timeout watcher fires
during a `loadPhase != .ready` window (i.e. cold-start in progress),
defer the `.awaitingResponseTimeout` event until after `reload()`
completes. Concretely:
```swift
@MainActor
private func checkAwaitingResponseTimeouts() {
    guard loadPhase == .ready else { return }  // defer until reload settles
    // ... existing logic
}
```
This is one line and preserves the timeout's safety-net role for the
true "10 min and nothing came" case.

**Race-matrix coverage.** Not in §2. **Gap.**

---

## S-15 (added). Reply POST 200 but the card the user replied to is concurrently being upserted (server-side RR was already bumped)

**A very specific subset of §2.E that the design hand-waves.**

**Inputs.**
1. T0 — State = `[entry-S(.awaitingUser, card RR=1)]`. User typing.
2. T0+ε — Mac codex emits another stop on the same session
   (concurrent — unrelated work). Agent bumps RR=1→RR=2, refreshes
   card content. Mac funnel publishes; relay broadcasts.
3. T0+ε+50ms — User taps Send. POST fires. Reducer
   `.userReplied(cardId-X, text, instructionId)` runs.
   `instructedRevision = 1` (existing).
4. T0+ε+100ms — WS upsert with RR=2 lands.

**Walk-through.**
- T0+ε+50ms — `.userReplied`. §2.E rule: looks up by cardId.
  cardId = `card-${sessionId}` per §8.1, same across all turns. Found.
  Stage → `.awaitingResponse(T0+ε+50ms)`, `instructedRevision = 1`
  (snapshotted from the card at the moment of reply).
- T0+ε+100ms — `.upsert(card RR=2)`. Reducer: stage is now
  `.awaitingResponse`, `instructedRevision = 1`,
  `incoming.RR = 2 > 1` → promote per §1.6 rule 1. New state:
  `[entry-S(.awaitingUser, card RR=2)]`. User's reply is effectively
  abandoned at the UI level — the chip cleared, the response card is
  there. But the relay still has the queued instruction.
- T0+~5s — Mac drains the instruction. Writes prompt against the
  current state of codex. Whatever the user typed is now executing
  in the context of the second card, not the one they typed against.
- T0+~10s — codex finishes user's instruction. RR=2→RR=3. New upsert.

**Final state.** User got a response to their reply, but it's
contextually attached to the second card, not the one they were
looking at when they typed.

**Verdict.** **PASS-WITH-RISK.** The reducer is correct (§2.E rule).
The user-visible weirdness is a *product* concern, not a sync layer
concern. The reducer correctly noops `.userReplied` against a card
that has been promoted (per §2.E's defensive cardId match). But here
the cardId IS the same (`card-${sessionId}`), so the userReplied
does NOT noop — it does enter `.awaitingResponse`, and then promote
right back. The user sees one frame of "1 running" then zero.

**Race-matrix coverage.** §2.E defensive only ("cardId differs"
branch). The cardId-same-but-RR-bumped branch is not enumerated.

**Proposed design tweak.** §2.E should add: "`.userReplied(cardId)`
that matches the entry's cardId but where `entry.card.responseRevision
> entry.instructedRevision` (i.e. RR has been bumped since the user
last saw it) should ALSO no-op, surfacing a 'the underlying card
changed, please review' notice to the user."

---

## Summary

### Verdict counts (15 scenarios)

| Verdict | Count | Scenarios |
|---|---|---|
| PASS | 7 | S-1, S-2, S-3, S-5, S-6, S-10, S-11, S-12 |
| PASS-WITH-RISK | 5 | S-7, S-8, S-13, S-14, S-15 |
| FAIL | 1 | S-4 (Case B) |
| (S-9 counted in PASS but flagged as PASS pending product confirmation) | | |

Restated: **PASS = 8, RISK = 6, FAIL = 1, of 15.**

(S-3 is the headline PASS because it's the audit's R-7c+R-8 scenario;
S-4 is the headline FAIL because the design's "drop on resolve" rule
loses the ack=`injected`-then-die instruction.)

### Top 3 design gaps the simulation revealed

**1. The "resolve arrives, no follow-up upsert ever does" case is the
new R-4/R-5 trap, just with a different trigger.**

`docs/SYNC_LAYER_DESIGN_2026-05-13.md` §1.4 row `.resolved` says
"Drops the entry. Second resolve finds no matching entry; no-op." But
when the wrapper's ack is `injected` (PTY write succeeded) and the
child process dies *during* output, the agent's
`resolveActionCardsForSession` fires — `.resolved` arrives on iPhone —
the entry is dropped — no `.upsert` ever follows — and the user has no
visible signal that their reply was lost. The 10-min timeout doesn't
fire because the entry no longer exists. **Fix:** §1.4 should keep
`.awaitingResponse` entries alive across `.resolved` (revert R-4's
behavior bounded by R-5's timeout). Concretely: `.resolved` drops
`.awaitingUser` and `.failed` entries only; `.awaitingResponse` entries
are preserved until `.awaitingResponseTimeout` or a fresh `.upsert`
with `RR > instructedRevision` fires. The audit's §A.2 explicitly
discusses this as a closed problem — but the closure depends on the
timeout being able to FIRE on the entry, which requires the entry to
exist.

**2. No automatic GET refresh after in-foreground WS reconnect.**

The design assumes WS reconnect alone is sufficient — but missed
broadcasts during the down window are lost forever unless something
fires `reload()`. `scenePhase = .active` does it for the
background-foreground case; `connectWebSocket()` doesn't do it for the
in-foreground WiFi flap case (S-8). **Fix:** §6.3 or a new §6.5: on
every successful `connectWebSocket` that follows a `reconnectAttempt >
0`, automatically call `reload()` once the first frame is received.
One concrete line in `receiveLoop`'s "first successful frame, reset
attempt counter" branch.

**3. The timeout watcher's interaction with cold-start is not
specified, and risks a 1-frame banner flicker on the very scenario
that's the design's headline win (S-14).**

When a user backgrounds at T0 with a pending reply and unlocks at
T0+12m via APNS tap, the watcher's 30 s task wakes immediately on
`.active` and can fire `.awaitingResponseTimeout` *before* `reload()`'s
GET completes — surfacing a 1-frame "response timeout" banner that
clears as soon as the snapshot lands. §5.3 hand-waves this as
intentional, but for a clean cold-start where the response is *already
on the relay* this is a UI flicker, not a useful safety net. **Fix:**
§5.1 should gate `checkAwaitingResponseTimeouts` on `loadPhase ==
.ready`. One line.

### Honest confidence rating

**Medium.** The design is structurally sound for the headline R-7c+R-8
scenario (S-3) and for the foundational happy paths (S-1, S-2, S-12).
It correctly handles idempotency (S-10), Mac restart (S-9), and 12+
min reconnect (S-5). But three gaps emerged from simulation that aren't
in the doc:

- The `.resolved → entry-drop` rule defeats the timeout safety net
  (S-4 Case B). **One-line fix.**
- No GET-on-reconnect after in-foreground WS flap (S-8).
  **One-line fix.**
- Timeout watcher fires before cold-start reload completes (S-14).
  **One-line fix.**

A fourth, minor, gap is doc-clarity rather than a real bug: §1.2's
"process-monotonic eventSeq" should be explicit about being per-
device, not relay-global (S-7).

If the three one-line fixes land before PR-3/PR-6, my confidence
becomes **high** — the design's structure is right; these are
oversights, not architectural debt. As written today, dogfooding S-4
and S-8 will surface bugs that look like new regressions.

### What I cannot answer from paper simulation

- **iOS suspend-vs-Task-resume timing.** When iOS resumes a suspended
  Task, does `Task.sleep` measure wall-clock or process-active-clock?
  The design's §5.1 says "real wall-clock" — but `Task.sleep` is
  implemented atop `mach_absolute_time` on Darwin, which on
  iOS suspends with the process. The watcher may NOT fire until the
  user unlocks, which is exactly when the cold-start race in S-14
  happens.
- **Cloudflare DO behavior under launch-day load.** §2.H "the race we
  accept" assumes the DO will deliver broadcasts coherently to the
  Mac and iPhone within ~RTT. Under load, DO can be slower. The
  design's snapshotStartedAtSeq rule (§2.B) is the only protection,
  and it's client-only.
- **APNS + iOS Focus mode interactions.** §9.3 defers this; the design
  doesn't change it. S-3's "APNS lands while backgrounded" assumes
  the banner shows; under Sleep Focus it may not, breaking the user's
  cold-start trigger.
- **Multi-device concurrent typing.** S-7's risk is wording only, but
  the failure mode (two phones racing to inject conflicting prompts)
  is a real product question the design doesn't address.
- **Whether `Data.write(to: .atomic)` on macOS APFS is truly atomic
  under SIGKILL.** §4.4 assumes yes. POSIX rename is documented to
  be atomic on local filesystems; APFS honors this. But under iCloud
  Drive (the user's home is in iCloud) or external volume, behavior
  may diverge. Out of scope but worth real-device verification.

The simulation can rule out structural bugs but not timing-dependent
ones. Dogfood Phase 9 of `docs/LAUNCH_CHECKLIST.md` against the post-
fix design (with the three one-line additions above) would catch the
three timing risks.

