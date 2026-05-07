import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { createStore } from "../src/store.js";

function createLifecycleStore() {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "steer-lifecycle-"));
  const dbPath = path.join(tempDir, "steer.sqlite");
  const store = createStore(dbPath);
  const now = "2026-05-06T23:00:00.000Z";

  store.upsertSession({
    id: "codex-lifecycle",
    provider: "codex",
    adapterKind: "pty-bridge",
    command: "codex",
    args: [],
    cwd: tempDir,
    pid: process.pid,
    runState: "running",
    createdAt: now,
    updatedAt: now,
    currentRoomId: store.defaultRoomId
  });

  return { store, dbPath };
}

function readCard(dbPath) {
  const db = new DatabaseSync(dbPath);
  const card = db.prepare(`
    SELECT category, state, title, summary, options_json
    FROM action_cards
    WHERE session_id = 'codex-lifecycle'
  `).get();
  db.close();
  return card;
}

function readTranscriptStreams(dbPath) {
  const db = new DatabaseSync(dbPath);
  const rows = db.prepare(`
    SELECT stream, chunk
    FROM transcript_entries
    WHERE session_id = 'codex-lifecycle'
    ORDER BY timestamp ASC
  `).all();
  db.close();
  return rows;
}

test("lifecycle contract: reply closes the card and next provider report reopens it", () => {
  const { store, dbPath } = createLifecycleStore();

  store.recordHookEvent({
    sessionId: "codex-lifecycle",
    provider: "codex",
    eventName: "Stop",
    providerSessionId: "provider-session",
    lastAssistantMessage: "Question: should I continue with the simpler implementation?",
    rawPayload: {}
  });
  store.updateSessionState("codex-lifecycle", "waiting");

  let card = readCard(dbPath);
  assert.equal(card.state, "active");
  assert.equal(card.category, "question");
  assert.match(card.summary, /simpler implementation/);

  store.createInstruction({
    id: "instruction-1",
    sessionId: "codex-lifecycle",
    text: "Yes, continue."
  });
  store.appendTranscript({
    sessionId: "codex-lifecycle",
    stream: "user",
    chunk: "[user] Yes, continue.\n"
  });
  store.resolveActionCardsForSession("codex-lifecycle");

  card = readCard(dbPath);
  assert.equal(card.state, "done");

  store.recordHookEvent({
    sessionId: "codex-lifecycle",
    provider: "codex",
    eventName: "Stop",
    providerSessionId: "provider-session",
    lastAssistantMessage: "Completed the requested change.\n\nNext: review the diff and tell me what to adjust.",
    rawPayload: {}
  });
  store.updateSessionState("codex-lifecycle", "waiting");
  store.close();

  card = readCard(dbPath);
  assert.equal(card.state, "active");
  assert.equal(card.category, "waiting");
  assert.match(card.summary, /adjust/);

  const streams = readTranscriptStreams(dbPath).map((row) => row.stream);
  assert.ok(streams.includes("report"));
  assert.ok(streams.includes("user"));
});

test("lifecycle contract: disconnected sessions do not keep active cards", () => {
  const { store, dbPath } = createLifecycleStore();

  store.recordHookEvent({
    sessionId: "codex-lifecycle",
    provider: "codex",
    eventName: "Stop",
    providerSessionId: "provider-session",
    lastAssistantMessage: "Need answer before continuing?",
    rawPayload: {}
  });
  store.updateSessionState("codex-lifecycle", "waiting");
  assert.equal(readCard(dbPath).state, "active");

  store.updateSessionState("codex-lifecycle", "disconnected");
  store.close();

  const card = readCard(dbPath);
  assert.equal(card.state, "done");
  assert.equal(card.category, "disconnected");
});

test("lifecycle contract: PTY repaint is never enough to create an active action card", () => {
  const { store, dbPath } = createLifecycleStore();

  store.appendTranscript({
    sessionId: "codex-lifecycle",
    stream: "pty",
    chunk: "\x1B]9;Useful live preview text\x07\x1B[50;1H\r\n─ Worked for 1m 05s ─\r\n"
  });
  store.close();

  const card = readCard(dbPath);
  assert.equal(card.state, "done");
  assert.equal(card.category, "progress");
  assert.equal(card.summary, "[no transcript yet]");
});
