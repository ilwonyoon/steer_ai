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
            // Bottom-right cluster. While listening, the amplitude
            // dots + mic glyph share a single accent-tinted
            // capsule (matches the user's reference); when idle,
            // it's just the bare mic / send buttons. The dots
            // never travel to the leading edge — the "Listening…"
            // placeholder owns that side.
            HStack(spacing: 8) {
                listeningOrMicCluster
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

    /// Always-mounted TextField. While listening the placeholder
    /// switches to "Listening…" and the field is disabled to block
    /// typing, but the dictated text stays visible (live
    /// transcription) so the user can verify what's being heard.
    /// The dots cluster lives in the trailing capsule, not over
    /// the text — so they never collide.
    @ViewBuilder
    private var textField: some View {
        let displayedPlaceholder: String = dictation.state == .listening
            ? "Listening…"
            : (placeholder ?? "Reply to this session")

        let base = TextField(displayedPlaceholder, text: $reply, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 17))
            .foregroundStyle(SteerColors.ink)
            .lineLimit(1...8)
            .accessibilityIdentifier("reply-input")
            .padding(.leading, 14)
            // Trailing padding needs to accommodate the dots+mic
            // capsule (≈72pt wide) while listening, so the live
            // transcript doesn't run under it. Idle leaves the
            // standard mic / mic+send footprint.
            .padding(.trailing, trailingPadding)
            .padding(.vertical, 12)
            .frame(minHeight: 48)
            .disabled(dictation.state == .listening)

        if let externalFocus {
            base.focused(externalFocus)
        } else {
            base.focused($fallbackFocus)
        }
    }

    private var trailingPadding: CGFloat {
        if dictation.state == .listening {
            return showSend ? 120 : 88
        }
        return dictationEnabled ? (showSend ? 84 : 46) : (showSend ? 48 : 14)
    }

    /// Border stays exactly the same in idle and listening — the
    /// "I'm listening" signal lives entirely inside the field as
    /// the three-dot amplitude visualizer.
    @ViewBuilder
    private var inputBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(SteerColors.softSeparator, lineWidth: 1)
    }

    /// Idle: bare mic glyph (32×32 hit area, no background).
    /// Listening: dots + mic glyph bundled into a single accent
    /// capsule so they read as one affordance (matches the
    /// reference). Tap target stays the full capsule.
    @ViewBuilder
    private var listeningOrMicCluster: some View {
        if !dictationEnabled {
            EmptyView()
        } else if dictation.state == .listening {
            Button(action: handleMicTap) {
                HStack(spacing: 8) {
                    ListeningDots(levels: dictation.dotLevels)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.18), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reply-mic")
            .accessibilityLabel("Stop dictation")
        } else {
            micButton
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

/// Three amplitude-reactive capsule dots that sit inside the
/// trailing mic cluster while dictation is live. Spec from the
/// audio-visualizer research note:
///
///   - 4pt wide capsules, 6pt → 18pt height range, 4pt gap.
///   - 30% idle floor so the dots read as "live mic" at silence.
///   - All three driven from the same RMS envelope, but each
///     samples the envelope at 0ms / 80ms / 160ms delays
///     (computed in DictationController.dotLevels) so they
///     ripple instead of pulsing in unison.
///   - Single accent color, no gradient (too small for one).
private struct ListeningDots: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: dotHeight(for: i))
                    .animation(.easeOut(duration: 0.08), value: levels)
            }
        }
        .frame(height: 18)
    }

    private func dotHeight(for i: Int) -> CGFloat {
        let level = CGFloat(levels.indices.contains(i) ? levels[i] : 0)
        // 30% floor + 70% live range = [6pt, 18pt].
        let scale = 0.3 + level * 0.7
        return 6 + 12 * scale
    }
}
