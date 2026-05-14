import XCTest
@testable import SteerCore

/// PR-2 introduces `lastReplyEventSeq` / `lastTouchedSeq` on
/// `SessionEntry`. The reducer doesn't read them yet — that's PR-3
/// work. These tests pin the *invariants* the host must uphold while
/// stamping the fields, so the PR-3 rewrite has a contract to honour.
final class EventSeqTests: XCTestCase {

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

    // MARK: - SessionEntry defaults

    func test_sessionEntry_defaultsToNilSeqs() {
        let entry = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A"),
            stage: .awaitingUser
        )
        XCTAssertNil(entry.lastReplyEventSeq, "fresh entries have no reply seq")
        XCTAssertNil(entry.lastTouchedSeq, "fresh entries have no touch seq")
    }

    func test_sessionEntry_acceptsExplicitSeqs() {
        let entry = SessionEntry(
            sessionId: "S1",
            card: makeCard(sessionId: "S1", cardId: "A"),
            stage: .awaitingResponse,
            lastReplyText: "go",
            lastInstructionId: "i1",
            instructedRevision: 3,
            lastReplyEventSeq: 42,
            lastTouchedSeq: 42
        )
        XCTAssertEqual(entry.lastReplyEventSeq, 42)
        XCTAssertEqual(entry.lastTouchedSeq, 42)
    }

    // MARK: - markUserReplied stamping

    func test_markUserReplied_withoutSeq_leavesFieldNil() {
        // Backward-compat default: callers that haven't been updated
        // get nil seqs. The reducer (PR-3) is required to handle nil
        // gracefully (treat as "stamp absent, fall back to revision").
        var entries: [SessionEntry] = [
            SessionEntry(
                sessionId: "S1",
                card: makeCard(sessionId: "S1", cardId: "A", revision: 3),
                stage: .awaitingUser
            )
        ]
        entries = SessionEntryStore.markUserReplied(
            previous: entries, cardId: "A",
            text: "go", instructionId: "i1"
        )
        XCTAssertEqual(entries[0].stage, .awaitingResponse)
        XCTAssertNil(entries[0].lastReplyEventSeq)
        XCTAssertNil(entries[0].lastTouchedSeq)
    }

    func test_markUserReplied_withSeq_stampsBothFields() {
        var entries: [SessionEntry] = [
            SessionEntry(
                sessionId: "S1",
                card: makeCard(sessionId: "S1", cardId: "A", revision: 3),
                stage: .awaitingUser
            )
        ]
        entries = SessionEntryStore.markUserReplied(
            previous: entries, cardId: "A",
            text: "go", instructionId: "i1",
            eventSeq: 7
        )
        XCTAssertEqual(entries[0].lastReplyEventSeq, 7)
        XCTAssertEqual(entries[0].lastTouchedSeq, 7,
            "touch seq mirrors reply seq on initial stamp")
    }

    func test_markUserReplied_secondReply_overwritesSeq() {
        // Retry path: the same entry is reset and stamped with a new
        // seq. The reducer must never see a stale seq from a prior
        // reply.
        var entries: [SessionEntry] = [
            SessionEntry(
                sessionId: "S1",
                card: makeCard(sessionId: "S1", cardId: "A", revision: 3),
                stage: .awaitingUser
            )
        ]
        entries = SessionEntryStore.markUserReplied(
            previous: entries, cardId: "A",
            text: "go", instructionId: "i1",
            eventSeq: 10
        )
        // Failed reply path retries with a new instructionId + new seq.
        entries = SessionEntryStore.markUserReplied(
            previous: entries, cardId: "A",
            text: "go", instructionId: "i2",
            eventSeq: 25
        )
        XCTAssertEqual(entries[0].lastReplyEventSeq, 25)
        XCTAssertEqual(entries[0].lastTouchedSeq, 25)
        XCTAssertEqual(entries[0].lastInstructionId, "i2")
    }

    // MARK: - PR-1 race tests must still pass

    func test_pr1_userRepliedThenResponseUpsert_promotesWithSeqStamped() {
        // §2.C: response upsert promotes. Adding the seq stamp must
        // not break the promotion path.
        var entries = SessionEntryStore.onCardUpsert(
            previous: [],
            card: makeCard(sessionId: "S1", cardId: "A", revision: 3)
        )
        entries = SessionEntryStore.markUserReplied(
            previous: entries, cardId: "A",
            text: "go", instructionId: "i1",
            eventSeq: 42
        )
        XCTAssertEqual(entries[0].lastReplyEventSeq, 42)

        entries = SessionEntryStore.onCardUpsert(
            previous: entries,
            card: makeCard(
                sessionId: "S1", cardId: "A",
                updatedAtMs: 2000, revision: 4
            )
        )
        XCTAssertEqual(entries[0].stage, .awaitingUser)
        // PR-3 may zero or recompute the seq fields on promotion.
        // Today they survive unchanged. Test pins today's behaviour
        // so a PR-3 contract change is visible.
        XCTAssertEqual(entries[0].lastReplyEventSeq, 42,
            "promotion preserves seq until PR-3 reducer rewrites the rule")
    }
}
