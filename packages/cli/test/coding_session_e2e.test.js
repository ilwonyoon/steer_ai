// End-to-end coding-session simulation. The story we're walking
// through:
//
//   1. User opens `steer wrap -- fake_provider`. A ready card surfaces.
//   2. They send the first instruction via the reply box. Card hides
//      while the fake produces a 30 KB markdown reply over 4 seconds.
//   3. The session goes back to waiting; the next card surfaces.
//   4. User types a couple of characters into the wrapped terminal
//      (mid-thinking) — card hides immediately. They press Esc to
//      cancel, card returns.
//   5. They send the second instruction (5 KB reply, 2s). Same arc.
//   6. They press Ctrl-C while a longer instruction is running — the
//      cancel returns the session to waiting and the card resurfaces
//      with the body the model already produced before the cancel.
//
// The test asserts the *invariants* across that flow rather than the
// exact text payloads. Each invariant maps to a real bug we hit during
// dogfooding.

import test from "node:test";
import assert from "node:assert/strict";
import { setTimeout as delay } from "node:timers/promises";
import { createHarness } from "./helpers/harness.js";

const SKIP = process.env.STEER_INTEGRATION !== "1";
const suite = (name, fn) =>
  test(name, { skip: SKIP ? "set STEER_INTEGRATION=1 to run" : false }, fn);

async function captureSessionId(harness) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    const db = harness.db();
    const row = db.prepare("SELECT id FROM sessions ORDER BY created_at DESC LIMIT 1").get();
    db.close();
    if (row?.id) return row.id;
    await delay(50);
  }
  throw new Error("no session within 5s");
}

function readSession(db, id) {
  return db.prepare("SELECT id, run_state FROM sessions WHERE id = ?").get(id);
}

function readActiveCard(db, id) {
  return db.prepare(`SELECT category, state FROM action_cards WHERE session_id = ? AND state = 'active'`).get(id);
}

function readRunStateHistory(db, id) {
  return db
    .prepare(
      `SELECT metadata_json FROM metric_events WHERE session_id = ? AND type = 'state_changed' ORDER BY timestamp ASC`
    )
    .all(id)
    .map((row) => JSON.parse(row.metadata_json).runState);
}

function readTrafficCount(db, id, streams) {
  const placeholders = streams.map(() => "?").join(",");
  const row = db
    .prepare(
      `SELECT COUNT(*) AS n FROM transcript_entries WHERE session_id = ? AND stream IN (${placeholders})`
    )
    .get(id, ...streams);
  return row?.n ?? 0;
}


suite("e2e coding session: 3-turn conversation with mid-turn cancel", async (t) => {
  const harness = createHarness();
  t.after(() => harness.cleanup());

  await harness.startAgent();
  harness.setPlan({
    turns: [
      // Turn 1: a mid-sized refactor explanation. Big response + repaint.
      { preamble: "claude is reading…\n", responseBytes: 12000, responseDelayMs: 1500, ptyRepaints: 3, stopHook: true },
      // Turn 2: short clarifying answer.
      { preamble: "claude:\n", responseBytes: 2400, responseDelayMs: 600, ptyRepaints: 1, stopHook: true },
      // Turn 3: long-running run that we'll cancel.
      { preamble: "claude is searching…\n", responseBytes: 30000, responseDelayMs: 8000, ptyRepaints: 6, stopHook: true }
    ]
  });

  const wrapper = harness.spawnWrappedSession();
  const sessionId = await captureSessionId(harness);

  // ── Step 1: ready card on register ────────────────────────────
  await harness.waitFor(() => {
    const db = harness.db();
    try {
      return readActiveCard(db, sessionId)?.state === "active";
    } finally {
      db.close();
    }
  });

  // ── Step 2: first reply-box send ──────────────────────────────
  await harness.fireStopHook(sessionId, "Here is the explanation you asked for.");
  await delay(300);
  await harness.sendInstruction(sessionId, "explain the refactor");

  // run_state → running, user transcript exists
  await harness.waitFor(() => {
    const db = harness.db();
    try {
      const sess = readSession(db, sessionId);
      const userN = readTrafficCount(db, sessionId, ["user"]);
      return sess?.run_state === "running" && userN >= 1;
    } finally {
      db.close();
    }
  });

  // Wait for the fake to finish producing the response.
  await delay(2000);
  await harness.fireStopHook(sessionId, "Here is the explanation you asked for.");
  await delay(300);

  // After Stop, the active card should still exist and be of an
  // actionable category.
  {
    const db = harness.db();
    try {
      const card = readActiveCard(db, sessionId);
      assert.equal(card?.state, "active", "card should still be active after Stop");
      assert.ok(
        ["waiting", "blocker", "decision", "question"].includes(card?.category),
        `card category should be actionable, got ${card?.category}`
      );
    } finally {
      db.close();
    }
  }

  // ── Step 3: user starts typing in the terminal mid-thinking ───
  // Bare keystrokes must NOT dismiss the card. Run_state stays waiting.
  wrapper.stdin.write("h")
  wrapper.stdin.write("i")
  await delay(300)

  {
    const db = harness.db();
    try {
      const sess = readSession(db, sessionId);
      assert.equal(
        sess?.run_state,
        "waiting",
        "bare keystrokes should keep the session in waiting"
      );
    } finally {
      db.close();
    }
  }

  // ── Step 4: user presses Esc; nothing has flipped to running, so
  //          the explicit cancel just reinforces waiting. ────────────
  wrapper.stdin.write(Buffer.from([0x1b]));
  await delay(400);

  await harness.waitFor(() => {
    const db = harness.db();
    try {
      return readSession(db, sessionId)?.run_state === "waiting";
    } finally {
      db.close();
    }
  });

  // ── Step 5: second reply ────────────────────────────────────
  await harness.sendInstruction(sessionId, "what about edge cases?");
  await delay(900);
  await harness.fireStopHook(sessionId, "Here is the explanation you asked for.");
  await delay(300);

  // ── Step 6: third reply gets cancelled with Esc mid-flight ──
  // Ctrl-C 0x03 would also kill the fake provider via SIGINT, which
  // tears the PTY down and is too aggressive for the assertion we
  // care about here. Esc is the same code path through isCancelChunk.
  await harness.sendInstruction(sessionId, "list every place the gate is enforced");
  await delay(800);
  wrapper.stdin.write(Buffer.from([0x1b]));
  await delay(400);

  await harness.waitFor(() => {
    const db = harness.db();
    try {
      return readSession(db, sessionId)?.run_state === "waiting";
    } finally {
      db.close();
    }
  });

  // ── Final assertions: every transition we care about happened ───
  const db = harness.db();
  try {
    const history = readRunStateHistory(db, sessionId);
    const counts = history.reduce((acc, s) => ({ ...acc, [s]: (acc[s] ?? 0) + 1 }), {});
    assert.ok(counts.running >= 3, `should have flipped to running at least 3 times; history=${JSON.stringify(history)}`);
    assert.ok(counts.waiting >= 3, `should have flipped to waiting at least 3 times; history=${JSON.stringify(history)}`);

    // Total transcript volume: should be substantial — three real
    // responses' worth of stdout/stderr/pty bytes.
    const allTraffic = readTrafficCount(db, sessionId, ["report", "stdout", "stderr", "pty", "user"]);
    assert.ok(allTraffic > 20, `expected lots of transcript activity, got ${allTraffic}`);
  } finally {
    db.close();
  }

  wrapper.kill("SIGTERM");
});
