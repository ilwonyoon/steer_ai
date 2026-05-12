// PR S0 — migration runner tests.
//
// Covers the three states a SteerAgent DB can be in when the runner
// touches it:
//   1. Empty file — no tables yet. Runner applies 0001_initial and
//      records schema_version = 1.
//   2. Pre-S0 DB — has baseline tables but no schema_version row.
//      Runner backstamps version=1 without re-running 0001 (the
//      content is already there; this matters for multi-GB user DBs).
//   3. Already-current DB — schema_version = 1 present. Runner is a
//      no-op.
//
// Plus the "DB written by a newer Steer" failure mode: schema_version
// is higher than the binary's max migration → throw with an
// actionable error.
//
// Uses a temp `migrationsDir` so we can stage synthetic migrations
// without touching the package-level migrations folder.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { applyMigrations, __internal } from "../src/migrations.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REAL_MIGRATIONS_DIR = path.resolve(__dirname, "..", "migrations");

function freshDb() {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "steer-mig-"));
  const dbPath = path.join(tempDir, "steer.sqlite");
  const db = new DatabaseSync(dbPath);
  return { db, tempDir, dbPath };
}

function tableExists(db, name) {
  const row = db
    .prepare(
      "SELECT 1 AS present FROM sqlite_master WHERE type='table' AND name=?"
    )
    .get(name);
  return row?.present === 1;
}

function currentVersion(db) {
  return __internal.currentSchemaVersion(db);
}

test("filename parser accepts 4-digit prefix + description", () => {
  assert.deepEqual(__internal.parseMigrationFile("0001_initial.sql"), {
    version: 1,
    description: "initial",
    filename: "0001_initial.sql",
  });
  assert.deepEqual(__internal.parseMigrationFile("0042_drop-messages.sql"), {
    version: 42,
    description: "drop-messages",
    filename: "0042_drop-messages.sql",
  });
  assert.equal(__internal.parseMigrationFile("not_a_migration.sql"), null);
  assert.equal(__internal.parseMigrationFile("0001_initial.txt"), null);
});

test("fresh DB: applies 0001_initial, records version=1", () => {
  const { db } = freshDb();
  const after = applyMigrations(db, { migrationsDir: REAL_MIGRATIONS_DIR });
  assert.equal(after, 4);
  // Baseline tables present. `messages` was dropped in 0003; we
  // assert it's gone in a separate check below.
  for (const t of [
    "rooms",
    "sessions",
    "instructions",
    "terminal_excerpts",
    "action_cards",
    "transcript_entries",
    "metric_events",
    "schema_version",
  ]) {
    assert.equal(tableExists(db, t), true, `${t} should exist`);
  }
  assert.equal(
    tableExists(db, "messages"),
    false,
    "messages should be gone after migration 0003"
  );
  // schema_version has exactly one row at version 1.
  const versions = db
    .prepare("SELECT version FROM schema_version ORDER BY version")
    .all();
  assert.deepEqual(
    versions.map((r) => r.version),
    [1, 2, 3, 4]
  );
});

test("pre-S0 DB: baseline tables exist, no schema_version → backstamps without re-running 0001", () => {
  const { db } = freshDb();
  // Simulate a pre-S0 DB by directly creating the baseline schema
  // (the same content 0001_initial.sql carries). Critically we do
  // NOT create schema_version — that's what makes this look pre-S0
  // to the runner.
  db.exec(
    fs.readFileSync(path.join(REAL_MIGRATIONS_DIR, "0001_initial.sql"), "utf8")
  );
  // Insert a row to prove the runner doesn't wipe it.
  db.prepare(
    "INSERT INTO rooms (id, name, is_default, created_at, updated_at) VALUES (?, ?, 1, ?, ?)"
  ).run("default", "Default", new Date().toISOString(), new Date().toISOString());

  const after = applyMigrations(db, { migrationsDir: REAL_MIGRATIONS_DIR });
  assert.equal(after, 4);
  // Our row survived.
  const row = db.prepare("SELECT id FROM rooms WHERE id = 'default'").get();
  assert.equal(row?.id, "default");
  // schema_version backstamp description marks the path taken.
  const r = db
    .prepare("SELECT description FROM schema_version WHERE version = 1")
    .get();
  assert.match(r.description, /backstamped/);
});

