// PR S1 — lockfile.js unit tests.
//
// agent_concurrent_spawn.test.js covers the end-to-end "two agents
// can't race" scenario; this file covers the edge cases inside
// acquireAgentLock itself:
//   - Stale lockfile detection + retry.
//   - Live-holder rejection.
//   - Release semantics (only unlinks if we own it).

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { acquireAgentLock, AgentLockHeld } from "../src/lockfile.js";

function freshLockPath() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "steer-lock-"));
  return path.join(dir, "agent.lock");
}

test("first call creates the lockfile and writes our pid", () => {
  const p = freshLockPath();
  const handle = acquireAgentLock(p);
  try {
    assert.equal(fs.existsSync(p), true);
    const contents = fs.readFileSync(p, "utf8");
    assert.equal(contents, String(process.pid));
  } finally {
    handle.release();
  }
});

test("release unlinks the lockfile", () => {
  const p = freshLockPath();
  const handle = acquireAgentLock(p);
  handle.release();
  assert.equal(fs.existsSync(p), false);
});

test("release is a no-op when the lockfile holder pid no longer matches", () => {
  const p = freshLockPath();
  const handle = acquireAgentLock(p);
  // Overwrite the pid so release sees a different owner — release
  // should NOT delete the file.
  fs.writeFileSync(p, "99999");
  handle.release();
  assert.equal(fs.existsSync(p), true, "must not delete a lockfile owned by someone else");
  // Manual cleanup.
  fs.unlinkSync(p);
});

test("stale lockfile (dead holder pid) is reclaimed", () => {
  const p = freshLockPath();
  // Write a pid that's almost certainly not running.
  fs.writeFileSync(p, "999999");
  const handle = acquireAgentLock(p);
  try {
    const contents = fs.readFileSync(p, "utf8");
    assert.equal(contents, String(process.pid));
  } finally {
    handle.release();
  }
});

test("live holder pid: throws AgentLockHeld with holderPid + lockPath", async () => {
  const p = freshLockPath();
  // Spawn a child sleep that we'll record as the lock holder.
  const child = spawn("sleep", ["30"]);
  try {
    fs.writeFileSync(p, String(child.pid));
    let caught;
    try {
      acquireAgentLock(p);
    } catch (e) {
      caught = e;
    }
    assert.ok(caught instanceof AgentLockHeld, "must throw AgentLockHeld");
    assert.equal(caught.holderPid, child.pid);
    assert.equal(caught.lockPath, p);
    assert.match(caught.message, /already running/);
  } finally {
    child.kill("SIGKILL");
    try { fs.unlinkSync(p); } catch {}
  }
});

test("non-numeric lockfile contents → treated as stale and reclaimed", () => {
  const p = freshLockPath();
  fs.writeFileSync(p, "not-a-pid");
  const handle = acquireAgentLock(p);
  try {
    const contents = fs.readFileSync(p, "utf8");
    assert.equal(contents, String(process.pid));
  } finally {
    handle.release();
  }
});

test("acquire after release in same process is allowed", () => {
  const p = freshLockPath();
  const a = acquireAgentLock(p);
  a.release();
  const b = acquireAgentLock(p);
  try {
    const contents = fs.readFileSync(p, "utf8");
    assert.equal(contents, String(process.pid));
  } finally {
    b.release();
  }
});
