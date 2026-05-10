import SwiftUI

/// "What Syncs?" — required disclosure of what data leaves the user's
/// Mac through the relay, per IOS_PRE_CONNECTION_ONBOARDING.md and
/// PRIVACY_POLICY.md. Reachable from iOS Settings without sign-in,
/// and again from Account/Settings after sign-in.
///
/// Mirrors the Mac-side disclosure in SteerSettings.IPhoneSyncSection
/// — keep both lists in sync when fields are added.
struct WhatSyncsView: View {
    var body: some View {
        List {
            Section {
                ForEach(SyncDisclosure.synced, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(item)
                    }
                }
            } header: {
                Text("What Syncs")
            } footer: {
                Text("Synced through the Steer relay between your own Mac and iPhone signed in with the same Apple account.")
            }

            Section {
                ForEach(SyncDisclosure.notSynced, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                        Text(item)
                    }
                }
            } header: {
                Text("What Does Not Sync")
            } footer: {
                Text("Full raw transcripts, environment variables, and arbitrary file contents stay on your Mac. Terminal excerpts may still contain sensitive data if the underlying CLI prints it.")
            }

            Section {
                Text("Live delivery requires Steer for Mac to be running. iPhone replies queue while the Mac is offline and deliver as soon as it returns.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Delivery")
            }
        }
        .navigationTitle("What Syncs?")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Centralized list so iOS and Mac can show the same disclosure copy.
enum SyncDisclosure {
    static let synced: [String] = [
        "Card title and summary",
        "Short terminal excerpt that triggered the card",
        "Suggested replies",
        "Project, provider, and branch labels",
        "Replies you send from iPhone",
        "Delivery status and failure reason",
        "Account identifier from Sign in with Apple"
    ]

    static let notSynced: [String] = [
        "Full raw transcripts",
        "Environment variables",
        "Attachments and arbitrary file contents",
        "Anything outside Steer-managed CLI sessions"
    ]
}
