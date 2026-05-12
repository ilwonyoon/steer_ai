// Reproduction tests for the wrapper-layer codex_session_reader
// regression observed in dogfood on 2026-05-12:
//
//   - User's freshly-spawned `steer codex` wrapper (pid 65563).
//   - Codex wrote `agent_message phase=final_answer` to its jsonl.
//   - But agent.report stream stayed at zero entries for that
//     session — the wrapper never forwarded the line.
//   - Aido session that had been running since the previous day
//     kept forwarding correctly. The difference is timing /
//     state of the codex_session_reader at wrapper boot.
//
// What this file proves:
//   1. The reader emits final_answer messages it writes AFTER
//      the spawnedAt timestamp (the working case).
//   2. The reader emits final_answer messages it writes BEFORE
//      the spawnedAt timestamp if the jsonl filename is recent
//      enough (i.e. SPAWN_WINDOW_MS).
//   3. The reader does NOT silently swallow messages when the
//      jsonl filename is exactly at the spawn moment (the
//      dogfood scenario; jsonl created 1s after wrapper spawn).
//
// All three are pure JS-level checks against the
// codex_session_reader module — no Codex subprocess required.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";

// The reader reads STEER_CODEX_SESSIONS_DIR PER POLL (function
// call, not module-level constant) so each test can safely
// repoint it without re-importing the module. See
// codex_session_reader.js codexSessionsDir().
import { startCodexSessionReader } from "../src/codex_session_reader.js";

const SESSIONS_ROOT = fs.mkdtempSync(
  path.join(os.tmpdir(), "steer-codex-reader-root-")
);

async function loadReader(sessionsDir) {
  process.env.STEER_CODEX_SESSIONS_DIR = sessionsDir;
  return startCodexSessionReader;
}

let sessionCounter = 0;
function makeCodexHome() {
  sessionCounter += 1;
  const sessionsDir = path.join(SESSIONS_ROOT, `t${sessionCounter}`);
  fs.mkdirSync(sessionsDir, { recursive: true });
  return { sessionsDir };
}

// Compatibility shim: existing tests called patchHome+restore.
function patchHome() {
  return () => {};
}

