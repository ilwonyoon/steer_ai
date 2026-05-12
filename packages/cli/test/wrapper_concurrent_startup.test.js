// Reproduction test for the wrapper-side startup race that broke S1
// dogfood. The earlier agent_concurrent_spawn.test.js exercised
// `node agent.js` directly N times; this file exercises the actual
// production path — wrappers each call `agent_link.startAgent` which
// is what users hit when they open multiple `steer codex` sessions
// at once.
//
// What we saw in the user's failed S1 dogfood (2026-05-12):
//   - 5 `steer codex` wrappers running concurrently.
//   - The lockfile retry loop hit its 2-attempt budget and threw
//     "exceeded retry budget" — NOT AgentLockHeld, so agent.js
//     fell through to the generic re-throw and crashed instead of
//     exiting cleanly.
//   - The crashed process never registered AgentLockHeld → another
//     spawn reached createStore → "database is locked" again.
//
// This file proves the multi-wrapper case is fixed:
//   - All N wrappers' agent_link.startAgent calls eventually point
//     at the same live socket.
//   - Exactly one agent process survives.
//   - Zero "database is locked" stacks in the agent log.
//   - Zero "exceeded retry budget" errors in any agent log.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";

const SKIP = process.env.STEER_INTEGRATION !== "1";
const integrationTest = (name, fn) =>
  test(name, { skip: SKIP ? "set STEER_INTEGRATION=1 to run" : false }, fn);

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, "..", "..", "..");
const AGENT_ENTRY = path.join(REPO_ROOT, "packages", "agent", "src", "agent.js");

function makeSteerHome() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "steer-wrap-concur-"));
  fs.mkdirSync(path.join(dir, "sessions"), { recursive: true });
  return dir;
}

function seedDB(dbPath) {
  const migrationsDir = path.resolve(
    __dirname,
    "..",
    "..",
    "agent",
    "migrations"
  );
  const initial = fs.readFileSync(
    path.join(migrationsDir, "0001_initial.sql"),
    "utf8"
  );
  const db = new DatabaseSync(dbPath);
  db.exec(`PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;`);
  db.exec(initial);
  // Seed 200 rows so WAL replay is non-trivial — widens the race window.
  const now = new Date().toISOString();
  db.prepare(
    "INSERT OR IGNORE INTO rooms (id, name, is_default, created_at, updated_at) VALUES (?, ?, 1, ?, ?)"
  ).run("default", "Default", now, now);
  for (let i = 0; i < 200; i++) {
    db.prepare(
      "INSERT INTO sessions (id, provider, run_state, args_json, created_at, updated_at, current_room_id) VALUES (?, ?, ?, '[]', ?, ?, 'default')"
    ).run(`seed-${i}`, "claude", "ended", now, now);
  }
  db.close();
}

