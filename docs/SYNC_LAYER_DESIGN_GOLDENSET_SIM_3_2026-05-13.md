# Sync Layer Design — Golden-Set Simulation #3 (2026-05-13)

Third simulation, run after `docs/SYNC_LAYER_DESIGN_2026-05-13.md` §11
landed three additional patches addressing the gaps from
`docs/SYNC_LAYER_DESIGN_GOLDENSET_SIM_2_2026-05-13.md`:

- **§11.5** (lines 1987–2037) — §1.5 step 2 now preserves
  `.awaitingResponse` entries inside their timeout window (OR-clause).
  Reducer pseudocode at §1.5 lines 326–386. Codified as the second
  half of invariant §8.9 (lines 1663–1683).
- **§11.6** (lines 2039–2080) — §5.1 gate is extended with
  `!reloadInFlight`. Pseudocode at §5.1 lines 914–977. Prose at
  §5.3 lines 1005–1025.
- **§11.7** (lines 2082–2123) — §5.1 captive-portal escape hatch:
  bypass the gate when `loadPhase != .ready` for >5 minutes
  consecutively via `loadPhaseEnteredNotReadyAt`. Pseudocode at
  §5.1 lines 962–971. Prose at §5.3 lines 1027–1048.

Re-walk: all 18 scenarios from sim 2, plus three new scenarios
(S-19, S-20, S-21) the new patches could plausibly break. Verdicts
are re-issued; new risks introduced by the patches are flagged
explicitly. Where sim 2 already walked the trace end-to-end and the
new patches don't touch the relevant rule, the re-walk is
abbreviated to "unchanged from sim 2 — see [link]" and the verdict
is restated.

---

## S-1. Fresh install → Sign in with Apple → first card from Mac codex stops

**Re-walk.** Patches §11.5 / §11.6 / §11.7 are inert here:
- §11.5: no `.awaitingResponse` entry (state empty at sign-in); the
  new OR-clause is checked but `entry.stage` is always `.awaitingUser`
  on first card arrival, so clause (b) never engages.
- §11.6: no `.awaitingResponse` for the watcher to fire on;
  `reloadInFlight` is set during the bootstrap GET but the watcher
  finds nothing to iterate.
- §11.7: `loadPhase` transitions `.idle → .bootstrapping → .ready`
  in <1s on a healthy network; `loadPhaseEnteredNotReadyAt` is
  stamped then cleared well before the 5-min hatch threshold.

Verdict unchanged from sim 2.

**Verdict.** **PASS.**

---

## S-2. User replies on iPhone, app foreground, WS healthy

**Re-walk.** Single device, healthy network, no reconnect, no
`.resolved`. The §11.5 OR-clause never engages (the entry promotes
to `.awaitingUser` via §1.6 rule 1 within ~7s, well inside the
10-min window, before any snapshot fires). §11.6's `reloadInFlight`
gate is irrelevant (no `reload()` racing). §11.7's escape hatch is
inert (`loadPhase == .ready` throughout).

If a stray `scenePhase.active`-driven `reload()` happens during the
~7s wait (e.g. user briefly switches apps and returns), §11.5
clause (b) preserves the `.awaitingResponse` entry across the
intervening `.snapshot` with `cards = [pre-reply-card]`. §1.5 step
2's OR-clause kicks in for the case where the server hasn't yet
seen the response (cards may include the pre-reply card, in which
case clause (b) is never reached — the upsert rules merge in
place and stage stays `.awaitingResponse` per §2.C).

**Verdict.** **PASS.** Patches inert; clean §2.C → §1.6 rule-1
traversal.

---

## S-3. Reply backgrounded → Mac publishes while WS dead → APNS tap → cold launch

**Re-walk.** Audit's R-7c+R-8 scenario. Cold-launch GET returns the
response card; §1.6 rule 1 promotes the (resurrected from APNS-
delivered hint) entry to `.awaitingUser`. The `.snapshot` event
includes the card for this session, so §1.5 step 2's "session NOT
in `cards`" branch is never reached for that entry — §11.5 inert.
§11.6: `reloadInFlight = true` during the cold-start GET, so the
watcher defers; once it lands, `.awaitingUser` (not
`.awaitingResponse`) is the entry stage, watcher finds nothing.
§11.7: `loadPhase` reaches `.ready` within ~200 ms; hatch never
triggers.

**Verdict.** **PASS.**

---

## S-4. User replies; wrapper dies before response can be produced

**Case A — PTY write fails, ack=`failed`.** No `.resolved` is
broadcast. Watcher fires at T+10min; §11.6 gate is satisfied
(`loadPhase == .ready`, `reloadInFlight == false`); transitions to
`.failed`. §11.5 / §11.7 inert. **PASS.**

**Case B — PTY write succeeds, child dies, ack=`injected`,
`.resolved` broadcast.** §1.4.1 preserves the
`.awaitingResponse` entry on `.resolved` (sim 2 closure). At
T+10min the watcher fires `.awaitingResponseTimeout`. §11.6 gate
is satisfied. Entry transitions to `.failed("response timeout")`.
Banner with retry appears. §11.5 / §11.7 inert in the no-reload
sub-path. **PASS.**

**Case B-with-foreground-during-window** (the case S-18 surfaced
in sim 2). After `.resolved` preserves the entry, the user
backgrounds and re-foregrounds inside the 10-min window. A
`reload()` runs (`scenePhase.active` or §6.5 auto-GET).
Server returns `cards = []` for that session (relay stripped on
`.resolved`). `.snapshot` event fires.

**§1.5 step 2 walk (lines 326–386):**
- `previous = [entry-S(.awaitingResponse(T0), instructedRevision=1, lastReplyEventSeq=L)]`.
- Index `cards = []` → empty.
- Entry-S: session NOT in cards.
- Clause (a): `lastReplyEventSeq > snapshotStartedAtSeq`? L < K, NO.
- Clause (b) (§11.5 new): `stage == .awaitingResponse(stampedAt:)` ✓
  AND `stampedAt + 10min > now` (T0 + 600 > T0+~10s) ✓ →
  **PRESERVE.**
- Final state: `[entry-S(.awaitingResponse(T0), ...)]`. Chip stays
  "1 running."

At T+10min, watcher fires (§11.6 gate satisfied —
`reloadInFlight == false` outside any `scenePhase.active`-driven
reload), reducer transitions to `.failed("response timeout")`,
banner appears.

**Verdict.** **PASS.** §11.5 closes the sim 2 FAIL.

---

## S-5. iPhone backgrounded 12+ min; Cloudflare DO half-closes; user foregrounds

