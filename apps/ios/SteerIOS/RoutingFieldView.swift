import SwiftUI

/// Animated background for SignInPrompt: a dot grid where signals
/// route Manhattan-style (right-angle steps along grid lines) from
/// scattered source dots toward a temporary "attention" target dot.
/// When several signals converge on that target it lights up, then
/// becomes itself a new source that re-emits to fresh targets.
/// Repeat. The center has no special role — attention floats
/// around the field.
///
/// Implementation: SwiftUI `Canvas` + `TimelineView` at 60 fps.
/// No Metal, no shaders. Each `Trace` walks a fixed sequence of
/// grid coordinates (start, optional bend, end); `progress` slides
/// along that polyline. Multiple traces can target the same dot;
/// when one arrives, that dot pulses, and the world picks a new
/// attention target for future spawns.

struct RoutingFieldView: View {
    /// 26pt between dots. Dense enough that Manhattan routes have
    /// visible bends; loose enough that the dots don't look
    /// painted-on.
    private let dotSpacing: CGFloat = 26
    private let maxActiveTraces = 10
    private let traceLifetime: Double = 1.4
    private let spawnIntervalMs: Int = 180
    /// How long an "attention" target stays as a destination
    /// before the world picks a fresh one.
    private let attentionLifetime: Double = 2.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var traces: [Trace] = []
    @State private var pulses: [Pulse] = []
    @State private var lastSpawnAt: Date = .distantPast
    @State private var attention: GridPoint? = nil
    @State private var attentionStarted: Date = .distantPast

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let cols = max(2, Int(size.width / dotSpacing))
            let rows = max(2, Int(size.height / dotSpacing))

            ZStack {
                // Static dot grid — draws once per resize.
                Canvas { ctx, _ in
                    drawDotGrid(in: &ctx, cols: cols, rows: rows)
                }

                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                        Canvas { ctx, _ in
                            let now = timeline.date
                            advance(now: now, cols: cols, rows: rows)
                            drawTraces(in: &ctx, now: now)
                            drawPulses(in: &ctx, now: now)
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

    private func drawTraces(in ctx: inout GraphicsContext, now: Date) {
        // Orange core + faint glow.
        let core = Color(red: 0.98, green: 0.42, blue: 0.18)
        for trace in traces {
            let t = trace.progress(now: now)
            guard t > 0 else { continue }
            let path = trace.partialPath(
                progress: t,
                pointFor: { pointFor($0) }
            )
            // Wide soft glow
            ctx.stroke(path,
                with: .color(core.opacity(0.18)),
                style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .miter)
            )
            // Core stroke
            ctx.stroke(path,
                with: .color(core.opacity(0.95)),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .miter)
            )
            // Bright moving head — the small dot at the leading
            // edge so traces feel like they're traveling. Compute
            // inline using the same Manhattan walk as partialPath.
            let head: CGPoint = {
                let segments = trace.waypoints.count - 1
                guard segments > 0 else { return pointFor(trace.waypoints[0]) }
                let segT = t * Double(segments)
                let segIdx = min(segments - 1, Int(segT))
                let localT = min(1.0, max(0.0, segT - Double(segIdx)))
                let a = pointFor(trace.waypoints[segIdx])
                let b = pointFor(trace.waypoints[segIdx + 1])
                return CGPoint(
                    x: a.x + (b.x - a.x) * CGFloat(localT),
                    y: a.y + (b.y - a.y) * CGFloat(localT)
                )
            }()
            let r: CGFloat = 2.5
            ctx.fill(
                Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2)),
                with: .color(core)
            )
        }
    }

    private func drawPulses(in ctx: inout GraphicsContext, now: Date) {
        let core = Color(red: 0.98, green: 0.42, blue: 0.18)
        for pulse in pulses {
            let age = now.timeIntervalSince(pulse.bornAt)
            guard age >= 0, age <= pulse.duration else { continue }
            let t = age / pulse.duration
            let p = pointFor(pulse.at)
            let radius: CGFloat = 4 + CGFloat(t) * 26
            let alpha = (1 - t) * 0.85
            ctx.stroke(
                Path(ellipseIn: CGRect(
                    x: p.x - radius, y: p.y - radius,
                    width: radius * 2, height: radius * 2
                )),
                with: .color(core.opacity(alpha)),
                lineWidth: 1.6
            )
            // Brighten the dot itself momentarily
            let dotR: CGFloat = 3
            ctx.fill(
                Path(ellipseIn: CGRect(
                    x: p.x - dotR, y: p.y - dotR,
                    width: dotR * 2, height: dotR * 2
                )),
                with: .color(core.opacity(1 - t))
            )
        }
    }

    // MARK: - State machine

    private func advance(now: Date, cols: Int, rows: Int) {
        // Drop expired.
        traces.removeAll { now.timeIntervalSince($0.startedAt) > traceLifetime }
        pulses.removeAll { now.timeIntervalSince($0.bornAt) > $0.duration }

        // Pick a new attention target if expired or first run.
        if attention == nil ||
           now.timeIntervalSince(attentionStarted) > attentionLifetime {
            attention = randomGrid(cols: cols, rows: rows)
            attentionStarted = now
        }

        // Trace arrivals → pulse at end, and the attention point
        // becomes a *source* for the next wave (so attention
        // "scatters" outward from where it just landed).
        var scatterSources: [GridPoint] = []
        for idx in traces.indices {
            if !traces[idx].arrived && traces[idx].progress(now: now) >= 1.0 {
                traces[idx].arrived = true
                pulses.append(Pulse(at: traces[idx].endNode, bornAt: now, duration: 0.55))
                scatterSources.append(traces[idx].endNode)
            }
        }

        // Spawn new traces.
        let sinceSpawn = now.timeIntervalSince(lastSpawnAt) * 1000
        guard traces.count < maxActiveTraces, Int(sinceSpawn) >= spawnIntervalMs else { return }
        guard let target = attention else { return }
        // Bias: 70% inbound to current attention, 30% outbound
        // from a recently-arrived dot to a fresh random target —
        // gives the "scatters and re-collects" feel.
        let outbound = !scatterSources.isEmpty && Double.random(in: 0...1) < 0.3
        let (start, end): (GridPoint, GridPoint) = {
            if outbound, let from = scatterSources.randomElement() {
                let to = randomGrid(cols: cols, rows: rows, avoiding: from)
                return (from, to ?? target)
            }
            // Inbound: random source dot, end = attention.
            let from = randomGrid(cols: cols, rows: rows, avoiding: target) ?? randomGrid(cols: cols, rows: rows)!
            return (from, target)
        }()
        traces.append(makeTrace(start: start, end: end, startedAt: now))
        lastSpawnAt = now
    }

    private func randomGrid(cols: Int, rows: Int, avoiding: GridPoint? = nil) -> GridPoint? {
        for _ in 0..<10 {
            let g = GridPoint(
                col: Int.random(in: 0..<cols),
                row: Int.random(in: 0..<rows)
            )
            if g != avoiding { return g }
        }
        return GridPoint(col: 0, row: 0)
    }

    /// Build a Manhattan-routed trace: start → optional intermediate
    /// bend at the corner formed by either (start.col, end.row) or
    /// (end.col, start.row), chosen at random for variety → end.
    /// If start and end share a row or column the route is a
    /// single straight segment.
    private func makeTrace(start: GridPoint, end: GridPoint, startedAt: Date) -> Trace {
        var nodes: [GridPoint] = [start]
        if start.col != end.col && start.row != end.row {
            let bend: GridPoint
            if Bool.random() {
                bend = GridPoint(col: end.col, row: start.row)
            } else {
                bend = GridPoint(col: start.col, row: end.row)
            }
            nodes.append(bend)
        }
        nodes.append(end)
        return Trace(
            waypoints: nodes,
            startedAt: startedAt,
            lifetime: traceLifetime,
            arrived: false
        )
    }
}

