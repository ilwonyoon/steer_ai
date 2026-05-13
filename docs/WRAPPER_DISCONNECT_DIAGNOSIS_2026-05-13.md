# Wrapper-disconnect after iPhone reply — diagnosis 2026-05-13

Task: #283 (in-progress). Tracks G14 in `docs/STORAGE_PRODUCTION_READINESS.md`.

Symptom (user-observable):

```
iPhone reply  →  relay queues instruction  →  Mac drainQueuedInstructions
              →  steer send <sid> "<text>"  →  agent.routeInstruction
              →  session.socket.write({type:"instruction", ...})
              →  wrapper writes to PTY / Codex JSON-RPC
              →  <silence>  ←  iPhone chip stuck at "1 running" forever
```

Codex (or Claude) appears to be reachable up to "send" but the
follow-up answer never reaches the agent over the wrapper
socket — so `refreshActionCard` never fires for this session
and neither Mac nor iPhone sees a new card.

The storage / lockfile work (PRs S0+S1) closed one cause of the
chain (agent crash-loop on the 1.8 GB DB), but G14 still flaps
in dogfood. Below is what I read, what I think the surviving
root cause is, and how to reproduce it inside the existing
harness without touching production code.

## What I read

Wrapper side (CLI process, owns child + PTY):

- `packages/cli/src/index.js`
  - `wrapPtyProvider(provider, childCommand, childArgs)` — the
    default path for `steer codex` / `steer claude`. Lines
    134–287. Owns the pty, the instruction queue
    (`pendingInstructions`), and the readiness gate
    (`ptyReady` / `instructionInFlight`).
  - `submitPtyInstruction(message, done)` — lines 253–268.
    Writes the bracketed-paste payload, sleeps 50 ms, writes
    `\r`, emits `ack` unconditionally.
  - `runClaudeHeadlessAdapter` — lines 361–441. stream-json
    over stdio. Different surface: doesn't use the reconnecting
    `agent_link`; it uses raw `connectToAgent()`.
  - `runCodexHeadlessAdapter` — lines 457–612. JSON-RPC over
    stdio to `codex app-server`. Same caveat: raw socket, no
    reconnect.
  - `createAgentLink({ agentEntryPath })` — lines 13–143.
    Buffered, reconnecting Unix-socket client. Used only by
    `wrapPtyProvider`.

- `packages/cli/src/pty_input.js` — `formatPtyInstructionInput`
  wraps multiline payloads in CSI 200/201 (bracketed paste) for
  Codex + Claude. No error path; pure string transformer.

- `packages/cli/src/codex_session_reader.js` — polls
  `~/.codex/sessions/*.jsonl`, emits `report` stream entries
  for `agent_message phase=final_answer`. Fixed at commits
  fe262a8 / e76e9de so the reader survives a 15 s discovery
  timeout and re-evaluates `STEER_CODEX_SESSIONS_DIR` per call.

- `packages/cli/src/cancel_keys.js` — Esc / Ctrl-C detector for
  raw-mode stdin.

- `packages/cli/src/agent_link.js` — wrapper-side reconnect /
  buffering. Notably:
  - Line 63: `socket.on("error", () => {});` — errors swallowed.
  - Line 64–68: on close, sets `socket = null`, calls
    `void connect()` to retry forever.
  - Lines 79–97: `write(message)` — if `socket` is null,
    pushes into a 1024-capacity buffer with priority
    pre-emption (state/ack/output stay; old non-priority drops).

Agent side (single-writer Node process, owns SQLite + socket):

- `packages/agent/src/agent.js`
  - `handleMessage` dispatch — lines 52–93. Decoded once per
    line via `createLineDecoder`. Branches on `register` /
    `output` / `state` / `send` / `hook_event` / `ack`
    / `sessions`.
  - `socket.on("close", ...)` — lines 96–110. For every session
    whose `socket === socket`, flips `runState` to
    `disconnected` (unless already `ended`) AND writes that to
    the store. **This is the one-way trip that ends the
    chain.** Once `disconnected` is in the DB, the card
    classifier silently down-classifies the active card to
    `done/disconnected` via `resolveStaleDisconnectedCards()`
    on the next agent startup (line 175), and `routeInstruction`
    bounces any new `send` with "session is disconnected"
    (line 290).
  - `routeInstruction` — lines 282–319. Writes the instruction
    to `session.socket` via plain `socket.write(...)`. **No
    write-result inspection. No EPIPE handler. No retry.**
  - `registerSession` — lines 187–222. Preserves a prior
    `run_state` *unless* it's `disconnected` or `ended` (line
    192–196). So reconnect from `disconnected` → defaults to
    `running`.