function writeRolloutFile(sessionsDir, filename, lines) {
  const filePath = path.join(sessionsDir, filename);
  fs.writeFileSync(filePath, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
  return filePath;
}

function appendLine(filePath, obj) {
  fs.appendFileSync(filePath, JSON.stringify(obj) + "\n");
}

function finalAnswerLine(timestamp, message) {
  return {
    timestamp,
    type: "event_msg",
    payload: {
      type: "agent_message",
      message,
      phase: "final_answer",
    },
  };
}

// A poll cycle is ~150 ms in production; give the reader several
// cycles to discover + read + emit.
const POLL_GRACE_MS = 1500;

test("emits final_answer message written AFTER spawnedAt", async () => {
  const { home, sessionsDir } = makeCodexHome();
  const restore = patchHome(home);
  try {
    const spawnedAt = new Date("2026-05-12T18:03:48.000Z");
    const filePath = writeRolloutFile(
      sessionsDir,
      "rollout-2026-05-12T11-03-49-test-after.jsonl",
      []
    );

    const startCodexSessionReader = await loadReader(sessionsDir);
    const received = [];
    const reader = startCodexSessionReader({
      spawnedAt,
      onAgentMessage: (m) => received.push(m),
      onError: () => {},
    });

    // Codex writes the answer 5s into the session.
    await delay(300);
    appendLine(filePath, finalAnswerLine("2026-05-12T18:03:53.000Z", "11:04"));
    await delay(POLL_GRACE_MS);

    reader.stop();
    assert.deepEqual(received, ["11:04"]);
  } finally {
    restore();
  }
});

test("emits final_answer message that ALREADY existed when the reader started", async () => {
  const { home, sessionsDir } = makeCodexHome();
  const restore = patchHome(home);
  try {
    const spawnedAt = new Date("2026-05-12T18:03:48.000Z");
    writeRolloutFile(
      sessionsDir,
      "rollout-2026-05-12T11-03-49-test-existing.jsonl",
      [finalAnswerLine("2026-05-12T18:03:53.000Z", "already-there")]
    );

    const startCodexSessionReader = await loadReader(sessionsDir);
    const received = [];
    const reader = startCodexSessionReader({
      spawnedAt,
      onAgentMessage: (m) => received.push(m),
      onError: () => {},
    });
    await delay(POLL_GRACE_MS);
    reader.stop();

    assert.deepEqual(received, ["already-there"]);
  } finally {
    restore();
  }
});

test("emits final_answer when the jsonl exists at spawn time and gets appended (the dogfood scenario)", async () => {
  // This is the scenario the user hit. Wrapper starts; codex
  // creates jsonl ~1s later; wrapper picks up filename via
  // SPAWN_WINDOW_MS; codex appends final_answer; wrapper SHOULD
  // emit it.
  const { home, sessionsDir } = makeCodexHome();
  const restore = patchHome(home);
  try {
    const spawnedAt = new Date("2026-05-12T18:03:48.000Z");
    // jsonl is created 1 second after spawnedAt.
    const filePath = writeRolloutFile(
      sessionsDir,
      "rollout-2026-05-12T11-03-49-dogfood.jsonl",
      []
    );

    const startCodexSessionReader = await loadReader(sessionsDir);
    const received = [];
    const reader = startCodexSessionReader({
      spawnedAt,
      onAgentMessage: (m) => received.push(m),
      onError: () => {},
    });

    // First polling cycle finds the (empty) jsonl, then we append.
    await delay(300);
    // Replicate what codex writes in real life — a few non-final
    // event_msg lines, then the final answer.
    appendLine(filePath, {
      timestamp: "2026-05-12T18:04:13.053Z",
      type: "event_msg",
      payload: { type: "token_count" },
    });
    appendLine(filePath, finalAnswerLine("2026-05-12T18:04:15.069Z", "dogfood-answer"));
    await delay(POLL_GRACE_MS);

    reader.stop();
    assert.deepEqual(
      received,
      ["dogfood-answer"],
      "the line appended after wrapper started watching must reach onAgentMessage"
    );
  } finally {
    restore();
  }
});

test("does NOT emit final_answer from a jsonl whose filename predates spawnedAt by more than 2s", async () => {
  // Sanity: an old session shouldn't leak into a fresh wrapper.
  const { home, sessionsDir } = makeCodexHome();
  const restore = patchHome(home);
  try {
    const spawnedAt = new Date("2026-05-12T18:03:48.000Z");
    writeRolloutFile(
      sessionsDir,
      "rollout-2026-05-11T11-00-00-stale.jsonl",
      [finalAnswerLine("2026-05-11T18:00:00.000Z", "old-session-answer")]
    );

    const startCodexSessionReader = await loadReader(sessionsDir);
    const received = [];
    const reader = startCodexSessionReader({
      spawnedAt,
      onAgentMessage: (m) => received.push(m),
      onError: () => {},
    });
    await delay(POLL_GRACE_MS);
    reader.stop();

    assert.deepEqual(received, []);
  } finally {
    restore();
  }
});

test("RECOVERS when codex's jsonl appears later than DISCOVERY_TIMEOUT_MS (the dogfood bug)", async () => {
  // The actual production scenario from 2026-05-12:
  //   - Wrapper spawned at t=0.
  //   - Codex jsonl filename was findable by SPAWN_WINDOW_MS rules
  //     but didn't actually appear on disk for over 15s for some
  //     reason (slow disk, ENOENT race, codex's own startup
  //     deferred jsonl creation, etc).
  //   - Pre-fix code: discovery timeout fires, onError is called
  //     once, the `return;` skips scheduleNextPoll, so the reader
  //     is permanently dead. Even when the jsonl shows up later,
  //     no final_answer ever reaches onAgentMessage.
  //
  // After fix: the reader keeps polling past the timeout (with
  // at most one warning to onError), so when codex's output
  // finally lands it gets forwarded normally.
  const { home, sessionsDir } = makeCodexHome();
  const restore = patchHome(home);
  try {
    const spawnedAt = new Date(Date.now()); // real time so DISCOVERY_TIMEOUT_MS=15s actually fires
    let errorCount = 0;
    const startCodexSessionReader = await loadReader(sessionsDir);
    const received = [];
    const reader = startCodexSessionReader({
      spawnedAt,
      onAgentMessage: (m) => received.push(m),
      onError: () => { errorCount += 1; },
    });

    // No jsonl exists for >15s, then we create one + append a
    // final answer. The reader MUST still pick it up.
    //
    // 16s is unfortunately the test wall clock cost, but it's
    // exactly the production codepath we need to prove fixed.
    await delay(16_000);
    // jsonl filename uses current time so SPAWN_WINDOW_MS rules
    // accept it relative to spawnedAt (we used spawnedAt = now,
    // so this is +16s, inside the 30s window).
    const ts = new Date();
    const fname = `rollout-${ts.getFullYear()}-${String(ts.getMonth()+1).padStart(2,"0")}-${String(ts.getDate()).padStart(2,"0")}T${String(ts.getHours()).padStart(2,"0")}-${String(ts.getMinutes()).padStart(2,"0")}-${String(ts.getSeconds()).padStart(2,"0")}-late.jsonl`;
    const filePath = path.join(sessionsDir, fname);
    fs.writeFileSync(filePath, "");
    await delay(500);
    appendLine(filePath, finalAnswerLine(new Date().toISOString(), "late-answer"));
    await delay(POLL_GRACE_MS);
    reader.stop();

    assert.deepEqual(
      received,
      ["late-answer"],
      "reader must keep polling past DISCOVERY_TIMEOUT_MS and emit late jsonl"
    );
  } finally {
    restore();
  }
});
