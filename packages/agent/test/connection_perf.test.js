// Connection-stability harness for the Terminal -> Mac path.
//
// We don't measure raw classifier algorithm correctness here — that's
// in classifier.test.js. We measure the *latency budget* a real
// session must keep so the Mac UI feels live:
//
//   - p50 classifier latency per transcript      target < 1ms
//   - p95 classifier latency per transcript      target < 5ms
//   - 100 transcripts / second sustained         target no thrash
//
// If a future change regresses these numbers the test fails and CI
// flags it.  Numbers are recorded so a "before/after" claim has
// receipts.

import { test } from "node:test";
import assert from "node:assert/strict";
import { performance } from "node:perf_hooks";
import { classifyTranscript } from "../src/classifier.js";

function percentile(values, p) {
  const sorted = [...values].sort((a, b) => a - b);
  const idx = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return sorted[idx];
}

function runOne(session, entries) {
  const start = performance.now();
  classifyTranscript({ session, entries });
  return performance.now() - start;
}

test("classifier: 1k iterations short transcript stays inside latency budget", () => {
  const session = {
    id: "perf-session",
    provider: "codex",
    cwd: "/tmp/perf",
    runState: "waiting",
  };
  const entries = [
    { kind: "report", text: "Need decision: option A or option B?", at: Date.now() },
  ];

  const samples = [];
  for (let i = 0; i < 1000; i++) {
    samples.push(runOne(session, entries));
  }
  const p50 = percentile(samples, 50);
  const p95 = percentile(samples, 95);
  const p99 = percentile(samples, 99);

  // Print so CI logs leave a trail.
  console.log(`[perf] classifier short  p50=${p50.toFixed(3)}ms p95=${p95.toFixed(3)}ms p99=${p99.toFixed(3)}ms`);

  assert.ok(p50 < 1.0, `p50 ${p50.toFixed(3)}ms exceeds 1ms budget`);
  assert.ok(p95 < 5.0, `p95 ${p95.toFixed(3)}ms exceeds 5ms budget`);
});

test("classifier: long terminal transcript stays inside latency budget", () => {
  // Realistic noisy Codex transcript: 200 lines of mixed content.
  const lines = [];
  for (let i = 0; i < 60; i++) lines.push(`  working...   `);
  for (let i = 0; i < 30; i++) lines.push(`Step ${i}: doing the thing on file_${i}.ts`);
  lines.push("");
  lines.push("Decision needed:");
  lines.push("- Option A: keep migration as is");
  lines.push("- Option B: split into two");
  lines.push("");
  lines.push("Which one?");
  for (let i = 0; i < 100; i++) lines.push("  > waiting"); // chrome repaints

  const session = {
    id: "perf-session-long",
    provider: "codex",
    cwd: "/tmp/perf",
    runState: "waiting",
  };
  const entries = [
    { kind: "report", text: lines.join("\n"), at: Date.now() },
  ];

  const samples = [];
  for (let i = 0; i < 200; i++) {
    samples.push(runOne(session, entries));
  }
  const p50 = percentile(samples, 50);
  const p95 = percentile(samples, 95);
  const p99 = percentile(samples, 99);
  console.log(`[perf] classifier long   p50=${p50.toFixed(3)}ms p95=${p95.toFixed(3)}ms p99=${p99.toFixed(3)}ms`);

  // Long transcripts cost more — keep budget realistic, not aspirational.
  assert.ok(p50 < 5.0, `p50 ${p50.toFixed(3)}ms exceeds 5ms budget`);
  assert.ok(p95 < 25.0, `p95 ${p95.toFixed(3)}ms exceeds 25ms budget`);
});

test("classifier: 1000 unique sessions throughput stays above 200 ops/s", () => {
  const start = performance.now();
  for (let i = 0; i < 1000; i++) {
    classifyTranscript({
      session: { id: `s-${i}`, provider: "claude", cwd: `/tmp/${i}`, runState: "waiting" },
      entries: [{ kind: "report", text: `Question ${i}?`, at: Date.now() }],
    });
  }
  const elapsedMs = performance.now() - start;
  const opsPerSecond = (1000 / elapsedMs) * 1000;
  console.log(`[perf] classifier throughput ${opsPerSecond.toFixed(0)} ops/s (${elapsedMs.toFixed(1)}ms for 1k)`);

  assert.ok(opsPerSecond > 200, `${opsPerSecond.toFixed(0)} ops/s under 200 ops/s floor`);
});
