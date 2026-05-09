import Foundation
import CloudKit
import SteerCore

/// Publishes the local action card / session state to the user's
/// private CloudKit database so the iPhone Steer app can read it.
///
/// Opt-in. Default OFF until the user flips the toggle in Settings.
/// All writes go through this single object so a future privacy
/// review only has to look at one place to know what leaves the Mac.
@MainActor
final class CloudKitSync {
    static let shared = CloudKitSync()

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let deviceId: String

    private var zoneEnsured = false

    private init() {
        self.container = CKContainer(identifier: CloudKitFields.containerIdentifier)
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: CloudKitFields.zoneName, ownerName: CKCurrentUserDefaultName)
        self.deviceId = CloudKitSync.resolveDeviceId()
    }

    /// Publish a card snapshot. Caller is responsible for opt-in gating;
    /// this function does not consult the user setting.
    func publishCard(_ card: CardSnapshot) async {
        await ensureZoneExists()
        let record = makeCardRecord(card)
        do {
            _ = try await database.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Conflict — retrieve the server record's recordChangeTag and
            // retry. CloudKit doesn't have a generic upsert; merging on
            // sourceFingerprint keeps the iPhone in sync.
            if let serverRecord = error.serverRecord {
                let merged = mergeIntoServerRecord(serverRecord, with: card)
                _ = try? await database.save(merged)
            }
        } catch {
            NSLog("[CloudKitSync] publishCard failed: \(error.localizedDescription)")
        }
    }

    /// Publish session metadata so iOS can disambiguate cards across
    /// multiple wrapped CLIs at the same time.
    func publishSession(_ session: SessionSnapshot) async {
        await ensureZoneExists()
        let record = makeSessionRecord(session)
        do {
            _ = try await database.save(record)
        } catch {
            NSLog("[CloudKitSync] publishSession failed: \(error.localizedDescription)")
        }
    }

    /// Heartbeat so iPhone knows the Mac is online and likely to deliver
    /// a queued instruction.
    func publishDeviceHeartbeat(displayName: String, appVersion: String) async {
        await ensureZoneExists()
        let device = DeviceSnapshot(
            deviceId: deviceId,
            platform: "mac",
            displayName: displayName,
            lastSeenAt: Date(),
            appVersion: appVersion
        )
        let record = makeDeviceRecord(device)
        do {
            _ = try await database.save(record)
        } catch {
            NSLog("[CloudKitSync] publishDeviceHeartbeat failed: \(error.localizedDescription)")
        }
    }

    /// Pull every queued InstructionRequest the user's other devices
    /// have written. Caller should mark each one claimed/injected/failed
    /// after invoking the local delivery path.
    func fetchQueuedInstructions() async -> [InstructionRequest] {
        await ensureZoneExists()
        let predicate = NSPredicate(format: "%K == %@", CloudKitFields.Instruction.status, InstructionStatus.queued.rawValue)
        let query = CKQuery(recordType: CloudKitFields.Instruction.recordType, predicate: predicate)
        do {
            let result = try await database.records(matching: query, inZoneWith: zoneID)
            return result.matchResults.compactMap { (_, recordResult) -> InstructionRequest? in
                guard case let .success(record) = recordResult else { return nil }
                return CloudKitSync.decodeInstruction(record)
            }
        } catch let error as CKError where error.code == .zoneNotFound {
            return []
        } catch {
            NSLog("[CloudKitSync] fetchQueuedInstructions failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Update an InstructionRequest after the Mac has tried to deliver
    /// it locally.
    func updateInstructionStatus(
        _ instruction: InstructionRequest,
        status: InstructionStatus,
        failureReason: String? = nil
    ) async {
        let recordID = CKRecord.ID(recordName: instruction.instructionId, zoneID: zoneID)
        do {
            let record = try await database.record(for: recordID)
            record[CloudKitFields.Instruction.status] = status.rawValue as CKRecordValue
            record[CloudKitFields.Instruction.claimedByMacDeviceId] = deviceId as CKRecordValue
            record[CloudKitFields.Instruction.claimedAt] = Date() as CKRecordValue
            if status == .injected {
                record[CloudKitFields.Instruction.injectedAt] = Date() as CKRecordValue
            }
            if let reason = failureReason {
                record[CloudKitFields.Instruction.failureReason] = reason as CKRecordValue
            }
            _ = try await database.save(record)
        } catch {
            NSLog("[CloudKitSync] updateInstructionStatus failed: \(error.localizedDescription)")
        }
    }

    /// The Mac's stable device id, exposed so other components can tag
    /// records they create with it.
    var localDeviceId: String { deviceId }

    private static func decodeInstruction(_ record: CKRecord) -> InstructionRequest? {
        guard
            let instructionId = record[CloudKitFields.Instruction.instructionId] as? String,
            let targetSessionId = record[CloudKitFields.Instruction.targetSessionId] as? String,
            let text = record[CloudKitFields.Instruction.text] as? String,
            let createdAt = record[CloudKitFields.Instruction.createdAt] as? Date,
            let createdByDeviceId = record[CloudKitFields.Instruction.createdByDeviceId] as? String,
            let statusRaw = record[CloudKitFields.Instruction.status] as? String,
            let status = InstructionStatus(rawValue: statusRaw)
        else { return nil }

        return InstructionRequest(
            instructionId: instructionId,
            targetSessionId: targetSessionId,
            text: text,
            createdAt: createdAt,
            createdByDeviceId: createdByDeviceId,
            status: status,
            claimedByMacDeviceId: record[CloudKitFields.Instruction.claimedByMacDeviceId] as? String,
            claimedAt: record[CloudKitFields.Instruction.claimedAt] as? Date,
            injectedAt: record[CloudKitFields.Instruction.injectedAt] as? Date,
            failureReason: record[CloudKitFields.Instruction.failureReason] as? String
        )
    }

    /// Mark a card as resolved on the iPhone side by deleting its
    /// snapshot. The card row itself stays in the local SQLite for the
    /// Mac UI; only the iCloud projection is dropped.
    func deleteCard(cardId: String) async {
        let recordID = CKRecord.ID(recordName: cardId, zoneID: zoneID)
        do {
            _ = try await database.deleteRecord(withID: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            // Already absent; ignore.
        } catch {
            NSLog("[CloudKitSync] deleteCard failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Internal

    private func ensureZoneExists() async {
        if zoneEnsured { return }
        let zone = CKRecordZone(zoneID: zoneID)
        do {
            _ = try await database.save(zone)
            zoneEnsured = true
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Already exists; treat as ensured.
            zoneEnsured = true
        } catch {
            NSLog("[CloudKitSync] ensureZone failed: \(error.localizedDescription)")
        }
    }

    private func makeCardRecord(_ card: CardSnapshot) -> CKRecord {
        let recordID = CKRecord.ID(recordName: card.cardId, zoneID: zoneID)
        let record = CKRecord(recordType: CloudKitFields.Card.recordType, recordID: recordID)
        record[CloudKitFields.Card.cardId] = card.cardId as CKRecordValue
        record[CloudKitFields.Card.sessionId] = card.sessionId as CKRecordValue
        record[CloudKitFields.Card.category] = card.category as CKRecordValue
        record[CloudKitFields.Card.priority] = card.priority as CKRecordValue
        record[CloudKitFields.Card.title] = card.title as CKRecordValue
        record[CloudKitFields.Card.summary] = card.summary as CKRecordValue
        if let actionPrompt = card.actionPrompt {
            record[CloudKitFields.Card.actionPrompt] = actionPrompt as CKRecordValue
        }
        record[CloudKitFields.Card.terminalLinesJSON] = encodeJSON(card.terminalLines) as CKRecordValue
        record[CloudKitFields.Card.optionsJSON] = encodeJSON(card.options) as CKRecordValue
        record[CloudKitFields.Card.state] = card.state as CKRecordValue
        record[CloudKitFields.Card.createdAt] = card.createdAt as CKRecordValue
        record[CloudKitFields.Card.updatedAt] = card.updatedAt as CKRecordValue
        record[CloudKitFields.Card.sourceFingerprint] = card.sourceFingerprint as CKRecordValue
        return record
    }

    private func mergeIntoServerRecord(_ server: CKRecord, with card: CardSnapshot) -> CKRecord {
        server[CloudKitFields.Card.summary] = card.summary as CKRecordValue
        server[CloudKitFields.Card.title] = card.title as CKRecordValue
        server[CloudKitFields.Card.state] = card.state as CKRecordValue
        server[CloudKitFields.Card.terminalLinesJSON] = encodeJSON(card.terminalLines) as CKRecordValue
        server[CloudKitFields.Card.optionsJSON] = encodeJSON(card.options) as CKRecordValue
        server[CloudKitFields.Card.updatedAt] = card.updatedAt as CKRecordValue
        server[CloudKitFields.Card.sourceFingerprint] = card.sourceFingerprint as CKRecordValue
        return server
    }

    private func makeSessionRecord(_ session: SessionSnapshot) -> CKRecord {
        let recordID = CKRecord.ID(recordName: session.sessionId, zoneID: zoneID)
        let record = CKRecord(recordType: CloudKitFields.Session.recordType, recordID: recordID)
        record[CloudKitFields.Session.sessionId] = session.sessionId as CKRecordValue
        record[CloudKitFields.Session.provider] = session.provider as CKRecordValue
        record[CloudKitFields.Session.projectName] = session.projectName as CKRecordValue
        if let branchLabel = session.branchLabel {
            record[CloudKitFields.Session.branchLabel] = branchLabel as CKRecordValue
        }
        record[CloudKitFields.Session.runState] = session.runState as CKRecordValue
        record[CloudKitFields.Session.lastActivityAt] = session.lastActivityAt as CKRecordValue
        record[CloudKitFields.Session.macDeviceId] = session.macDeviceId as CKRecordValue
        record[CloudKitFields.Session.isDeliverable] = (session.isDeliverable ? 1 : 0) as CKRecordValue
        return record
    }

    private func makeDeviceRecord(_ device: DeviceSnapshot) -> CKRecord {
        let recordID = CKRecord.ID(recordName: device.deviceId, zoneID: zoneID)
        let record = CKRecord(recordType: CloudKitFields.Device.recordType, recordID: recordID)
        record[CloudKitFields.Device.deviceId] = device.deviceId as CKRecordValue
        record[CloudKitFields.Device.platform] = device.platform as CKRecordValue
        record[CloudKitFields.Device.displayName] = device.displayName as CKRecordValue
        record[CloudKitFields.Device.lastSeenAt] = device.lastSeenAt as CKRecordValue
        record[CloudKitFields.Device.appVersion] = device.appVersion as CKRecordValue
        return record
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func resolveDeviceId() -> String {
        let key = "ai.steer.mac.cloudkit.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}