- `packages/agent/src/store.js`
  - `createInstruction({id, sessionId, text})` — line 258.
    Stamps `awaiting_response_since` on the session so the next
    `report`/`stdout`/`stderr` after that timestamp atomically
    bumps `last_response_revision` (this is the iPhone chip-clear
    signal).
  - `updateInstructionStatus`, `resolveActionCardsForSession`,
    `resolveStaleDisconnectedCards`.

Mac side (read-only consumer that re-injects via shell-out):

- `apps/mac/Sources/SteerMac/SteerRootView.swift`
  - `drainQueuedInstructions()` — lines 608–635. `drainInFlight`
    re-entrancy guard, then for each queued instruction:
    `store.send(...)` → `markInstructionInjected`. **On
    `markInstructionFailed` the failure reason becomes whatever
    `error.localizedDescription` says — typically the stderr of
    the failed `steer send` subprocess.**
  - `send(_:to:)` — lines 288–303. The local card-reply path,
    same `store.send` underneath.

- `apps/mac/Sources/SteerMac/LocalSteerStore.swift`
  - `send(_ text, attachments, to sessionId)` — lines 39–64.
    Spawns `steer send` as a subprocess and waits for exit.
    Reads stderr only on non-zero exit. Doesn't time out.

Tests that already exercise this path (and so define the
harness primitives I'd build on):

- `packages/cli/test/wrapper_invariant.test.js` — five live
  integration cases against the fake provider (`STEER_INTEGRATION=1`
  gated). Each one boots a real isolated agent under `STEER_HOME`,
  spawns `steer wrap -- node fake_provider.js`, asserts via direct
  SQLite read.
- `packages/cli/test/reconnect_invariant.test.js` — SIGKILL +
  graceful-restart scenarios. Already proves the lockfile-stale-
  socket recovery path is covered, but NOT the in-flight
  instruction loss path.
- `packages/cli/test/coding_session_e2e.test.js` — 3-turn
  conversation with mid-turn cancel.
- `packages/cli/test/codex_session_reader_emit.test.js` — five
  reader-only cases covering discovery / late-jsonl recovery.
- `packages/cli/test/helpers/harness.js` — `createHarness()`
  returns `{startAgent, stopAgent, spawnWrappedSession,
  fireStopHook, sendInstruction, db, waitFor, cleanup}`.
  Everything the integration tests need is in here.
- `packages/cli/test/helpers/fake_provider.js` — controllable
  fake reading turns out of `$STEER_FAKE_PLAN` (a JSON file).
  Already supports `responseBytes`, `responseDelayMs`,
  `ptyRepaints`, `stopHook`.
- `packages/agent/test/lifecycle_contract.test.js` — store-level
  unit, no socket. Useful for the "ack → resolveActionCardsForSession
  must close the active card" invariant.

## Most likely root cause(s) — ranked

### #1. `submitPtyInstruction` emits "injected" regardless of whether the PTY actually accepted the input

`packages/cli/src/index.js:253–268`:

```js
function submitPtyInstruction(message, done) {
  agent.write({ type: "state", sessionId, runState: "running" });
  const merged = formatInstructionWithAttachments(message.text, message.attachments);
  const input = formatPtyInstructionInput(provider, merged);
  ptyProcess.write(input);
  setTimeout(() => {
    ptyProcess.write("\r");
    agent.write({
      type: "ack",
      sessionId,
      instructionId: message.instructionId,
      status: "injected"
    });
    done();
  }, 50);
}
```

Problems with this code, in dogfood-likely order:

1. **`ptyProcess.write` return value is ignored.** node-pty
   returns `false` when the pty's internal buffer is full
   (backpressure). With Codex mid-turn — the exact moment when
   an iPhone reply lands during a long response — the pty's
   read buffer can be backed up. Bracketed-paste bytes that
   should arrive *atomically* can be split or dropped at the
   pty boundary. **No drain wait, no retry, no warning.**

2. **The 50 ms gap is open-loop.** Between
   `ptyProcess.write(input)` and `ptyProcess.write("\r")`,
   nothing inspects the pty's state. If Codex/Claude is still
   producing output during those 50 ms, the `\r` lands
   somewhere in the middle of a half-rendered prompt and Codex
   never associates it with the just-written paste.

3. **The ack fires unconditionally.** Even if the paste is lost,
   the agent records the instruction as `injected`, the active
   card is resolved (`resolveActionCardsForSession` runs in the
   agent at `case "ack"`), and the only remaining signal that
   anything is wrong is the *absence* of a follow-up report —
   which the agent has no timer for. The session sits forever
   in `runState=running`, and the chip stays at "1 running"
   forever.

Concretely for the user's dogfood: codex is in the middle of a
20s turn when the iPhone reply arrives. The bracketed-paste
bytes hit the pty's buffer, Codex either ignores them (it
explicitly rejects keystrokes during streaming) or it stashes
them in its UI compose buffer, the `\r` 50 ms later does
nothing visible. The user never sees their reply land. No new
turn is started, so `codex_session_reader` has nothing to
forward. The chip stays "1 running" forever even though the
agent says "instruction injected."

