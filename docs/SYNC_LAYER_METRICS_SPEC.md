# Sync Layer Metrics Spec — 2026-05-13

Companion to:
- `docs/SYNC_LAYER_AUDIT_2026-05-13.md` (what broke)
- `docs/SYNC_LAYER_DESIGN_2026-05-13.md` (the patched design,
  including §11.1–§11.8)
- `docs/SYNC_LAYER_DESIGN_GOLDENSET_SIM_2026-05-13.md` (sim 1)
- `docs/SYNC_LAYER_DESIGN_GOLDENSET_SIM_2_2026-05-13.md` (sim 2)
- `docs/SYNC_LAYER_DESIGN_GOLDENSET_SIM_3_2026-05-13.md` (sim 3)

Purpose. Three rounds of paper simulation produced a "high
confidence" verdict, but that's qualitative. This spec replaces
that adjective with numbers: every claim about "design readiness"
must map to a measurable threshold, computed from the documents
above, that an engineer can re-derive in 10 minutes. The intended
audience is a future Steer engineer who needs to decide "is this
design ready for PR-1?" without having to re-read the entire
design + audit + sim trio.

Two halves: §A build-time metrics computed today from the docs;
§B runtime metrics deferred to post-launch instrumentation. §C is
the decision rule that flips "ready to start PR-1" from yes to
no based on those numbers, with no editorial judgement required.
§D is the honest list of things that resist measurement.

The companion scorecard is
`docs/SYNC_LAYER_METRICS_SCORECARD_2026-05-13.md` — that file
applies §A's thresholds to the trajectory across sims 1 → 2 → 3
and current design, and ends with the Y/N gating verdict.

---

## §A. Build-time / paper metrics

Each metric below has the same shape:

- **Definition** — one sentence.
- **Measurement** — what to count, where to find it.
- **Target** — the threshold that must be met before PR-1
  starts.
- **Current value** — computed from existing docs at HEAD
  (`b737db8` / `launch-candidate-2026-05-13`).
- **Failure mode** — what regression risk we carry if the
  metric is below target.

### A.1. Race coverage

- **Definition.** Fraction of the §2 race-matrix cells (§2.A
  through §2.H) that has at least one PR-1-planned test
  reproducing it.
- **Measurement.** Count §2 sub-sections that name a distinct
  race scenario (§2.G is a tie-breaker summary, not a race;
  exclude). For each, scan
  `docs/SYNC_LAYER_DESIGN_2026-05-13.md` §7's PR-1 test list
  for a one-to-one match. `XCTSkip` until a later PR is
  acceptable — the test still locks the spec, it just can't
  exercise production code that doesn't exist yet. Count any
  skip as covered.
