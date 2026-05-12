import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { applyMigrations } from "../src/migrations.js";

// Phase 1 — terminal_excerpts is card-bound. When a card resolves
// (state='done') or is deleted, its excerpt MUST disappear in the
// same write. No application-level cleanup, no orphan excerpts.

function freshDb() {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "steer-excerpt-"));
  const db = new DatabaseSync(path.join(tempDir, "test.sqlite"));
  db.exec("PRAGMA foreign_keys = ON;");
  applyMigrations(db, {
    migrationsDir: path.resolve("packages/agent/migrations"),
  });
  // Seed the minimum referenced rows.
  db.prepare(
    "INSERT INTO rooms (id, name, is_default, created_at, updated_at) VALUES ('r', 'Default', 1, '2026-01-01', '2026-01-01')"
  ).run();
  db.prepare(
    "INSERT INTO sessions (id, provider, adapter_kind, command, args_json, cwd, pid, provider_thread_id, run_state, created_at, updated_at, current_room_id) VALUES ('s', 'codex', 'pty', 'codex', '[]', '/tmp', 1, NULL, 'running', '2026-01-01', '2026-01-01', 'r')"
  ).run();
  return { db, tempDir };
}

function insertCardWithExcerpt(db, cardId, excerptId) {
  db.prepare(
    "INSERT INTO terminal_excerpts (id, session_id, start_offset, end_offset, raw_text, display_lines_json, highlighted_line_indexes_json, created_at) VALUES (?, 's', NULL, NULL, 'raw', '[]', '[]', '2026-01-01')"
  ).run(excerptId);
  db.prepare(
    "INSERT INTO action_cards (id, room_id, session_id, terminal_excerpt_id, category, priority, title, summary, action_prompt, options_json, state, created_at, updated_at, snoozed_until) VALUES (?, 'r', 's', ?, 'question', 'normal', 't', 's', NULL, NULL, 'active', '2026-01-01', '2026-01-01', NULL)"
  ).run(cardId, excerptId);
}

function excerptCount(db) {
  return db.prepare("SELECT COUNT(*) AS c FROM terminal_excerpts").get().c;
}

test("card → state='done' drops its excerpt", () => {
  const { db } = freshDb();
  insertCardWithExcerpt(db, "card-1", "ex-1");
  assert.equal(excerptCount(db), 1);
  // The classifier path doesn't DELETE cards directly; it marks
  // them done. Trigger must follow.
  db.prepare(
    "UPDATE action_cards SET state = 'done', updated_at = '2026-01-02' WHERE id = ?"
  ).run("card-1");
  assert.equal(excerptCount(db), 0, "trigger must drop the excerpt");
  db.close();
});

test("card → DELETE drops its excerpt", () => {
  const { db } = freshDb();
  insertCardWithExcerpt(db, "card-2", "ex-2");
  db.prepare("DELETE FROM action_cards WHERE id = ?").run("card-2");
  assert.equal(excerptCount(db), 0);
  db.close();
});

test("card UPDATE of terminal_excerpt_id drops the old excerpt", () => {
  const { db } = freshDb();
  insertCardWithExcerpt(db, "card-3", "ex-old");
  // Insert a fresh excerpt and swap the card to it (refreshActionCard
  // does this on a new turn — `excerpt-${sessionId}` doesn't change
  // in prod, but the migration should be defensive).
  db.prepare(
    "INSERT INTO terminal_excerpts (id, session_id, start_offset, end_offset, raw_text, display_lines_json, highlighted_line_indexes_json, created_at) VALUES ('ex-new', 's', NULL, NULL, 'r2', '[]', '[]', '2026-01-02')"
  ).run();
  db.prepare(
    "UPDATE action_cards SET terminal_excerpt_id = 'ex-new', updated_at = '2026-01-02' WHERE id = ?"
  ).run("card-3");
  // Only the new excerpt remains.
  const ids = db
    .prepare("SELECT id FROM terminal_excerpts ORDER BY id")
    .all()
    .map((r) => r.id);
  assert.deepEqual(ids, ["ex-new"]);
  db.close();
});

test("card state UPDATE that keeps state='active' does NOT drop excerpt", () => {
  const { db } = freshDb();
  insertCardWithExcerpt(db, "card-4", "ex-4");
  // Classifier re-runs and bumps updated_at, but the card stays
  // active (re-classify of the same situation).
  db.prepare(
    "UPDATE action_cards SET updated_at = '2026-01-02' WHERE id = ?"
  ).run("card-4");
  assert.equal(excerptCount(db), 1);
  db.close();
});

test("card with terminal_excerpt_id = NULL is safe (no orphan delete)", () => {
  const { db } = freshDb();
  db.prepare(
    "INSERT INTO action_cards (id, room_id, session_id, terminal_excerpt_id, category, priority, title, summary, action_prompt, options_json, state, created_at, updated_at, snoozed_until) VALUES ('card-5', 'r', 's', NULL, 'question', 'normal', 't', 's', NULL, NULL, 'active', '2026-01-01', '2026-01-01', NULL)"
  ).run();
  db.prepare(
    "UPDATE action_cards SET state = 'done' WHERE id = ?"
  ).run("card-5");
  assert.equal(excerptCount(db), 0); // still no excerpts; no spurious delete attempted
  db.close();
});
