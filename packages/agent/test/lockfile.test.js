// PR S1-final — lockfile wrapper tests.
//
// The lockfile module wraps `proper-lockfile`. We don't re-test
// proper-lockfile's own correctness (its own suite does that);
// we cover *our* surface:
//   - acquire returns a release handle
//   - release removes the lockfile sibling so a follow-up
//     acquire in the same process succeeds
//   - AgentLockHeld is raised when another process holds the
//     lock (we spawn one in a child process to prove this)

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { acquireAgentLock, AgentLockHeld } from "../src/lockfile.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function freshLockPath() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "steer-lock-"));
  return path.join(dir, "agent.lock");
}

test("first acquire succeeds and creates the lockfile sibling", () => {
  const p = freshLockPath();
  const handle = acquireAgentLock(p);
  try {
    // proper-lockfile creates a sibling `<path>.lock` directory
    // as the actual mutex. Both should exist.
    assert.equal(fs.existsSync(p), true, "target lockfile must exist");
    assert.equal(
      fs.existsSync(`${p}.lock`),
      true,
      "proper-lockfile sibling must exist"
    );
  } finally {
    handle.release();
  }
});

test("release removes the sibling lock directory", () => {
  const p = freshLockPath();
  const handle = acquireAgentLock(p);
  handle.release();
  assert.equal(
    fs.existsSync(`${p}.lock`),
    false,
    "sibling must be removed on release"
  );
});

test("acquire-release-acquire in the same process is allowed", () => {
  const p = freshLockPath();
  const a = acquireAgentLock(p);
  a.release();
  const b = acquireAgentLock(p);
  try {
    assert.equal(fs.existsSync(`${p}.lock`), true);
  } finally {
    b.release();
  }
});

test("AgentLockHeld is thrown when a live child process holds the lock", async () => {
  const p = freshLockPath();
  // Spawn a child that takes the lock then sleeps. We use a small
  // inline node script so we don't have to set up a fixture file.
  const holderScript = `
    import { acquireAgentLock } from "${path
      .resolve(__dirname, "..", "src", "lockfile.js")
      .replace(/\\\\/g, "\\\\\\\\")}";
    const handle = acquireAgentLock(${JSON.stringify(p)});
    process.stdout.write("LOCKED\\n");
    // keep the lock for 10 seconds; the test should finish well
    // before this expires.
    setTimeout(() => handle.release(), 10000);
  `;
  const child = spawn(process.execPath, ["--input-type=module", "-e", holderScript], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  try {
    // Wait for the child to confirm it's taken the lock.
    await new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("child did not log LOCKED within 3s")),
        3000
      );
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk) => {
        if (chunk.includes("LOCKED")) {
          clearTimeout(timer);
          resolve();
        }
      });
      child.once("exit", () =>
        reject(new Error("child exited before logging LOCKED"))
      );
    });

    let caught;
    try {
      acquireAgentLock(p);
    } catch (e) {
      caught = e;
    }
    assert.ok(
      caught instanceof AgentLockHeld,
      `expected AgentLockHeld, got ${caught?.constructor?.name}: ${caught?.message}`
    );
    assert.equal(caught.code, "AGENT_LOCK_HELD");
    assert.equal(caught.lockPath, p);
    assert.match(caught.message, /already running/);
  } finally {
    child.kill("SIGKILL");
    await new Promise((r) => setTimeout(r, 200));
  }
});

test("after the holder is SIGKILL'd, a new acquirer succeeds within the stale window", async () => {
  const p = freshLockPath();
  const holderScript = `
    import { acquireAgentLock } from "${path
      .resolve(__dirname, "..", "src", "lockfile.js")
      .replace(/\\\\/g, "\\\\\\\\")}";
    const handle = acquireAgentLock(${JSON.stringify(p)});
    process.stdout.write("LOCKED\\n");
    setTimeout(() => {}, 60000);  // hold forever (until killed)
  `;
  const child = spawn(process.execPath, ["--input-type=module", "-e", holderScript], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  try {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("child timeout")), 3000);
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk) => {
        if (chunk.includes("LOCKED")) {
          clearTimeout(timer);
          resolve();
        }
      });
    });

    child.kill("SIGKILL");
    // Our stale threshold (set in lockfile.js) is 5s. Wait long
    // enough for the lock to be considered stale and reclaimable.
    await new Promise((r) => setTimeout(r, 6_000));

    const handle = acquireAgentLock(p);
    try {
      assert.equal(fs.existsSync(`${p}.lock`), true);
    } finally {
      handle.release();
    }
  } finally {
    child.kill("SIGKILL");
  }
});
