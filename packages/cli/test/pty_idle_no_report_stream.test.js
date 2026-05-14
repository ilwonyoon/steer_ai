// Regression guard: `schedulePtyIdleReport` must never publish PTY
// buffer contents as a `report` stream. PTY screen grabs from the
// Claude TUI are split-pane + status-bar + wrap; feeding them through
// the classifier as trusted output produced the jumbled card body the
// user saw on 2026-05-14 (CLASSIFIER_CONTRACT: PTY is NOT trusted).
//
// Trusted card bodies come from the Claude Stop hook (`hook_event`)
// or Codex's `turn/completed` (codex session reader). The idle-detect
// path may only flip `runState` to "waiting"; it may not emit text.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const SRC = readFileSync(
  path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "../src/index.js"
  ),
  "utf8"
);

function extractFunctionBody(source, name) {
  const header = `function ${name}(`;
  const start = source.indexOf(header);
  assert.notEqual(start, -1, `${name} not found in source`);

  let depth = 0;
  let inBody = false;
  for (let i = start; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === "{") {
      depth += 1;
      inBody = true;
    } else if (ch === "}") {
      depth -= 1;
      if (inBody && depth === 0) {
        return source.slice(start, i + 1);
      }
    }
  }
  throw new Error(`${name} body unbalanced`);
}

test("schedulePtyIdleReport never writes a `report` stream", () => {
  const body = extractFunctionBody(SRC, "schedulePtyIdleReport");
  assert.ok(
    !/stream:\s*["']report["']/.test(body),
    "schedulePtyIdleReport must not publish PTY screen contents as a `report` stream. " +
      "Trusted card bodies come from the Claude Stop hook or Codex turn/completed. " +
      "If you need the user to see something on idle, flip runState, not stream."
  );
});

test("schedulePtyIdleReport flips runState to waiting on idle", () => {
  const body = extractFunctionBody(SRC, "schedulePtyIdleReport");
  assert.ok(
    /runState:\s*["']waiting["']/.test(body),
    "schedulePtyIdleReport should still flip runState to 'waiting' when the TUI goes idle " +
      "(that's the whole point of the idle detector — the body emission is what we banned, " +
      "not the state transition)."
  );
});
