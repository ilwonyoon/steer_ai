import SwiftUI
import SteerCore

struct InboxView: View {
    @ObservedObject var inbox: CloudKitInbox
    @State private var selected: CardSnapshot?

    var body: some View {
        NavigationStack {
            Group {
                if inbox.isLoading && inbox.cards.isEmpty {
                    ProgressView().padding()
                } else if let error = inbox.loadError, inbox.cards.isEmpty {
                    ContentUnavailableView("Can't reach iCloud", systemImage: "icloud.slash", description: Text(error))
                } else if inbox.cards.isEmpty {
                    ContentUnavailableView(
                        "No cards yet",
                        systemImage: "tray",
                        description: Text("Open Steer for Mac, turn on iCloud sync, and let a wrapped session ask a question.")
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
                Button {
                    Task { await inbox.fetchAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .sheet(item: $selected) { card in
                CardDetailView(card: card, inbox: inbox)
            }
        }
    }
}

private struct CardRow: View {
    let card: CardSnapshot

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

extension CardSnapshot: Identifiable {
    public var id: String { cardId }
}
