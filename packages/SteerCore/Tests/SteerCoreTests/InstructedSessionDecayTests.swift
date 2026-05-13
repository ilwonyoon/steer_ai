import XCTest
@testable import SteerCore

final class InstructedSessionDecayTests: XCTestCase {

    // MARK: - The bug this exists to fix
    //
    // Before this helper existed, SteerRootView's inline decay used
    // `instructed.intersection(loadedChips).subtracting(cards)`. The
    // `subtracting(cards)` clause was wrong: when the user replied
    // to an existing card, the same card row was still active in
    // SQLite for a few hundred ms before the agent resolved it, and
    // the decay removed the session from `instructedSessionIds` on
    // the very next reload tick. iPhone chip went from "1 running"
    // straight back to "Mac" the instant the user pressed send.

    func test_replyToExistingCard_chipStaysUntilNewResponseArrives() {
        // t0 = 1000 ms: user replied via Mac/iPhone. Card A is
        // currently the *previous* response, still active in SQLite
        // because the agent hasn't resolved it yet.
        let previous: [String: InstructedAt] = [
            "A": InstructedAt(atMs: 1000)
        ]
        // Next reload tick: card A is still active, same updatedAt
        // as before (no new response yet — terminal is mid-flight).
        let next = InstructedSessionDecay.decay(
            previous: previous,
            liveSessionIds: ["A"],
            cards: [
                CardUpdateSnapshot(sessionId: "A", updatedAtMs: 500)
            ]
        )
        XCTAssertEqual(next.keys.sorted(), ["A"])
    }

    func test_newCardAfterReply_decaysOut() {
        // t0 = 1000 ms: reply sent.
        let previous: [String: InstructedAt] = [
            "A": InstructedAt(atMs: 1000)
        ]
        // Later: terminal finished; new card produced at t=1500.
        // updatedAt(1500) > instructedAt(1000) → decay.
        let next = InstructedSessionDecay.decay(
            previous: previous,
            liveSessionIds: ["A"],
            cards: [
                CardUpdateSnapshot(sessionId: "A", updatedAtMs: 1500)
            ]
        )
        XCTAssertEqual(next, [:])
    }

    func test_sessionEnded_decaysOut() {
        let previous: [String: InstructedAt] = [
            "A": InstructedAt(atMs: 1000)
        ]
        // Session disappeared from the live set (ended / disconnected).
        let next = InstructedSessionDecay.decay(
            previous: previous,
            liveSessionIds: [],
            cards: []
        )
        XCTAssertEqual(next, [:])
    }

    func test_runStateFlipAlone_doesNotDecay() {
        // The decay function only cares about (live, cards). It
        // does NOT take run_state, so a short reply that flips the
        // wrapper from "running" → "waiting" between two reload
        // ticks leaves the chip stable.
        let previous: [String: InstructedAt] = [
            "A": InstructedAt(atMs: 1000)
        ]
        let next = InstructedSessionDecay.decay(
            previous: previous,
            liveSessionIds: ["A"],
            cards: [] // no card yet
        )
        XCTAssertEqual(next.keys.sorted(), ["A"])
    }

    func test_replyToNewSession_noPriorCard() {
        // Brand-new session, no pre-existing card. Reply at t=1000;
        // terminal hasn't finished yet → no card → stays.
        let previous: [String: InstructedAt] = [
            "FRESH": InstructedAt(atMs: 1000)
        ]
        let next = InstructedSessionDecay.decay(
            previous: previous,
            liveSessionIds: ["FRESH"],
            cards: []
        )
        XCTAssertEqual(next.keys.sorted(), ["FRESH"])
    }

    func test_multipleSessions_independentDecay() {
        let previous: [String: InstructedAt] = [
            "A": InstructedAt(atMs: 1000),
            "B": InstructedAt(atMs: 1000),
            "C": InstructedAt(atMs: 1000)
        ]
        let next = InstructedSessionDecay.decay(
            previous: previous,
            liveSessionIds: ["A", "B"],  // C ended
            cards: [
                // A: old card, no new response → stays
                CardUpdateSnapshot(sessionId: "A", updatedAtMs: 500),
                // B: new card just arrived → decays
                CardUpdateSnapshot(sessionId: "B", updatedAtMs: 1500)
            ]
        )
        XCTAssertEqual(next.keys.sorted(), ["A"])
    }

    func test_duplicateCardEntries_pickNewestUpdate() {
        // Defensive: classifier upsert race can briefly produce two
        // rows for the same session. The helper must consult the
        // *newest* card update, not the first one it encounters.
        let previous: [String: InstructedAt] = [
            "A": InstructedAt(atMs: 1000)
        ]
        let next = InstructedSessionDecay.decay(
            previous: previous,
            liveSessionIds: ["A"],
            cards: [
                CardUpdateSnapshot(sessionId: "A", updatedAtMs: 500),
                CardUpdateSnapshot(sessionId: "A", updatedAtMs: 1500) // newer
            ]
        )
        // Newest card (1500) > reply (1000) → decay.
        XCTAssertEqual(next, [:])
    }

    func test_emptyInput_isNoOp() {
        let next = InstructedSessionDecay.decay(
            previous: [:],
            liveSessionIds: [],
            cards: []
        )
        XCTAssertEqual(next, [:])
    }
}
