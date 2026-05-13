import SwiftUI
import SteerCore

/// iOS-conventional two-level Settings:
///   Top level shows only what the user actually scans for —
///     • who they're signed in as (a tappable identity card)
///     • support links (Privacy / Terms)
///     • destructive: Sign Out
///   Identity details (Apple relay email, internal user id) and the
///   Delete Account action move one tap deeper into the Account
///   detail screen.  Mirrors how the system Settings app surfaces
///   Apple ID: name + photo on top, the long technical fields are
///   inside.
struct SettingsView: View {
    @ObservedObject var inbox: SyncInbox
    /// Settings is presented as a sheet by InboxView. Dismiss it
    /// automatically after Sign Out so the user lands on the
    /// signed-out main screen (with the Sign in with Apple button)
    /// instead of being stuck inside a Settings list whose every
    /// row is now meaningless. Without this dismiss the only way
    /// out is Done in the navigation bar, which felt like one extra
    /// hop after every sign-out.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                identitySection
                syncSection
                supportSection
                if inbox.isSignedIn {
                    Section {
                        Button("Sign Out", role: .destructive) {
                            inbox.signOut()
                            dismiss()
                        }
                    }
                }
                if let error = inbox.lastError {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var syncSection: some View {
        Section {
            NotificationsRow(inbox: inbox)
        } header: {
            Text("Sync")
        }
    }

    @ViewBuilder
    private var identitySection: some View {
        Section {
            if case .signedIn(let user) = inbox.status {
                NavigationLink {
                    AccountDetailView(inbox: inbox, user: user)
                } label: {
                    IdentityRow(user: user)
                }
            } else {
                Text("Not signed in")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var supportSection: some View {
        Section {
            Link(destination: URL(string: "https://github.com/ilwonyoon/steer_ai/issues/new")!) {
                // Real GitHub mark instead of an SF Symbol so users
                // recognize where the link goes at a glance. Octicons
                // mark-github (CC0) — see Assets.xcassets.
                LinkLabel(title: "Report an Issue", assetName: "github-mark")
            }
            // Support is a real human inbox — opens Mail composer
            // with a pre-filled subject so the user doesn't have to
            // write one. mailto links go straight through SwiftUI's
            // `Link` without extra plumbing.
            Link(destination: URL(string: "mailto:superwedge.labs@gmail.com?subject=Steer%20Feedback")!) {
                LinkLabel(title: "Support", icon: "questionmark.circle")
            }
            // Cloudflare Pages routes for the legal site live on
            // steer-legal.pages.dev (see legal-site worktree). The
            // steer.ai apex is reserved for the marketing site that
            // doesn't host these pages yet, so we link directly to
            // the deployed Pages instance instead of routing through
            // an unstable redirect.
            Link(destination: URL(string: "https://steer-legal.pages.dev/privacy/")!) {
                LinkLabel(title: "Privacy Policy", icon: "hand.raised")
            }
            Link(destination: URL(string: "https://steer-legal.pages.dev/terms/")!) {
                LinkLabel(title: "Terms of Service", icon: "doc.text")
            }
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text(appVersion)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("About")
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }
}

private struct IdentityRow: View {
    let user: SyncUser

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Text(initials)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("Apple ID · iPhone Sync")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var displayName: String {
        if let n = user.displayName, !n.isEmpty { return n }
        return "Signed in"
    }

    private var initials: String {
        guard let n = user.displayName, let first = n.first else { return "—" }
        return String(first).uppercased()
    }
}

private struct LinkLabel: View {
    enum Source {
        case sfSymbol(String)
        case asset(String)
    }
    let title: String
    let source: Source

    init(title: String, icon: String) {
        self.title = title
        self.source = .sfSymbol(icon)
    }

    init(title: String, assetName: String) {
        self.title = title
        self.source = .asset(assetName)
    }

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(.primary)
        } icon: {
            switch source {
            case .sfSymbol(let name):
                Image(systemName: name)
                    .foregroundStyle(.secondary)
            case .asset(let name):
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Toggle for push notifications. iOS doesn't let an app revoke its
/// own notification grant — you can only ask for it once via the
/// system prompt, after that the user has to leave the app and
/// flip the switch in Settings. So this control behaves like a
/// shortcut, not a stored preference:
///   - Off + permission .notDetermined → flipping on triggers the
///     system prompt
///   - Off + permission .denied        → flipping on deep-links to
///     Settings so the user can re-enable
///   - On (permission .granted)        → flipping off deep-links to
///     Settings; we can't turn it off ourselves
/// The underlying source of truth is `inbox.notificationPermission`,
/// not a local @State — that way switching to Settings, flipping the
/// real toggle, and coming back updates the row automatically.
private struct NotificationsRow: View {
    @ObservedObject var inbox: SyncInbox

    var body: some View {
        Toggle(isOn: bindingForToggle) {
            Label {
                Text("Notifications")
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: iconName)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// `.provisional` (Apple's silent-quiet notifications) counts as
    /// "on" for the toggle — pushes still arrive, just without
    /// banners. Anything else reads as off.
    private var isOn: Bool {
        switch inbox.notificationPermission {
        case .granted, .provisional: return true
        case .denied, .notDetermined, .unknown: return false
        }
    }

    private var iconName: String {
        isOn ? "bell" : "bell.slash"
    }

    private var bindingForToggle: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { newValue in
                handleToggle(newValue: newValue)
            }
        )
    }

    private func handleToggle(newValue: Bool) {
        switch (inbox.notificationPermission, newValue) {
        case (.notDetermined, true), (.unknown, true):
            // First-time: trigger the system prompt. The
            // didChangeAuthorization observer in SyncInbox will
            // update `notificationPermission` and the toggle flips
            // on its own once Apple's callback fires.
            Task { await inbox.requestNotificationPermissionIfNeeded() }
        case (.denied, true), (.granted, false), (.provisional, false):
            // iOS won't let us turn it on after denial or off after
            // grant. Send the user to the per-app Settings page.
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        default:
            break
        }
    }
}

/// Account detail — second tier. The technical / sensitive bits
/// (Apple relay address, server-assigned user id, account deletion)
/// live here so the top-level Settings stays scannable.
struct AccountDetailView: View {
    @ObservedObject var inbox: SyncInbox
    let user: SyncUser

    @State private var confirmsDeletion = false
    @State private var isDeleting = false
    /// Same reasoning as SettingsView: after the account is gone the
    /// signed-in UI in the parent sheet doesn't make sense, so
    /// dismiss out to the main screen.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                if let name = user.displayName, !name.isEmpty {
                    LabeledRow(label: "Name", value: name)
                }
                if let email = user.appleEmail, !email.isEmpty {
                    LabeledRow(label: "Apple Relay", value: email, monospaced: true)
                }
            } header: {
                Text("Identity")
            }

            Section {
                LabeledRow(label: "User ID", value: user.userId, monospaced: true)
            } header: {
                Text("Server")
            }

            Section {
                Button(role: .destructive) {
                    confirmsDeletion = true
                } label: {
                    HStack {
                        Text(isDeleting ? "Deleting Account…" : "Delete Account")
                        if isDeleting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isDeleting)
            } footer: {
                Text("Deletes your server data and signs you out. Your Mac files are untouched.")
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete your account?",
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                Task {
                    isDeleting = true
                    await inbox.deleteAccount()
                    isDeleting = false
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Mac data is untouched.")
        }
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(monospaced ? .system(size: 13, design: .monospaced) : .system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
