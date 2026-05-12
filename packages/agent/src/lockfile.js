// OS-level exclusive lock for the SteerAgent process.
//
// Acquired BEFORE `createStore` so two agents can't race the
// SQLite open path. Holds for the lifetime of the agent and is
// released automatically by the OS on process death (no PID
// liveness check required).
//
// Implementation: wraps `proper-lockfile`, the maintained
// userland-around-syscall lockfile package. Why this and not a
// custom retry loop:
//
//   - `proper-lockfile` couples acquire-and-stale-detection inside
//     a single atomic attempt. Our previous custom retry loop had
//     a window where two processes could both pass the "holder is
//     dead" check, both `unlinkSync`, and both `openSync(..., 'wx')`
//     because the unlink+create dance isn't atomic from userland.
//   - It uses `lockfile.lock(target)` which creates a sibling
//     `.lock` directory atomically (mkdir is atomic on POSIX),
//     not a regular file open. Directories can't be partially
//     created so the race window collapses.
//   - Staleness detection is via the lockfile mtime, refreshed by
//     a background updater. Threshold default 10s. Dead holders
//     stop refreshing → next acquirer reclaims.
//   - On process crash (SIGKILL, ENOMEM, panic), the lockfile
//     simply stops being refreshed and the next acquirer reclaims
//     after the staleness threshold. No PID liveness ambiguity
//     (Darwin's `EPERM` on reaped pids broke our previous impl).
//
// We deliberately wrap it so callers see the same surface as
// before — `acquireAgentLock(path) -> { release() }` and an
// `AgentLockHeld` error class — and so future swaps of the
// underlying lock library are a one-file change.

import fs from "node:fs";
import properLockfile from "proper-lockfile";

export class AgentLockHeld extends Error {
  constructor(lockPath) {
    super(`another SteerAgent is already running (lock=${lockPath})`);
    this.code = "AGENT_LOCK_HELD";
    this.lockPath = lockPath;
  }
}

/**
 * Acquire the agent lock. Returns a handle whose `release()`
 * removes the lock.
 *
 * Sync interface preserved for callers in agent.js's bootstrap
 * top-of-file, which needs to run before any async work.
 * `proper-lockfile` exposes a sync variant (`lockSync`).
 *
 * Throws `AgentLockHeld` if another live process owns the lock.
 * Other I/O errors propagate as-is.
 */
export function acquireAgentLock(lockPath) {
  // proper-lockfile's stale threshold: how long after the last
  // mtime touch we consider the lock dead. 10s matches the
  // package default and is long enough to absorb a slow SQLite
  // open path on a multi-GB DB; the held lock has a background
  // touch every (stale / 2) = 5s so a live process's lock never
  // crosses the threshold.
  //
  // retries: total acquisition attempts. We use a short retry
  // window so concurrent boots converge within ~250 ms — long
  // enough for the OS to settle but short enough to not stall
  // wrapper startup. After the budget the call throws ELOCKED;
  // we translate to AgentLockHeld so callers can decide what to
  // do.
  // proper-lockfile's `lockSync` operates against an existing
  // file or directory — it creates a sibling `.lock` directory
  // for the actual mutex. Touch the target path so the call
  // resolves; the file's contents are irrelevant.
  try {
    fs.closeSync(fs.openSync(lockPath, "a"));
  } catch {
    // If the path itself is unwritable, surface the error from
    // lockSync below where it's contextualized.
  }
  // proper-lockfile's sync API rejects the `retries` option, but
  // we want a short retry window so that:
  //   - Multiple concurrent boots converge cleanly (the loser
  //     gets ELOCKED on the first try and we don't want to throw
  //     AgentLockHeld too eagerly when the OS lock just lost a
  //     nanosecond race).
  //   - A SIGKILL'd predecessor's stale lock gets reclaimed
  //     without forcing us to keep `stale` very high.
  // We implement the retry manually with `Atomics.wait` on a
  // shared buffer for synchronous backoff. Each attempt remains
  // OS-atomic via proper-lockfile.
  const sharedBuf = new SharedArrayBuffer(4);
  const sharedView = new Int32Array(sharedBuf);
  const sleepSync = (ms) => Atomics.wait(sharedView, 0, 0, ms);

  // Two-phase contention budget:
  //   - STALE_MS: how long after the last lock refresh we treat
  //     the holder as dead. proper-lockfile refreshes every
  //     stale/2 ms while alive, so STALE_MS=5s means a live
  //     holder refreshes ~every 2.5s and is never falsely
  //     considered stale.
  //   - RETRY_BUDGET_MS: how long we keep trying before giving
  //     up and surfacing AgentLockHeld. Must exceed STALE_MS so
  //     that after a SIGKILL'd predecessor, a new acquirer
  //     waits long enough for the stale window to open before
  //     it gives up.
  // Net effect: a freshly-orphaned lockfile is reclaimed in
  // ~5-6 s; live-holder contention surfaces AgentLockHeld at ~6s.
  const STALE_MS = 5_000;
  const RETRY_BUDGET_MS = 6_000;
  const BACKOFF_MS = 150;
  const deadline = Date.now() + RETRY_BUDGET_MS;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const release = properLockfile.lockSync(lockPath, {
        realpath: false,
        stale: STALE_MS,
      });
      return {
        release() {
          try { release(); } catch { /* already released */ }
        },
      };
    } catch (error) {
      lastError = error;
      // ELOCKED: a live holder owns the lock right now. Wait a
      // beat and retry — the holder may be a transient sibling
      // that's about to exit on its own (mid-race) or a real
      // long-running agent (which we'll surface as AgentLockHeld
      // when the budget runs out).
      //
      // Any other code (EPERM, ENOENT-on-the-target after
      // someone unlinked it during our touch, etc.) is a real
      // I/O failure and we propagate up.
      if (!error || error.code !== "ELOCKED") throw error;
      sleepSync(BACKOFF_MS);
    }
  }
  // Budget exhausted, holder is still alive.
  throw new AgentLockHeld(lockPath);
}
