import Foundation
import CloudKit
import SteerCore

@MainActor
final class CloudKitInbox: ObservableObject {
    @Published var cards: [CardSnapshot] = []
    @Published var loadError: String?
    @Published var isLoading = false

    private let zoneID: CKRecordZone.ID
    private let deviceId: String

    private var resolved: (container: CKContainer, database: CKDatabase)?

    init() {
        self.zoneID = CKRecordZone.ID(zoneName: CloudKitFields.zoneName, ownerName: CKCurrentUserDefaultName)
        self.deviceId = CloudKitInbox.resolveDeviceId()
    }

    /// Public so SwiftUI .task can call into it. Boots the zone, runs an
    /// initial query, then leaves the change-token poll to refresh().
    func start() async {
        await fetchAll()
    }

    /// Resolve the CloudKit container lazily. The container init traps
    /// (EXC_BREAKPOINT) when the running binary lacks the matching
    /// `com.apple.developer.icloud-container-identifiers` entitlement —
    /// which is what happens for ad-hoc / linker-signed simulator builds.
    /// Catching it would require Objective-C exception bridging that
    /// CloudKit doesn't provide, so we simply detect missing entitlements
    /// up-front and surface a friendly message instead of letting the
    /// app crash on launch.
    private func resolveDatabaseIfNeeded() -> CKDatabase? {
        if let resolved { return resolved.database }
        guard CloudKitInbox.hasICloudEntitlement() else {
            loadError = "iCloud disabled for this build (no entitlement). Sign and embed a provisioning profile to enable."
            return nil
        }
        let container = CKContainer(identifier: CloudKitFields.containerIdentifier)
        let database = container.privateCloudDatabase
        resolved = (container, database)
        return database
    }

    func fetchAll() async {
        isLoading = true
        defer { isLoading = false }

        guard let database = resolveDatabaseIfNeeded() else {
            cards = []
            return
        }

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
            cards = []
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Send a reply for `card`. The Mac claims the resulting
    /// InstructionRequest record and injects into the wrapper.
    func sendReply(text: String, for card: CardSnapshot) async {
        guard let database = resolveDatabaseIfNeeded() else { return }
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

    /// Best-effort: only consider iCloud usable when an embedded
    /// provisioning profile asserts the container. Without one,
    /// `CKContainer(identifier:)` traps on init for ad-hoc / linker-
    /// signed simulator builds. We err on the side of NOT calling into
    /// CloudKit when the binary can't prove its entitlement.
    private static func hasICloudEntitlement() -> Bool {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision")
                  ?? Bundle.main.path(forResource: "embedded", ofType: "provisionprofile"),
              let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return false
        }
        guard let s = String(data: raw, encoding: .ascii) ?? String(data: raw, encoding: .utf8) else {
            return false
        }
        return s.contains(CloudKitFields.containerIdentifier)
    }
}
