// Wire format for the Steer relay backend (Cloudflare Workers).
//
// These models are the JSON shape that travels between Mac, iOS, and
// the worker. Field names use camelCase to match the worker's TS
// structs (see `packages/relay/src/types.ts`); both sides serialize
// with default Codable / JSON.stringify so a Mac PUT and an iPhone
// GET round-trip identically.
//
// This file replaces the CloudKit-shaped models for V1 sync. The
// older CloudKitRecords.swift still ships in the package for
// historical context and to keep ios-spike branch builds working,
// but the apps' SyncClient.swift uses the types here instead.

import Foundation

public struct CardPayload: Codable, Hashable, Sendable {
    public let cardId: String
    public let sessionId: String
    public let category: String
    public let priority: String
    public let title: String
    public let summary: String
    public let actionPrompt: String?
    /// Free-form payload bag. We keep the wire side opaque so the
    /// Mac can ferry terminalLines / chips / source fingerprints
    /// without forcing a relay schema migration every time the UI
    /// adds a field.
    public let payload: [String: AnyCodable]?
    public let state: String   // "active" | "done"
    public let createdAt: Int64  // ms since epoch
    public let updatedAt: Int64

    public init(
        cardId: String,
        sessionId: String,
        category: String,
        priority: String,
        title: String,
        summary: String,
        actionPrompt: String? = nil,
        payload: [String: AnyCodable]? = nil,
        state: String,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.cardId = cardId
        self.sessionId = sessionId
        self.category = category
        self.priority = priority
        self.title = title
        self.summary = summary
        self.actionPrompt = actionPrompt
        self.payload = payload
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct InstructionRequestV2: Codable, Hashable, Sendable {
    public let instructionId: String
    public let targetSessionId: String
    public let text: String

    public init(instructionId: String, targetSessionId: String, text: String) {
        self.instructionId = instructionId
        self.targetSessionId = targetSessionId
        self.text = text
    }
}

public struct InstructionRecord: Codable, Hashable, Sendable {
    public let instructionId: String
    public let targetSessionId: String
    public let text: String
    public let status: String  // "queued" | "injected" | "failed"
    public let createdAt: Int64
    public let injectedAt: Int64?
    public let failureReason: String?

    public init(
        instructionId: String,
        targetSessionId: String,
        text: String,
        status: String,
        createdAt: Int64,
        injectedAt: Int64? = nil,
        failureReason: String? = nil
    ) {
        self.instructionId = instructionId
        self.targetSessionId = targetSessionId
        self.text = text
        self.status = status
        self.createdAt = createdAt
        self.injectedAt = injectedAt
        self.failureReason = failureReason
    }
}

/// Mac/iOS device presence published to the relay so the other
/// device can show a connection chip + queue-vs-deliver decisions.
public struct DeviceSnapshot: Codable, Sendable {
    public let deviceId: String
    public let platform: String          // "mac" | "ios"
    public let displayName: String?
    public let deviceClass: String?      // "MacBook Air", "Mac mini", "iPhone"
    public let appVersion: String?
    public let syncEnabled: Bool
    public let lastSeenAt: Int64         // ms epoch
    /// Hex-encoded APNS device token for iOS. Only set on iOS, only
    /// after the user grants notification permission and Apple hands
    /// us a token. The relay uses this to fan out push notifications
    /// when a card lands on this user.
    public let apnsToken: String?

    public init(
        deviceId: String,
        platform: String,
        displayName: String?,
        deviceClass: String?,
        appVersion: String?,
        syncEnabled: Bool,
        lastSeenAt: Int64,
        apnsToken: String? = nil
    ) {
        self.deviceId = deviceId
        self.platform = platform
        self.displayName = displayName
        self.deviceClass = deviceClass
        self.appVersion = appVersion
        self.syncEnabled = syncEnabled
        self.lastSeenAt = lastSeenAt
        self.apnsToken = apnsToken
    }
}

public struct DeviceListResponse: Codable, Sendable {
    public let devices: [DeviceSnapshot]
    public init(devices: [DeviceSnapshot]) { self.devices = devices }
}

/// Live session metadata published by Mac so iPhone can render a
/// "1 running" badge alongside the connection chip. Mirrors the
/// relay's `SessionSnapshot` TS interface (see packages/relay/src/types.ts).
public struct SessionSnapshot: Codable, Sendable {
    public let sessionId: String
    public let provider: String
    public let projectName: String?
    public let branchLabel: String?
    public let runState: String        // "running" | "waiting" | "blocked"
    public let lastActivityAt: Int64   // ms epoch

    public init(
        sessionId: String,
        provider: String,
        projectName: String?,
        branchLabel: String?,
        runState: String,
        lastActivityAt: Int64
    ) {
        self.sessionId = sessionId
        self.provider = provider
        self.projectName = projectName
        self.branchLabel = branchLabel
        self.runState = runState
        self.lastActivityAt = lastActivityAt
    }
}

/// GET /v1/sync/sessions — the live running/waiting/blocked
/// sessions the user's Mac last reported. iPhone reads this to
/// surface a "1 running" count inside the Mac connection chip.
public struct SessionListResponse: Codable, Sendable {
    public let sessions: [SessionSnapshot]
    public init(sessions: [SessionSnapshot]) { self.sessions = sessions }
}

public struct AuthAppleRequest: Codable, Sendable {
    public let identityToken: String
    public let displayName: String?
    /// One-time authorization code from Apple. Only present on the
    /// initial sign-in event for a given session; the relay stores
    /// it server-side and uses it to call Apple's revoke endpoint
    /// during account deletion. Optional for backwards compatibility
    /// with older clients.
    public let authorizationCode: String?
    /// Per-install device id. Sent so the relay can bind this value
    /// into the JWT's `did` claim — every subsequent request must
    /// carry the matching `X-Steer-Device-Id` header. Lets us reject
    /// a stolen token being replayed from another device.
    public let deviceId: String?

    public init(
        identityToken: String,
        displayName: String?,
        authorizationCode: String? = nil,
        deviceId: String? = nil
    ) {
        self.identityToken = identityToken
        self.displayName = displayName
        self.authorizationCode = authorizationCode
        self.deviceId = deviceId
    }
}

public struct AuthAppleResponse: Codable, Sendable {
    public let sessionToken: String
    public let user: SyncUser

    public init(sessionToken: String, user: SyncUser) {
        self.sessionToken = sessionToken
        self.user = user
    }
}

public struct SyncUser: Codable, Hashable, Sendable {
    public let userId: String
    public let appleEmail: String?
    public let displayName: String?

    public init(userId: String, appleEmail: String?, displayName: String?) {
        self.userId = userId
        self.appleEmail = appleEmail
        self.displayName = displayName
    }
}

public struct CardListResponse: Codable, Sendable {
    public let cards: [CardPayload]
    public init(cards: [CardPayload]) { self.cards = cards }
}

public struct InstructionListResponse: Codable, Sendable {
    public let instructions: [InstructionRecord]
    public init(instructions: [InstructionRecord]) { self.instructions = instructions }
}

public enum WSMessage: Codable, Sendable {
    case cardUpsert(CardPayload)
    case cardResolved(String)
    case instructionQueued(InstructionRecord)
    case instructionStatus(instructionId: String, status: String, failureReason: String?)
    case ping
    case pong

    enum CodingKeys: String, CodingKey {
        case type, card, cardId, instruction, instructionId, status, failureReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "card.upsert":
            self = .cardUpsert(try c.decode(CardPayload.self, forKey: .card))
        case "card.resolved":
            self = .cardResolved(try c.decode(String.self, forKey: .cardId))
        case "instruction.queued":
            self = .instructionQueued(try c.decode(InstructionRecord.self, forKey: .instruction))
        case "instruction.status":
            self = .instructionStatus(
                instructionId: try c.decode(String.self, forKey: .instructionId),
                status: try c.decode(String.self, forKey: .status),
                failureReason: try c.decodeIfPresent(String.self, forKey: .failureReason)
            )
        case "ping": self = .ping
        case "pong": self = .pong
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown WS type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cardUpsert(let card):
            try c.encode("card.upsert", forKey: .type)
            try c.encode(card, forKey: .card)
        case .cardResolved(let id):
            try c.encode("card.resolved", forKey: .type)
            try c.encode(id, forKey: .cardId)
        case .instructionQueued(let r):
            try c.encode("instruction.queued", forKey: .type)
            try c.encode(r, forKey: .instruction)
        case .instructionStatus(let id, let status, let reason):
            try c.encode("instruction.status", forKey: .type)
            try c.encode(id, forKey: .instructionId)
            try c.encode(status, forKey: .status)
            try c.encodeIfPresent(reason, forKey: .failureReason)
        case .ping: try c.encode("ping", forKey: .type)
        case .pong: try c.encode("pong", forKey: .type)
        }
    }
}

/// Type-erased value for `payload` JSON object. Supports nested
/// objects so we can ship `{ terminalLines: [...] }` without losing
/// the array shape.
public struct AnyCodable: Codable, Hashable, Sendable {
    public let value: AnyCodableValue

