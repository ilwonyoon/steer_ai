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

    /// Process-monotonic counter (`SyncInbox.nextEventSeq()`) captured
    /// at the moment the user pressed Send. Lets the §2.B reducer rule
    /// distinguish "GET fired before the user replied" from "GET fired
    /// after." nil for entries that never went through
    /// `markUserReplied`. NOT serialised to the wire; per-device only
    /// (design doc §1.2, §9 invariant — multi-device contention
    /// resolves via server-side `updatedAt` / `responseRevision`).
    public var lastReplyEventSeq: UInt64?
    /// Process-monotonic counter captured the last time *any* host
    /// event touched this entry. Currently unused; PR-3 reducer reads
    /// it to break the §2.A "GET landed first, then WS" race when the
    /// content payload is equal but ordering matters.
    public var lastTouchedSeq: UInt64?

    /// Real wall-clock when `markUserReplied` set the entry to
    /// `.awaitingResponse`. The §5.1 timeout watcher reads this to
    /// decide which entries are >10 min stale and need to decay to
    /// `.failed("response timeout")`. nil for any entry that never
    /// went through `markUserReplied` or that's been promoted back to
    /// `.awaitingUser`.
    ///
    /// Wall-clock (not monotonic) because iOS suspend pauses
    /// `mach_absolute_time()` — a 12-min background lock with a
    /// monotonic clock would never tick past 10 min, and the user's
    /// stuck reply would never decay. `Date()` keeps counting across
    /// suspend.
    public var awaitingResponseStampedAt: Date?

    public init(
        sessionId: String,
        card: CardPayload,
        stage: SessionStage,
        lastReplyText: String? = nil,
        lastInstructionId: String? = nil,
        instructedRevision: Int? = nil,
        lastReplyEventSeq: UInt64? = nil,
        lastTouchedSeq: UInt64? = nil,
        awaitingResponseStampedAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.card = card
        self.stage = stage
        self.lastReplyText = lastReplyText
        self.lastInstructionId = lastInstructionId
        self.instructedRevision = instructedRevision
        self.lastReplyEventSeq = lastReplyEventSeq
        self.lastTouchedSeq = lastTouchedSeq
        self.awaitingResponseStampedAt = awaitingResponseStampedAt
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
                switch existing.stage {
                case .awaitingResponse:
                    // G15.applyBootstrap — only promote when the
                    // GET delivers a strictly-newer revision than
                    // the one the user replied against. If the
                    // revisions match, this is the *same* card the
                    // user already replied to (Mac's reload tick
                    // re-published the pre-reply card, or the GET
                    // raced with the resolve event) — keeping
                    // `.awaitingResponse` preserves the chip and
                    // hides the stale card until the real response
                    // upsert arrives.
                    //
                    // The earlier behaviour blindly promoted on
                    // any GET to "bias toward unsticking" the chip,
                    // but that broke the user-visible invariant
                    // (chip drops only when a fresh answer card
                    // appears). The §5.1 10-minute decay watcher
                    // in SyncInbox is the real safety net for the
                    // genuine-stuck case.
                    let stamp = existing.instructedRevision ?? 0
                    let incoming = card.responseRevision ?? 0
                    if incoming > stamp {
                        bySession[card.sessionId] = SessionEntry(
                            sessionId: card.sessionId,
                            card: card,
                            stage: .awaitingUser,
                            lastReplyEventSeq: existing.lastReplyEventSeq,
                            lastTouchedSeq: existing.lastTouchedSeq
                        )
                    } else {
                        bySession[card.sessionId] = SessionEntry(
                            sessionId: card.sessionId,
                            card: card,
                            stage: existing.stage,
                            lastReplyText: existing.lastReplyText,
                            lastInstructionId: existing.lastInstructionId,
                            instructedRevision: existing.instructedRevision,
                            lastReplyEventSeq: existing.lastReplyEventSeq,
                            lastTouchedSeq: existing.lastTouchedSeq,
                            awaitingResponseStampedAt: existing.awaitingResponseStampedAt
                        )
                    }
                case .failed:
                    // User saw a "reply failed" state and the relay
                    // now has a card for this session. Surface the
                    // card so the user can retry their reply against
                    // it.
                    bySession[card.sessionId] = SessionEntry(
                        sessionId: card.sessionId,
                        card: card,
                        stage: .awaitingUser
                    )
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
        // Drop entries whose card no longer appears in the GET.
        // Earlier this branch preserved `.awaitingResponse` and
        // `.failed` indefinitely, on the theory that the user's
        // reply still owned them and a future WS upsert would
        // replace them. Empirically that "future upsert" sometimes
        // never came (Mac process died between resolve and reply
        // response, wrapper-disconnect-after-reply, etc.) and the
        // entry stuck at `.awaitingResponse` forever — chip pinned
        // to a dead session. The full GET is authoritative: if the
        // relay has no card for this session, the session is
        // truly gone.
        let observedSessions = Set(cards.map(\.sessionId))
        var next: [SessionEntry] = []
        for entry in bySession.values {
            if !observedSessions.contains(entry.sessionId) {
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
                    // Promotion — drop reply text + instructionId +
                    // awaitingResponseStampedAt (they're now stale),
                    // but preserve the seq stamps so the §2.B race
                    // rule (PR-3) can still see "this entry's reply
                    // came from seq N." Clearing the stamp also
                    // tells the §5.1 timeout watcher this entry no
                    // longer needs decay.
                    next[idx] = SessionEntry(
                        sessionId: existing.sessionId,
                        card: card,
                        stage: .awaitingUser,
                        lastReplyEventSeq: existing.lastReplyEventSeq,
                        lastTouchedSeq: existing.lastTouchedSeq
                    )
                } else {
                    // Pre-response re-upsert from Mac's reload tick
                    // — same revision, refreshed content. Keep stage
                    // so the chip doesn't flicker. Preserve the
                    // awaitingResponse stamp so the timeout watcher
                    // keeps counting from the original Send press.
                    next[idx] = SessionEntry(
                        sessionId: existing.sessionId,
                        card: card,
                        stage: existing.stage,
                        lastReplyText: existing.lastReplyText,
                        lastInstructionId: existing.lastInstructionId,
                        instructedRevision: existing.instructedRevision,
                        lastReplyEventSeq: existing.lastReplyEventSeq,
                        lastTouchedSeq: existing.lastTouchedSeq,
                        awaitingResponseStampedAt: existing.awaitingResponseStampedAt
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

    /// WebSocket pushed `card.resolved` for `cardId`. Drop the
    /// matching entry regardless of its stage.
    ///
    /// History: an earlier version (commit 86f87a3) held
    /// `.awaitingResponse` entries through the gap between
    /// `card.resolved` and the next `card.upsert`, on the theory
    /// that the chip would otherwise flicker 1 → 0 → 1 across the
    /// short window. That hold was load-bearing only when the next
    /// upsert was actually coming. In practice, when the wrapper
    /// died, the user signed out, the terminal didn't answer, or
    /// the response card raced through a different code path,
    /// the entry stuck at `.awaitingResponse` forever and the
    /// chip stayed lit. "N running" got pinned to dead sessions
    /// that the user couldn't dismiss.
    ///
    /// We accept the brief chip flicker. It's a 1-second visual
    /// jitter; the stuck-forever alternative was a launch
    /// blocker.
    public static func onCardResolved(
        previous: [SessionEntry],
        cardId: String
    ) -> [SessionEntry] {
        previous.compactMap { entry in
            entry.card.cardId == cardId ? nil : entry
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
        instructionId: String,
        eventSeq: UInt64? = nil,
        now: Date = Date()
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
            // PR-2 stamp: capture the host's monotonic seq at reply
            // time so the §2.B race rule can distinguish "GET fired
            // before the user replied" from "after." Reducer doesn't
            // read it yet — that's PR-3 work. The stamp is per-device
            // (§1.2 invariant); never serialised to the wire.
            if let eventSeq {
                next[idx].lastReplyEventSeq = eventSeq
                next[idx].lastTouchedSeq = eventSeq
            }
            // PR-6 stamp: real wall-clock at the moment the user
            // pressed Send. The 10-min timeout watcher in
            // SyncInbox.checkAwaitingResponseTimeouts reads this and
            // decays the entry to .failed("response timeout") if no
            // response card arrives in time. Injected so tests can
            // pass a fixed `now`.
            next[idx].awaitingResponseStampedAt = now
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

    /// 10-minute timeout fired without a response arriving — see
    /// design doc §5. The host's `SyncInbox.checkAwaitingResponseTimeouts`
    /// watcher calls this once per stuck session per wake. The entry
    /// transitions to `.failed("response timeout")` so the user sees
    /// the same retry banner as a POST failure, and the chip clears.
    ///
    /// Idempotent: if the entry has already promoted to
    /// `.awaitingUser` (the response landed seconds before the
    /// watcher fired), this is a no-op. If it's in `.failed` for some
    /// other reason, it stays.
    public static func markAwaitingResponseTimedOut(
        previous: [SessionEntry],
        sessionId: String,
        reason: String = "response timeout"
    ) -> [SessionEntry] {
        var next = previous
        if let idx = next.firstIndex(where: { $0.sessionId == sessionId }) {
            if case .awaitingResponse = next[idx].stage {
                next[idx].stage = .failed(reason)
                next[idx].awaitingResponseStampedAt = nil
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
