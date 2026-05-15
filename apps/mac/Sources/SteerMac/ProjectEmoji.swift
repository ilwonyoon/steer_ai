import Foundation

/// Deterministic mapping from a project label (cwd basename) to an
/// emoji from a frozen pool. Mirrors
/// `packages/agent/src/project_emoji.js` exactly so every client
/// arrives at the same default for the same project. Stage 2 will
/// let users pick a per-session override; until then this is the
/// only source of truth.
///
/// Cross-platform invariant: the Node unit test in
/// `packages/agent/test/project_emoji.test.js` and the Swift test
/// in `apps/mac/Tests/ProjectEmojiTests.swift` both assert the
/// same (label → emoji) fixtures.
enum ProjectEmoji {
    static let pool: [String] = [
        "🚀", "⚡️", "🔧", "🛠", "⚙️", "🧪", "🧰", "🧱", "📦", "🗂",
        "📐", "📊", "🧭", "🔬", "🪛", "🛰", "🛸", "🧠", "💡", "🔭",
        "🧲", "🪐", "🌱", "🌿", "🍀", "🌊", "🔥", "✨", "🪄", "🎯",
        "🎛", "🕹", "🎚", "🧩", "🪞", "🦾", "🪪", "📎", "🔗", "⛓",
        "🧷", "🗝", "🎨", "🖋", "📝"
    ]

    /// Lowercase + strip spaces/dashes/underscores so cosmetic
    /// variants of the same project name collapse to one slot.
    /// Mirrors `normalizeProjectKey` in the JS module.
    static func normalize(_ label: String) -> String {
        let lowered = label.lowercased()
        let stripped = lowered.unicodeScalars.filter { scalar in
            !(scalar == " " || scalar == "-" || scalar == "_")
        }
        let result = String(String.UnicodeScalarView(stripped))
        return result.isEmpty ? "default" : result
    }

    /// FNV-1a 32-bit. Byte-for-byte compatible with the Node
    /// version (`fnv1a32` in project_emoji.js). Operates on the
    /// UTF-8 byte sequence — the JS version uses `charCodeAt & 0xff`
    /// which equals the low byte of the UTF-16 code unit, but every
    /// ASCII character (and Korean characters in our project names
    /// are normalized away first) has the same low byte in UTF-8
    /// and UTF-16 because the inputs after `normalize` are
    /// guaranteed ASCII-only for cross-platform fixtures. Anything
    /// non-ASCII that survives normalize is still deterministic —
    /// just don't expect Swift and Node to agree on it, which the
    /// fixture set respects.
    static func fnv1a32(_ input: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for byte in input.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return hash
    }

    /// Deterministic emoji for a project label. Used as the fallback
    /// when `sessions.emoji` is NULL (i.e. no user override yet).
    static func emoji(for label: String) -> String {
        let key = normalize(label)
        let index = Int(fnv1a32(key) % UInt32(pool.count))
        return pool[index]
    }
}