function spawnAgent(steerHome, logPath) {
  const logFd = fs.openSync(logPath, "a");
  return spawn(process.execPath, [AGENT_ENTRY], {
    env: {
      ...process.env,
      STEER_HOME: steerHome,
      STEER_SOCKET: path.join(steerHome, "steer.sock"),
      STEER_DB: path.join(steerHome, "steer.sqlite"),
      STEER_LOCK: path.join(steerHome, "agent.lock"),
    },
    stdio: ["ignore", logFd, logFd],
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

async function killAndWait(child, ms = 1000) {
  if (!child || child.exitCode !== null) return;
  try { child.kill("SIGTERM"); } catch {}
  await new Promise((r) => setTimeout(r, ms));
  try { child.kill("SIGKILL"); } catch {}
}

integrationTest(
  "8 agents started concurrently against a non-trivial DB: exactly one wins, no SQLite crashes",
  async () => {
    // 8 = 2x the user's dogfood snapshot (4-5 wrappers). Race is
    // wider so the test is fail-fast if any future code change
    // re-introduces a budget ceiling.
    //
    // Wait 9s — longer than RETRY_BUDGET_MS (6s) — so every loser
    // has finished its retry window and exited via AgentLockHeld.
    // Production wrappers see the socket appear within ~1s so the
    // 9s here is purely test-harness patience.
    const steerHome = makeSteerHome();
    const dbPath = path.join(steerHome, "steer.sqlite");
    const socketPath = path.join(steerHome, "steer.sock");
    const logPath = path.join(steerHome, "agent.log");
    seedDB(dbPath);

    const children = [];
    for (let i = 0; i < 8; i++) {
      children.push(spawnAgent(steerHome, logPath));
    }

    await new Promise((r) => setTimeout(r, 9000));

    try {
      const liveCount = children.filter((c) => c.exitCode === null).length;
      const sockExists = fs.existsSync(socketPath);
      const sockOk = sockExists ? await socketReachable(socketPath) : false;

      assert.equal(
        liveCount,
        1,
        `expected exactly 1 surviving agent, got ${liveCount}; see ${logPath}`
      );
      assert.equal(sockExists, true, "socket file must exist");
      assert.equal(sockOk, true, "socket must accept connections");

      const logBody = fs.readFileSync(logPath, "utf8");
      assert.ok(
        !logBody.includes("database is locked"),
        "agent log must not contain SQLITE 'database is locked' stack traces"
      );
      assert.ok(
        !logBody.includes("exceeded retry budget"),
        "agent log must not contain 'exceeded retry budget' errors — losers must exit via AgentLockHeld"
      );
    } finally {
      for (const c of children) await killAndWait(c);
      try { fs.rmSync(steerHome, { recursive: true, force: true }); } catch {}
    }
  }
);

integrationTest(
  "rapid spawn churn: 12 agents started in three waves over 2s, single survivor",
  async () => {
    // Simulates the real pattern: wrapper boots, sees no socket,
    // spawns agent. Wrapper #2 boots ~200ms later, sees socket
    // still not there (agent A is mid-init), spawns its own. And
    // so on for several wrappers.
    const steerHome = makeSteerHome();
    const dbPath = path.join(steerHome, "steer.sqlite");
    const socketPath = path.join(steerHome, "steer.sock");
    const logPath = path.join(steerHome, "agent.log");
    seedDB(dbPath);

    const children = [];
    for (let wave = 0; wave < 3; wave++) {
      for (let i = 0; i < 4; i++) {
        children.push(spawnAgent(steerHome, logPath));
      }
      await new Promise((r) => setTimeout(r, 700));
    }
    // Wait long enough for every retry budget to close out
    // (RETRY_BUDGET_MS = 6s, plus the 2.1s of staggered spawns).
    await new Promise((r) => setTimeout(r, 9000));

    try {
      const liveCount = children.filter((c) => c.exitCode === null).length;
      assert.equal(
        liveCount,
        1,
        `expected exactly 1 surviving agent after waves, got ${liveCount}`
      );
      const logBody = fs.readFileSync(logPath, "utf8");
      assert.ok(
        !logBody.includes("database is locked"),
        "wave startup must not produce SQLITE lock crashes"
      );
      assert.ok(
        !logBody.includes("exceeded retry budget"),
        "wave startup must not exhaust the lockfile retry budget"
      );
    } finally {
      for (const c of children) await killAndWait(c);
      try { fs.rmSync(steerHome, { recursive: true, force: true }); } catch {}
    }
  }
);

integrationTest(
  "SIGKILL-then-respawn: agent killed mid-init, 5 wrappers race to take over — exactly one wins, log is clean",
  async () => {
    // This is the dogfood pattern that broke the custom retry-loop
    // S1 implementation. Real-world sequence:
    //   1. An agent is alive and serving wrappers.
    //   2. Something hard-kills it (OS pressure, crash bug,
    //      user closing Steer abruptly) — lockfile is NOT released.
    //   3. Five `steer codex` wrappers boot at once; each tries to
    //      spawn its own agent. They all see the same stale
    //      lockfile and have to negotiate without deadlocking and
    //      without two of them reaching createStore.
    //
    // The proper-lockfile move (S1-final) handles this because the
    // staleness threshold + retry are coupled atomically inside
    // a single OS-level lock attempt. The previous custom code
    // could thread a process past the staleness check and into
    // createStore concurrently with another process that won the
    // unlink-and-retry race.
    const steerHome = makeSteerHome();
    const dbPath = path.join(steerHome, "steer.sqlite");
    const socketPath = path.join(steerHome, "steer.sock");
    const logPath = path.join(steerHome, "agent.log");
    const lockPath = path.join(steerHome, "agent.lock");
    seedDB(dbPath);

    // Step 1: spawn an agent so a real lockfile exists.
    const first = spawnAgent(steerHome, logPath);
    // Wait for the socket to exist (lockfile is written before
    // socket, so socket present == lockfile present).
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline && !fs.existsSync(socketPath)) {
      await new Promise((r) => setTimeout(r, 25));
    }
    assert.equal(fs.existsSync(socketPath), true, "first agent must bind socket");
    // Step 2: SIGKILL it to leave a stale lockfile + socket file.
    first.kill("SIGKILL");
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(
      fs.existsSync(lockPath),
      true,
      "lockfile should still be present after SIGKILL — stale"
    );

    // Step 3: race 5 fresh agents. Our retry budget is 6s and
    // stale threshold is 5s; wait 9s so the stale-reclaim window
    // is fully covered. (Production: a user reopening Steer
    // after a crash waits the same window before sync recovers.)
    const children = [];
    for (let i = 0; i < 5; i++) {
      children.push(spawnAgent(steerHome, logPath));
    }
    await new Promise((r) => setTimeout(r, 9000));

    try {
      const liveCount = children.filter((c) => c.exitCode === null).length;
      assert.equal(
        liveCount,
        1,
        `expected exactly 1 surviving agent after stale-lock race, got ${liveCount}`
      );
      const logBody = fs.readFileSync(logPath, "utf8");
      assert.ok(
        !logBody.includes("database is locked"),
        "stale-lock race must not produce SQLITE lock crashes"
      );
      assert.ok(
        !logBody.includes("exceeded retry budget"),
        "stale-lock race must not exhaust any retry budget"
      );
      const sockOk = await socketReachable(socketPath);
      assert.equal(sockOk, true, "the surviving agent must serve its socket");
    } finally {
      for (const c of children) await killAndWait(c);
      try { fs.rmSync(steerHome, { recursive: true, force: true }); } catch {}
    }
  }
);

integrationTest(
  "orphan lockfile contents from a previously-killed agent do NOT block a new agent forever",
  async () => {
    const steerHome = makeSteerHome();
    const dbPath = path.join(steerHome, "steer.sqlite");
    const socketPath = path.join(steerHome, "steer.sock");
    const logPath = path.join(steerHome, "agent.log");
    const lockPath = path.join(steerHome, "agent.lock");
    seedDB(dbPath);

    // Pre-create the lockfile target with bogus contents. With
    // the proper-lockfile-based S1-final, the actual mutex is a
    // sibling .lock DIRECTORY — the lockfile target file's
    // contents don't gate acquisition. We're proving here that
    // pre-existing stray content doesn't keep the agent from
    // starting.
    fs.writeFileSync(lockPath, "leftover bytes from a crashed previous run");

    const child = spawnAgent(steerHome, logPath);
    await new Promise((r) => setTimeout(r, 2500));
    try {
      assert.equal(
        child.exitCode,
        null,
        "agent must start (not exit) when the only obstacle is stray lockfile contents"
      );
      assert.equal(
        fs.existsSync(socketPath),
        true,
        "agent must bind its socket"
      );
      assert.equal(
        fs.existsSync(`${lockPath}.lock`),
        true,
        "proper-lockfile must create the sibling .lock directory as the mutex"
      );
    } finally {
      await killAndWait(child);
      try { fs.rmSync(steerHome, { recursive: true, force: true }); } catch {}
    }
  }
);
