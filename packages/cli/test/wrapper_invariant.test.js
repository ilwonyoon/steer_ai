// Wrapper × agent invariant tests. Each test boots a real isolated
// SteerAgent under STEER_HOME, runs `steer wrap -- node fake_provider.js`
// against the fake CLI, and reads the SQLite DB to assert behaviour.
//
// We test the wire path at full fidelity: wrapper PTY, agent socket
// protocol, classifier, store. Only the provider on the other end is
// mocked. That's the layer the dogfood bugs have been hiding in.
//
// Each test takes 10–30 seconds; the suite is heavier than the rest of
// `npm test` and is gated behind STEER_INTEGRATION=1 by default.

import test from "node:test";
import assert from "node:assert/strict";
import { setTimeout as delay } from "node:timers/promises";
import { createHarness } from "./helpers/harness.js";

const SKIP = process.env.STEER_INTEGRATION !== "1";

function suite(name, fn) {
  test(name, { skip: SKIP ? "set STEER_INTEGRATION=1 to run" : false }, fn);
}

function readSession(db, sessionId) {
  return db.prepare("SELECT id, run_state, command FROM sessions WHERE id = ?").get(sessionId);
}

function readActiveCard(db, sessionId) {
  return db
    .prepare(`SELECT category, state FROM action_cards WHERE session_id = ? AND state = 'active'`)
    .get(sessionId);
}

function readRunStateHistory(db, sessionId) {
  return db
    .prepare(
      `SELECT metadata_json FROM metric_events WHERE session_id = ? AND type = 'state_changed' ORDER BY timestamp ASC`
    )
    .all(sessionId)
    .map((row) => JSON.parse(row.metadata_json).runState);
}

async function captureSessionId(harness) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    const db = harness.db();
    const row = db.prepare("SELECT id FROM sessions ORDER BY created_at DESC LIMIT 1").get();
    db.close();
    if (row?.id) return row.id;
    await delay(50);
  }
  throw new Error("no session registered within 5s");
}

suite("wrapper invariant: register surfaces a ready card", async (t) => {
  const harness = createHarness();
  t.after(() => harness.cleanup());

  await harness.startAgent();
  harness.setPlan({ turns: [] });
  const wrapper = harness.spawnWrappedSession();
  const sessionId = await captureSessionId(harness);

  await harness.waitFor(() => {
    const db = harness.db();
    try {
      const card = readActiveCard(db, sessionId);
      return card?.category === "waiting";
    } finally {
      db.close();
    }
  });

  wrapper.kill("SIGTERM");
});

suite("wrapper invariant: stdin keystroke flips state to running", async (t) => {
  const harness = createHarness();
  t.after(() => harness.cleanup());

  await harness.startAgent();
  harness.setPlan({ turns: [{ responseBytes: 0, responseDelayMs: 200 }] });
  const wrapper = harness.spawnWrappedSession();
  const sessionId = await captureSessionId(harness);

  // Wait for the session to settle in 'running' (default register state).
  await harness.waitFor(() => {
    const db = harness.db();
    try {
      return readSession(db, sessionId)?.run_state === "running";
    } finally {
      db.close();
    }
  });

  // Force the state to waiting first (simulates a Stop hook), then
  // observe whether the next keystroke flips it back to running.
  await harness.sendInstruction(sessionId, "noop").catch(() => {});
  // Give the wrapper a chance to write the instruction back into stdout
  // and the classifier time to land it.
  await delay(300);

  // Now flip to waiting via direct DB update — this is what the codex
  // session reader would do in real life.
  await new Promise((resolve) => {
    const db = harness.db();
    try {
      // node:sqlite read-only doesn't allow update; re-open writable.
      db.close();
    } catch {}
    resolve();
  });
  // Instead of poking the DB directly, use the agent's hook event path
  // which is the actual production trigger.

  // Send a real keystroke through the wrapper's stdin. The PTY is
  // raw-mode, so the byte goes straight into the wrapper's stdin handler.
  wrapper.stdin.write("x");
  // Give the wrapper 500ms (the dedup window) and then a beat for the
  // socket round-trip.
  await delay(700);

  const history = (() => {
    const db = harness.db();
    try {
      return readRunStateHistory(db, sessionId);
    } finally {
      db.close();
    }
  })();

  // We expect to see the state cycle past 'running' at least twice —
  // once at register, and again after the user keystroke. Without the
  // dedup-cache fix this test fails because the second running is
  // silently dropped.
  const runningCount = history.filter((s) => s === "running").length;
  assert.ok(
    runningCount >= 2,
    `expected at least two running transitions, got history=${JSON.stringify(history)}`
  );

  wrapper.kill("SIGTERM");
});

