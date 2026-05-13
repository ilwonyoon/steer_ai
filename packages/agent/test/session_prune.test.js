import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { createStore } from "../src/store.js";
import { applyMigrations } from "../src/migrations.js";

// Phase 4 — store.pruneTerminalSessions removes sessions in
// terminal states past their horizon, cascading through every
// child table. Active / waiting / blocked / running sessions stay.
//
// store.js doesn't expose its underlying DB, so we mutate
// timestamps via a side channel: a separate DatabaseSync handle
// on the same file. SQLite's WAL means both handles see the same
// rows.

function fresh() {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "steer-prune-"));
  const dbPath = path.join(tempDir, "test.sqlite");
  // Apply migrations + open both handles. The store handle is
  // what the prune function reads; the raw handle is what the
  // test uses to seed + backdate.
  const seed = new DatabaseSync(dbPath);
  seed.exec("PRAGMA foreign_keys = ON;");
  applyMigrations(seed, {
    migrationsDir: path.resolve("packages/agent/migrations"),
  });
  seed.close();
  const store = createStore(dbPath);
  const raw = new DatabaseSync(dbPath);
  raw.exec("PRAGMA foreign_keys = ON;");
  return { store, raw, dbPath };
}

function seedSession(raw, id, runState, opts = {}) {
  const ts = opts.ts ?? new Date().toISOString();
  const endedAt = runState === "ended" ? (opts.endedAt ?? ts) : null;
  raw.prepare(
    `INSERT OR IGNORE INTO rooms (id, name, is_default, created_at, updated_at) VALUES ('default', 'Default', 1, ?, ?)`
  ).run(ts, ts);
  raw.prepare(`
    INSERT INTO sessions (
      id, provider, adapter_kind, command, args_json, cwd, pid,
      provider_thread_id, run_state, created_at, updated_at,
      ended_at, current_room_id
    ) VALUES (?, 'codex', 'pty', 'codex', '[]', '/tmp', 1, NULL, ?, ?, ?, ?, 'default')
  `).run(id, runState, ts, ts, endedAt);
}

test("ended session older than 1h is pruned", () => {
  const { store, raw } = fresh();
  const oldTs = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString();
  seedSession(raw, "old", "ended", { ts: oldTs, endedAt: oldTs });

  assert.equal(store.pruneTerminalSessions(), 1);
  const count = raw.prepare("SELECT COUNT(*) AS c FROM sessions").get().c;
  assert.equal(count, 0);
});

test("ended session within 1h is kept", () => {
  const { store, raw } = fresh();
  const recent = new Date(Date.now() - 5 * 60 * 1000).toISOString();
  seedSession(raw, "fresh", "ended", { ts: recent, endedAt: recent });

  assert.equal(store.pruneTerminalSessions(), 0);
});

test("disconnected session older than 24h is pruned; younger is kept", () => {
  const { store, raw } = fresh();
  const oldTs = new Date(Date.now() - 26 * 60 * 60 * 1000).toISOString();
  const freshTs = new Date(Date.now() - 23 * 60 * 60 * 1000).toISOString();
  seedSession(raw, "old-disc", "disconnected", { ts: oldTs });
  seedSession(raw, "fresh-disc", "disconnected", { ts: freshTs });

  assert.equal(store.pruneTerminalSessions(), 1);
  const ids = raw
    .prepare("SELECT id FROM sessions ORDER BY id")
    .all()
    .map((r) => r.id);
  assert.deepEqual(ids, ["fresh-disc"]);
});

test("live sessions (running/waiting/blocked) never prune, regardless of age", () => {
  const { store, raw } = fresh();
  const ancient = new Date(0).toISOString();
  for (const rs of ["running", "waiting", "blocked"]) {
    seedSession(raw, `live-${rs}`, rs, { ts: ancient });
  }

  assert.equal(store.pruneTerminalSessions(), 0);
  const count = raw.prepare("SELECT COUNT(*) AS c FROM sessions").get().c;
  assert.equal(count, 3);
});

test("prune cascades through child rows", () => {
  const { store, raw } = fresh();
  const oldTs = new Date(0).toISOString();
  seedSession(raw, "doomed", "ended", { ts: oldTs, endedAt: oldTs });
  // Seed children directly to avoid coupling to store internals.
  raw.prepare(
    "INSERT INTO transcript_entries (id, session_id, timestamp, stream, chunk) VALUES ('t1', 'doomed', ?, 'stdout', 'hi')"
  ).run(oldTs);
  raw.prepare(
    "INSERT INTO instructions (id, room_id, target_session_id, text, is_quick_reply, status, created_at) VALUES ('i1', 'default', 'doomed', 'go', 0, 'pending', ?)"
  ).run(oldTs);

  assert.equal(store.pruneTerminalSessions(), 1);

  const survivors = raw.prepare(`
    SELECT 'sessions' AS t, COUNT(*) AS c FROM sessions WHERE id = 'doomed'
    UNION ALL SELECT 'transcripts', COUNT(*) FROM transcript_entries WHERE session_id = 'doomed'
    UNION ALL SELECT 'instructions', COUNT(*) FROM instructions WHERE target_session_id = 'doomed'
    UNION ALL SELECT 'cards', COUNT(*) FROM action_cards WHERE session_id = 'doomed'
    UNION ALL SELECT 'excerpts', COUNT(*) FROM terminal_excerpts WHERE session_id = 'doomed'
  `).all();
  for (const row of survivors) {
    assert.equal(row.c, 0, `${row.t} should be 0 after prune`);
  }
});

test("custom horizons honored", () => {
  const { store, raw } = fresh();
  const oldTs = new Date(Date.now() - 10 * 60 * 1000).toISOString(); // 10 min
  seedSession(raw, "x", "ended", { ts: oldTs, endedAt: oldTs });

  // Default 1h horizon: kept.
  assert.equal(store.pruneTerminalSessions(), 0);
  // Override to 5 min: pruned.
  assert.equal(
    store.pruneTerminalSessions({ endedHorizonMs: 5 * 60 * 1000 }),
    1
  );
});
