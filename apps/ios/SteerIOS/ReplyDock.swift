import SwiftUI

/// Visual treatments for the "I'm listening" state — all four
/// variants live ENTIRELY on the input field's outline and are
/// all GLOW patterns (a follow-up to user feedback that the glow
/// direction read the best of the previous variant set). Each
/// reacts to live mic amplitude in a different way so we can
/// dogfood the four flavors against each other.
///
/// Text area is untouched in every variant.
enum DictationVisualStyle: String, CaseIterable, Identifiable {
    /// Claude.ai-style halo: soft accent ring bleeding outside the
    /// rounded rect. Outer ring width + opacity track mic level so
    /// loud speech briefly "brightens" the halo.
    case glow
    /// In-bounds masked halo: blur sits ON the inside of the
    /// rounded rect, clipped so nothing spills outside. Reads like
    /// Apple Intelligence's edge-glow pressing inward; inner-blur
    /// strength tracks amplitude.
    case innerGlow
    /// Cursor IDE-style traced light: an angular gradient sweeps
    /// the stroke perimeter. Rotation speed + brightness scale
    /// with amplitude — quiet = slow soft sweep, loud = fast
    /// bright sweep.
    case sweep
    /// Heartbeat: a thin solid stroke with an outer soft glow whose
    /// width and blur expand on every speech peak. Amplitude is
    /// the entire animation — at silence the field is a calm
    /// accent line; on speech the glow blooms.
    case pulseGlow

    var id: String { rawValue }
    var label: String {
        switch self {
        case .glow:       return "Glow"
        case .innerGlow:  return "Inner"
        case .sweep:      return "Sweep"
        case .pulseGlow:  return "Pulse"
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
    var dictationStyle: DictationVisualStyle = .glow
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
    /// one of four glow variants, each amplitude-reactive in a
    /// different way. None touch the text area.
    @ViewBuilder
    private var inputBorder: some View {
        if dictation.state == .listening {
            switch dictationStyle {
            case .glow:
                GlowBorder(color: .accentColor, level: dictation.audioLevel)
            case .innerGlow:
                InnerGlowBorder(color: .accentColor, level: dictation.audioLevel)
            case .sweep:
                SweepBorder(color: .accentColor, level: dictation.audioLevel)
            case .pulseGlow:
                PulseGlowBorder(color: .accentColor, level: dictation.audioLevel)
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

// MARK: - Glow variants
//
// Shared shape constants so all four variants use exactly the
// same corner radius and outer/inner clip frame as the input
// field. Drift here would make the visuals subtly misaligned.
private let dictationCornerRadius: CGFloat = 12

/// Variant 1 — "Glow". Soft outer halo, Claude.ai pattern. A
/// thin solid stroke sits on the border; behind it a wider
/// blurred ring breathes outside the field. Outer ring opacity
/// + width track mic level: silence reads as a quiet halo,
/// loud speech briefly brightens and thickens it.
private struct GlowBorder: View {
    let color: Color
    let level: Float
    @State private var breathe: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: dictationCornerRadius, style: .continuous)
                .stroke(color.opacity(0.85), lineWidth: 1.5)
            RoundedRectangle(cornerRadius: dictationCornerRadius + 4, style: .continuous)
                .stroke(color.opacity(haloOpacity), lineWidth: haloWidth)
                .blur(radius: 6)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .animation(.easeOut(duration: 0.18), value: level)
    }

    private var haloOpacity: Double {
        let base = breathe ? 0.5 : 0.2
        return min(0.85, base + Double(level) * 0.5)
    }

    private var haloWidth: CGFloat {
        4 + CGFloat(level) * 6
    }
}

/// Variant 2 — "Inner". Apple-Intelligence-style edge glow
/// pressing inward. We render a blurred ring OUTSIDE the field
/// then clip the whole effect back to the rounded rect, so the
/// glow feathers from the border toward the center but never
/// leaks past the rounded corners. Inner blur strength tracks
/// amplitude.
private struct InnerGlowBorder: View {
    let color: Color
    let level: Float
    @State private var breathe: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: dictationCornerRadius, style: .continuous)
            .strokeBorder(color, lineWidth: 1.2)
            .background(
                RoundedRectangle(cornerRadius: dictationCornerRadius, style: .continuous)
                    .stroke(color.opacity(innerOpacity), lineWidth: innerWidth)
                    .blur(radius: blurRadius)
                    .clipShape(RoundedRectangle(cornerRadius: dictationCornerRadius, style: .continuous))
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
            .animation(.easeOut(duration: 0.2), value: level)
    }

    private var innerOpacity: Double {
        let base = breathe ? 0.65 : 0.3
        return min(0.95, base + Double(level) * 0.4)
    }

    private var innerWidth: CGFloat {
        6 + CGFloat(level) * 10
    }

    private var blurRadius: CGFloat {
        5 + CGFloat(level) * 6
    }
}

/// Variant 3 — "Sweep". Cursor IDE-style traced light. A bright
/// accent arc rotates around the rounded rect; rotation speed
/// scales with mic level (silence = slow, loud = fast). Behind
/// it sits a faint stationary stroke so the field always has a
/// readable outline.
private struct SweepBorder: View {
    let color: Color
    let level: Float
    @State private var phase: Double = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: dictationCornerRadius, style: .continuous)
                .stroke(color.opacity(0.3), lineWidth: 1.2)
            RoundedRectangle(cornerRadius: dictationCornerRadius, style: .continuous)
                .trim(from: 0, to: trimFraction)
                .stroke(color.opacity(strokeOpacity), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(phase))
                .blur(radius: 0.6)
        }
        .onAppear {
            phase = 0
            withAnimation(.linear(duration: rotationDuration).repeatForever(autoreverses: false)) {
                phase = 360
            }
        }
        .animation(.easeInOut(duration: 0.4), value: level)
    }

    private var rotationDuration: Double {
        let base = 2.6
        let speedup = Double(level) * 1.6
        return max(0.7, base - speedup)
    }

    private var trimFraction: CGFloat {
        0.16 + CGFloat(level) * 0.12
    }

    private var strokeOpacity: Double {
        0.55 + Double(level) * 0.4
    }
}

/// Variant 4 — "Pulse". Heartbeat-style amplitude bloom. A thin
/// solid stroke is the resting state; on every speech peak, a
/// soft outer glow blooms briefly. The animation is entirely
/// driven by mic level — at silence the field is a calm accent
/// line, on speech the surround halo expands and brightens.
private struct PulseGlowBorder: View {
    let color: Color
    let level: Float

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: dictationCornerRadius, style: .continuous)
                .stroke(color.opacity(0.8), lineWidth: 1.4)
            RoundedRectangle(cornerRadius: dictationCornerRadius + 6, style: .continuous)
                .stroke(color.opacity(glowOpacity), lineWidth: glowWidth)
                .blur(radius: blurRadius)
        }
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: level)
    }

    private var glowOpacity: Double {
        // Quiet ≈ invisible, loud ≈ vivid.
        min(0.9, Double(level) * 1.2)
    }

    private var glowWidth: CGFloat {
        2 + CGFloat(level) * 14
    }

    private var blurRadius: CGFloat {
        4 + CGFloat(level) * 10
    }
}