- **Target.** ≥ 100% (7 of 7 cells).
- **Current value.** 100% (7/7).
  Mapping computed at design HEAD:
  | Race | PR-1 test |
  |---|---|
  | §2.A GET vs WS updatedAt | `test_get_then_ws_widerUpdatedAtWins` + `test_ws_then_get_doesNotDowngrade` |
  | §2.B GET arrives after concurrent upsert | `test_get_doesNotClobberCardWrittenDuringFlight` (will FAIL on today's code; that is the spec-locking purpose) |
  | §2.C user-reply vs stale upsert | `test_userReplied_thenStaleUpsert_keepsAwaitingResponse` + `test_userReplied_thenResponseUpsert_promotes` |
  | §2.D timeout vs late response | `test_timeout_thenLateResponse_promotesThroughFailed` (XCTSkip until PR-6) |
  | §2.E concurrent reply + promotion | `test_concurrent_replyAndPromotion_byCardId` |
  | §2.F out-of-order revisions | `test_outOfOrder_revisions_useMax` |
  | §2.H race-we-accept | `test_snapshot_preReplyCardDoesNotDowngrade` |
- **Failure mode if below target.** A race not covered by a
  test is a race the design only proves works on paper. The
  audit's R-4 / R-5 / R-6 / R-7c regression cascade came from
  exactly this: races that were "discussed in code comments"
  but had no automated reproduction. New races land as user-
  visible regressions.

### A.2. Invariant coverage

- **Definition.** Fraction of the §8 invariants (§8.1 through
  §8.10) locked by at least one existing test or one PR-1- /
  PR-2- / … / PR-6-planned test.
- **Measurement.** Each §8 sub-section names the invariant
  and lists a test (existing) or proposes one (new). Count
  invariant-test pairs where the test is either already in
  tree (verified by `find` against the repo) or named in §7's
  PR plans.
- **Target.** ≥ 100% (10 of 10 invariants).
- **Current value.** 100% (10/10).
  Computed mapping:
  | Invariant | Test (existing or planned) | Owner |
  |---|---|---|
  | §8.1 `card_id == card-${sessionId}` | `packages/relay/test/store_upsert_dedupe.test.ts` | exists (664518c) |
  | §8.2 one active card per session | `packages/agent/test/classifier.test.js` | exists |
  | §8.3 `responseRevision` monotonic | `packages/agent/test/instruction_response_revision.test.js` | exists-or-add |
  | §8.4 single SQLite writer | `packages/agent/test/lockfile.test.js` | exists |
  | §8.5 WS payload contract | `test_wsMessage_cardUpsert_roundTrip` | proposed |
  | §8.6 `becameActive` APNS gate | `packages/relay/test/store_upsert_dedupe.test.ts` | exists (664518c) |
  | §8.7 Mac idempotent re-publish | `CardReconcilerTests` + `test_persistence_loadedBaseline_matchesInMemorySteadyState` | exists + PR-5 |
  | §8.8 `pendingReplies` projection stable | `test_pendingReplies_projection_unchangedAcrossReducerVersions` | PR-3 |
  | §8.9 `.resolved` + `.snapshot` preservation | `test_resolved_preservesAwaitingResponse`, `test_resolved_dropsAwaitingUserAndFailed`, `test_resolved_then_no_upsert_triggers_10min_timeout`, `test_snapshot_preservesAwaitingResponseForResolvedSession`, `test_snapshot_dropsAwaitingResponseAfterTimeoutWindowExpired`, `test_watcher_defersWhileTwoReloadsOverlap` | PR-1 + PR-6 |
  | §8.10 `eventSeq` never on wire | `test_eventSeq_neverSerializedToWire` | PR-2 |
- **Failure mode if below target.** An unlocked invariant is
  one a future refactor can violate without CI noticing. F-6
  in the audit ("card_id == card-${sessionId}" was a contract
  documented only in source comments) cost a full day of
  debugging R-10.

### A.3. Scenario PASS rate (sim 3 results)

- **Definition.** Fraction of golden-set scenarios that walk
  end-to-end through the reducer without surfacing a FAIL or
  a PASS-WITH-RISK / RISK verdict, against the most recent
  simulation run.
- **Measurement.** Read sim 3's summary table. Compute
  `PASS / (PASS + PASS-WITH-RISK + RISK + FAIL)`.
- **Target.** ≥ 70% PASS rate. Three sub-rules: FAIL = 0
  (see A.4 below); any RISK that maps to a one-line fix
  must have that fix scheduled in PR-1 through PR-6; new
  RISKs introduced by patches between sims must trend down
  (sim 3 introduced 1 RISK, sims 1+2 closed 1 FAIL + 3 RISK,
  net trend is correct).
- **Current value.** 71% (15 PASS / 21 total).
  Sim 3 breakdown:
  | Verdict | Count | Scenarios |
  |---|---|---|
  | PASS | 15 | S-1, S-2, S-3, S-4 (all sub-cases), S-5, S-6, S-7, S-8, S-9, S-10, S-11, S-12, S-14, S-18, S-19 |
  | PASS-WITH-RISK | 5 | S-13, S-15, S-16, S-17, S-21 |
  | RISK | 1 | S-20 |
  | FAIL | 0 | — |
- **Failure mode if below target.** The simulations are the
  only place asymmetric paths (cold-launch vs warm-foreground
  vs in-foreground reconnect) get walked side-by-side. A drop
  below 70% means at least one common scenario is unhandled
  on paper; PR-1's race-matrix tests can't cover what isn't
  in the design.

### A.4. FAIL count

- **Definition.** Number of golden-set scenarios at sim 3
  whose verdict was FAIL (silent user-visible loss with no
  one-line patch).
- **Measurement.** Sim 3 summary table, "FAIL" row.
- **Target.** = 0.
- **Current value.** 0.
- **Failure mode if below target.** A FAIL is a known-broken
  scenario the user will hit. PR-1 ships the regression test
  that documents it but cannot fix it; the team is then
  obligated to publish a patch design BEFORE PR-3 lands. A
  single FAIL on launch is a single broken golden-set item,
  which under the QA rule (the user owns the golden set; I
  own all technical validation) means the launch can't
  pass.

### A.5. Single-funnel violations (iOS)

- **Definition.** Number of places in current production code
  that mutate `sessions: [SessionEntry]` outside the funnel
  `SyncInbox.setSessions(_:)`.
- **Measurement.** Grep
  `apps/ios/SteerIOS/SyncInbox.swift` for `sessions =` and
  `sessions.append`. Count occurrences NOT inside `setSessions`.
- **Target.** = 0 (single funnel — audit Rule 4).
- **Current value.** 0. The only assignment to `sessions` is
  at `SyncInbox.swift:643` (`sessions = next`), which IS the
  body of `setSessions`. No `sessions.append`, no
  `sessions.remove`, no `sessions.insert` outside the funnel.
- **Failure mode if below target.** Audit F-1 is exactly this
  fragility class. R-1 (chip vs card-array desync) cost an
  hour of debugging; the root cause was two `@Published`
  arrays being mutated by three call sites. Each extra
  mutation point doubles the surface area for an asymmetric
  bug.

### A.6. Reducer entry-point count

- **Definition.** Number of public functions on
  `SessionEntryStore` that take and return a `[SessionEntry]`
  (the mutating reducer surface). Excludes derived-view
  helpers (`awaitingUserEntries`, `awaitingResponseEntries`,
  `failedEntries`) — those project rather than mutate.
- **Measurement.** Grep
  `packages/SteerCore/Sources/SteerCore/SessionEntryStore.swift`
  for `public static func` whose return type is `[SessionEntry]`.
- **Target (baseline; tracked, not gated).** 1 (after
  PR-3 / PR-7 land). Today's count is the **baseline** PR-3
  is graded against; the gate for PR-1 is that the
  consolidation is **planned**, not yet executed.
- **Current value.** 6 mutating entry points
  (`applyBootstrap`, `onCardUpsert`, `onCardResolved`,
  `markUserReplied`, `markReplyFailed`, `cancelFailedReply`) +
  3 derived views (excluded). Design §1.2 explicitly enumerates
  these as the surface that `apply(...)` replaces.
- **Failure mode if below target after PR-7.** Asymmetric
  reducer paths (audit F-4) are the single most expensive
  regression class in the audit window (R-7c → R-8 in 8
  minutes). Two paths handling "server says here's a card"
  through different rules is what produced both.

### A.7. Patch round count

- **Definition.** Number of post-simulation patch sets
  appended to the design (§11.x sections). More rounds is not
  inherently good or bad — three rounds of cohesive closure is
  thorough; three rounds of conflicting patches is thrashing.
  This metric tracks process health, not design correctness.
- **Measurement.** Count `§11.N` sub-sections in
  `docs/SYNC_LAYER_DESIGN_2026-05-13.md`.
- **Target.** Tracked, not gated. Soft alert if the count
  exceeds 5 (a fourth simulation introducing more than one new
  FAIL would be a thrash signal).
- **Current value.** 8 patches across 3 rounds (§11.1 / §11.2 /
  §11.3 / §11.4 from sim 1; §11.5 / §11.6 / §11.7 from sim 2;
  §11.8 from sim 3). Patches are net additive: sims 2 and 3
  each closed every FAIL the prior sim found and surfaced
  exactly one new manageable risk. Trend is convergent.
- **Failure mode if below target.** N/A — informational. If
  the count climbs past 5 with new FAILs each round, that's
  the signal to pause and ask whether the design's foundation
  needs revisiting rather than incrementally patching.

### A.8. Test → assertion ratio (PR-1 plan)

- **Definition.** Across the PR-1 race-matrix test file, the
  ratio of `XCTAssert*` calls to `func test_*` functions.
  Tests with zero assertions are vapor coverage — they execute
  the production path but cannot fail.
- **Measurement.** Read the PR-1 test list in
  `docs/SYNC_LAYER_DESIGN_2026-05-13.md` §7. Each test should
  have at least 1 `XCTAssertEqual` / `XCTAssertTrue` /
  `XCTAssertEqual(state, expected)` call. Spec-locking tests
  for races that won't pass until later PRs (e.g. §2.D before
  PR-6) should `XCTSkip` rather than empty-pass; an
  `XCTSkip` counts as one "assertion" for purposes of this
  metric — it explicitly documents the spec-vs-reality gap.
