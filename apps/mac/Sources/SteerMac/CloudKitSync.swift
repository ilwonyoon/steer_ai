import Foundation
import SteerCore

/// Publishes the local action card / session state to the user's
/// private CloudKit database via CloudKit Web Services REST API.
///
/// This Mac build cannot use the native `CKContainer` SDK because
/// adding `com.apple.developer.icloud-services` entitlement to a
/// Direct-Distribution / Developer ID-signed Mac app makes launchd
/// reject the bundle with POSIX 163. Instead we talk REST against
/// `api.apple-cloudkit.com` using a public API token + per-user
/// `ckWebAuthToken` obtained through a sign-in sheet on first run.
///
/// iOS keeps using the native CloudKit SDK against the same shared
/// `iCloud.ai.steer.mac` container, so both platforms read/write the
/// same set of records.
///
/// All writes go through this single object so a future privacy
/// review only has to look at one place to know what leaves the Mac.
@MainActor
final class CloudKitSync: ObservableObject {
    static let shared = CloudKitSync()

    /// Surfaced to the UI so the root view can present a sign-in sheet
    /// the moment a publish call fails with `authenticationRequired`.
    @Published var pendingAuthURL: URL?

    private let client: CloudKitWebClient
    private let deviceId: String

    private init() {
        self.client = CloudKitWebClient(
            apiToken: CloudKitFields.cloudKitWebAPIToken
        )
        self.deviceId = CloudKitSync.resolveDeviceId()
    }

    /// True once the user has completed sign-in. The UI should gate
    /// publish-toggle and sync banners on this.
    var isSignedIn: Bool { client.hasWebAuthToken }

    /// Hand control back to the auth flow — used by the sign-in sheet
    /// after WKWebView captures a `ckWebAuthToken`.
    func storeWebAuthToken(_ token: String) {
        client.setWebAuthToken(token)
        pendingAuthURL = nil
    }

    func clearAuth() { client.clearWebAuthToken() }

    /// Publish a card snapshot. Caller is responsible for opt-in gating;
    /// this function does not consult the user setting.
    func publishCard(_ card: CardSnapshot) async {
        let op = CloudKitWebClient.RecordModify(
            operationType: "forceUpdate",
            recordName: card.cardId,
            recordType: CloudKitFields.Card.recordType,
            fields: cardFields(card)
        )
        await runModify([op], label: "publishCard")
    }

    /// Publish session metadata so iOS can disambiguate cards across
    /// multiple wrapped CLIs at the same time.
    func publishSession(_ session: SessionSnapshot) async {
        let op = CloudKitWebClient.RecordModify(
            operationType: "forceUpdate",
            recordName: session.sessionId,
            recordType: CloudKitFields.Session.recordType,
            fields: sessionFields(session)
        )
        await runModify([op], label: "publishSession")
    }

    /// Heartbeat so iPhone knows the Mac is online and likely to deliver
    /// a queued instruction.
    func publishDeviceHeartbeat(displayName: String, appVersion: String) async {
        let device = DeviceSnapshot(
            deviceId: deviceId,
            platform: "mac",
            displayName: displayName,
            lastSeenAt: Date(),
            appVersion: appVersion
        )
        let op = CloudKitWebClient.RecordModify(
            operationType: "forceUpdate",
            recordName: device.deviceId,
            recordType: CloudKitFields.Device.recordType,
            fields: deviceFields(device)
        )
        await runModify([op], label: "publishDeviceHeartbeat")
    }

