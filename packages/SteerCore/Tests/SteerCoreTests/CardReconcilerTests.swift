import XCTest
@testable import SteerCore

/// Proves the reconciler returns the right (publish, resolve)
/// diffs in every scenario the Mac side hits.
///
/// The bug that motivated extracting this into SteerCore: cold
/// start with relay-side orphans. Mac app cold-starts with
/// empty `lastPublishedIds`; a card published yesterday and
/// since deleted locally would never get a DELETE without
/// pre-seeding from the relay's active list. Test 1 below is
/// the regression test for exactly that case.
final class CardReconcilerTests: XCTestCase {

    // MARK: - 1. Cold start with relay orphans (the regression)

    func test_coldStart_seededFromRelay_resolvesOrphans() {
        // Yesterday Mac published cards A, B, C. Today the local
        // store only reports A (B and C are gone — answered,
        // resolved, session ended). On cold start the caller
        // seeds `lastPublishedIds` from GET /v1/sync/cards and
        // gets back ["A","B","C"]; local reports ["A"].
        let decision = CardReconciler.reconcile(
            currentLocalIds: ["A"],
            lastPublishedIds: ["A", "B", "C"],
            changedIdsSinceLastPublish: []  // A is content-identical
        )
        XCTAssertEqual(decision.publishIds, [])
        XCTAssertEqual(decision.resolveIds, ["B", "C"])
        XCTAssertEqual(decision.nextPublishedIds, ["A"])
    }

    // MARK: - 2. Steady state (nothing changed)

    func test_steadyState_noPublishNoResolve() {
        let decision = CardReconciler.reconcile(
            currentLocalIds: ["A", "B"],
            lastPublishedIds: ["A", "B"],
            changedIdsSinceLastPublish: []
        )
        XCTAssertEqual(decision.publishIds, [])
        XCTAssertEqual(decision.resolveIds, [])
        XCTAssertEqual(decision.nextPublishedIds, ["A", "B"])
    }

    // MARK: - 3. New card appears locally

    func test_newCard_publishedOnFirstSeen() {
        let decision = CardReconciler.reconcile(
            currentLocalIds: ["A", "B"],
            lastPublishedIds: ["A"],
            changedIdsSinceLastPublish: ["B"]  // B is new, content "changed"
        )
        XCTAssertEqual(decision.publishIds, ["B"])
        XCTAssertEqual(decision.resolveIds, [])
        XCTAssertEqual(decision.nextPublishedIds, ["A", "B"])
    }

    // MARK: - 4. Existing card content updated

    func test_existingCard_republishedWhenContentChanges() {
        let decision = CardReconciler.reconcile(
            currentLocalIds: ["A", "B"],
            lastPublishedIds: ["A", "B"],
            changedIdsSinceLastPublish: ["A"]  // A's title or terminal lines changed
        )
        XCTAssertEqual(decision.publishIds, ["A"])
        XCTAssertEqual(decision.resolveIds, [])
        XCTAssertEqual(decision.nextPublishedIds, ["A", "B"])
    }

    // MARK: - 5. Local card disappears (resolve path)

    func test_existingCard_resolvedWhenLocalDisappears() {
        let decision = CardReconciler.reconcile(
            currentLocalIds: ["A"],
            lastPublishedIds: ["A", "B"],
            changedIdsSinceLastPublish: []
        )
        XCTAssertEqual(decision.publishIds, [])
        XCTAssertEqual(decision.resolveIds, ["B"])
        XCTAssertEqual(decision.nextPublishedIds, ["A"])
    }

    // MARK: - 6. changedIds containing an id that isn't local
    //         (defensive — caller's fingerprint set should never
    //         leak a stale id, but if it does we shouldn't try to
    //         PUT a card that isn't there)

    func test_changedIds_outsideLocal_areIgnored() {
        let decision = CardReconciler.reconcile(
            currentLocalIds: ["A"],
            lastPublishedIds: ["A"],
            changedIdsSinceLastPublish: ["X", "A"]  // X isn't local anymore
        )
        XCTAssertEqual(decision.publishIds, ["A"], "X must not appear in publishIds")
        XCTAssertEqual(decision.resolveIds, [])
        XCTAssertEqual(decision.nextPublishedIds, ["A"])
    }

    // MARK: - 7. Pure publish + pure resolve combined

    func test_combined_publishAndResolveInSameTick() {
        // Local: gained C, lost B
        // lastPublished: had A, B
        // → publish C (new), resolve B (gone), A unchanged
        let decision = CardReconciler.reconcile(
            currentLocalIds: ["A", "C"],
            lastPublishedIds: ["A", "B"],
            changedIdsSinceLastPublish: ["C"]
        )
        XCTAssertEqual(decision.publishIds, ["C"])
        XCTAssertEqual(decision.resolveIds, ["B"])
        XCTAssertEqual(decision.nextPublishedIds, ["A", "C"])
    }

    // MARK: - 8. Empty local + empty published (degenerate)

    func test_bothEmpty_isANoOp() {
        let decision = CardReconciler.reconcile(
            currentLocalIds: [],
            lastPublishedIds: [],
            changedIdsSinceLastPublish: []
        )
        XCTAssertEqual(decision.publishIds, [])
        XCTAssertEqual(decision.resolveIds, [])
        XCTAssertEqual(decision.nextPublishedIds, [])
    }
}
