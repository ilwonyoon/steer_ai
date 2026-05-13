import SwiftUI
import SteerCore

/// Single capsule chip at the top of InboxView that surfaces ALL
/// connection-related signals — Mac presence, in-flight replies,
/// running sessions. It used to be three separate widgets
/// (MacConnectionChip, PendingRepliesChip, LiveSessionChipRow);
/// stacking them broke the user's mental model that the header
/// state ("Mac") and the activity state ("1 running") are the
/// same slot. Tapping opens MacSyncStatusView, which lists running
/// sessions and pending replies inline so the affordance now
/// matches: every chip variant has the same destination.
struct MacConnectionChip: View {
    let state: DevicePresenceObserver.State
    /// Sessions the user has replied to where the terminal hasn't
    /// produced a fresh card yet. Derived locally on iPhone from
    /// `SyncInbox.activeSessionIds` (sending ∪ injected).
    var runningCount: Int = 0
    /// Replies that the Mac rejected, network failed, etc. The user
    /// can retry/cancel them from the sheet.
    var failedCount: Int = 0
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(SteerColors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .steerGlass(shape: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mac connection: \(label).")
    }

    /// "running" already counts sending + injected pending rows
    /// (the SyncInbox `activeSessionIds` set), so we no longer
    /// separately label sending. Failed is the only orthogonal
    /// state — the user has to fix it.
    private var label: String {
        var parts: [String] = []
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        if case .connected = state, runningCount > 0 {
            parts.append("\(runningCount) running")
        }
        if parts.isEmpty { return state.label }
        return parts.joined(separator: " · ")
    }

    /// Failed dominates the dot color — that's the actionable state.
    /// Running uses the running color (sending rolls into running),
    /// idle falls back to the connection state.
    private var dotColor: Color {
        if failedCount > 0 { return SteerColors.blocked }
        if runningCount > 0 { return SteerColors.running }
        switch state {
        case .demo: return SteerColors.tertiaryInk
        case .connecting: return SteerColors.waiting
        case .neverConnected: return SteerColors.tertiaryInk
        case .connected: return SteerColors.running
        case .stale: return SteerColors.waiting
        case .offline: return SteerColors.disconnected
        case .error: return SteerColors.blocked
        }
    }
}

/// Sheet shown when the user taps the chip. Single destination for
/// every chip variant so the affordance is consistent — Mac state,
/// running sessions (when any), and pending replies (when any) all
/// live in one list. Recovery instructions only show for states
/// where the user can do something about it (offline / stale /
/// error / neverConnected); the connected case used to surface a
/// "What Now" section but it just restated what the user already
/// knew, so we drop it.
struct MacSyncStatusView: View {
    @ObservedObject var observer: DevicePresenceObserver
    let pendingReplies: [SyncInbox.PendingReply]
    let onRetry: (String) -> Void
    let onCancel: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    /// One row per active (sending or injected) reply. Same data
    /// the chip count reflects, so the user sees a per-session
    /// breakdown of what's "running" on Mac. Failed rows fall into
    /// the Pending replies section instead.
    private var runningReplies: [SyncInbox.PendingReply] {
        pendingReplies.filter { reply in
            switch reply.status {
            case .sending, .injected: return true
            case .failed: return false
            }
        }
    }

    private var failedReplies: [SyncInbox.PendingReply] {
        pendingReplies.filter { reply in
            if case .failed = reply.status { return true }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Circle()
                            .fill(stateColor)
                            .frame(width: 8, height: 8)
                        Text(observer.state.label)
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Text(stateTitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("State")
                }

                if !runningReplies.isEmpty {
                    Section {
                        ForEach(runningReplies) { reply in
                            RunningReplyRow(reply: reply)
                        }
                    } header: {
                        Text("Running")
                    }
                }

                if !failedReplies.isEmpty {
                    Section {
                        ForEach(failedReplies) { reply in
                            PendingReplyRow(
                                reply: reply,
                                onRetry: onRetry,
                                onCancel: onCancel
                            )
                        }
                    } header: {
                        Text("Failed replies")
                    }
                }

                if let mac = primaryMac {
                    Section {
                        LabeledRow(label: "Display name", value: mac.displayName ?? "—")
                        LabeledRow(label: "Device class", value: mac.deviceClass ?? "Mac")
                        LabeledRow(label: "App version", value: mac.appVersion ?? "—", monospaced: true)
                        LabeledRow(label: "iPhone Sync", value: mac.syncEnabled ? "Enabled" : "Disabled")
                        LabeledRow(label: "Last seen", value: relative(mac.lastSeenAt))
                    } header: {
                        Text("Mac")
                    }
                }

                // Recovery steps only when the user has something to
                // fix. Connected/demo just show the live state above —
                // adding a "What Now" section restated the obvious.
                if needsRecoverySection {
                    Section {
                        ForEach(recoverySteps, id: \.self) { step in
                            Text(step)
                        }
                    } header: {
                        Text(recoveryTitle)
                    } footer: {
                        Text("Replies queue while the Mac is offline.")
                    }
                }
            }
            .navigationTitle("Mac Sync Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await observer.refresh() }
        }
    }

