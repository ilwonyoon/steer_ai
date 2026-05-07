import SwiftUI

struct ReplyDock: View {
    let chips: [String]
    @Binding var reply: String
    let onSend: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            chipScroller
            inputField
        }
    }

    private var trimmedReply: String {
        reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitReply() {
        let text = trimmedReply
        guard !text.isEmpty else { return }
        onSend(text)
        reply = ""
    }

    private var chipScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { chip in
                    Button {
                        reply = chip
                    } label: {
                        Text(chip)
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                    }
                    .buttonStyle(.plain)
                    .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.black.opacity(0.075), lineWidth: 1)
                    }
                }
            }
            .padding(.vertical, 1)
            .padding(.trailing, 18)
        }
        .overlay(alignment: .trailing) {
            LinearGradient(
                colors: [
                    Color(red: 0.985, green: 0.985, blue: 0.975).opacity(0),
                    Color(red: 0.985, green: 0.985, blue: 0.975).opacity(0.94)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 28)
            .allowsHitTesting(false)
        }
    }

    private var inputField: some View {
        ZStack(alignment: .trailing) {
            TextField("reply to this session", text: $reply)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .onSubmit(submitReply)
                .accessibilityIdentifier("reply-input")
                .padding(.leading, 14)
                .padding(.trailing, 46)
                .frame(height: 42)
                .background(Color.black.opacity(0.026), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.black.opacity(0.075), lineWidth: 1)
                }

            if !trimmedReply.isEmpty {
                Button(action: submitReply) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 31, height: 31)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reply-send")
                .padding(.trailing, 6)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Send reply")
            }
        }
        .animation(.snappy(duration: 0.16), value: reply.isEmpty)
    }
}
