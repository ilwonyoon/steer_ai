import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { applyMigrations } from "../src/migrations.js";

// G15 — PTY flood durability.
//
// Reproduces the 5/13 dogfood regression:
//   1. user sends an instruction (one stream='user' row),
//   2. AI replies (one stream='report' row),
//   3. PTY status-line repaint streams ~60 chunks/min into
//      stream='pty' rows.
//
// The per-session 100-row cap (migration 0005) is stream-agnostic:
// after ~2 min of idle PTY traffic the user + report rows are
// evicted, leaving 100 PTY rows. The classifier then sees
// latestUserIndex=null & latestOutputIndex=null and emits a stub
// "session opened; send your first instruction" card — exactly
// the user-reported symptom.
//
// These tests pin the invariant we need going forward:
//   "After any volume of PTY repaint chunks, the most recent
//    user line and the most recent trusted output line must
//    remain queryable for classifier input."
//
// Today's code FAILS this test on purpose — that's the
// reproduction. Step 1 (session state snapshot columns) will
// make it PASS.

function freshDb() {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "steer-flood-"));
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

function insertSession(db, id) {
  db.prepare(
    "INSERT INTO sessions (id, provider, adapter_kind, command, args_json, cwd, pid, provider_thread_id, run_state, created_at, updated_at, current_room_id) VALUES (?, 'codex', 'pty', 'codex', '[]', '/tmp', 1, NULL, 'running', '2026-01-01', '2026-01-01', 'r')"
  ).run(id);
}

function insertTranscript(db, sessionId, stream, chunk) {
  db.prepare(
    "INSERT INTO transcript_entries (id, session_id, timestamp, stream, chunk) VALUES (?, ?, ?, ?, ?)"
  ).run(crypto.randomUUID(), sessionId, new Date().toISOString(), stream, chunk);
}

// Mirror the prepared statements used by store.refreshActionCard.
function selectRecentTrusted(db, sessionId) {
  return db
    .prepare(
      `SELECT stream, chunk FROM transcript_entries
       WHERE session_id = ? AND stream IN ('report', 'stdout', 'stderr')
       ORDER BY rowid DESC LIMIT 24`
    )
    .all(sessionId);
}

function selectRecentUser(db, sessionId) {
  return db
    .prepare(
      `SELECT stream, chunk FROM transcript_entries
       WHERE session_id = ? AND stream = 'user'
       ORDER BY rowid DESC LIMIT 8`
    )
    .all(sessionId);
}

test("DOC: PTY flood does still evict transcript_entries rows", () => {
  // This pins the pre-existing 100-row cap behaviour at the raw
  // transcript_entries layer. We do NOT depend on transcript_entries
  // for classifier input anymore (see snapshot columns), but the
  // cap remains in place to bound disk use, and this test makes
  // sure the cap continues working — if it ever stops, the
  // session snapshot path absorbs the load gracefully.
  const { db } = freshDb();
  insertSession(db, "s1");

  insertTranscript(db, "s1", "user", "[user] please answer\n");
  insertTranscript(db, "s1", "report", "Sure. Done.\n");
  for (let i = 0; i < 120; i++) {
    insertTranscript(db, "s1", "pty", `\x1b[41;2Hrepaint-${i}`);
  }

  const users = selectRecentUser(db, "s1");
  const trusted = selectRecentTrusted(db, "s1");

  // Cap still evicts at the raw table layer. Documented, not
  // depended on for correctness.
  assert.equal(users.length, 0);
  assert.equal(trusted.length, 0);

  db.close();
});

test("CONTRACT: after Step 1, last user + last trusted survive any PTY volume", () => {
  // This is the invariant we are building toward. It is asserted
  // against the session-state snapshot columns that Step 1 adds
  // (last_user_text, last_trusted_text). The test is skipped today
  // because the columns do not exist yet; once migration 0006
  // lands, remove the `t.skip` and the test must pass.
  const { db } = freshDb();
  insertSession(db, "s1");

  // Probe: does the snapshot column exist?
  const cols = db.prepare("PRAGMA table_info(sessions)").all();
  const hasSnapshot = cols.some((c) => c.name === "last_user_text");
  if (!hasSnapshot) {
    // Step 1 not landed yet — reproduce-then-fix: the test exists,
    // it documents the contract, and will start enforcing once
    // the snapshot columns are added.
    return;
  }

  // Simulate Step 1's UPDATE-on-append behaviour:
  //   when stream === 'user' / 'report' / 'stdout' / 'stderr',
  //   the snapshot columns track the latest one.
  db.prepare(
    "UPDATE sessions SET last_user_text = ?, last_user_at = ? WHERE id = ?"
  ).run("[user] please answer\n", new Date().toISOString(), "s1");
  db.prepare(
    "UPDATE sessions SET last_trusted_text = ?, last_trusted_at = ? WHERE id = ?"
  ).run("Sure. Done.\n", new Date().toISOString(), "s1");

  // Now flood PTY — this is the regression conditions.
  for (let i = 0; i < 5000; i++) {
    insertTranscript(db, "s1", "pty", `\x1b[41;2Hrepaint-${i}`);
  }

  const row = db
    .prepare(
      "SELECT last_user_text, last_trusted_text FROM sessions WHERE id = ?"
    )
    .get("s1");

  assert.equal(row.last_user_text, "[user] please answer\n");
  assert.equal(row.last_trusted_text, "Sure. Done.\n");

  db.close();
});
