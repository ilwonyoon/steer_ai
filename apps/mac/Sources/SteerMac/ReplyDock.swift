import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ReplyDock: View {
    let chips: [String]
    @Binding var reply: String
    @Binding var attachments: [ReplyAttachment]
    let onSend: (String, [ReplyAttachment]) -> Void
    var tint: Color = SteerColors.inputFill
    var provider: ProviderKind = .custom

    @StateObject private var clipboardMonitor = ClipboardImageMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                AttachmentRow(
                    attachments: attachments,
                    onRemove: removeAttachment
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            inputField
        }
        .animation(.snappy(duration: 0.18), value: attachments)
        .onDrop(of: [.image, .fileURL], isTargeted: nil, perform: handleDrop)
        .onAppear {
            clipboardMonitor.onImageDetected = { attachment in
                attachments.append(attachment)
            }
            clipboardMonitor.start()
        }
        .onDisappear {
            clipboardMonitor.stop()
        }
    }

    private var trimmedReply: String {
        reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmedReply.isEmpty || !attachments.isEmpty
    }

    private func submitReply() {
        let text = trimmedReply
        guard canSend else { return }
        let outgoing = attachments
        onSend(text, outgoing)
        reply = ""
        attachments = []
    }

    private func removeAttachment(_ attachment: ReplyAttachment) {
        AttachmentService.discard(attachment)
        attachments.removeAll { $0.id == attachment.id }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task { @MainActor in
            let captured = await AttachmentService.attachments(from: providers)
            if !captured.isEmpty {
                attachments.append(contentsOf: captured)
            }
        }
        return true
    }

    private var inputField: some View {
        ZStack(alignment: .bottomTrailing) {
            TextField("reply to this session", text: $reply, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(SteerColors.ink)
                .lineLimit(1...8)
                .accessibilityIdentifier("reply-input")
                .padding(.leading, 14)
                .padding(.trailing, 46)
                .padding(.vertical, 12)
                .frame(minHeight: 42)
                .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(SteerColors.softSeparator, lineWidth: 1)
                }
                .onKeyPress(keys: [.return], phases: .down) { keyPress in
                    if keyPress.modifiers.contains(.shift) {
                        return .ignored
                    }
                    submitReply()
                    return .handled
                }

            if canSend {
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
                .padding(.bottom, 5)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Send reply")
            }
        }
        .animation(.snappy(duration: 0.16), value: canSend)
    }
}

private struct AttachmentRow: View {
    let attachments: [ReplyAttachment]
    let onRemove: (ReplyAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentThumbnail(attachment: attachment, onRemove: { onRemove(attachment) })
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 2)
        }
    }
}

private struct AttachmentThumbnail: View {
    let attachment: ReplyAttachment
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            thumbnailImage
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(SteerColors.softSeparator, lineWidth: 1)
                }
                .help(attachment.url.path)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white)
                    .background(Circle().fill(Color.black.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .padding(2)
            .accessibilityLabel("Remove attachment")
            .opacity(isHovered ? 1 : 0.85)
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let nsImage = NSImage(contentsOf: attachment.url) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 64)
                .clipped()
        } else {
            Rectangle()
                .fill(SteerColors.subtleFill)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(SteerColors.tertiaryInk)
                }
        }
    }
}

