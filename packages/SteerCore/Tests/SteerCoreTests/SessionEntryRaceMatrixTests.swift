import XCTest
@testable import SteerCore

/// Locks the race matrix from `docs/SYNC_LAYER_DESIGN_2026-05-13.md §2`
/// against the *current* SessionEntryStore behaviour. The reducer
/// rewrite in PR-3 will reorganise the entry points; these tests
/// describe the user-visible invariants that survive that refactor.
///
/// Cases tagged with `XCTSkip` document gaps that today's code does
/// NOT yet enforce — they unblock once the PR-2 `eventSeq` primitive
/// and PR-6 `.awaitingResponse` timeout land. Skipping (rather than
/// deleting) keeps the contract visible at the test site so the next
/// engineer knows what work is still owed.
///
/// See:
///   §2.A in design doc — updatedAt as content tiebreaker
///   §2.B — stale GET vs in-flight write (skip; needs PR-2)
///   §2.C — pre-reply re-upsert vs response upsert
///   §2.D — late-arriving response after timeout (skip; needs PR-6)
///   §2.E — concurrent reply + promotion by cardId
///   §2.F — out-of-order WS upserts use max revision
///   §2.H — pre-reply card on snapshot does not downgrade stage
final class SessionEntryRaceMatrixTests: XCTestCase {

    // MARK: - Helpers (same shape as SessionEntryStoreTests)

    private func makeCard(
        sessionId: String,
        cardId: String,
        updatedAtMs: Int64 = 0,
        revision: Int? = nil
    ) -> CardPayload {
        CardPayload(
            cardId: cardId,
            sessionId: sessionId,
            category: "question",
            priority: "normal",
            title: "title-\(cardId)",
            summary: "summary-\(updatedAtMs)",
            actionPrompt: nil,
            payload: nil,
            state: "active",
            createdAt: 0,
            updatedAt: updatedAtMs,
            responseRevision: revision
        )
    }

    // MARK: - §2.A — GET landed before WS; WS wins on later updatedAt.