    private var needsRecoverySection: Bool {
        switch observer.state {
        case .neverConnected, .stale, .offline, .error: return true
        case .connecting, .connected, .demo: return false
        }
    }

    private var primaryMac: DeviceSnapshot? {
        observer.devices.filter { $0.platform == "mac" }
            .max(by: { $0.lastSeenAt < $1.lastSeenAt })
    }

    private var stateColor: Color {
        switch observer.state {
        case .demo: return SteerColors.tertiaryInk
        case .connecting: return SteerColors.waiting
        case .neverConnected: return SteerColors.tertiaryInk
        case .connected: return SteerColors.running
        case .stale: return SteerColors.waiting
        case .offline: return SteerColors.disconnected
        case .error: return SteerColors.blocked
        }
    }

    private var stateTitle: String {
        switch observer.state {
        case .demo: return "Sample workspace"
        case .connecting: return "Reaching your Mac"
        case .neverConnected: return "No Mac yet"
        case .connected: return "Connected"
        case .stale: return "Idle"
        case .offline: return "Offline"
        case .error: return "Sync issue"
        }
    }

    private var recoveryTitle: String {
        switch observer.state {
        case .connecting, .neverConnected: return "Set Up Mac First"
        case .stale, .offline: return "Bring Your Mac Back Online"
        case .error: return "Try Again"
        case .connected, .demo: return "What Now"
        }
    }

    private var recoverySteps: [String] {
        switch observer.state {
        case .connecting:
            // needsRecoverySection returns false for .connecting,
            // so this branch is never read — but switches must
            // be exhaustive.
            return []
        case .neverConnected:
            return [
                "1. Open Steer for Mac.",
                "2. Sign in with the same Apple account.",
                "3. Open Settings → iPhone Sync.",
                "4. Review What Syncs and enable sync.",
                "5. Start or resume a Steer-managed coding session."
            ]
        case .stale, .offline:
            return [
                "1. Wake or unlock the Mac.",
                "2. Open Steer for Mac.",
                "3. Confirm iPhone Sync is still enabled.",
                "4. Check that the Mac has internet access.",
                "5. Leave Steer for Mac running so it can deliver queued replies."
            ]
        case .error:
            return [
                "Pull down to retry.",
                "If the issue keeps happening, sign out and sign back in, or report the issue from Settings."
            ]
        case .connected:
            return [
                "Cards from your Mac appear here automatically.",
                "Replies you send are delivered to the matching Steer-managed session on your Mac."
            ]
        case .demo:
            return [
                "You're browsing sample data. Replies don't reach a real Mac.",
                "Tap Use Live Sync above to sign in with Apple and connect your own Mac."
            ]
        }
    }

    private func relative(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(monospaced ? .system(size: 13, design: .monospaced) : .system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct RunningReplyRow: View {
    let reply: SyncInbox.PendingReply

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(SteerColors.running)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(reply.cardTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The user's own reply text, dimmed. Helps when
                // multiple sessions are running at once and they
                // need to recall what they said.
                Text(reply.text)
                    .font(.system(size: 13))
                    .foregroundStyle(SteerColors.secondaryInk)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: statusIcon)
                .font(.system(size: 12))
                .foregroundStyle(SteerColors.tertiaryInk)
        }
        .padding(.vertical, 2)
    }

    private var statusIcon: String {
        switch reply.status {
        case .sending: return "paperplane.fill"
        case .injected: return "hourglass"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

private struct PendingReplyRow: View {
    let reply: SyncInbox.PendingReply
    let onRetry: (String) -> Void
    let onCancel: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 13))
                .foregroundStyle(statusColor)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(reply.cardTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(reply.text)
                    .font(.system(size: 14))
                    .foregroundStyle(SteerColors.secondaryInk)
                    .lineLimit(2)
                if case .failed(let reason) = reply.status {
                    Text(reason)
                        .font(.system(size: 12))
                        .foregroundStyle(SteerColors.blocked)
                        .lineLimit(2)
                }
            }
            Spacer()
            if case .failed = reply.status {
                VStack(spacing: 6) {
                    Button("Retry") { onRetry(reply.id) }
                        .font(.system(size: 14, weight: .semibold))
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
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: String {
        switch reply.status {
        case .sending: return "paperplane.fill"
        case .injected: return "hourglass"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
    private var statusColor: Color {
        switch reply.status {
        case .sending, .injected: return SteerColors.running
        case .failed: return SteerColors.blocked
        }
    }
}
