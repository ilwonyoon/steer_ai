import SwiftUI

/// iOS port of the Mac ReplyDock. Drops the Mac-only AppKit pieces
/// (clipboard image monitor, NSItemProvider drag-and-drop,
/// .onKeyPress(.return)) and keeps the visual + send semantics:
///   - rounded inputFill background with softSeparator stroke
///   - 13pt monospaced placeholder ("reply to this session")
///   - chip row above input
///   - floating bottom-right send button that appears only when canSend
///   - in-card mic button (Step 3) that streams SFSpeechRecognizer
///     partials into the same `reply` binding
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

    /// Voice-reply controller. @StateObject so swiping to a
    /// different card destroys the engine instead of reusing it
    /// (each card gets its own clean controller).
    @StateObject private var dictation = DictationController()
    @State private var showDeniedAlert: Bool = false
    @State private var crashTrailText: String? = nil
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            textInput
                .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(borderColor, lineWidth: borderWidth)
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
        .animation(.easeOut(duration: 0.16), value: canSend)
        .animation(.easeOut(duration: 0.16), value: dictation.state)
        .onChange(of: dictation.partialText) { _, newValue in
            // While listening, the controller is the writer; mirror
            // its composed string (baseText + recognized) into the
            // reply binding so the user sees the transcript live.
            // When idle, partialText stops updating, and the user's
            // typing wins as normal.
            if dictation.state == .listening {
                reply = newValue
            }
        }
        .onChange(of: dictation.state) { _, newState in
            if newState == .denied {
                showDeniedAlert = true
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
        // Tear the engine down on (a) card swap — @StateObject is
        // dropped with the view, and (b) app background — iOS will
        // suspend audio anyway, and we want the recognizer fully
        // unwound so it doesn't drain battery or hold the mic.
        .onDisappear { dictation.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && dictation.state == .listening {
                dictation.stop()
            }
        }
        .onAppear {
            // Surface the breadcrumb a previous launch left behind
            // if dictation crashed mid-flight. Temporary debug aid;
            // remove once we've nailed the crash.
            if let trail = DictationController.drainTrail() {
                crashTrailText = trail
            }
        }
        .alert(
            "Dictation crash trail",
            isPresented: Binding(
                get: { crashTrailText != nil },
                set: { if !$0 { crashTrailText = nil } }
            ),
            actions: {
                Button("Copy") {
                    if let t = crashTrailText { UIPasteboard.general.string = t }
                    crashTrailText = nil
                }
                Button("Dismiss", role: .cancel) { crashTrailText = nil }
            },
            message: {
                Text(crashTrailText ?? "")
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
    /// Hide the send button while dictation is live — sending a
    /// half-recognized transcript by accident is the worst failure
    /// mode here. User taps stop, sees the final text, then sends.
    private var showSend: Bool {
        canSend && dictation.state != .listening
    }

    private var borderColor: Color {
        dictation.state == .listening ? Color.accentColor : SteerColors.softSeparator
    }
    private var borderWidth: CGFloat {
        dictation.state == .listening ? 1.5 : 1
    }

    private func submit() {
        // allowEmptySend (param or env) lets the onboarding card
        // advance on a blank send; real cards still require text.
        let text = trimmedReply
        if !effectiveAllowEmpty && text.isEmpty { return }
        onSend(text)
        reply = ""
        // Drop the keyboard so the carousel reappears immediately
        // after sending — matches Mac's "send and move on" feel.
        externalFocus?.wrappedValue = false
        fallbackFocus = false
    }

    @ViewBuilder
    private var textInput: some View {
        // iOS body weight: 17pt SF Text. Reply input is a chat field
        // — keep it SF (was monospaced and read like a terminal).
        let base = TextField(placeholder ?? "Reply to this session", text: $reply, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 17))
            .foregroundStyle(SteerColors.ink)
            .lineLimit(1...8)
            .accessibilityIdentifier("reply-input")
            .padding(.leading, 14)
            // Reserve space for mic + (maybe) send button. Mic is
            // always there; send appears alongside it when canSend.
            .padding(.trailing, showSend ? 84 : 46)
            .padding(.vertical, 12)
            .frame(minHeight: 48)
            .disabled(dictation.state == .listening)

        // Dismiss paths: tap outside the card, send-and-clear, or
        // the system swipe-down gesture inside the terminal scroll.
        // We deliberately don't add a keyboard accessory toolbar
        // because InboxView isn't inside a NavigationStack and the
        // resulting "Done" button floats awkwardly.
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
                .overlay {
                    if dictation.state == .listening {
                        Circle()
                            .stroke(Color.accentColor, lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reply-mic")
        .accessibilityLabel(dictation.state == .listening ? "Stop dictation" : "Start dictation")
        .transition(.scale.combined(with: .opacity))
    }

    private var micIconName: String {
        switch dictation.state {
        case .listening: return "stop.fill"
        case .requestingPermission: return "mic"
        default: return "mic.fill"
        }
    }
    private var micIconColor: Color {
        switch dictation.state {
        case .listening: return .white
        case .denied, .failed: return SteerColors.blocked
        default: return SteerColors.secondaryInk
        }
    }
    private var micBackground: Color {
        dictation.state == .listening ? Color.accentColor : SteerColors.subtleFill
    }

    private func handleMicTap() {
        switch dictation.state {
        case .idle, .failed:
            Task { await dictation.start(appendingTo: reply) }
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