- **Target.** ≥ 2 assertions per test on average.
- **Current value (planned).** 9 PR-1 tests, design names
  state-equality assertions in each (`assertEqual` against
  expected state) + at least one stage check + an
  `XCTUnwrap` per test. Planned ratio is ~2-3 assertions per
  test. Existing comparable tests
  (`SessionEntryStoreTests.swift`: 16 tests / 44 assertions =
  2.75) confirm the convention is upheld in tree.
- **Failure mode if below target.** A test that runs but
  asserts nothing is a green light masking a regression. The
  audit's lesson from F-8 is the integration test that DIDN'T
  exist would have caught half the cascade; the corollary is
  a vapor-coverage test that DOES exist provides false
  comfort.

### A.9. Cycle time to PR-1-ready

- **Definition.** Wall-clock duration from "design doc first
  drafted" (the first commit of
  `docs/SYNC_LAYER_DESIGN_2026-05-13.md`) to "metric
  thresholds met" (this spec's first PASS verdict on the
  scorecard). Tracks design-process health, not code
  health.
- **Measurement.** Compare git timestamps. Both files live
  in `docs/`; this is two `git log -- <file>` calls.
- **Target.** ≤ 3 days. The audit's regression cascade was
  10 hours of code chaos; the design plus simulations are
  the deliberate counter-investment. More than three days
  indicates the simulations are surfacing fundamental
  issues rather than gaps.
