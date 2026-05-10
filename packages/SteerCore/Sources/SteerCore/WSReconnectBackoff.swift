import Foundation

/// Exponential backoff for WebSocket reconnect attempts.
///
/// Why this isn't just a fixed delay: the WS receiveLoop's previous
/// implementation slept a flat 3 seconds between reconnects. In a
/// network hiccup (subway, weak cell, captive portal) that meant ~20
/// reconnect attempts per minute. Each attempt is one TLS handshake
/// + one Durable Object connect; that's measurable battery drain on
/// the client and direct dollar cost on Cloudflare. None of those
/// attempts help — while the underlying network is down the next
/// reconnect will also fail.
///
/// Pattern: 1s, 2s, 4s, 8s, 16s, then capped at 30s. With ±20%
/// jitter so a herd of clients reconnecting against the same outage
/// don't all retry on the same second.
///
/// The harness in `WSReconnectBackoffTests` exercises this without
/// any real network so the cadence is provable, not just inferred
/// from logs.
public struct WSReconnectBackoff: Sendable {
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let jitterFraction: Double

    public init(
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        jitterFraction: Double = 0.2
    ) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitterFraction = jitterFraction
    }

    /// Delay (in seconds) before the Nth reconnect attempt. attempt
    /// is 1-indexed: attempt 1 returns ~baseDelay, attempt 2 returns
    /// ~2*baseDelay, etc. The returned value is always clamped to
    /// [0, maxDelay] and includes random jitter.
    public func delaySeconds(forAttempt attempt: Int) -> TimeInterval {
        delaySeconds(forAttempt: attempt, random: { Double.random(in: 0..<1) })
    }

    /// Test-friendly variant that takes a deterministic RNG so the
    /// harness can pin exact numbers. `random` must return values in
    /// [0, 1).
    public func delaySeconds(forAttempt attempt: Int, random: () -> Double) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        // 2^(attempt-1) — first attempt = baseDelay.
        let exponent = min(attempt - 1, 30)  // guard against overflow on absurd input
        let raw = baseDelay * pow(2.0, Double(exponent))
        let capped = min(raw, maxDelay)
        let jitter = capped * jitterFraction * (random() * 2 - 1)  // [-jitter, +jitter]
        return max(0, capped + jitter)
    }

    /// Total wall-clock time spent across attempts 1..N, given the
    /// midpoint (no jitter) delays. Used by tests to compare against
    /// the old 3s-fixed loop and prove an improvement.
    public func totalDelayForFirstNAttempts(_ n: Int) -> TimeInterval {
        guard n > 0 else { return 0 }
        var sum: TimeInterval = 0
        for i in 1...n {
            // No jitter for the analytic comparison.
            let exponent = min(i - 1, 30)
            let raw = baseDelay * pow(2.0, Double(exponent))
            sum += min(raw, maxDelay)
        }
        return sum
    }

    /// Number of attempts the old fixed-delay reconnect loop would
    /// make in the given window. Used by tests to express the
    /// improvement as a ratio.
    public static func attemptsInWindow(fixedDelay: TimeInterval, windowSeconds: TimeInterval) -> Int {
        guard fixedDelay > 0 else { return 0 }
        return Int(windowSeconds / fixedDelay)
    }

    /// Number of attempts THIS backoff strategy makes in the given
    /// window (using midpoint delays).
    public func attemptsInWindow(_ windowSeconds: TimeInterval) -> Int {
        var elapsed: TimeInterval = 0
        var n = 0
        while elapsed < windowSeconds {
            n += 1
            elapsed += min(baseDelay * pow(2.0, Double(n - 1)), maxDelay)
        }
        return n
    }
}