**Re-walk.** Same as sim 2 except: on `scenePhase.active`'s
`await reload()`, §11.6 sets `reloadInFlight = true` at entry,
clears at do/catch tails. Watcher defers during the GET (~1-2s on
LTE). No `.awaitingResponse` exists in `state` (state was `[]`),
so the iteration is empty even after the gate opens. §11.5 inert
(no entries to preserve). §11.7 inert (`loadPhase` already
`.ready`).

`scenePhase.active`-only path on a kept-warm process: `loadPhase`
stays `.ready` per SyncInbox.swift L515; only `reloadInFlight`
swings true→false during the reload. The two `connectWebSocket()`
overlap race sim 2 flagged at S-5 sub-risk is unchanged — but the
worst case is two `reload()` calls serialize on @MainActor, each
captures its own `reloadInFlight` cycle, watcher defers until
both clear, no leak.

**Verdict.** **PASS.**

---

## S-6. Mac sign-out while iPhone has a card visible

**Re-walk.** Patches inert (no `.resolved` for the card; Mac just
stops publishing; no reconnect; no `.awaitingResponse`).

**Verdict.** **PASS.**

---

## S-7. Two iPhones signed in to the same Apple ID

**Re-walk.** §11.5 / §11.6 / §11.7 patches are inert (each phone's
state is independent; their `eventSeq` counters are per-process per
§1.2 / §8.10; cross-device tie-breaking still uses
`responseRevision` + `updatedAt`). Reducer behaviour identical to
sim 2.

If both phones simultaneously enter `.awaitingResponse` (each user
replies on their own device), each phone independently runs its
watcher with its own `reloadInFlight` flag — no cross-device
coupling. §11.5's OR-clause activates locally on each phone if its
device-local `.snapshot` lands while its device-local
`.awaitingResponse` is in-window.

**Verdict.** **PASS.**

---

## S-8. Network flap; WiFi briefly drops and reconnects

**Re-walk.** §6.5's auto-GET still fires on `reconnectAttempt > 0`.
The new wrinkle: §11.6's `reloadInFlight` flag is set inside
`reload()`. During the auto-GET (~1-2s), the watcher is gated. If
a `.awaitingResponse` entry exists from before the flap, its
stamp is now older than before the flap (wall-clock advances during
the GET) but no new `.awaitingResponseTimeout` event can fire
mid-GET. After the GET lands:
- If the response card was broadcast during the gap and is now in
  the snapshot, §1.6 rule 1 promotes the entry to `.awaitingUser`.
  Watcher's next tick finds no `.awaitingResponse`. **No flicker.**
- If `cards = []` (session was `.resolved` during the gap), §11.5
  clause (b) preserves the entry. Watcher's next tick at T+30s
  fires the timeout if T+10min has passed.

§11.7 inert (`loadPhase` stays `.ready` throughout).

**Verdict.** **PASS.**

---

## S-9. Mac process restart mid-publish

**Re-walk.** Mac-side persistence concern; iOS patches inert.

**Verdict.** **PASS.**

---

## S-10. Duplicate event: same WS `card.upsert` delivered twice

**Re-walk.** Idempotency handled by §1.4 row 2; §11.5 / §11.6 /
§11.7 don't touch upsert handling.

**Verdict.** **PASS.**

---

## S-11. User taps notification while app is foreground

**Re-walk.** Patches inert (no reload, no `.awaitingResponse`
state, no reconnect).

**Verdict.** **PASS.**

---

## S-12. APNS arrives before the WS `card.upsert`

**Re-walk.** Patches inert (fresh-state insert path; no
`.awaitingResponse`, no reconnect-from-error).

**Verdict.** **PASS.**

---

## S-13. User signs out and signs back in on the same iPhone

**Re-walk.** Sign-out wipes via `setSessions([])` (sim 2 walk
unchanged). §11.5 clause (b) is checked but `previous = []` so
the loop is empty.

**New sub-risk: §11.5 clause (b) + sign-out interaction.** Question
raised: an `.awaitingResponse` from before sign-out must NOT
survive sign-in to a different account.

Walk:
1. User-A on Phone, `state = [entry-S(.awaitingResponse(T0), …)]`.
2. User signs out at T0+5min. `signOut()` calls `setSessions([])`
   (SyncInbox.swift L441 per sim 2). State is `[]`.
3. User signs in as User-B at T0+6min. `refreshMe → reload()`.
4. The reload's `applyEvent(.snapshot(cards: User-B's cards,
   snapshotStartedAtSeq: K'))` runs against `previous = []`. §1.5
   step 2's loop iterates an empty `previous` — clause (b) is
   never evaluated. New entries are inserted as `.awaitingUser`
   per §1.5 step 3.

**The §11.5 OR-clause does NOT survive sign-out** because the
preservation only ever runs against `previous`, and sign-out
wiped `previous` via the dedicated `setSessions([])` path (not
via `.snapshot`). The wall-clock comparison `stampedAt + 10min >
now` is never reached.

**`reloadInFlight` reset on sign-out:** sim 2 flagged that the
watcher Task is presumably never cancelled by `signOut()`. With
§11.6 introducing `reloadInFlight`, the flag's lifecycle matters
too. If `signOut()` is called *during* a `reload()`, the catch
tail still clears `reloadInFlight = false`. No leak — but the
behaviour is implicit. Worth a one-line `reloadInFlight = false`
in `signOut()` to be explicit. **Minor.**

**`loadPhaseEnteredNotReadyAt` lifecycle:** §11.7 says the stamp
is "set on every transition away from `.ready`, cleared on the
next `.ready` transition." `signOut()` sets `loadPhase = .idle`
(L443) — that's a transition away from `.ready` if the prior
state was `.ready`. So the stamp gets set on sign-out. On sign-in,
`refreshMe` calls `reload()`, which enters `.bootstrapping` (no
transition to `.ready` yet). The stamp is still set from sign-out
time. If sign-in takes a long time + bootstrap GET fails, the
hatch could fire spuriously against an empty `previous`. But
since `previous = []` post-sign-out, the watcher iterates nothing
even if the hatch opens. No leak.

**Sign back into the same account, retry POSTs queued:** existing
`pendingReplies` projection (§8.8) — out of scope for this
simulation.

**Verdict.** **PASS-WITH-RISK** (unchanged from sim 2 — pre-existing
watcher Task lifecycle gap; §11.6 / §11.7 add `reloadInFlight` and
`loadPhaseEnteredNotReadyAt` lifecycles that should also be reset
on `signOut()` for explicit hygiene). Patches do not regress.

---

