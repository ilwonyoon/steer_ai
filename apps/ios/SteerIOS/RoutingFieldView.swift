import SwiftUI

/// Animated background for SignInPrompt: a soft dot grid with
/// bezier "attention" traces routing from random outer dots to a
/// single hub dot in the center. The hub pulses when a trace
/// arrives, then re-emits new traces back out. Reads as: many
/// signals converging, one decision point, signals dispatched.
///
/// Implementation choice: SwiftUI `Canvas` + `TimelineView` at
/// ~60 fps. No Metal, no Lottie. The whole thing is ~150 lines
/// of pure SwiftUI and runs entirely on the CPU compositor.
/// `prefersReducedMotion` cuts the animation off and renders just
/// the static dot grid for accessibility.

struct RoutingFieldView: View {
    /// 24pt between dots reads as PCB-trace density without
    /// becoming visual noise behind the sign-in card.
    private let dotSpacing: CGFloat = 24
    /// 5 simultaneous traces gives the impression of activity
    /// without ever crowding the field.
    private let maxActiveTraces = 5
    /// One trace lifetime, in seconds.
    private let traceLifetime: Double = 2.0
    /// New trace cadence — one spawned roughly every 0.45s while
    /// we're under the cap.
    private let spawnIntervalMs: Int = 450

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var traces: [Trace] = []
    @State private var pulses: [Pulse] = []
    @State private var lastSpawnAt: Date = .distantPast
    @State private var startedAt: Date = Date()

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let hub = CGPoint(x: size.width / 2, y: size.height / 2)
            let cols = Int(size.width / dotSpacing) + 1
            let rows = Int(size.height / dotSpacing) + 1

            ZStack {
                // Layer 1 — static dot grid. Drawn once per
                // resize via Canvas (cheap path: no animation).
                Canvas { ctx, _ in
                    drawDotGrid(in: &ctx, cols: cols, rows: rows)
                }

                if !reduceMotion {
                    // Layer 2 — animated traces + pulses. The
                    // TimelineView wakes once per frame; the
                    // Canvas just re-draws the current state.
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                        Canvas { ctx, _ in
                            let now = timeline.date
                            advance(now: now, hub: hub, fieldSize: size, cols: cols, rows: rows)
                            drawTraces(in: &ctx, now: now)
                            drawPulses(in: &ctx, now: now, hub: hub)
                            drawHubDot(in: &ctx, hub: hub, now: now)
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .drawingGroup() // GPU-composite the whole field
    }

    // MARK: - Drawing

    private func drawDotGrid(
        in ctx: inout GraphicsContext,
        cols: Int,
        rows: Int
    ) {
        let dotColor = SteerColors.softSeparator.opacity(0.7)
        for r in 0..<rows {
            for c in 0..<cols {
                let x = CGFloat(c) * dotSpacing + dotSpacing / 2
                let y = CGFloat(r) * dotSpacing + dotSpacing / 2
                let rect = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(dotColor))
            }
        }
    }

    private func drawTraces(in ctx: inout GraphicsContext, now: Date) {
        for trace in traces {
            let t = trace.progress(now: now)
            guard t > 0 else { continue }
            // Partial bezier path up to t. Two cubic segments for
            // a more organic feel than a single curve.
            let path = trace.partialPath(progress: t)
            // Orange gradient stroke. Core: #FB7139.
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [
                    Color(red: 1.00, green: 0.55, blue: 0.35).opacity(0),
                    Color(red: 0.98, green: 0.44, blue: 0.22)
                ]),
                startPoint: trace.start,
                endPoint: trace.end
            )
            ctx.stroke(path, with: shading, style: StrokeStyle(
                lineWidth: 1.5, lineCap: .round, lineJoin: .round
            ))
        }
    }

    private func drawPulses(in ctx: inout GraphicsContext, now: Date, hub: CGPoint) {
        for pulse in pulses {
            let age = now.timeIntervalSince(pulse.bornAt)
            guard age >= 0, age <= pulse.duration else { continue }
            let t = age / pulse.duration
            let radius: CGFloat = 6 + CGFloat(t) * 40
            let alpha = (1 - t) * 0.45
            let rect = CGRect(
                x: hub.x - radius, y: hub.y - radius,
                width: radius * 2, height: radius * 2
            )
            ctx.stroke(
                Path(ellipseIn: rect),
                with: .color(Color(red: 0.98, green: 0.44, blue: 0.22).opacity(alpha)),
                lineWidth: 1.5
            )
        }
    }

    private func drawHubDot(in ctx: inout GraphicsContext, hub: CGPoint, now: Date) {
        // The hub always glows faintly so the user reads it as
        // "the destination," even between trace arrivals.
        let pulseGlow = pulses.reduce(0.0) { acc, p in
            let age = now.timeIntervalSince(p.bornAt)
            guard age >= 0, age <= p.duration else { return acc }
            return acc + (1 - age / p.duration) * 0.7
        }
        let glow = min(1.0, 0.3 + pulseGlow)
        let radius: CGFloat = 5
        let rect = CGRect(
            x: hub.x - radius, y: hub.y - radius,
            width: radius * 2, height: radius * 2
        )
        ctx.fill(
            Path(ellipseIn: rect),
            with: .color(Color(red: 1.00, green: 0.44, blue: 0.22).opacity(glow))
        )
    }

    // MARK: - State machine

    private func advance(
        now: Date,
        hub: CGPoint,
        fieldSize: CGSize,
        cols: Int,
        rows: Int
    ) {
        // Drop expired traces.
        traces.removeAll { now.timeIntervalSince($0.startedAt) > traceLifetime }
        pulses.removeAll { now.timeIntervalSince($0.bornAt) > $0.duration }

        // Each trace that just crossed t == 1 emits a pulse + a
        // counter-trace heading outward. We track this by stamping
        // a flag the first time we observe an arrival.
        for idx in traces.indices {
            if !traces[idx].arrived && traces[idx].progress(now: now) >= 1.0 {
                traces[idx].arrived = true
                pulses.append(Pulse(bornAt: now, duration: 0.6))
                // Outward counter-trace. Mirrored bezier.
                if let counter = randomTrace(
                    inward: false,
                    hub: hub,
                    fieldSize: fieldSize,
                    cols: cols,
                    rows: rows,
                    startedAt: now
                ) {
                    if traces.count < maxActiveTraces * 2 {
                        traces.append(counter)
                    }
                }
            }
        }

        // Spawn new inbound traces under the cap.
        let sinceSpawn = now.timeIntervalSince(lastSpawnAt) * 1000
        if traces.count < maxActiveTraces, Int(sinceSpawn) >= spawnIntervalMs {
            if let t = randomTrace(
                inward: true,
                hub: hub,
                fieldSize: fieldSize,
                cols: cols,
                rows: rows,
                startedAt: now
            ) {
                traces.append(t)
                lastSpawnAt = now
            }
        }
    }

    private func randomTrace(
        inward: Bool,
        hub: CGPoint,
        fieldSize: CGSize,
        cols: Int,
        rows: Int,
        startedAt: Date
    ) -> Trace? {
        guard cols > 2, rows > 2 else { return nil }
        // Pick an edge dot (not within 3 dots of the hub).
        let cx = cols / 2, cy = rows / 2
        var attempts = 0
        while attempts < 12 {
            attempts += 1
            let c = Int.random(in: 0..<cols)
            let r = Int.random(in: 0..<rows)
            let dx = abs(c - cx), dy = abs(r - cy)
            if max(dx, dy) < 3 { continue }
            let p = CGPoint(
                x: CGFloat(c) * dotSpacing + dotSpacing / 2,
                y: CGFloat(r) * dotSpacing + dotSpacing / 2
            )
            // Random control points biased toward the hub for
            // organic bezier curvature.
            let mid = CGPoint(x: (p.x + hub.x) / 2, y: (p.y + hub.y) / 2)
            let jitter: CGFloat = 60
            let c1 = CGPoint(
                x: mid.x + CGFloat.random(in: -jitter...jitter),
                y: mid.y + CGFloat.random(in: -jitter...jitter)
            )
            let c2 = CGPoint(
                x: (mid.x + (inward ? hub.x : p.x)) / 2 + CGFloat.random(in: -jitter...jitter),
                y: (mid.y + (inward ? hub.y : p.y)) / 2 + CGFloat.random(in: -jitter...jitter)
            )
            return Trace(
                start: inward ? p : hub,
                end:   inward ? hub : p,
                c1: c1,
                c2: c2,
                startedAt: startedAt,
                lifetime: traceLifetime,
                arrived: false
            )
        }
        return nil
    }
}

