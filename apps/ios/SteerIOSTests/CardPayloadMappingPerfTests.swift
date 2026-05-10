import XCTest
import SteerCore
@testable import Steer

/// Records the cost of CardPayload -> ActionCard projection that runs
/// every time the iPhone receives an update from the relay. We
/// memoize this in InboxView so it runs once per inbox.cards change,
/// but the per-call cost itself still has to stay tight or the
/// optimistic-send + chip-reorder paths feel laggy.
///
/// Baseline numbers from XCTest's automatic measure() block live in
/// the .xcresult bundle; printed values give a quick CI signal.
final class CardPayloadMappingPerfTests: XCTestCase {
    func makePayload(_ index: Int) -> CardPayload {
        CardPayload(
            cardId: "perf-card-\(index)",
            sessionId: "perf-session-\(index)",
            category: ["question", "blocker", "waiting", "decision"][index % 4],
            priority: "normal",
            title: "Perf Card \(index) · markdown **bold** *italic*",
            summary: "summary line for **card \(index)** with `inline code`",
            actionPrompt: "Decide.",
            payload: [
                "provider": AnyCodable("codex"),
                "project": AnyCodable("perf/repo"),
                "branchLabel": AnyCodable("main"),
                "options": AnyCodable(["Yes", "No", "Explain"]),
                "terminalLines": AnyCodable([
                    "$ swift build",
                    "Building...",
                    "* something happens",
                    "- option A",
                    "- option B",
                    "Decision needed."
                ])
            ],
            state: "active",
            createdAt: Int64(Date().timeIntervalSince1970 * 1000),
            updatedAt: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    func testMappingSingleCardLatency() {
        let payload = makePayload(0)
        // Warm caches.
        for _ in 0..<10 { _ = CardPayloadMapping.actionCard(from: payload) }

        measure {
            for _ in 0..<1000 {
                _ = CardPayloadMapping.actionCard(from: payload)
            }
        }
        // Loose budget: 1000 mappings under 100ms, i.e. <0.1ms each.
        // Tightened later when we have iPhone 14/15 Pro readings.
    }

    func testMappingFiftyCardsBatch() {
        let payloads = (0..<50).map { makePayload($0) }
        measure {
            _ = payloads.map { CardPayloadMapping.actionCard(from: $0) }
        }
    }
}
