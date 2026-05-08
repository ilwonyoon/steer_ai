import test from "node:test";
import assert from "node:assert/strict";
import { isCancelChunk } from "../src/cancel_keys.js";

test("Ctrl-C alone is a cancel", () => {
  assert.equal(isCancelChunk(Buffer.from([0x03])), true);
});

test("bare Esc is a cancel", () => {
  assert.equal(isCancelChunk(Buffer.from([0x1B])), true);
});

test("Esc followed by [ is an arrow / CSI sequence, not a cancel", () => {
  assert.equal(isCancelChunk(Buffer.from([0x1B, 0x5B, 0x41])), false); // ↑
  assert.equal(isCancelChunk(Buffer.from([0x1B, 0x5B, 0x42])), false); // ↓
});

test("Esc followed by O is an SS3 function key, not a cancel", () => {
  assert.equal(isCancelChunk(Buffer.from([0x1B, 0x4F, 0x50])), false); // F1
});

test("double Esc still counts as cancel", () => {
  assert.equal(isCancelChunk(Buffer.from([0x1B, 0x1B])), true);
});

test("Esc + Enter (alt-enter) counts as cancel", () => {
  assert.equal(isCancelChunk(Buffer.from([0x1B, 0x0D])), true);
});

test("plain printable text is not a cancel", () => {
  assert.equal(isCancelChunk(Buffer.from("hello")), false);
});

test("empty / null chunks are not cancels", () => {
  assert.equal(isCancelChunk(Buffer.alloc(0)), false);
  assert.equal(isCancelChunk(null), false);
  assert.equal(isCancelChunk(undefined), false);
});
