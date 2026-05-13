import SwiftUI

/// Animated background for SignInPrompt. Dot grid with bright
/// orange "signals" traveling Manhattan-style between grid dots.
/// Periodically several signals converge on a temporary attention
/// dot, which pulses, then scatters outward to new targets.
///
/// Implementation: **deterministic, time-driven**. We pre-generate
/// a fixed schedule of traces at view creation (~300 of them on
/// a 30 s loop) seeded with a per-launch RNG so the field never
/// stalls. At each render frame we compute which traces are
/// "live right now" by comparing `now - startedAt` against each
/// trace's lifetime. No @State mutation inside the Canvas; no
/// timer hooks to schedule re-renders. TimelineView just keeps
/// `now` ticking.

struct RoutingFieldView: View {
    private let dotSpacing: CGFloat = 26
    private let traceLifetime: Double = 1.6
    private let spawnIntervalMs: Double = 220
    private let pulseDuration: Double = 0.6
    private let loopSeconds: Double = 30 // schedule repeats every 30s

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Wall-clock at view creation. `now - epoch` indexes the
    /// pre-rolled schedule. All randomness was already realized
    /// when `schedule` was built, so render-time is pure math.
    private let epoch: Date = Date()
    /// Per-launch schedule. Each entry tells us when a trace was
    /// born and which grid dots it walks. Pulses derive from
    /// arrivals.
    private let schedule: [ScheduledTrace]

