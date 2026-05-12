// Reproduces today's wrapper-disconnect chain in a hermetic test
// so we never debug it from raw logs again.
//
// The bug (observed 2026-05-12 in dogfood):
//   - Multiple `steer codex` wrappers start within the same second.
//   - Each checks `fs.existsSync(~/.steer/steer.sock)`; none exist yet.
//   - Each spawns its own SteerAgent process.
//   - Both agents reach `createStore()` BEFORE either has bound the
//     socket. The agent.js `prepareSocketPath` singleton check
//     guards on the socket file, but `createStore` runs before that
//     completes its full open path on a multi-GB DB.
//   - Both agents race on the SQLite open. The loser dies with
//     `SQLITE_ERROR: database is locked`. The wrapper that spawned
//     the losing agent has its socket close out from under it; the
//     session flips to `disconnected`; the next card publish never
//     fires; iPhone reply receives no answer.
//
// What this test does:
//   1. Stages a STEER_HOME tmpdir, seeds the DB with a synthetic
//      working size (enough to slow WAL replay measurably). The
//      seed is real rows so the agent open path runs the same code
//      as production.
//   2. Starts N agent processes simultaneously (N=4 matches today's
//      dogfood snapshot).
//   3. Asserts: exactly one agent stays alive after the dust
//      settles AND the socket is reachable AND a fresh wrapper
//      connection succeeds.
//
// Before PR S1 (flock + busy_timeout reorder) this test fails:
// the losing agents crash with "database is locked" and depending
// on timing 1+ agent might survive. After PR S1 it passes: the
// flock makes exactly one agent reach createStore at a time;
// losers exit cleanly with an "agent already starting" message.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";

// Integration gate, same convention as the other wrapper tests.
const SKIP = process.env.STEER_INTEGRATION !== "1";
const integrationTest = (name, fn) =>
  test(name, { skip: SKIP ? "set STEER_INTEGRATION=1 to run" : false }, fn);

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const agentEntry = path.resolve(
  __dirname,
  "..",
  "..",
  "agent",
  "src",
  "agent.js"
);

function makeSteerHome() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "steer-concur-"));
  fs.mkdirSync(path.join(dir, "sessions"), { recursive: true });
  return dir;
}

