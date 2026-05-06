import SwiftUI

struct ReplyDock: View {
    let chips: [String]
    @Binding var reply: String
    let onSend: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.self) { chip in
                        Button {
                            reply = chip
                        } label: {
                            Text(chip)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 13)
                                .frame(height: 34)
                        }
                        .buttonStyle(.plain)
                        .steerGlass(cornerRadius: 17, interactive: true)
                    }
                }
            }

            ZStack(alignment: .trailing) {
                TextField("Reply to this AI session", text: $reply)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .padding(.leading, 14)
                    .padding(.trailing, 50)
                    .frame(height: 44)
                    .steerGlass(cornerRadius: 22, interactive: true)

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
        }
    }
}