    /// Pull every queued InstructionRequest the user's other devices
    /// have written. Caller should mark each one claimed/injected/failed
    /// after invoking the local delivery path.
    func fetchQueuedInstructions() async -> [InstructionRequest] {
        do {
            let records = try await client.queryRecords(
                recordType: CloudKitFields.Instruction.recordType,
                filterBy: [
                    CloudKitWebClient.QueryFilter(
                        fieldName: CloudKitFields.Instruction.status,
                        comparator: "EQUALS",
                        fieldValue: InstructionStatus.queued.rawValue
                    )
                ]
            )
            return records.compactMap { decodeInstruction($0) }
        } catch CloudKitWebClient.ClientError.authenticationRequired(let url) {
            pendingAuthURL = url
            return []
        } catch {
            NSLog("[CloudKitSync] fetchQueuedInstructions failed: \(error)")
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
        var fields: [String: Any] = [
            CloudKitFields.Instruction.status: status.rawValue,
            CloudKitFields.Instruction.claimedByMacDeviceId: deviceId,
            CloudKitFields.Instruction.claimedAt: timestampMs(Date())
        ]
        if status == .injected {
            fields[CloudKitFields.Instruction.injectedAt] = timestampMs(Date())
        }
        if let reason = failureReason {
            fields[CloudKitFields.Instruction.failureReason] = reason
        }
        let op = CloudKitWebClient.RecordModify(
            operationType: "update",
            recordName: instruction.instructionId,
            recordType: CloudKitFields.Instruction.recordType,
            fields: fields
        )
        await runModify([op], label: "updateInstructionStatus")
    }

    /// Mark a card as resolved on the iPhone side by deleting its
    /// snapshot. The card row itself stays in the local SQLite for the
    /// Mac UI; only the iCloud projection is dropped.
    func deleteCard(cardId: String) async {
        let op = CloudKitWebClient.RecordModify(
            operationType: "delete",
            recordName: cardId,
            recordType: CloudKitFields.Card.recordType,
            fields: [:]
        )
        await runModify([op], label: "deleteCard")
    }

    /// The Mac's stable device id, exposed so other components can tag
    /// records they create with it.
    var localDeviceId: String { deviceId }

    // MARK: - Internal

    private func runModify(_ ops: [CloudKitWebClient.RecordModify], label: String) async {
        do {
            _ = try await client.modifyRecords(ops)
        } catch CloudKitWebClient.ClientError.authenticationRequired(let url) {
            pendingAuthURL = url
        } catch {
            NSLog("[CloudKitSync] \(label) failed: \(error)")
        }
    }

    private func cardFields(_ card: CardSnapshot) -> [String: Any] {
        var fields: [String: Any] = [
            CloudKitFields.Card.cardId: card.cardId,
            CloudKitFields.Card.sessionId: card.sessionId,
            CloudKitFields.Card.category: card.category,
            CloudKitFields.Card.priority: card.priority,
            CloudKitFields.Card.title: card.title,
            CloudKitFields.Card.summary: card.summary,
            CloudKitFields.Card.terminalLinesJSON: encodeJSON(card.terminalLines),
            CloudKitFields.Card.optionsJSON: encodeJSON(card.options),
            CloudKitFields.Card.state: card.state,
            CloudKitFields.Card.createdAt: timestampMs(card.createdAt),
            CloudKitFields.Card.updatedAt: timestampMs(card.updatedAt),
            CloudKitFields.Card.sourceFingerprint: card.sourceFingerprint
        ]
        if let actionPrompt = card.actionPrompt {
            fields[CloudKitFields.Card.actionPrompt] = actionPrompt
        }
        return fields
    }

    private func sessionFields(_ session: SessionSnapshot) -> [String: Any] {
        var fields: [String: Any] = [
            CloudKitFields.Session.sessionId: session.sessionId,
            CloudKitFields.Session.provider: session.provider,
            CloudKitFields.Session.projectName: session.projectName,
            CloudKitFields.Session.runState: session.runState,
            CloudKitFields.Session.lastActivityAt: timestampMs(session.lastActivityAt),
            CloudKitFields.Session.macDeviceId: session.macDeviceId,
            CloudKitFields.Session.isDeliverable: session.isDeliverable ? 1 : 0
        ]
        if let branchLabel = session.branchLabel {
            fields[CloudKitFields.Session.branchLabel] = branchLabel
        }
        return fields
    }

    private func deviceFields(_ device: DeviceSnapshot) -> [String: Any] {
        return [
            CloudKitFields.Device.deviceId: device.deviceId,
            CloudKitFields.Device.platform: device.platform,
            CloudKitFields.Device.displayName: device.displayName,
            CloudKitFields.Device.lastSeenAt: timestampMs(device.lastSeenAt),
            CloudKitFields.Device.appVersion: device.appVersion
        ]
    }

    private func decodeInstruction(_ record: CloudKitWebClient.RecordResponse) -> InstructionRequest? {
        guard let fields = record.fields else { return nil }
        guard
            let instructionId = stringValue(fields, CloudKitFields.Instruction.instructionId),
            let targetSessionId = stringValue(fields, CloudKitFields.Instruction.targetSessionId),
            let text = stringValue(fields, CloudKitFields.Instruction.text),
            let createdAt = dateValue(fields, CloudKitFields.Instruction.createdAt),
            let createdByDeviceId = stringValue(fields, CloudKitFields.Instruction.createdByDeviceId),
            let statusRaw = stringValue(fields, CloudKitFields.Instruction.status),
            let status = InstructionStatus(rawValue: statusRaw)
        else { return nil }

        return InstructionRequest(
            instructionId: instructionId,
            targetSessionId: targetSessionId,
            text: text,
            createdAt: createdAt,
            createdByDeviceId: createdByDeviceId,
            status: status,
            claimedByMacDeviceId: stringValue(fields, CloudKitFields.Instruction.claimedByMacDeviceId),
            claimedAt: dateValue(fields, CloudKitFields.Instruction.claimedAt),
            injectedAt: dateValue(fields, CloudKitFields.Instruction.injectedAt),
            failureReason: stringValue(fields, CloudKitFields.Instruction.failureReason)
        )
    }

    private func stringValue(_ fields: [String: CloudKitWebClient.RecordResponse.FieldEnvelope], _ key: String) -> String? {
        return fields[key]?.value?.raw as? String
    }

    private func dateValue(_ fields: [String: CloudKitWebClient.RecordResponse.FieldEnvelope], _ key: String) -> Date? {
        guard let raw = fields[key]?.value?.raw else { return nil }
        if let ms = raw as? Int64 { return Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0) }
        if let ms = raw as? Double { return Date(timeIntervalSince1970: ms / 1000.0) }
        return nil
    }

    private func timestampMs(_ date: Date) -> Int64 {
        return Int64(date.timeIntervalSince1970 * 1000.0)
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
