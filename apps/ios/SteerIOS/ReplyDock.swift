import SwiftUI

/// Visual treatments for the "I'm listening" state — all four
/// variants live ENTIRELY on the input field's outline. The text
/// area is never touched: no overlays inside the field, no padding
/// shifts, no opacity changes on the TextField itself. The signal
/// that dictation is live comes from the border alone.
enum DictationVisualStyle: String, CaseIterable, Identifiable {
    /// Accent stroke with opacity + width pulsing on a slow ease.
    case outlinePulse
    /// Siri-style soft blurred halo blooming outside the rounded
    /// rect, breathing slowly.
    case edgeGlow
    /// The stroke path itself ripples — a sinusoidal offset on the
    /// rounded-rect outline that reacts to mic amplitude.
    case organicWaves
    /// Accent dash runs around the perimeter like a tracer. Speed
    /// is modulated by mic amplitude.
    case traceRunner

    var id: String { rawValue }
    var label: String {
        switch self {
        case .outlinePulse:  return "Pulse"
        case .edgeGlow:      return "Glow"
        case .organicWaves:  return "Waves"
        case .traceRunner:   return "Trace"
        }
    }
}

/// iOS port of the Mac ReplyDock. Drops the Mac-only AppKit pieces
/// (clipboard image monitor, NSItemProvider drag-and-drop,
/// .onKeyPress(.return)) and keeps the visual + send semantics:
///   - rounded inputFill background with softSeparator stroke
///   - 13pt monospaced placeholder ("reply to this session")
///   - chip row above input
///   - floating bottom-right send button that appears only when canSend
///   - in-card mic button (v2) driven by `DictationController`
struct ReplyDock: View {
    @Binding var reply: String
    let onSend: (String) -> Void
    var tint: Color = SteerColors.inputFill
    /// Override for the TextField placeholder. Real cards leave this
    /// nil and get the default ("reply to this session"); onboarding
    /// cards pass the suggested next word ("next" / "done") so the
    /// user sees inline what to type to advance.
    var placeholder: String? = nil
    /// External @FocusState owned by the parent. We bind the TextField
    /// directly to it so the parent can both observe changes and
    /// programmatically dismiss the keyboard.
    var externalFocus: FocusState<Bool>.Binding? = nil
    /// When true, the send button shows even with empty text. Used
    /// by the onboarding flow so "just hit send →" works literally.
    /// The flow propagates this via the environment; this struct
    /// reads the env value and ORs it in.
    var allowEmptySend: Bool = false
    /// Hide the mic button entirely. Onboarding / demo flows use
    /// this so the user can't tap into the real permission +
    /// recognizer machinery from a tutorial card.
    var dictationEnabled: Bool = true
    /// Which native-inspired visual to use for the listening state.
    /// Configurable per-mount so the dogfood comparison page can
    /// flip between them.
    var dictationStyle: DictationVisualStyle = .outlinePulse
    @Environment(\.onboardingAllowEmptySend) private var envAllowEmpty: Bool
    @FocusState private var fallbackFocus: Bool

