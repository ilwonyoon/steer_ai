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
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(inbox.cards, id: \.cardId) { card in
                                Button { selected = card } label: {
                                    InboxCardRow(card: card)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                    .refreshable { await inbox.reload() }
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

private struct InboxCardRow: View {
    let card: CardPayload

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(CardCategory.color(for: card.category))
                .frame(width: 4)
                .cornerRadius(2)

            VStack(alignment: .leading, spacing: 8) {
                CardMetaRow(card: card)
                Text(card.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(card.summary)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct CardMetaRow: View {
    let card: CardPayload

    private var provider: String {
        card.payload?["provider"]?.value.stringValue ?? "agent"
    }
    private var project: String? {
        card.payload?["project"]?.value.stringValue
    }
    private var branch: String? {
        card.payload?["branchLabel"]?.value.stringValue
    }

    var body: some View {
        HStack(spacing: 6) {
            CategoryBadge(category: card.category)
            if let project, !project.isEmpty {
                Text(project)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let branch, !branch.isEmpty {
                Text("· \(branch)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

struct CategoryBadge: View {
    let category: String
    var body: some View {
        Text(category.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(CardCategory.color(for: category))
            .clipShape(Capsule())
    }
}

enum CardCategory {
    static func color(for category: String) -> Color {
        switch category {
        case "blocker": return Color.red
        case "question": return Color.blue
        case "decision": return Color.purple
        case "waiting": return Color.orange
        case "completion": return Color.green
        default: return Color.gray
        }
    }
}

extension AnyCodableValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
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
