import Foundation

/// Single source of truth for "which session is in which stage right now."
///
/// Before this lived as separate `cards` + `pendingReplies` arrays on the
/// iPhone, which had to be kept in sync from two network channels (cards
/// over WebSocket, replies over HTTP) plus two local mutations (sendReply,
/// retry/cancel). Every race we hit — chip flickering, chip leaving before
/// the new card landed, "1 running" stale after a response arrived —
/// traced back to those two arrays disagreeing about the same underlying
/// invariant: "is this session waiting on the user, or waiting on the
/// terminal?"
///
/// This file replaces that with one array of `SessionEntry`, each tagged
/// with a `Stage`. The chip count, the card carousel, and the sheet's
/// running list all derive from this same array.

public enum SessionStage: Equatable {
    /// Card is in the user's inbox waiting for them to reply or dismiss.
    case awaitingUser
    /// User replied; terminal is working on it. The chip counts these.
    case awaitingResponse
    /// Reply POST failed. User must retry or cancel.
    case failed(String)
}

public struct SessionEntry: Identifiable, Equatable {
    public var id: String { card.cardId }
    public let sessionId: String
    public var card: CardPayload
    public var stage: SessionStage
    /// Last reply text the user sent, kept around so .failed entries
    /// can retry without re-typing. nil for entries that never left
    /// `.awaitingUser`.
    public var lastReplyText: String?
    /// instruction id of the in-flight or failed POST. Lets retry
    /// scope deduplicate against the existing record. nil until
    /// sendReply runs.
    public var lastInstructionId: String?
    /// The card's `responseRevision` at the moment the user replied.
    /// Mac increments `responseRevision` on a session whenever it
    /// finishes producing a fresh response (i.e. the
    /// `instructedSessions` decay fires). Comparing the card's
    /// incoming revision against this stamp is the unambiguous
    /// "terminal answered" signal — no timestamp drift, no content
    /// hashing, no cardId churn. nil while in `.awaitingUser`.
    public var instructedRevision: Int?

    public init(
        sessionId: String,
        card: CardPayload,
        stage: SessionStage,
        lastReplyText: String? = nil,
        lastInstructionId: String? = nil,
        instructedRevision: Int? = nil
    ) {
        self.sessionId = sessionId
        self.card = card
        self.stage = stage
        self.lastReplyText = lastReplyText
        self.lastInstructionId = lastInstructionId
        self.instructedRevision = instructedRevision
    }
}

public enum SessionEntryStore {
    // MARK: - Network event handlers
    //
    // Each function is pure: takes the previous array, returns a new one.
    // The view layer holds the array and re-renders on change.

    /// Initial GET /v1/sync/cards landed. Replace any cards the user
    /// hasn't already started replying to. Preserves entries currently
    /// in `.awaitingResponse` or `.failed` (their card may not show up
    /// in the GET because Mac resolved it after our optimistic transit).
    public static func applyBootstrap(
        previous: [SessionEntry],
        cards: [CardPayload]
    ) -> [SessionEntry] {
        // Index previous by sessionId so we can decide per-card whether
        // to overwrite or skip.
        var bySession: [String: SessionEntry] = [:]
        for entry in previous { bySession[entry.sessionId] = entry }
        for card in cards {
            if let existing = bySession[card.sessionId] {
                // Preserve in-flight or failed state. Even if the card
                // id differs, the user's reply belongs to that session;
                // we don't want a stale GET resurrecting the old card.
                switch existing.stage {
                case .awaitingResponse, .failed:
                    continue
                case .awaitingUser:
                    // Refresh card content (title, summary may have
                    // changed) but keep the stage.
                    bySession[card.sessionId] = SessionEntry(
                        sessionId: card.sessionId,
                        card: card,
                        stage: .awaitingUser
                    )
                }
            } else {
                bySession[card.sessionId] = SessionEntry(
                    sessionId: card.sessionId,
                    card: card,
                    stage: .awaitingUser
                )
            }
        }
        // Drop entries whose card no longer appears in the GET AND
        // are currently `.awaitingUser` — Mac resolved them server-
        // side. Entries in awaitingResponse / failed survive (the
        // user's reply still owns them; a future WS upsert with a
        // new cardId will replace them).
        let observedSessions = Set(cards.map(\.sessionId))
        var next: [SessionEntry] = []
        for entry in bySession.values {
            if !observedSessions.contains(entry.sessionId),
               case .awaitingUser = entry.stage {
                continue
            }
            next.append(entry)
        }
        return next.sorted { $0.card.updatedAt < $1.card.updatedAt }
    }

