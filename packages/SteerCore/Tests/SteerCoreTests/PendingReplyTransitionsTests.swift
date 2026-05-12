import XCTest
@testable import SteerCore

final class PendingReplyTransitionsTests: XCTestCase {

    // MARK: - Single-row golden path

    func test_sending_to_injected_onRelayAccepted() {
        let p1 = [
            PendingReplySnapshot(id: "p1", sessionId: "S1", status: .sending)
        ]
        let next = PendingReplyTransitions.onRelayAccepted(previous: p1, id: "p1")
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].status, .injected)
        XCTAssertEqual(
            PendingReplyTransitions.activeSessionIds(in: next),
            ["S1"]
        )
    }

    func test_injected_dropsWhenCardArrives() {
        let p1 = [
            PendingReplySnapshot(id: "p1", sessionId: "S1", status: .injected)
        ]
        let next = PendingReplyTransitions.onCardArrivedForSession(
            previous: p1, sessionId: "S1"
        )
        XCTAssertEqual(next, [])
        XCTAssertEqual(
            PendingReplyTransitions.activeSessionIds(in: next),
            []
        )
    }

    func test_sending_failedOnRelayError() {
        let p1 = [
            PendingReplySnapshot(id: "p1", sessionId: "S1", status: .sending)
        ]
        let next = PendingReplyTransitions.onRelayFailed(
            previous: p1, id: "p1", reason: "boom"
        )
        XCTAssertEqual(next[0].status, .failed("boom"))
        XCTAssertEqual(
            PendingReplyTransitions.activeSessionIds(in: next),
            []
        )
    }

    // MARK: - Defensive

    func test_cardArrival_doesNotDropSendingRow() {
        // POST still in flight; we haven't seen the relay's ack yet.
        // A card showing up for the same session right now is a race
        // (Mac already produced a new card before our POST reached
        // the relay). Leave the .sending row alone: we'll resolve it
        // on the relay POST callback either way.
        let p1 = [
            PendingReplySnapshot(id: "p1", sessionId: "S1", status: .sending)
        ]
        let next = PendingReplyTransitions.onCardArrivedForSession(
            previous: p1, sessionId: "S1"
        )
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].status, .sending)
    }

    func test_cardArrival_leavesFailedRow() {
        // User still needs to retry / cancel; the card row showing
        // up shouldn't auto-resolve their error.
        let p1 = [
            PendingReplySnapshot(id: "p1", sessionId: "S1", status: .failed("net"))
        ]
        let next = PendingReplyTransitions.onCardArrivedForSession(
            previous: p1, sessionId: "S1"
        )
        XCTAssertEqual(next, p1)
    }

    func test_relayAccepted_ignoresUnknownId() {
        let p1 = [
            PendingReplySnapshot(id: "p1", sessionId: "S1", status: .sending)
        ]
        let next = PendingReplyTransitions.onRelayAccepted(
            previous: p1, id: "nope"
        )
        XCTAssertEqual(next, p1)
    }

    func test_relayAccepted_doesNotDowngradeInjected() {
        // Idempotent: if somehow the same ack fires twice we don't
        // flicker .injected back to anything.
        let p1 = [
            PendingReplySnapshot(id: "p1", sessionId: "S1", status: .injected)
        ]
        let next = PendingReplyTransitions.onRelayAccepted(
            previous: p1, id: "p1"
        )
        XCTAssertEqual(next, p1)
    }

    // MARK: - Multi-row coexistence

    func test_multipleRowsDifferentSessions() {
        let pending = [
            PendingReplySnapshot(id: "p1", sessionId: "A", status: .sending),
            PendingReplySnapshot(id: "p2", sessionId: "B", status: .injected),
            PendingReplySnapshot(id: "p3", sessionId: "C", status: .failed("x"))
        ]
        XCTAssertEqual(
            PendingReplyTransitions.activeSessionIds(in: pending),
            ["A", "B"]
        )
        // Card for B → only B's .injected drops.
        let afterB = PendingReplyTransitions.onCardArrivedForSession(
            previous: pending, sessionId: "B"
        )
        XCTAssertEqual(afterB.count, 2)
        XCTAssertEqual(
            PendingReplyTransitions.activeSessionIds(in: afterB),
            ["A"]
        )
        XCTAssertTrue(afterB.contains(where: { $0.id == "p1" }))
        XCTAssertTrue(afterB.contains(where: { $0.id == "p3" }))
    }

    func test_multipleRowsSameSession_keepsBothUntilEachInjected() {
        // Edge case: the user fires two replies into the same session
        // quickly. Both rows should track independently.
        let p1 = [
            PendingReplySnapshot(id: "p1", sessionId: "S1", status: .sending),
            PendingReplySnapshot(id: "p2", sessionId: "S1", status: .sending)
        ]
        let after1 = PendingReplyTransitions.onRelayAccepted(
            previous: p1, id: "p1"
        )
        XCTAssertEqual(after1[0].status, .injected)
        XCTAssertEqual(after1[1].status, .sending)
        // Card for S1: drops only the .injected row. .sending row
        // stays — its POST hasn't returned yet.
        let afterCard = PendingReplyTransitions.onCardArrivedForSession(
            previous: after1, sessionId: "S1"
        )
        XCTAssertEqual(afterCard.count, 1)
        XCTAssertEqual(afterCard[0].id, "p2")
        XCTAssertEqual(afterCard[0].status, .sending)
        // S1 still counts as "active" because the second reply is
        // still in flight.
        XCTAssertEqual(
            PendingReplyTransitions.activeSessionIds(in: afterCard),
            ["S1"]
        )
    }

    func test_empty_isNoOp() {
        XCTAssertEqual(
            PendingReplyTransitions.onRelayAccepted(previous: [], id: "p1"),
            []
        )
        XCTAssertEqual(
            PendingReplyTransitions.onCardArrivedForSession(
                previous: [], sessionId: "S1"),
            []
        )
        XCTAssertEqual(
            PendingReplyTransitions.activeSessionIds(in: []),
            []
        )
    }
}
