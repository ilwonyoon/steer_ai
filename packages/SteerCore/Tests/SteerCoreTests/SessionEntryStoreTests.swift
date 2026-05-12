import XCTest
@testable import SteerCore

final class SessionEntryStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeCard(
        sessionId: String,
        cardId: String,
        updatedAtMs: Int64 = 0
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
            updatedAt: updatedAtMs
        )
    }

    // MARK: - The atomic chip-clear / card-surface transition

    func test_newCardForSession_swapsAwaitingResponseToAwaitingUserAtomically() {
        // Initial state: one entry, awaitingResponse (user replied to
        // cardId A, terminal still working).
        let entryA = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A", updatedAtMs: 1000),
            stage: .awaitingResponse,
            lastReplyText: "hi",
            lastInstructionId: "i1"
        )
        // Terminal finished → fresh card B arrives for the same session.
        let cardB = makeCard(sessionId: "S1", cardId: "B", updatedAtMs: 2000)
        let next = SessionEntryStore.onCardUpsert(
            previous: [entryA], card: cardB
        )
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].card.cardId, "B")
        XCTAssertEqual(next[0].stage, .awaitingUser)
        // Chip count is now 0; card carousel has the new card.
        XCTAssertEqual(
            SessionEntryStore.awaitingResponseEntries(in: next).count, 0
        )
        XCTAssertEqual(
            SessionEntryStore.awaitingUserEntries(in: next).count, 1
        )
    }

    // MARK: - WS re-upsert of the same cardId is a no-op for stage

    func test_sameCardId_keepsStage() {
        let entry = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A", updatedAtMs: 1000),
            stage: .awaitingResponse,
            lastReplyText: "x",
            lastInstructionId: "i1"
        )
        // Same cardId, refreshed summary (Mac re-classified).
        let refreshed = makeCard(sessionId: "S1", cardId: "A", updatedAtMs: 1100)
        let next = SessionEntryStore.onCardUpsert(
            previous: [entry], card: refreshed
        )
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].card.updatedAt, 1100)
        XCTAssertEqual(next[0].stage, .awaitingResponse)
        XCTAssertEqual(next[0].lastReplyText, "x")
    }

    // MARK: - sendReply → marks awaitingResponse

    func test_markUserReplied_transitionsStage() {
        let entry = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A"),
            stage: .awaitingUser
        )
        let next = SessionEntryStore.markUserReplied(
            previous: [entry], cardId: "A", text: "go", instructionId: "i1"
        )
        XCTAssertEqual(next[0].stage, .awaitingResponse)
        XCTAssertEqual(next[0].lastReplyText, "go")
        XCTAssertEqual(next[0].lastInstructionId, "i1")
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

    func test_cardResolved_removesEntry() {
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
        // Step 1: card lands.
        var entries: [SessionEntry] = []
        entries = SessionEntryStore.onCardUpsert(
            previous: entries,
            card: makeCard(sessionId: "S1", cardId: "A", updatedAtMs: 1000)
        )
        XCTAssertEqual(
            SessionEntryStore.awaitingUserEntries(in: entries).count, 1
        )
        XCTAssertEqual(
            SessionEntryStore.awaitingResponseEntries(in: entries).count, 0
        )

        // Step 2: user replies. Chip == 1, carousel == 0.
        entries = SessionEntryStore.markUserReplied(
            previous: entries, cardId: "A", text: "go", instructionId: "i1"
        )
        XCTAssertEqual(
            SessionEntryStore.awaitingUserEntries(in: entries).count, 0
        )
        XCTAssertEqual(
            SessionEntryStore.awaitingResponseEntries(in: entries).count, 1
        )

        // Step 3: Mac re-upserts the same card (its 2s reload tick).
        // Stage must NOT flicker.
        entries = SessionEntryStore.onCardUpsert(
            previous: entries,
            card: makeCard(sessionId: "S1", cardId: "A", updatedAtMs: 1100)
        )
        XCTAssertEqual(
            SessionEntryStore.awaitingResponseEntries(in: entries).count, 1
        )

        // Step 4: 10s later, terminal answers — new cardId B for same
        // session. Chip → 0 and carousel ← 1 in one mutation.
        entries = SessionEntryStore.onCardUpsert(
            previous: entries,
            card: makeCard(sessionId: "S1", cardId: "B", updatedAtMs: 12000)
        )
        XCTAssertEqual(
            SessionEntryStore.awaitingUserEntries(in: entries).count, 1
        )
        XCTAssertEqual(
            SessionEntryStore.awaitingResponseEntries(in: entries).count, 0
        )
        XCTAssertEqual(entries[0].card.cardId, "B")
    }
}
