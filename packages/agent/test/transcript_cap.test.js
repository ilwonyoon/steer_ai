import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { applyMigrations } from "../src/migrations.js";

// Phase 2 — transcript_entries is a per-session capped buffer.
// Two invariants at the DB layer:
//   1. INSERT trigger keeps per-session rows ≤ 100 (oldest drop).
//   2. session run_state → ended/disconnected drops its transcript.
// Plus the one-time cleanup that runs as part of the migration
// should drop all transcripts for already-ended sessions.

const CAP = 100;

function freshDb() {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "steer-cap-"));
  const db = new DatabaseSync(path.join(tempDir, "test.sqlite"));
  db.exec("PRAGMA foreign_keys = ON;");
  applyMigrations(db, {
    migrationsDir: path.resolve("packages/agent/migrations"),
  });
  db.prepare(
    "INSERT INTO rooms (id, name, is_default, created_at, updated_at) VALUES ('r', 'Default', 1, '2026-01-01', '2026-01-01')"
  ).run();
  return { db, tempDir };
}

function insertSession(db, id, runState = "running") {
  db.prepare(
    "INSERT INTO sessions (id, provider, adapter_kind, command, args_json, cwd, pid, provider_thread_id, run_state, created_at, updated_at, current_room_id) VALUES (?, 'codex', 'pty', 'codex', '[]', '/tmp', 1, NULL, ?, '2026-01-01', '2026-01-01', 'r')"
  ).run(id, runState);
}

function insertTranscript(db, sessionId, stream, chunk = "x") {
  db.prepare(
    "INSERT INTO transcript_entries (id, session_id, timestamp, stream, chunk) VALUES (?, ?, ?, ?, ?)"
  ).run(crypto.randomUUID(), sessionId, new Date().toISOString(), stream, chunk);
}

function transcriptCount(db, sessionId) {
  return db
    .prepare(
      "SELECT COUNT(*) AS c FROM transcript_entries WHERE session_id = ?"
    )
    .get(sessionId).c;
}

test("per-session cap holds at " + CAP + " rows", () => {
  const { db } = freshDb();
  insertSession(db, "s1");
  for (let i = 0; i < CAP + 50; i++) {
    insertTranscript(db, "s1", "pty", "chunk-" + i);
  }
  assert.equal(transcriptCount(db, "s1"), CAP);
  db.close();
});

test("oldest rows are the ones dropped", () => {
  const { db } = freshDb();
  insertSession(db, "s1");
  for (let i = 0; i < CAP + 5; i++) {
    insertTranscript(db, "s1", "pty", "chunk-" + i);
  }
  // The first 5 should be gone; chunks 5..(CAP+4) survive.
  const surviving = db
    .prepare(
      "SELECT chunk FROM transcript_entries WHERE session_id = 's1' ORDER BY rowid ASC LIMIT 1"
    )
    .get();
  assert.equal(surviving.chunk, "chunk-5");
  db.close();
});

test("cap is per session — two sessions both keep " + CAP + " each", () => {
  const { db } = freshDb();
  insertSession(db, "a");
  insertSession(db, "b");
  for (let i = 0; i < CAP + 20; i++) {
    insertTranscript(db, "a", "pty");
    insertTranscript(db, "b", "stdout");
  }
  assert.equal(transcriptCount(db, "a"), CAP);
  assert.equal(transcriptCount(db, "b"), CAP);
  db.close();
});

test("session → ended drops its transcript", () => {
  const { db } = freshDb();
  insertSession(db, "s1");
  for (let i = 0; i < 50; i++) insertTranscript(db, "s1", "pty");
  assert.equal(transcriptCount(db, "s1"), 50);
  db.prepare(
    "UPDATE sessions SET run_state = 'ended', updated_at = '2026-01-02' WHERE id = ?"
  ).run("s1");
  assert.equal(transcriptCount(db, "s1"), 0);
  db.close();
});

test("session → disconnected drops its transcript", () => {
  const { db } = freshDb();
  insertSession(db, "s1");
  for (let i = 0; i < 30; i++) insertTranscript(db, "s1", "pty");
  db.prepare(
    "UPDATE sessions SET run_state = 'disconnected', updated_at = '2026-01-02' WHERE id = ?"
  ).run("s1");
  assert.equal(transcriptCount(db, "s1"), 0);
  db.close();
});

test("running → waiting → running keeps transcript", () => {
  // Only ended/disconnected drop. Intermediate states between
  // running/waiting/blocked are normal turn-by-turn lifecycle and
  // must preserve the working buffer.
  const { db } = freshDb();
  insertSession(db, "s1");
  for (let i = 0; i < 20; i++) insertTranscript(db, "s1", "pty");
  db.prepare(
    "UPDATE sessions SET run_state = 'waiting' WHERE id = ?"
  ).run("s1");
  assert.equal(transcriptCount(db, "s1"), 20);
  db.prepare(
    "UPDATE sessions SET run_state = 'running' WHERE id = ?"
  ).run("s1");
  assert.equal(transcriptCount(db, "s1"), 20);
  db.close();
});
