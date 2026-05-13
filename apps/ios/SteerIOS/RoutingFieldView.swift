import SwiftUI

/// Animated background for SignInPrompt. Four-beat looping motion
/// that visually narrates "attention routing":
///
///   Beat 1 — Gather  (0.0–1.5s)
///     6 thin orange traces ascend from scattered bottom dots,
///     each routing one Manhattan bend toward a 4-cell focus
///     cluster around the upper-middle of the screen. The trace
///     is drawn cell-by-cell, like a signal walking the grid.
///
///   Beat 2 — Focus   (1.5–2.0s)
///     The cluster's strokes briefly brighten. No new traces. The
///     accumulated lines from Beat 1 are now all sitting in place
///     so the eye sees them as a single converging "thought."
///
///   Beat 3 — Disperse (2.0–3.5s)
///     A smaller number (3) of traces leave from the focus cluster
///     and route upward to scattered top-edge dots, fading as
///     they go. The decision is dispatched outward.
///
///   Beat 4 — Quiet    (3.5–5.0s)
///     Everything fades. The dot grid stays. A brief breath
///     before the next gather.
///
/// Loop period: 5 s. Render is fully time-driven (no @State writes
/// inside Canvas). All randomness is realized once at init.

struct RoutingFieldView: View {
    private let dotSpacing: CGFloat = 28
    private let loopSeconds: Double = 5.0

    // Beat boundaries, in loop-seconds.
    private let gatherStart: Double = 0.0
    private let gatherEnd: Double = 1.5
    private let focusEnd: Double = 2.0
    private let disperseEnd: Double = 3.5
    // 5.0 = quiet end / loop start

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let epoch: Date = Date()
    /// Inbound traces (gather beat). Each is a Manhattan polyline
    /// starting near the bottom and ending inside the focus
    /// cluster. Drawn in proportion to gather-beat progress.
    private let gatherTraces: [Polyline]
    /// Outbound traces (disperse beat). Start inside the focus
    /// cluster and route up to the top edge.
    private let disperseTraces: [Polyline]
    /// The 2-by-2 focus cluster (4 cells) the gather traces
    /// converge into. Center of the screen, upper third.
    private let focusCells: [GridPoint]

