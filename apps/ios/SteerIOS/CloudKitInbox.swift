import Foundation
import CloudKit
import SteerCore

@MainActor
final class CloudKitInbox: ObservableObject {
    @Published var cards: [CardSnapshot] = []
    @Published var loadError: String?
    @Published var isLoading = false

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let deviceId: String

    init() {
        self.container = CKContainer(identifier: CloudKitFields.containerIdentifier)
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: CloudKitFields.zoneName, ownerName: CKCurrentUserDefaultName)
        self.deviceId = CloudKitInbox.resolveDeviceId()
    }

    /// Public so SwiftUI .task can call into it. Boots the zone, runs an
    /// initial query, then leaves the change-token poll to refresh().
    func start() async {
        await fetchAll()
    }

    func fetchAll() async {
        isLoading = true
        defer { isLoading = false }

        let query = CKQuery(recordType: CloudKitFields.Card.recordType, predicate: NSPredicate(value: true))
        do {
            let result = try await database.records(matching: query, inZoneWith: zoneID)
            let decoded: [CardSnapshot] = result.matchResults.compactMap { (_, recordResult) -> CardSnapshot? in
                guard case let .success(record) = recordResult else { return nil }
                return CloudKitInbox.decodeCard(record)
            }
            cards = decoded.sorted { $0.updatedAt < $1.updatedAt }
            loadError = nil
        } catch let error as CKError where error.code == .notAuthenticated {
            loadError = "Sign in to iCloud in Settings to receive Steer cards."
        } catch let error as CKError where error.code == .zoneNotFound {
            // Zone hasn't been created yet by the Mac. Treat as empty.
            cards = []
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Send a reply for `card`. The Mac claims the resulting
    /// InstructionRequest record and injects into the wrapper.
    func sendReply(text: String, for card: CardSnapshot) async {
        let request = InstructionRequest(
            instructionId: UUID().uuidString,
            targetSessionId: card.sessionId,
            text: text,
            createdAt: Date(),
            createdByDeviceId: deviceId
        )
        let recordID = CKRecord.ID(recordName: request.instructionId, zoneID: zoneID)
        let record = CKRecord(recordType: CloudKitFields.Instruction.recordType, recordID: recordID)
        record[CloudKitFields.Instruction.instructionId] = request.instructionId as CKRecordValue
        record[CloudKitFields.Instruction.targetSessionId] = request.targetSessionId as CKRecordValue
        record[CloudKitFields.Instruction.text] = request.text as CKRecordValue
        record[CloudKitFields.Instruction.createdAt] = request.createdAt as CKRecordValue
        record[CloudKitFields.Instruction.createdByDeviceId] = request.createdByDeviceId as CKRecordValue
        record[CloudKitFields.Instruction.status] = request.status.rawValue as CKRecordValue
        do {
            _ = try await database.save(record)
        } catch {
            loadError = "Reply send failed: \(error.localizedDescription)"
        }
    }

    private static func decodeCard(_ record: CKRecord) -> CardSnapshot? {
        guard
            let cardId = record[CloudKitFields.Card.cardId] as? String,
            let sessionId = record[CloudKitFields.Card.sessionId] as? String,
            let category = record[CloudKitFields.Card.category] as? String,
            let title = record[CloudKitFields.Card.title] as? String,
            let summary = record[CloudKitFields.Card.summary] as? String,
            let createdAt = record[CloudKitFields.Card.createdAt] as? Date,
            let updatedAt = record[CloudKitFields.Card.updatedAt] as? Date
        else { return nil }

        let priority = (record[CloudKitFields.Card.priority] as? String) ?? "normal"
        let actionPrompt = record[CloudKitFields.Card.actionPrompt] as? String
        let state = (record[CloudKitFields.Card.state] as? String) ?? "active"
        let fingerprint = (record[CloudKitFields.Card.sourceFingerprint] as? String) ?? cardId

        let terminalLines = decodeJSON([String].self, record[CloudKitFields.Card.terminalLinesJSON] as? String) ?? []
        let options = decodeJSON([String].self, record[CloudKitFields.Card.optionsJSON] as? String) ?? []

        return CardSnapshot(
            cardId: cardId,
            sessionId: sessionId,
            category: category,
            priority: priority,
            title: title,
            summary: summary,
            actionPrompt: actionPrompt,
            terminalLines: terminalLines,
            options: options,
            state: state,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sourceFingerprint: fingerprint
        )
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, _ raw: String?) -> T? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func resolveDeviceId() -> String {
        let key = "ai.steer.ios.cloudkit.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}