The reason this didn't show up before the storage fix: pre-S2,
the agent's PTY transcript was so dense that the user almost
always saw the bracketed-paste *echo* in the terminal and could
hit Enter manually. Post-S2 we filter PTY rows; that's
unrelated to the actual injection but it removes the
incidental "user saw it didn't work, fixed it" path.

### #2. The wrapper socket can close silently and the agent has no liveness probe to distinguish "wrapper crashed" from "agent restarted while wrapper was alive"

`packages/agent/src/agent.js:96–110`:

```js
socket.on("close", () => {
  for (const [sessionId, session] of sessions) {
    if (session.socket === socket) {
      sessions.set(sessionId, {
        ...session,
        socket: null,
        runState: session.runState === "ended" ? "ended" : "disconnected",
        updatedAt: new Date().toISOString()
      });
      if (session.runState !== "ended") {
        store.updateSessionState(sessionId, "disconnected");
      }
    }
  }
});
```

Any single `close` event flips the session to `disconnected` in
SQLite *immediately*. The wrapper's `createAgentLink` does
auto-reconnect (`agent_link.js:64–68`), so within 250 ms a new
socket will reconnect and re-register. But during that 250 ms:

- If the Mac's `drainQueuedInstructions` happens to fire (it's
  bound to every `syncDidReceiveUpdate`, which fires from the
  WebSocket pong cadence too), `steer send` will hit the agent
  while `session.socket` is null, return
  `"session is disconnected"`, and the iPhone reply gets marked
  `failed` on the relay. **The reply is lost; the iPhone
  doesn't notice because the chip is "1 running" not "1
  failed".**
- Even if the timing is benign, `disconnected` is now what's
  in the DB. The next agent startup runs
  `resolveStaleDisconnectedCards()` (line 175) which
  marks every active card on that session `done/disconnected`.
  The next Mac reload tick reads zero active cards for that
  session and tells the relay to DELETE — iPhone chip clears
  but **no new card ever lands** because the session never
  re-emitted a report.

What triggers the close: any of (a) the agent crashes (the
storage track partially fixed this), (b) the wrapper crashes,
(c) the OS reclaims the socket on sleep/resume (macOS does this
to Unix sockets sometimes), (d) the agent's `shutdown()` path
runs `closeAllConnections()` on SIGTERM. The wrapper has no
side channel to know "this close is the agent restarting; my
session should be preserved" vs. "this close is permanent."

### #3. Codex headless adapter: in-flight `turn/start` await can hang

`packages/cli/src/index.js:575–611`:

```js
agent.on("data", createLineDecoder(async (message) => {
  if (message.type !== "instruction") return;

  try {
    setState("running");
    const payload = formatInstructionWithAttachments(...);
    const input = [{ type: "text", text: payload, text_elements: [] }];
    if (activeTurnId && runState === "running") {
      const response = await codex.request("turn/steer", { ... });
      ...
    } else {
      const response = await codex.request("turn/start", { threadId, input });
      ...
    }
    ...
  } catch (error) {
    ...
    setState("blocked");
  }
}));
```

