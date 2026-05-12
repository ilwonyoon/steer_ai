import Foundation

/// Pure transition logic for the iPhone-side "I replied; waiting for
/// the terminal" state. The Mac doesn't need this — Mac has direct
/// access to `instructedSessions` from its in-process state. iPhone
/// has to reconstruct the same set from what the relay tells it
/// (instruction POST acks + card WebSocket push), which is what this
/// helper formalises.
///
/// Why a separate helper instead of inlining in `SyncInbox`:
///
/// 1. `SyncInbox` is a `@MainActor ObservableObject` glued to
///    networking + Combine; isolating the rules makes them testable
///    without `URLProtocol` mocks.
///
/// 2. The previous design treated `pendingReplies` as a network
///    request log — rows came in on `sendReply()` and left on POST
///    response. That left a gap: the iPhone forgot about a reply
///    the moment the relay confirmed enqueue, even though the
///    underlying terminal hadn't yet produced a response. The chip
///    derived from that gap was always wrong.
///
/// New contract — three lifecycle stages map to one chip:
///
///   .sending  → POST in flight, network not yet acked
///   .injected → relay acked the enqueue. Mac will pick it up
///               and feed the wrapper. We don't yet know if the
///               terminal has produced a response.
///   .failed   → terminal error from the POST.
///
/// "Chip eligible" = sending ∪ injected. The chip clears when a new
/// card for that session arrives over WebSocket — that's the only
/// signal we trust for "terminal produced its response," because
/// `instruction.injected` from the Mac only proves the bytes hit
/// stdin, not that the model has answered.

public enum PendingReplyStatus: Equatable {
    case sending
    case injected
    case failed(String)
}

public struct PendingReplySnapshot: Equatable {
    public let id: String
    public let sessionId: String
    public var status: PendingReplyStatus

    public init(id: String, sessionId: String, status: PendingReplyStatus) {
        self.id = id
        self.sessionId = sessionId
        self.status = status
    }
}

public enum PendingReplyTransitions {
    /// Transition: relay accepted the instruction POST. Move the
    /// row from .sending to .injected. Anything not currently
    /// .sending is ignored (already failed or already injected — we
    /// don't replay).
    public static func onRelayAccepted(
        previous: [PendingReplySnapshot],
        id: String
    ) -> [PendingReplySnapshot] {
        var next = previous
        if let idx = next.firstIndex(where: { $0.id == id }),
           case .sending = next[idx].status {
            next[idx].status = .injected
        }
        return next
    }

    /// Transition: a fresh card for `sessionId` arrived over the
    /// WebSocket push. The terminal has produced its response —
    /// drop any .injected row for that session (it's served its
    /// purpose). .sending rows are left alone (the POST is still
    /// in flight; we'll either resolve on .onRelayAccepted or
    /// .onRelayFailed). .failed rows are left alone too (the user
    /// still needs to retry/cancel them).
    public static func onCardArrivedForSession(
        previous: [PendingReplySnapshot],
        sessionId: String
    ) -> [PendingReplySnapshot] {
        previous.filter { row in
            // Drop only .injected rows for the matching session.
            if row.sessionId == sessionId, row.status == .injected {
                return false
            }
            return true
        }
    }

    /// Transition: POST returned an error. .sending → .failed with
    /// reason. Anything else stays put.
    public static func onRelayFailed(
        previous: [PendingReplySnapshot],
        id: String,
        reason: String
    ) -> [PendingReplySnapshot] {
        var next = previous
        if let idx = next.firstIndex(where: { $0.id == id }),
           case .sending = next[idx].status {
            next[idx].status = .failed(reason)
        }
        return next
    }

    /// Derived view: session ids currently in the "user replied,
    /// terminal still working" state. This is what drives the
    /// running-count side of the chip label.
    public static func activeSessionIds(
        in pending: [PendingReplySnapshot]
    ) -> Set<String> {
        var set = Set<String>()
        for row in pending {
            switch row.status {
            case .sending, .injected:
                set.insert(row.sessionId)
            case .failed:
                continue
            }
        }
        return set
    }
}
