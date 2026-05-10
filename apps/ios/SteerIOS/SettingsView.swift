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
            NavigationLink {
                WhatSyncsView()
            } label: {
                LinkLabel(title: "What Syncs?", icon: "arrow.triangle.2.circlepath")
            }
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
                LinkLabel(title: "Report an Issue", icon: "exclamationmark.bubble")
            }
            Link(destination: URL(string: "https://github.com/ilwonyoon/steer_ai/issues")!) {
                LinkLabel(title: "Browse Known Issues", icon: "list.bullet.rectangle")
            }
            Link(destination: URL(string: "https://steer.ai/privacy")!) {
                LinkLabel(title: "Privacy Policy", icon: "hand.raised")
            }
            Link(destination: URL(string: "https://steer.ai/terms")!) {
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
    let title: String
    let icon: String

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
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
