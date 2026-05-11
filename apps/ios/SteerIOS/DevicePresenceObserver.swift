import Foundation
import SteerCore
import Combine

/// Polls /v1/sync/devices and exposes the user's most-recent Mac
/// presence + a derived MacConnectionState. Drives the top-right
/// connection chip + Mac Sync Status sheet on iOS.
///
/// State thresholds match IOS_PRE_CONNECTION_ONBOARDING.md:
///   connected      — last heartbeat within 90s
///   stale          — 90s..10m
///   offline        — beyond 10m
///   neverConnected — no Mac device row
@MainActor
final class DevicePresenceObserver: ObservableObject {
    enum State: Equatable {
        case demo
        case neverConnected
        case connected(label: String)
        case stale(label: String)
        case offline(label: String)
        case error(message: String)

        var label: String {
            switch self {
            case .demo: return "Sample"
            case .neverConnected: return "No Mac"
            case .connected(let l), .stale(let l), .offline(let l): return l
            case .error: return "Sync issue"
            }
        }
    }

    @Published private(set) var state: State = .neverConnected
    @Published private(set) var devices: [DeviceSnapshot] = []
    /// Live sessions the Mac last reported (running / waiting /
    /// blocked, last 5 minutes). The chip composes its label from
    /// `runningCount` so the user sees "1 running" or "2 running ·
    /// 1 waiting" in the connection capsule.
    @Published private(set) var liveSessions: [SessionSnapshot] = []

    var runningCount: Int {
        liveSessions.filter { $0.runState == "running" }.count
    }

    private weak var inbox: SyncInbox?
    private var pollTimer: Timer?

    init(inbox: SyncInbox) {
        self.inbox = inbox
    }

    func start() {
        Task { await refresh() }
        pollTimer?.invalidate()
        // 15s poll. Was 5s, which made the chip flip Connected ↔
        // Stale within ~10s of the Mac going offline but burned 12
        // req/min × 2 endpoints per user — the dominant chunk of
        // Cloudflare quota in practice. 15s × 1 consolidated
        // endpoint = 4 req/min, an ~83% drop. With the Mac heartbeat
        // bumped to 15s alongside (see SteerAppDelegate), the chip
        // still flips Stale within ~30s of a real Mac quit — slower
        // than before, but not noticeably so. Phase A1 of
        // docs/SYNC_STABILITY_AND_COST_PLAN.md.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Recompute state from local data. Called by the timer and on
    /// demand from the chip's pull-to-refresh.
    func refresh() async {
        guard let inbox else { return }
        if inbox.isDemoMode {
            if state != .demo { state = .demo }
            return
        }
        guard inbox.isSignedIn else {
            if state != .neverConnected { state = .neverConnected }
            return
        }
        // Single combined request — was two (devices + sessions).
        // Phase A1.
        let (fetchedDevices, fetchedSessions) = await fetchPresence()
        if devices != fetchedDevices {
            devices = fetchedDevices
        }
        let nextState = derive(from: fetchedDevices)
        if state != nextState {
            state = nextState
        }
        if liveSessions != fetchedSessions {
            liveSessions = fetchedSessions
        }
    }

    private func fetchPresence() async -> ([DeviceSnapshot], [SessionSnapshot]) {
        guard let inbox else { return ([], []) }
        do {
            let resp: PresenceResponse = try await inbox.getJSONRaw("/v1/sync/presence")
            return (resp.devices, resp.sessions)
        } catch {
            return ([], [])
        }
    }

    private func derive(from devices: [DeviceSnapshot]) -> State {
        let macs = devices.filter { $0.platform == "mac" && $0.syncEnabled }
        guard let mac = macs.max(by: { $0.lastSeenAt < $1.lastSeenAt }) else {
            return .neverConnected
        }
        let label = mac.deviceClass ?? mac.displayName ?? "Mac"
        let ageMs = Double(Date().timeIntervalSince1970 * 1000) - Double(mac.lastSeenAt)
        // Mac heartbeats every 15s, so a 30s window covers one
        // missed beat (jitter / wake-from-sleep) without flapping.
        if ageMs < 30_000 { return .connected(label: label) }
        // 5 minutes of silence ≈ Mac is sleeping or app killed; we
        // call this "stale" so replies still queue rather than fail.
        if ageMs < 300_000 { return .stale(label: label) }
        return .offline(label: label)
    }

}
