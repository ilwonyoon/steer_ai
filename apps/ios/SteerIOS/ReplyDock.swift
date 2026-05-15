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
    @Environment(\.onboardingAllowEmptySend) private var envAllowEmpty: Bool
    @FocusState private var fallbackFocus: Bool

    @StateObject private var dictation = DictationController()
    @State private var showDeniedAlert: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
        ZStack(alignment: .bottomTrailing) {
            textInput
                .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(SteerColors.softSeparator, lineWidth: 1)
                }
            HStack(spacing: 6) {
                micButton
                if showSend {
                    sendButton
                }
            }
            .padding(.trailing, 8)
            .padding(.bottom, 8)
        }
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

    @ViewBuilder
    private var textInput: some View {
        let base = TextField(placeholder ?? "Reply to this session", text: $reply, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 17))
            .foregroundStyle(SteerColors.ink)
            .lineLimit(1...8)
            .accessibilityIdentifier("reply-input")
            .padding(.leading, 14)
            .padding(.trailing, showSend ? 84 : 46)
            .padding(.vertical, 12)
            .frame(minHeight: 48)

        if let externalFocus {
            base.focused(externalFocus)
        } else {
            base.focused($fallbackFocus)
        }
    }

    private var micButton: some View {
        Button(action: handleMicTap) {
            Image(systemName: micIconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(micIconColor)
                .frame(width: 32, height: 32)
                .background(micBackground, in: Circle())
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
        case .listening: return .white
        case .denied: return SteerColors.blocked
        default: return SteerColors.secondaryInk
        }
    }
    private var micBackground: Color {
        dictation.state == .listening ? Color.accentColor : SteerColors.subtleFill
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
