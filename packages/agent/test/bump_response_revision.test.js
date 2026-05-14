import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { createStore } from "../src/store.js";

// G15.b — bumpResponseRevisionIfReady contract.
//
// After Send: agent stamps awaiting_response_since.
// After codex final_answer reaches the wrapper: a trusted report
// chunk lands, last_trusted_at gets set.
// At that point bumpResponseRevisionIfReady must fire ONCE,
// incrementing last_response_revision by 1 and clearing
// awaiting_response_since (atomic, single statement).
//
// The chip on iPhone reacts to that revision bump — it's the
// signal "the response arrived." If this contract slips, chip
// stays on forever (no answer detected) OR fires prematurely
// (pre-existing trusted line leaks through).

function freshStore() {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "steer-bump-"));
  const dbPath = path.join(tempDir, "store.sqlite");
  const store = createStore(dbPath);
  return { store, dbPath };
}

function rawQuery(dbPath) {
  return new DatabaseSync(dbPath);
}

function readSession(dbPath, id) {
  const db = rawQuery(dbPath);
  const row = db
    .prepare(
      `SELECT id, run_state, last_response_revision, awaiting_response_since,
              last_user_text, last_trusted_text, last_user_at, last_trusted_at
       FROM sessions WHERE id = ?`
    )
    .get(id);
  db.close();
  return row;
}

test("bump fires when first trusted chunk lands after awaiting", async () => {
  const { store, dbPath } = freshStore();
  store.upsertSession({
    id: "s1",
    provider: "codex",
    adapterKind: "pty",
    command: "codex",
    args: [],
    cwd: "/tmp",
    pid: 1,
    runState: "running",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
  });

  // Pre-existing trusted chunk (e.g. a previous turn).
  store.appendTranscript({
    sessionId: "s1",
    stream: "report",
    chunk: "previous reply\n",
  });
  const before = readSession(dbPath, "s1");
  assert.equal(before.last_response_revision, 0);
  assert.notEqual(before.last_trusted_at, null);

  // User Send — stamps awaiting *after* the existing last_trusted_at.
  store.createInstruction({
    id: "i1",
    sessionId: "s1",
    text: "next reply",
  });

  const afterSend = readSession(dbPath, "s1");
  assert.notEqual(afterSend.awaiting_response_since, null);
  // Revision must NOT bump on Send — the existing last_trusted_at
  // is older than awaiting_response_since by the time we stamp it.
  assert.equal(afterSend.last_response_revision, 0);

  // Now a trusted report chunk arrives — that's "the answer."
  // Small delay so timestamps strictly increase.
  const after = await new Promise((resolve) => {
    setTimeout(() => {
      store.appendTranscript({
        sessionId: "s1",
        stream: "report",
        chunk: "answer for next reply\n",
      });
      resolve(readSession(dbPath, "s1"));
    }, 20);
  });

  // The contract: bump fires, awaiting clears.
  assert.equal(after.last_response_revision, 1);
  assert.equal(after.awaiting_response_since, null);
  assert.match(after.last_trusted_text, /answer for next reply/);

  store.close();
});
