import SwiftUI
import SteerCore

/// Compact rounded capsule with a colored dot + Mac display label.
/// Sits in the InboxView header (top-right) per
/// IOS_PRE_CONNECTION_ONBOARDING.md "Persistent Mac Connection
/// Indicator". Tapping opens MacSyncStatusView.
struct MacConnectionChip: View {
    let state: DevicePresenceObserver.State
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(state.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SteerColors.secondaryInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                Group {
                    if #available(iOS 26.0, *) {
                        Capsule().fill(.regularMaterial)
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
            )
            .overlay(Capsule().stroke(SteerColors.softSeparator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mac connection: \(state.label)")
    }

    private var dotColor: Color {
        switch state {
        case .demo: return SteerColors.tertiaryInk
        case .neverConnected: return SteerColors.tertiaryInk
        case .connected: return SteerColors.running
        case .stale: return SteerColors.waiting
        case .offline: return SteerColors.disconnected
        case .error: return SteerColors.blocked
        }
    }
}

/// Sheet shown when the user taps the chip. Surfaces the live state,
/// the underlying Mac device row, and recovery instructions matched
/// to the current state — copy verbatim from
/// IOS_PRE_CONNECTION_ONBOARDING.md.
struct MacSyncStatusView: View {
    @ObservedObject var observer: DevicePresenceObserver
    @Environment(\.dismiss) private var dismiss

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

    private var primaryMac: DeviceSnapshot? {
        observer.devices.filter { $0.platform == "mac" }
            .max(by: { $0.lastSeenAt < $1.lastSeenAt })
    }

    private var stateColor: Color {
        switch observer.state {
        case .demo: return SteerColors.tertiaryInk
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
        case .neverConnected: return "No Mac yet"
        case .connected: return "Connected"
        case .stale: return "Idle"
        case .offline: return "Offline"
        case .error: return "Sync issue"
        }
    }

    private var recoveryTitle: String {
        switch observer.state {
        case .neverConnected: return "Set Up Mac First"
        case .stale, .offline: return "Bring Your Mac Back Online"
        case .error: return "Try Again"
        case .connected, .demo: return "What Now"
        }
    }

    private var recoverySteps: [String] {
        switch observer.state {
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