// MARK: - Data

private struct GridPoint: Equatable, Hashable {
    let col: Int
    let row: Int
}

private struct Trace {
    /// Manhattan waypoints (grid coordinates), 2 or 3 of them.
    let waypoints: [GridPoint]
    let startedAt: Date
    let lifetime: Double
    var arrived: Bool

    var endNode: GridPoint { waypoints.last ?? waypoints[0] }

    func progress(now: Date) -> Double {
        let age = now.timeIntervalSince(startedAt)
        return min(1.0, max(0.0, age / lifetime))
    }

    /// Path along the Manhattan waypoints up to fraction t (0…1).
    /// Segments are weighted equally — the visual cadence is
    /// dominated by the first segment, then the bend, then the
    /// final approach. Easing isn't applied per-segment because
    /// Manhattan routes already produce a clean stepped feel.
    func partialPath(
        progress t: Double,
        pointFor: (GridPoint) -> CGPoint
    ) -> Path {
        var path = Path()
        guard waypoints.count >= 2 else { return path }
        let segments = waypoints.count - 1
        path.move(to: pointFor(waypoints[0]))
        let totalT = t
        let segT = totalT * Double(segments)
        for i in 0..<segments {
            let segStart = pointFor(waypoints[i])
            let segEnd = pointFor(waypoints[i + 1])
            let localT = min(1.0, max(0.0, segT - Double(i)))
            if localT <= 0 { break }
            let x = segStart.x + (segEnd.x - segStart.x) * CGFloat(localT)
            let y = segStart.y + (segEnd.y - segStart.y) * CGFloat(localT)
            if i == 0 {
                // Already at segStart from move(to:). Just draw.
            }
            path.addLine(to: CGPoint(x: x, y: y))
            if localT < 1 { break }
        }
        return path
    }
}

private struct Pulse {
    let at: GridPoint
    let bornAt: Date
    let duration: Double
}
