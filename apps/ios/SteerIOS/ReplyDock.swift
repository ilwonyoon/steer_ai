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
    /// Optional outer FocusState binding so the parent (Inbox) can react to
    /// keyboard focus and hide chrome (carousel) while typing.
    var externalFocus: FocusState<Bool>.Binding? = nil
    @FocusState private var localFocus: Bool

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
        .animation(.snappy(duration: 0.16), value: canSend)
        .onChange(of: localFocus) { _, focused in
            externalFocus?.wrappedValue = focused
        }
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
    }

    private var textInput: some View {
        TextField("reply to this session", text: $reply, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 15, design: .monospaced))
            .foregroundStyle(SteerColors.ink)
            .lineLimit(1...8)
            .accessibilityIdentifier("reply-input")
            .focused($localFocus)
            .padding(.leading, 14)
            .padding(.trailing, 46)
            .padding(.vertical, 12)
            .frame(minHeight: 42)
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
