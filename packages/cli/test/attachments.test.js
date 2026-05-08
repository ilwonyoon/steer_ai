import test from "node:test";
import assert from "node:assert/strict";
import { formatInstructionWithAttachments, ATTACHMENT_MARKER } from "../src/attachments.js";

test("no attachments returns trimmed text unchanged", () => {
  assert.equal(formatInstructionWithAttachments("hello", []), "hello");
  assert.equal(formatInstructionWithAttachments("hello\n", []), "hello");
  assert.equal(formatInstructionWithAttachments("hello", undefined), "hello");
});

test("single attachment is appended after a blank line", () => {
  const out = formatInstructionWithAttachments("read this", ["/tmp/a.png"]);
  assert.equal(out, `read this\n\n${ATTACHMENT_MARKER} /tmp/a.png`);
});

test("multiple attachments stack on consecutive lines", () => {
  const out = formatInstructionWithAttachments("look", ["/a.png", "/b.png", "/c.png"]);
  assert.equal(
    out,
    `look\n\n${ATTACHMENT_MARKER} /a.png\n${ATTACHMENT_MARKER} /b.png\n${ATTACHMENT_MARKER} /c.png`
  );
});

test("empty text + attachments still emits the attachment lines", () => {
  const out = formatInstructionWithAttachments("", ["/only.png"]);
  assert.equal(out, `${ATTACHMENT_MARKER} /only.png`);
});

test("paths with spaces are kept as-is, not quoted", () => {
  const out = formatInstructionWithAttachments(
    "describe",
    ["/Users/Alice/Pictures/Screenshot 2026-05-08.png"]
  );
  assert.equal(
    out,
    `describe\n\n${ATTACHMENT_MARKER} /Users/Alice/Pictures/Screenshot 2026-05-08.png`
  );
});

test("blank attachment entries are dropped", () => {
  const out = formatInstructionWithAttachments("hi", ["", "  ", "/real.png", null, undefined]);
  assert.equal(out, `hi\n\n${ATTACHMENT_MARKER} /real.png`);
});

test("trailing whitespace on text is normalized before joining", () => {
  const out = formatInstructionWithAttachments("hi   \n\n", ["/a.png"]);
  assert.equal(out, `hi\n\n${ATTACHMENT_MARKER} /a.png`);
});
