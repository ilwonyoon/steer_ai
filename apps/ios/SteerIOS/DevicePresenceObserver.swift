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

    private weak var inbox: SyncInbox?
    private var pollTimer: Timer?

    init(inbox: SyncInbox) {
        self.inbox = inbox
    }

    func start() {
        Task { await refresh() }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
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
            state = .demo
            return
        }
        guard inbox.isSignedIn else {
            state = .neverConnected
            return
        }
        let fetched = await fetchDevices()
        devices = fetched
        state = derive(from: fetched)
    }

    private func derive(from devices: [DeviceSnapshot]) -> State {
        let macs = devices.filter { $0.platform == "mac" && $0.syncEnabled }
        guard let mac = macs.max(by: { $0.lastSeenAt < $1.lastSeenAt }) else {
            return .neverConnected
        }
        let label = mac.deviceClass ?? mac.displayName ?? "Mac"
        let ageMs = Double(Date().timeIntervalSince1970 * 1000) - Double(mac.lastSeenAt)
        if ageMs < 90_000 { return .connected(label: label) }
        if ageMs < 600_000 { return .stale(label: label) }
        return .offline(label: label)
    }

    private func fetchDevices() async -> [DeviceSnapshot] {
        guard let inbox else { return [] }
        do {
            let resp: DeviceListResponse = try await inbox.getJSONRaw("/v1/sync/devices")
            return resp.devices
        } catch {
            return []
        }
    }
}