function seedNonTrivialDB(dbPath) {
  // We don't need a multi-GB file to surface the race — even a
  // small DB with WAL pages exhibits the lock window. We DO want
  // baseline schema + rooms row present so `prepareStatements` in
  // createStore can finish its open path.
  const migrationsDir = path.resolve(__dirname, "..", "..", "agent", "migrations");
  const initial = fs.readFileSync(
    path.join(migrationsDir, "0001_initial.sql"),
    "utf8"
  );
  const db = new DatabaseSync(dbPath);
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA foreign_keys = ON;
  `);
  db.exec(initial);
  // Insert a few rows so WAL has something to replay on next open.
  const now = new Date().toISOString();
  db.prepare(
    "INSERT OR IGNORE INTO rooms (id, name, is_default, created_at, updated_at) VALUES (?, ?, 1, ?, ?)"
  ).run("default", "Default", now, now);
  for (let i = 0; i < 50; i++) {
    db.prepare(
      "INSERT INTO sessions (id, provider, run_state, args_json, created_at, updated_at, current_room_id) VALUES (?, ?, ?, '[]', ?, ?, 'default')"
    ).run(`seed-${i}`, "claude", "ended", now, now);
  }
  db.close();
}

function spawnAgent(steerHome, logPath) {
  const logFd = fs.openSync(logPath, "a");
  const child = spawn(process.execPath, [agentEntry], {
    env: {
      ...process.env,
      STEER_HOME: steerHome,
      STEER_SOCKET: path.join(steerHome, "steer.sock"),
      STEER_DB: path.join(steerHome, "steer.sqlite"),
    },
    stdio: ["ignore", logFd, logFd],
  });
  return child;
}

function waitForSocket(socketPath, deadlineMs) {
  return new Promise((resolve) => {
    const deadline = Date.now() + deadlineMs;
    const tick = () => {
      if (fs.existsSync(socketPath)) return resolve(true);
      if (Date.now() > deadline) return resolve(false);
      setTimeout(tick, 25);
    };
    tick();
  });
}

function socketReachable(socketPath, timeoutMs = 500) {
  return new Promise((resolve) => {
    const socket = net.createConnection(socketPath);
    let settled = false;
    const finish = (ok) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(ok);
    };
    socket.once("connect", () => finish(true));
    socket.once("error", () => finish(false));
    setTimeout(() => finish(false), timeoutMs);
  });
}

async function waitChildExitOrAlive(child, ms) {
  return new Promise((resolve) => {
    let resolved = false;
    const timer = setTimeout(() => {
      if (resolved) return;
      resolved = true;
      resolve({ alive: true, code: null });
    }, ms);
    child.once("exit", (code) => {
      if (resolved) return;
      resolved = true;
      clearTimeout(timer);
      resolve({ alive: false, code });
    });
  });
}

async function killAndWait(child, ms = 1000) {
  if (!child || child.exitCode !== null) return;
  try {
    child.kill("SIGTERM");
  } catch {}
  await new Promise((r) => setTimeout(r, ms));
  try {
    child.kill("SIGKILL");
  } catch {}
}

integrationTest(
  "four agents started concurrently: exactly one survives, socket is reachable",
  async () => {
    const steerHome = makeSteerHome();
    const dbPath = path.join(steerHome, "steer.sqlite");
    const socketPath = path.join(steerHome, "steer.sock");
    const logPath = path.join(steerHome, "agent.log");
    seedNonTrivialDB(dbPath);

    // Spawn four agents at once. Order of arrival on the SQLite
    // open is racy. Before S1 this consistently produces "database
    // is locked" stack traces in the log for some subset of them.
    const children = [
      spawnAgent(steerHome, logPath),
      spawnAgent(steerHome, logPath),
      spawnAgent(steerHome, logPath),
      spawnAgent(steerHome, logPath),
    ];

    // Wait 9s — longer than RETRY_BUDGET_MS (6s) — so every
    // loser has exited via AgentLockHeld. Production wrappers
    // see the socket appear in ~1s and don't need to wait that
    // long; the test waits patiently to assert the steady state.
    await new Promise((r) => setTimeout(r, 9000));

    try {
      const liveCount = children.filter((c) => c.exitCode === null).length;
      const sockExists = fs.existsSync(socketPath);
      const sockOk = sockExists ? await socketReachable(socketPath) : false;

      // The contract S1 enforces:
      //   Exactly one agent process survives + socket is bound + reachable.
      // Anything else is the race we want to fail-fast on.
      assert.equal(
        liveCount,
        1,
        `expected exactly 1 surviving agent, got ${liveCount} (see ${logPath} for crash stacks)`
      );
      assert.equal(sockExists, true, "agent must create the socket file");
      assert.equal(sockOk, true, "agent must accept connections on the socket");

      // The losers must have exited with an actionable message —
      // not a crash stack. Check the log doesn't contain
      // "database is locked".
      const logBody = fs.readFileSync(logPath, "utf8");
      assert.ok(
        !logBody.includes("database is locked"),
        "agent log must not contain SQLITE 'database is locked' stack traces"
      );
    } finally {
      for (const c of children) await killAndWait(c);
      try {
        fs.rmSync(steerHome, { recursive: true, force: true });
      } catch {}
    }
  }
);

integrationTest(
  "second agent starts cleanly after the first one is already running",
  async () => {
    const steerHome = makeSteerHome();
    const dbPath = path.join(steerHome, "steer.sqlite");
    const socketPath = path.join(steerHome, "steer.sock");
    const logPath = path.join(steerHome, "agent.log");
    seedNonTrivialDB(dbPath);

    const first = spawnAgent(steerHome, logPath);
    const up = await waitForSocket(socketPath, 5000);
    assert.equal(up, true, "first agent should bind the socket");

    // Now start a second one. It must exit cleanly (not crash) and
    // leave the first agent's socket intact. The retry budget for
    // lockfile contention is 6s; allow 8s for the exit.
    const second = spawnAgent(steerHome, logPath);
    const result = await waitChildExitOrAlive(second, 8000);

    try {
      assert.equal(
        result.alive,
        false,
        "second agent should exit when one is already running, not stay alive"
      );
      assert.notEqual(
        result.code,
        null,
        "second agent must exit with an exit code, not crash silently"
      );
      // Original socket still reachable.
      const sockOk = await socketReachable(socketPath);
      assert.equal(sockOk, true, "first agent's socket must survive");

      const logBody = fs.readFileSync(logPath, "utf8");
      assert.ok(
        !logBody.includes("database is locked"),
        "second-agent startup must not crash with SQLITE lock errors"
      );
    } finally {
      await killAndWait(first);
      await killAndWait(second);
      try {
        fs.rmSync(steerHome, { recursive: true, force: true });
      } catch {}
    }
  }
);
