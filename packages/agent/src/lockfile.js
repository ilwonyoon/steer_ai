// Exclusive lockfile for the SteerAgent process.
//
// The agent's singleton check used to be a probe of the Unix socket
// (~/.steer/steer.sock), executed inside agent.js right before
// `createStore`. The problem: when two agents start within the same
// few milliseconds (typical when multiple `steer codex` wrappers
// boot from refresh-dogfood / shell startup / multiple terminals at
// once), both probe BEFORE either has bound the socket. Both proceed
// to `createStore`, both race on the SQLite WAL open. The loser dies
// with `SQLITE_ERROR: database is locked`; its wrapper's session is
// flipped to `disconnected` and no further card publish fires.
//
// The fix: a filesystem-level mutex taken BEFORE `createStore` and
// held until the process exits.
//
// Why an OS-level file lock and not a sentinel PID file:
//   - OS-level locks are released automatically when the holder
//     dies, even via SIGKILL. PID files leak.
//   - `flock(2)` on Darwin/Linux is exactly the primitive we want;
//     Node exposes it via `O_EXLOCK` (BSD/Darwin) or, portably,
//     via a non-blocking exclusive open of the lockfile combined
//     with a flock syscall through `proper-lockfile` style.
//   - We don't have a lockfile dependency available, but Node's
//     own `fs.openSync(path, 'wx')` is atomic exclusive-create. A
//     stale lockfile (process crashed without unlinking) is
//     detected by reading the recorded PID and confirming the
//     process is still alive via `process.kill(pid, 0)`.
//
// Public API: `acquireAgentLock(lockPath) -> { release(): void }`.
// Throws `AgentLockHeld` if a live agent already holds the lock.
//
// `acquireAgentLock` is intentionally synchronous so it can run in
// the agent's bootstrap top-of-file path (before the rest of the
// initialization). All it does is one `open()` and one `write()`.

import fs from "node:fs";

export class AgentLockHeld extends Error {
  constructor(holderPid, lockPath) {
    super(
      `another SteerAgent is already running (pid=${holderPid}, lock=${lockPath})`
    );
    this.code = "AGENT_LOCK_HELD";
    this.holderPid = holderPid;
    this.lockPath = lockPath;
  }
}

function isProcessAlive(pid) {
  if (!Number.isFinite(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM = process exists but we can't signal it (different user).
    // ESRCH = no such process.
    return error.code === "EPERM";
  }
}

function readLockHolderPid(lockPath) {
  try {
    const raw = fs.readFileSync(lockPath, "utf8").trim();
    const pid = Number.parseInt(raw, 10);
    return Number.isFinite(pid) ? pid : null;
  } catch {
    return null;
  }
}

/**
 * Acquire the agent lock. Returns an opaque handle whose `release()`
 * method removes the lockfile.
 *
 * Throws `AgentLockHeld` if another agent process owns the lock.
 * Throws other I/O errors as-is (permission denied, disk full, ...).
 */
export function acquireAgentLock(lockPath) {
  // Loop at most twice: first attempt the exclusive create; if it
  // fails because the file already exists, inspect the holder. If
  // the holder is dead (stale file from a crash), unlink and retry
  // exactly once. Any further failure is the contention we surface
  // to the caller.
  for (let attempt = 0; attempt < 2; attempt++) {
    let fd;
    try {
      fd = fs.openSync(lockPath, "wx");
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      const holderPid = readLockHolderPid(lockPath);
      if (holderPid && isProcessAlive(holderPid)) {
        throw new AgentLockHeld(holderPid, lockPath);
      }
      // Stale lockfile. Remove and retry once.
      try {
        fs.unlinkSync(lockPath);
      } catch {
        // Race with another claimant who unlinked first — retry.
      }
      continue;
    }

    try {
      fs.writeSync(fd, String(process.pid));
    } finally {
      try {
        fs.closeSync(fd);
      } catch {}
    }

    return {
      release() {
        try {
          // Only unlink if it's still ours (PID match). Defense
          // against the rare case where our process slept long
          // enough for another agent to forcibly take over.
          const ownerPid = readLockHolderPid(lockPath);
          if (ownerPid === process.pid) {
            fs.unlinkSync(lockPath);
          }
        } catch {}
      },
    };
  }
  // Shouldn't reach here — the loop either returns or throws.
  throw new Error("acquireAgentLock: exceeded retry budget");
}