// MARK: - Data

private struct Trace {
    let start: CGPoint
    let end: CGPoint
    let c1: CGPoint
    let c2: CGPoint
    let startedAt: Date
    let lifetime: Double
    var arrived: Bool

    func progress(now: Date) -> Double {
        let age = now.timeIntervalSince(startedAt)
        return min(1.0, max(0.0, age / lifetime))
    }

    /// Partial cubic bezier path from `start` toward `end` up to
    /// fraction t. We approximate by stepping through small
    /// segments — for sub-frame fidelity at typical curvatures
    /// 24 segments is plenty.
    func partialPath(progress t: Double) -> Path {
        var path = Path()
        path.move(to: start)
        let segments = 24
        let upTo = max(1, Int(Double(segments) * t))
        for i in 1...upTo {
            let s = Double(i) / Double(segments)
            path.addLine(to: bezierPoint(at: s))
        }
        return path
    }

    private func bezierPoint(at t: Double) -> CGPoint {
        // Cubic Bezier B(t) = (1-t)^3 P0 + 3(1-t)^2 t P1 + 3(1-t) t^2 P2 + t^3 P3
        let u = 1 - t
        let uu = u * u
        let uuu = uu * u
        let tt = t * t
        let ttt = tt * t
        let x = uuu * start.x
            + 3 * uu * t * c1.x
            + 3 * u * tt * c2.x
            + ttt * end.x
        let y = uuu * start.y
            + 3 * uu * t * c1.y
            + 3 * u * tt * c2.y
            + ttt * end.y
        return CGPoint(x: x, y: y)
    }
}

private struct Pulse {
    let bornAt: Date
    let duration: Double
}
