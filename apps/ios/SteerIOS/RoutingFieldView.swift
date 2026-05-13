import SwiftUI

/// Animated background for SignInPrompt. Each "walker" is a small
/// orange dot that traverses the grid one cell at a time, picking
/// a new direction every time it arrives at a dot. Slow, calm,
/// neural-network-y. The grid stays mostly quiet; a handful of
/// walkers drift through it.
///
/// Implementation: a fixed roster of walkers, each with its own
/// pre-rolled random walk (a `let` array of grid coordinates that
/// loops). At render time we compute which cell each walker is
/// currently in + how far it's progressed toward the next cell,
/// then draw a small dot + a faint trailing segment. No @State
/// mutation during rendering.

struct RoutingFieldView: View {
    /// 28pt between dots — slightly looser so a walker moving
    /// from cell to cell reads as actually traveling, not just
    /// blinking onto the next dot.
    private let dotSpacing: CGFloat = 28
    /// Seconds per single-cell step. 0.85 reads as "walking,"
    /// not "racing."
    private let stepDuration: Double = 0.85
    /// Number of independent walkers on the field. Few enough
    /// that you can follow individual ones; many enough that
    /// the field never feels empty.
    private let walkerCount: Int = 6
    /// Length of each walker's pre-rolled path. A long path with
    /// many bends — visually random over the loop.
    private let walkLength: Int = 80

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let epoch: Date = Date()
    private let walkers: [Walker]

    init() {
        var rng = SystemRandomNumberGenerator()
        // Virtual grid larger than any phone so walkers can
        // wander; cells outside the visible bounds are wrapped
        // at render time.
        let cols = 18
        let rows = 36
        var roster: [Walker] = []
        roster.reserveCapacity(walkerCount)
        for w in 0..<walkerCount {
            var path: [GridPoint] = []
            path.reserveCapacity(walkLength)
            // Start at a random cell.
            var current = GridPoint(
                col: Int.random(in: 0..<cols, using: &rng),
                row: Int.random(in: 0..<rows, using: &rng)
            )
            path.append(current)
            // Last direction so we don't go back the way we came
            // every step (would just hop between two dots).
            var lastDir: (dx: Int, dy: Int)? = nil
            for _ in 1..<walkLength {
                let directions: [(dx: Int, dy: Int)] = [
                    (1, 0), (-1, 0), (0, 1), (0, -1)
                ]
                var candidates = directions
                if let last = lastDir {
                    candidates.removeAll { $0.dx == -last.dx && $0.dy == -last.dy }
                }
                // Stay in bounds (don't walk off the virtual grid).
                candidates.removeAll { dir in
                    let nc = current.col + dir.dx
                    let nr = current.row + dir.dy
                    return nc < 0 || nc >= cols || nr < 0 || nr >= rows
                }
                // Pick randomly. Skip-empty fallback covers
                // pathological corner cases.
                let dir = candidates.randomElement(using: &rng) ?? (1, 0)
                current = GridPoint(
                    col: current.col + dir.dx,
                    row: current.row + dir.dy
                )
                path.append(current)
                lastDir = dir
            }
            // Stagger walkers' start phases so they don't all
            // hit cells at the same instant.
            let phase = Double(w) / Double(walkerCount) * stepDuration
            roster.append(Walker(path: path, phaseOffset: phase))
        }
        self.walkers = roster
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
                            drawWalkers(in: &ctx, elapsed: elapsed, cols: cols, rows: rows)
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .drawingGroup()
    }

    private func pointFor(_ g: GridPoint, cols: Int, rows: Int) -> CGPoint {
        // Wrap virtual coords onto the visible grid so walkers
        // that wandered off-screen reappear on the other side.
        let c = ((g.col % cols) + cols) % cols
        let r = ((g.row % rows) + rows) % rows
        return CGPoint(
            x: CGFloat(c) * dotSpacing + dotSpacing / 2,
            y: CGFloat(r) * dotSpacing + dotSpacing / 2
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
                let p = pointFor(GridPoint(col: c, row: r), cols: cols, rows: rows)
                let rect = CGRect(x: p.x - 1.2, y: p.y - 1.2, width: 2.4, height: 2.4)
                ctx.fill(Path(ellipseIn: rect), with: .color(dotColor))
            }
        }
    }

    private func drawWalkers(
        in ctx: inout GraphicsContext,
        elapsed: Double,
        cols: Int,
        rows: Int
    ) {
        let core = Color(red: 0.98, green: 0.42, blue: 0.18)

        for walker in walkers {
            // Walker's local time, staggered.
            let t = elapsed + walker.phaseOffset
            let totalSteps = walker.path.count
            // Loop the path infinitely.
            let stepFloat = t / stepDuration
            let stepIndex = Int(stepFloat) % totalSteps
            let localT = stepFloat - floor(stepFloat) // 0..1 within this step

            let fromGrid = walker.path[stepIndex]
            let toGrid = walker.path[(stepIndex + 1) % totalSteps]
            let from = pointFor(fromGrid, cols: cols, rows: rows)
            let to = pointFor(toGrid, cols: cols, rows: rows)

            // Skip the segment if the wrap put it across the
            // edge — drawing a line from (0, *) to (cols-1, *)
            // visually streaks across the screen.
            let dx = abs(to.x - from.x)
            let dy = abs(to.y - from.y)
            let acrossWrap = dx > dotSpacing * 2 || dy > dotSpacing * 2

            // Current walker position.
            let cx = from.x + (to.x - from.x) * CGFloat(localT)
            let cy = from.y + (to.y - from.y) * CGFloat(localT)
            let pos = CGPoint(x: cx, y: cy)

            if !acrossWrap {
                // Faint trail: a short line from the previous dot
                // up to the walker's current position.
                var trail = Path()
                trail.move(to: from)
                trail.addLine(to: pos)
                ctx.stroke(trail,
                    with: .color(core.opacity(0.35)),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
                )
            }

            // The walker dot itself — a small bright orange ball.
            let r: CGFloat = 3
            let dotRect = CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2)
            // Soft halo around the dot.
            let haloRect = CGRect(x: pos.x - 8, y: pos.y - 8, width: 16, height: 16)
            ctx.fill(Path(ellipseIn: haloRect), with: .color(core.opacity(0.18)))
            ctx.fill(Path(ellipseIn: dotRect), with: .color(core.opacity(0.95)))
        }
    }
}

// MARK: - Data

private struct GridPoint: Equatable, Hashable {
    let col: Int
    let row: Int
}

private struct Walker {
    /// Pre-rolled grid path. Each consecutive pair is one
    /// orthogonal cell step. The walker loops this path forever.
    let path: [GridPoint]
    /// Time offset (s) so walkers' steps don't sync up.
    let phaseOffset: Double
}
