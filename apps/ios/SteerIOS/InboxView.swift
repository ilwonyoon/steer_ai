import SwiftUI
import SteerCore

struct InboxView: View {
    @ObservedObject var inbox: SyncInbox
    @State private var selected: CardPayload?

    var body: some View {
        NavigationStack {
            Group {
                if !inbox.isSignedIn {
                    SignInPrompt(inbox: inbox)
                } else if inbox.cards.isEmpty {
                    ContentUnavailableView(
                        "No cards yet",
                        systemImage: "tray",
                        description: Text("Open Steer for Mac, turn on iPhone Sync, and let a wrapped session ask a question.")
                    )
                } else {
                    List(inbox.cards, id: \.cardId) { card in
                        Button {
                            selected = card
                        } label: {
                            CardRow(card: card)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Steer")
            .toolbar {
                if inbox.isSignedIn {
                    Button {
                        Task { await inbox.reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(item: $selected) { card in
                CardDetailView(card: card, inbox: inbox)
            }
        }
    }
}

private struct CardRow: View {
    let card: CardPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Text(card.summary)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 6)
    }
}

private struct SignInPrompt: View {
    @ObservedObject var inbox: SyncInbox
    @State private var isSigningIn = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Sign in to see Steer cards from your Mac")
                .font(.headline)
                .multilineTextAlignment(.center)
            if let err = inbox.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button {
                Task {
                    isSigningIn = true
                    await inbox.startSignInWithApple()
                    isSigningIn = false
                }
            } label: {
                HStack {
                    if isSigningIn { ProgressView().controlSize(.small) }
                    Text(isSigningIn ? "Signing in…" : "Sign in with Apple")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.black)
                .foregroundColor(.white)
                .clipShape(Capsule())
            }
            .disabled(isSigningIn)
            Spacer()
        }
        .padding()
    }
}

extension CardPayload: Identifiable {
    public var id: String { cardId }
}
