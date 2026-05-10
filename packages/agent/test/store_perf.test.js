// Store write throughput + concurrency harness.
//
// SQLite is the single point of contention between every wrapper
// process and the agent. If a single transcript chunk takes more
// than a few ms, the wrapper's stdout pump backs up and the user
// sees terminal output stutter. This harness records:
//
//   - p50 / p95 / p99 latency of appendTranscript (the hot path)
//   - throughput in writes/second under burst
//   - sustained throughput over a long run (warm cache)
//
// All numbers are baseline; future regressions show up immediately.

import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { performance } from "node:perf_hooks";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { createStore } from "../src/store.js";

let tmpDir;
let store;
const SESSION_ID = "perf-session";

function percentile(values, p) {
  const sorted = [...values].sort((a, b) => a - b);
  const idx = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return sorted[idx];
}

beforeEach(() => {
  tmpDir = mkdtempSync(path.join(tmpdir(), "steer-perf-"));
  const dbPath = path.join(tmpDir, "perf.sqlite");
  store = createStore(dbPath);
  const now = new Date().toISOString();
  store.upsertSession({
    id: SESSION_ID,
    provider: "codex",
    adapterKind: "pty",
    command: "fake",
    args: [],
    cwd: tmpDir,
    pid: null,
    providerThreadId: null,
    runState: "running",
    createdAt: now,
    updatedAt: now,
  });
});

afterEach(() => {
  store.close();
  rmSync(tmpDir, { recursive: true, force: true });
});

test("store: appendTranscript p50 < 2ms, p95 < 10ms over 500 writes", () => {
  const samples = [];
  for (let i = 0; i < 500; i++) {
    const start = performance.now();
    store.appendTranscript({
      sessionId: SESSION_ID,
      stream: "stdout",
      chunk: `line ${i} of perf transcript with some realistic content`,
    });
    samples.push(performance.now() - start);
  }
  const p50 = percentile(samples, 50);
  const p95 = percentile(samples, 95);
  const p99 = percentile(samples, 99);
  console.log(`[perf] store.appendTranscript p50=${p50.toFixed(3)}ms p95=${p95.toFixed(3)}ms p99=${p99.toFixed(3)}ms`);

  assert.ok(p50 < 2.0, `p50 ${p50.toFixed(3)}ms over 2ms budget`);
  assert.ok(p95 < 10.0, `p95 ${p95.toFixed(3)}ms over 10ms budget`);
});

test("store: throughput stays above 500 writes/s sustained", () => {
  // Warm the page cache with one batch first; we want the steady-state
  // number, not the cold-start number.
  for (let i = 0; i < 100; i++) {
    store.appendTranscript({ sessionId: SESSION_ID, stream: "stdout", chunk: `warm ${i}` });
  }
  const start = performance.now();
  for (let i = 0; i < 1000; i++) {
    store.appendTranscript({ sessionId: SESSION_ID, stream: "stdout", chunk: `bench ${i}` });
  }
  const elapsedMs = performance.now() - start;
  const opsPerSecond = (1000 / elapsedMs) * 1000;
  console.log(`[perf] store throughput ${opsPerSecond.toFixed(0)} writes/s (${elapsedMs.toFixed(1)}ms for 1k)`);

  assert.ok(opsPerSecond > 500, `${opsPerSecond.toFixed(0)} writes/s under 500/s floor`);
});

test("store: bursts of mixed streams stay inside latency budget", () => {
  // Simulate the real wrapper: stdout chunks interleaved with state
  // updates and occasional reports. p99 must stay reasonable so the
  // wrapper's pump doesn't back up on the burst.
  const samples = [];
  const streams = ["stdout", "stderr", "pty", "report", "system"];
  for (let i = 0; i < 1000; i++) {
    const stream = streams[i % streams.length];
    const start = performance.now();
    store.appendTranscript({
      sessionId: SESSION_ID,
      stream,
      chunk: `mixed ${stream} chunk ${i}`,
    });
    samples.push(performance.now() - start);
  }
  const p99 = percentile(samples, 99);
  console.log(`[perf] store mixed streams p99=${p99.toFixed(3)}ms over 1k writes`);
  assert.ok(p99 < 25.0, `p99 ${p99.toFixed(3)}ms over 25ms budget`);
});
