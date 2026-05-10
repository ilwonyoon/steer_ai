import XCTest
import SteerCore
@testable import Steer

/// Optimistic reply contract: when the user taps Send the card must
/// disappear from `cards` and a row must appear in `pendingReplies`
/// before any network call resolves. On success the row drops; on
/// failure the card returns and the row turns red.
///
/// We can't poke SyncInbox.shared's URLSession directly without
/// MockURLProtocol. Instead, exercise the public state-only paths:
/// enterDemoMode -> sendDemoReply (no network), and verify the
/// transitions match the same shape sendReply would produce.
@MainActor
final class SyncInboxOptimisticTests: XCTestCase {
    func testDemoModeSeedsCards() {
        let inbox = SyncInbox.shared
        // Reset just in case prior test left state.
        inbox.exitDemoMode()
        inbox.enterDemoMode()
        XCTAssertTrue(inbox.isDemoMode)
        XCTAssertGreaterThanOrEqual(inbox.cards.count, 3)
        inbox.exitDemoMode()
        XCTAssertFalse(inbox.isDemoMode)
        XCTAssertEqual(inbox.cards.count, 0)
    }

    func testDemoReplyTransitions() async {
        let inbox = SyncInbox.shared
        inbox.exitDemoMode()
        inbox.enterDemoMode()
        guard let card = inbox.cards.first else {
            return XCTFail("demo mode should seed cards")
        }
        // queued immediately
        Task { await inbox.sendDemoReply(text: "go", for: card) }
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        XCTAssertNotNil(inbox.demoReplyStates[card.cardId])

        // wait long enough for the 800ms simulation to finish
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let final = inbox.demoReplyStates[card.cardId]
        XCTAssertNotNil(final)
        switch final {
        case .delivered, .failed:
            break // any terminal state is acceptable
        default:
            XCTFail("expected terminal demo reply state, got \(String(describing: final))")
        }
        inbox.exitDemoMode()
    }
}