- **Current value.** Same day. Design doc dated 2026-05-13;
  this metric spec also dated 2026-05-13. Three simulation
  rounds + 8 patches landed within the same day, which is
  itself a process-health signal that each simulation
  converged.
- **Failure mode if below target.** Faster than threshold is
  a positive signal; slower triggers an audit of whether the
  design's foundation should be revisited.

### A.10. Open-question count

- **Definition.** Number of items in §9 of the design ("What
  this doc does NOT cover") that remain unanswered.
- **Measurement.** Count §9.N sub-sections in
  `docs/SYNC_LAYER_DESIGN_2026-05-13.md`.
- **Target.** ≤ 5. Hard cap; more than five "intentional
  punts" means the design is under-scoped for what it
  promises to ship.
- **Current value.** 8 (§9.1 iPad multi-window, §9.2 Apple
  Sign-In re-auth race, §9.3 APNS deep-link race, §9.4 v3
  event log, §9.5 Mac WS handler, §9.6 wrapper-side ack,
  §9.7 test-clock injection, §9.8 server-side eventSeq).
- **Failure mode if below target.** EXCEEDS today. Of the
  eight open questions, several should be either resolved or
  formally scoped out before PR-1 starts. Action: triage §9
  in the scorecard's "minimum additional patches required"
  list — the items that don't affect PR-1 through PR-6 (§9.2,
  §9.4, §9.5, §9.6, §9.7, §9.8) should be moved to a separate
  "post-v1 follow-up" doc; the items that DO affect a planned
  PR (§9.1 iPad, §9.3 deep-link) should be either resolved or
  explicitly deferred with a follow-up ticket.