    @StateObject private var dictation = DictationController()
    @State private var showDeniedAlert: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            inputFieldContainer
            if case .failed(let reason) = dictation.state, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SteerColors.blocked)
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                    .lineLimit(3)
            }
        }
        .animation(.easeOut(duration: 0.16), value: canSend)
        .animation(.easeOut(duration: 0.16), value: dictation.state)
        .onChange(of: dictation.partialText) { _, newValue in
            // The controller is the writer while listening; mirror
            // its composed string into the reply binding so the
            // transcript appears live in the TextField.
            if dictation.state == .listening {
                reply = newValue
            }
        }
        .onChange(of: dictation.state) { _, newState in
            if newState == .denied {
                showDeniedAlert = true
            }
        }
        .onDisappear { dictation.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && dictation.state == .listening {
                dictation.stop()
            }
        }
        .alert(
            "Microphone access required",
            isPresented: $showDeniedAlert,
            actions: {
                Button("Open Settings") { dictation.openSettings() }
                Button("Cancel", role: .cancel) {}
            },
            message: {
                Text("Steer needs Microphone and Speech Recognition permissions to dictate replies. Enable both in Settings, then tap the mic again.")
            }
        )
    }

    private var borderStroke: Color {
        dictation.state == .listening ? Color.accentColor : SteerColors.softSeparator
    }
    private var borderWidth: CGFloat {
        dictation.state == .listening ? 1.5 : 1
    }

    private var trimmedReply: String {
        reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var effectiveAllowEmpty: Bool { allowEmptySend || envAllowEmpty }
    private var canSend: Bool {
        if effectiveAllowEmpty { return true }
        return !trimmedReply.isEmpty
    }
    /// Send is hidden while dictation is running — pressing send on
    /// a half-recognized transcript is the worst failure mode.
    private var showSend: Bool {
        canSend && dictation.state != .listening
    }

    private func submit() {
        let text = trimmedReply
        if !effectiveAllowEmpty && text.isEmpty { return }
        onSend(text)
        reply = ""
        externalFocus?.wrappedValue = false
        fallbackFocus = false
    }

    /// The full input row. Critical invariant: the TextField is
    /// always mounted and never has its padding / opacity changed
    /// by the dictation state. All "I'm listening" signals live
    /// on the border layer only.
    @ViewBuilder
    private var inputFieldContainer: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint)
            textField
            HStack(spacing: 6) {
                if dictationEnabled {
                    micButton
                }
                if showSend {
                    sendButton
                }
            }
            .padding(.trailing, 8)
            .padding(.bottom, 8)
        }
        .overlay {
            inputBorder
        }
    }

    /// Always-mounted TextField — same shape regardless of dictation
    /// state.
    @ViewBuilder
    private var textField: some View {
        let base = TextField(placeholder ?? "Reply to this session", text: $reply, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 17))
            .foregroundStyle(SteerColors.ink)
            .lineLimit(1...8)
            .accessibilityIdentifier("reply-input")
            .padding(.leading, 14)
            .padding(.trailing, dictationEnabled ? (showSend ? 84 : 46) : (showSend ? 48 : 14))
            .padding(.vertical, 12)
            .frame(minHeight: 48)

        if let externalFocus {
            base.focused(externalFocus)
        } else {
            base.focused($fallbackFocus)
        }
    }

    /// Border treatment. Idle / failed → simple stroke. Listening →
    /// one of four outline-only animations driven by the active
    /// dictationStyle. None of these touch the text area.
    @ViewBuilder
    private var inputBorder: some View {
        if dictation.state == .listening {
            switch dictationStyle {
            case .outlinePulse:
                PulsingBorder(color: .accentColor)
            case .edgeGlow:
                EdgeGlowBorder(color: .accentColor)
            case .organicWaves:
                OrganicWavesBorder(color: .accentColor, level: dictation.audioLevel)
            case .traceRunner:
                TraceRunnerBorder(color: .accentColor, level: dictation.audioLevel)
            }
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderStroke, lineWidth: borderWidth)
        }
    }

    private var micButton: some View {
        Button(action: handleMicTap) {
            Image(systemName: micIconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(micIconColor)
                // Keep the 32x32 hit area but render only the
                // glyph — no background disc. contentShape(.rect)
                // makes the whole square tappable so the touch
                // target survives the visual cleanup.
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reply-mic")
        .accessibilityLabel(dictation.state == .listening ? "Stop dictation" : "Start dictation")
        .disabled(dictation.state == .requestingPermission)
    }

    private var micIconName: String {
        switch dictation.state {
        case .listening: return "stop.fill"
        case .requestingPermission: return "hourglass"
        default: return "mic.fill"
        }
    }
    private var micIconColor: Color {
        switch dictation.state {
        case .listening: return Color.accentColor   // stop glyph in accent
        case .denied: return SteerColors.blocked
        default: return SteerColors.secondaryInk
        }
    }

    private func handleMicTap() {
        switch dictation.state {
        case .idle, .failed:
            Task { @MainActor in
                let result = await dictation.requestAuthorizations()
                guard result == .authorized else {
                    // The state machine flips to .denied via the alert
                    // sink — we just need to set it.
                    dictation.objectWillChange.send()
                    showDeniedAlert = true
                    return
                }
                dictation.start(appendingTo: reply)
            }
        case .listening:
            dictation.stop()
        case .denied:
            showDeniedAlert = true
        case .requestingPermission:
            break
        }
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.accentColor, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reply-send")
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel("Send reply")
    }
}

/// Variant 1 — Minimal accent stroke that pulses in opacity and
/// line width.
private struct PulsingBorder: View {
    let color: Color
    @State private var pulse: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(color.opacity(pulse ? 1.0 : 0.4), lineWidth: pulse ? 2.4 : 1.4)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

/// Variant 2 — Siri-style outer glow. Solid border + a wider
/// blurred ring breathing behind it.
private struct EdgeGlowBorder: View {
    let color: Color
    @State private var breathe: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(color, lineWidth: 1.5)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(color.opacity(breathe ? 0.55 : 0.15), lineWidth: 6)
                .blur(radius: 6)
                .scaleEffect(breathe ? 1.02 : 1.0)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

/// Variant 3 — Organic waves. The outline path itself ripples on
/// the top and bottom edges, with amplitude tied to live mic
/// level. Built as a stroked Shape so the deformation lives on
/// the path, not on an overlay.
private struct OrganicWavesBorder: View {
    let color: Color
    let level: Float
    @State private var phase: CGFloat = 0

    var body: some View {
        WavyRoundedRect(cornerRadius: 12, amplitude: amplitude, frequency: 3, phase: phase)
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            .onAppear {
                withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                    phase = .pi * 2
                }
            }
    }

    private var amplitude: CGFloat {
        // Idle floor so the waves are always visible, plus mic
        // level so loud speech actually flexes the border.
        1.0 + CGFloat(level) * 4.0
    }
}

private struct WavyRoundedRect: Shape {
    var cornerRadius: CGFloat
    var amplitude: CGFloat
    var frequency: CGFloat
    var phase: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(phase, amplitude) }
        set { phase = newValue.first; amplitude = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(cornerRadius, rect.height / 2)
        let top = rect.minY
        let bottom = rect.maxY
        let left = rect.minX
        let right = rect.maxX

        // Sample the top and bottom edges with a small sine wave;
        // sides stay straight so the rounded rect shape reads as
        // an input field.
        let segments: CGFloat = 40
        // Top edge (left→right) with wave.
        p.move(to: CGPoint(x: left + r, y: top))
        for i in 0...Int(segments) {
            let t = CGFloat(i) / segments
            let x = (left + r) + t * (rect.width - 2 * r)
            let y = top + sin(t * frequency * .pi * 2 + phase) * amplitude
            p.addLine(to: CGPoint(x: x, y: y))
        }
        // Top-right corner.
        p.addArc(
            center: CGPoint(x: right - r, y: top + r),
            radius: r,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        // Right edge (straight).
        p.addLine(to: CGPoint(x: right, y: bottom - r))
        // Bottom-right corner.
        p.addArc(
            center: CGPoint(x: right - r, y: bottom - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        // Bottom edge (right→left) with wave (mirrored phase).
        for i in 0...Int(segments) {
            let t = CGFloat(i) / segments
            let x = (right - r) - t * (rect.width - 2 * r)
            let y = bottom - sin(t * frequency * .pi * 2 - phase) * amplitude
            p.addLine(to: CGPoint(x: x, y: y))
        }
        // Bottom-left corner.
        p.addArc(
            center: CGPoint(x: left + r, y: bottom - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        // Left edge.
        p.addLine(to: CGPoint(x: left, y: top + r))
        // Top-left corner.
        p.addArc(
            center: CGPoint(x: left + r, y: top + r),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        return p
    }
}

/// Variant 4 — Trace runner. Faint baseline stroke + an accent
/// dash that travels around the perimeter. Mic level controls
/// run speed.
private struct TraceRunnerBorder: View {
    let color: Color
    let level: Float
    @State private var dashOffset: CGFloat = 0
    @State private var perimeterEstimate: CGFloat = 600

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(color.opacity(0.25), lineWidth: 1.2)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .trim(from: 0, to: 0.18)
                .stroke(color, style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
                .rotationEffect(.degrees(Double(dashOffset)))
        }
        .onAppear {
            // 2.4s base period; speeds up to ~1.0s when speaking
            // loudly. linear repeat so the runner motion is even.
            withAnimation(.linear(duration: animationDuration).repeatForever(autoreverses: false)) {
                dashOffset = 360
            }
        }
        .animation(.easeInOut(duration: 0.4), value: level)
    }

    private var animationDuration: Double {
        let base = 2.4
        let speedup = Double(level) * 1.4
        return max(0.6, base - speedup)
    }
}