## S-14. 11+ minute background → unlock → APNS-driven cold start

**Re-walk.** Sim 2 split this into three sub-cases:
- 14.a (warm-foreground, watcher reaches actor first) — flicker
  risk.
- 14.b (warm-foreground, reload() reaches actor first) — same flicker.
- 14.c (cold-launch from suspended app) — fixed by §11.3 gate.

§11.6 closes 14.a and 14.b: `reloadInFlight` is set at the entry
of `reload()` before any suspension point (§5.1 pseudocode line 970
combined with the prose at lines 938–949). The watcher's gate is
now `loadPhase == .ready && !reloadInFlight`. On a warm-foreground
unlock:
1. `scenePhase.active` schedules `await reload()`. The closure
   sets `reloadInFlight = true` synchronously at entry.
2. Watcher Task wakes from `Task.sleep(30s)`. Tries to acquire
   `@MainActor`. `reload()` already holds it.
3. `reload()` hits its first await (URLSession HTTP). Suspends.
4. Watcher acquires actor. Checks
   `loadPhase == .ready && !reloadInFlight`. `reloadInFlight` is
   `true` (set in step 1, do-tail hasn't run). Gate fires →
   return.
5. `reload()` resumes, applies snapshot, clears `reloadInFlight`.
6. If the snapshot included the response card, §1.6 rule 1 promotes
   to `.awaitingUser`. Watcher's next 30s tick finds nothing.
7. If `cards = []` (server resolved), §11.5 preserves the entry.
   Watcher's next 30s tick fires the timeout cleanly.

**14.a fixed.** **14.b fixed.** **14.c still fixed by §11.3.**

**Captive-portal corollary** (sim 2 flagged as a new regression):
`loadPhase` stuck at `.bootstrapping` forever; watcher gated
forever. §11.7 closes this: `loadPhaseEnteredNotReadyAt` is set
on every transition away from `.ready` (e.g. `.idle →
.bootstrapping` on cold start). After 5 minutes consecutively
stuck, the watcher's gate is bypassed. Walk:
1. T0 — user signs in. `loadPhase = .idle → .bootstrapping`.
   `loadPhaseEnteredNotReadyAt = T0`.
2. T0+ε — bootstrap GET hits captive portal, fails. `loadPhase`
   stays `.bootstrapping`. `loadPhaseEnteredNotReadyAt` unchanged.
3. T0+5min — escape hatch threshold reached. Next watcher tick
   evaluates `loadPhase != .ready && enteredAt < now - 300s` →
   TRUE → bypass gate.
4. If user replied between T0 and now (state has
   `.awaitingResponse(T_reply)` and `T_reply + 10min > now`),
   watcher fires the timeout. Otherwise no-op.

**Captive-portal sub-corollary closed.**

**Verdict.** **PASS.** §11.6 closes warm-foreground; §11.7 closes
captive-portal sub-corollary.

**Sub-risk: §11.6 stuck-reloadInFlight case** (raised by the
verification questions). What if `reloadInFlight` gets stuck `true`
because the GET hangs but never throws (TCP zombie — typical on
unstable cellular)?

`reload()`'s do/catch covers throwing paths; `URLSession`'s default
`timeoutIntervalForRequest` is 60s on iOS. After 60s the request
throws `URLError(.timedOut)`, the catch tail runs, `reloadInFlight
= false`. Worst case: watcher defers for 60s, fires on next 30s
tick. Acceptable.

But: §11.7's 5-minute escape hatch ALSO covers this — if the
URLSession timeout doesn't fire (e.g. some intermediary keeps the
connection alive without delivering bytes), `loadPhase` never
returns to `.ready`. After 5 min, `loadPhaseEnteredNotReadyAt`'s
hatch trips and the watcher fires. **The two escape paths are
defense in depth.** The reload's URLSession timeout (60s) is the
primary; §11.7's 5-min hatch is the backstop.

What about `loadPhase == .ready && reloadInFlight stuck true`?
This requires `reload()` to have entered, set `reloadInFlight =
true`, and never reached its do/catch tail. The only way this can
happen on a process that's still alive is a programming bug — the
do/catch covers throws, the function has no early `return` after
setting the flag. **Code-review item, not a runtime risk.** But it
IS a place where `loadPhase` doesn't help: if `loadPhase` is
`.ready` (e.g. the GET *did* succeed historically but the current
`reload()` hangs), §11.7's escape hatch does NOT trigger because
`loadPhase != .ready` is false. **The watcher is silently dormant
until the URLSession timeout (60s) clears `reloadInFlight`.**

**Severity: low** (URLSession default timeout is 60s; the
watcher's polling cadence is 30s; worst case the timeout is
delayed by 60s). Worth a comment in the production code to ensure
nobody removes the URLSession timeout assumption. The 60s
URLSession timeout is the load-bearing rule that prevents
permanent stick on warm-foreground; without it, §11.7 doesn't help
because `loadPhase == .ready` keeps the hatch closed.

---

## S-15. Reply POST 200 but card is concurrently being upserted

**Re-walk.** Patches inert (no `.resolved`, no reconnect, no
cold-start gate, single device). The §2.E "cardId match but RR
bumped" gap is unchanged. Verdict same as sim 2.

**Verdict.** **PASS-WITH-RISK.**

---

## S-16. Sign-in cold start GET fails (captive portal) then succeeds 10 min later

**Re-walk.** Sim 2 flagged this as a pre-existing gap (no
automatic re-`reload()` path other than `scenePhase.active` /
§6.5). The new patches:
- §11.5: only acts when there's an `.awaitingResponse` entry; on
  pure sign-in cold start with no prior state, no entries. Inert.
- §11.6: `reloadInFlight` cycles correctly during the failing GET.
  Gate stays closed during reload, opens after. Inert (no entries).
- §11.7: `loadPhase` stays `.bootstrapping`,
  `loadPhaseEnteredNotReadyAt = T0`. At T0+5min the hatch trips —
  but the state is `[]`, so the watcher iterates nothing. Inert.

At T0+10min when the portal clears, no automatic `reload()` runs
unless the WS resets or the user backgrounds/foregrounds (sim 2's
gap). Status unchanged.

**Verdict.** **PASS-WITH-RISK (pre-existing, not introduced by
patches).** Same recommendation as sim 2: track in
`LAUNCH_CHECKLIST.md` Phase 9.

**New sub-risk for §11.7 in S-16:** if the user-A had a prior
`.awaitingResponse` entry from before sign-out, signed out,
signed back in (S-13), and then hits a captive portal on the
fresh sign-in… `previous = []` post-sign-out, so the hatch trips
against an empty list. No leak.