---

## §B. Runtime metrics (post-launch telemetry)

Same shape as §A: definition, measurement, threshold, current
value, failure mode. All §B metrics are **not instrumented yet**
at HEAD `b737db8` — the entire metrics layer is a v1.1 follow-up
captured in §C as "must be instrumented before v1.1 closes."

A minimum-viable instrumentation proposal follows §B.8.

### B.1. WS uptime % (24-hour rolling)

- **Definition.** Percentage of 24-hour wall-clock window
  during which an iPhone (foreground OR backgrounded with a
  live WS) maintained a connected WebSocket frame stream
  (i.e. `lastFrameReceivedAt` within last 60 s, the §6.2
  watchdog threshold). Computed per-device, p50 across all
  active devices in the v1 cohort.
- **Measurement.** Each ping cycle (every 20 s) appends a
  `frame_received_ok: bool` row to a sidecar log. Daily
  cron rolls up `sum(ok=true) / sum(ok=true) + sum(ok=false)`
  per device, then takes the median across devices.
- **Target.** ≥ 95% p50.
- **Current value.** Not instrumented yet.
- **Failure mode if below target.** WS is the design's
  primary card-delivery channel; APNS + `scenePhase.active`
  + GET is the safety net. Below 95% means the safety net is
  doing real work, which hides regressions in the WS path.
  Audit R-6 / R-7a is exactly this — a year-long silent
  decline in WS uptime that wasn't visible because APNS was
  covering the gap.

### B.2. WS reconnect latency p50/p99

- **Definition.** Time from a `URLSessionWebSocketTask` close
  event (intentional cancel OR error throw from receiveLoop)
  to the first received frame on the next successfully
  connected task. Includes backoff sleep + handshake RTT.
  Measured per-event, aggregated daily.
- **Measurement.** On every `receiveLoop` catch arm, stamp
  `lastCloseAt`. On every successful first-frame receive,
  log `(now - lastCloseAt, attemptCounter)` to a JSON sidecar.
  Roll up p50/p99 nightly.
- **Target.** p50 ≤ 2 s, p99 ≤ 30 s (matches `WSReconnectBackoff`
  cap of 30 s).
- **Current value.** Not instrumented yet. Backoff cadence
  is 1, 2, 4, 8, 16, 30 s with ±20% jitter
  (`WSReconnectBackoff.swift`), so the design intends p99 to
  hit the 30 s cap and no higher.
- **Failure mode if below target.** A p99 above 30 s means
  backoff is escalating beyond design — likely a captive
  portal or a relay-side rejection loop. Without this
  metric, S-16 / S-19 (captive-portal stuck cases) cannot be
  detected from telemetry; only user complaints surface them.

### B.3. `.awaitingResponse` lifecycle p50/p99/max

- **Definition.** Time an entry spends in
  `.awaitingResponse` stage between `markUserReplied` and the
  next transition (promotion to `.awaitingUser`, decay to
  `.failed`, or drop). Distribution per entry, aggregated per
  user per day.
- **Measurement.** On every reducer event, if the entry's
  stage transitions FROM `.awaitingResponse`, log
  `(now - stampedAt, transitionedTo)`. Roll up p50/p99/max
  daily.
- **Target.** p50 ≤ 10 s (the codex response RTT user
  expectation); p99 ≤ 60 s; max ≤ 600 s (the §5.1 timeout).
- **Current value.** Not instrumented yet.
- **Failure mode if below target.** A p99 ≥ 60 s implies
  the Mac wrapper is queuing instructions for ≥ 1 minute,
  which is either a usability complaint or a Mac-side bug.
  A p99 ≥ 600 s means timeouts are firing more often than
  responses — the safety net is the user's experience, not
  the safety net.

### B.4. Stuck entries (`.awaitingResponse` > 10 min) count