Two subtle issues, in dogfood-likely order:

1. **`codex.request` (line 875–887) has no timeout.** If the
   app-server hangs (it does, occasionally, when the model API
   is degraded), the awaited request never resolves. The
   `agent.on("data", ...)` callback is async — node's line
   decoder doesn't await it — but the `setState("running")`
   sticks. From the agent's perspective the session is
   `running` forever.

2. **`createLineDecoder` does not await async handlers.** The
   handler in the agent socket data callback (`createLineDecoder`
   in `protocol.js:5–22`) calls `onMessage(JSON.parse(line))`
   synchronously. An async handler returns a Promise that's
   immediately discarded. If a second instruction arrives while
   the first is still awaiting `turn/start`, both fire
   in parallel and the second's `setState`/`writeAgent` racing
   the first's. Less likely to cause the disconnect chain
   directly, but it's the kind of thing that produces the
   observed behavior (state stuck, no ack).

### Ranking summary

| # | Probability | Surface area | Lives in |
|---|-------------|--------------|----------|
| 1 | high | PTY adapters (`wrapPtyProvider`) — the path the user mostly hits | `cli/src/index.js:253` |
| 2 | medium | Cross-layer (agent + wrapper). Worst case combined with #1 | `agent/src/agent.js:96` + `agent_link.js:64` |
| 3 | medium for `--headless` users | Codex JSON-RPC adapter | `cli/src/index.js:575` |

I'd start by writing the regression test for #1 (it's the
cheapest to repro and the test will also catch #3-style hangs
if the test driver pauses the fake provider mid-turn). #2's
test is mostly already covered by `reconnect_invariant.test.js`
"agent SIGKILL leaves a stale socket; wrapper auto-recovers"
— what's missing there is the *instruction that races the
reconnect* assertion.

## Reproduction approach

### Test file to create

`packages/cli/test/inject_invariant.test.js` — sits next to
`wrapper_invariant.test.js` and `reconnect_invariant.test.js`.
Gated on `STEER_INTEGRATION=1` per the same convention.

Three new cases, in priority order:

#### Case A — instruction injected during a long turn must eventually surface a follow-up report

This is the direct G14 repro at the wrapper layer.

Setup (uses the existing harness primitives, no new ones
needed):

```js
const harness = createHarness();
t.after(() => harness.cleanup());

await harness.startAgent();
// First turn: 6 s long, no Stop hook (mimics codex still typing
// when the user replies again). Second turn: short answer to
// the injected reply. We need to fire the Stop hook
// programmatically because the fake provider never does it
// itself — see harness.fireStopHook.
harness.setPlan({
  turns: [
    { preamble: "thinking…\n", responseBytes: 30_000, responseDelayMs: 6_000, ptyRepaints: 4 },
    { preamble: "ok:\n",       responseBytes:  1_200, responseDelayMs:   600 }
  ]
});

const wrapper = harness.spawnWrappedSession();
const sessionId = await captureSessionId(harness);

// Drive turn 1.
await harness.sendInstruction(sessionId, "do the long thing");
await delay(1500);  // we are mid-turn here, by design

// User taps iPhone reply mid-turn. From the agent's POV this is
// identical to drainQueuedInstructions → steer send.
await harness.sendInstruction(sessionId, "actually, also do X");

// Force turn 1 + turn 2 to complete on the fake side.
await delay(7_000);
await harness.fireStopHook(sessionId, "Done. Also X is done.");
await delay(500);

// Invariants:
//   (i) the SECOND instruction's user transcript row exists.
//   (ii) an active card with a non-empty body exists AFTER the
//        second send (so refreshActionCard fired post-injection).
//   (iii) sessions.last_response_revision incremented by ≥ 1
//        AFTER the second send was injected.
//        (responseRevision is the iPhone chip-clear signal.)
```

The third assertion is the key one: it directly proves the
follow-up report reached the agent. **It will fail today** on
the PTY-buffer-backpressure / mid-turn-paste failure mode
described above. The fake provider implementation doesn't echo
the bracketed-paste literally (it reads stdin via `readline`),
so it will accept whatever lands at its `rl.on("line", ...)`
boundary — but the wrapper's `submitPtyInstruction` 50 ms gap
in the middle of turn 1's `responseDelayMs=6000` window is
exactly where the regression hides.

