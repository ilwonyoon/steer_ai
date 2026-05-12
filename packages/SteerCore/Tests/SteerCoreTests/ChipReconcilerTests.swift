import XCTest
@testable import SteerCore

final class ChipReconcilerTests: XCTestCase {

    // MARK: - 1. Cold start with relay orphans (the regression)

    func test_coldStart_seededFromRelay_resolvesOrphans() {
        // Yesterday Mac published chips A, B, C. Today the local
        // store only reports A live (B and C ended). Cold-start
        // seeding put A/B/C into lastPublished; local is [A].
        let now: TimeInterval = 1000
        let decision = ChipReconciler.reconcile(
            currentLocal: [
                ChipSnapshot(sessionId: "A", fingerprint: "running|proj|claude")
            ],
            lastPublished: [
                "A": ChipPublishMemory(fingerprint: "running|proj|claude", publishedAtEpoch: now),
                "B": ChipPublishMemory(fingerprint: "running|otherproj|codex", publishedAtEpoch: now - 60),
                "C": ChipPublishMemory(fingerprint: "waiting|x|codex", publishedAtEpoch: now - 60)
            ],
            now: now
        )
        // A is unchanged + fresh → no publish/heartbeat
        XCTAssertEqual(decision.publishIds, [])
        XCTAssertEqual(decision.heartbeatIds, [])
        // B and C must get terminal-state publishes
        XCTAssertEqual(decision.resolveIds, ["B", "C"])
        // Baseline keeps A, drops B/C
        XCTAssertEqual(decision.nextPublished.keys.sorted(), ["A"])
    }

    // MARK: - 2. Steady state — same fingerprints, fresh heartbeat

    func test_steadyState_noWork() {
        let now: TimeInterval = 1000
        let decision = ChipReconciler.reconcile(
            currentLocal: [
                ChipSnapshot(sessionId: "A", fingerprint: "running|p|claude")
            ],
            lastPublished: [
                "A": ChipPublishMemory(fingerprint: "running|p|claude", publishedAtEpoch: now - 5)
            ],
            now: now
        )
        XCTAssertEqual(decision.publishIds, [])
        XCTAssertEqual(decision.heartbeatIds, [])
        XCTAssertEqual(decision.resolveIds, [])
    }

    // MARK: - 3. Content changed → publish

    func test_contentChanged_publishes() {
        let now: TimeInterval = 1000
        let decision = ChipReconciler.reconcile(
            currentLocal: [
                ChipSnapshot(sessionId: "A", fingerprint: "running|p|claude")
            ],
            lastPublished: [
                "A": ChipPublishMemory(fingerprint: "waiting|p|claude", publishedAtEpoch: now - 5)
            ],
            now: now
        )
        XCTAssertEqual(decision.publishIds, ["A"])
        XCTAssertEqual(decision.heartbeatIds, [])
        XCTAssertEqual(decision.resolveIds, [])
        XCTAssertEqual(decision.nextPublished["A"]?.fingerprint, "running|p|claude")
        XCTAssertEqual(decision.nextPublished["A"]?.publishedAtEpoch, now)
    }

    // MARK: - 4. Same content but stale heartbeat → republish

    func test_staleHeartbeat_republishes() {
        let now: TimeInterval = 1000
        let decision = ChipReconciler.reconcile(
            currentLocal: [
                ChipSnapshot(sessionId: "A", fingerprint: "running|p|claude")
            ],
            lastPublished: [
                "A": ChipPublishMemory(fingerprint: "running|p|claude", publishedAtEpoch: now - 31)
            ],
            now: now
        )
        XCTAssertEqual(decision.publishIds, [])
        XCTAssertEqual(decision.heartbeatIds, ["A"])
        XCTAssertEqual(decision.nextPublished["A"]?.publishedAtEpoch, now)
    }

    // MARK: - 5. New local chip with no prior baseline → publish

    func test_brandNewChip_publishes() {
        let decision = ChipReconciler.reconcile(
            currentLocal: [
                ChipSnapshot(sessionId: "NEW", fingerprint: "running|p|claude")
            ],
            lastPublished: [:],
            now: 1000
        )
        XCTAssertEqual(decision.publishIds, ["NEW"])
        XCTAssertEqual(decision.heartbeatIds, [])
        XCTAssertEqual(decision.resolveIds, [])
    }

    // MARK: - 6. Session ends → terminal resolve

    func test_localSessionDisappears_resolvedTerminal() {
        let now: TimeInterval = 1000
        let decision = ChipReconciler.reconcile(
            currentLocal: [],  // session ended locally
            lastPublished: [
                "A": ChipPublishMemory(fingerprint: "running|p|claude", publishedAtEpoch: now - 5)
            ],
            now: now
        )
        XCTAssertEqual(decision.publishIds, [])
        XCTAssertEqual(decision.heartbeatIds, [])
        XCTAssertEqual(decision.resolveIds, ["A"])
        XCTAssertEqual(decision.nextPublished, [:])
    }

    // MARK: - 7. Mix of publish + heartbeat + resolve in same tick

    func test_combinedTick_allThreeShapes() {
        let now: TimeInterval = 1000
        let decision = ChipReconciler.reconcile(
            currentLocal: [
                // A: content changed
                ChipSnapshot(sessionId: "A", fingerprint: "waiting|p|claude"),
                // B: same content, stale → heartbeat
                ChipSnapshot(sessionId: "B", fingerprint: "running|p|codex"),
                // C: brand new
                ChipSnapshot(sessionId: "C", fingerprint: "running|new|codex")
            ],
            lastPublished: [
                "A": ChipPublishMemory(fingerprint: "running|p|claude", publishedAtEpoch: now - 1),
                "B": ChipPublishMemory(fingerprint: "running|p|codex", publishedAtEpoch: now - 60),
                // D: was live, now gone → resolve
                "D": ChipPublishMemory(fingerprint: "running|d|claude", publishedAtEpoch: now - 10)
            ],
            now: now
        )
        XCTAssertEqual(decision.publishIds, ["A", "C"])
        XCTAssertEqual(decision.heartbeatIds, ["B"])
        XCTAssertEqual(decision.resolveIds, ["D"])
        XCTAssertEqual(decision.nextPublished.keys.sorted(), ["A", "B", "C"])
    }

    // MARK: - 8. Both empty (degenerate)

    func test_bothEmpty_isANoOp() {
        let decision = ChipReconciler.reconcile(
            currentLocal: [],
            lastPublished: [:],
            now: 1000
        )
        XCTAssertEqual(decision.publishIds, [])
        XCTAssertEqual(decision.heartbeatIds, [])
        XCTAssertEqual(decision.resolveIds, [])
        XCTAssertEqual(decision.nextPublished, [:])
    }
}
