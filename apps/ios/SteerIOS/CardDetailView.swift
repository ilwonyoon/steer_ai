import SwiftUI
import SteerCore

struct CardDetailView: View {
    let card: CardPayload
    @ObservedObject var inbox: SyncInbox

    @Environment(\.dismiss) private var dismiss
    @State private var reply: String = ""
    @State private var isSending = false

    private var terminalLines: [String] {
        switch card.payload?["terminalLines"]?.value {
        case .stringArray(let arr): return arr
        default: return []
        }
    }

    private var options: [String] {
        switch card.payload?["options"]?.value {
        case .stringArray(let arr): return arr
        default: return []
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(card.title)
                        .font(.system(size: 18, weight: .semibold))
                    Text(card.summary)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !terminalLines.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(terminalLines, id: \.self) { line in
                                Text(line.isEmpty ? " " : line)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if !options.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(options, id: \.self) { chip in
                                Button {
                                    reply = chip
                                } label: {
                                    Text(chip)
                                        .font(.system(size: 13, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 12)
                                        .background(Color(.tertiarySystemBackground))
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }

            VStack(spacing: 0) {
                Divider()
                HStack {
                    TextField("reply to this session", text: $reply, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .disabled(isSending)
                    Button {
                        Task { await send() }
                    } label: {
                        Image(systemName: isSending ? "hourglass" : "arrow.up.circle.fill")
                            .font(.system(size: 28))
                    }
                    .disabled(isSending || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(12)
            }
            .background(.regularMaterial)
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func send() async {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        await inbox.sendReply(text: text, for: card)
        reply = ""
        dismiss()
    }
}
