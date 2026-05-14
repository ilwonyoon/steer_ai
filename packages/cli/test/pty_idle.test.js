import test from "node:test";
import assert from "node:assert/strict";
import { extractPtyIdleReport } from "../src/pty_idle.js";

test("extracts Codex idle assistant text when the prompt returns", () => {
  const raw = [
    "\x1B[1;1H│ >_ OpenAI Codex (v0.128.0)",
    "\x1B[2;1H│ model: gpt-5.5 high fast /model to",
    "\x1B[3;1H│ directory: ~/Documents/Steer_ai",
    "\x1B[10;1H⚠ Under-development features enabled: goals.",
    "\x1B[11;1H  incomplete and may behave unpredictably. To suppress this warning, set",
    "\x1B[12;1H•Working(0s • esc to interrupt)",
    "\x1B[40;1H• Hi. What would you like to work on in steer_ai?",
    "\x1B[48;1H› "
  ].join("");

  assert.equal(
    extractPtyIdleReport("codex", raw),
    "Hi. What would you like to work on in steer_ai?"
  );
});

test("does not extract Codex text before the input prompt returns", () => {
  const raw = "\x1B[1;1H• Working on the request...";

  assert.equal(extractPtyIdleReport("codex", raw), null);
});

test("ignores Codex startup chrome at an empty prompt", () => {
  const raw = [
    "\x1B[1;1H│ >_ OpenAI Codex (v0.128.0)",
    "\x1B[2;1H│ model: gpt-5.5 high fast /model to",
    "\x1B[3;1H│ directory: ~/Documents/Steer_ai",
    "\x1B[48;1H› "
  ].join("");

  assert.equal(extractPtyIdleReport("codex", raw), null);
});
