// Shared models that travel through the CloudKit private database
// between Mac Steer.app and Steer for iOS.
//
// These types deliberately don't depend on CloudKit — that decoding /
// encoding lives in the Mac and iOS apps so SteerCore stays pure data.

import Foundation

public struct DeviceSnapshot: Codable, Hashable, Sendable {
    public let deviceId: String
    public let platform: String           // "mac" | "iphone"
    public let displayName: String
    public let lastSeenAt: Date
    public let appVersion: String

    public init(
        deviceId: String,
        platform: String,
        displayName: String,
        lastSeenAt: Date,
        appVersion: String
    ) {
        self.deviceId = deviceId
        self.platform = platform
        self.displayName = displayName
        self.lastSeenAt = lastSeenAt
        self.appVersion = appVersion
    }
}

public struct SessionSnapshot: Codable, Hashable, Sendable {
    public let sessionId: String
    public let provider: String
    public let projectName: String
    public let branchLabel: String?
    public let runState: String
    public let lastActivityAt: Date
    public let macDeviceId: String
    public let isDeliverable: Bool

    public init(
        sessionId: String,
        provider: String,
        projectName: String,
        branchLabel: String?,
        runState: String,
        lastActivityAt: Date,
        macDeviceId: String,
        isDeliverable: Bool
    ) {
        self.sessionId = sessionId
        self.provider = provider
        self.projectName = projectName
        self.branchLabel = branchLabel
        self.runState = runState
        self.lastActivityAt = lastActivityAt
        self.macDeviceId = macDeviceId
        self.isDeliverable = isDeliverable
    }
}

public struct CardSnapshot: Codable, Hashable, Sendable {
    public let cardId: String
    public let sessionId: String
    public let category: String
    public let priority: String
    public let title: String
    public let summary: String
    public let actionPrompt: String?
    public let terminalLines: [String]
    public let options: [String]
    public let state: String
    public let createdAt: Date
    public let updatedAt: Date
    public let sourceFingerprint: String

    public init(
        cardId: String,
        sessionId: String,
        category: String,
        priority: String,
        title: String,
        summary: String,
        actionPrompt: String?,
        terminalLines: [String],
        options: [String],
        state: String,
        createdAt: Date,
        updatedAt: Date,
        sourceFingerprint: String
    ) {
        self.cardId = cardId
        self.sessionId = sessionId
        self.category = category
        self.priority = priority
        self.title = title
        self.summary = summary
        self.actionPrompt = actionPrompt
        self.terminalLines = terminalLines
        self.options = options
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceFingerprint = sourceFingerprint
    }
}

public enum InstructionStatus: String, Codable, Sendable {
    case queued
    case claimed
    case injected
    case failed
    case expired
}

public struct InstructionRequest: Codable, Hashable, Sendable {
    public let instructionId: String
    public let targetSessionId: String
    public let text: String
    public let createdAt: Date
    public let createdByDeviceId: String
    public var status: InstructionStatus
    public var claimedByMacDeviceId: String?
    public var claimedAt: Date?
    public var injectedAt: Date?
    public var failureReason: String?

    public init(
        instructionId: String,
        targetSessionId: String,
        text: String,
        createdAt: Date,
        createdByDeviceId: String,
        status: InstructionStatus = .queued,
        claimedByMacDeviceId: String? = nil,
        claimedAt: Date? = nil,
        injectedAt: Date? = nil,
        failureReason: String? = nil
    ) {
        self.instructionId = instructionId
        self.targetSessionId = targetSessionId
        self.text = text
        self.createdAt = createdAt
        self.createdByDeviceId = createdByDeviceId
        self.status = status
        self.claimedByMacDeviceId = claimedByMacDeviceId
        self.claimedAt = claimedAt
        self.injectedAt = injectedAt
        self.failureReason = failureReason
    }
}

/// Field names used as CKRecord keys. Centralised here so Mac and iOS
/// can never drift on a typo.
public enum CloudKitFields {
    public enum Device {
        public static let recordType = "Device"
        public static let deviceId = "deviceId"
        public static let platform = "platform"
        public static let displayName = "displayName"
        public static let lastSeenAt = "lastSeenAt"
        public static let appVersion = "appVersion"
    }

    public enum Session {
        public static let recordType = "SessionSnapshot"
        public static let sessionId = "sessionId"
        public static let provider = "provider"
        public static let projectName = "projectName"
        public static let branchLabel = "branchLabel"
        public static let runState = "runState"
        public static let lastActivityAt = "lastActivityAt"
        public static let macDeviceId = "macDeviceId"
        public static let isDeliverable = "isDeliverable"
    }

    public enum Card {
        public static let recordType = "CardSnapshot"
        public static let cardId = "cardId"
        public static let sessionId = "sessionId"
        public static let category = "category"
        public static let priority = "priority"
        public static let title = "title"
        public static let summary = "summary"
        public static let actionPrompt = "actionPrompt"
        public static let terminalLinesJSON = "terminalLinesJSON"
        public static let optionsJSON = "optionsJSON"
        public static let state = "state"
        public static let createdAt = "createdAt"
        public static let updatedAt = "updatedAt"
        public static let sourceFingerprint = "sourceFingerprint"
    }

    public enum Instruction {
        public static let recordType = "InstructionRequest"
        public static let instructionId = "instructionId"
        public static let targetSessionId = "targetSessionId"
        public static let text = "text"
        public static let createdAt = "createdAt"
        public static let createdByDeviceId = "createdByDeviceId"
        public static let status = "status"
        public static let claimedByMacDeviceId = "claimedByMacDeviceId"
        public static let claimedAt = "claimedAt"
        public static let injectedAt = "injectedAt"
        public static let failureReason = "failureReason"
    }

    /// CloudKit container shared between Mac and iOS apps. Single source
    /// of truth so the two platforms can't drift on identifier strings.
    public static let containerIdentifier = "iCloud.ai.steer.mac"
    public static let zoneName = "SteerPrivateZone"
}