If the test passes consistently, root cause #1 is wrong and
I should instead look at #2 first.

What gets mocked vs. what's real:

- **Real**: `SteerAgent` Node process under isolated
  `$STEER_HOME`; `steer wrap` Node process; node-pty pty; the
  full agent socket protocol; `steer send` CLI.
- **Mocked**: the underlying "AI" — the fake provider in
  `helpers/fake_provider.js` is what plays the role of Codex /
  Claude. It does NOT replicate Codex's bracketed-paste rejection
  during streaming — that's the surface area we'd need a real
  Codex for. Caveat acknowledged in the test comment.

Caveat to call out in the test docblock: this reproduces the
**injection-during-streaming** case, but Codex's actual TUI
behavior (reject paste during stream) is not in the fake
provider. To exercise that we'd need to extend the fake
provider with a "busy-rejects-input" mode — small change, ~30
lines.

#### Case B — instruction that arrives during the 250 ms wrapper-socket-bounce must not be marked failed silently

Builds on `reconnect_invariant.test.js` "agent SIGKILL leaves a
stale socket". Same setup, but the test driver fires
`harness.sendInstruction` immediately AFTER `stopAgent({graceful: false})`
and BEFORE `harness.startAgent()` runs again. Invariant: by the
time the wrapper has re-registered, the agent eventually sees
the instruction (either via the relay re-queueing or via the
local `instructions` table holding `status='pending'` until
the wrapper acks).

This will likely fail today because `routeInstruction` returns
an error immediately on `!session.socket`, the caller (`steer send`)
prints stderr + exits non-zero, `LocalSteerStore.send` throws,
and `drainQueuedInstructions` calls `markInstructionFailed`. The
relay drops the instruction. **The iPhone reply is lost forever
with no signal back to the user.**

The fix space here is: either (a) the agent should *buffer*
instructions for sessions whose socket is null but whose pid is
still alive (with a 2–5 s window matching `agent_link.js`
reconnect cadence), or (b) the Mac drain path should retry on
"session is disconnected" failures within a small budget.

#### Case C — instruction with a payload that triggers PTY backpressure

A 64 KB single-line reply (no newlines) sent into a paused PTY.
This is the synthetic version of "the user pasted a long
prompt". The fake provider should *not* read from stdin while
the test holds it, and the test then asserts that:
1. The bracketed-paste byte count written to the wrapper's
   `process.stdin` equals what node-pty drained to the child.
2. After the PTY is unpaused, the child sees the full payload.

This is more of a unit test against `pty_input.js` + the
`ptyProcess.write` return value, and probably belongs in
`pty_input.test.js` rather than the integration suite. Lower
priority than A and B.

### What the existing harness gives us for free

`packages/cli/test/helpers/harness.js`:

- `harness.startAgent()` — boots a real agent process under
  `$STEER_HOME=mkdtemp`. Already proves an isolated working DB.
- `harness.spawnWrappedSession({ provider: "custom" })` — runs
  `steer wrap -- node fake_provider.js`. Returns the child
  process; tests write to `child.stdin` for keystrokes.
- `harness.sendInstruction(sessionId, text)` — uses real
  `steer send` subprocess. **This is the exact path
  `drainQueuedInstructions` ultimately invokes.**
- `harness.fireStopHook(sessionId, lastAssistantMessage)` — uses
  real `steer hook claude Stop`. Simulates the trusted-report
  arrival.
- `harness.waitFor(predicate, {timeoutMs, intervalMs})` —
  poll-until-true with a 5 s default.
- `harness.db()` — read-only SQLite handle for assertions.

What I'd need to add (small):

