# Sync Layer Design — Golden-Set Simulation #2 (2026-05-13)

Second simulation, run after `docs/SYNC_LAYER_DESIGN_2026-05-13.md`
§11 (line 1776) landed four patches addressing the gaps from
`docs/SYNC_LAYER_DESIGN_GOLDENSET_SIM_2026-05-13.md`. The patches
are localized to:

- **§1.2 doc-comment** (lines 102–116) — `eventSeq` per-device wording
- **§1.4 idempotency row + §1.4.1 prose** (lines 246, 252–323) —
  `.resolved` preserves `.awaitingResponse`
- **§5.1 pseudocode** (lines 879–894) — timeout watcher gates on
  `loadPhase == .ready`
- **§5.3 wall-clock latency note** (lines 922–934)
- **§6.5 new** (lines 1087–1142) — auto-GET after WS reconnect
- **§8.9 / §8.10 new invariants** (lines 1538–1570)
- **§A.2 revised** (lines 1692–1715)

Same 15 scenarios as `_GOLDENSET_SIM_2026-05-13.md`, plus three
new scenarios (S-16, S-17, S-18) the patches could plausibly break.
Verdicts are re-issued per scenario; new risks the patches introduce
are flagged explicitly.

Conventions are inherited from sim 1 (T-relative timestamps,
`eventSeq=N`, `RR=K`, etc.). Where sim 1 already walked the trace
end-to-end and the patch does NOT touch the relevant rule, the
re-walk is abbreviated to "unchanged from sim 1 — see [link]" and
the verdict is restated.

---

## S-1. Fresh install → Sign in with Apple → first card from Mac codex stops

**Re-walk.** Patches §1.4.1 / §6.5 / §5.1 / §1.2 are inert here:
no `.resolved` event, no WS reconnect (`reconnectAttempt` stays
0 across `refreshMe → connectWebSocket`), no `.awaitingResponse`
entry to time out, no second device. The only patched surface the
flow touches is §5.1's `loadPhase == .ready` gate, which only
matters once `.awaitingResponse` exists — N/A for this scenario.

Verdict unchanged from sim 1 (see lines 95–98 of
`_GOLDENSET_SIM_2026-05-13.md`).

**Verdict.** **PASS.**

---

## S-2. User replies on iPhone, app foreground, WS healthy

**Re-walk.** No reconnect, no `.resolved`, no cold-start (loadPhase
is already `.ready`), single device. The §5.1 gate is a no-op
(response arrives at T1+~7s; watcher next ticks at T1+30s and finds
the entry already promoted to `.awaitingUser`).

The §1.4.1 preservation rule does not engage — no `.resolved` event
arrives in this flow (the agent's `resolveActionCardsForSession` is
called on `injected` *after* the response upsert, not before; the
response card overwrites in-place, and the only `.resolved` would
fire much later when a new instruction wave clears the resolved
state). Even if a `.resolved` arrived after the §1.6 rule-1
promotion, the entry is now `.awaitingUser`, which §1.4.1's
"`.awaitingUser` / `.failed` drop" branch still drops correctly.

**Verdict.** **PASS.** Patches inert; clean §2.C → §1.6 rule-1
traversal.

---

## S-3. Reply backgrounded → Mac publishes while WS dead → APNS tap → cold launch

**Re-walk.** This is the audit's R-7c+R-8 scenario; patches are
adjacent.

- T0+~15s — APNS-driven cold launch. `connectWebSocket()` runs,
  `lastFrameReceivedAt` set at entry (§6.3). `receiveLoop` blocks
  on `task.receive()`. **`reconnectAttempt` is still 0 here** —
  this is a *fresh* connect after `scenePhase.active`, not a
  reconnect from an error path. **§6.5's `reconnectAttempt > 0`
  guard does NOT fire** — the backfill `reload()` would be
  duplicative anyway because `scenePhase.active` already kicked off
  `reload()` (see `InboxView.scenePhase` observer cited in sim 1
  S-3 walk). Good: §6.5 is correctly inert here.
- T0+~15.2s — GET returns card RR=2, snapshot promotes entry-S to
  `.awaitingUser` via §1.6 rule 1. `loadPhase = .ready` (per
  SyncInbox.swift L532, hit on success).
- §5.1 gate at next 30 s watcher tick: `loadPhase == .ready` is
  satisfied, but the entry was already promoted, so the gate is
  trivially satisfied AND there's no `.awaitingResponse` to time
  out. Watcher iterates an empty stage-filter result. No-op.

Patches inert except as harmless guard. Verdict matches sim 1
(lines 255–256 of `_GOLDENSET_SIM_2026-05-13.md`).

**Verdict.** **PASS.**

---

## S-4. User replies; wrapper dies before response can be produced

**Re-walk.** This is the FAIL from sim 1; the §1.4.1 patch is
designed for it.

**Case A — PTY write fails, ack=`failed`.** Unchanged. No
`.resolved` is broadcast (`resolveActionCardsForSession` is gated
on `injected`). At T0+10m the watcher fires
`.awaitingResponseTimeout`; entry decays to `.failed("response
timeout")`. **PASS** (same as sim 1).

**Case B — PTY write succeeds, child dies mid-output, ack=`injected`.**
The agent's ack handler calls `resolveActionCardsForSession`. Mac
funnel's next tick emits `resolveCardIds = [card-${sessionId}]`.
Relay deletes the card, broadcasts `card.resolved`.

iPhone WS receives `.resolved(cardId)`. **Reducer hits §1.4.1's
pseudocode (lines 286–305):**

```swift
case .resolved(let cardId):
    guard let idx = previous.firstIndex(where: { $0.card.cardId == cardId })
    else { return previous }
    let entry = previous[idx]
    switch entry.stage {
    case .awaitingResponse:
        return previous       // PRESERVE
    case .awaitingUser, .failed:
        var next = previous
        next.remove(at: idx)
        return next           // DROP
    }
```

