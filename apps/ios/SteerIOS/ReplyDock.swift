import SwiftUI


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
            // Three amplitude-reactive dots sit inside the field
            // while listening, replacing the visible text area
            // (transcript still lands in $reply, just hidden until
            // the user taps stop). The placeholder reads
            // "Listening…" via textFieldPlaceholder, and the dots
            // sit on top of the empty field.
            if dictation.state == .listening {
                ListeningDots(level: dictation.audioLevel)
                    .allowsHitTesting(false)
                    .padding(.leading, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
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

    /// Always-mounted TextField. While listening the text is hidden
    /// (foreground = clear) and the placeholder is forced to
    /// "Listening…" so the dots overlay sits on a clean field.
    @ViewBuilder
    private var textField: some View {
        let displayedPlaceholder: String = dictation.state == .listening
            ? "Listening…"
            : (placeholder ?? "Reply to this session")

        let base = TextField(displayedPlaceholder, text: $reply, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 17))
            // While listening, hide the typed/dictated text behind
            // the dots overlay. Transcript still accumulates in
            // $reply — it just becomes visible when listening ends.
            .foregroundStyle(dictation.state == .listening ? Color.clear : SteerColors.ink)
            .lineLimit(1...8)
            .accessibilityIdentifier("reply-input")
            .padding(.leading, 14)
            .padding(.trailing, dictationEnabled ? (showSend ? 84 : 46) : (showSend ? 48 : 14))
            .padding(.vertical, 12)
            .frame(minHeight: 48)
            .disabled(dictation.state == .listening)

        if let externalFocus {
            base.focused(externalFocus)
        } else {
            base.focused($fallbackFocus)
        }
    }

    /// Border stays exactly the same in idle and listening — the
    /// "I'm listening" signal lives entirely inside the field as
    /// the three-dot amplitude visualizer.
    @ViewBuilder
    private var inputBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(SteerColors.softSeparator, lineWidth: 1)
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

/// Three amplitude-reactive dots that sit inside the reply field
/// while dictation is live. Pattern: a phase offset per dot so
/// they look like a small wave (left → center → right), with the
/// vertical scale tied to mic level. Color: accent.
private struct ListeningDots: View {
    let level: Float
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: dotHeight(for: i))
            }
        }
        .frame(height: 20)
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }

    private func dotHeight(for i: Int) -> CGFloat {
        // Each dot lags the previous by 1/3 of the cycle so the
        // wave reads as motion across the row. Amplitude is a
        // base floor (so silence still shows three dots) plus the
        // live mic level for reactivity.
        let offset = CGFloat(i) * (.pi * 2 / 3)
        let positional = sin(phase + offset)
        let amplitude: CGFloat = 0.45 + CGFloat(level) * 0.55
        let scale = 0.6 + 0.4 * (0.5 + 0.5 * positional) * amplitude
        return max(8, 22 * scale)
    }
}
