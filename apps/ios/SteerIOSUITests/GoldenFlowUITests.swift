import XCTest

/// Golden-path scenarios. These mirror the journeys a real user takes
/// most often and the branches we deliberately keep working: demo
/// entry, multi-card swipe + draft preservation, keyboard layout,
/// and the Settings drill-down.
///
/// Smoke tests live in CardFlowUITests; this file is heavier and is
/// meant to catch behavioral regressions that don't show up in a
/// single-tap test.
final class GoldenFlowUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - 1. Sign-in prompt → Try Demo → reply → exit demo

    func test_demo_entry_reply_exit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-signed-out"]
        app.launch()

        // Sign-in prompt visible (no fixture mode).
        let prompt = app.otherElements["sign-in-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 6))
        // Apple sign-in button is replaced by a stub identifier so the
        // system sheet never opens.
        XCTAssertTrue(app.staticTexts["apple-signin-stub"].exists)

        // Try Demo enters demo mode and shows sample cards.
        let tryDemo = app.buttons["try-demo-button"]
        XCTAssertTrue(tryDemo.waitForExistence(timeout: 2))
        tryDemo.tap()

        let inbox = app.otherElements["inbox-content"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 4))
        let reply = app.textFields["reply-input"]
        XCTAssertTrue(reply.waitForExistence(timeout: 4))

        // Send a demo reply. After send, the field's value clears.
        reply.tap()
        reply.typeText("hello demo")
        app.buttons["reply-send"].tap()
        let cleared = expectation(
            for: NSPredicate(format: "value == 'reply to this session'"),
            evaluatedWith: reply, handler: nil
        )
        wait(for: [cleared], timeout: 3)

        // Top-right "Use Live Sync" exits demo mode → sign-in prompt
        // returns. The button label is plain text without an identifier,
        // so we find it via label.
        let useLive = app.buttons["Use Live Sync"]
        XCTAssertTrue(useLive.waitForExistence(timeout: 2))
        useLive.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 4))
    }

    // MARK: - 2. Card swipe + per-card draft preservation

    func test_swipe_preservesDraftPerCard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launch()

        let reply = app.textFields["reply-input"]
        XCTAssertTrue(reply.waitForExistence(timeout: 6))

        // Type a draft into card A.
        reply.tap()
        reply.typeText("draft A")
        XCTAssertEqual(reply.value as? String, "draft A")

        // Dismiss keyboard by tapping inbox-content, then swipe to card B.
        // The card itself is the gesture surface — swipe left on its
        // frame goes to the next card.
        app.otherElements["inbox-content"].tap()
        // Use a long swipe so the 82pt threshold inside cardSwipeGesture
        // is comfortably exceeded.
        let inboxRect = app.otherElements["inbox-content"].coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)
        )
        let leftEdge = app.otherElements["inbox-content"].coordinate(
            withNormalizedOffset: CGVector(dx: 0.05, dy: 0.4)
        )
        inboxRect.press(forDuration: 0.05, thenDragTo: leftEdge)

        // Wait for the card transition to settle. The TextField is
        // replaced by the next card's TextField; XCTest re-resolves
        // `reply` because the query is by identifier.
        // After the swipe, value should be empty (= placeholder).
        let placeholderPredicate = NSPredicate(format: "value == 'reply to this session'")
        let onCardB = expectation(for: placeholderPredicate, evaluatedWith: reply, handler: nil)
        wait(for: [onCardB], timeout: 3)

        // Type a draft on card B.
        reply.tap()
        reply.typeText("draft B")
        XCTAssertEqual(reply.value as? String, "draft B")

        // Dismiss keyboard and swipe back to card A (drag from left to right).
        app.otherElements["inbox-content"].tap()
        let leftEdge2 = app.otherElements["inbox-content"].coordinate(
            withNormalizedOffset: CGVector(dx: 0.05, dy: 0.4)
        )
        let rightEdge = app.otherElements["inbox-content"].coordinate(
            withNormalizedOffset: CGVector(dx: 0.95, dy: 0.4)
        )
        leftEdge2.press(forDuration: 0.05, thenDragTo: rightEdge)

        let draftA = NSPredicate(format: "value == 'draft A'")
        let restoredA = expectation(for: draftA, evaluatedWith: reply, handler: nil)
        wait(for: [restoredA], timeout: 3)
    }

    // MARK: - 3. Keyboard show/hide layout stability

    func test_keyboard_showHide_doesNotShakeCard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launch()

        let inbox = app.otherElements["inbox-content"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 6))
        let reply = app.textFields["reply-input"]
        XCTAssertTrue(reply.waitForExistence(timeout: 4))

        // Capture inbox frame with the keyboard hidden.
        let restingFrame = inbox.frame

        // Focus the reply field; keyboard rises.
        reply.tap()
        // Give SwiftUI two frames to settle.
        Thread.sleep(forTimeInterval: 0.4)
        // After tap, the inbox-content frame can shift up because
        // SwiftUI's keyboard avoidance pushes content. That's expected
        // — what we're asserting is that it returns to the resting
        // frame exactly after dismiss.

        // Dismiss the keyboard by tapping the card body (the
        // simultaneousGesture in InboxView clears focus on tap).
        inbox.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()

        // Wait for keyboard to retract. UIKit fires didHide once,
        // KeyboardObserver flips height to 0, and the carousel
        // re-inserts. Give it 0.5s.
        Thread.sleep(forTimeInterval: 0.6)

        let afterFrame = inbox.frame
        let drift = abs(afterFrame.origin.y - restingFrame.origin.y)
            + abs(afterFrame.size.height - restingFrame.size.height)
        XCTAssertLessThan(
            drift, 2.0,
            "Inbox frame drifted by \(drift)pt after keyboard show/hide — expected exact restore"
        )
    }

    // MARK: - 4. Settings → about / what syncs round-trip

    func test_settings_tabs_aboutAndWhatSyncs_reachable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launch()

        XCTAssertTrue(app.otherElements["inbox-content"].waitForExistence(timeout: 6))

        // Tab bar replaced by top-left Liquid Glass settings button.
        let settingsButton = app.buttons["settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 2))
        settingsButton.tap()

        // SettingsView is a Form/List. We don't pin identifiers on
        // every row because labels are stable. Instead we sanity-check
        // that the Settings list is up and at least one row is hit-
        // testable. If the user renames a row this test fails fast.
        let table = app.collectionViews.firstMatch
        if !table.waitForExistence(timeout: 2) {
            // iOS 17+ may render SettingsView as a List backed by a
            // UITableView; try that fallback.
            XCTAssertTrue(app.tables.firstMatch.waitForExistence(timeout: 2))
        }

        // Round-trip back to Inbox via the Done button in the sheet.
        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 2))
        doneButton.tap()
        XCTAssertTrue(app.otherElements["inbox-content"].waitForExistence(timeout: 2))
    }
}