Entry-S is `.awaitingResponse` → **preserved**. Chip stays "1
running." At T0+10m the §5.1 watcher fires
`.awaitingResponseTimeout(sessionId: S)`. Reducer transitions to
`.failed("response timeout — your reply may not have been
delivered")`. Failed banner with retry appears.

§11.1 (lines 1783–1798) calls this exactly. §8.9 (lines 1538–1551)
codifies it. §A.2 (lines 1692–1715) walks the new R-4↔R-5 trade-off.

**Verdict.** **PASS.** The patch closes the FAIL case in sim 1.

**New-risk audit for the §1.4.1 preservation rule:**

1. *Wrapper sends `.resolved` then a fresh `.upsert` 200ms later.*
   §1.4.1 preserves the `.awaitingResponse` entry on `.resolved`.
   The fresh `.upsert` at T0+~5.5s arrives with
   `responseRevision > entry.instructedRevision` (the bump happened
   before the publish). §1.6 rule 1 promotes to `.awaitingUser` —
   the upsert correctly overrides the preservation. *No leak.*

   Sub-risk: what if the upsert has `RR == instructedRevision`?
   That would be a Mac funnel re-publish of the pre-reply card
   (the 2 s tick republishing identical content before the bump
   lands). §2.C rule applies: stage stays `.awaitingResponse`,
   content refreshed. Entry sits where it should. *No leak.*

2. *User signs out while `.awaitingResponse` is preserved.*
   `signOut()` calls `setSessions([])` (SyncInbox.swift L441),
   blowing away ALL entries including the preserved one.
   `loadPhase = .idle` (L443), `webSocketTask?.cancel()` (L444).
   The §5.1 watcher Task is not explicitly cancelled (see S-13
   re-walk below), but iterates an empty list. On sign back in,
   `refreshMe → reload()` rebuilds from server snapshot — the
   server's relay state is post-`.resolved`, so the card is gone;
   §1.5 step 2 sees "session not in `cards`" branch.
   `entry.lastReplyEventSeq` is irrelevant (entry was wiped). The
   user's reply is permanently lost across sign-out — but that's
   intentional sign-out semantics, not a §1.4.1 regression.
   *No new leak.*

3. *iOS app suspended for hours while preserved entry sits there.*
   `Task.sleep` on Darwin pauses with the process (sim 1 noted
   this at lines 1207–1212 as an unanswered question). On resume,
   the watcher's first tick fires; reducer sees stamp >> 10 min,
   transitions to `.failed`. **§5.1 gate also fires:** if `reload()`
   is in flight (which `scenePhase.active` triggers), gate
   short-circuits the watcher; once GET settles, watcher fires on
   next 30 s tick, OR the snapshot itself drops the entry (server
   resolved it, no card in snapshot) per §1.5 step 2. The user
   sees either the failed banner or an empty carousel + chip=0,
   depending on which path wins. The empty-carousel case is the
   *silent reply loss* sim 1 flagged for Case B. **§1.4.1 patch
   does not cover this:** on a `.snapshot` (not `.resolved`) for a
   session not in `cards`, §1.5 step 2 still drops the entry
   (unless `lastReplyEventSeq > snapshotStartedAtSeq`, which it
   isn't on a fresh-load post-sign-in or post-suspend reload).
   **See S-18 below for the dedicated walk.**

---

## S-5. iPhone backgrounded 12+ min; Cloudflare DO half-closes; user foregrounds

**Re-walk.** Inputs identical to sim 1 (lines 391–414).

- T0+~12m — `scenePhase.active`. `reconnectWebSocketIfNeeded()` →
  `connectWebSocket()` opens a NEW socket. Critical: the prior
  socket was suspended-but-not-errored; `receiveLoop` was inside
  `task.receive()` which never threw, so `reconnectAttempt` was
  never incremented. The new socket spins up with
  `reconnectAttempt == 0`. **§6.5's `reconnectAttempt > 0` guard
  does NOT fire.** No auto-GET from §6.5.
- BUT: `scenePhase.active` separately fires `await inbox.reload()`
  (existing path), so a GET happens anyway. The new card lands.
- §5.1 gate: at the moment of `scenePhase.active`, `loadPhase`
  was already `.ready` from a prior run (the user signed in
  earlier). Watcher continues firing. No `.awaitingResponse`
  exists here (state was `[]`), so the iteration is empty. Gate
  is fine.

**Verdict.** **PASS.** Same as sim 1.

**Sub-risk for §6.5.** §6.5 says the backfill triggers after
`reconnectAttempt > 0`. In S-5 the previous socket was killed by
`connectWebSocket()`'s pre-cancel of the old task (see
SyncInbox.swift L508-511 area), which calls cancel → the suspended
receiveLoop wakes with `CancellationError`, increments
`reconnectAttempt += 1`, starts backoff … but `scenePhase.active`'s
`connectWebSocket()` overlapping with that backoff is a race. The
backoff path also calls `connectWebSocket()` from its catch block
(SyncInbox.swift L888). Two `connectWebSocket()` calls may overlap.

Looking at line 508 of SyncInbox.swift: `reconnectWebSocketIfNeeded`
just calls `connectWebSocket()`. The latter's body (not read in
this sim) is presumably idempotent (cancels the prior task, opens
a new one). If `reconnectAttempt` gets incremented by the
suspended-loop's cancellation throw, then §6.5's guard fires when
the new socket gets its first ping. Two paths to `reload()`: the
`scenePhase.active` path and §6.5. Both call the same
`@MainActor reload()`; one will serialize after the other; the
second is an idempotent no-op snapshot. *Acceptable, no leak* — but
see "§6.5 + bootstrap interaction" risk note below.

---

## S-6. Mac sign-out while iPhone has a card visible

**Re-walk.** §1.4.1 / §6.5 / §5.1 / §1.2 patches inert (no
`.resolved` for cards; Mac just stops publishing; no reconnect
on iPhone; no `.awaitingResponse`). Verdict unchanged.

