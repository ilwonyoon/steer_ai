import SwiftUI

/// iOS port of the Mac ReplyDock. Drops the Mac-only AppKit pieces
/// (clipboard image monitor, NSItemProvider drag-and-drop,
/// .onKeyPress(.return)) and keeps the visual + send semantics:
///   - rounded inputFill background with softSeparator stroke
///   - 13pt monospaced placeholder ("reply to this session")
///   - chip row above input
///   - floating bottom-right send button that appears only when canSend
struct ReplyDock: View {
    @Binding var reply: String
    let onSend: (String) -> Void
    var tint: Color = SteerColors.inputFill
    /// External @FocusState owned by the parent. We bind the TextField
    /// directly to it so the parent can both observe changes and
    /// programmatically dismiss the keyboard.
    var externalFocus: FocusState<Bool>.Binding? = nil
    @FocusState private var fallbackFocus: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            textInput
                .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(SteerColors.softSeparator, lineWidth: 1)
                }
            if canSend {
                sendButton
            }
        }
        .animation(.easeOut(duration: 0.16), value: canSend)
    }

    private var trimmedReply: String {
        reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSend: Bool { !trimmedReply.isEmpty }

    private func submit() {
        let text = trimmedReply
        guard canSend else { return }
        onSend(text)
        reply = ""
        // Drop the keyboard so the carousel reappears immediately
        // after sending — matches Mac's "send and move on" feel.
        externalFocus?.wrappedValue = false
        fallbackFocus = false
    }

    @ViewBuilder
    private var textInput: some View {
        let base = TextField("reply to this session", text: $reply, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 15, design: .monospaced))
            .foregroundStyle(SteerColors.ink)
            .lineLimit(1...8)
            .accessibilityIdentifier("reply-input")
            .padding(.leading, 14)
            .padding(.trailing, 46)
            .padding(.vertical, 12)
            .frame(minHeight: 42)

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

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 31, height: 31)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reply-send")
        .padding(.trailing, 6)
        .padding(.bottom, 5)
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel("Send reply")
    }
}
