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
            // Halved speed: 7s → 14s per traversal. Reads as a
            // slow, ambient wave rather than a fast cycle.
            let cycleSeconds = 14.0 + Double.random(in: -0.8...0.8, using: &rng)
            let xCenter = 0.20 + Double(i) * 0.30
            let xWobbleAmp = 0.10 + Double.random(in: -0.03...0.03, using: &rng)
            // Lateral wobble also slower — proportional to cycle.
            let xWobbleSpeed = 0.3 + Double.random(in: -0.05...0.05, using: &rng)
            // Wider blobs so the highlight gradient covers more
            // grid cells before falling off. Dots themselves stay
            // a fixed size; only the gradient extent grows.
            let radius = 150.0 + (i == 0 ? 30.0 : -20.0)
            let strength = (i == 0 ? 1.0 : 0.6)
            roster.append(Blob(
                cycleSeconds: cycleSeconds,
                phase: phase,
                xCenterNorm: xCenter,
                xWobbleAmpNorm: xWobbleAmp,
                xWobbleSpeed: xWobbleSpeed,
                radius: radius,
                strength: strength
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
        // Compute current blob positions once per frame.
        let centers: [(pos: CGPoint, radius: CGFloat, strength: Double)] = blobs.map { blob in
            // y travels bottom → top over cycleSeconds, with a
            // smoothstep so the blob slows near both edges.
            let t = ((elapsed / blob.cycleSeconds) + blob.phase)
                .truncatingRemainder(dividingBy: 1.0)
            let yEased = smoothstep(t)
            // Start a bit below the visible area and end a bit
            // above, so the blob is never "popping in" at the edges.
            let yPx = size.height * (1.15 - yEased * 1.30)
            // Lateral wobble — sin curve on its own slow timer.
            let wobble = sin(elapsed * blob.xWobbleSpeed + blob.phase * .pi * 2)
            let xNorm = blob.xCenterNorm + blob.xWobbleAmpNorm * wobble
            let xPx = size.width * CGFloat(xNorm)
            return (CGPoint(x: xPx, y: yPx), CGFloat(blob.radius), blob.strength)
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

                // Influence = max over all blobs of (smooth radial
                // falloff). Single max so the brightest blob wins
                // visually; sum would blow out the saturation in
                // overlap regions.
                var influence: Double = 0
                for center in centers {
                    let dx = Double(x - center.pos.x)
                    let dy = Double(y - center.pos.y)
                    let d = sqrt(dx * dx + dy * dy)
                    let radius = Double(center.radius)
                    guard d < radius else { continue }
                    let local = (1 - d / radius) * center.strength
                    if local > influence { influence = local }
                }
                // Soften the falloff so the edge of each blob is
                // diffuse, not a circle.
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
    /// Influence radius in points.
    let radius: Double
    /// Brightness multiplier (0..1).
    let strength: Double
}

/// Classic smoothstep — eases t at both 0 and 1.
private func smoothstep(_ t: Double) -> Double {
    let x = max(0.0, min(1.0, t))
    return x * x * (3 - 2 * x)
}
