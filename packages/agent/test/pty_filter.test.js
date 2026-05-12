import { test } from "node:test";
import assert from "node:assert/strict";
import { isWhitespaceOnlyPty } from "../src/store.js";

// S2 — appendTranscript drops pty chunks whose post-ANSI-strip
// content is whitespace-only. The classifier already discards
// these on read, so persisting them is pure overhead (the bulk of
// the 1.8GB DB users hit in dogfood).
//
// These tests cover the filter predicate in isolation. The wrapper
// invariant suite (STEER_INTEGRATION=1) covers the full classify
// path to prove the filter doesn't drop semantically meaningful
// content.

test("plain whitespace pty chunk is whitespace-only", () => {
  assert.equal(isWhitespaceOnlyPty(""), true);
  assert.equal(isWhitespaceOnlyPty("   "), true);
  assert.equal(isWhitespaceOnlyPty("\n\n"), true);
  assert.equal(isWhitespaceOnlyPty("\r\n"), true);
  assert.equal(isWhitespaceOnlyPty(" \t \r\n "), true);
});

test("CSI cursor moves with no real content are whitespace-only", () => {
  // ESC[H = cursor to home
  assert.equal(isWhitespaceOnlyPty("\x1b[H"), true);
  // ESC[2K = erase line
  assert.equal(isWhitespaceOnlyPty("\x1b[2K"), true);
  // ESC[?25l = hide cursor; ESC[?25h = show cursor
  assert.equal(isWhitespaceOnlyPty("\x1b[?25l\x1b[?25h"), true);
  // Multiple moves + line erase = repaint, no content
  assert.equal(
    isWhitespaceOnlyPty("\x1b[H\x1b[2J\x1b[1;1H"),
    true
  );
});

test("color SGR sequences alone are whitespace-only", () => {
  // ESC[1;31m = bold red, ESC[0m = reset — but no text in between
  assert.equal(isWhitespaceOnlyPty("\x1b[1;31m\x1b[0m"), true);
});

test("OSC title updates are whitespace-only", () => {
  // ESC]0;some title\x07 — terminal-title set
  assert.equal(isWhitespaceOnlyPty("\x1b]0;Steer\x07"), true);
});

test("pty chunk with even one printable character is kept", () => {
  assert.equal(isWhitespaceOnlyPty("a"), false);
  assert.equal(isWhitespaceOnlyPty("\x1b[1;31mERROR\x1b[0m"), false);
  // Real codex/claude output: prompt char + spacing
  assert.equal(isWhitespaceOnlyPty("\x1b[H\x1b[2K> ready"), false);
  // Korean / Unicode characters
  assert.equal(isWhitespaceOnlyPty("안녕"), false);
  assert.equal(isWhitespaceOnlyPty("\x1b[2K안녕"), false);
});

test("non-string inputs are treated as whitespace-only", () => {
  assert.equal(isWhitespaceOnlyPty(null), true);
  assert.equal(isWhitespaceOnlyPty(undefined), true);
  assert.equal(isWhitespaceOnlyPty(123), true);
});

test("standalone control characters are whitespace-only", () => {
  // BEL, lone ESC, NUL, etc.
  assert.equal(isWhitespaceOnlyPty("\x07"), true);
  assert.equal(isWhitespaceOnlyPty("\x1b"), true);
  assert.equal(isWhitespaceOnlyPty("\x00\x07\x1b"), true);
});

test("malformed escape sequence followed by content keeps the chunk", () => {
  // Defensive: even if the strip pattern leaves cruft, real content
  // after it should preserve the chunk. We do not want to drop a
  // half-decoded chunk that turns out to carry meaning.
  assert.equal(isWhitespaceOnlyPty("\x1b[hello"), false);
});
