import XCTest

/// Stress / soak scenarios. These don't assert "feature X works" — the
/// smoke and golden tests already do that. Instead they hammer one
/// path many times and use XCTMetric to catch silent regressions:
///   - memory growth across repeated view recycling
///   - CPU spikes from re-rendering or markdown re-parsing
///   - state machines that work once but break after N invocations
///
/// They are slow (each measure block runs the closure 5 times by
/// default) — run them locally before a release, not on every commit.
/// CI gating is up to whoever wires the pre-merge script.
final class StressFlowUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - 100x swipe loop, memory + CPU baseline

    func test_stress_100swipe_memoryAndCPU() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launch()

        let inbox = app.otherElements["inbox-content"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 6))
        XCTAssertTrue(app.textFields["reply-input"].waitForExistence(timeout: 4))

        let options = XCTMeasureOptions()
        options.iterationCount = 1
        // Measure both peak memory and CPU. If the swipe loop leaks
        // ActionCardView/CardPayloadMapping memos, peak memory
        // diverges from baseline over many runs.
        measure(metrics: [XCTMemoryMetric(), XCTCPUMetric()], options: options) {
            for _ in 0..<100 {
                let from = inbox.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.85, dy: 0.4)
                )
                let to = inbox.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.15, dy: 0.4)
                )
                from.press(forDuration: 0.03, thenDragTo: to)
            }
        }

        // After 100 swipes the reply field must still be reachable —
        // catches the case where the gesture overshoots and lands in
        // an empty state.
        XCTAssertTrue(app.textFields["reply-input"].exists)
    }

    // MARK: - 50x demo reply send, no state-machine drift

    func test_stress_50demoReplies_pendingChipStable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-signed-out"]
        app.launch()

        app.buttons["try-demo-button"].tap()

        let reply = app.textFields["reply-input"]
        XCTAssertTrue(reply.waitForExistence(timeout: 4))

        // Demo mode keeps the same card visible after each send (the
        // demo reply flips its state, doesn't remove the card from the
        // stack). So 50 sends against the same field is realistic.
        for i in 0..<50 {
            reply.tap()
            reply.typeText("r\(i)")
            app.buttons["reply-send"].tap()
            let cleared = expectation(
                for: NSPredicate(format: "value == 'Reply to this session'"),
                evaluatedWith: reply, handler: nil
            )
            wait(for: [cleared], timeout: 2)
        }

        // The reply path must still be live. The send button only
        // renders when `canSend` (non-empty trimmed reply), so we
        // type a single char first, then assert.
        XCTAssertTrue(reply.exists)
        reply.tap()
        reply.typeText("z")
        XCTAssertTrue(
            app.buttons["reply-send"].waitForExistence(timeout: 2),
            "reply-send button never re-appeared after 50 demo sends + 1 char"
        )
    }

    // MARK: - rotation + background/foreground churn

    func test_stress_rotationAndLifecycle_doesNotCrash() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launch()

        XCTAssertTrue(app.otherElements["inbox-content"].waitForExistence(timeout: 6))

        let device = XCUIDevice.shared
        let orientations: [UIDeviceOrientation] = [
            .landscapeLeft, .portrait, .landscapeRight, .portrait
        ]
        for _ in 0..<5 {
            for o in orientations {
                device.orientation = o
                // Give SwiftUI a frame to relayout. We don't actually
                // assert the layout — we assert that the app survives.
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        // Final state portrait.
        device.orientation = .portrait

        // Background / foreground 10 times. press(.home) suspends the
        // app; activate() brings it back.
        for _ in 0..<10 {
            device.press(.home)
            Thread.sleep(forTimeInterval: 0.3)
            app.activate()
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Still alive and inbox content is rendered.
        XCTAssertTrue(app.otherElements["inbox-content"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.textFields["reply-input"].exists)
    }

    // MARK: - long typing + erase, doesn't freeze input

    func test_stress_longTypingAndErase_textFieldRemainsResponsive() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launch()

        let reply = app.textFields["reply-input"]
        XCTAssertTrue(reply.waitForExistence(timeout: 6))
        reply.tap()

        // 600 chars (typeText() throughput in the sim is the bottleneck;
        // 2000 takes minutes). Three rounds = 1800 input events.
        let long = String(repeating: "abcdefghij ", count: 60)  // ~660 chars
        for _ in 0..<3 {
            reply.typeText(long)
            // Erase via cmd+A delete — works on simulator with hardware
            // keyboard enabled (default for XCUITest).
            reply.typeText(XCUIKeyboardKey.command.rawValue + "a")
            reply.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        // Field still focused and reachable.
        XCTAssertTrue(reply.exists)
    }
}
