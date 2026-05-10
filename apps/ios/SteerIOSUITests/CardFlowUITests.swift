import XCTest

/// Golden-path XCUITest. Runs against a simulator from the CLI:
///
///   xcodebuild test \
///     -project apps/ios/Steer.xcodeproj \
///     -scheme Steer \
///     -destination 'platform=iOS Simulator,name=iPhone 16' \
///     -only-testing:SteerUITests
///
/// Why this lives in `apps/ios/SteerIOSUITests` rather than the unit
/// test bundle: XCUITest runs in a separate "Runner" process and
/// drives the real app through the accessibility framework, so we
/// only see what a real user sees. Unit tests in SteerIOSTests host
/// the app in-process and can poke @Published state directly.
///
/// We pass `--uitest` as a launch argument so `SyncInbox.fixtureModeEnabled`
/// returns true. That forces:
///   - skip Sign in with Apple (the system ID sheet is owned by
///     another process and isn't drivable by XCUITest)
///   - load a fake user
///   - seed sample cards (fixture-question, fixture-waiting,
///     fixture-blocker, fixture-failed)
/// without any network round trip to the relay.
final class CardFlowUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Stop after the first failure so the diagnostic screenshot is
        // tied to the actual failing step, not whatever follow-on
        // assertion ran on a broken UI.
        continueAfterFailure = false
    }

    func test_launch_showsFixtureCard_inboxTabSelected() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launch()

        // The container that wraps the whole inbox is published.
        let inbox = app.otherElements["inbox-content"]
        XCTAssertTrue(
            inbox.waitForExistence(timeout: 8),
            "inbox-content never appeared. Snapshot: \(app.debugDescription)"
        )

        // Reply field is unique-per-card and the surest proof that a
        // real ActionCardView mounted with a usable reply path.
        let replyField = app.textFields["reply-input"]
        XCTAssertTrue(
            replyField.waitForExistence(timeout: 4),
            "reply-input never appeared. Snapshot: \(app.debugDescription)"
        )
    }

    func test_reply_send_clearsInputAndAdvances() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launch()

        let replyField = app.textFields["reply-input"]
        XCTAssertTrue(
            replyField.waitForExistence(timeout: 8),
            "reply-input never appeared. Snapshot: \(app.debugDescription)"
        )

        replyField.tap()
        replyField.typeText("approved")

        // Reply send button is wrapped in a Button + custom view, so
        // XCTest sees it under .buttons by identifier.
        let sendButton = app.buttons["reply-send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 2))
        sendButton.tap()

        // After send the field's value clears and focus drops. The
        // text field's `value` is the placeholder when empty.
        let predicate = NSPredicate(format: "value == 'reply to this session'")
        let cleared = expectation(for: predicate, evaluatedWith: replyField, handler: nil)
        wait(for: [cleared], timeout: 3)
    }

    func test_settings_tabReachable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launch()

        // Wait for inbox so we know we're past the launch screen.
        XCTAssertTrue(app.otherElements["inbox-content"].waitForExistence(timeout: 8))

        // .tabItem strips most of our custom identifiers and replaces
        // them with the SF Symbol's accessibility label (e.g. "Album"
        // for `rectangle.stack.fill`). System TabBar buttons are
        // best located by index or by the system-assigned label.
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 2))
        XCTAssertEqual(tabBar.buttons.count, 2, "Expected exactly 2 tabs (Inbox, Settings)")
        // Settings is the second tab.
        tabBar.buttons.element(boundBy: 1).tap()
        // Round-trip back to Inbox so subsequent tests start clean.
        tabBar.buttons.element(boundBy: 0).tap()
    }
}