- **Definition.** Number of entries that DID reach the §5.1
  10-minute decay (transitioned to `.failed("response
  timeout")` via the watcher rather than via response upsert
  promotion). Counted per user per day.
- **Measurement.** Increment a counter whenever the reducer
  applies `.awaitingResponseTimeout` to an entry that was
  still `.awaitingResponse` at fire-time.
- **Target.** ≤ 1% of `.userReplied` events per day.
- **Current value.** Not instrumented yet (the watcher
  itself doesn't exist yet — lands in PR-6).
- **Failure mode if below target.** A high stuck-rate means
  the timeout is the dominant card-completion path, which
  inverts the design's intent. The user sees retry banners
  more often than responses; trust in the system erodes.

### B.5. Card delivery latency p50/p99

- **Definition.** Time from Mac SQLite write of a new
  `action_cards` row (the agent's `refreshActionCard` write at
  `store.js:L409`) to the iPhone reducer applying a
  corresponding `.snapshot` or `.upsert` event. End-to-end
  pipeline latency.
- **Measurement.** Mac stamps `agentWrittenAt = now()` into
  the card payload. iOS subtracts on reducer apply. Log
  `(agentWrittenAt - now, channel: "ws"|"snapshot")`. Roll up
  p50/p99 per channel daily.
- **Target.** p50 ≤ 3 s (Mac funnel 2 s tick + WS RTT); p99
  ≤ 15 s (one APNS round-trip).
- **Current value.** Not instrumented yet.
- **Failure mode if below target.** A p99 ≥ 15 s indicates
  WS push is unreliable and APNS is doing more work than
  designed — same hidden-decline issue as B.1.

### B.6. Push delivery rate

- **Definition.** Of APNS fanout attempts with `ok=true`
  return from `api.push.apple.com`, the fraction over the
  fanout-target device count. (How many of the iOS devices
  the relay tried to notify accepted the push.)
- **Measurement.** `packages/relay/src/apns.ts` already
  knows ok=true/false per send; record per-fanout-event
  `(targetCount, okCount)` to D1 or sidecar log. Aggregate
  daily.
- **Target.** ≥ 99% (one Apple-side failure per 100 sends
  is the documented ceiling for healthy APNS connections).
- **Current value.** Not instrumented yet. Relay's
  `apns.ts` logs individual sends but doesn't aggregate.
- **Failure mode if below target.** APNS errors compounding
  silently is invisible without aggregation. The R-9 fix
  (`badge: 1`) shipped without a way to confirm the badge
  was actually being sent in production — the JWT could
  expire, the cert could rotate, the silent-mode flag could
  flip; we'd find out from user complaints, not metrics.

### B.7. `.failed("response timeout")` decays per day

- **Definition.** Daily count of reducer transitions to
  `.failed` via `.awaitingResponseTimeout` (the §5.1 watcher
  firing), per user. Distinct from `.failed` via POST
  failure (different reason string).
- **Measurement.** Sub-counter of B.4. Log only the timeout-
  reason `.failed` transitions, filter on `reason ==
  "response timeout — your reply may not have been
  delivered"`.
- **Target.** ≤ 0.5 per user per day on average. Higher
  signals the wrapper-die scenario (S-4 Case B) is firing
  more often than the design expects.
- **Current value.** Not instrumented yet.
- **Failure mode if below target.** A spike in timeout-
  decays is a leading indicator for Mac-side wrapper
  instability or for an unhealthy network path that the GET
  isn't catching. Without this metric, we'd see the symptom
  ("user complaints about not knowing if reply landed") but
  not the trend.

### B.8. Reload-fired-card-missed-by-WS rate

- **Definition.** Number of times an iPhone `reload()`
  surfaces a card whose `cardId` was not previously seen
  via WS in the same session. A measure of how often the
  WS-only path is insufficient and the GET backfill (§6.5 or
  `scenePhase.active`) is doing real work.
- **Measurement.** iOS maintains a per-session set of
  `cardIds-seen-via-WS`. On every `.snapshot` apply, count
  cards not in that set. Log per `reload()` event.
- **Target.** ≤ 5% of reload calls. Below 5% means WS is
  delivering reliably; the GET is verifying, not replacing.
- **Current value.** Not instrumented yet.
- **Failure mode if below target.** A high rate is the same
  signal as B.1 / B.5 — WS is silently degrading and the
  safety net is masking it. This is the metric that would
  have caught R-7a five days earlier.

### Minimum-viable instrumentation

The simplest plumbing that produces B.1–B.8 without breaking
the v1 ship-before-instrument cadence:

- **Per-device JSON sidecar log**:
  `~/Library/Application Support/Steer/sync-metrics-YYYYMMDD.log`
  on iOS (or `~/.steer/sync-metrics-YYYYMMDD.log` on Mac).
  Append-only newline-delimited JSON. One event per line.
  Schema:

  ```json
  {
    "ts": 1747156800000,
    "kind": "ws_frame_received" | "ws_close" | "ws_reconnect_complete"
          | "entry_transition" | "reload_complete" | "apns_fanout"
          | "timeout_decay",
    "deviceId": "<sha256 of did claim>",
    "fields": { ... per-kind body ... }
  }
  ```

- **Daily rollup**: a `steer stats --sync` command (the CLI
  already prints `steer stats` per
  `packages/cli/src/index.js:901`) walks the day's log,
  computes B.1–B.8, prints a human-readable summary.

- **Opt-in upload**: an explicit Settings toggle "Help
  improve Steer (anonymized sync metrics)" with default OFF;
  when ON, the daily rollup is POSTed to a relay endpoint
  that stores in D1. Same posture as the rest of v1: no
  data leaves the device without an explicit user toggle
  (cited in `EXECUTION_PLAN.md` Operating Rules).

- **What `steer stats --sync` would print**:

  ```
  Steer Sync Metrics — 2026-05-13

  WebSocket
    Uptime (24h): 97.3%
    Reconnect p50/p99: 1.2s / 4.8s

  Card delivery
    Mac→iPhone p50/p99: 1.8s / 9.1s
    WS-only:  94%   (B.8: 6% required GET backfill)

  AwaitingResponse lifecycle
    p50: 4.3s    p99: 21.7s    max: 612s (1 timeout)
    Stuck >10min: 1 / 47 replies (2.1%)

  APNS
    Fanout success: 99.4%
    Timeout decays: 1
  ```

  One screen. No dashboard required.

---

## §C. The decision rule

> **PR-1 may start when all build-time metrics §A.1 through
> §A.10 meet their target. Runtime metrics §B.1 through §B.8
> must be instrumented before v1.1 closes.**

In plain language: PR-1 doesn't ship if a single §A metric is
below target — there are no editorial overrides. The scorecard
in `SYNC_LAYER_METRICS_SCORECARD_2026-05-13.md` is the
mechanical check. If every row in §A is ✅ MET, the gate opens.
If any row is ❌ BELOW, that row's "smallest patch to close it"
column is the work that must land before PR-1.

Runtime metrics are not a launch gate. They are an obligation
on v1.1: the §A metrics let us start PR-1 with confidence; the
§B metrics let us KEEP confidence in production. A v1.1 that
ships without §B instrumentation is one user incident away from
flying blind on the very regressions §A was designed to catch.

The two halves work together:

1. §A says "the design is internally consistent enough to start
   coding." It catches paper-stage gaps.
2. §B says "the deployed system is behaving the way the design
   promised." It catches production-stage drift.

Without §A, we ship a design we can't validate. Without §B, we
ship a validated design we can't observe. Either gap is a
silent regression waiting for a user to find it. The two-stage
rule closes both.

A future engineer reading this doc applies the rule like this:

- Run the scorecard's checks for §A.1 through §A.10. The
  scorecard is one Markdown file with one table — re-running
  it is 10 minutes of grep + arithmetic.
- If every row says ✅ MET, PR-1 may start. Tag the commit
  `pr1-ready-YYYY-MM-DD` and push the tag (independent of
  whether PR-1 is merged immediately — the tag is the audit
  trail).
- If any row says ❌ BELOW, apply the smallest-patch column.
  Re-check. Loop until every row is ✅. Then tag.

No subjective judgement enters. The two engineers may disagree
on whether the design "feels ready"; they cannot disagree on
whether the seven race tests are named in the plan.

---

## §D. What this doc does NOT cover

Honest list of failure modes that resist measurement. Each
must be evaluated by dogfood — running the build on a real
device and observing the user-visible behaviour against the
golden set.

1. **UX flicker on slow network.** Sim 3 closed the 1-frame
   `.failed` banner flicker via §11.6's `reloadInFlightCount`
   gate. But the watcher itself fires at 30 s cadence; a
   real network with 4G drops to LTE every 8–10 s would
   produce micro-flickers around card-promotion moments that
   no paper simulation can predict. Dogfood: run iOS phone on
   a long subway commute; observe whether chip transitions
   are smooth or staccato.

2. **Banner readability under Focus filter.** The R-9 badge
   fix shipped without verifying that Focus filters (Sleep,
   Work, Do Not Disturb) actually surface the `badge: 1`
   semantic. Apple's documented behaviour says yes; real-
   device behaviour varies by iOS version and per-user
   configuration. Audit §6.3 explicitly defers this. Dogfood:
   set Sleep Focus, reply on Mac, verify badge updates iPhone
   Lock Screen.

3. **User perception of "it feels fast."** S-2's design says
   the round-trip is ≤ 7 s p50; user-perceived "fast" is a
   different threshold (closer to 3 s for chip-clear to feel
   immediate). The metric in B.5 catches the *fact* of
   latency but not the *experience* of it. Dogfood: time a
   reply with a stopwatch and ask "did that feel snappy?"
   before checking the log.

4. **iOS background suspend timing in real-world conditions.**
   Sim trios are paper; iOS jetsam behaviour under battery
   pressure / Low Power mode / lots-of-apps-running is not
   reproducible from code review. Dogfood: lock iPhone for
   30 / 60 / 90 / 120 minutes with the phone in Low Power
   mode + 10 other apps open; verify card delivery on unlock.

5. **APNS delivery under Apple-side outage.** Even at 99%
   APNS success (B.6), a 5-minute Apple status-page outage
   during launch hour produces user-visible "reply landed
   but no banner" reports. Sim doesn't cover Apple-side
   incidents. Dogfood: subscribe to status.apple.com APNS
   incidents and have a manual incident-acknowledgement
   playbook in `docs/INCIDENT_RUNBOOK.md`.

6. **Multi-iPhone / multi-Mac topology under shared Apple
   ID.** S-7 walked one specific case (two iPhones replying
   to the same card); real users have additional permutations
   (iPad in the morning, iPhone in the evening, plus the work
   Mac). Dogfood with 2 iPhones + 2 Macs + 1 iPad: verify
   chip + carousel + badge state across all four during a
   typical day.

7. **Captive-portal recovery experience.** Sim 2 + Sim 3
   close the silent-stuck-watcher case but the bootstrap GET
   itself doesn't retry (S-16). The user's experience between
   "tap network" → "accept captive portal" → "next reload
   fires" depends on whether they happen to background-then-
   foreground or hit pull-to-refresh. Dogfood at a coffee
   shop / hotel.

8. **App-Store-review concerns about runtime telemetry.**
   §B's "opt-in JSON sidecar + relay upload" posture matches
   Steer's existing privacy commitment, but App Store
   reviewers sometimes flag any non-user-initiated network
   call. Dogfood the submission flow with §B turned ON in
   debug only; submit with §B turned OFF as default for
   v1.1's first review pass.

For each of items 1–8, the failure mode is "the build looks
green by metrics but feels wrong to the user." That's the gap
the metrics can't close; the QA rule (user owns the golden
set; I own all technical validation) closes it. The metric
spec is necessary but not sufficient; dogfood is the second
necessary condition.