    init() {
        var rng = SystemRandomNumberGenerator()
        // Virtual grid sized for any phone; cells outside the
        // visible area are skipped at render time.
        let cols = 16
        let rows = 32
        // Focus cluster — 2x2 around (cols/2, rows*0.35).
        let fc = cols / 2
        let fr = max(2, Int(Double(rows) * 0.35))
        let cluster = [
            GridPoint(col: fc - 1, row: fr),
            GridPoint(col: fc,     row: fr),
            GridPoint(col: fc - 1, row: fr + 1),
            GridPoint(col: fc,     row: fr + 1),
        ]
        self.focusCells = cluster

        // Six gather traces: each starts on a random column near
        // the bottom edge, then bends once toward a random cluster
        // cell.
        var gather: [Polyline] = []
        for _ in 0..<6 {
            let startCol = Int.random(in: 1..<(cols - 1), using: &rng)
            let startRow = rows - 1 - Int.random(in: 0..<3, using: &rng)
            let start = GridPoint(col: startCol, row: startRow)
            let end = cluster.randomElement(using: &rng)!
            gather.append(Polyline(waypoints: manhattan(start: start, end: end, rng: &rng)))
        }
        self.gatherTraces = gather

        // Three disperse traces.
        var disperse: [Polyline] = []
        for _ in 0..<3 {
            let start = cluster.randomElement(using: &rng)!
            let endCol = Int.random(in: 1..<(cols - 1), using: &rng)
            let endRow = Int.random(in: 0..<3, using: &rng)
            let end = GridPoint(col: endCol, row: endRow)
            disperse.append(Polyline(waypoints: manhattan(start: start, end: end, rng: &rng)))
        }
        self.disperseTraces = disperse
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let cols = max(2, Int(size.width / dotSpacing))
            let rows = max(2, Int(size.height / dotSpacing))

            ZStack {
                // Static dot grid — drawn once per resize. Subtle.
                Canvas { ctx, _ in
                    drawDotGrid(in: &ctx, cols: cols, rows: rows)
                }

                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                        Canvas { ctx, _ in
                            let elapsed = timeline.date.timeIntervalSince(epoch)
                            let loopT = elapsed.truncatingRemainder(dividingBy: loopSeconds)
                            drawBeats(in: &ctx, loopT: loopT, cols: cols, rows: rows)
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

    private func drawDotGrid(in ctx: inout GraphicsContext, cols: Int, rows: Int) {
        let dotColor = SteerColors.softSeparator.opacity(0.6)
        for r in 0..<rows {
            for c in 0..<cols {
                let p = pointFor(GridPoint(col: c, row: r))
                let rect = CGRect(x: p.x - 1.0, y: p.y - 1.0, width: 2.0, height: 2.0)
                ctx.fill(Path(ellipseIn: rect), with: .color(dotColor))
            }
        }
    }

    private func drawBeats(
        in ctx: inout GraphicsContext,
        loopT: Double,
        cols: Int,
        rows: Int
    ) {
        let core = Color(red: 0.98, green: 0.42, blue: 0.18)

        // Beat 1 — Gather (0..1.5s). Each trace draws cell-by-cell
        // proportional to the beat's progress. Stroke alpha rises
        // from 0 to ~0.35 over the beat.
        if loopT < gatherEnd {
            let beatT = loopT / gatherEnd // 0..1
            for trace in gatherTraces {
                guard trace.fitsIn(cols: cols, rows: rows) else { continue }
                let path = partialPath(trace.waypoints, progress: beatT)
                let alpha = 0.10 + beatT * 0.25
                ctx.stroke(path,
                    with: .color(core.opacity(alpha)),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .miter)
                )
            }
        }
        // Beat 2 — Focus (1.5..2.0s). All gather traces fully
        // drawn; their stroke briefly brightens then settles.
        else if loopT < focusEnd {
            let beatT = (loopT - gatherEnd) / (focusEnd - gatherEnd) // 0..1
            // Brighten-then-soften: peak alpha at midpoint.
            let alpha = 0.35 + sin(beatT * .pi) * 0.25
            for trace in gatherTraces {
                guard trace.fitsIn(cols: cols, rows: rows) else { continue }
                let path = partialPath(trace.waypoints, progress: 1.0)
                ctx.stroke(path,
                    with: .color(core.opacity(alpha)),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .miter)
                )
            }
            // Soft halo on the focus cluster itself.
            for cell in focusCells {
                let p = pointFor(cell)
                let haloRect = CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)
                ctx.fill(Path(ellipseIn: haloRect), with: .color(core.opacity(alpha * 0.4)))
            }
        }
        // Beat 3 — Disperse (2.0..3.5s). Gather traces fade out
        // while disperse traces draw outward. Smooth handoff.
        else if loopT < disperseEnd {
            let beatT = (loopT - focusEnd) / (disperseEnd - focusEnd) // 0..1
            // Gather traces fade from 0.35 -> 0.
            let gatherAlpha = 0.35 * (1 - beatT)
            if gatherAlpha > 0.02 {
                for trace in gatherTraces {
                    guard trace.fitsIn(cols: cols, rows: rows) else { continue }
                    let path = partialPath(trace.waypoints, progress: 1.0)
                    ctx.stroke(path,
                        with: .color(core.opacity(gatherAlpha)),
                        style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .miter)
                    )
                }
            }
            // Disperse traces draw in.
            let disperseAlpha = 0.10 + beatT * 0.25
            for trace in disperseTraces {
                guard trace.fitsIn(cols: cols, rows: rows) else { continue }
                let path = partialPath(trace.waypoints, progress: beatT)
                ctx.stroke(path,
                    with: .color(core.opacity(disperseAlpha)),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .miter)
                )
            }
        }
        // Beat 4 — Quiet (3.5..5.0s). Everything fades to nothing.
        else {
            let beatT = (loopT - disperseEnd) / (loopSeconds - disperseEnd) // 0..1
            let alpha = 0.35 * (1 - beatT)
            if alpha > 0.02 {
                for trace in disperseTraces {
                    guard trace.fitsIn(cols: cols, rows: rows) else { continue }
                    let path = partialPath(trace.waypoints, progress: 1.0)
                    ctx.stroke(path,
                        with: .color(core.opacity(alpha)),
                        style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .miter)
                    )
                }
            }
        }
    }

    /// Path along Manhattan waypoints up to fraction t.
    private func partialPath(_ waypoints: [GridPoint], progress t: Double) -> Path {
        var path = Path()
        guard waypoints.count >= 2 else { return path }
        let segments = waypoints.count - 1
        let segT = t * Double(segments)
        path.move(to: pointFor(waypoints[0]))
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
}

// MARK: - Data + helpers

private struct GridPoint: Equatable, Hashable {
    let col: Int
    let row: Int
}

private struct Polyline {
    let waypoints: [GridPoint]

    func fitsIn(cols: Int, rows: Int) -> Bool {
        waypoints.allSatisfy { $0.col >= 0 && $0.col < cols && $0.row >= 0 && $0.row < rows }
    }
}

/// 2- or 3-point Manhattan route between two grid cells. Same-row /
/// same-col pairs become a 2-point straight line; otherwise we
/// insert a single corner bend at one of the two L-shapes.
private func manhattan(
    start: GridPoint,
    end: GridPoint,
    rng: inout SystemRandomNumberGenerator
) -> [GridPoint] {
    if start.col == end.col || start.row == end.row {
        return [start, end]
    }
    let bend: GridPoint
    if Bool.random(using: &rng) {
        bend = GridPoint(col: end.col, row: start.row)
    } else {
        bend = GridPoint(col: start.col, row: end.row)
    }
    return [start, bend, end]
}
