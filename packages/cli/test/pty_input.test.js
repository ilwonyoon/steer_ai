import test from "node:test";
import assert from "node:assert/strict";
import { formatPtyInstructionInput } from "../src/pty_input.js";

test("keeps single-line PTY instructions unchanged", () => {
  assert.equal(formatPtyInstructionInput("codex", "Use option A"), "Use option A");
});

test("wraps Codex multiline instructions in bracketed paste", () => {
  assert.equal(
    formatPtyInstructionInput("codex", "Line one\nLine two"),
    "\x1B[200~Line one\nLine two\x1B[201~"
  );
});

test("wraps Claude multiline instructions in bracketed paste", () => {
  assert.equal(
    formatPtyInstructionInput("claude", "Line one\r\nLine two"),
    "\x1B[200~Line one\nLine two\x1B[201~"
  );
});

test("does not assume bracketed paste support for custom wrappers", () => {
  assert.equal(formatPtyInstructionInput("custom", "Line one\nLine two"), "Line one\nLine two");
});
