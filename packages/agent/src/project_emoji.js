// Deterministic project emoji mapping: every session that lives in the
// same project folder (cwd basename) lands on the same emoji without
// any per-project storage.
//
// Stage 1 = display only. Stage 2 will let the user override per
// session and persist the choice in `sessions.emoji`; the override
// wins over this default when set.
//
// The hash + pool are duplicated in apps/{mac,ios} (Swift). Both
// implementations MUST stay in sync — a session loaded by either
// client should land on the same default emoji. The unit tests in
// packages/agent/test/project_emoji.test.js + the Swift test in
// apps/.../Tests/ProjectEmojiTests.swift lock the cross-platform
// invariant with a shared fixture set.

export const PROJECT_EMOJI_POOL = [
  "🚀", "⚡️", "🔧", "🛠", "⚙️", "🧪", "🧰", "🧱", "📦", "🗂",
  "📐", "📊", "🧭", "🔬", "🪛", "🛰", "🛸", "🧠", "💡", "🔭",
  "🧲", "🪐", "🌱", "🌿", "🍀", "🌊", "🔥", "✨", "🪄", "🎯",
  "🎛", "🕹", "🎚", "🧩", "🪞", "🦾", "🪪", "📎", "🔗", "⛓",
  "🧷", "🗝", "🎨", "🖋", "📝"
];

/// Normalize a project label (cwd basename) so the hash is stable
/// across trivial cosmetic differences. Lowercased; spaces, dashes,
/// and underscores collapse to nothing. "Portfolio_deck_2026" and
/// "portfolio-deck-2026" and "portfolio deck 2026" all hash to the
/// same slot. Empty strings fall back to "default" so we still
/// return a deterministic emoji.
export function normalizeProjectKey(label) {
  if (typeof label !== "string") return "default";
  const cleaned = label
    .toLowerCase()
    .replace(/[\s_\-]+/g, "");
  return cleaned.length > 0 ? cleaned : "default";
}

/// FNV-1a 32-bit. Picked because it's short, deterministic, and
/// trivial to re-implement byte-for-byte in Swift. Cross-platform
/// parity matters more than cryptographic strength here.
export function fnv1a32(input) {
  let hash = 0x811c9dc5;
  for (let i = 0; i < input.length; i += 1) {
    hash ^= input.charCodeAt(i) & 0xff;
    // 32-bit truncated multiply by FNV prime (0x01000193). We work
    // in 32 bits with Math.imul to stay inside JS's int range.
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash >>> 0;
}

/// Deterministic mapping from a normalized project key to a pool
/// entry. Stable forever as long as PROJECT_EMOJI_POOL doesn't
/// reorder — appending new emoji to the end is safe; reordering
/// or removing entries shifts everyone's emoji.
export function projectEmojiFor(label) {
  const key = normalizeProjectKey(label);
  const index = fnv1a32(key) % PROJECT_EMOJI_POOL.length;
  return PROJECT_EMOJI_POOL[index];
}