    /// WebSocket pushed an upsert for a card. The Mac wrapper reuses
    /// the same cardId across responses for a single session (one
    /// `action_cards` row per session, re-upserted with refreshed
    /// content + new `updatedAt`). So we can't use "new cardId" as
    /// the response signal — we use timestamp instead.
    ///
    /// Per-session decision:
    ///
    ///   - No entry yet → insert as `.awaitingUser`.
    ///   - Entry in `.awaitingUser` / `.failed` → refresh content,
    ///     keep stage.
    ///   - Entry in `.awaitingResponse`:
    ///       * `card.updatedAt > instructedAtMs` → terminal produced
    ///         a fresh response after the user's reply. Atomic swap:
    ///         stage → `.awaitingUser`, content refreshed.
    ///       * otherwise → it's a re-upsert of the *pre-reply* card
    ///         content (Mac's 2s reload tick). Keep stage; don't
    ///         downgrade.
    public static func onCardUpsert(
        previous: [SessionEntry],
        card: CardPayload
    ) -> [SessionEntry] {
        var next = previous
        if let idx = next.firstIndex(where: { $0.sessionId == card.sessionId }) {
            let existing = next[idx]
            switch existing.stage {
            case .awaitingUser, .failed:
                next[idx] = SessionEntry(
                    sessionId: existing.sessionId,
                    card: card,
                    stage: existing.stage,
                    lastReplyText: existing.lastReplyText,
                    lastInstructionId: existing.lastInstructionId,
                    instructedRevision: existing.instructedRevision
                )
            case .awaitingResponse:
                // Stamp absent means the entry never went through
                // markUserReplied (legacy or direct construction).
                // Treat any upsert as the response so the chip
                // doesn't stick forever in tests + bad migrations.
                let isResponse: Bool
                if let stamp = existing.instructedRevision {
                    let incoming = card.responseRevision ?? 0
                    isResponse = incoming > stamp
                } else {
                    isResponse = true
                }
                if isResponse {
                    next[idx] = SessionEntry(
                        sessionId: existing.sessionId,
                        card: card,
                        stage: .awaitingUser
                    )
                } else {
                    // Pre-response re-upsert from Mac's reload tick
                    // — same revision, refreshed content. Keep stage
                    // so the chip doesn't flicker.
                    next[idx] = SessionEntry(
                        sessionId: existing.sessionId,
                        card: card,
                        stage: existing.stage,
                        lastReplyText: existing.lastReplyText,
                        lastInstructionId: existing.lastInstructionId,
                        instructedRevision: existing.instructedRevision
                    )
                }
            }
        } else {
            next.append(SessionEntry(
                sessionId: card.sessionId,
                card: card,
                stage: .awaitingUser
            ))
        }
        next.sort { $0.card.updatedAt < $1.card.updatedAt }
        return next
    }

    /// WebSocket pushed `card.resolved` for `cardId`. Three cases:
    ///
    ///   - matching entry is `.awaitingUser` or `.failed`: drop it.
    ///     The card the user was looking at (or had failed to reply
    ///     to) is gone server-side; nothing to keep.
    ///
    ///   - matching entry is `.awaitingResponse`: KEEP it. This is
    ///     the load-bearing case. After the user sends a reply, Mac
    ///     resolves the original card on its end — that resolve
    ///     event races the next cardUpsert that carries the
    ///     terminal's response. If we drop the entry here, the
    ///     chip clears before the new card arrives, and the user
    ///     sees "chip → 0, card → ?, card lands seconds later."
    ///     Holding the entry until the next cardUpsert (which
    ///     replaces the card atomically) keeps the chip lit through
    ///     the gap.
    public static func onCardResolved(
        previous: [SessionEntry],
        cardId: String
    ) -> [SessionEntry] {
        previous.compactMap { entry in
            guard entry.card.cardId == cardId else { return entry }
            switch entry.stage {
            case .awaitingResponse: return entry  // hold for upsert
            case .awaitingUser, .failed: return nil
            }
        }
    }

    // MARK: - User-driven transitions

    /// User tapped Send on `cardId`. Move to `.awaitingResponse`,
    /// remember the text + instruction id for retry / failure.
    /// If the card isn't in the store, no-op (defensive — UI shouldn't
    /// allow this).
    public static func markUserReplied(
        previous: [SessionEntry],
        cardId: String,
        text: String,
        instructionId: String
    ) -> [SessionEntry] {
        var next = previous
        if let idx = next.firstIndex(where: { $0.card.cardId == cardId }) {
            next[idx].stage = .awaitingResponse
            next[idx].lastReplyText = text
            next[idx].lastInstructionId = instructionId
            // Stamp the current `responseRevision`. The next
            // cardUpsert that ships a strictly-greater revision is
            // "terminal produced its response" — no clock skew,
            // no content hashing.
            next[idx].instructedRevision = next[idx].card.responseRevision ?? 0
        }
        return next
    }

    /// Reply POST failed. Move from `.awaitingResponse` to `.failed`.
    /// Anything else stays put.
    public static func markReplyFailed(
        previous: [SessionEntry],
        instructionId: String,
        reason: String
    ) -> [SessionEntry] {
        var next = previous
        if let idx = next.firstIndex(where: {
            $0.lastInstructionId == instructionId
        }) {
            if case .awaitingResponse = next[idx].stage {
                next[idx].stage = .failed(reason)
            }
        }
        return next
    }

    /// User dismissed a failed entry without retrying. Go back to
    /// `.awaitingUser` so they can edit and try again, or just leave
    /// the card sitting in their inbox.
    public static func cancelFailedReply(
        previous: [SessionEntry],
        instructionId: String
    ) -> [SessionEntry] {
        var next = previous
        if let idx = next.firstIndex(where: {
            $0.lastInstructionId == instructionId
        }) {
            if case .failed = next[idx].stage {
                next[idx].stage = .awaitingUser
                next[idx].lastReplyText = nil
                next[idx].lastInstructionId = nil
                next[idx].instructedRevision = nil
            }
        }
        return next
    }

    // MARK: - Derived views

    /// Entries the user must respond to. Drives the card carousel.
    public static func awaitingUserEntries(
        in entries: [SessionEntry]
    ) -> [SessionEntry] {
        entries.filter {
            if case .awaitingUser = $0.stage { return true }
            return false
        }
    }

    /// Entries currently in the "I replied, terminal is working"
    /// stage. Drives the chip's `runningCount`.
    public static func awaitingResponseEntries(
        in entries: [SessionEntry]
    ) -> [SessionEntry] {
        entries.filter {
            if case .awaitingResponse = $0.stage { return true }
            return false
        }
    }

    /// Failed reply entries. Drives the chip's `failedCount` and the
    /// sheet's "Failed replies" section (which exposes retry / cancel).
    public static func failedEntries(
        in entries: [SessionEntry]
    ) -> [SessionEntry] {
        entries.filter {
            if case .failed = $0.stage { return true }
            return false
        }
    }
}
