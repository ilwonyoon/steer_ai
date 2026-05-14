import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { createStore } from "../src/store.js";

// G15.B — classifier must not regress an active reply to the
// "session just opened" stub after PTY repaint flood.
//
// This is the iPhone-visible failure mode of the 5/13 regression:
// the user sent a reply, the AI answered, but ~50 min later the
// iPhone showed a card whose summary was
//   "codex session opened; send your first instruction."
//
// Root cause: per-session 100-row cap evicted the user + report
// rows under PTY status repaint flood, leaving the classifier
// with no trusted output and no user index → it emits the stub
// waiting card and overwrites the real one.
//
// Today's code FAILS this test by emitting the stub. Step 1
// (session-state snapshot) flips it to PASS by letting the
// classifier consult last_user_text / last_trusted_text columns
// that survive the cap.

function freshStore() {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "steer-stub-"));
  const dbPath = path.join(tempDir, "store.sqlite");
  const store = createStore(dbPath);
  return { store, tempDir, dbPath };
}

function rawQuery(dbPath) {
  return new DatabaseSync(dbPath);
}

test("CONTRACT: PTY flood after a real reply keeps the real reply card", () => {
  const { store, dbPath } = freshStore();

  store.upsertSession({
    id: "s1",
    provider: "codex",
    adapterKind: "pty",
    command: "codex",
    args: [],
    cwd: "/tmp",
    pid: 1234,
    runState: "running",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
  });

  // 1) user sends an instruction → wrapper appends a user row.
  store.appendTranscript({
    sessionId: "s1",
    stream: "user",
    chunk: "[user] please answer\n",
  });

  // 2) provider replies with a trusted report row.
  store.appendTranscript({
    sessionId: "s1",
    stream: "report",
    chunk: "Sure. The answer is 42.\n",
  });

  // 3) Two minutes of PTY status-bar repaint, ~60 chunks/min.
  for (let i = 0; i < 120; i++) {
    store.appendTranscript({
      sessionId: "s1",
      stream: "pty",
      // Non-whitespace control bytes — isWhitespaceOnlyPty must
      // not filter these out, mirroring real codex repaint.
      chunk: `\x1b[41;2HR${i}`,
    });
  }

  store.close();

  // The action_card row reflects the latest classifier verdict.
  // We read it raw — UI / iPhone see exactly this summary.
  const db = rawQuery(dbPath);
  const card = db
    .prepare(
      "SELECT category, state, summary FROM action_cards WHERE session_id = ?"
    )
    .get("s1");
  db.close();

  const stubSummary = card.summary.toLowerCase();
  const isStub =
    stubSummary.includes("session opened") ||
    stubSummary.includes("send your first instruction") ||
    stubSummary.includes("just opened");

  assert.equal(
    isStub,
    false,
    `stub card must not overwrite real reply. summary=${card.summary}`
  );
  assert.match(card.summary, /42/, "real reply text must survive PTY flood");
});

test("CONTRACT: 5000-chunk PTY flood after a reply still preserves the reply", () => {
  // Heavy version of the same contract — an hour-plus of PTY
  // status repaint must not regress the snapshot-backed card.
  const { store, dbPath } = freshStore();

  store.upsertSession({
    id: "s1",
    provider: "codex",
    adapterKind: "pty",
    command: "codex",
    args: [],
    cwd: "/tmp",
    pid: 1234,
    runState: "running",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
  });

  store.appendTranscript({
    sessionId: "s1",
    stream: "user",
    chunk: "[user] please answer\n",
  });
  store.appendTranscript({
    sessionId: "s1",
    stream: "report",
    chunk: "Sure. The answer is 42.\n",
  });

  for (let i = 0; i < 5000; i++) {
    store.appendTranscript({
      sessionId: "s1",
      stream: "pty",
      chunk: `\x1b[41;2HR${i}`,
    });
  }

  store.close();

  const db = rawQuery(dbPath);
  const card = db
    .prepare(
      "SELECT category, state, summary FROM action_cards WHERE session_id = ?"
    )
    .get("s1");
  db.close();

  const stubSummary = card.summary.toLowerCase();
  const isStub =
    stubSummary.includes("session opened") ||
    stubSummary.includes("send your first instruction") ||
    stubSummary.includes("just opened");

  assert.equal(
    isStub,
    false,
    `post-Step-1: stub must not overwrite the real reply. summary=${card.summary}`
  );
});
