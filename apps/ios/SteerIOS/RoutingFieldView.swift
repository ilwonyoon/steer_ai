import SwiftUI

/// Animated background for SignInPrompt. Instead of drawing lines,
/// the dot grid *itself* becomes the canvas: each dot brightens
/// based on its proximity to a slowly-drifting blob of "attention."
/// The blob travels upward across the field, deforming gently as
/// it moves, with two or three smaller satellite blobs adding
/// texture. Reads as a soft glow rolling through the grid — like
/// activity rippling across a neural sheet.
///
/// Visual intent:
///   - Subtle. Dots never become the foreground.
///   - Upward motion (the user explicitly asked for bottom → top).
///   - Organic. Blobs ease, breathe, fade. No sharp transitions.
///   - "Attention routing" is conveyed through *which dots are
///     lit*, not through drawn paths.

struct RoutingFieldView: View {
    /// 1.5× denser than the previous 24pt — each dot now sits
    /// 16pt from its neighbor. Reads as a fine mesh that the
    /// blob highlights can paint across smoothly.
    private let dotSpacing: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let epoch: Date = Date()
    private let blobs: [Blob]

    init() {
        var rng = SystemRandomNumberGenerator()
        // Three blobs: one primary doing the main bottom→top drift,
        // two smaller satellites following slightly offset paths so
        // the field has texture rather than a single blob moving.
        var roster: [Blob] = []
        roster.reserveCapacity(3)
        for i in 0..<3 {
            let phase = Double(i) / 3.0
            // Slower again — 22 s per bottom→top traversal. Reads
            // as a drifting ambient field, not a moving spotlight.
            let cycleSeconds = 22.0 + Double.random(in: -1.2...1.2, using: &rng)
            let xCenter = 0.20 + Double(i) * 0.30
            let xWobbleAmp = 0.08 + Double.random(in: -0.02...0.02, using: &rng)
            let xWobbleSpeed = 0.22 + Double.random(in: -0.04...0.04, using: &rng)
            // Smaller blobs so the highlight is a soft region,
            // not the entire screen. Dots still stay constant.
            let radius = 95.0 + (i == 0 ? 15.0 : -10.0)
            let strength = (i == 0 ? 0.9 : 0.55)
            // Each blob gets its own deformation seed + phase so
            // the lobes don't sync up across the three blobs.
            let deformPhase = Double.random(in: 0..<(2 * .pi), using: &rng)
            let deformSeed = Double.random(in: 0..<100, using: &rng)
            roster.append(Blob(
                cycleSeconds: cycleSeconds,
                phase: phase,
                xCenterNorm: xCenter,
                xWobbleAmpNorm: xWobbleAmp,
                xWobbleSpeed: xWobbleSpeed,
                radius: radius,
                strength: strength,
                deformPhase: deformPhase,
                deformSeed: deformSeed
            ))
        }
        self.blobs = roster
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let cols = max(2, Int(size.width / dotSpacing))
            let rows = max(2, Int(size.height / dotSpacing))

            if reduceMotion {
                Canvas { ctx, _ in
                    drawStaticGrid(in: &ctx, cols: cols, rows: rows)
                }
                .ignoresSafeArea()
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                    Canvas { ctx, _ in
                        let elapsed = timeline.date.timeIntervalSince(epoch)
                        drawGrid(in: &ctx, elapsed: elapsed,
                                 size: size, cols: cols, rows: rows)
                    }
                }
                .ignoresSafeArea()
                .drawingGroup()
            }
        }
    }

    // MARK: - Drawing

    private func drawStaticGrid(
        in ctx: inout GraphicsContext,
        cols: Int,
        rows: Int
    ) {
        let dotColor = SteerColors.softSeparator
        for r in 0..<rows {
            for c in 0..<cols {
                let x = CGFloat(c) * dotSpacing + dotSpacing / 2
                let y = CGFloat(r) * dotSpacing + dotSpacing / 2
                let rect = CGRect(x: x - 1.0, y: y - 1.0, width: 2.0, height: 2.0)
                ctx.fill(Path(ellipseIn: rect), with: .color(dotColor))
            }
        }
    }

    private func drawGrid(
        in ctx: inout GraphicsContext,
        elapsed: Double,
        size: CGSize,
        cols: Int,
        rows: Int
    ) {
        // Pre-compute each blob's render data for this frame.
        struct Live {
            let pos: CGPoint
            let radius: Double
            let strength: Double
            let deformPhase: Double
            let deformTime: Double
        }
        let live: [Live] = blobs.map { blob in
            let t = ((elapsed / blob.cycleSeconds) + blob.phase)
                .truncatingRemainder(dividingBy: 1.0)
            let yEased = smoothstep(t)
            let yPx = size.height * (1.15 - yEased * 1.30)
            let wobble = sin(elapsed * blob.xWobbleSpeed + blob.phase * .pi * 2)
            let xNorm = blob.xCenterNorm + blob.xWobbleAmpNorm * wobble
            let xPx = size.width * CGFloat(xNorm)
            return Live(
                pos: CGPoint(x: xPx, y: yPx),
                radius: blob.radius,
                strength: blob.strength,
                deformPhase: blob.deformPhase,
                deformTime: elapsed * 0.35 + blob.deformSeed
            )
        }

        // Color the active orange + the dim baseline. Each dot's
        // alpha + radius interpolates between the two based on the
        // strongest blob's local influence.
        let active = Color(red: 0.98, green: 0.42, blue: 0.18)
        let baseline = SteerColors.softSeparator

        for r in 0..<rows {
            for c in 0..<cols {
                let x = CGFloat(c) * dotSpacing + dotSpacing / 2
                let y = CGFloat(r) * dotSpacing + dotSpacing / 2

                // Influence = max over all blobs of an
                // angle-modulated radial falloff. The blob's
                // effective radius along a given bearing is the
                // base radius shaped by two superposed low-freq
                // sin waves; the waves slowly drift in time
                // (`deformTime`) so the lobes shift instead of
                // being statically lumpy. Net effect: the blob's
                // outline ripples organically rather than being
                // a perfect circle.
                var influence: Double = 0
                for blob in live {
                    let dx = Double(x - blob.pos.x)
                    let dy = Double(y - blob.pos.y)
                    let d = sqrt(dx * dx + dy * dy)
                    let angle = atan2(dy, dx)
                    // Two lobes (3-fold + 5-fold) summed give an
                    // amoeba shape; amplitudes are fractions of
                    // the base radius so the blob still reads as
                    // "around this size."
                    let lobe = sin(angle * 3 + blob.deformTime + blob.deformPhase) * 0.18
                              + sin(angle * 5 + blob.deformTime * 1.4) * 0.10
                    let r = blob.radius * (1.0 + lobe)
                    guard d < r else { continue }
                    let local = (1 - d / r) * blob.strength
                    if local > influence { influence = local }
                }
                // Soften the falloff so the edge is diffuse.
                let eased = pow(influence, 1.8)

                // Dot SIZE stays constant — the field's visual
                // variety lives entirely in color + alpha. Growing
                // dots read as "the grid is breathing"; constant
                // dots with shifting tint read as "a wave is
                // passing through."
                let radius: CGFloat = 1.2
                let rect = CGRect(x: x - radius, y: y - radius,
                                  width: radius * 2, height: radius * 2)
                let alpha: Double
                let color: Color
                if eased > 0.02 {
                    alpha = 0.35 + eased * 0.55
                    color = active
                } else {
                    alpha = 0.45
                    color = baseline
                }
                ctx.fill(Path(ellipseIn: rect),
                         with: .color(color.opacity(alpha)))
            }
        }
    }
}

// MARK: - Data + helpers

private struct Blob {
    /// How long one bottom-to-top cycle takes.
    let cycleSeconds: Double
    /// Where in the cycle this blob starts (0..1).
    let phase: Double
    /// Average column position, in 0..1 across screen width.
    let xCenterNorm: Double
    /// Peak lateral wobble around `xCenterNorm`, in 0..1.
    let xWobbleAmpNorm: Double
    /// Wobble frequency (radians/sec).
    let xWobbleSpeed: Double
    /// Influence radius in points (base, before deformation).
    let radius: Double
    /// Brightness multiplier (0..1).
    let strength: Double
    /// Per-blob deformation phase offset so the lobes of
    /// different blobs aren't synchronized.
    let deformPhase: Double
    /// Initial deformation seed so the lobes don't start in the
    /// same configuration at the loop boundary.
    let deformSeed: Double
}

/// Classic smoothstep — eases t at both 0 and 1.
private func smoothstep(_ t: Double) -> Double {
    let x = max(0.0, min(1.0, t))
    return x * x * (3 - 2 * x)
}
