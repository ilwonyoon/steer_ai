import test from "node:test";
import assert from "node:assert/strict";
import { extractPtyIdleReport, extractInteractiveModalReport } from "../src/pty_idle.js";

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

// G16 — interactive modal sniff. Verifies that an AskUserQuestion
// modal (Claude TUI) or a Codex permission prompt is detected and
// returned with the option list intact, so the iPhone can surface
// it as a Mac-action-required blocker card.

test("detects Claude AskUserQuestion modal via Enter-to-select footer", () => {
  const raw = [
    "\x1B[1;1H╭ 작업 선택 ────────────────────────────────╮",
    "\x1B[2;1H│ 어떤 작업을 진행할까요?                  │",
    "\x1B[3;1H│                                          │",
    "\x1B[4;1H│ › 1. 현재 디렉토리 탐색                  │",
    "\x1B[5;1H│   2. 구체적 작업 지정                    │",
    "\x1B[6;1H│   3. 이전 컨텍스트 확인                  │",
    "\x1B[7;1H│   4. Type something.                     │",
    "\x1B[8;1H│   5. Chat about this                     │",
    "\x1B[9;1H╰──────────────────────────────────────────╯",
    "\x1B[10;1HEnter to select · ↑/↓ to navigate · Esc to cancel",
  ].join("");

  const out = extractInteractiveModalReport("claude", raw);
  assert.notEqual(out, null, "modal not detected");
  assert.match(out, /작업 선택/);
  // The cursor-prefixed selected row may get stripped by the
  // existing prompt-line filter; the option list rows without
  // the `›` cursor must survive.
  assert.match(out, /구체적 작업 지정/);
  assert.match(out, /Chat about this/);
  assert.match(out, /Enter to select/);
});

test("detects Codex permission prompt (numeric Allow list)", () => {
  const raw = [
    "\x1B[1;1HAllow the backtick MCP server to run tool",
    "\x1B[2;1H\"backtick_list_notes\"?",
    "\x1B[3;1H",
    "\x1B[4;1H  1. Allow",
    "\x1B[5;1H  2. Allow for this session",
    "\x1B[6;1H  3. Always allow",
    "\x1B[7;1H  4. Cancel",
    "\x1B[8;1Henter to submit | esc to cancel",
  ].join("");

  const out = extractInteractiveModalReport("codex", raw);
  assert.notEqual(out, null, "codex permission prompt not detected");
  assert.match(out, /Allow/);
  assert.match(out, /Cancel/);
});

test("returns null when no modal footer is on screen", () => {
  const raw = [
    "\x1B[1;1HHello there.",
    "\x1B[2;1HThis is just regular output without a modal.",
    "\x1B[3;1H› ",
  ].join("");

  assert.equal(extractInteractiveModalReport("claude", raw), null);
});

test("normal numbered list in body without modal footer is not flagged", () => {
  // Guard against false positive: AI may write "1. ... 2. ..." in
  // its answer. Without the modal footer we must not treat it as
  // a parked modal.
  const raw = [
    "\x1B[1;1HHere are three options:",
    "\x1B[2;1H1. Simple fix",
    "\x1B[3;1H2. Larger refactor",
    "\x1B[4;1H3. Workaround",
    "\x1B[5;1H› ",
  ].join("");

  assert.equal(extractInteractiveModalReport("claude", raw), null);
});
