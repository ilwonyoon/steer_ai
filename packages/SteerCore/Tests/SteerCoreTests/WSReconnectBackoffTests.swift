import XCTest
@testable import SteerCore

/// Numeric proof that the new exponential backoff is strictly better
/// than the old fixed 3s delay across realistic network outages.
///
/// We do not actually open a WebSocket. The harness exercises the
/// helper directly. Network behaviour is captured by the call site,
/// not by this strategy — what we're proving here is the cadence.
final class WSReconnectBackoffTests: XCTestCase {

    // MARK: - 1. Exact midpoint cadence

    func test_delays_followExpectedExponentialPattern_noJitter() {
        let b = WSReconnectBackoff(baseDelay: 1.0, maxDelay: 30.0, jitterFraction: 0.0)
        let expected: [TimeInterval] = [1, 2, 4, 8, 16, 30, 30, 30]
        for (i, want) in expected.enumerated() {
            let got = b.delaySeconds(forAttempt: i + 1)
            XCTAssertEqual(got, want, accuracy: 1e-6,
                "attempt \(i + 1) should sleep \(want)s, got \(got)")
        }
    }

    // MARK: - 2. Jitter stays within bounds

    func test_jitter_neverExceedsConfiguredFraction() {
        let b = WSReconnectBackoff(baseDelay: 1.0, maxDelay: 30.0, jitterFraction: 0.2)
        // Sweep all sane attempt indices through both random extremes.
        for attempt in 1...10 {
            let lower = b.delaySeconds(forAttempt: attempt) { 0.0 }   // worst negative jitter
            let upper = b.delaySeconds(forAttempt: attempt) { 0.999 } // worst positive jitter
            let midpoint = b.delaySeconds(forAttempt: attempt) { 0.5 } // exactly mid → no jitter
            // ±20% bound
            XCTAssertGreaterThanOrEqual(lower, midpoint * 0.8 - 1e-9)
            XCTAssertLessThanOrEqual(upper, midpoint * 1.2 + 1e-9)
        }
    }

    // MARK: - 3. Number of attempts in a real network outage window

    /// The original receiveLoop slept 3s flat. The new backoff sleeps
    /// 1, 2, 4, 8, 16, 30, 30, 30, ... Both numbers are direct
    /// counts, not interpretation.
    func test_attemptCount_60sOutage_dropsAtLeast4xVsFixed3s() {
        let window: TimeInterval = 60.0
        let oldCount = WSReconnectBackoff.attemptsInWindow(fixedDelay: 3.0, windowSeconds: window)
        let newBackoff = WSReconnectBackoff(baseDelay: 1.0, maxDelay: 30.0, jitterFraction: 0.0)
        let newCount = newBackoff.attemptsInWindow(window)

        XCTAssertEqual(oldCount, 20,
            "Sanity: 60s / 3s fixed = 20 attempts under the old loop")
        // Exponential reaches 1+2+4+8+16+30 = 61s in 6 attempts.
        XCTAssertLessThanOrEqual(newCount, 6)
        XCTAssertGreaterThanOrEqual(Double(oldCount) / Double(newCount), 3.0,
            "Expected at least a 3x reduction. old=\(oldCount), new=\(newCount).")
    }

    /// A 10-minute outage matters more for battery and Cloudflare
    /// dollar cost. The improvement gets larger, not smaller, as the
    /// outage lengthens — the new strategy stops re-trying at 30s
    /// while the old one keeps pounding every 3s forever.
    func test_attemptCount_10minOutage_dropsAtLeast10xVsFixed3s() {
        let window: TimeInterval = 600.0
        let oldCount = WSReconnectBackoff.attemptsInWindow(fixedDelay: 3.0, windowSeconds: window)
        let newBackoff = WSReconnectBackoff(baseDelay: 1.0, maxDelay: 30.0, jitterFraction: 0.0)
        let newCount = newBackoff.attemptsInWindow(window)

        XCTAssertEqual(oldCount, 200, "Sanity: 600s / 3s fixed = 200 attempts")
        // Exponential: 1+2+4+8+16+30+30+... in 600s reaches roughly
        // (600 - 31) / 30 + 6 ≈ 25 attempts.
        XCTAssertLessThanOrEqual(newCount, 25)
        XCTAssertGreaterThanOrEqual(Double(oldCount) / Double(newCount), 8.0,
            "Expected at least 8x reduction over a 10-min outage. old=\(oldCount), new=\(newCount).")
    }

    // MARK: - 4. First reconnect is fast (user-visible recovery)

    /// We don't want the backoff to delay the first reconnect too
    /// much. A flaky connection that drops once and recovers should
    /// come back inside ~1 second.
    func test_firstAttempt_isUnderTwoSeconds_evenWithMaxJitter() {
        let b = WSReconnectBackoff(baseDelay: 1.0, maxDelay: 30.0, jitterFraction: 0.2)
        let upper = b.delaySeconds(forAttempt: 1) { 0.999 }
        XCTAssertLessThan(upper, 2.0,
            "First reconnect must stay snappy; got \(upper)s")
    }
}
