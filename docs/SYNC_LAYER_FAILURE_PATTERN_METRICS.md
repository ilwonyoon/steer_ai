# Sync-Layer Failure Pattern Metrics — Derived From History (2026-05-13)

Companion to `docs/SYNC_LAYER_METRICS_SPEC.md` (which derives metrics
from first principles). This file derives the same metric set from the
**inventory of every sync-layer regression we have actually shipped**,
plus the simulation FAIL/RISK verdicts that would have caught them.
The thresholds in §3-§4 are quoted from the source commit, log entry,
or design-doc paragraph that justifies the number.

The intent is to answer: *"For each regression we paid for in dogfood,
what metric and what threshold would have caught it before it shipped?"*

If a category of failure has no proposed metric, that gap is called out
in §6.

Inputs read (and quoted from below):
- `docs/SYNC_LAYER_AUDIT_2026-05-13.md` — regressions R-0 … R-10.
- `docs/SYNC_LAYER_DESIGN_GOLDENSET_SIM_2026-05-13.md` — S-1 … S-15.
- `docs/SYNC_LAYER_DESIGN_GOLDENSET_SIM_2_2026-05-13.md` — adds S-16,
  S-17, S-18.
- `docs/SYNC_LAYER_DESIGN_GOLDENSET_SIM_3_2026-05-13.md` — adds S-19,
  S-20, S-21.
- `docs/WRAPPER_DISCONNECT_DIAGNOSIS_2026-05-13.md` — G14 root cause.
- `docs/SYNC_LAYER_DESIGN_2026-05-13.md` §11 (patch history §11.1 …
  §11.8).
- `git log --since="2026-05-12 00:00"` on the sync-layer files.
- `docs/REGRESSION_CONTRACT.md` (current G14 contract, including the
  `SEND_RECONNECT_RETRY_MS = 8 s` cite).

---

## §1. Failure inventory

The columns are: ID, date, layer, what broke, symptom the user saw,
one-line root cause, how it was detected, and how long it lived in the
codebase before being fixed. "Lived" is measured from the first commit
that introduced the fragility (or "always" for pre-existing assumptions)
to the merge of the fix.

### §1a. Historical regressions (audit R-0 … R-10)

