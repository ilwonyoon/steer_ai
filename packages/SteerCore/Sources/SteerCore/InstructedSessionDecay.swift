import Foundation

/// Tracks which sessions the user has replied to and the terminal
/// is still working on. This is the source of truth for the "N
/// running" chip on both Mac UI and iPhone.
///
/// Membership rules:
///
///   - Enters: `markInstructed(sessionId, atMs:)` called immediately
///     after a successful inject (Mac card reply OR iPhone drain).
///     Stamps the current wall-clock time so we know when the user's
///     reply was sent.
///
///   - Stays: as long as the session is still live AND no new card
///     has appeared *since* the reply was sent. A card whose
///     `updatedAt > instructedAtMs` means the terminal finished the
///     work, produced an output the user now has to handle, and the
///     chip should fall off in favor of the card.
///
///   - Leaves:
///     1. Session no longer in the live set (ended / disconnected /
///        90 s liveness cutoff).
///     2. A card for that session has `updatedAt > instructedAtMs`
///        — terminal produced a new response after the reply.
///
/// We deliberately do NOT decay on `run_state` flipping back to
/// "waiting" alone: short replies finish before the next reload
/// tick and the chip would flicker in for a single frame, so the
/// user would never see it. Holding membership through the full
/// instruction-processing window matches the user's mental model:
/// "I replied, the terminal is working, the chip should still show
/// it." See `decay()` for the exact predicates.

public struct InstructedAt: Equatable {
    /// Wall-clock milliseconds when the reply was injected. Compared
    /// against card `updatedAt` to detect "new response since reply".
    public let atMs: Int64

    public init(atMs: Int64) {
        self.atMs = atMs
    }
}

public struct CardUpdateSnapshot: Equatable {
    public let sessionId: String
    public let updatedAtMs: Int64

    public init(sessionId: String, updatedAtMs: Int64) {
        self.sessionId = sessionId
        self.updatedAtMs = updatedAtMs
    }
}

public enum InstructedSessionDecay {
    /// Compute the next instructed-session map given the previous
    /// state and the current snapshot of live sessions + cards.
    ///
    /// - Parameters:
    ///   - previous: the instructed-session map at the start of this
    ///     reload tick (`[sessionId: InstructedAt]`).
    ///   - liveSessionIds: every session id currently in the live
    ///     set (running / waiting / blocked). NOT card-filtered —
    ///     pass the raw set from `loadLiveSessions(excluding: [])`.
    ///   - cards: current cards with `updatedAt`. The function
    ///     decays any session whose card's `updatedAtMs >
    ///     instructedAtMs` (new response arrived after the reply).
    /// - Returns: the new instructed-session map. Callers persist
    ///   this and read its `.keys` as the chip publish source.
    public static func decay(
        previous: [String: InstructedAt],
        liveSessionIds: Set<String>,
        cards: [CardUpdateSnapshot]
    ) -> [String: InstructedAt] {
        let latestCardUpdate: [String: Int64] = cards.reduce(into: [:]) { acc, snap in
            // Defensive: same session may appear multiple times in
            // cards (it shouldn't post-classifier, but the agent's
            // upsert race is real). Keep the newest stamp.
            if let prev = acc[snap.sessionId], prev >= snap.updatedAtMs { return }
            acc[snap.sessionId] = snap.updatedAtMs
        }

        var next: [String: InstructedAt] = [:]
        for (sessionId, stamp) in previous {
            // Rule 1: session must still be live.
            guard liveSessionIds.contains(sessionId) else { continue }
            // Rule 2: any card update strictly newer than the reply
            // means the terminal already produced its response;
            // the card surface takes over.
            if let cardUpdate = latestCardUpdate[sessionId],
               cardUpdate > stamp.atMs {
                continue
            }
            next[sessionId] = stamp
        }
        return next
    }
}
