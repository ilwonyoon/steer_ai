import XCTest
@testable import SteerCore

/// G15.applyBootstrap — chip-card atomicity under GET refresh.
///
/// Invariant from the user's verbal spec:
///   "Card disappears → 1 running → card reappears → 1 running gone"
///
/// Phrased operationally: an `.awaitingResponse` entry must be
/// promoted to `.awaitingUser` ONLY when a strictly-newer response
/// revision lands. If a GET (bootstrap / periodic reload) delivers
/// the *same* revision the user replied against, the entry stays
/// `.awaitingResponse`, the chip stays on, and the carousel stays
/// empty until the real response upsert arrives.
///
/// The old implementation promoted on every GET as a defensive
/// "unsticking" measure; the §5.1 10-minute decay watcher now
/// owns the genuine-stuck case, so the bootstrap path can be
/// strict.
final class ApplyBootstrapRevisionTests: XCTestCase {

    private func card(
        cardId: String,
        sessionId: String,
        revision: Int? = nil,
        updatedAt: Int64 = 0
    ) -> CardPayload {
        CardPayload(
            cardId: cardId,
            sessionId: sessionId,
            category: "question",
            priority: "normal",
            title: "title-\(cardId)",
            summary: "summary-\(revision ?? -1)",
            actionPrompt: nil,
            payload: nil,
            state: "active",
            createdAt: 0,
            updatedAt: updatedAt,
            responseRevision: revision
        )
    }

    func test_sameRevisionGet_doesNotPromote_chipStaysOn() {
        // User replied while revision=3. Mac's reload tick re-
        // publishes the pre-reply card at revision=3. Bootstrap
        // GET picks it up. Entry must stay `.awaitingResponse`.
        let entries = SessionEntryStore.markUserReplied(
            previous: [
                SessionEntry(
                    sessionId: "s1",
                    card: card(cardId: "A", sessionId: "s1", revision: 3),
                    stage: .awaitingUser
                )
            ],
            cardId: "A",
            text: "please answer",
            instructionId: "i1"
        )
        XCTAssertEqual(entries[0].stage, .awaitingResponse)
        XCTAssertEqual(entries[0].instructedRevision, 3)

        let bootstrapped = SessionEntryStore.applyBootstrap(
            previous: entries,
            cards: [card(cardId: "A", sessionId: "s1", revision: 3, updatedAt: 5000)]
        )
        XCTAssertEqual(bootstrapped[0].stage, .awaitingResponse,
            "Same-revision GET must NOT promote — chip would drop before real answer")
        XCTAssertEqual(bootstrapped[0].instructedRevision, 3)
        XCTAssertEqual(bootstrapped[0].lastReplyText, "please answer")
        XCTAssertEqual(bootstrapped[0].lastInstructionId, "i1")
    }

    func test_newerRevisionGet_promotes_chipDropsAtomically() {
        // The real response landed: revision bumped from 3 → 4.
        // Bootstrap GET delivers revision=4. That IS the answer —
        // promote so the new card surfaces and chip drops together.
        let entries = SessionEntryStore.markUserReplied(
            previous: [
                SessionEntry(
                    sessionId: "s1",
                    card: card(cardId: "A", sessionId: "s1", revision: 3),
                    stage: .awaitingUser
                )
            ],
            cardId: "A",
            text: "please answer",
            instructionId: "i1"
        )

        let bootstrapped = SessionEntryStore.applyBootstrap(
            previous: entries,
            cards: [card(cardId: "A", sessionId: "s1", revision: 4, updatedAt: 5000)]
        )
        XCTAssertEqual(bootstrapped[0].stage, .awaitingUser)
        XCTAssertEqual(bootstrapped[0].card.responseRevision, 4)
    }

    func test_olderRevisionGet_doesNotPromote() {
        // Pathological — GET sees an older revision than what the
        // user replied against (stale relay cache, replay). Must
        // not promote.
        let entries = SessionEntryStore.markUserReplied(
            previous: [
                SessionEntry(
                    sessionId: "s1",
                    card: card(cardId: "A", sessionId: "s1", revision: 5),
                    stage: .awaitingUser
                )
            ],
            cardId: "A",
            text: "ping",
            instructionId: "i1"
        )

        let bootstrapped = SessionEntryStore.applyBootstrap(
            previous: entries,
            cards: [card(cardId: "A", sessionId: "s1", revision: 4, updatedAt: 5000)]
        )
        XCTAssertEqual(bootstrapped[0].stage, .awaitingResponse)
        XCTAssertEqual(bootstrapped[0].instructedRevision, 5)
    }

    func test_missingRevisionsOnBothSides_promotes() {
        // Legacy path — entry has no instructedRevision stamp
        // (direct construction in older flows) and the GET card
        // has no responseRevision. We treat both as 0 and apply
        // the "incoming > stamp" rule: 0 > 0 is false → no
        // promote. This is intentionally safer than the old
        // bias-to-unstick behavior; the decay watcher catches
        // genuine stuck cases.
        let entry = SessionEntry(
            sessionId: "s1",
            card: card(cardId: "A", sessionId: "s1", revision: nil),
            stage: .awaitingResponse,
            lastReplyText: "ping",
            lastInstructionId: "i1"
        )
        let bootstrapped = SessionEntryStore.applyBootstrap(
            previous: [entry],
            cards: [card(cardId: "A", sessionId: "s1", revision: nil, updatedAt: 5000)]
        )
        XCTAssertEqual(bootstrapped[0].stage, .awaitingResponse)
    }

    func test_failed_entryStillPromotes_userCanRetry() {
        // `.failed` is explicit — the user already saw a failure
        // banner; bootstrap surfacing the new card lets them
        // retry. This branch is unchanged from before.
        let entry = SessionEntry(
            sessionId: "s1",
            card: card(cardId: "A", sessionId: "s1", revision: 3),
            stage: .failed("send timeout"),
            lastReplyText: "ping",
            lastInstructionId: "i1"
        )
        let bootstrapped = SessionEntryStore.applyBootstrap(
            previous: [entry],
            cards: [card(cardId: "A", sessionId: "s1", revision: 3, updatedAt: 5000)]
        )
        XCTAssertEqual(bootstrapped[0].stage, .awaitingUser)
    }
}
