import SwiftUI

struct ReplyDock: View {
    let chips: [String]
    @Binding var reply: String
    let onSend: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            chipScroller
            inputField
        }
    }

    private var chipScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { chip in
                    Button {
                        reply = chip
                    } label: {
                        Text(chip)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .padding(.horizontal, 13)
                            .frame(height: 34)
                    }
                    .buttonStyle(.plain)
                    .background(.white.opacity(0.78), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    }
                }
            }
            .padding(.vertical, 1)
            .padding(.trailing, 18)
        }
        .overlay(alignment: .trailing) {
            LinearGradient(
                colors: [
                    Color(red: 0.97, green: 0.97, blue: 0.98).opacity(0),
                    Color(red: 0.97, green: 0.97, blue: 0.98).opacity(0.92)
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
            TextField("Reply to this AI session", text: $reply)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(.leading, 14)
                .padding(.trailing, 50)
                .frame(height: 44)
                .background(.white.opacity(0.74), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                }

            if !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    onSend(reply)
                    reply = ""
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 5)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Send reply")
            }
        }
        .animation(.snappy(duration: 0.16), value: reply.isEmpty)
    }
}