    init() {
        var rng = SystemRandomNumberGenerator()
        // Big enough field to handle any reasonable phone size
        // (we'll clip to visible cols/rows at render time).
        let virtualCols = 24
        let virtualRows = 48
        let count = Int(30_000 / spawnIntervalMs) // ~135
        var entries: [ScheduledTrace] = []
        entries.reserveCapacity(count)
        // Attention target changes every 2s. Pre-roll the
        // sequence so we can compute "what was the attention dot
        // 4.3s into the loop" in O(1) at render time.
        var attentionAt: Double = 0
        var attention = GridPoint(
            col: Int.random(in: 0..<virtualCols, using: &rng),
            row: Int.random(in: 0..<virtualRows, using: &rng)
        )
        for i in 0..<count {
            let t = Double(i) * (spawnIntervalMs / 1000.0)
            if t - attentionAt > 2.0 {
                attention = GridPoint(
                    col: Int.random(in: 0..<virtualCols, using: &rng),
                    row: Int.random(in: 0..<virtualRows, using: &rng)
                )
                attentionAt = t
            }
            let from = GridPoint(
                col: Int.random(in: 0..<virtualCols, using: &rng),
                row: Int.random(in: 0..<virtualRows, using: &rng)
            )
            // Bend at one of the two corners.
            let bend: GridPoint
            if Bool.random(using: &rng) {
                bend = GridPoint(col: attention.col, row: from.row)
            } else {
                bend = GridPoint(col: from.col, row: attention.row)
            }
            entries.append(ScheduledTrace(
                bornAt: t,
                waypoints: from == attention ? [from, attention] : [from, bend, attention]
            ))
        }
        self.schedule = entries
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let cols = max(2, Int(size.width / dotSpacing))
            let rows = max(2, Int(size.height / dotSpacing))

            ZStack {
                Canvas { ctx, _ in
                    drawDotGrid(in: &ctx, cols: cols, rows: rows)
                }

                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                        Canvas { ctx, _ in
                            let elapsed = timeline.date.timeIntervalSince(epoch)
                            let loopT = elapsed.truncatingRemainder(dividingBy: loopSeconds)
                            drawLiveTraces(in: &ctx, loopT: loopT, cols: cols, rows: rows)
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .drawingGroup()
    }

    // MARK: - Drawing

    private func pointFor(_ g: GridPoint) -> CGPoint {
        CGPoint(
            x: CGFloat(g.col) * dotSpacing + dotSpacing / 2,
            y: CGFloat(g.row) * dotSpacing + dotSpacing / 2
        )
    }

    private func drawDotGrid(
        in ctx: inout GraphicsContext,
        cols: Int,
        rows: Int
    ) {
        let dotColor = SteerColors.softSeparator
        for r in 0..<rows {
            for c in 0..<cols {
                let p = pointFor(GridPoint(col: c, row: r))
                let rect = CGRect(x: p.x - 1.2, y: p.y - 1.2, width: 2.4, height: 2.4)
                ctx.fill(Path(ellipseIn: rect), with: .color(dotColor))
            }
        }
    }

    private func drawLiveTraces(
        in ctx: inout GraphicsContext,
        loopT: Double,
        cols: Int,
        rows: Int
    ) {
        let core = Color(red: 0.98, green: 0.42, blue: 0.18)

        // Trace pass.
        for entry in schedule {
            let age = loopT - entry.bornAt
            if age < 0 { continue }
            if age > traceLifetime + pulseDuration { continue }

            // Skip if any waypoint is off this device's visible grid.
            if !entry.waypoints.allSatisfy({ $0.col < cols && $0.row < rows }) {
                continue
            }

            if age <= traceLifetime {
                let t = max(0, min(1, age / traceLifetime))
                let path = manhattanPath(
                    waypoints: entry.waypoints,
                    progress: t
                )
                // Wide halo.
                ctx.stroke(path,
                    with: .color(core.opacity(0.18)),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .miter)
                )
                // Core stroke.
                ctx.stroke(path,
                    with: .color(core.opacity(0.95)),
                    style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .miter)
                )
                // Moving head dot.
                let head = headPoint(waypoints: entry.waypoints, progress: t)
                let r: CGFloat = 3
                ctx.fill(
                    Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2)),
                    with: .color(core)
                )
            } else {
                // Pulse phase at the end node.
                let pulseT = (age - traceLifetime) / pulseDuration
                let end = entry.waypoints.last!
                let p = pointFor(end)
                let radius: CGFloat = 4 + CGFloat(pulseT) * 28
                let alpha = (1 - pulseT) * 0.85
                ctx.stroke(
                    Path(ellipseIn: CGRect(
                        x: p.x - radius, y: p.y - radius,
                        width: radius * 2, height: radius * 2
                    )),
                    with: .color(core.opacity(alpha)),
                    lineWidth: 1.8
                )
                let dotR: CGFloat = 3
                ctx.fill(
                    Path(ellipseIn: CGRect(
                        x: p.x - dotR, y: p.y - dotR,
                        width: dotR * 2, height: dotR * 2
                    )),
                    with: .color(core.opacity(1 - pulseT))
                )
            }
        }
    }

    private func manhattanPath(waypoints: [GridPoint], progress t: Double) -> Path {
        var path = Path()
        guard waypoints.count >= 2 else { return path }
        let segments = waypoints.count - 1
        path.move(to: pointFor(waypoints[0]))
        let segT = t * Double(segments)
        for i in 0..<segments {
            let localT = max(0, min(1, segT - Double(i)))
            if localT == 0 { break }
            let a = pointFor(waypoints[i])
            let b = pointFor(waypoints[i + 1])
            let x = a.x + (b.x - a.x) * CGFloat(localT)
            let y = a.y + (b.y - a.y) * CGFloat(localT)
            path.addLine(to: CGPoint(x: x, y: y))
            if localT < 1 { break }
        }
        return path
    }

    private func headPoint(waypoints: [GridPoint], progress t: Double) -> CGPoint {
        let segments = waypoints.count - 1
        guard segments > 0 else { return pointFor(waypoints[0]) }
        let segT = t * Double(segments)
        let i = min(segments - 1, Int(segT))
        let localT = max(0, min(1, segT - Double(i)))
        let a = pointFor(waypoints[i])
        let b = pointFor(waypoints[i + 1])
        return CGPoint(
            x: a.x + (b.x - a.x) * CGFloat(localT),
            y: a.y + (b.y - a.y) * CGFloat(localT)
        )
    }
}

// MARK: - Data

private struct GridPoint: Equatable, Hashable {
    let col: Int
    let row: Int
}

private struct ScheduledTrace {
    /// Seconds into the loop when this trace was born.
    let bornAt: Double
    /// 2 or 3 grid waypoints.
    let waypoints: [GridPoint]
}
