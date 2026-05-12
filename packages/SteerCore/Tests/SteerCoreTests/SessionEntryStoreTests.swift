import XCTest
@testable import SteerCore

final class SessionEntryStoreTests: XCTestCase {

    // MARK: - Helpers

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
            summary: "summary",
            actionPrompt: nil,
            payload: nil,
            state: "active",
            createdAt: 0,
            updatedAt: updatedAtMs,
            responseRevision: revision
        )
    }

    // MARK: - The atomic chip-clear / card-surface transition

    func test_cardUpsertWithGreaterRevision_swapsAtomically() {
        // User replied while card was at revision=3.
        let entryA = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A", revision: 3),
            stage: .awaitingResponse,
            lastReplyText: "hi",
            lastInstructionId: "i1",
            instructedRevision: 3
        )
        // Terminal finished → Mac bumps revision to 4 and re-upserts.
        let next = SessionEntryStore.onCardUpsert(
            previous: [entryA],
            card: makeCard(sessionId: "S1", cardId: "A", revision: 4)
        )
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].card.responseRevision, 4)
        XCTAssertEqual(next[0].stage, .awaitingUser)
        XCTAssertEqual(
            SessionEntryStore.awaitingResponseEntries(in: next).count, 0
        )
    }

    // MARK: - Same revision → keep stage even on content refresh

    func test_sameRevisionReUpsert_keepsAwaitingResponse() {
        // Mac's 2s reload tick re-publishes the same response-revision
        // — classifier may have refreshed title / summary, but no new
        // terminal response yet. Chip must stay lit.
        let entry = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A", revision: 3),
            stage: .awaitingResponse,
            lastReplyText: "x",
            lastInstructionId: "i1",
            instructedRevision: 3
        )
        let refreshed = makeCard(
            sessionId: "S1", cardId: "A", updatedAtMs: 1500, revision: 3
        )
        let next = SessionEntryStore.onCardUpsert(
            previous: [entry], card: refreshed
        )
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].stage, .awaitingResponse)
        XCTAssertEqual(next[0].card.updatedAt, 1500)
    }

    // MARK: - sendReply → marks awaitingResponse

    func test_markUserReplied_transitionsStage() {
        let entry = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A", revision: 7),
            stage: .awaitingUser
        )
        let next = SessionEntryStore.markUserReplied(
            previous: [entry], cardId: "A", text: "go",
            instructionId: "i1"
        )
        XCTAssertEqual(next[0].stage, .awaitingResponse)
        XCTAssertEqual(next[0].lastReplyText, "go")
        XCTAssertEqual(next[0].lastInstructionId, "i1")
        // Stamp = card.responseRevision at the moment of reply.
        XCTAssertEqual(next[0].instructedRevision, 7)
        // Chip count == 1, carousel == 0.
        XCTAssertEqual(
            SessionEntryStore.awaitingResponseEntries(in: next).count, 1
        )
        XCTAssertEqual(
            SessionEntryStore.awaitingUserEntries(in: next).count, 0
        )
    }

    // MARK: - POST failure transitions to failed

    func test_markReplyFailed_movesAwaitingResponseToFailed() {
        let entry = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A"),
            stage: .awaitingResponse,
            lastReplyText: "go",
            lastInstructionId: "i1"
        )
        let next = SessionEntryStore.markReplyFailed(
            previous: [entry], instructionId: "i1", reason: "boom"
        )
        XCTAssertEqual(next[0].stage, .failed("boom"))
        XCTAssertEqual(
            SessionEntryStore.awaitingResponseEntries(in: next).count, 0
        )
        XCTAssertEqual(
            SessionEntryStore.failedEntries(in: next).count, 1
        )
    }

    func test_markReplyFailed_doesNotDowngradeFailed() {
        // Idempotency: a duplicate failure ack shouldn't flip back.
        let entry = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A"),
            stage: .failed("prior"),
            lastReplyText: "go",
            lastInstructionId: "i1"
        )
        let next = SessionEntryStore.markReplyFailed(
            previous: [entry], instructionId: "i1", reason: "newer"
        )
        XCTAssertEqual(next[0].stage, .failed("prior"))
    }

    // MARK: - cancelFailedReply restores awaitingUser

    func test_cancelFailedReply_returnsToAwaitingUser() {
        let entry = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A"),
            stage: .failed("net"),
            lastReplyText: "go",
            lastInstructionId: "i1"
        )
        let next = SessionEntryStore.cancelFailedReply(
            previous: [entry], instructionId: "i1"
        )
        XCTAssertEqual(next[0].stage, .awaitingUser)
        XCTAssertNil(next[0].lastReplyText)
        XCTAssertNil(next[0].lastInstructionId)
    }

    // MARK: - cardResolved drops entry

    func test_cardResolved_dropsAwaitingUser() {
        let entry = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A"),
            stage: .awaitingUser
        )
        let next = SessionEntryStore.onCardResolved(
            previous: [entry], cardId: "A"
        )
        XCTAssertEqual(next, [])
    }

    func test_cardResolved_holdsAwaitingResponseUntilUpsert() {
        // The bug we kept hitting: after user replies, Mac
        // resolves the original card before publishing the
        // response's new card. If we drop the entry on resolve,
        // the chip clears too early. Hold it until the
        // cardUpsert with the new cardId arrives.
        let entry = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A", updatedAtMs: 1000),
            stage: .awaitingResponse,
            lastReplyText: "go",
            lastInstructionId: "i1"
        )
        // resolve fires first.
        let afterResolve = SessionEntryStore.onCardResolved(
            previous: [entry], cardId: "A"
        )
        XCTAssertEqual(afterResolve.count, 1)
        XCTAssertEqual(afterResolve[0].stage, .awaitingResponse)
        // Chip count must still be 1.
        XCTAssertEqual(
            SessionEntryStore.awaitingResponseEntries(in: afterResolve).count,
            1
        )
        // Then the new cardUpsert lands.
        let cardB = makeCard(sessionId: "S1", cardId: "B", updatedAtMs: 2000)
        let afterUpsert = SessionEntryStore.onCardUpsert(
            previous: afterResolve, card: cardB
        )
        XCTAssertEqual(afterUpsert.count, 1)
        XCTAssertEqual(afterUpsert[0].card.cardId, "B")
        XCTAssertEqual(afterUpsert[0].stage, .awaitingUser)
    }

    func test_cardResolved_dropsFailedEntry() {
        // Failed reply has the card resolved — the user can't
        // retry against a non-existent card anyway, so drop it.
        let entry = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A"),
            stage: .failed("x"),
            lastReplyText: "go",
            lastInstructionId: "i1"
        )
        let next = SessionEntryStore.onCardResolved(
            previous: [entry], cardId: "A"
        )
        XCTAssertEqual(next, [])
    }

    // MARK: - Bootstrap preserves in-flight stages

    func test_applyBootstrap_preservesAwaitingResponseEvenIfMissingFromGET() {
        // User replied to S1/A. Mac resolved A right after our POST,
        // so the next GET doesn't include it — Mac hasn't published
        // the response card yet. The entry must survive so the chip
        // stays lit.
        let entry = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A", updatedAtMs: 1000),
            stage: .awaitingResponse,
            lastReplyText: "go",
            lastInstructionId: "i1"
        )
        let next = SessionEntryStore.applyBootstrap(
            previous: [entry], cards: []
        )
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].stage, .awaitingResponse)
    }

    func test_applyBootstrap_preservesFailedEvenIfMissingFromGET() {
        let entry = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A"),
            stage: .failed("x"),
            lastReplyText: "go",
            lastInstructionId: "i1"
        )
        let next = SessionEntryStore.applyBootstrap(
            previous: [entry], cards: []
        )
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].stage, .failed("x"))
    }

    func test_applyBootstrap_dropsAwaitingUserCardsMacResolved() {
        // Conversely: a card the user was looking at, that Mac
        // resolved server-side (e.g. user replied on Mac), should
        // disappear on the next bootstrap GET.
        let entry = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A"),
            stage: .awaitingUser
        )
        let next = SessionEntryStore.applyBootstrap(
            previous: [entry], cards: []
        )
        XCTAssertEqual(next, [])
    }

    func test_applyBootstrap_replacesAwaitingUserCardContent() {
        // Same session, but Mac re-classified the card. New title /
        // summary, same stage.
        let prior = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A", updatedAtMs: 1000),
            stage: .awaitingUser
        )
        let refreshed = makeCard(
            sessionId: "S1", cardId: "A", updatedAtMs: 1500
        )
        let next = SessionEntryStore.applyBootstrap(
            previous: [prior], cards: [refreshed]
        )
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].card.updatedAt, 1500)
        XCTAssertEqual(next[0].stage, .awaitingUser)
    }

    // MARK: - Multi-session independence

    func test_multipleSessions_independentStages() {
        let a = SessionEntry(
            sessionId: "A",
            card: makeCard(sessionId: "A", cardId: "ca"),
            stage: .awaitingUser
        )
        let b = SessionEntry(
            sessionId: "B",
            card: makeCard(sessionId: "B", cardId: "cb"),
            stage: .awaitingResponse,
            lastReplyText: "x",
            lastInstructionId: "i2"
        )
        let c = SessionEntry(
            sessionId: "C",
            card: makeCard(sessionId: "C", cardId: "cc"),
            stage: .failed("net"),
            lastReplyText: "y",
            lastInstructionId: "i3"
        )
        let all = [a, b, c]
        XCTAssertEqual(SessionEntryStore.awaitingUserEntries(in: all).count, 1)
        XCTAssertEqual(SessionEntryStore.awaitingResponseEntries(in: all).count, 1)
        XCTAssertEqual(SessionEntryStore.failedEntries(in: all).count, 1)
    }

    // MARK: - The exact bug we kept hitting

    func test_chipAndCard_neverDisagree_acrossReplyAndResponse() {
        // Step 1: card lands at t=1000.
        var entries: [SessionEntry] = []
        entries = SessionEntryStore.onCardUpsert(
            previous: entries,
            card: makeCard(
                sessionId: "S1", cardId: "A",
                updatedAtMs: 1000, revision: 1
            )
        )
        XCTAssertEqual(
            SessionEntryStore.awaitingUserEntries(in: entries).count, 1
        )

        // Step 2: user replies. Stamp = current responseRevision=1.
        entries = SessionEntryStore.markUserReplied(
            previous: entries, cardId: "A", text: "go",
            instructionId: "i1"
        )
        XCTAssertEqual(entries[0].instructedRevision, 1)
        XCTAssertEqual(
            SessionEntryStore.awaitingResponseEntries(in: entries).count, 1
        )

        // Step 3: Mac's 2s reload tick re-upserts. Revision is still 1
        // (no new response yet). Stage must NOT flicker.
        entries = SessionEntryStore.onCardUpsert(
            previous: entries,
            card: makeCard(
                sessionId: "S1", cardId: "A",
                updatedAtMs: 2200, revision: 1
            )
        )
        XCTAssertEqual(
            SessionEntryStore.awaitingResponseEntries(in: entries).count, 1
        )

        // Step 4: Mac resolves the card before publishing the response.
        // Entry must survive (otherwise chip drops too early).
        entries = SessionEntryStore.onCardResolved(
            previous: entries, cardId: "A"
        )
        XCTAssertEqual(
            SessionEntryStore.awaitingResponseEntries(in: entries).count, 1
        )

        // Step 5: 10s later, terminal answers. Mac bumps revision to
        // 2 and re-upserts. Atomic transition: chip → 0, carousel ← 1.
        entries = SessionEntryStore.onCardUpsert(
            previous: entries,
            card: makeCard(
                sessionId: "S1", cardId: "A",
                updatedAtMs: 12000, revision: 2
            )
        )
        XCTAssertEqual(
            SessionEntryStore.awaitingUserEntries(in: entries).count, 1
        )
        XCTAssertEqual(
            SessionEntryStore.awaitingResponseEntries(in: entries).count, 0
        )
        XCTAssertEqual(entries[0].card.responseRevision, 2)
    }
}
