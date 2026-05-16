import SwiftUI

/// Visual treatments for the "I'm listening" state on the input
/// field. Each variant translates a different native iOS reference
/// (see docs/IOS_DICTATION_DESIGN.md research notes) so we can
/// dogfood and pick one before settling.
enum DictationVisualStyle: String, CaseIterable, Identifiable {
    /// WhatsApp / Telegram: the input row is replaced by a
    /// horizontally-scrolling amplitude-reactive waveform while
    /// recording is live.
    case rowWaveform
    /// Apple Notes: small inline amplitude bars sit on the leading
    /// edge next to the transcript, like a tiny level meter.
    case inlineBars
    /// Minimal: just an accent-tinted border that gently pulses
    /// in opacity. No content-area chrome.
    case outlinePulse
    /// Siri-style: a soft accent glow blooming outside the input's
    /// rounded rect, breathing slowly.
    case edgeGlow

    var id: String { rawValue }
    var label: String {
        switch self {
        case .rowWaveform: return "Row waveform"
        case .inlineBars:  return "Inline bars"
        case .outlinePulse: return "Outline pulse"
        case .edgeGlow:    return "Edge glow"
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
    var dictationStyle: DictationVisualStyle = .rowWaveform
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

    /// The full input row: background + border + (variant-specific
    /// listening visual) + the always-mounted TextField + mic/send
    /// buttons.
    @ViewBuilder
    private var inputFieldContainer: some View {
        ZStack(alignment: .bottomTrailing) {
            // 1) Field background. For the rowWaveform variant we
            //    hide the text background while listening so the
            //    waveform fills the row by itself.
            backgroundLayer

            // 2) Listening visual specific to the active style. All
            //    variants except rowWaveform are non-interactive
            //    overlays so the TextField underneath still
            //    receives taps.
            if dictation.state == .listening {
                listeningOverlay
                    .allowsHitTesting(dictationStyle == .rowWaveform)
            }

            // 3) The text field. Always mounted so the SwiftUI
            //    focus / lifecycle stays clean across listening
            //    transitions. Hidden visually under .rowWaveform
            //    (the waveform replaces the row entirely) but still
            //    receives the streamed transcript via $reply.
            textField
                .opacity(textFieldOpacity)

            // 4) Mic + send. The mic is always visible (subject to
            //    `dictationEnabled`); send appears alongside when
            //    we have something to send and we're not actively
            //    listening.
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
            // Border treatment. Variants tweak this:
            //   .outlinePulse  → opacity-pulses accent
            //   .edgeGlow      → wider soft glow drawn outside
            //   others         → simple accent border while listening
            inputBorder
        }
    }

    /// Always-mounted TextField. The opacity is driven by the active
    /// variant — rowWaveform hides the field while listening so the
    /// waveform owns the row visually; other variants keep the
    /// transcript readable underneath their non-blocking overlay.
    @ViewBuilder
    private var textField: some View {
        let base = TextField(placeholder ?? "Reply to this session", text: $reply, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 17))
            .foregroundStyle(SteerColors.ink)
            .lineLimit(1...8)
            .accessibilityIdentifier("reply-input")
            .padding(.leading, textFieldLeadingPadding)
            .padding(.trailing, dictationEnabled ? (showSend ? 84 : 46) : (showSend ? 48 : 14))
            .padding(.vertical, 12)
            .frame(minHeight: 48)

        if let externalFocus {
            base.focused(externalFocus)
        } else {
            base.focused($fallbackFocus)
        }
    }

    /// rowWaveform takes over the visible row, so the field beneath
    /// disappears visually. Other variants keep the transcript
    /// readable.
    private var textFieldOpacity: Double {
        if dictation.state == .listening && dictationStyle == .rowWaveform {
            return 0
        }
        return 1
    }

    /// Inline bars sit on the leading edge of the field, so the
    /// text needs to be pushed right when they're showing.
    private var textFieldLeadingPadding: CGFloat {
        if dictation.state == .listening && dictationStyle == .inlineBars {
            return 14 + 36
        }
        return 14
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tint)
    }

    @ViewBuilder
    private var inputBorder: some View {
        switch dictationStyle {
        case .outlinePulse where dictation.state == .listening:
            PulsingBorder(color: .accentColor)
        case .edgeGlow where dictation.state == .listening:
            EdgeGlowBorder(color: .accentColor)
        default:
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderStroke, lineWidth: borderWidth)
        }
    }

    /// The visual that renders ONLY while listening. Each variant
    /// owns its own subview so the body stays scannable.
    @ViewBuilder
    private var listeningOverlay: some View {
        switch dictationStyle {
        case .rowWaveform:
            RowWaveform(text: reply, level: dictation.audioLevel)
        case .inlineBars:
            InlineBars(level: dictation.audioLevel)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 12)
                .padding(.top, 14)
        case .outlinePulse, .edgeGlow:
            // These variants draw entirely on the border; no
            // additional overlay content.
            EmptyView()
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

/// Variant A — WhatsApp/Telegram in-row waveform. While dictation
/// is live the input row is replaced by a horizontal amplitude
/// strip; the transcript fades in below as a thin caption so the
/// user can still verify recognition. Reactive to mic level.
private struct RowWaveform: View {
    let text: String
    let level: Float
    @State private var phase: CGFloat = 0
    private let barCount = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                HStack(spacing: 3) {
                    ForEach(0..<barCount, id: \.self) { i in
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: 3, height: barHeight(for: i, in: proxy.size.height))
                            .opacity(0.6 + 0.4 * envelope(for: i))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 26)
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(SteerColors.secondaryInk)
                    .lineLimit(2)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 46)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private func envelope(for i: Int) -> CGFloat {
        // Combines the current mic level with a positional sine so
        // the bars look like a moving wave rather than identical
        // pulses. Each bar gets a phase offset.
        let positional = sin((CGFloat(i) / CGFloat(barCount) + phase) * .pi * 4)
        return (CGFloat(level) * 0.7 + 0.3) * (0.5 + 0.5 * abs(positional))
    }

    private func barHeight(for i: Int, in maxH: CGFloat) -> CGFloat {
        max(4, maxH * envelope(for: i))
    }
}

/// Variant B — Apple Notes inline amplitude bars. Three vertical
/// bars sit on the leading edge of the input, hugging where the
/// caret would be. Bars rise and fall with mic level.
private struct InlineBars: View {
    let level: Float
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: barHeight(for: i))
            }
        }
        .frame(height: 20)
        .onAppear {
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private func barHeight(for i: Int) -> CGFloat {
        let positional = sin((CGFloat(i) / 4.0 + phase) * .pi * 2)
        let amp = (CGFloat(level) * 0.6 + 0.25) * (0.5 + 0.5 * abs(positional))
        return max(5, 22 * amp)
    }
}

/// Variant C — Minimal accent border that gently pulses in width
/// and opacity. No content-area chrome.
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

/// Variant D — Siri-style soft outer glow. A blurred RoundedRect
/// drawn behind the border breathes slowly so the input looks
/// like it's "humming".
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