    public init(_ value: AnyCodableValue) { self.value = value }
    public init(_ string: String) { self.value = .string(string) }
    public init(_ array: [String]) { self.value = .stringArray(array) }
    public init(_ int: Int64) { self.value = .integer(int) }
    public init(_ bool: Bool) { self.value = .bool(bool) }
    public init(_ double: Double) { self.value = .double(double) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self.value = .string(s); return }
        if let i = try? c.decode(Int64.self) { self.value = .integer(i); return }
        if let d = try? c.decode(Double.self) { self.value = .double(d); return }
        if let b = try? c.decode(Bool.self) { self.value = .bool(b); return }
        if let arr = try? c.decode([String].self) { self.value = .stringArray(arr); return }
        if let dict = try? c.decode([String: AnyCodable].self) { self.value = .dict(dict); return }
        if let arr = try? c.decode([AnyCodable].self) { self.value = .array(arr); return }
        self.value = .null
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case .string(let s): try c.encode(s)
        case .integer(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .stringArray(let a): try c.encode(a)
        case .array(let a): try c.encode(a)
        case .dict(let d): try c.encode(d)
        case .null: try c.encodeNil()
        }
    }
}

public enum AnyCodableValue: Hashable, Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case stringArray([String])
    case array([AnyCodable])
    case dict([String: AnyCodable])
    case null
}
