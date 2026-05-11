import SwiftUI
import SteerCore

/// Shows the count of in-flight / failed replies as a small capsule
/// chip. Tapping reveals a list with retry/cancel for any failed row.
/// Mirrors the Mac RunningBadge pattern but for outgoing instructions.
struct PendingRepliesChip: View {
    let pending: [SyncInbox.PendingReply]
    let onRetry: (String) -> Void
    let onCancel: (String) -> Void
    @State private var expanded = false

    private var sendingCount: Int {
        pending.filter { $0.status == .sending }.count
    }
    private var failedCount: Int {
        pending.reduce(0) { acc, p in
            if case .failed = p.status { return acc + 1 }
            return acc
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chip
            if expanded {
                ForEach(pending) { row in
                    PendingReplyRow(reply: row, onRetry: onRetry, onCancel: onCancel)
                }
            }
        }
    }

    private var chip: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(failedCount > 0 ? SteerColors.blocked : SteerColors.running)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SteerColors.secondaryInk)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SteerColors.tertiaryInk)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(SteerColors.cardBackground, in: Capsule())
            .overlay(Capsule().stroke(SteerColors.softSeparator, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var label: String {
        var parts: [String] = []
        if sendingCount > 0 { parts.append("\(sendingCount) sending") }
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        return parts.joined(separator: " · ")
    }
}

private struct PendingReplyRow: View {
    let reply: SyncInbox.PendingReply
    let onRetry: (String) -> Void
    let onCancel: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: statusIcon)
                .font(.system(size: 12))
                .foregroundStyle(statusColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(reply.cardTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(reply.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(SteerColors.secondaryInk)
                    .lineLimit(2)
                if case .failed(let reason) = reply.status {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(SteerColors.blocked)
                        .lineLimit(2)
                }
            }
            Spacer()
            if case .failed = reply.status {
                Button("Retry") { onRetry(reply.id) }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                Button {
                    onCancel(reply.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SteerColors.tertiaryInk)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(SteerColors.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(SteerColors.softSeparator, lineWidth: 1)
        )
    }

    private var statusIcon: String {
        switch reply.status {
        case .sending: return "paperplane.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
    private var statusColor: Color {
        switch reply.status {
        case .sending: return SteerColors.running
        case .failed: return SteerColors.blocked
        }
    }
}
