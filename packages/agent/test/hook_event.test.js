import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { createStore } from "../src/store.js";

test("Claude Stop hook creates an active action card from the final assistant message", () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "steer-agent-hook-"));
  const dbPath = path.join(tempDir, "steer.sqlite");
  const store = createStore(dbPath);

  store.upsertSession({
    id: "claude-test-session",
    provider: "claude",
    adapterKind: "pty-bridge",
    command: "claude",
    args: [],
    cwd: tempDir,
    pid: 123,
    runState: "running",
    createdAt: "2026-05-06T23:00:00.000Z",
    updatedAt: "2026-05-06T23:00:00.000Z",
    currentRoomId: store.defaultRoomId
  });

  store.recordHookEvent({
    sessionId: "claude-test-session",
    provider: "claude",
    eventName: "Stop",
    providerSessionId: "provider-session",
    lastAssistantMessage: "Decision needed: choose Option A or Option B before I continue.",
    rawPayload: {}
  });
  store.updateSessionState("claude-test-session", "waiting");
  store.close();

  const db = new DatabaseSync(dbPath);
  const card = db.prepare(`
    SELECT category, state, title, summary, options_json
    FROM action_cards
    WHERE session_id = ?
  `).get("claude-test-session");
  db.close();

  assert.equal(card.category, "decision");
  assert.equal(card.state, "active");
  assert.match(card.title, /Claude Code/);
  assert.match(card.summary, /Option B/);
  assert.deepEqual(JSON.parse(card.options_json), ["Use your recommendation", "Pick simpler option", "Explain options"]);
});

test("Claude Stop hook keeps completion reports active because the session stopped", () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "steer-agent-hook-"));
  const dbPath = path.join(tempDir, "steer.sqlite");
  const store = createStore(dbPath);

  store.upsertSession({
    id: "claude-complete-stop",
    provider: "claude",
    adapterKind: "pty-bridge",
    command: "claude",
    args: [],
    cwd: tempDir,
    pid: 123,
    runState: "running",
    createdAt: "2026-05-06T23:00:00.000Z",
    updatedAt: "2026-05-06T23:00:00.000Z",
    currentRoomId: store.defaultRoomId
  });

  store.recordHookEvent({
    sessionId: "claude-complete-stop",
    provider: "claude",
    eventName: "Stop",
    providerSessionId: "provider-session",
    lastAssistantMessage: "Completed the requested change and all tests passed.",
    rawPayload: {}
  });
  store.updateSessionState("claude-complete-stop", "waiting");
  store.close();

  const db = new DatabaseSync(dbPath);
  const card = db.prepare(`
    SELECT category, state, title, summary, options_json
    FROM action_cards
    WHERE session_id = ?
  `).get("claude-complete-stop");
  db.close();

  assert.equal(card.category, "waiting");
  assert.equal(card.state, "active");
  assert.match(card.title, /is waiting/);
  assert.match(card.summary, /tests passed/);
  assert.deepEqual(JSON.parse(card.options_json), ["Continue", "Summarize result", "Start next task"]);
});