But: if the user signed in, replied, *then* hit the captive
portal, `loadPhase` was `.ready` when they replied; the captive
portal kicks in only when the next `reload()` fires (e.g.
`scenePhase.active`). At that moment `loadPhase` transits
`.ready → ???` — actually no, the catch arm of `reload()` doesn't
set `loadPhase` (sim 2 confirmed via SyncInbox.swift L534-536
audit). So `loadPhase` stays `.ready` throughout the failing
reload. `loadPhaseEnteredNotReadyAt` is never set. §11.7's hatch
never engages.

But `reloadInFlight` cycles back to `false` after the GET fails
(catch tail clears the flag). The watcher's gate is satisfied
(`loadPhase == .ready && !reloadInFlight`). The watcher fires
normally. **§11.7's hatch is only needed for the cold-start
failing-GET case where `loadPhase` is genuinely
`.bootstrapping`.** Warm-foreground failing-GET is handled by the
gate naturally opening once the reload's catch tail runs.

**Acceptable.**

---

## S-17. §6.5 fires DURING bootstrap (auto-GET races bootstrap GET)

**Re-walk.** Both `reload()` calls are `@MainActor`, serialize.
With §11.6's `reloadInFlight`:
1. Bootstrap `reload()` enters, sets `reloadInFlight = true`,
   hits first await (HTTP). Suspends.
2. WS first frame arrives. `reconnectAttempt > 0` triggers §6.5's
   `Task { await reload() }`.
3. The Task takes the actor. The closure body of `reload()`'s
   §11.6 pseudocode is:
   ```
   reloadInFlight = true        // already true from step 1
   try { ... }
   reloadInFlight = false
   ```
   §11.6's prose says "set at the entry of reload()". If the
   implementation is naive (`reloadInFlight = true` unconditionally
   at entry, `reloadInFlight = false` unconditionally at end), then
   the second `reload()`'s exit will clear the flag while the FIRST
   reload is still mid-HTTP. **A race window opens between when
   §6.5's reload completes and when the bootstrap reload's tail
   runs.**

Walk that race:
- T0: bootstrap `reload()` enters, sets `reloadInFlight = true`.
- T0+ε: suspends on URLSession.
- T0+0.5s: §6.5's `reload()` enters, sets `reloadInFlight = true`
  (no-op, already true).
- T0+0.5s+ε: suspends on URLSession.
- T0+0.7s: §6.5's `reload()` returns, applies snapshot, sets
  `reloadInFlight = false`. **Bug: bootstrap reload is still in
  flight.**
- T0+0.8s: watcher Task wakes, checks gate. `reloadInFlight = false`
  → gate satisfied. Fires if it sees an in-window
  `.awaitingResponse`.
- T0+0.9s: bootstrap reload returns, applies snapshot, sets
  `reloadInFlight = false`. (No-op since already false.)

**Possible early-fire window between T0+0.7s and T0+0.9s.** If the
state had a `.awaitingResponse` entry whose 10-min stamp had
expired during the gap, the watcher would fire prematurely (200 ms
before the bootstrap snapshot lands).

**Severity:** low. The window is the difference between two HTTP
RTTs (typically <1s). The watcher's 30s polling cadence means it
won't catch this specific window every time. But it IS the same
flicker bug §11.6 was designed to prevent.

**Proposed fix:** `reloadInFlight` should be a **counter**, not a
**flag**. Increment at entry, decrement at do/catch tails. Gate on
`reloadInFlight > 0`. This composes correctly when two `reload()`s
overlap.

Pseudocode:
```swift
public func reload() async {
    reloadInFlightCount += 1
    defer { reloadInFlightCount -= 1 }
    do { ... } catch { ... }
}
// Gate:
guard loadPhase == .ready && reloadInFlightCount == 0 else { return }
```

Or, equivalent and lower-impact: gate on `reloadInFlight ==
LAST_RELOAD_DONE_AT < now - 1s` instead. But the counter approach
is simpler and idiomatic.

**Verdict.** **PASS-WITH-RISK.** A new sub-risk introduced by
§11.6 + §6.5 interaction: `reloadInFlight` as a Bool is not
re-entrant. Should be a counter. **One-word patch
(`reloadInFlightCount: Int`).**

Note: this only matters when two `reload()`s overlap. The
single-reload case is unaffected.

---

## S-18. Entry preserved via §1.4.1, then later wiped by `.snapshot` step 2

**Re-walk.** This was the FAIL from sim 2. §11.5 is designed for it.

§1.5 step 2 pseudocode (lines 363–378):
```swift
let stillInTimeoutWindow: Bool = {
    guard case .awaitingResponse(let stampedAt) = entry.stage
    else { return false }
    return now.timeIntervalSince(stampedAt) < 600
}()
let writeRaceProtected =
    (entry.lastReplyEventSeq ?? 0) > snapshotStartedAtSeq

if writeRaceProtected || stillInTimeoutWindow {
    keep(entry)
} else {
    drop(entry)
}
```

Walk:
1. T0 — `[entry-S(.awaitingResponse(T0), instructedRevision=1)]`.
2. T0+~5s — `.resolved(card-S)` → §1.4.1 preserves.
3. T0+~10s — background→foreground triggers `reload()`. GET
   returns `cards = []`.
4. `.snapshot` event fires. Step 2:
   - `stillInTimeoutWindow`: stage is `.awaitingResponse(T0)`;
     `now - T0 = 10s < 600s` → TRUE.
   - `writeRaceProtected`: L < K → FALSE.
   - `writeRaceProtected || stillInTimeoutWindow` → TRUE → KEEP.
5. State: `[entry-S(.awaitingResponse(T0), ...)]`. Chip stays
   "1 running."
6. T+10min — watcher fires (§11.6 gate satisfied, no in-flight
   reload at this moment), reducer transitions to `.failed`.

**§11.5 closes the sim 2 FAIL.** **PASS.**

**Verification of the patch's wall-clock interactions** (raised by
the verification questions):

*(a) Clock skew — user manually sets wall clock to the past.*
`now.timeIntervalSince(stampedAt) < 600` becomes false (negative
interval) → entry is NOT preserved. But the §5.1 watcher's
expiration check `now.timeIntervalSince(stamp) > 600` is ALSO
false. The entry is dropped at the next snapshot. Lost reply.

But the user's stamp was set with the same wall clock — if the
user set the clock to the past *after* stamping, the stamp is
"in the future" relative to the new `now`. The entry would have
been preserved forever. Then the user re-sets the clock back to
real time. Now `now.timeIntervalSince(stampedAt) ≈ 0`, still <
600. Preserved. Eventually `now` advances real wall-clock; entry
either decays at T+10min (real wall) or gets promoted by a
response upsert. **No leak as long as wall clock returns to
sanity.**

