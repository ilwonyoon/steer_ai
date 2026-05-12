// Migration runner for SteerAgent's local SQLite (PR S0).
//
// Mirrors the numbered-file pattern the relay package already uses
// (packages/relay/migrations/000N_*.sql). Each migration is a plain
// SQL file with a name `<4-digit-number>_<description>.sql`. The
// runner applies pending migrations in numeric order, recording each
// applied version in a `schema_version` table.
//
// Why a runner instead of `db.exec(schemaSql)` on every startup:
// CREATE TABLE IF NOT EXISTS is silent on existing tables, so any
// new column or ALTER inside the schema string never reaches existing
// user databases. With the runner, future ALTERs land in numbered
// files and are applied exactly once per DB.
//
// Existing user DBs (rows present, no schema_version table yet) get
// backstamped to version=1 without re-running 0001_initial — the
// CREATEs there would be no-ops anyway, but skipping them avoids
// touching multi-GB files we don't need to touch.
//
// Public API:
//
//   applyMigrations(db, { migrationsDir })
//
// Returns the version the DB is at after the call. Throws on
// integrity problems (a version is present in the DB that isn't
// present on disk — i.e. the user has a newer DB than this binary).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DEFAULT_MIGRATIONS_DIR = path.resolve(__dirname, "..", "migrations");

/**
 * Detects whether the database is "non-empty" — has any of the
 * baseline tables that 0001_initial creates. Used to decide whether
 * to backstamp version=1 or actually run 0001_initial.
 *
 * Empty DB → run 0001 (creates schema).
 * Pre-S0 DB (has rooms/sessions/etc but no schema_version) → backstamp.
 */
function isPreS0Schema(db) {
  // sqlite_master lookup is cheap even on a 2GB DB; doesn't touch
  // any row data.
  const row = db
    .prepare(
      "SELECT 1 AS present FROM sqlite_master WHERE type='table' AND name='sessions' LIMIT 1"
    )
    .get();
  return row != null;
}

function ensureSchemaVersionTable(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS schema_version (
      version INTEGER PRIMARY KEY,
      applied_at TEXT NOT NULL,
      description TEXT
    );
  `);
}

function currentSchemaVersion(db) {
  const row = db
    .prepare("SELECT MAX(version) AS v FROM schema_version")
    .get();
  return row?.v ?? 0;
}

/** Parse a migration filename of the form `0001_initial.sql`. */
function parseMigrationFile(name) {
  const m = /^(\d{4})_([\w-]+)\.sql$/.exec(name);
  if (!m) return null;
  return {
    version: Number.parseInt(m[1], 10),
    description: m[2],
    filename: name,
  };
}

function listMigrationsOnDisk(migrationsDir) {
  if (!fs.existsSync(migrationsDir)) return [];
  return fs
    .readdirSync(migrationsDir)
    .map(parseMigrationFile)
    .filter(Boolean)
    .sort((a, b) => a.version - b.version);
}

/**
 * Apply all pending migrations.
 *
 * Order of operations:
 *   1. Ensure `schema_version` table exists.
 *   2. Detect existing-pre-S0 DBs and backstamp version=1 so we
 *      don't re-run 0001 on a multi-GB file.
 *   3. Read current version, list disk migrations, apply any with
 *      version > current.
 *   4. If the DB version is HIGHER than any on-disk migration, throw
 *      — the user's DB was written by a newer binary; rolling back
 *      schema would corrupt data.
 */
export function applyMigrations(db, opts = {}) {
  const migrationsDir = opts.migrationsDir ?? DEFAULT_MIGRATIONS_DIR;

  ensureSchemaVersionTable(db);

  const onDisk = listMigrationsOnDisk(migrationsDir);
  if (onDisk.length === 0) {
    throw new Error(
      `No migration files found under ${migrationsDir}. ` +
        `At minimum 0001_initial.sql must exist.`
    );
  }
  const maxOnDisk = onDisk[onDisk.length - 1].version;

  const before = currentSchemaVersion(db);
  if (before > maxOnDisk) {
    throw new Error(
      `SteerAgent DB schema is at version ${before} but this binary only ` +
        `ships migrations through ${maxOnDisk}. Update Steer to a newer ` +
        `build, or remove ~/.steer/steer.sqlite to start fresh ` +
        `(loses local history).`
    );
  }

  // Backstamp pre-S0 DBs at version 1 if they have baseline tables
  // but no schema_version entries yet. We do this BEFORE the apply
  // loop so the loop sees `before = 1` and skips 0001_initial.
  if (before === 0 && isPreS0Schema(db)) {
    db.prepare(
      "INSERT INTO schema_version (version, applied_at, description) VALUES (?, ?, ?)"
    ).run(1, new Date().toISOString(), "initial (backstamped from pre-S0 DB)");
  }

  const after = currentSchemaVersion(db);
  for (const migration of onDisk) {
    if (migration.version <= after) continue;
    const sqlPath = path.join(migrationsDir, migration.filename);
    const sql = fs.readFileSync(sqlPath, "utf8");
    // db.exec runs the whole file in one shot; migrations are
    // structured to be safe under that (statements separated by ;).
    db.exec(sql);
    db.prepare(
      "INSERT INTO schema_version (version, applied_at, description) VALUES (?, ?, ?)"
    ).run(migration.version, new Date().toISOString(), migration.description);
  }

  return currentSchemaVersion(db);
}

// Re-export the helpers we test directly. Internal use only;
// applyMigrations is the public entry point.
export const __internal = {
  isPreS0Schema,
  currentSchemaVersion,
  parseMigrationFile,
  listMigrationsOnDisk,
};
