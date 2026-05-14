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
  // metric_events was the historical state log; it was dropped in
  // Phase 3 because nothing read it in production. For test
  // invariants that just want to confirm "did this state ever
  // happen", we now compare against the live `sessions.run_state`.
  // Each call returns a 1-element array — the current state — but
  // the array shape is preserved so existing `.includes(...)`
  // assertions still work.
  const row = db
    .prepare("SELECT run_state FROM sessions WHERE id = ?")
    .get(sessionId);
  return row ? [row.run_state] : [];
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

suite("wrapper invariant: bare stdin keystroke does NOT hide the card", async (t) => {
  // A bare keystroke into the wrapped terminal is *not* enough to
  // dismiss the card. Only real semantic AI output (report / stdout /
  // stderr) or an explicit reply send should flip the gate. Otherwise
  // the user loses the card the moment they think out loud at the
  // prompt — the opposite of what they want.
  const harness = createHarness();
  t.after(() => harness.cleanup());

  await harness.startAgent();
  harness.setPlan({ turns: [{ responseBytes: 0, responseDelayMs: 200 }] });
  const wrapper = harness.spawnWrappedSession();
  const sessionId = await captureSessionId(harness);

  // Push the session into the 'waiting' bucket via a Stop hook; the gate
  // then surfaces an active card.
  await harness.fireStopHook(sessionId, "Need an answer.");
  await delay(300);

  await harness.waitFor(() => {
    const db = harness.db();
    try {
      return readSession(db, sessionId)?.run_state === "waiting";
    } finally {
      db.close();
    }
  });

  // Now type a normal character at the wrapped terminal. The wrapper
  // forwards the byte to the underlying PTY but does NOT emit
  // state=running anymore.
  wrapper.stdin.write("h");
  wrapper.stdin.write("i");
  await delay(500);

  const finalState = (() => {
    const db = harness.db();
    try {
      return readSession(db, sessionId)?.run_state;
    } finally {
      db.close();
    }
  })();

  assert.equal(
    finalState,
    "waiting",
    "bare keystrokes must not flip run_state away from waiting"
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