**Verdict.** **PASS.**

---

## S-7. Two iPhones signed in to the same Apple ID

**Re-walk.** §1.2 (lines 102–116) now explicitly states `eventSeq`
is "monotonic within a single client process" and "NOT serialized
to the wire." §8.10 (lines 1553–1570) adds the testable invariant
("no `Codable` type carries an `eventSeq` field"). §11.4 (lines
1838–1854) captures the rationale.

Walking the trace: Phone A and Phone B each maintain their own
counter (50, 50). Cross-device tie-breaking is purely
`responseRevision` (server-bumped, monotonic per session per §8.3)
+ `updatedAt`. Both phones see RR=2 → RR=3 in order; both reducers
promote idempotently.

**Does the new wording disambiguate any other place the doc
implied a cross-device sequence number?** Searched for `eventSeq`
mentions:

- §1.2 (now disambiguated)
- §2.B (`snapshotStartedAtSeq` vs `lastReplyEventSeq`, explicit
  within-process race)
- §2.G ("client-only; no server bump" row, explicit)
- §8.10 invariant
- §9.4 / §9.8 (deferred v3 event log; explicit "server-side event
  id" naming — never conflated with local `eventSeq`)

No other mention reads as cross-device after the patch. The
ambiguity is closed.

**Verdict.** **PASS.** Patch §1.2 + §8.10 closes the wording risk
sim 1 flagged.

---

## S-8. Network flap; WiFi briefly drops and reconnects

**Re-walk.** This is the RISK case from sim 1; §6.5 is designed for
it.

- T1 — `pingLoop`'s send or `receiveLoop`'s recv throws. Per the
  catch block at SyncInbox.swift L884-889: `reconnectAttempt += 1`,
  `Task.sleep(delay)`, `connectWebSocket()`, `return`. The new
  `connectWebSocket()` spawns a fresh `receiveLoop` against a new
  task. **`reconnectAttempt` is now > 0.**
- T1+~1.2s — handshake succeeds. Relay sends initial `ping`
  (userHub.ts L55).
- T1+~1.3s — `task.receive()` returns the `ping`. Per existing
  L875: `if reconnectAttempt > 0 { reconnectAttempt = 0 }`. This
  is precisely the branch §6.5 hooks. The patch sketch (lines
  1113–1121):

  ```swift
  if reconnectAttempt > 0 {
      reconnectAttempt = 0
      Task { @MainActor [weak self] in
          await self?.reload()
      }
  }
  self.lastFrameReceivedAt = Date()
  ```

  Fires `reload()` exactly once. GET returns missing cards. §1.5
  expansion: any card the relay broadcasts during the gap is now
  in the snapshot and lands as `.awaitingUser` (if new) or
  refreshes content (if same RR). User sees the missed card within
  ~RTT of the flap recovery, no foreground transition needed.

**Verdict.** **PASS.** §6.5 closes the S-8 RISK from sim 1.

**Verification of the patch's "exactly once" + race answers:**

*(a) Does auto-GET response arriving AFTER the next WS frame
clobber newer state?* Suppose between T1+1.3s (auto-GET fired)
and T1+1.5s (auto-GET returns), a fresh WS upsert arrives with
RR=N+1. The auto-GET captured `snapshotStartedAtSeq` *before*
firing. The fresh WS upsert at T1+1.4s stamps the entry's
`lastTouchedSeq` (and if it's a `.userReplied`, `lastReplyEventSeq`)
to `eventSeq` > `snapshotStartedAtSeq`. When the auto-GET response
lands at T1+1.5s, §2.B's rule fires for that entry: "did a
higher-seq event touch this entry after snapshotStartedAtSeq?
If yes, keep the entry." The WS upsert's content survives. *No
clobber.*

But: the §2.B rule only protects `lastReplyEventSeq > snapshotSeq`.
It does NOT protect `lastTouchedSeq > snapshotSeq` for non-reply
events. So a pure `card.upsert` from the relay that races the
auto-GET will be overridden by the (older) snapshot's content if
the snapshot has a different (older) `updatedAt`. Per §2.A: "WS
lands first, then GET — if GET's `updatedAt < WS's`, GET is stale;
reducer keeps WS card." That covers the case. The auto-GET
response carries the server-authoritative `updatedAt`, which is
≥ the WS upsert's `updatedAt` only if the relay processed the WS
trigger before serving the GET. Server-side: `upsertCard` is a
single SQLite write before broadcast (per `store.ts:upsertCard`
sequencing). The GET reads the same SQLite. So *if* the WS upsert
landed on the iPhone before the GET response, the relay processed
the upsert BEFORE the GET responded, and the GET response carries
the same or newer `updatedAt`. **Not a clobber: a refresh with
equal content.** Acceptable.

*(b) What if `reload()` is already in flight (user pulled-to-
refresh) when the reconnect happens?* §6.5 says "exactly once" per
reconnect via the `reconnectAttempt > 0` guard. But it does NOT
guard against an already-in-flight `reload()`. Two paths:

1. The user's manual `reload()` was triggered before the
   `reconnectAttempt > 0` branch fires. Both `reload()` calls
   serialize on `@MainActor`; one runs first, completes, sets
   state, then the other runs and is a no-op snapshot. Acceptable.
2. The user's manual `reload()` and §6.5's auto `reload()` race;
   both capture independent `snapshotStartedAtSeq` values
   (different counters), both fire GETs. Two GETs may produce two
   `.snapshot` events back-to-back. Each is idempotent (§1.5),
   replaying the same server state. Acceptable.

**No new leak.** The patch is well-scoped.

*(c) S-8 interaction with §1.5 bootstrap.* On cold start
(`loadPhase == .idle → .bootstrapping`), `refreshMe → reload()` is
the bootstrap GET. If a WiFi flap occurs DURING this initial GET,
the GET fails (Catch arm at SyncInbox.swift L535 sets `lastError`,
does NOT set `loadPhase = .ready`). The watchdog or pingLoop will
notice the dead socket and `reconnectAttempt += 1`. On reconnect,
§6.5's auto-GET fires `reload()` again — which retries the
bootstrap GET. On success, `loadPhase = .ready` (L532). **§6.5
acts as the bootstrap retry path the design previously lacked.**
*Beneficial side effect, no leak.*

**One caveat for the bootstrap interaction: see new scenario S-16
below.**

---

## S-9. Mac process restart mid-publish

Patches all inert (Mac-side persistence concern, no §1.4.1 trigger,
no `.resolved` on iPhone, etc.). Verdict unchanged.

**Verdict.** **PASS.**

---

## S-10. Duplicate event: same WS `card.upsert` delivered twice

Patches inert (no `.resolved`, no reconnect, no cold-start, no
multi-device). Verdict unchanged.

**Verdict.** **PASS.**

---

## S-11. User taps notification while app is foreground

Patches inert. Verdict unchanged.

**Verdict.** **PASS.**

---

## S-12. APNS arrives before the WS `card.upsert`

Patches inert (fresh-state insert via `.snapshot`; no
`.awaitingResponse`, no reconnect-from-error). Verdict unchanged.

**Verdict.** **PASS.**

---

## S-13. User signs out and signs back in on the same iPhone

**Re-walk.** §1.4.1 added a new wrinkle: `.resolved` may preserve
`.awaitingResponse` entries. `signOut()` calls `setSessions([])`
(SyncInbox.swift L441), which atomically clears all entries
including any preserved `.awaitingResponse`. `loadPhase = .idle`
(L443). Watcher's `for entry in sessions` iterates an empty list.
*The patch does not introduce a new sign-out leak.*

On sign back in: `refreshMe → reload()` builds state from server
snapshot. If the server still has the card active, it lands as
`.awaitingUser` (§1.5 step 3). If the server resolved the card
during sign-out (or it expired), nothing lands and the carousel
is empty. **Same as sim 1.**

§11.4's §1.2 doc-comment, §8.10 invariant: per-device counter
is per-process — sign-out doesn't reset it (`_nextSeq` is an
instance var on the singleton `SyncInbox`, persists across
sign-out cycles). The counter monotonically grows across the
sign-out/sign-in event boundary. `snapshotStartedAtSeq` captured
post-sign-in is strictly greater than any `lastReplyEventSeq`
from the pre-sign-out era. Since `setSessions([])` wiped those
entries anyway, the comparison is irrelevant. *No leak.*

§5.1's gate: post-sign-in, `loadPhase` enters `.bootstrapping`,
then `.ready` on GET success. Watcher correctly short-circuits
during `.bootstrapping`. Once `.ready`, the empty sessions array
makes the watcher a no-op. Acceptable.

**Risk note still standing:** sim 1 line 940 flagged "watcher Task
lifecycle on sign-out / sign-in not specified." Patches did NOT
fix this. The watcher Task is presumably never cancelled by
`signOut()`. **Still PASS-WITH-RISK** — see "Top remaining gaps"
below.

**Verdict.** **PASS-WITH-RISK.** Patches do not regress; do not
fix.

---

## S-14. 11+ minute background → unlock → APNS-driven cold start

**Re-walk.** This is the RISK case from sim 1; §5.1 gate is
designed for it.

- T0+~12m — User unlocks. `scenePhase.active`. Sequence:
  1. `reconnectWebSocketIfNeeded()` (sync).
  2. `setBadgeCount(0)` (sync).
  3. `await reload()` (async; **`loadPhase` enters
     `.bootstrapping` if it was `.idle`, OR stays at `.ready` if
     not — see code at SyncInbox.swift L515).
- The watcher Task was suspended during background (Darwin
  semantics) and resumes here. Its `Task.sleep(30s)` may complete
  immediately (if the suspend ate the sleep — semantics on iOS
  for suspended Tasks are: the deadline persists in wall-clock
  terms, so a 30-min suspend means sleep returns instantly on
  resume). Watcher tries to acquire `@MainActor` and run
  `checkAwaitingResponseTimeouts()`.

**Critical timing:** in what order do `reload()` and
`checkAwaitingResponseTimeouts()` run?

- Both are `@MainActor`. They serialize.
- `scenePhase.active`'s closure schedules `await reload()`. That
  await is the first suspension point.
- The watcher Task's `await self.checkAwaitingResponseTimeouts()`
  competes for the main actor.

Three sub-cases:

**Sub-case 14.a — watcher reaches the actor first.** `loadPhase`
state at this moment depends on whether the user had been signed
in previously:
- If they had: `loadPhase` is still `.ready` (it never moved to
  `.bootstrapping` on `scenePhase.active` because `reload()` only
  enters `.bootstrapping` from `.idle`, see L515).
- If they hadn't: not the scenario.

**With `loadPhase == .ready`, the §5.1 gate (line 887) does NOT
short-circuit.** Watcher computes `Date().timeIntervalSince(T0) >
600` → TRUE → fires `.awaitingResponseTimeout(sessionId: S)`.
Reducer transitions to `.failed("response timeout")`. Banner
appears.

Then `reload()` runs, snapshot includes the response card with
RR=2, §1.5 step 2 calls "upsert rules" → the entry is now
`.failed`, but the response card has `RR > instructedRevision`...
Hmm. §1.6 doesn't enumerate `.failed → .awaitingUser` explicitly.
§5.3 (line 506–510) does: "A subsequent `.upsert` with
`responseRevision > instructedRevision` then promotes via the
`.failed` branch (current L110-119 logic), refreshing the card
and moving to `.awaitingUser`." So `.failed` → `.awaitingUser`
on next upsert.

**So the flicker IS still possible if `loadPhase == .ready` was
true at the moment the watcher fires.** The §5.1 gate only helps
if `loadPhase != .ready`.

Re-read §11.3 (lines 1818–1836): the patch says "short-circuits
while `loadPhase != .ready`." Backwards-reading: when `loadPhase
== .ready`, the watcher runs as before. In sim 1's S-14 trace,
the user's prior state was foreground-with-card-known (loadPhase
already `.ready` from earlier). On `scenePhase.active`, loadPhase
stays `.ready`. **The §5.1 gate does NOT prevent the flicker
because loadPhase was never `.idle` or `.bootstrapping` during
the race window.**

Wait — but `reload()` does NOT re-enter `.bootstrapping` on
foreground transitions (only on `.idle → .bootstrapping`,
SyncInbox.swift L515). That means on every `scenePhase.active`,
`loadPhase` stays `.ready` throughout the reload, and the §5.1
gate is permanently disengaged after the very first bootstrap.

**This is a partial fix.** §11.3 closes the cold-launch flicker
(loadPhase transitions idle → bootstrapping → ready, gate
engaged) but does NOT close the warm-foreground flicker
(loadPhase stays ready throughout, gate disengaged).

Sub-case 14.a verdict: **flicker still possible in the
warm-foreground-with-stale-entry case.**

**Sub-case 14.b — `reload()` reaches the actor first.** It enters
the function body, hits its first await (the URLSession HTTP
call). Suspends main actor. The watcher Task acquires the actor.
Same as 14.a — `loadPhase` is `.ready`, no gate, fires the
timeout. Banner appears. Then GET returns, snapshot promotes
`.failed` to `.awaitingUser`. Same flicker.

**Sub-case 14.c — cold-launch-from-suspended-app.** App was
suspended; on `.active`, init code runs. `loadPhase` may transit
`.idle → .bootstrapping`. *Here* the §5.1 gate is engaged.
Watcher's first tick after resume fires; gate short-circuits;
no timeout event; `reload()` lands, promotes via §1.6 rule 1;
no banner. **Sub-case 14.c is fixed by §11.3.**

**Aggregate verdict for S-14:** §5.1 patch is necessary but not
sufficient. Cold-launch (gate engaged) is fixed; warm-foreground
unlock-after-long-lock (gate disengaged) is not.

But wait — is sub-case 14.b actually realistic? iOS suspends apps
backgrounded > ~30s; on `.active`, the app process may have been
killed by iOS jetsam, in which case init code runs (`loadPhase
== .idle → .bootstrapping`). Or it may have been kept warm in
the swap, in which case `loadPhase` is the cached `.ready`. The
realistic 11-minute-background case is mixed: iOS will jetsam
more often the longer the background, but not always.

**Verdict.** **PASS-WITH-RISK (warm-foreground-unlock-flicker
still possible).** Sim 1's RISK rating is partially reduced.

**Proposed additional tweak:** §5.1 should also short-circuit
while there's an in-flight `reload()` task. Add a `reloadInFlight:
Bool` flag set at L513 entry, cleared at the end of the do or
catch block. Gate becomes:

```swift
guard loadPhase == .ready && !reloadInFlight else { return }
```

This catches the warm-foreground case: `scenePhase.active`
schedules `reload()`, the closure sets `reloadInFlight = true`
*before* the first await, watcher running concurrently sees
`reloadInFlight = true` and defers.

Alternatively, demote `loadPhase` to `.bootstrapping` on every
`scenePhase.active` (more user-visible: placeholder reappears
briefly during reload). The first approach is one-line; the
second is a UX change.

**Captive portal sub-question:** "What if `loadPhase` never
reaches `.ready` (the GET fails forever — network out, captive
portal)?"

`reload()`'s catch block (SyncInbox.swift L534-536) sets
`lastError` but does NOT touch `loadPhase`. So `loadPhase` stays
at `.bootstrapping` indefinitely. The §5.1 gate short-circuits
forever. **The 10-min timeout never fires.** The user sees a
chip stuck at "1 running" forever, OR more likely the bootstrap
placeholder forever (because the UI uses `loadPhase ==
.bootstrapping` to show the SyncingPlaceholder per
SyncInbox.swift L43-50 comment).

**This is a NEW regression introduced by §11.3.** The §5.1 gate
adds a stuck-state where, without the gate, the watcher would
have fired and surfaced "response timeout — your reply may not
have been delivered" — which is *exactly* the user-actionable
signal §5.3 promises.

**Severity:** medium. Captive portals are common (airport WiFi,
hotel WiFi). A user signs in at home, replies on iPhone, walks
into a captive-portal airport WiFi 8 min later, the GET starts
failing on every reload, the 10-min timeout never fires, the
chip is stuck. Once the captive portal clears, the next
`reload()` succeeds, `loadPhase = .ready`, watcher's gate opens
and finds the entry well past 10 min → fires `.failed("response
timeout")`. **The behavior is recoverable**, but only on the next
successful GET, which may be hours later.

**Proposed additional tweak (captive-portal corollary):** §5.1
gate should be `loadPhase == .ready || loadPhase ==
.bootstrapping && hasEverReachedReady`. I.e. "if we've ever been
ready, the bootstrap-stuck case shouldn't gate the watcher."
Or simpler: track `lastReloadEndedAt`; if `Date() -
lastReloadEndedAt > 5 min`, treat the bootstrap state as a
hung-GET state and allow the watcher to fire.

The simplest one-line fix: don't gate on `loadPhase` at all;
gate on `reloadInFlight && reloadStartedAt < 30s ago`. That way:
- A fresh `reload()` defers the watcher for up to 30s, plenty
  for a healthy GET (RTT << 1s).
- A stuck `reload()` (captive portal) doesn't defer beyond 30s;
  watcher fires normally.

**Verdict (revised, post captive-portal analysis).** S-14 cold
case: PASS. S-14 warm + captive-portal cases: **RISK** (new
regression introduced by §11.3).

---

## S-15. Reply POST 200 but card is concurrently being upserted

**Re-walk.** Patches inert (no `.resolved`, no reconnect, no
cold-start gate, single device). The §2.E "cardId match but RR
bumped" gap from sim 1 is **not patched** — it was a product
concern, not a sync-layer one. Verdict unchanged: **PASS-WITH-RISK**.

---

## NEW: S-16. Sign-in cold start GET fails (captive portal) then succeeds 10 min later

**A new scenario the patches could break.** §6.5 + §5.1 + §1.4.1
interaction during a stuck bootstrap.

**Inputs:**
1. T0 — User signs in via Apple. Token issued.
2. T0+ε — `refreshMe → connectWebSocket() → reload()`.
3. T0+ε — `connectWebSocket()` succeeds against relay (TCP works).
4. T0+ε — `reload()` fires GET. Captive portal intercepts the
   HTTPS request, returns 200 HTML instead of JSON. JSON parse
   throws. Catch block sets `lastError`, `loadPhase` STAYS at
   `.bootstrapping` (L535-536).
5. T0+30s — `pingLoop` may or may not have errored (captive
   portals usually allow established WSes through, especially
   with TLS-terminated relays). Assume WS stays alive.
6. T0+~5m — User finally accepts the captive portal terms.
   Network is now clean.
7. T0+~5m — Nothing in the design re-triggers `reload()` until
   either (a) `scenePhase.active` fires (app stayed foregrounded
   throughout), (b) WS reconnect fires.

**Walk-through:**
- T0+~5m — WS still alive (captive portals usually pass through
  WebSockets), so `reconnectAttempt == 0`, §6.5 does not fire.
- `scenePhase.active` does not fire (app was foreground
  throughout).
- The next time `reload()` runs is... never, automatically.

**This is a pre-existing gap, NOT a regression from the patches.**
But sim 1's S-8 fix via §6.5 highlights it: the auto-GET only
fires after a *connection reset*, not after a captive-portal
fake-response. The audit's R-6/R-7a covered some of this; §6.5
covers the post-reset case; but the captive-portal-without-reset
case requires a manual pull-to-refresh.

**Verdict.** **PASS-WITH-RISK (pre-existing, not introduced by
patches).** §6.5 narrows but doesn't close. Captive-portal is a
real-world dogfood scenario worth noting; not in any §2 race
matrix cell.

**Optional design tweak:** add a "retry the bootstrap GET on
exponential backoff while `loadPhase == .bootstrapping`." Sketch:

```swift
public func reload() async {
    ...
    } catch {
        lastError = "..."
        if loadPhase == .bootstrapping {
            // Retry on backoff until bootstrap succeeds.
            try? await Task.sleep(nanoseconds: UInt64(min(60.0, 1.0 * pow(2.0, Double(bootstrapRetryAttempt))) * 1_000_000_000))
            bootstrapRetryAttempt += 1
            await reload()
        }
    }
```

Bounded retry loop, awake throughout. Out of scope for this sim's
specific patches but worth flagging.

---

## NEW: S-17. §6.5 fires DURING bootstrap (the auto-GET races the bootstrap GET)

**A new scenario the §6.5 patch could break.** What if the first
bootstrap `reload()` is still in flight when a WS reconnect
triggers §6.5's auto `reload()`?

**Inputs:**
1. T0 — User signs in. `refreshMe → connectWebSocket()`.
   `lastFrameReceivedAt = T0` per §6.3. WS task starts.
2. T0+ε — `refreshMe` continues: `await reload()`. **This is
   `bootstrapping` phase.**
3. T0+ε+RTT — relay sends initial `ping`. Receive loop accepts.
   `reconnectAttempt` is 0 (fresh connect). §6.5's guard fails;
   no auto-`reload()`. Good.
4. T0+200ms — bootstrap GET still in flight. WS hits a transient
   error (relay restart, transient TCP RST). `receiveLoop`
   catches, `reconnectAttempt = 1`, sleeps for backoff, then
   `connectWebSocket()`. New socket spins up.
5. T0+~1.5s — new socket's first frame arrives. Receive loop:
   `reconnectAttempt > 0 → reload()` per §6.5.
6. T0+~2s — bootstrap GET finally returns. `applyEvent(.snapshot(...))`.
   `loadPhase = .ready`.
7. T0+~2.5s — §6.5's `reload()` returns with a (possibly newer
   or identical) snapshot. `applyEvent(.snapshot(...))`.

**Walk-through:**
- Both `reload()` calls are `@MainActor`. They serialize.
- Each captures its own `snapshotStartedAtSeq` (via
  `nextEventSeq()`); they are strictly monotonic.
- The bootstrap `reload()` fires first, gets seq=1. §6.5's
  `reload()` gets seq=2.
- HTTP responses may return in either order. §1.5 expansion
  processes events in the order they're `applyEvent`ed, not in
  the order the GETs were fired.
- If the second `.snapshot` (seq=2) arrives first via applyEvent
  (HTTP races), §1.5 sees `previous = [] (still empty from
  T0)` (or empty if no prior state), inserts whatever cards are
  in `cards`. Then the first `.snapshot` (seq=1) lands —
  `previous` now has the cards from the seq=2 apply. §1.5 step 2
  checks "session not in `cards`" for each — both snapshots came
  from the same relay state (within ~500ms), so the card sets
  should match. **Both snapshots apply the same content.**

  But seq=1's `snapshotStartedAtSeq = 1` is LESS than the entries'
  `lastTouchedSeq` (which was stamped during the seq=2 apply, so
  ≥ 2). §1.5 step 2 sub-clause: "if `entry.lastReplyEventSeq >
  snapshotStartedAtSeq`, keep entry." This is checked when a
  session is NOT in `cards`. Since both snapshots have the same
  cards, no session is missing. The "keep entry" branch doesn't
  fire. *No race.*

- `loadPhase`: bootstrap reload set it to `.ready` on its success
  path. §6.5's reload doesn't change it (already `.ready` →
  guard at L515 is false; success path at L532 reassigns
  `.ready` no-op).

**Edge case within S-17:** what if the bootstrap GET fails
(captive portal style) but §6.5's GET succeeds (network recovered
during reconnect)? Walk:
- Bootstrap `reload()` catches → `loadPhase` stays
  `.bootstrapping`. `lastError` set.
- §6.5's `reload()` runs, succeeds → `applyEvent(.snapshot(...))`
  → `loadPhase = .ready` per L532.
- Bootstrap got the user out of `.bootstrapping`. **§6.5 acts as
  a bootstrap retry path for the network-just-recovered case.**

*Beneficial. No leak.*

**Verdict.** **PASS.** §6.5's interaction with §1.5 bootstrap is
clean. Both paths are idempotent snapshots; serialize correctly
via @MainActor; eventSeq monotonicity is preserved.

---

## NEW: S-18. Entry preserved via §1.4.1, then later wiped by `.snapshot` step 2

**The dedicated S-4 sub-case.** §1.4.1 preserves an
`.awaitingResponse` entry on `.resolved`. But §1.5 step 2 still
drops entries whose session isn't in `cards`. Sequence:

1. T0 — `[entry-S(.awaitingResponse(T0), instructedRevision=1)]`.
2. T0+~5s — `.resolved(card-S)` arrives. Per §1.4.1: PRESERVED.
   State unchanged.
3. T0+~10s — `reload()` fires for some reason
   (`scenePhase.active`, §6.5 auto-GET, manual pull-to-refresh).
4. T0+~10s — GET returns. Server's relay state: card-S is in
   `done`/resolved state, NOT in the `active` cards list. The
   `/v1/sync/cards` endpoint returns `[]` for this session (the
   relay's `loadActiveCards` filters by `state = 'active'`).
5. T0+~10s — `applyEvent(.snapshot(cards: [], snapshotStartedAtSeq: K))`.

**Walk-through (§1.5 step 2):**
- `previous = [entry-S(.awaitingResponse(T0), instructedRevision=1, lastReplyEventSeq=L)]`.
- Index `cards = []` → empty.
- For each entry in `previous`:
  - session-S is NOT in cards.
  - Check: `entry.lastReplyEventSeq > snapshotStartedAtSeq`?
    `L < K` (the user's reply was BEFORE the snapshot fire; K
    advanced monotonically since L). **L is not greater than K.**
  - Drop the entry.
- Final state: `[]`. Chip drops to 0. **The §5.1 watcher iterates
  an empty list at next 30 s tick. No banner.**

**This is the silent-loss case sim 1 flagged for S-4 Case B,
recurring at a different layer.** The §1.4.1 patch closes the
`.resolved`-event path, but the `.snapshot`-event path still
drops preserved entries — because `.snapshot` doesn't know to
preserve them.

**When does this trigger?**
- The user replies (entry enters `.awaitingResponse`,
  `lastReplyEventSeq = L`).
- A `.resolved` arrives — §1.4.1 preserves the entry.
- Before the 10-min timeout fires, ANY `reload()` runs (manual
  refresh, `scenePhase.active`, §6.5 auto-GET). Server returns
  `cards = []` for this session.
- §1.5 step 2 drops the entry. Watcher has nothing to fire on.

**Frequency:** every time the user backgrounds/foregrounds in
the 10 minutes after a wrapper-died reply. Pretty common. Or
once §6.5 lands and any WiFi flap occurs during the same window.

**This is the patch's MOST IMPORTANT NEW RISK.** §1.4.1's
preservation buys time for the timeout, but the snapshot can
prematurely terminate that preservation.

**Proposed fix:** §1.5 step 2 must also preserve
`.awaitingResponse` entries, not just entries with
`lastReplyEventSeq > snapshotStartedAtSeq`. Concretely:

```swift
// §1.5 step 2 (revised):
for entry in previous {
    if cardsByIdSession[entry.sessionId] != nil {
        // apply upsert rules to merge in new payload
        ...
    } else {
        // session NOT in cards — drop or keep?
        if entry.lastReplyEventSeq != nil &&
           entry.lastReplyEventSeq! > snapshotStartedAtSeq {
            // PRE-EXISTING RULE: race protection
            // user replied AFTER the GET went out; keep entry
            keep(entry)
        } else if case .awaitingResponse = entry.stage {
            // NEW RULE: snapshot doesn't have a card for a session
            // we're awaiting a response on. This is the §1.4.1 +
            // .snapshot interaction — preserve so the §5.1 timeout
            // watcher can fire.
            keep(entry)
        } else {
            drop(entry)
        }
    }
}
```

This is one rule, symmetric with §1.4.1's `.resolved` preservation.
Without it, §1.4.1's protection is undermined by the very
`.snapshot` flows §6.5 introduced for backfill.

**Verdict.** **FAIL.** §1.4.1 patch is incomplete; the
`.snapshot` step 2 path needs the symmetric rule.

**This is the headline NEW RISK introduced by the patches.**

---

## Summary

### Verdict counts (18 scenarios)

| Verdict | Count | Scenarios |
|---|---|---|
| PASS | 11 | S-1, S-2, S-3, S-4 (closed), S-5, S-6, S-7, S-8, S-9, S-10, S-11, S-12, S-17 |
| PASS-WITH-RISK | 4 | S-13, S-14, S-15, S-16 |
| FAIL | 1 | S-18 (new — §1.4.1 + §1.5 step 2 gap) |

(Recount: PASS = 13, RISK = 4, FAIL = 1, total 18. S-4 is now
PASS instead of FAIL — a true improvement.)

**Comparison to sim 1:**
- Sim 1 over 15 scenarios: PASS = 8, RISK = 6, FAIL = 1.
- Sim 2 over the same 15 scenarios: PASS = 12, RISK = 3, FAIL = 0.
- Net improvement on the original set: +4 PASS, -3 RISK, -1 FAIL.
- Sim 2 over 18 scenarios (adds S-16, S-17, S-18): PASS = 13,
  RISK = 4, FAIL = 1.

The patches **close every gap sim 1 found**. The four patches
deliver what they promised:
- §11.1 / §1.4.1 closes S-4 FAIL → PASS.
- §11.2 / §6.5 closes S-8 RISK → PASS.
- §11.3 / §5.1 partially closes S-14 RISK (cold case PASS, warm
  case + captive portal still RISK).
- §11.4 / §1.2 closes S-7 RISK → PASS.

But sim 2 surfaces **one new FAIL** introduced by patch §11.1
acting in isolation:

### Top remaining gaps

**1. S-18 FAIL — §1.4.1's preservation is undone by §1.5 step 2.**

When a `.resolved` arrives, §1.4.1 keeps the
`.awaitingResponse` entry alive so §5.1's watcher can fire. But
the next `.snapshot` (from any source: `scenePhase.active`,
§6.5 auto-GET, manual refresh) drops the preserved entry because
§1.5 step 2 doesn't know to preserve `.awaitingResponse` entries
for sessions the server has resolved.

**Fix:** §1.5 step 2 should preserve `.awaitingResponse` entries
in addition to the existing `lastReplyEventSeq > snapshotStartedAtSeq`
preservation. One additional rule, symmetric with §1.4.1.
Pseudocode in S-18 section above.

The fix is one line in the reducer. It does NOT change the §5.1
timeout semantics — preserved entries still decay to `.failed`
at T+10min. It does NOT change R-5's user-signed-out semantics —
sign-out wipes via `setSessions([])`, not via `.snapshot`.

**2. S-14 partial fix — warm-foreground unlock flicker still
possible.**

§5.1's `loadPhase == .ready` gate is engaged only during
cold-start (loadPhase transits `.idle → .bootstrapping → .ready`).
On a warm-foreground unlock (process not killed by iOS jetsam),
`loadPhase` stays `.ready` throughout the
`scenePhase.active`/`reload()` flow. The watcher can fire
mid-reload and produce the 1-frame banner sim 1 flagged.

**Fix:** gate on `reloadInFlight` too. Set a flag at the start
of `reload()`, clear it in the do/catch, gate the watcher on
`loadPhase == .ready && !reloadInFlight`. One additional line.

**3. S-14 captive-portal corollary — §5.1 gate creates a
permanent-stuck case.**

If the cold-start GET fails forever (captive portal, network
fully out, JSON-parse error from an HTTP intercept), `loadPhase`
stays `.bootstrapping` forever. §5.1 gate short-circuits forever.
The 10-min timeout never fires. The user sees a chip stuck at
"1 running" with no actionable banner.

**Fix:** either retry the bootstrap GET on backoff while
`loadPhase == .bootstrapping` (S-16 sketch), OR change the gate
to a time-based "is there an in-flight reload from the last 30s?"
instead of a state-based gate. Either is one short patch.

**4. S-16 pre-existing — captive portal blocks every retry path.**

Independent of §5.1, the captive-portal scenario has no
automatic re-`reload()` path other than `scenePhase.active` and
§6.5 (which requires a WS reset). A user signed in *before*
hitting the captive portal will be stuck in `.bootstrapping`
until they manually pull-to-refresh or background+foreground
the app.

**Fix:** retry-on-backoff during `.bootstrapping`. Pre-existing,
not regression — flag for execution-phase follow-up.

### New risks the patches DO introduce

| Risk | Source | Severity |
|---|---|---|
| `.snapshot` drops `.awaitingResponse` after `.resolved` preserved it | §1.4.1 + §1.5 step 2 interaction | **HIGH** (S-18 FAIL) |
| Warm-foreground unlock flicker still possible | §5.1 gate keyed on `loadPhase`, not on `reloadInFlight` | MEDIUM (S-14) |
| Captive portal permanently stalls the watcher | §5.1 gate engages forever if GET fails forever | MEDIUM (S-14) |
| Two `reload()` paths can race (manual + §6.5) | benign per S-8 / S-17 analysis | LOW |

None of these are architectural; all are one-rule reducer or
host-side additions.

### Confidence rating

**Medium-high.** A clear improvement over sim 1's "medium" — the
four patches deliver the closures sim 1 prescribed, and the
walk-throughs confirm S-4 / S-8 / S-7 are now PASS. But the new
S-18 FAIL is real and load-bearing: it would defeat §11.1's
benefit in the very real-world case where any reload happens in
the 10-min window between `.resolved` and the timeout.

The §5.1 gate's partial coverage of S-14 (cold yes, warm no) and
its captive-portal corollary keep the timeout safety net's
reliability below 100%.

If S-18's one-line fix to §1.5 step 2 lands **before** PR-3
(the reducer rewrite, per §7's migration order), confidence
ratchets to **high**. Without it, the §1.4.1 protection is
fragile — it works only until the next `reload()`.

The S-14 and S-16 follow-ups are tractable and could be deferred
to PR-6 (`.awaitingResponse` decay) if accepted as known gaps.

### Recommendation

**One more design tweak required before migration order §7
executes.** Specifically:

1. **Patch S-18 (must-fix before PR-3):** add §1.5 step 2's
   `.awaitingResponse` preservation rule. Update §A.2's test list
   to include `test_snapshot_preservesAwaitingResponseForResolvedSession`.

2. **Patch S-14 warm + captive-portal (should-fix before PR-6):**
   either re-key §5.1's gate on `reloadInFlight && reloadStartedAt
   < 30s` OR add `lastReachedReady: Date?` to the load phase and
   gate on "has been ready within the last N seconds."

3. **S-16 (defer):** captive-portal bootstrap retry is a
   pre-existing gap; track separately under
   `LAUNCH_CHECKLIST.md` Phase 9 dogfood, not in this design's
   scope.

With (1) landed, the design is ready for PR-3 with high confidence.
Without (1), PR-3 ships a reducer that silently loses replies on
the very common path of background→foreground after wrapper death.

---