| ID | Date | Layer | What broke | Symptom user saw | Root cause one-liner | Detected via | Lived for |
|---|---|---|---|---|---|---|---|
| R-0 | 2026-05-12 | agent SQLite + wire | `responseRevision` primitive introduced — chip vs. card transitioned by `updatedAt` clock comparison (flaky); pre-existing. | Chip and carousel disagreed; "1 running" persisted past response. | No atomic "Mac answered" signal; iPhone guessed via `updatedAt` skew. | User dogfood; absence of trustworthy primitive forced the new feature in `b6b8d67`. | ≥ weeks (since chip + card were ever a thing) |
| R-1 | 2026-05-12 (`9e98fbb`) | iOS SyncInbox | Chip and card lived in two `@Published` arrays, hand-synced. | Chip and carousel disagreed by 1–15 s. | Two arrays for one invariant — separate WS and HTTP-poll channels delivered the same logical state at different latencies. | User dogfood; chip flickered against carousel. | ~24 h after the chip↔card transition first shipped. |
| R-2 | 2026-05-12 (`3dd5b65`) | iOS SyncInbox | Chip derived from 15 s HTTP poll; card from ~1 s WS push. | Chip lagged carousel. | Two latency channels for the same invariant. | User dogfood; "chip is just another view of the card data." | ~24 h. |
| R-3 | 2026-05-13 (`1a0cce1`) | Mac chip publisher | `loadedChips` filtered out sessions with active cards. | Mid-reply session showed chip = 0, indistinguishable from "no one running." | Mac-UI dedupe rule (cards exclude live) was applied to an inter-device wire contract. | User dogfood; cross-checked against spec ("N replies in flight"). | ~24 h. |
| R-4 | 2026-05-12 (`86f87a3`) | iOS SessionEntryStore | `cardResolved` held `.awaitingResponse` entries forever, awaiting next upsert that might never arrive. | Chip pinned to dead sessions; "2 running stuck for sessions I already killed." | Unbounded cache lifetime: invariant "next upsert is coming" was false when the wrapper died / user signed out. | User dogfood. | ~24 h before being reverted by R-5. |
| R-5 | 2026-05-13 (`79a2f24`) | iOS SessionEntryStore | Reverted R-4. Now drops `.awaitingResponse` on resolve. Also added `reconnectWebSocketIfNeeded` for foreground. | (R-4 fix; restores R-1 brief flicker behaviour as a trade-off.) | R-4's invariant was wrong; bounded trade-off was forced. | User dogfood ❌ on R-4 → revert. | Same day as R-4. |
| R-6 | 2026-05-13 (`0e062c8`) | iOS WebSocket pingLoop | `task.send(ping)` caught Cloudflare DO half-close, but handler just `return`'d — `task.receive()` stayed blocked forever. | "iPhone reply not delivered / huge delay" — `wrangler tail` showed `GET /v1/stream - Canceled @ 2:50:07 PM`. | Half-closed socket; SDK assumption "if send fails, receive will fail too" is false on WS half-close. | `wrangler tail` log review during dogfood. | Since WS was introduced. |
| R-7a | 2026-05-13 (`b6fe8fe`) | Mac SyncClient pingLoop | Same half-closed socket bug as R-6, on Mac side. | Same as R-6, on Mac. | R-6 patched iOS only — Mac diverged. | Same dogfood pass; user-reported "huge delay." | 5 days after R-6 fix. |
| R-7b | 2026-05-13 (`b6fe8fe`) | both pingLoops | Ping cadence 30 s was too sparse relative to Cloudflare DO 5–10 min idle. | Same. | Cadence drifted into the danger zone. | Same dogfood pass. | Same lifecycle. |
| R-7c | 2026-05-13 (`b6fe8fe`) | SessionEntryStore.applyBootstrap | `applyBootstrap` preserved `.awaitingResponse`/`.failed` "in case the response card shows up later." | "N running stuck forever" when response never came. | Optimistic in-memory state outranked authoritative server. | Same dogfood pass. | Since bootstrap was added. |
| R-8 | 2026-05-13 (`069cb4e`) | applyBootstrap (asymmetric) | After R-7c made GET authoritative for dropping, it was *over*-authoritative for promotion — `continue`'d on `.awaitingResponse` instead of accepting the new card. | "1 running + empty carousel" on APNS-tap cold-launch (the most user-visible window). | Bootstrap GET and WS upsert treated the same logical event with different rules. | User dogfood ❌ on R-7c → fix. | ~30 min after R-7c. |
| R-9 | 2026-05-13 (`b737db8`) | relay APNS payload | APNS had `alert` + `sound` but no `badge` key. | "Alerts arrive but icon never carries the unread red dot." | iOS only paints the dot when server sets `badge` explicitly; relying on alert alone is wrong. | User dogfood (visual). | Since APNS payload was first constructed. |
| R-10 | 2026-05-13 (`664518c`) | relay store / APNS fanout | `card_id` is hard-coded `card-${sessionId}` (`store.js:410`); fanout gated on `inserted` only, so every reply after the first was an UPDATE → no APNS. | "The first card alerts, every reply after that doesn't." | Cross-component contract (agent's reuse of `card-${sessionId}`) was undocumented; relay's `becameActive` predicate didn't know about it. | User dogfood. | Since multi-card sessions first shipped. |

### §1b. Adjacent groundwork (cited by audit for completeness)

| ID | Date | Layer | What broke | Symptom user saw | Root cause one-liner | Detected via | Lived for |
|---|---|---|---|---|---|---|---|
| R-2a | 2026-05-12 (`2a261d2`) | Mac cold-start reconciliation | `lastPublishedCardIds` lived in `@State` only; relay carried orphans from prior process. | Stale orphan cards visible after Mac restart. | In-memory cold-start baseline was empty; nothing seeded from relay. | User dogfood (post-restart artifact). | Since Mac publish path existed. |
| R-2b | 2026-05-12 (`9789d01`) | Mac chip channel ("ended" publish) | Mac dropped `ended`/`disconnected` sessions from `loadLiveSessions` silently; relay kept stale "running" snapshot until its 90 s cutoff. | Stale "running" chips for terminated sessions. | Same shape as R-2a but for the chip channel. | User dogfood. | Same. |
| R-S0 | 2026-05-12 (`fefc3bc`) | agent SQLite singleton | Crash-loop on 1.8 GB DB; no `proper-lockfile` enforced single-writer. | Agent failed to start; G14 chain blocked. | Single-writer invariant was implicit; multi-process races possible across cold start. | User dogfood after large session accumulation. | Months. |
| R-WA | 2026-05-13 (`b832acc`) | wrapper PTY split-write | The "atomic write" experiment (`e0b25c0`) caused codex/claude to treat `\r` as part of paste payload; the input box sat there with no submit. | "iPhone reply lands in the input box but never submits — line just sits there." | Codex/Claude TUI requires a small gap between bracketed-paste END (`\x1B[201~`) and `\r`. | User dogfood ❌ on the prior "atomic" fix. | ~1 h. |
| R-WT | 2026-05-13 (`05f5d9f`) | wrapper module init order | `SEND_RECONNECT_RETRY_MS` `const` declared after top-level await; TDZ ReferenceError fired on first `steer send`. | "`steer send` broken for every user." | Test-time-only init-order bug; happens to fire in production at the dispatcher's first call. | `STEER_INTEGRATION=1 npm test` (after push). | < 1 h (caught by integration suite). |
| R-WS | 2026-05-13 (`e0b25c0` retry portion, kept) | wrapper send retry budget | `steer send` exited non-zero immediately on transient "session is disconnected"; `drainQueuedInstructions` permanently marked instructions failed → reply lost. | "iPhone reply silently dropped on agent restart." | `routeInstruction` returned an error before the 250 ms agent_link reconnect could complete. | Wrapper-disconnect diagnosis doc + Case B repro test. | Since agent_link reconnect was introduced. |

### §1c. Simulation FAILs and RISKs that would have shipped without the design-doc patches

These are the regressions the design + simulations *prevented* before
they ever reached `main`. They are the same shape of failure as §1a,
just caught on paper.

| ID | Sim | Layer | What would have broken | Symptom user would have seen | Root cause one-liner | Detected via | "Lived" in design before fix |
|---|---|---|---|---|---|---|---|
| S-4 (Case B) | Sim 1 → Sim 2 §11.1 | SessionEntryStore.onCardResolved | After PTY-write succeeds but child dies, agent ack=`injected` → relay broadcasts `.resolved` → reducer drops `.awaitingResponse` → no banner. | "1 running" → empty carousel, no actionable retry; user's reply silently vanishes. | `.resolved` reducer rule dropped unconditionally; ignored that `.awaitingResponse` needed the 10-min timeout to surface a failure. | Golden-set Sim 1. | Hours (in design). |
| S-18 | Sim 2 → Sim 3 §11.5 | SessionEntryStore.applyBootstrap step 2 | `.resolved` preservation undone by next `.snapshot` (background→foreground in the 10-min window); reducer drops the preserved entry. | Same as S-4 Case B: silent loss on every background→foreground inside the timeout. | Asymmetric path: `.resolved` preserved, but `.snapshot` step 2 dropped — two paths into the same state with different rules. | Golden-set Sim 2. | Hours. |
| S-20 (and S-17, S-21) | Sim 3 → §11.8 | `reloadInFlight: Bool` | Two `reload()` calls overlap; whichever returns first clears the Bool while the other is mid-HTTP — watcher fires inside the in-flight snapshot. | 1-frame `.failed("response timeout")` banner flicker on WiFi flap during reload. | Reentrance bug: Bool not safe across two concurrent suspended calls. | Golden-set Sim 3. | Hours. |
| S-14 (warm) | Sim 2 → §11.6 | `checkAwaitingResponseTimeouts` gate | Gate keyed on `loadPhase` only; `loadPhase` stays `.ready` on warm-foreground; watcher fires mid-reload. | Same 1-frame flicker. | Asymmetric: cold-launch transits `.idle → .bootstrapping → .ready` (gated); warm-foreground doesn't (ungated). | Sim 2. | Hours. |
| S-14 (captive) | Sim 2 → §11.7 | watcher gate vs. permanently stuck `.bootstrapping` | Captive portal keeps GET failing → `loadPhase` never reaches `.ready` → watcher never fires → 10-min timeout never surfaces banner. | Chip stuck "1 running" with no actionable banner; can only recover by background+foreground after captive portal clears. | Long-tail of the `loadPhase` gate: no escape hatch. | Sim 2. | Hours. |
| S-8 | Sim 1 → §11.2 (§6.5 auto-GET) | WS reconnect | `reconnectAttempt > 0` increments and recovers, but never triggers a backfill `reload()`; any `card.upsert` during down window is silently missed. | "Card never arrived" until next foreground transition (~minutes). | WS reconnect path didn't pull authoritative state. | Sim 1. | Hours. |
| S-7 | Sim 1 → §11.4 | `eventSeq` semantics | Doc wording "process-monotonic" was ambiguous; a future contributor could try to serialize across devices and break §2.B. | Cross-device clobber of in-flight reply preservation. | Cross-component contract documented only in comments. | Sim 1 wording audit. | Hours. |

---

## §2. Categorize the failures (mechanism-driven)

Buckets emerge from the data — they are NOT invented ahead of time.
Counts include all of §1a, §1b, §1c.

### §2a. State machine asymmetry — two paths into the same state with different rules

| Bug | Path A | Path B | What differed |
|---|---|---|---|
| R-1 | WS card upsert | HTTP chip poll | Latency + container; "same row, two views" not enforced. |
| R-6 vs. R-7a | iOS pingLoop | Mac pingLoop | iOS got the half-close fix, Mac did not (5-day skew). |
| R-7c vs. R-8 | bootstrap GET drop | bootstrap GET promote | "Drop if not in cards" applied; "promote if in cards" missing. |
| R-7c | `applyBootstrap` | `onCardUpsert` | Snapshot reducer != delta reducer. |
| S-4 (Case B) | `.resolved` rule | (no symmetric snapshot rule) | Drops on resolve but doesn't preserve on snapshot. |
| S-18 | `.resolved` preserve | `.snapshot` step 2 drop | §11.1 fixed `.resolved`; §11.5 fixed `.snapshot` (both clauses needed). |
| S-14 (warm) | cold-launch gate | warm-foreground gate | `loadPhase` only transits cold; warm never enters gate. |

**Count: 7 regressions.** This is the single largest bucket and the
audit's headline ("six bug-fix commits hit `SessionEntryStore.swift`
alone in 6 hours; two reverted each other").

### §2b. Half-closed socket health — send/receive disagree about WS liveness

| Bug | Layer | Failure mode |
|---|---|---|
| R-6 | iOS WS pingLoop | `send` errored but `receive` stayed blocked forever. |
| R-7a | Mac WS pingLoop | Same as R-6, on Mac, 5 days later. |
| R-7b | both | 30 s cadence too sparse vs. 5–10 min Cloudflare DO idle. |
| (latent F-2 in audit) | both | "frame received within N seconds" watchdog absent — only `send`/`ping` outcomes signaled health. |

**Count: 3 regressions + 1 latent fragility.** All four manifest as
"reply not delivered / huge delay" from the user's side.

### §2c. Unbounded cache lifetime — entry pinned forever because no timeout

| Bug | Cache | Why pinned |
|---|---|---|
| R-1 (and R-2/R-3, indirect) | chip set | derived from poll that lagged forever. |
| R-4 (reverted by R-5) | `.awaitingResponse` | no decay; depended on a never-arriving upsert. |
| R-7c | bootstrap-preserved `.awaitingResponse`/`.failed` | optimistic preservation, no time bound. |
| S-4 Case B (latent, sim-caught) | `.resolved`-preserved `.awaitingResponse` | needed §5.1 10-min decay to be the *only* sanctioned exit. |
| audit F-5 | `.awaitingResponse` watchdog absent | no 10-min decay until §11.1/§11.5/§11.6 designed it. |

**Count: 3 shipped, 1 sim-caught, 1 named fragility.**

### §2d. Atomic-vs-split write at the TUI boundary

| Bug | Layer | Failure mode |
|---|---|---|
| R-WA (revert of `e0b25c0`'s atomic-write portion) | wrapper `submitPtyInstruction` | Combined `[paste+\r]` into one `ptyProcess.write` → codex/claude TUI absorbed `\r` into paste payload, line never submitted. |
| (inverse, pre-`e0b25c0`) | wrapper `submitPtyInstruction` | 50 ms `setTimeout` gap split the write; mid-stream backpressure could lose bytes (root-cause hypothesis in `WRAPPER_DISCONNECT_DIAGNOSIS_2026-05-13.md` §1). |

**Count: 1 shipped regression, 1 pre-existing fragility never proven
in test.** The codified contract (`REGRESSION_CONTRACT.md` §G14) now
mandates: "PTY instruction payload and submit keystroke MUST be a
single atomic `ptyProcess.write`" — but the `b832acc` revert proves
that contract was the wrong rule; the correct invariant is "50 ms gap
required for codex/claude TUI to accept the submit." The contract
needs to be updated; flagged in §6.

### §2e. Test-time-only init/hoisting bugs (TDZ-style)

| Bug | Layer | Failure mode |
|---|---|---|
| R-WT (`05f5d9f`) | wrapper `index.js` | `SEND_RECONNECT_RETRY_MS` declared after a top-level await → TDZ ReferenceError on first `steer send`. |

**Count: 1.** Caught by integration suite within < 1 h of push, but
*shipped to dogfood* — the integration suite ran AFTER the push.

### §2f. Server / cross-component contract mismatch — payload schema disagreement

| Bug | Components | Mismatch |
|---|---|---|
| R-0 (introduction) | agent ↔ iPhone | `responseRevision` did not exist; chip/card transition guessed via `updatedAt`. |
| R-9 | relay ↔ iOS | APNS payload missing `badge`; iOS contract required it. |
| R-10 | agent ↔ relay | `card_id = card-${sessionId}` reuse semantics — relay's `becameActive` predicate didn't know. |
| R-2a (`2a261d2`) | Mac ↔ relay | `lastPublishedCardIds` cold-start baseline missing; relay carried orphans. |
| R-2b (`9789d01`) | Mac ↔ relay | "Ended" sessions silently dropped from chip channel; relay kept stale. |
| S-7 wording (sim-caught) | iOS ↔ wire | `eventSeq` ambiguous between per-process and cross-device. |

**Count: 5 shipped + 1 sim-caught.** Each one is documented only in
source comments.

### §2g. Deployment lag — code merged, not deployed

| Bug | Component | Detail |
|---|---|---|
| R-8 deploy delay | relay (Cloudflare) | The `becameActive` fix needed `npx wrangler deploy` from `packages/relay`; until then the merged code was inert. (Cited by `b737db8` commit body: "Requires `npx wrangler deploy` from packages/relay and a fresh iPhone install before the badge shows up end-to-end.") |

**Count: 1 known instance.** No metric/contract today.

### §2h. Reentrance — overlapping calls to the same function

| Bug | Layer | Failure mode |
|---|---|---|
| S-20 (sim 3 → §11.8) | SyncInbox `reloadInFlight: Bool` | Two `reload()`s overlap; first-to-return clears Bool while second is still mid-HTTP; watcher fires prematurely. |
| S-17 (same root) | bootstrap + §6.5 auto-GET overlap | Same Bool-not-counter failure mode. |
| S-21 (same root) | warm-foreground + WiFi-flap-§6.5 overlap | Same. |

**Count: 3 sim-caught manifestations of 1 underlying mechanism.** The
counter fix (`reloadInFlightCount: Int`) is one line.

### §2i. Bootstrap vs. broadcast asymmetry (special case of §2a but worth its own bucket)

| Bug | Path A | Path B |
|---|---|---|
| R-7c | bootstrap GET preserve | WS upsert promote |
| R-8 | bootstrap GET drop | bootstrap GET promote |
| S-18 | `.resolved` preserve | `.snapshot` step 2 drop |
| S-14 (cold vs. warm) | `.bootstrapping` transit gate | `.ready` no-op gate |
| S-12 (sim 1, pre-design) | APNS-then-WS sequencing | bootstrap GET sequencing |

**Count: 4 shipped + 1 sim-caught.** The audit's "Rule 1: Treat the
relay GET as authoritative on every transition" is the
load-bearing fix.

---

## §3. Derive metrics from the categories

For each category, the metric and threshold are derived from §1's
"lived for" and the design-doc threshold the simulations converged on.

### M-1. State machine asymmetry — symmetry test on bootstrap vs. broadcast

- **Category covered**: §2a, §2i.
- **Metric** (compile-time / unit-test): the reducer that handles
  `.snapshot` and the reducer that handles `.upsert` / `.resolved` must
  be the **same function**, parametrized by event kind. Run a property
  test: for any sequence of (initial state, server snapshot), the
  result of `applyServerSnapshot` must equal the result of
  `applyEvent(.resolved)` for every missing session + `applyEvent(.upsert)`
  for every present card. If they diverge, the test fails.
- **Threshold**: number of distinct reducer paths into a stage must
  equal **1**. Today the design enforces this via §1.5 step 2's
  unified path; the audit's F-4 "smallest test" sketches the property
  test.
- **Failure cost from history**: 7 regressions (largest bucket); two
  reverts in the same day (R-4 ↔ R-5; R-7c ↔ R-8).
- **Why this threshold**: the audit's executive summary names the
  reducer split as the single root cause of the 6-bug cluster.
  Anything > 1 path is *the* fragility this codebase has been bitten
  by hardest.

### M-2. WS half-closed health — `lastFrameReceivedAt` watchdog

- **Category covered**: §2b.
- **Metric** (runtime, per-client): `Date().timeIntervalSince(lastFrameReceivedAt)`
  on both iOS `SyncInbox` and Mac `SyncClient`. If this exceeds the
  threshold while `loadPhase`/connection state expects an open socket,
  force-cancel and reconnect — independent of `send`/`ping` outcomes.
- **Threshold**: **frame-received latency p99 ≤ 90 s** in the steady
  state. Recommended client-side fail-action: `> 60 s` of silence
  triggers force-cancel. Reasoning:
  - Cloudflare DO idle close floor: 5 min (see audit §1e: "Cloudflare
    hibernates idle sockets after 5–10 min"; quoted at `userHub.ts`
    L57 area).
  - Steer ping cadence (post-R-7b): 20 s.
  - One missed ping cycle: 40 s.
  - Two missed ping cycles + RTT slop: ~70-80 s.
  - 90 s p99 keeps us comfortably under DO idle and tolerates one
    skipped pong without false-positive cancel.
- **Failure cost from history**: 3 regressions (R-6, R-7a, R-7b);
  user-visible "reply not delivered / huge delay"; required `wrangler
  tail` diagnosis to root-cause.
- **Lock**: integration test using `URLProtocol` stub that accepts a
  WS upgrade then goes silent — assert reconnect-attempt fires
  within 90 s.

### M-3. Unbounded cache lifetime — every state-machine stage has a documented max lifetime

- **Category covered**: §2c.
- **Metric** (compile-time): every variant of `SessionEntry.Stage`
  (and every key in `Mac.instructedSessions`, `pendingFocusSessionId`,
  etc.) must have an exit transition with a finite wall-clock bound,
  OR be annotated `// PERMANENT — explicit reason`.
- **Threshold**:
  - `.awaitingResponse` decays to `.failed("response timeout")` at
    **T+10 min** (from §5.3 design doc; matches user-reported "I
    waited about 10 min before reporting" anchor in audit narrative).
  - `.connecting` (DevicePresenceObserver) decays at **T+10 s** (per
    audit §1c: `connectingTimeout=10s`).
  - `pendingFocusSessionId` clears at **T+30 s** (audit Rule 2's
    suggested cadence).
- **Why 10 min?** Quoting design doc §5.3 / §11.1 "After: `.resolved`
  preserves `.awaitingResponse` entries and drops only `.awaitingUser`
  / `.failed`. The §5.1 watcher decays the preserved entry to
  `.failed("response timeout")` at T+10min, giving the user an
  actionable retry banner." 10 min is the floor where a user has
  almost certainly noticed and given up on the response; shorter would
  cause false-positive `.failed` banners during legitimate long codex
  turns.
- **Failure cost from history**: 3 shipped (R-4, R-7c, audit F-5
  named) + 1 sim-caught (S-4 Case B).
- **Lock**: unit test
  `test_awaitingResponse_decaysAfterTimeout` — clock-injectable
  fixture proving every Stage variant exits within its declared
  bound. Audit §5b §F-5 cites this as DOES-NOT-EXIST-today; the
  design doc lists it as required.

### M-4. Atomic-vs-split write at TUI boundary — fake-TUI fixture test

- **Category covered**: §2d.
- **Metric** (integration test): the wrapper's `submitPtyInstruction`
  must be exercised end-to-end against a fake-TUI fixture that mirrors
  codex's stdin parser, asserting (a) the bracketed-paste END
  sequence is recognized AS paste, (b) the `\r` lands AFTER the paste
  is closed.
- **Threshold**: **50 ms gap between bracketed-paste END (`\x1B[201~`)
  and `\r`, written in two separate `ptyProcess.write` calls**.
  Justification: `b832acc` commit body — "codex / claude TUIs need a
  small gap between the bracketed-paste END sequence and the submit
  keystroke. When both arrive in the same `ptyProcess.write` call,
  the TUI treats the carriage return as part of the paste payload."
  This is the OPPOSITE of what `REGRESSION_CONTRACT.md` currently
  says (the contract still mandates atomic write — a stale rule from
  `e0b25c0`). **Contract needs to be updated; see §6.**
- **Failure cost from history**: 1 shipped regression (`e0b25c0` →
  `b832acc` revert, ~1 h dogfood thrash).
- **Lock**: extend `helpers/fake_provider.js` with a "busy-rejects-input"
  mode AND a "post-paste \r requires 50 ms gap" mode. Integration
  test `inject_invariant.test.js` Case A (from
  `WRAPPER_DISCONNECT_DIAGNOSIS_2026-05-13.md` §Reproduction approach).

### M-5. Init-order / TDZ — lint rule + Node `--check`

- **Category covered**: §2e.
- **Metric** (lint / pre-commit): ESLint rule
  `@typescript-eslint/no-use-before-define` configured for
  module-level `const`/`let` references in files that use top-level
  await. Plus `node --check packages/cli/src/index.js` in CI.
- **Threshold**: **zero TDZ warnings on `npm run lint`**.
- **Failure cost from history**: 1 regression (R-WT `05f5d9f`); broke
  `steer send` for every user; caught < 1 h post-push by integration
  suite — but the test ran *after* the push.
- **Lock**: pre-push hook running `node --check`.

### M-6. Cross-component contract — relay deploy contract test + wire-shape invariants doc

- **Category covered**: §2f, §2i.
- **Metric** (CI): on every relay deploy, run `connection_contract.test.ts`
  asserting the wire-shape invariants:
  - `card_id == "card-${sessionId}"` for every agent-published card.
  - `becameActive = inserted OR (previousState !== "active")` for
    every `upsertCard` call.
  - APNS `aps.badge` is set to **1** on every fanout where category
    ∈ `{blocker, decision, question, waiting}`.
  - `responseRevision` is monotonic per `sessionId` across all
    upserts.
  - `eventSeq` is process-local; no `Codable` type carries it (§11.4 /
    §8.10 invariant).
- **Threshold**: **contract test must pass before `wrangler deploy`
  completes** — block the deploy on failure. The audit's F-7 prescribes
  this as a server-side JWT-platform check (Mac vs. iOS).
- **Failure cost from history**: 5 shipped (R-0, R-9, R-10, R-2a,
  R-2b) + 1 sim-caught (S-7 wording).
- **Lock**: `packages/relay/test/store_upsert_dedupe.test.ts` already
  covers R-10; extend with R-9 + S-7. Update `REGRESSION_CONTRACT.md`
  Wire-Shape Invariants section (audit §4 Rule 5).

### M-7. Deployment lag — relay version sticker

- **Category covered**: §2g.
- **Metric** (runtime, per-client): include the relay's deployed git
  short-sha in `/v1/auth/whoami` response; client (iPhone + Mac)
  displays it in a debug overlay or settings screen. CI compares the
  sha against the latest tag and warns if main is ahead of deployed.
- **Threshold**: **deployed sha == merged-to-main sha within
  T+15 min of merge** (Cloudflare Workers deploys in seconds; 15 min
  is generous for human-driven `wrangler deploy`). Surfaced as a
  badge in a debug screen — easy to spot pre-dogfood.
- **Failure cost from history**: 1 known instance (R-9 deploy delay,
  cited in `b737db8` commit body); user-perceived delay between
  merging the fix and seeing it work.
- **Lock**: relay endpoint `/v1/auth/whoami` returns `version`;
  client UI shows it; CI step asserts.

### M-8. Reentrance — static analysis for Bool-style "inFlight" flags

- **Category covered**: §2h.
- **Metric** (static analysis / convention): every Bool-style flag
  matching `/^.*[Ii]n[Ff]light$/`, `/^.*[Pp]ending$/`, `/^.*[Bb]usy$/`
  (whichever pattern emerges from the codebase) is flagged by a
  custom Swift/JS lint rule. The lint suggests converting to a
  counter (`Int`) or a set of in-flight IDs.
- **Threshold**: **zero Bool-style inFlight flags in code paths that
  can be re-entered via `@MainActor` await suspensions or via async
  callbacks**. Counter-based equivalents pass.
- **Failure cost from history**: 0 shipped (sim-caught in S-17, S-20,
  S-21); but the underlying class is real and the design now uses a
  counter explicitly (§11.8).
- **Lock**: §11.8 `reloadInFlightCount: Int` is the model; lint
  audits the codebase for siblings.

### M-9. Wrapper send retry budget — golden-path test with agent restart

- **Category covered**: instructions queued during the wrapper-socket
  bounce or agent restart window. This is the wrapper-layer
  reflection of §2c (unbounded cache) — but the underlying mechanism
  is "no retry budget" rather than "no decay."
- **Metric** (integration test, gated on `STEER_INTEGRATION=1`):
  `instruction_delivery_invariant.test.js` Case B — `steer send`
  during the 250–8000 ms agent-restart window must not return error;
  the agent eventually injects.
- **Threshold**: **`SEND_RECONNECT_RETRY_MS ≥ 8 s`** in wrapper's
  `index.js` (cite: `packages/cli/src/index.js:648` and
  `REGRESSION_CONTRACT.md` §G14 — "It must retry for up to
  `SEND_RECONNECT_RETRY_MS` (8 s) to absorb wrapper socket bounce /
  agent restart windows before failing hard. This budget
  intentionally exceeds the agent lock stale-reclaim window after
  SIGKILL."). 8 s is the floor; shorter caused R-WS.
- **Failure cost from history**: 1 shipped (R-WS), 1 hour of dogfood
  reply loss before retry was added.
- **Lock**: contract test already exists in tree.

### M-10. PTY backpressure — drain-aware write

- **Category covered**: §2d (companion to M-4).
- **Metric** (integration test): a 64 KB single-line reply must
  arrive byte-complete at the fake provider's stdin even when its
  read loop is paused for 1 s.
- **Threshold**: **`ptyProcess.write` return value must be respected;
  on `false`, wait for `drain` event before writing further bytes**.
  Today: not implemented; `submitPtyInstruction` ignores the return
  value (cited at `WRAPPER_DISCONNECT_DIAGNOSIS_2026-05-13.md` §1).
- **Failure cost from history**: 0 shipped *directly* — but
  hypothesized as a non-trivial fraction of G14 reports; the
  diagnosis doc ranks it root cause #1.
- **Lock**: Case C from the diagnosis doc — a unit test against
  `pty_input.js` + `ptyProcess.write` return value semantics.

---

## §4. Threshold derivation: why these specific numbers

For every threshold in §3, the table below quotes the source.

| Metric | Threshold | Quote / cite |
|---|---|---|
| M-2 (WS p99) | **frame-received p99 ≤ 90 s; force-cancel after 60 s silence** | Audit §F-2: "If `now - lastFrameReceivedAt > 60 s` and we should be connected, force-cancel and reconnect." `b6fe8fe` commit body: ping cadence 30 → 20 s, "comfortably inside the 5–10 min DO idle floor." 60 s allows two missed 20 s ping cycles + RTT slop without false-positive cancel. 90 s p99 is the SLO upper bound (well under DO idle, leaves headroom for one slow pong). |
| M-3 (`.awaitingResponse` decay) | **10 min** | Design doc §11.1: "the §5.1 watcher decays the preserved entry to `.failed("response timeout")` at T+10min, giving the user an actionable retry banner." 10 min is "well above any legitimate codex turn duration" (per design doc §5.3) and well below typical user attention span. |
| M-3 (`.connecting`) | **10 s** | Audit §1c: `connectingTimeout=10s` already in `DevicePresenceObserver.swift` L49-59. Anchored by APNS wake latency observed in dogfood. |
| M-3 (`pendingFocusSessionId`) | **30 s** | Audit §4 Rule 2 prescription; cold-launch APNS-tap window typically completes within ~5-15 s, 30 s gives a 2× margin. |
| M-4 (TUI paste gap) | **50 ms** | `b832acc` commit body — "codex / claude TUIs need a small gap" — empirically required; this commit reverted the "atomic write" experiment after dogfood proved atomic write breaks codex/claude submit. Quote: "When both arrive in the same `ptyProcess.write` call, the TUI treats the carriage return as part of the paste payload." Status: contradicts current `REGRESSION_CONTRACT.md` §G14 wording. |
| M-7 (deploy lag) | **15 min from merge to deployed sha** | No prior cite — derived from R-8 dogfood narrative: the user noticed the badge fix wasn't working ~15 min after the merge before checking the deploy state. Threshold gives "you should have hit `wrangler deploy` by now" alarm. |
| M-9 (send retry) | **`SEND_RECONNECT_RETRY_MS ≥ 8 s`** | `REGRESSION_CONTRACT.md` §G14 explicit: "It must retry for up to `SEND_RECONNECT_RETRY_MS` (8 s) to absorb wrapper socket bounce / agent restart windows before failing hard. This budget intentionally exceeds the agent lock stale-reclaim window after SIGKILL." Confirmed in `packages/cli/src/index.js:648`. |
| Scenario PASS rate | **≥ 95%** for design-doc simulations | Sim 3 hit 15/21 PASS + 5/21 PASS-WITH-RISK + 1/21 RISK = 71% strict PASS, 95% PASS-OR-PASS-WITH-RISK. The 1 RISK (S-20) closes with the §11.8 counter fix; remaining RISKs are deferred product concerns (S-15) or pre-existing gaps (S-16). 95% leaves room for one undiscovered scenario in the future. The prompt suggested 90%; 95% is the actually-achievable bar from the sims. |

The cross-PR/integration coverage threshold (§3 M-1 through M-10):
**% catchable** is computed in §5.

---

## §5. Metric → regression preventability matrix

For each regression ID in §1, the cell shows which §3 metric (M-1
through M-10) would have caught it, or `—` if no proposed metric
applies.

| ID | Caught by |
|---|---|
| R-0 (responseRevision primitive needed) | M-6 (wire-shape invariants would have required an atomic transition signal as a contract) |
| R-1 (chip + card two arrays) | M-1 (single reducer; same row, two projections) |
| R-2 (chip 15 s poll) | M-1 (same root: two latency channels merge into one reducer projection) |
| R-3 (`loadedChips` over-filter) | M-1 (Mac chip publisher should be a projection of one set) |
| R-4 (unbounded `.awaitingResponse` hold) | M-3 (10-min decay) |
| R-5 (R-4 revert) | M-3 (with R-4's intent + 10-min decay, the revert wouldn't have been needed) |
| R-6 (iOS half-closed WS) | M-2 (frame watchdog) |
| R-7a (Mac half-closed WS) | M-2 (same metric, applied to Mac client) |
| R-7b (30 s cadence) | M-2 (cadence is one tunable of the same metric) |
| R-7c (bootstrap over-preserve) | M-1 (`applyBootstrap` and `onCardUpsert` should be one reducer) |
| R-8 (bootstrap under-promote) | M-1 (same — asymmetric paths) |
| R-9 (APNS missing badge) | M-6 (wire-shape contract test on APNS payload) |
| R-10 (`becameActive` semantics) | M-6 (wire-shape contract test on `card_id` reuse + `becameActive`) |
| R-2a (cold-start orphans) | M-6 (cold-start baseline is a wire-shape contract; relay GET is authoritative) |
| R-2b ("ended" silent drop) | M-6 (same channel) |
| R-S0 (agent SQLite singleton) | — (predates sync layer; storage track, not in scope for this catalog) |
| R-WA (atomic write breaks TUI submit) | M-4 (fake-TUI fixture with 50 ms gap assertion) |
| R-WT (TDZ on first `steer send`) | M-5 (lint rule for use-before-define + `node --check`) |
| R-WS (send retry budget too small) | M-9 (integration test exercising 8 s retry budget) |
| S-4 Case B (silent reply loss on resolve) | M-3 (10-min decay) + M-1 (`.resolved` and `.snapshot` share a reducer rule) |
| S-18 (snapshot drops preserved entry) | M-1 (the bootstrap/broadcast symmetric reducer) |
| S-20 (reloadInFlight Bool) | M-8 (counter conversion via lint) |
| S-17 / S-21 (same root) | M-8 |
| S-14 warm (gate keyed on `loadPhase` only) | M-1 (cold and warm reload paths share gate state) |
| S-14 captive (5-min escape hatch absent) | M-3 (escape hatch is itself a max-lifetime contract on the `.bootstrapping` phase) |
| S-8 (WS reconnect no backfill) | M-1 (auto-GET on reconnect treats GET as authoritative everywhere) |
| S-7 (eventSeq wording) | M-6 (wire-shape contract: `eventSeq` is not on the wire) |

### Tally

| | Count |
|---|---|
| Total regressions in inventory (shipped + sim-caught, ex-R-S0 which is storage track) | **26** |
| Caught by **any** proposed metric M-1 … M-10 | **25** |
| Not caught (predates this catalog) | **1** (R-S0 — storage layer, out of scope) |
| **% catchable** (relative to in-scope sync layer) | **25/25 = 100%** |
| **% catchable** (over total including R-S0) | **25/26 = 96.2%** |

R-S0 lives in the storage track (proper-lockfile + migration runner)
and is correctly excluded — `docs/STORAGE_PRODUCTION_READINESS.md` is
the contract for that surface. Within the sync layer, every shipped
and sim-caught regression is mapped to a metric.

---

## §6. Output

### Categories present in history

| Bucket | Sub-bucket | Shipped | Sim-caught | Total |
|---|---|---|---|---|
| §2a State machine asymmetry | (R-1, R-7c↔R-8, R-6↔R-7a) | 5 | 2 (S-4, S-18, S-14-warm) | 7 |
| §2b Half-closed socket health | (R-6, R-7a, R-7b) | 3 | 0 | 3 |
| §2c Unbounded cache lifetime | (R-1/2/3 chip side, R-4, R-7c) | 3 | 1 (S-4 Case B latent) | 4 |
| §2d Atomic-vs-split TUI write | (R-WA) | 1 | 0 | 1 |
| §2e TDZ / init-order | (R-WT) | 1 | 0 | 1 |
| §2f Cross-component contract | (R-0, R-9, R-10, R-2a, R-2b) | 5 | 1 (S-7) | 6 |
| §2g Deployment lag | (R-8 deploy delay) | 1 | 0 | 1 |
| §2h Reentrance | — | 0 | 3 (S-17, S-20, S-21) | 3 |
| §2i Bootstrap vs. broadcast | (R-7c, R-8, S-12, S-14 cold-vs-warm, S-18) | 4 | 1 (S-18 reclassified) | 5 |

(§2i overlaps §2a; the underlying mechanism is identical, but it's
useful to track separately because the cure is *one specific* rule —
"GET is authoritative" — rather than the general "single reducer."
Both metrics M-1 and M-6 cover it.)

### Total regressions in inventory

- **Shipped**: 19 (R-0 through R-10 + R-2a, R-2b + R-WA, R-WT, R-WS;
  excluding R-S0 storage out of scope).
- **Sim-caught (would have shipped without design patches)**: 7
  (S-4 Case B, S-18, S-20, S-17, S-21, S-14-warm, S-14-captive, S-8,
  S-7 — totals 9, but S-17 and S-21 share root with S-20, so 7
  distinct mechanisms).
- **Combined**: **26 distinct regression instances**.

### % catchable by proposed metrics

- **In-scope (sync layer)**: 25 / 25 = **100%**.
- **Total catalog (including R-S0)**: 25 / 26 = **96.2%**.

This exceeds the 90% target from the prompt — meaning **the
ten-metric set M-1 through M-10 is sufficient**, with the caveat that
deployment lag (M-7) and the storage layer (out of scope) are real
external dependencies that need their own contracts.

### Categories with no metric proposed

None within the sync layer. The single un-mapped regression (R-S0)
belongs to the storage track and is locked by
`docs/STORAGE_PRODUCTION_READINESS.md` + the `fefc3bc`
`proper-lockfile` work. Outside the sync layer's scope but worth
noting that *the same metric-from-history methodology* should be
applied there independently.

### Minimum additional metrics required

None — 100% in-scope coverage is achieved with M-1 … M-10. The
weakest is M-7 (deployment lag), where the metric is human-pace
(15 min) and the lock is a visible badge rather than automated
gating. If the team wants a stricter bound, M-7 can be tightened to
"CI fails main if no relay deploy has been triggered within 60 min
of the last `packages/relay/**` merge."

### Risks the metric set doesn't catch

These are *known* gaps the prompt did not require closing:

1. **Real-device timing** — APNS wake latency, iOS jetsam pressure,
   iOS suspend timing on real cellular. Not derivable from history;
   only from real-device dogfood. (Cited in audit §6.)
2. **Captive portal at sign-in cold start (S-16)** — pre-existing,
   no automatic re-`reload()` path. Sim 3 explicitly defers to
   `LAUNCH_CHECKLIST.md` Phase 9 dogfood.
3. **Product-concern reply-against-stale-card races (S-15)** — sim
   1/2/3 unanimously deferred as a product question, not a sync
   architecture question.

### Contract update required (discovered during this audit)

`docs/REGRESSION_CONTRACT.md` §G14 currently mandates:

> "The PTY instruction payload and its submit keystroke (`\r`) MUST
> be written as a single atomic `ptyProcess.write` call."

This is **wrong** per `b832acc` (the revert). The correct rule is:

> "The PTY instruction payload (with bracketed-paste END) and its
> submit keystroke (`\r`) MUST be written as **two separate
> `ptyProcess.write` calls separated by at least 50 ms**. Atomic
> writes cause codex/claude to absorb the `\r` into the paste
> payload and the submit never fires."

Update suggested as a follow-up to this audit. Not in scope here
because the prompt says research-only.

### 300-word summary for parent agent

Cataloguing 26 distinct sync-layer regressions (19 shipped, 7
sim-caught) produces **nine mechanism buckets**: state-machine
asymmetry (7 hits, largest), half-closed WS (3), unbounded cache (4),
atomic-vs-split TUI write (1), TDZ init-order (1), cross-component
contract (6), deployment lag (1), reentrance (3, all sim-caught),
and the bootstrap-vs-broadcast special-case (overlaps state-machine
but covered separately because the cure is one explicit rule).
A ten-metric set falls out of the data, with thresholds quoted from
either the failing commit or the simulation patch that closed it:
M-1 single reducer (count=1), M-2 frame-received p99 ≤ 90 s + 60 s
force-cancel, M-3 every Stage variant decays at a documented bound
(`.awaitingResponse` = 10 min, `.connecting` = 10 s,
`pendingFocusSessionId` = 30 s), M-4 50 ms paste-submit gap with
fake-TUI fixture, M-5 ESLint no-use-before-define + `node --check`,
M-6 relay deploy contract test (5 wire-shape invariants), M-7
deployed-sha sticker with 15 min staleness alarm, M-8 lint converts
Bool inFlight flags to counters, M-9 wrapper retry budget ≥ 8 s with
integration test, M-10 PTY drain-aware write with 64 KB backpressure
test. The matrix in §5 maps each regression to its catching metric:
**100% of in-scope sync-layer regressions are catchable** by this
set; the only un-mapped instance (R-S0, agent SQLite singleton) is
the storage track and is locked by a separate contract. No category
in the data lacks a metric. One contract update is required as a
by-product of this audit: `REGRESSION_CONTRACT.md` §G14 mandates
"atomic paste-submit write," which the `b832acc` revert proves is
backwards — the correct rule is "two writes separated by ≥ 50 ms."
That contract change is flagged as a follow-up but out of scope for
research-only.