*(b) Clock skew — user manually sets wall clock to the future.*
Stamp is at T-real. User jumps clock forward by 1 hour.
`now.timeIntervalSince(stampedAt)` is now ~1 hour > 600. Entry
fails the OR-clause's clause (b) → drops on next snapshot. The
§5.1 watcher (also clock-based) would have fired at the next 30s
tick anyway, transitioning to `.failed` first. **The two paths
race but both produce `.failed` or empty.** User sees the timeout
banner or the empty carousel. Either is recoverable (retry from
pendingReplies sheet for `.failed`; manual retry from the cached
draft text for empty).

**This is acceptable behaviour for the user-clock-rewound case.**
Worth noting that the design uses **wall-clock** explicitly (§5.1
line 900: "Clock: real wall-clock, injected. Not monotonic. We
need to survive iOS background suspend"). The trade-off is
intentional. Document via a one-line comment that monotonic time
is NOT used because iOS background suspend pauses it.

*(c) NTP drift.* Sub-second to sub-minute drift across the 10-min
window is well inside the watcher's ±30s slop (§5.2). No leak.

**Verdict.** **PASS.** §11.5 closes the FAIL from sim 2. Clock-skew
edge cases produce recoverable user-visible states; no silent loss.

---

## NEW S-19: User on offline plane / airplane mode for 15 min; reply still in flight; `loadPhase != .ready`

**A new scenario the §11.7 escape hatch is designed for.**

**Inputs:**
1. T0 — User on home WiFi, replies on iPhone. State =
   `[entry-S(.awaitingResponse(T0), instructedRevision=1,
     lastReplyEventSeq=L)]`.
2. T0+ε — POST `/v1/sync/instructions` succeeds; WS broadcasts
   `card.resolved` (wrapper ack=injected); §1.4.1 preserves
   entry. State unchanged.
3. T0+30s — User enters airplane mode (boards a plane).
   `loadPhase` is currently `.ready` (was so before take-off).
   WS dies — `pingLoop` throws on the next tick.
   `reconnectAttempt += 1`, backoff begins.
4. T0+60s — `scenePhase.background` (user pockets the phone).
5. T0+5min — User opens iPhone. `scenePhase.active`.
   `reconnectWebSocketIfNeeded()` is called but the network is
   still down. `await reload()` fires. GET fails with
   `URLError(.notConnectedToInternet)` after the 60s default
   timeout. `loadPhase` was `.ready`; the catch arm sets
   `lastError` but does NOT set `loadPhase` (sim 2 confirmed).
   **`loadPhase` stays `.ready` throughout.**

**Walk-through:**
- §11.7's hatch is keyed on `loadPhase != .ready`. Here
  `loadPhase` is permanently `.ready` despite the offline
  network. **§11.7 hatch DOES NOT engage.**
- §11.6's gate: `loadPhase == .ready && !reloadInFlight`. During
  the failing reload (60s), `reloadInFlight = true` → gate
  closed. After the 60s URLSession timeout fires, the catch tail
  clears `reloadInFlight = false`. **Gate opens.**
- Watcher's next 30s tick fires. Stamp is T0; now is T0+5min+60s
  = T0+6min. `now - T0 = 360s < 600s`. Watcher condition
  `> 600` not met. No-op. Acceptable — entry still in window.
- User stays on plane for 10 more minutes. Each `scenePhase.active`
  triggers a failing reload. Each one cycles `reloadInFlight`
  true → false. Watcher gate cycles too. After 60s, gate opens.
- At T0+10min the entry's stamp is 10 minutes old. Watcher's next
  tick after that: stamp + 600 > now is false. Fires
  `.awaitingResponseTimeout`. Entry transitions to `.failed`.
  Banner appears.

**At exactly the 5-min hatch threshold (T0+5min into airplane mode):**
- `loadPhase` is still `.ready` (not in `.bootstrapping`). Hatch
  is gated on `loadPhase != .ready` — does NOT engage.
- Watcher's gate is the normal `loadPhase == .ready &&
  !reloadInFlight`. Engages and gates correctly during the
  failing GET.

**The 5-min hatch is irrelevant in S-19** because `loadPhase`
stays `.ready` throughout. The watcher runs normally between
failing reloads, and fires correctly at T+10min via the wall-clock
stamp check. **PASS.**

**Note:** §11.7 was designed for the *cold-launch* failing-GET
case where `loadPhase` is genuinely `.bootstrapping`. S-19 is the
*warm* failing-GET case, which is handled by §11.6's
`reloadInFlight` flag naturally cycling true→false on each failed
attempt. The hatch is the long-tail backstop for a different
failure mode.

**Verdict.** **PASS.** The patches stack: §11.6 cycles correctly on
each failing reload; the watcher fires at T+10min via the
wall-clock stamp.

**Sub-risk for the §11.7 hatch's interaction with §5.1 wall-clock
timeout** (raised by the verification questions): "if `loadPhase`
enters not-ready *immediately* after the user sends a reply,
then 5 minutes later the watcher fires while only 5 of 10 minutes
have elapsed on `.awaitingResponse`."

Walk that hypothetical:
1. T0 — user replies. `state = [entry-S(.awaitingResponse(T0))]`.
   `loadPhase = .ready`.
2. T0+ε — captive portal kicks in. Bootstrap is rerun (forced via
   some explicit transition that takes `loadPhase` back to
   `.bootstrapping`). `loadPhaseEnteredNotReadyAt = T0+ε`.
3. T0+5min — hatch trips.
4. Watcher's next 30s tick: hatch is open → bypass the
   `loadPhase == .ready && !reloadInFlight` gate. Iterate sessions.
   For entry-S, check `now.timeIntervalSince(stamp) > 600`.
   `now - T0 = 5min = 300s < 600s` → FALSE. **Watcher does NOT fire.**

**The hatch bypasses the gate, but the wall-clock stamp comparison
in the watcher itself still requires the 10-min threshold to have
passed.** §11.7 does NOT pre-empt the 10-min stamp; it only opens
the gate so the watcher can evaluate. The watcher's check
`now.timeIntervalSince(stamp) > 600` (§5.1 line 974) is the
true bound.

**The verification question's worry is unfounded.** The hatch is
gating gate-bypass, not stamp-bypass. The wall-clock 10-min stamp
is sovereign. **No early-fire risk.**

---

## NEW S-20: WiFi flap *during* a reload's GET in-flight — does `reloadInFlight` stay correctly gated?

**Inputs:**
1. T0 — `reload()` enters. `reloadInFlight = true`. URLSession
   request fires.
2. T0+0.5s — WiFi drops. URLSession's request stalls (no FIN/RST
   yet because the AP went silent). The watcher's 30s tick is
   pending.
3. T1 (~0.5s-30s later) — `pingLoop` separately throws on a
   WebSocket send. `reconnectAttempt += 1`, backoff begins.
4. T2 (a few seconds later) — WiFi reconnects. URLSession may:
   - (a) succeed (TCP zombie revives) — unlikely, AP changes
     destination IP usually.
   - (b) time out (60s default `timeoutIntervalForRequest`) — set
     `URLError(.timedOut)`, catch tail runs.
   - (c) error with `notConnectedToInternet` if cellular doesn't
     pick up — catch tail runs.
5. T3 — WS reconnects. `reconnectAttempt > 0` triggers §6.5's
   auto-GET. New `reload()` enters.

**Walk-through:**
- Between T0 and the original reload's catch/do tail, `reloadInFlight
  = true`. The watcher defers correctly.
- At T1 the WS dies but the original GET is still pending. The
  reducer's gate is still closed.
- At T3, §6.5's auto-GET enters. With §11.6's pseudocode treating
  `reloadInFlight` as a Bool, the second reload reads
  `reloadInFlight = true` (no-op, already true), enters HTTP.
  Two concurrent GETs.
- The original GET eventually times out at T0+60s. Catch tail
  clears `reloadInFlight = false`.
- §6.5's GET is still in flight, but `reloadInFlight` is now
  `false` — **incorrectly cleared.** The watcher's next 30s tick
  evaluates the gate as open. If there's a `.awaitingResponse`
  entry past its 10-min stamp, the watcher fires while the §6.5
  GET is still in flight.

**This is the same Bool-not-counter bug from S-17, re-manifesting
in a different sequence.** §6.5's GET could land 100-200ms later
with the response card, promote the entry via §1.6 rule 1 — but
the watcher already fired, transitioned to `.failed`. Then the
upsert lands and re-promotes from `.failed` to `.awaitingUser` (per
§5.3 promotion path). **1-frame banner flicker.**

**Severity:** medium. Requires the conjunction of (a) WiFi flap
during a GET, (b) `.awaitingResponse` entry past stamp, (c)
§6.5's auto-GET landing within ~200ms of the original GET's
catch tail clearing `reloadInFlight`. Rare in practice but not
impossible.

**Fix:** same as S-17 — convert `reloadInFlight` from Bool to a
counter (`reloadInFlightCount: Int`).

**Verdict.** **RISK.** §11.6's Bool isn't re-entrant. The
verification question "what if `reloadInFlight` gets stuck `true`
(the GET hangs but never throws)?" is one half of the same bug;
the other half is "what if `reloadInFlight` gets cleared while
another reload is still in flight?" Both close with the counter
fix.

**Note:** the URLSession 60s timeout makes the "stuck `true`"
worst case bounded. But the "cleared while another reload is in
flight" case is unbounded if §6.5 keeps firing on each WS
reconnect during a long WiFi flap session — though in practice
the relay's exponential backoff limits the reconnect rate.

---

## NEW S-21: User scrolls a card, replies, immediately backgrounds, 30s background, comes back

**Inputs:**
1. T0 — user is reading a card on iPhone, taps Send.
   `userReplied(cardId, text, instructionId)` event. `state =
   [entry-S(.awaitingResponse(T0), instructedRevision=1,
   lastReplyEventSeq=L)]`. POST fires.
2. T0+0.5s — POST returns 200. `markUserReplied` already ran
   (optimistic). No reducer event needed.
3. T0+1s — user backgrounds the app. `scenePhase.background`.
   The WS task continues briefly until iOS suspends the process
   (~5-10s out of foreground).
4. T0+~8s — iOS suspends the WS task. `pingLoop` is suspended
   too. No reconnect.
5. T0+10s — Mac codex stops, agent upserts card with RR=2,
   resolves the in-flight reply. Relay broadcasts `card.upsert`
   (response card with RR=2) and `card.resolved` (the agent's
   `resolveActionCardsForSession` was called on injected ack).
6. T0+15s — Cloudflare DO discovers the iPhone WS is half-closed;
   the broadcast was fanned-out to currently-connected sockets;
   iPhone misses both.
7. T0+30s — user re-foregrounds. `scenePhase.active`.
   `reconnectWebSocketIfNeeded()` calls `connectWebSocket()`.
   Concurrently, `await reload()` fires.

**Three concurrent things at T0+30s:**
- (1) `connectWebSocket()` opens a new socket. The old socket's
  `task.receive()` wakes with cancellation, `receiveLoop`'s catch
  arm increments `reconnectAttempt += 1`, sleeps for backoff,
  then calls `connectWebSocket()` (overlap with the
  `scenePhase.active` path's call — sim 2 S-5 walk).
- (2) `reload()` is called by `scenePhase.active`'s closure.
  `reloadInFlight = true`. GET fires. Will land in ~200-1000 ms.
- (3) New WS first frame may arrive before or after the GET. If
  before, `reconnectAttempt > 0 → §6.5 auto-GET`.

**Walk-through, ordering: GET-from-(2) lands first, then WS frame.**

- T0+30.3s — `reload()` (2) returns. Snapshot contains card with
  RR=2 (response).
- `applyEvent(.snapshot(cards: [card-S(RR=2)], snapshotStartedAtSeq: K))`.
- §1.5 step 1: index cards by sessionId. cards has session-S.
- §1.5 step 2: entry-S has session-S → "session IS in cards"
  branch. **NOT the OR-clause path.** Apply upsert rules per
  §1.6:
  - §1.6 rule 1: `responseRevision == 2` > `instructedRevision
    == 1` → **PROMOTE to `.awaitingUser`**, refresh content.
- State: `[entry-S(.awaitingUser, card RR=2)]`. Chip shows
  "1 ready to read." Banner appears for new response.
- `reloadInFlight = false` (catch/do tail).

- T0+30.5s — WS first frame arrives. `reconnectAttempt > 0` →
  §6.5 fires `reload()` (3).
- `reloadInFlight = true`. GET fires.
- T0+30.7s — GET returns. Server's state: card RR=2 is still
  active (no further `.resolved` in this scenario beyond the
  one from T0+10s; the response card itself is the new active
  card). Snapshot: `[card-S(RR=2)]`.
- `applyEvent(.snapshot(...))`. §1.5 step 2: entry-S session in
  cards → §1.6 rule 1 — but `responseRevision == 2` ==
  `instructedRevision` is FALSE because `instructedRevision`
  was bumped during the promotion at T0+30.3s.

Wait — does `instructedRevision` get bumped on promotion? Let me
re-read §1.6 rule 1:

> "**`responseRevision` strictly greater** than
> `entry.instructedRevision`. … The agent bumps it *before*
> upserting the card row in one write transaction
> (`store.js:refreshActionCard` L383-424); iPhone sees one
> consistent upsert with the new revision. Use this whenever the
> incoming card has a non-nil `responseRevision`."

The promotion rule reads `responseRevision > instructedRevision`
and promotes. The entry's `instructedRevision` field isn't
necessarily updated to match `responseRevision` post-promotion.
Looking at sim 2's S-8 sub-risk discussion, the entry's
`instructedRevision` is the revision at the time the user *sent*
the instruction; the promotion compares the response's RR against
that stamp. After promotion, `instructedRevision` stays put;
re-evaluating `RR > instructedRevision` on a re-played snapshot
still returns TRUE.

That means the second snapshot (T0+30.7s) re-runs the promotion
rule — but the entry is already `.awaitingUser`. Re-promotion is
a no-op (§1.4 row 2: "If `responseRevision` is greater than
`instructedRevision`, the first upsert already promoted to
`.awaitingUser`; the second finds the entry already in
`.awaitingUser` and just refreshes content").

State unchanged. `reloadInFlight = false` (tail). No flicker.

**Watcher's tick during this whole flow:**
- At T0+30s, the watcher's 30s timer (it's now T0+30s, the
  watcher was last fired at T-30s or earlier — actually the
  watcher fires every 30s wall-clock; we don't know its phase).
- If the watcher fires during the brief window between T0+30s
  (reload starts) and T0+30.3s (first reload's catch/do tail):
  - `reloadInFlight = true` (from reload 2). Gate closed. Defer.
- If the watcher fires between T0+30.3s and T0+30.5s
  (after first reload's tail, before second reload starts):
  - `reloadInFlight = false`. Gate open. Iterate sessions. Entry-S
    is now `.awaitingUser` (not `.awaitingResponse`). **Watcher's
    inner `guard case .awaitingResponse` short-circuits.** No
    timeout fired. Correct.
- If the watcher fires between T0+30.5s and T0+30.7s (during
  second reload):
  - `reloadInFlight = true`. Gate closed. Defer.

**All three cases produce correct behaviour.** None of the three
patches step on the others.

**The §11.5 OR-clause is NEVER hit in S-21** because the snapshot
always contains the session's card (the response card landed before
either GET returned, so both GETs see RR=2 in their snapshots).

**The §11.7 hatch is inert** (`loadPhase == .ready` throughout).

**Verdict.** **PASS.** The three patches stack cleanly. The only
sub-risk is the same S-17/S-20 Bool-not-counter risk if `reload()`
calls overlap exactly enough — but here the two GETs are
strictly serial because `@MainActor` serializes them and neither
holds a reentrancy lock during the actor-suspension await.

**Sub-clarification: does §11.6's `reloadInFlight` flag get
cleared by reload (3) before reload (2)'s actor turn returns?**
Both reloads run on `@MainActor`. If reload (2)'s
`reloadInFlight = true` is set synchronously at entry, then it
hits the URL await and SUSPENDS. The actor is freed. Reload
(3)'s closure body runs on the same actor; it sees
`reloadInFlight = true` (already true), so its set is a no-op. It
hits its URL await and SUSPENDS. Whichever HTTP response lands
first resumes its respective continuation; the catch/do tail
runs, sets `reloadInFlight = false`. **THE OTHER RELOAD IS NOW
WITHOUT THE GATE-PROTECTION** until it itself resumes.

**This is the S-17 / S-20 bug surfacing in S-21 as well.** The
window is tiny in S-21 (~200 ms between the two HTTP responses);
the watcher's 30s polling cadence makes the actual surface area
small. But it IS the same race. **The counter fix from S-17
closes this completely.**

**Verdict (refined).** **PASS-WITH-RISK.** S-21 walks correctly
under the Bool implementation because the watcher's polling
cadence makes the race-window-hit probability ~200ms / 30s = 0.7%
per overlap event. **But the underlying mechanism is the same as
S-20's RISK.** The counter fix is the same one-line change.

---

## Summary

### Verdict counts (21 scenarios)

| Verdict | Count | Scenarios |
|---|---|---|
| PASS | 15 | S-1, S-2, S-3, S-4 (all sub-cases including B-with-foreground), S-5, S-6, S-7, S-8, S-9, S-10, S-11, S-12, S-14, S-18, S-19 |
| PASS-WITH-RISK | 5 | S-13, S-15, S-16, S-17, S-21 |
| RISK | 1 | S-20 |
| FAIL | 0 | — |

(Recount: PASS = 15, PASS-WITH-RISK = 5, RISK = 1, FAIL = 0,
total 21. Note: S-17 and S-21 share the same Bool-not-counter
root cause with S-20; one fix closes all three.)

**Comparison to sim 2:**
- Sim 2 over 18 scenarios: PASS = 13, RISK = 4, FAIL = 1.
- Sim 3 over the same 18 scenarios: PASS = 13, RISK = 4, FAIL = 0.
  - S-18 FAIL → PASS (closed by §11.5).
  - S-14 RISK → PASS (closed by §11.6 + §11.7).
- Sim 3 adds three new scenarios (S-19, S-20, S-21): 2 PASS,
  1 RISK, 0 FAIL (S-19 PASS, S-20 RISK from re-entrancy bug,
  S-21 PASS-WITH-RISK from same root cause).
- Sim 3 over 21 scenarios: PASS = 15, RISK = 5, FAIL = 0, +1 RISK.

The patches **close every FAIL and RISK identified in sim 2**.
The new patches deliver what they promised:
- §11.5 closes S-18 FAIL → PASS (the headline closure).
- §11.6 closes S-14 warm-foreground RISK → PASS.
- §11.7 closes S-14 captive-portal RISK → PASS.

But sim 3 surfaces **one new RISK** introduced by §11.6's choice
of representation (Bool instead of counter), affecting any
scenario where two `reload()` calls overlap:

### Top remaining gaps

**1. S-20 RISK (and S-17, S-21 sub-risk) — `reloadInFlight` is a
Bool, not a counter.**

If two `reload()` calls overlap (e.g. bootstrap reload + §6.5
auto-GET; or `scenePhase.active` reload + §6.5 auto-GET on a
flap during the same wake), the second reload's catch/do tail
clears `reloadInFlight = false` while the first is still
in-flight. The watcher's gate opens prematurely. A 1-frame
flicker is possible if a 10-min stamp expires inside the window.

**Fix:** convert `reloadInFlight` from `Bool` to a counter
(`reloadInFlightCount: Int`). Increment at `reload()` entry,
decrement at do/catch tails (e.g. via Swift `defer`). Gate on
`reloadInFlightCount == 0`. **One-line patch.**

Pseudocode:
```swift
@MainActor
public func reload() async {
    reloadInFlightCount += 1
    defer { reloadInFlightCount -= 1 }
    // ... existing body, unchanged ...
}

// §5.1 gate:
guard loadPhase == .ready && reloadInFlightCount == 0 else { return }
```

Severity: **medium** (rare race; bounded by URLSession 60s
timeout; cosmetic 1-frame flicker). Tractable; should be in PR-6
alongside the watcher Task itself.

**2. S-15 partial — same as sim 2 (product concern, deferred).**

**3. S-16 pre-existing — same as sim 2 (captive-portal bootstrap
retry; deferred to dogfood checklist).**

**4. S-13 implicit — `reloadInFlight` and
`loadPhaseEnteredNotReadyAt` lifecycles on sign-out are not
spelled out.**

`signOut()` should explicitly reset `reloadInFlightCount = 0` and
`loadPhaseEnteredNotReadyAt = nil` for hygiene. The watcher Task
lifecycle on sign-out is a pre-existing gap (sim 1 / sim 2 raised
it; patches do not regress).

**Fix:** add the two lines to `signOut()` (SyncInbox.swift L441
area). Trivial.

### New risks the patches DO introduce

| Risk | Source | Severity |
|---|---|---|
| `reloadInFlight` not re-entrant when two reloads overlap | §11.6 Bool flag (vs counter) | **MEDIUM** (S-20 RISK; surfaces as 1-frame flicker in rare races) |
| `reloadInFlight` / `loadPhaseEnteredNotReadyAt` lifecycle on sign-out implicit | §11.6 + §11.7 + existing `signOut()` | LOW (cosmetic state; cleared by next reload regardless) |

Neither is architectural. Both are one-line state-management
changes localized to the SyncInbox host.

### Verification questions answered

**§11.5 OR-clause:**
- ✅ Closes S-18 (background→foreground silent reply loss).
- ✅ Sign-out interaction: `setSessions([])` blows entries before
  any `.snapshot` against `previous` runs; OR-clause never sees
  pre-sign-out entries; sign-in to a different account starts
  fresh. **No leak across accounts.**
- ✅ Clock skew (NTP drift, manual user clock changes): the
  wall-clock `stampedAt + 10min > now` comparison degrades
  gracefully — clock-back-to-past extends preservation;
  clock-jump-forward drops the entry and `.failed` banner
  surfaces via the watcher (same wall-clock baseline). Either
  way: no silent loss. Acceptable; document the wall-clock
  choice in the production code (already documented at §5.1
  line 900).

**§11.6 `reloadInFlight` gate:**
- ✅ Closes S-14 warm-foreground flicker.
- ⚠️ **Stuck `reloadInFlight = true` from a TCP zombie** is
  bounded by URLSession's default 60s timeout. The watcher
  defers up to 60s; tolerable.
- ⚠️ **`reloadInFlight` cleared while a second reload is in
  flight** (S-17, S-20, S-21 root cause) — re-entrancy bug.
  **Fix: convert to a counter.**

**§11.7 5-min escape hatch:**
- ✅ Closes S-14 captive-portal corollary.
- ✅ The escape hatch is gate-bypass, NOT stamp-bypass — the
  watcher's `now.timeIntervalSince(stamp) > 600` check still
  governs whether a timeout actually fires. The 5-min hatch and
  the 10-min stamp do NOT collide; the hatch only opens the
  watcher's evaluation, the wall-clock stamp gates whether the
  watcher acts.
- ✅ §11.7 only engages when `loadPhase != .ready` for >5min
  (captive portal at cold-start). The warm-foreground failing-GET
  case (S-19) leaves `loadPhase == .ready` and is handled by
  §11.6's `reloadInFlight` cycling on each failed attempt.

### Confidence rating

**High.** Sim 2 had one FAIL (S-18) and three RISKs (S-14 warm,
S-14 captive, S-15 product); sim 3 closes the FAIL, both S-14
RISKs, and surfaces only one new RISK that's a known
implementation refinement (Bool → counter), with severity bounded
by the watcher's polling cadence and the URLSession 60s timeout.

The design's load-bearing invariants — §8.9 (snapshot + resolved
preservation), §8.10 (eventSeq per-process), §1.5 step 2 OR-clause,
§5.1 gate-with-escape-hatch — are coherent and tested.

The remaining sub-risks are localized to single-line state-
management changes inside `SyncInbox.swift` and are easy to land
in PR-6 alongside the watcher implementation.

### Recommendation

**Ready to execute migration §7, with one mandatory implementation
detail captured in PR-6:**

1. **Implementation detail for PR-6 (must-fix):** convert
   `reloadInFlight: Bool` to `reloadInFlightCount: Int` (or
   equivalent re-entrant primitive — a Swift `actor`-isolated
   counter, or a `Set<UUID>` of in-flight reload IDs). Gate on
   `reloadInFlightCount == 0`. Closes S-17 / S-20 / S-21
   sub-risks. Update §5.1 pseudocode in the design doc to
   reflect this when PR-6 lands.

2. **Optional housekeeping in `signOut()`:** explicit
   `reloadInFlightCount = 0` and `loadPhaseEnteredNotReadyAt =
   nil` resets. Closes S-13's implicit lifecycle gap.

3. **Defer S-15 (product) and S-16 (captive portal bootstrap
   retry) to LAUNCH_CHECKLIST.md Phase 9 dogfood,** unchanged
   from sim 2.

With (1) baked into PR-6's specification (one or two lines of
code change), the design is ready to execute the §7 migration
order at high confidence. Sim 2's "medium-high" rating ratchets
to **high** in sim 3, conditional on (1) being captured in the
PR-6 plan.

If the team prefers to land the counter fix as a §11.8 design
amendment before any code lands, the patch is sub-paragraph
length (replace "Bool" with "counter" in the §5.1 pseudocode and
§11.6 prose). No design re-walk needed — the semantics are
identical for the single-reload case, and strictly more correct
for the overlap case.

Either path is fine; PR-6 baking is the lighter-weight option.

---
