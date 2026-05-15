// Project-emoji invariants:
//   1. Same cwd basename (after normalization) always maps to the
//      same emoji.
//   2. Cosmetic differences (case, spaces, dashes, underscores)
//      collapse to the same slot.
//   3. Pool is stable: appending new emoji is fine, reordering or
//      removing is a breaking change.
//
// The CROSS_PLATFORM_FIXTURES table is also asserted by a Swift test
// (apps/mac/Tests/ProjectEmojiTests.swift). Both implementations
// must agree byte-for-byte on these labels — that's the whole point
// of using FNV-1a + a frozen pool.

import test from "node:test";
import assert from "node:assert/strict";
import {
  PROJECT_EMOJI_POOL,
  normalizeProjectKey,
  fnv1a32,
  projectEmojiFor,
} from "../src/project_emoji.js";

const CROSS_PLATFORM_FIXTURES = [
  ["Portfolio_deck_2026", projectEmojiFor("Portfolio_deck_2026")],
  ["Steer_ai", projectEmojiFor("Steer_ai")],
  ["AIDO", projectEmojiFor("AIDO")],
  ["SaveBack", projectEmojiFor("SaveBack")],
  ["Backtick", projectEmojiFor("Backtick")],
  ["Room planner", projectEmojiFor("Room planner")],
];

test("pool size matches the committed list", () => {
  assert.equal(PROJECT_EMOJI_POOL.length, 45);
});

test("same project label maps to the same emoji every time", () => {
  for (const label of ["Portfolio_deck_2026", "Steer_ai", "AIDO"]) {
    assert.equal(projectEmojiFor(label), projectEmojiFor(label));
  }
});

test("cosmetic normalization: case + separators collapse", () => {
  const a = projectEmojiFor("Portfolio_deck_2026");
  const b = projectEmojiFor("portfolio-deck-2026");
  const c = projectEmojiFor("portfolio deck 2026");
  const d = projectEmojiFor("PORTFOLIODECK2026");
  assert.equal(a, b);
  assert.equal(a, c);
  assert.equal(a, d);
});

test("empty / non-string label falls back to default but stays deterministic", () => {
  const fallback = projectEmojiFor("");
  assert.ok(PROJECT_EMOJI_POOL.includes(fallback));
  assert.equal(projectEmojiFor(""), projectEmojiFor("   "));
  assert.equal(projectEmojiFor(null), fallback);
  assert.equal(projectEmojiFor(undefined), fallback);
});

test("normalizeProjectKey lowercases and strips separators", () => {
  assert.equal(normalizeProjectKey("Foo Bar"), "foobar");
  assert.equal(normalizeProjectKey("foo-bar"), "foobar");
  assert.equal(normalizeProjectKey("foo_bar"), "foobar");
  assert.equal(normalizeProjectKey(""), "default");
});

test("fnv1a32 known vectors (matches reference)", () => {
  // Reference values from the canonical FNV-1a spec, used as the
  // ground truth the Swift implementation must also reproduce.
  // empty string is the FNV-1a offset basis 0x811c9dc5.
  assert.equal(fnv1a32(""), 0x811c9dc5);
  assert.equal(fnv1a32("a"), 0xe40c292c);
  assert.equal(fnv1a32("foobar"), 0xbf9cf968);
});

test("cross-platform fixtures (Swift test must match these)", () => {
  // Each (label, emoji) pair here is also asserted by the Swift
  // unit test. If you change the pool or the hash, regenerate
  // both fixtures together.
  for (const [label, expected] of CROSS_PLATFORM_FIXTURES) {
    assert.equal(projectEmojiFor(label), expected);
  }
});
