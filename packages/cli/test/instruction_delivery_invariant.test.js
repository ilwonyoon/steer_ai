// Instruction-delivery invariant tests.
//
// Regression for G14: iPhone chip stuck at "1 running" forever after a
// reply was sent. Two failure modes are covered:
//
//   Case A — instruction injected mid-turn must produce a follow-up report.
//     The wrapper's submitPtyInstruction previously split the paste-content
//     write and the \r write across a 50 ms setTimeout, creating a race
//     window where the carriage return could arrive at a bad PTY boundary.
//     Fix: combine input + "\r" into a single atomic ptyProcess.write call.
//
//   Case B — instruction sent during the ~250 ms wrapper-socket-bounce
//     window must not be silently lost.
//     When the agent restarts (crash or socket bounce), the wrapper
//     re-registers within ~250 ms. Any `steer send` that arrives before
//     re-registration gets "session not found" from the fresh agent and
//     currently exits non-zero, causing drainQueuedInstructions to
//     markInstructionFailed. The instruction is never delivered.
//     Fix: steer send retries on "session not found" / "session is
//     disconnected" errors for up to RECONNECT_RETRY_MS (default 2000 ms).

import test from "node:test";
import assert from "node:assert/strict";
import { setTimeout as delay } from "node:timers/promises";
import { createHarness } from "./helpers/harness.js";

const SKIP = process.env.STEER_INTEGRATION !== "1";
const suite = (name, fn) =>
  test(name, { skip: SKIP ? "set STEER_INTEGRATION=1 to run" : false }, fn);

async function captureSessionId(harness, { timeoutMs = 5000 } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const db = harness.db();
    const row = db.prepare("SELECT id FROM sessions ORDER BY created_at DESC LIMIT 1").get();
    db.close();
    if (row?.id) return row.id;
    await delay(50);
  }
  throw new Error("no session registered within timeout");
}

// ─── Case A ──────────────────────────────────────────────────────────────────
//
// Regression guard: an instruction injected while the provider is mid-turn
// must still be processed and produce a follow-up report that bumps
// last_response_revision. With the 50 ms split-write bug the two PTY writes
// could interleave with provider output in a way that confuses some providers
// (e.g. Codex rejects bracketed-paste during streaming). The fake provider
// does NOT replicate Codex's rejection mode, so this test documents the
// happy-path invariant that must not regress and gives us a hook to extend
// with a "busy-rejects-input" fake-provider mode when needed.

suite("instruction invariant: mid-turn injection produces follow-up response revision", async (t) => {
  const harness = createHarness();
  t.after(() => harness.cleanup());

  await harness.startAgent();

  // Turn 1: slow streaming (3 s), turn 2: quick
  harness.setPlan({
    turns: [
      { responseBytes: 4000, responseDelayMs: 3000 },
      { responseBytes: 200, responseDelayMs: 0 }
    ]
  });

  const wrapper = harness.spawnWrappedSession();
  const sessionId = await captureSessionId(harness);

  // Kick off turn 1 — must be before mid-turn injection to actually be
  // "mid-turn". Keep this send non-awaited so we can inject at T+500 ms.
  const firstSendPromise = harness.sendInstruction(sessionId, "start work");

  // Wait until turn 1 is actively streaming.
  await delay(500);

  // Mid-turn injection: second instruction while turn 1 is still running.
  const secondSendPromise = harness.sendInstruction(sessionId, "follow-up mid-turn");

  // Let both sends resolve (they just need ack, not full turn completion).
  await firstSendPromise;
  await secondSendPromise;

  // Simulate provider stopping (turn 1 complete).
  await harness.fireStopHook(sessionId, "Turn 1 complete");

  // Wait a beat for turn 2 output to be processed.
  await delay(800);

  // Simulate provider stopping again (turn 2 complete from mid-turn injection).
  await harness.fireStopHook(sessionId, "Turn 2 complete — mid-turn instruction processed");

  // The session must eventually have response-revision >= 1, meaning the
  // agent received trusted output after awaiting_response_since was set.
  await harness.waitFor(
    () => {
      const db = harness.db();
      try {
        const sess = db
          .prepare("SELECT last_response_revision FROM sessions WHERE id = ?")
          .get(sessionId);
        return (sess?.last_response_revision ?? 0) >= 1;
      } finally {
        db.close();
      }
    },
    { timeoutMs: 8000 }
  );

  // Also assert: both instructions produced user-stream transcript entries.
  const db = harness.db();
  const userEntries = db
    .prepare(
      "SELECT COUNT(*) AS n FROM transcript_entries WHERE session_id = ? AND stream = 'user'"
    )
    .get(sessionId);
  db.close();

  assert.ok(
    (userEntries?.n ?? 0) >= 2,
    `expected >=2 user transcript entries for two instructions, got ${userEntries?.n}`
  );

  wrapper.kill("SIGTERM");
});

// ─── Case B ──────────────────────────────────────────────────────────────────
//
// An instruction delivered by `steer send` while the agent is restarting
// (socket bounce window) must NOT be silently lost.
//
// Scenario:
//   1. Normal session running.
//   2. Agent is SIGKILL'd (stale socket left behind, wrapper will reconnect).
//   3. `steer send` runs immediately — connects to the *new* agent (started
//      by connectToAgent when it finds ECONNREFUSED + stale socket) but the
//      wrapper has not yet re-registered the session. New agent returns
//      "session not found".
//   4. steer send MUST retry until the session is registered, then deliver
//      the instruction.
//   5. Wrapper eventually re-registers; the instruction must reach the PTY.
//
// This test FAILS on main (steer send exits 1 immediately on "session not
// found") and must PASS after the retry fix in sendInstruction.

suite("instruction invariant: instruction during agent-restart window is not lost", async (t) => {
  const harness = createHarness();
  t.after(() => harness.cleanup());

  await harness.startAgent();
  harness.setPlan({ turns: [{ responseBytes: 100, responseDelayMs: 0 }] });

  const wrapper = harness.spawnWrappedSession();
  const sessionId = await captureSessionId(harness);

  // Confirm session is fully registered.
  await harness.waitFor(() => {
    const db = harness.db();
    try {
      return db.prepare("SELECT id FROM sessions WHERE id = ?").get(sessionId) != null;
    } finally {
      db.close();
    }
  });

  // SIGKILL the agent so the socket file stays but the process is gone.
  await harness.stopAgent({ graceful: false });

  // Immediately attempt to send an instruction. connectToAgent will:
  //   a) see the stale socket file
  //   b) get ECONNREFUSED → unlink stale socket → spawn new agent
  //   c) connect to new agent
  // The new agent has no sessions registered yet. steer send must retry
  // until the wrapper reconnects and re-registers (up to ~2 s).
  //
  // This is the core regression: today this exits 1 ("session not found").
  await assert.doesNotReject(
    harness.sendInstruction(sessionId, "instruction sent during restart window"),
    "steer send must not reject during agent restart window"
  );

  // Confirm the instruction actually reached the DB as a transcript entry.
  const db = harness.db();
  const userEntry = db
    .prepare(
      "SELECT COUNT(*) AS n FROM transcript_entries WHERE session_id = ? AND stream = 'user'"
    )
    .get(sessionId);
  db.close();

  assert.ok(
    (userEntry?.n ?? 0) >= 1,
    "instruction must appear as a user transcript entry after delivery"
  );

  wrapper.kill("SIGTERM");
});