- A `harness.injectDirect(sessionId, text)` that mimics what
  `routeInstruction` does (write a single line of the
  instruction protocol to the wrapper's socket) for tests
  where I want to bypass `steer send`. Not strictly needed for
  the three cases above but useful for sharpening assertions.

## Risky places to NOT change without test coverage first

1. **`wrapPtyProvider.submitPtyInstruction`** — the 50 ms gap
   and the unconditional ack are the suspected root cause but
   they're also the path *every* dogfood reply currently
   goes through. Any change here without case A green first
   risks regressing the common path. Specifically don't:
   - "Replace the 50 ms with a readiness probe" without first
     verifying the probe doesn't add latency on the happy
     path.
   - Move the `ack` to inside a write-completion callback
     without first making sure node-pty actually fires one
     reliably (last I looked it didn't — there's no flush
     event, only the synchronous return value).

2. **`agent.js` socket.on("close") handler** — flipping a
   session to `disconnected` in the DB is irreversible from
   the wrapper's POV (re-register restores `running` but the
   "session is disconnected" error already fired for any
   races). Any change to make this *less* eager (e.g. defer
   the DB write by 250 ms to absorb reconnect bounces) needs
   tests for both the "graceful reconnect" and "real crash"
   cases.

3. **`createAgentLink.write` buffer** — currently 1024
   messages with priority eviction (state/ack/output stay,
   anything else drops). If we extend the buffer (e.g. to
   replay buffered messages after reconnect), we risk
   duplicate instructions or replaying state messages out of
   order. The existing test
   (`reconnect_invariant: agent SIGKILL leaves a stale socket`)
   should grow assertions about ack-correctness across the
   reconnect.

4. **`refreshActionCard`'s `responseRevision` bump** — the
   atomic chip-clear signal lives there. If we change the
   `awaiting_response_since` marker semantics (e.g. to mark
   sessions awaiting at *some* earlier point), we risk
   bumping `last_response_revision` on un-replied sessions,
   which the iPhone will misinterpret as "Mac is replying"
   and prematurely transition the chip. See PR #b6b8d67's
   commit message for the contract.

5. **`codex_session_reader`'s `findNewestSessionFile`
   matching window.** Both fe262a8 and e76e9de touched this
   recently — it's now per-call env read + discovery-timeout-
   survival. Don't widen the SPAWN_WINDOW_MS, don't shorten
   the POLL_INTERVAL_MS, don't change the rollout-filename
   regex without `codex_session_reader_emit.test.js` green
   first.

## Next steps for the morning (in priority order)

1. **Write Case A first (test, must fail on main)** — the
   "instruction injected mid-turn must produce a follow-up
   report" test. This is the smallest reproduction of G14 the
   harness can carry. ~60 lines including setup. If it passes
   today, root cause #1 is wrong and we move on; if it fails,
   we have a sharp signal for the fix.

2. **Decide on the surgical fix scope.** Two options:
   - (a) Smallest: make `submitPtyInstruction` await
     `ptyProcess.write` actually drained (loop on `false`
     return until `drain` event), and move the `ack` to AFTER
     the drained `\r` write. ~12 lines. Doesn't fix Codex's
     reject-during-stream behavior but does fix backpressure
     losses.
   - (b) Larger: gate `submitPtyInstruction` on a "child is
     idle" signal — wait for the codex_session_reader's
     `turn/completed` (Codex) or the Claude hook (Claude)
     before writing. Adds the kind of liveness signal the
     wrapper today doesn't have but multiplies latency for
     the happy path by ~the streaming turn duration. Probably
     overkill.

   I'd ship (a) and let dogfood prove whether (b) is needed
   on top.

3. **Add Case B (the reconnect-race test)** regardless of
   what we do about Case A. It's catching a different
   failure mode that's not gated by #1's fix.

4. **Document the new contract in `docs/REGRESSION_CONTRACT.md`**
   — specifically, "an injected instruction MUST produce a
   responseRevision bump within N seconds of its injected_at."
   Today that's an implicit invariant; making it explicit
   means future changes have something to break against.

5. **Only if Cases A + B both pass post-fix** and the user-
   facing dogfood smoke is green: revisit root cause #3
   (Codex headless adapter timeout). It's a separate user
   surface and unlikely to be the dogfood blocker today.

## What I did NOT do

- Did not touch any source files; this is research only.
- Did not run the regression test (`scripts/verify-steer-regression.sh`)
  — the user is asleep and the working tree is on
  `fix/mac-chip-reconciliation` with the user's in-flight
  changes; running the suite mid-investigation risks
  polluting their next session.
- Did not file or modify task #283 in any tracker beyond this
  document.