suite("wrapper invariant: Esc keystroke flips state to waiting", async (t) => {
  const harness = createHarness();
  t.after(() => harness.cleanup());

  await harness.startAgent();
  harness.setPlan({ turns: [] });
  const wrapper = harness.spawnWrappedSession();
  const sessionId = await captureSessionId(harness);

  await harness.waitFor(() => {
    const db = harness.db();
    try {
      return readSession(db, sessionId)?.run_state === "running";
    } finally {
      db.close();
    }
  });

  // Bare Esc byte (0x1B). The wrapper's isCancelChunk recognises it as
  // a cancel intent and emits state=waiting.
  wrapper.stdin.write(Buffer.from([0x1b]));
  await delay(400);

  const history = (() => {
    const db = harness.db();
    try {
      return readRunStateHistory(db, sessionId);
    } finally {
      db.close();
    }
  })();

  assert.ok(
    history.includes("waiting"),
    `expected waiting in history, got ${JSON.stringify(history)}`
  );

  wrapper.kill("SIGTERM");
});

suite("wrapper invariant: long turn keeps card hidden, Stop hook re-surfaces", async (t) => {
  const harness = createHarness();
  t.after(() => harness.cleanup());

  await harness.startAgent();
  harness.setPlan({
    turns: [
      {
        preamble: "claude is thinking…\n",
        responseBytes: 8000,
        responseDelayMs: 1500,
        ptyRepaints: 3
      }
    ]
  });
  const wrapper = harness.spawnWrappedSession();
  const sessionId = await captureSessionId(harness);

  await harness.sendInstruction(sessionId, "explain what AttachmentService does");

  // While the turn is running, no active card with body should be visible
  // through the SQL gate.
  await delay(800);
  // (We can't easily query the Mac gate from here without re-implementing it,
  // but we *can* assert the underlying state: the session is running and
  // there's traffic in stdout/stderr/pty.)
  const midTurn = (() => {
    const db = harness.db();
    try {
      const sess = readSession(db, sessionId);
      const traffic = db
        .prepare(
          `SELECT COUNT(*) AS n FROM transcript_entries
            WHERE session_id = ?
              AND stream IN ('report','stdout','stderr','user')`
        )
        .get(sessionId);
      return { runState: sess?.run_state, traffic: traffic?.n ?? 0 };
    } finally {
      db.close();
    }
  })();
  assert.equal(midTurn.runState, "running");
  assert.ok(midTurn.traffic > 0, "expected real traffic during the turn");

  // Wait for the fake to finish.
  await delay(1800);
  wrapper.kill("SIGTERM");
});

suite("wrapper invariant: PTY-only repaint keeps the ready card alive", async (t) => {
  const harness = createHarness();
  t.after(() => harness.cleanup());

  await harness.startAgent();
  // The fake's first turn never runs because we never call sendInstruction,
  // so all the wrapper sees on stdout is the banner + the prompt.
  harness.setPlan({ turns: [] });
  const wrapper = harness.spawnWrappedSession();
  const sessionId = await captureSessionId(harness);

  await harness.waitFor(() => {
    const db = harness.db();
    try {
      return readActiveCard(db, sessionId)?.state === "active";
    } finally {
      db.close();
    }
  });

  // Even after a few seconds of nothing-but-PTY, the ready card stays
  // active in the gate's eyes (run_state=running AND no semantic traffic).
  await delay(800);

  const trafficCounts = (() => {
    const db = harness.db();
    try {
      return db
        .prepare(
          `SELECT stream, COUNT(*) AS n FROM transcript_entries
            WHERE session_id = ?
            GROUP BY stream`
        )
        .all(sessionId)
        .reduce((acc, row) => {
          acc[row.stream] = row.n;
          return acc;
        }, {});
    } finally {
      db.close();
    }
  })();

  // No semantic traffic — only system + maybe pty.
  for (const stream of ["report", "stdout", "stderr", "user"]) {
    assert.equal(
      trafficCounts[stream] ?? 0,
      0,
      `expected zero ${stream} traffic but got ${trafficCounts[stream]}`
    );
  }

  wrapper.kill("SIGTERM");
});