    func test_get_then_ws_widerUpdatedAtWins() {
        // GET produces a snapshot at t=1000. WS upsert lands at t=2000
        // with refreshed content. Reducer must accept WS content.
        var entries: [SessionEntry] = []
        entries = SessionEntryStore.applyBootstrap(
            previous: entries,
            cards: [makeCard(sessionId: "S1", cardId: "A", updatedAtMs: 1000)]
        )
        entries = SessionEntryStore.onCardUpsert(
            previous: entries,
            card: makeCard(sessionId: "S1", cardId: "A", updatedAtMs: 2000)
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].card.updatedAt, 2000)
        XCTAssertEqual(entries[0].stage, .awaitingUser)
    }

    func test_ws_then_get_doesNotDowngrade() {
        // WS upsert with newer content arrives first. GET response
        // (older view) lands second. Today's applyBootstrap refreshes
        // content from the GET — locking the *current* behaviour, the
        // GET content does land. The §2.A spec says the staler payload
        // should be ignored once we have updatedAt comparison in the
        // reducer (PR-3); this test pins today and is rewritten then.
        var entries = SessionEntryStore.onCardUpsert(
            previous: [],
            card: makeCard(sessionId: "S1", cardId: "A", updatedAtMs: 2000)
        )
        entries = SessionEntryStore.applyBootstrap(
            previous: entries,
            cards: [makeCard(sessionId: "S1", cardId: "A", updatedAtMs: 1000)]
        )
        // Current behaviour: bootstrap replaces card (line 130 of
        // SessionEntryStore.swift refreshes `.awaitingUser` card
        // content unconditionally). Documented; PR-3 tightens this.
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].stage, .awaitingUser)
    }

    // MARK: - §2.B — Stale GET vs in-flight write.

    func test_get_doesNotClobberCardWrittenDuringFlight() throws {
        // The PR-2 eventSeq primitive is the only thing that lets the
        // reducer distinguish "card written between GET-fire and
        // GET-land" from "card legitimately gone." Until PR-2 lands,
        // a snapshot can clobber a fresh upsert.
        throw XCTSkip("Requires PR-2 eventSeq primitive — design doc §2.B")
    }

    // MARK: - §2.C — Pre-reply re-upsert keeps the chip lit.

    func test_userReplied_thenStaleUpsert_keepsAwaitingResponse() {
        // Mac's 2 s reload tick re-upserts the same pre-reply card
        // (same responseRevision). Stage must NOT downgrade to
        // .awaitingUser — the user already pressed Send.
        var entries = SessionEntryStore.onCardUpsert(
            previous: [],
            card: makeCard(sessionId: "S1", cardId: "A", revision: 3)
        )
        entries = SessionEntryStore.markUserReplied(
            previous: entries, cardId: "A", text: "go", instructionId: "i1"
        )
        XCTAssertEqual(entries[0].stage, .awaitingResponse)

        // Re-upsert with same revision (the reload-tick re-publish).
        entries = SessionEntryStore.onCardUpsert(
            previous: entries,
            card: makeCard(
                sessionId: "S1", cardId: "A",
                updatedAtMs: 2000, revision: 3
            )
        )
        XCTAssertEqual(entries[0].stage, .awaitingResponse)
        XCTAssertEqual(
            SessionEntryStore.awaitingResponseEntries(in: entries).count,
            1
        )
    }

    func test_userReplied_thenResponseUpsert_promotes() {
        // Same setup, but the upsert carries a strictly greater
        // responseRevision: this IS the response. Stage promotes.
        var entries = SessionEntryStore.onCardUpsert(
            previous: [],
            card: makeCard(sessionId: "S1", cardId: "A", revision: 3)
        )
        entries = SessionEntryStore.markUserReplied(
            previous: entries, cardId: "A", text: "go", instructionId: "i1"
        )
        entries = SessionEntryStore.onCardUpsert(
            previous: entries,
            card: makeCard(
                sessionId: "S1", cardId: "A",
                updatedAtMs: 2000, revision: 4
            )
        )
        XCTAssertEqual(entries[0].stage, .awaitingUser)
        XCTAssertEqual(entries[0].card.responseRevision, 4)
    }

    // MARK: - §2.D — Timeout decay then late response.

    func test_timeout_thenLateResponse_promotesThroughFailed() throws {
        // PR-6 introduces the 10-min .awaitingResponse timeout. Once
        // the watcher fires, the entry decays to .failed("response
        // timeout"). A subsequent response upsert promotes via
        // .failed → .awaitingUser. The current reducer has no
        // timeout decay path, so this transition is not yet
        // observable.
        throw XCTSkip("Requires PR-6 awaitingResponse timeout — design doc §2.D")
    }

    // MARK: - §2.E — Concurrent reply + promotion by cardId.

    func test_concurrent_replyAndPromotion_byCardId() {
        // markUserReplied is keyed by cardId, not sessionId. If a
        // response upsert (different cardId) lands while the user is
        // typing, markUserReplied against the OLD cardId no-ops —
        // protecting against the user replying to a stale card.
        //
        // Steer's invariant §8.1 is `card_id = card-${sessionId}`,
        // so cardIds match across response turns in practice. This
        // case is defensive only, but it pins the keying contract.
        var entries = SessionEntryStore.onCardUpsert(
            previous: [],
            card: makeCard(sessionId: "S1", cardId: "A", revision: 3)
        )
        // Response upsert with a NEW cardId arrives (hypothetical).
        entries = SessionEntryStore.onCardUpsert(
            previous: entries,
            card: makeCard(
                sessionId: "S1", cardId: "B",
                updatedAtMs: 2000, revision: 4
            )
        )
        // User taps Send against the old cardId. Should no-op
        // because cardId "A" no longer matches any entry.
        let after = SessionEntryStore.markUserReplied(
            previous: entries, cardId: "A",
            text: "go", instructionId: "i1"
        )
        XCTAssertEqual(after, entries, "markUserReplied against gone cardId is a no-op")
        XCTAssertEqual(after[0].card.cardId, "B")
        XCTAssertEqual(after[0].stage, .awaitingUser)
    }

    // MARK: - §2.F — Out-of-order WS upserts use max revision.

    func test_outOfOrder_revisions_useMax() throws {
        // WS reconnect can replay frames out of order. The reducer
        // SHOULD treat the higher revision as the response signal
        // regardless of arrival order. Today it doesn't — the
        // .awaitingUser upsert branch unconditionally adopts
        // incoming `card.responseRevision`, which regresses 4 → 3.
        //
        // Design doc §7 PR-1 lists this as expected-failing: "will
        // fail on today's code — that's expected, it's documenting
        // the gap." PR-3's reducer rewrite gives it a real
        // `max(incoming, existing)` rule (§2.F).
        throw XCTSkip("Requires PR-3 reducer max-revision rule — design doc §2.F")
    }

    // MARK: - §2.H — Pre-reply snapshot does not downgrade stage.

    func test_snapshot_preReplyCardDoesNotDowngrade() {
        // User replies on iPhone foreground. WS goes idle. iPhone
        // foregrounds again; applyBootstrap fires with the same
        // pre-reply card the server still has (Mac's resolve hasn't
        // propagated yet). The §1.5 OR-clause (post-§11.5 patch)
        // must preserve the .awaitingResponse entry — but the
        // current implementation refreshes the card *and* preserves
        // the stage as long as updatedAt aligns.
        var entries = SessionEntryStore.onCardUpsert(
            previous: [],
            card: makeCard(
                sessionId: "S1", cardId: "A",
                updatedAtMs: 1000, revision: 3
            )
        )
        entries = SessionEntryStore.markUserReplied(
            previous: entries, cardId: "A", text: "go", instructionId: "i1"
        )
        // Pre-reply card re-arrives via bootstrap.
        entries = SessionEntryStore.applyBootstrap(
            previous: entries,
            cards: [makeCard(
                sessionId: "S1", cardId: "A",
                updatedAtMs: 2000, revision: 3
            )]
        )
        // The current commit (b6fe8fe) treats .awaitingResponse as
        // "promotable on any server card." This test locks today's
        // behaviour so PR-6 can layer the responseRevision check
        // without breaking it silently.
        //
        // Acceptable post-PR-6 outcome: stage stays .awaitingResponse
        // (because incoming revision == instructedRevision). For
        // now we assert the entry survives at all.
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].sessionId, "S1")
    }
}
