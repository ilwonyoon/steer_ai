import QuartzCore
import SwiftUI
import UIKit


/// iOS port of the Mac ReplyDock. Drops the Mac-only AppKit pieces
/// (clipboard image monitor, NSItemProvider drag-and-drop,
/// .onKeyPress(.return)) and keeps the visual + send semantics:
///   - rounded inputFill background with softSeparator stroke
///   - 17pt SF text placeholder ("Reply to this session")
///   - 56pt input row (matches ChatGPT/Claude/Gemini iOS)
///   - floating bottom-right send button that appears only when canSend
///   - in-card mic button (v2) driven by `DictationController`
///
/// Listening UX matches the ChatGPT/Claude/Gemini takeover pattern:
/// the entire input row swaps to a full-width waveform + large
/// stop button, with no partial transcript on screen. The
/// recognized text is committed to the field only on stop. Tap +
/// state transitions also fire haptics.
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
        .onChange(of: dictation.state) { oldState, newState in
            // Industry pattern (ChatGPT / Claude / Gemini): hide the
            // partial transcript while listening — the waveform owns
            // the row. Commit the recognized text into the reply
            // binding only on listening → not-listening transition.
            if oldState == .listening && newState != .listening {
                let finalText = dictation.partialText
                if !finalText.isEmpty {
                    reply = finalText
                }
            }
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
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onSend(text)
        reply = ""
        externalFocus?.wrappedValue = false
        fallbackFocus = false
    }

    /// Two visual modes that **cross-fade** between each other so
    /// the transition into / out of dictation reads as a deliberate
    /// animation rather than a hard swap:
    ///
    /// - **Idle**: TextField + trailing mic/send buttons.
    /// - **Listening**: TextField hidden, full-width waveform on
    ///   the leading side and a 44pt circular stop button on the
    ///   trailing side.
    ///
    /// Both layers stay mounted; opacity + `.allowsHitTesting`
    /// gate which one the user actually interacts with.
    @ViewBuilder
    private var inputFieldContainer: some View {
        let listening = dictation.state == .listening
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint)

            // Idle layer. mic/send sit on the trailing edge but
            // are vertically centered on the row.
            ZStack(alignment: .trailing) {
                textField
                HStack(spacing: 8) {
                    micButton
                    if showSend {
                        sendButton
                    }
                }
                .padding(.trailing, 10)
            }
            .opacity(listening ? 0 : 1)
            .allowsHitTesting(!listening)

            listeningRow
                .opacity(listening ? 1 : 0)
                .allowsHitTesting(listening)
        }
        .animation(.easeInOut(duration: 0.25), value: listening)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SteerColors.softSeparator, lineWidth: 1)
        }
    }

    /// Idle TextField. Listening swaps the row out for the waveform
    /// takeover, so this view only renders in non-listening states.
    @ViewBuilder
    private var textField: some View {
        let displayedPlaceholder: String = placeholder ?? "Reply to this session"

        let base = TextField(displayedPlaceholder, text: $reply, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 17))
            .foregroundStyle(SteerColors.ink)
            .lineLimit(1...8)
            .accessibilityIdentifier("reply-input")
            .padding(.leading, 16)
            .padding(.trailing, trailingPadding)
            .padding(.vertical, 16)
            .frame(minHeight: 56)

        if let externalFocus {
            base.focused(externalFocus)
        } else {
            base.focused($fallbackFocus)
        }
    }

    private var trailingPadding: CGFloat {
        dictationEnabled ? (showSend ? 92 : 52) : (showSend ? 54 : 16)
    }

    /// Listening takeover: the row is the waveform + a single big
    /// stop button. No partial text — that's the industry pattern.
    /// Waveform sits 20pt off the left wall and 20pt off the stop
    /// button so it doesn't visually crowd either edge.
    @ViewBuilder
    private var listeningRow: some View {
        HStack(spacing: 20) {
            ScrollingWaveform(
                samples: dictation.waveformSamples,
                lastShiftTime: dictation.lastShiftTime,
                shiftInterval: dictation.shiftInterval
            )
                .frame(maxWidth: .infinity, alignment: .leading)
            stopButton
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
    }

    /// Idle-only mic button.
    @ViewBuilder
    private var micButton: some View {
        if !dictationEnabled {
            EmptyView()
        } else {
            Button(action: handleMicTap) {
                Image(systemName: micIconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(micIconColor)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reply-mic")
            .accessibilityLabel("Start dictation")
            .disabled(dictation.state == .requestingPermission)
        }
    }

    /// Big circular stop button — independent of the mic capsule.
    /// 44pt so the glyph reads as a confident "tap to stop"
    /// affordance, not a tiny inline icon.
    private var stopButton: some View {
        Button(action: handleMicTap) {
            Image(systemName: "stop.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.accentColor, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reply-mic")
        .accessibilityLabel("Stop dictation")
    }

    private var micIconName: String {
        switch dictation.state {
        case .requestingPermission: return "hourglass"
        default: return "mic.fill"
        }
    }
    private var micIconColor: Color {
        switch dictation.state {
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
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    dictation.objectWillChange.send()
                    showDeniedAlert = true
                    return
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                dictation.start(appendingTo: reply)
            }
        case .listening:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            dictation.stop()
        case .denied:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showDeniedAlert = true
        case .requestingPermission:
            break
        }
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reply-send")
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel("Send reply")
    }
}

/// Full-width scrolling waveform — true pixel-sliding.
///
/// The controller pushes one new amplitude per ~11ms (one audio
/// buffer worth). Between pushes, a TimelineView drives sub-slot
/// pixel offset on the HStack so the entire row translates left
/// continuously instead of stepping a slot at a time. When the
/// next push lands, the ring shifts and `lastShiftTime` resets —
/// the offset goes back to 0 and a new bar takes the right edge.
///
/// Visual: 3pt-wide rectangular sticks; 33 of them rendered with
/// the rightmost living off-screen as the "incoming" slot that's
/// half a slide away from being visible. The 20 leftmost visible
/// slots ride at 0.2 alpha (the past); the 12 nearest the right
/// edge are full opacity (the live edge). The incoming bar
/// fades 0 → 0.2 in step with the slide so it doesn't pop on.
private struct ScrollingWaveform: View {
    let samples: [Float]
    let lastShiftTime: TimeInterval
    let shiftInterval: TimeInterval

    private let barWidth: CGFloat = 3
    /// Leftmost N slots sit at 0.2 alpha; the rest are 1.0.
    private let fadedZoneCount: Int = 20

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let visibleBars = samples.count
            // Lay out (visibleBars + 1) bars in `totalWidth + slotWidth`
            // — the extra bar lives in the off-screen pocket on the
            // right and slides in as the row translates left.
            let totalBars = barWidth * CGFloat(visibleBars + 1)
            let spacing = max(2, (totalWidth - totalBars + barWidth) / CGFloat(max(1, visibleBars)))
            let slotWidth = barWidth + spacing

            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { _ in
                let progress = computeProgress()
                let offset = -CGFloat(progress) * slotWidth

                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<(visibleBars + 1), id: \.self) { i in
                        let amplitude: Float = {
                            if i < visibleBars { return samples[i] }
                            // Incoming bar: amplitude grows 0 →
                            // newest sample as we slide one slot,
                            // so it never pops at full height.
                            return Float(progress) * (samples.last ?? 0)
                        }()
                        RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                            .fill(Color.accentColor.opacity(alpha(for: i, visibleBars: visibleBars, progress: progress)))
                            .frame(width: barWidth, height: height(for: amplitude))
                    }
                }
                .frame(width: totalWidth + slotWidth, height: proxy.size.height, alignment: .leading)
                .offset(x: offset)
            }
            .frame(width: totalWidth, height: proxy.size.height, alignment: .leading)
            .clipped()
        }
        .frame(height: 36)
    }

    private func computeProgress() -> Double {
        guard shiftInterval > 0 else { return 0 }
        let now = CACurrentMediaTime()
        let elapsed = now - lastShiftTime
        // Clamp into [0, 1]. If audio threading slips past one
        // buffer we just pin to 1 until the next push lands —
        // no overshoot, no rebound.
        return min(1, max(0, elapsed / shiftInterval))
    }

    private func height(for level: Float) -> CGFloat {
        8 + 24 * CGFloat(level)
    }

    /// Index 0..fadedZoneCount-1: faded past (0.2).
    /// Then full opacity until the very last "incoming" slot,
    /// which fades 0 → 0.2 (matching the trailing edge of the
    /// faded zone it's about to feed) so the entry doesn't pop.
    private func alpha(for i: Int, visibleBars: Int, progress: Double) -> Double {
        if i == visibleBars {
            // Incoming bar — its destination after one slide is
            // the rightmost visible slot, which is full opacity.
            // Fade 0 → 1 in step with the slide so it appears
            // smoothly out of the right edge.
            return progress
        }
        return i < fadedZoneCount ? 0.2 : 1.0
    }
}
