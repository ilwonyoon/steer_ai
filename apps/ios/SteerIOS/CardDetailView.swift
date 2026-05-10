import SwiftUI
import SteerCore

struct CardDetailView: View {
    let card: CardPayload
    @ObservedObject var inbox: SyncInbox

    @Environment(\.dismiss) private var dismiss
    @State private var reply: String = ""
    @State private var isSending = false

    private var terminalLines: [String] {
        if case .stringArray(let arr) = card.payload?["terminalLines"]?.value { return arr }
        return []
    }
    private var options: [String] {
        if case .stringArray(let arr) = card.payload?["options"]?.value { return arr }
        return []
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        CardMetaRow(card: card)

                        Text(card.title)
                            .font(.system(size: 18, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)

                        if !card.summary.isEmpty {
                            Text(card.summary)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !terminalLines.isEmpty {
                            TerminalExcerpt(lines: terminalLines)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }

                ReplyComposer(
                    chips: options,
                    reply: $reply,
                    isSending: isSending,
                    onChip: { reply = $0 },
                    onSend: { Task { await send() } }
                )
            }
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

private struct TerminalExcerpt: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(white: 0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ReplyComposer: View {
    let chips: [String]
    @Binding var reply: String
    let isSending: Bool
    let onChip: (String) -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if !chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(chips, id: \.self) { chip in
                                Button {
                                    onChip(chip)
                                } label: {
                                    Text(chip)
                                        .font(.system(size: 13, design: .monospaced))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color(.tertiarySystemBackground))
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(Color(.separator), lineWidth: 0.5)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("reply to this session", text: $reply, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .monospaced))
                        .lineLimit(1...5)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .disabled(isSending)
                    Button {
                        onSend()
                    } label: {
                        Image(systemName: isSending ? "hourglass" : "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                    }
                    .disabled(!canSend || isSending)
                }
            }
            .padding(12)
        }
        .background(.regularMaterial)
    }

    private var canSend: Bool {
        !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