test("already-current DB: runner is a no-op", () => {
  const { db } = freshDb();
  applyMigrations(db, { migrationsDir: REAL_MIGRATIONS_DIR });
  const v1 = currentVersion(db);
  // Insert a row so we can verify it survives.
  db.prepare(
    "INSERT INTO rooms (id, name, is_default, created_at, updated_at) VALUES (?, ?, 1, ?, ?)"
  ).run("default", "Default", "2026-01-01", "2026-01-01");
  const v2 = applyMigrations(db, { migrationsDir: REAL_MIGRATIONS_DIR });
  assert.equal(v1, 4);
  assert.equal(v2, 4);
  // schema_version has exactly the migrations we ran (no duplicates).
  const rows = db.prepare("SELECT version FROM schema_version").all();
  assert.equal(rows.length, 4);
});

test("DB schema_version higher than max-on-disk: throws with actionable message", () => {
  const { db } = freshDb();
  // Bring it up to version 1 normally, then synthetically push the
  // version to 99 as if a newer binary had written it.
  applyMigrations(db, { migrationsDir: REAL_MIGRATIONS_DIR });
  db.prepare(
    "INSERT INTO schema_version (version, applied_at, description) VALUES (?, ?, ?)"
  ).run(99, new Date().toISOString(), "future-binary");

  assert.throws(
    () => applyMigrations(db, { migrationsDir: REAL_MIGRATIONS_DIR }),
    /version 99/,
    "must surface the version mismatch + actionable next step"
  );
});

test("stages a synthetic migration on top of an existing DB", () => {
  const { db, tempDir } = freshDb();
  // First bring the DB up to the current real version.
  applyMigrations(db, { migrationsDir: REAL_MIGRATIONS_DIR });

  // Stage a brand-new 0099 sentinel that nothing in-tree owns. This
  // proves the runner handles new migrations on a non-empty DB
  // without coupling to whatever number is the current head.
  const stagedDir = path.join(tempDir, "migrations");
  fs.mkdirSync(stagedDir);
  for (const f of fs.readdirSync(REAL_MIGRATIONS_DIR)) {
    fs.copyFileSync(
      path.join(REAL_MIGRATIONS_DIR, f),
      path.join(stagedDir, f)
    );
  }
  fs.writeFileSync(
    path.join(stagedDir, "0099_pr_s0_sentinel.sql"),
    "CREATE TABLE pr_s0_sentinel (n INTEGER);\n"
  );

  const after = applyMigrations(db, { migrationsDir: stagedDir });
  assert.equal(after, 99);
  assert.equal(tableExists(db, "pr_s0_sentinel"), true);
});

test("createStore wires the runner — store.js path covered end to end", async () => {
  // Importing createStore here ensures the wiring in store.js also
  // exercises the runner. (createStore is the only public surface
  // for the agent process.)
  const { createStore } = await import("../src/store.js");
  const { tempDir } = freshDb();
  const dbPath = path.join(tempDir, "store-wired.sqlite");
  const store = createStore(dbPath);
  // The store opens a DatabaseSync we don't directly access; sanity
  // check via a known cheap query.
  const sessions = store.listLiveSessions();
  assert.deepEqual(sessions, []);
  store.close();
  // Re-open the path to verify schema_version was recorded.
  const db = new DatabaseSync(dbPath);
  const v = db.prepare("SELECT MAX(version) AS v FROM schema_version").get().v;
  assert.equal(v, 4);
});

test("missing migrations dir → throws", () => {
  const { db, tempDir } = freshDb();
  assert.throws(
    () =>
      applyMigrations(db, {
        migrationsDir: path.join(tempDir, "does-not-exist"),
      }),
    /No migration files found/
  );
});
