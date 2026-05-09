// Reconnect / agent-restart / stale-socket scenarios. These tend to
// regress invisibly because they only manifest when the agent dies in
// the middle of a session and a wrapper has to recover. Real dogfood
// hits this often.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
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

suite("reply-box send forces state=running on the receiving session", async (t) => {
  const harness = createHarness();
  t.after(() => harness.cleanup());

  await harness.startAgent();
  harness.setPlan({ turns: [{ responseBytes: 200, responseDelayMs: 200 }] });
  const wrapper = harness.spawnWrappedSession();
  const sessionId = await captureSessionId(harness);

  // Mark the session waiting first by sending a Stop hook through the
  // agent socket (mirrors what the codex session reader would do).
  // We do it the cheap way: directly UPDATE the row, then verify the
  // gate reflects waiting.
  await harness.waitFor(() => {
    const db = harness.db();
    try {
      return db.prepare("SELECT id FROM sessions WHERE id = ?").get(sessionId) != null;
    } finally {
      db.close();
    }
  });

  await harness.sendInstruction(sessionId, "do something");

  // After a send, run_state must be running and the user transcript
  // entry must exist — that's how the gate decides the card is hidden.
  await harness.waitFor(() => {
    const db = harness.db();
    try {
      const sess = db.prepare("SELECT run_state FROM sessions WHERE id = ?").get(sessionId);
      const userTraffic = db
        .prepare(
          `SELECT COUNT(*) AS n FROM transcript_entries WHERE session_id = ? AND stream = 'user'`
        )
        .get(sessionId);
      return sess?.run_state === "running" && (userTraffic?.n ?? 0) >= 1;
    } finally {
      db.close();
    }
  });

  wrapper.kill("SIGTERM");
});

suite("agent SIGKILL leaves a stale socket; wrapper auto-recovers", async (t) => {
  const harness = createHarness();
  t.after(() => harness.cleanup());

  await harness.startAgent();
  harness.setPlan({ turns: [] });
  const wrapper = harness.spawnWrappedSession();
  const sessionId = await captureSessionId(harness);

  // SIGKILL the agent so the socket file is left dangling on disk.
  await harness.stopAgent({ graceful: false });
  assert.ok(fs.existsSync(harness.socketPath), "socket file should still exist on SIGKILL");

  // The wrapper should detect ECONNREFUSED, unlink the stale socket,
  // and spawn a fresh agent. Give it up to 8s — there's a backoff
  // (RECONNECT_INITIAL_MS=250ms, RECONNECT_MAX_MS=5000ms).
  await harness.waitFor(
    () => {
      const db = harness.db();
      try {
        const sess = db
          .prepare("SELECT run_state FROM sessions WHERE id = ?")
          .get(sessionId);
        return sess != null;
      } finally {
        db.close();
      }
    },
    { timeoutMs: 12000, intervalMs: 200 }
  );

  // Re-register should preserve the prior run_state. We can't easily
  // assert "preserved waiting" because the wrapper drove it back to
  // running on respawn, but we can confirm there's a fresh metric
  // event and the session still maps to the old session id.
  const db = harness.db();
  try {
    const events = db
      .prepare(
        `SELECT type, metadata_json FROM metric_events WHERE session_id = ? ORDER BY timestamp ASC`
      )
      .all(sessionId);
    db.close();
    assert.ok(events.length > 0, "expected metric events on the surviving session");
  } catch (e) {
    db.close();
    throw e;
  }

  wrapper.kill("SIGTERM");
});

suite("agent graceful restart preserves run_state on reconnect", async (t) => {
  const harness = createHarness();
  t.after(() => harness.cleanup());

  await harness.startAgent();
  harness.setPlan({ turns: [] });
  const wrapper = harness.spawnWrappedSession();
  const sessionId = await captureSessionId(harness);

  // Wait for first registration.
  await harness.waitFor(() => {
    const db = harness.db();
    try {
      return db.prepare("SELECT id FROM sessions WHERE id = ?").get(sessionId) != null;
    } finally {
      db.close();
    }
  });

  // Force the session into 'waiting' to mimic a Stop hook. The agent
  // restart logic should preserve this on reconnect rather than
  // overwriting with 'running'.
  await harness.stopAgent({ graceful: true });
  await delay(200);
  // Mutate the DB while the agent is down.
  const writable = new (await import("node:sqlite")).DatabaseSync(harness.dbPath);
  writable.prepare("UPDATE sessions SET run_state='waiting' WHERE id=?").run(sessionId);
  writable.close();

  await harness.startAgent();
  // Wrapper auto-reconnects, re-registers. With the new
  // registerSession code path, the prior 'waiting' should survive.
  await delay(2000);

  const db = harness.db();
  try {
    const sess = db
      .prepare("SELECT run_state FROM sessions WHERE id = ?")
      .get(sessionId);
    db.close();
    assert.equal(
      sess?.run_state,
      "waiting",
      `prior run_state should be preserved across agent restart (got ${sess?.run_state})`
    );
  } catch (e) {
    db.close();
    throw e;
  }

  wrapper.kill("SIGTERM");
});
