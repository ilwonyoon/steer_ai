import SwiftUI
import SteerCore

/// Root of the Settings tab. Holds account, privacy, and (later) any
/// runtime toggles. Mirrors what the Mac Settings… window exposes.
struct SettingsView: View {
    @ObservedObject var inbox: SyncInbox
    @State private var confirmsDeletion = false
    @State private var isDeleting = false

    private let privacyURL = URL(string: "https://steer.ai/privacy")!
    private let termsURL = URL(string: "https://steer.ai/terms")!

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if case .signedIn(let user) = inbox.status {
                        if let name = user.displayName, !name.isEmpty {
                            LabeledRow(label: "Name", value: name)
                        }
                        if let email = user.appleEmail, !email.isEmpty {
                            LabeledRow(label: "Apple Relay", value: email)
                        }
                        LabeledRow(label: "User ID", value: shortId(user.userId), monospaced: true)
                    } else {
                        Text("Not signed in")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Account")
                }

                Section {
                    Link("Privacy Policy", destination: privacyURL)
                    Link("Terms of Service", destination: termsURL)
                }

                if inbox.isSignedIn {
                    Section {
                        Button("Sign Out") {
                            inbox.signOut()
                        }

                        Button(role: .destructive) {
                            confirmsDeletion = true
                        } label: {
                            HStack {
                                Text(isDeleting ? "Deleting Account..." : "Delete Account")
                                if isDeleting {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isDeleting)
                    } footer: {
                        Text("Deleting your account removes relay sync data. Local Mac files are not deleted.")
                    }
                }

                if let error = inbox.lastError {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    LabeledRow(label: "App", value: "Steer iOS")
                    LabeledRow(label: "Version", value: appVersion, monospaced: true)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Delete your Steer relay account?",
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
                Text("This removes your relay account, synced cards, queued replies, and session metadata from Steer's server.")
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }

    private func shortId(_ id: String) -> String {
        guard id.count > 16 else { return id }
        let head = id.prefix(8)
        let tail = id.suffix(6)
        return "\(head)…\(tail)"
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
