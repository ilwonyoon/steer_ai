import Foundation
import SteerCore
import Combine
import UIKit

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
        /// Initial state until the first presence response lands.
        /// Reads as "Connecting" so a user who just installed the
        /// app doesn't see "No Mac" before we've even attempted
        /// a poll — that was misleading.
        case connecting
        case neverConnected
        case connected(label: String)
        case stale(label: String)
        case offline(label: String)
        case error(message: String)

        var label: String {
            switch self {
            case .demo: return "Sample"
            case .connecting: return "Connecting"
            case .neverConnected: return "No Mac"
            case .connected(let l), .stale(let l), .offline(let l): return l
            case .error: return "Sync issue"
            }
        }
    }

    @Published private(set) var state: State = .connecting
    @Published private(set) var devices: [DeviceSnapshot] = []

    private weak var inbox: SyncInbox?
    private var pollTimer: Timer?
    /// Wall-clock when we started trying to reach the Mac after
    /// sign-in. Used to keep state = .connecting until either a
    /// Mac device row shows up or the timeout elapses.
    private var connectingStartedAt: Date?
    /// How long to hold `.connecting` after sign-in before
    /// surrendering to `.neverConnected`. 10s gives the relay
    /// + iPhone poll cadence three full cycles (3 × 3s) to land
    /// a Mac heartbeat before we tell the user "no Mac yet."
    private let connectingTimeout: TimeInterval = 10
    /// Tracks whether the app is currently visible. We only run the
    /// poll timer when the user can actually see the chip — the WS
    /// stays open separately for instruction delivery and APNS still
    /// wakes the phone for new cards, so backgrounded polling is
    /// pure waste. Phase A2 of docs/SYNC_STABILITY_AND_COST_PLAN.md.
    private var isInForeground: Bool = true
    private var lifecycleObservers: [NSObjectProtocol] = []

    init(inbox: SyncInbox) {
        self.inbox = inbox
    }

    // Lifecycle observers stay registered for the lifetime of the
    // SyncInbox singleton's child observer. Removing them in deinit
    // would require crossing actor isolation on a non-Sendable
    // array of NSObjectProtocols; Swift 6 won't allow that. The
    // process death cleans the observers up alongside everything
    // else, so explicit removal is unnecessary.

    func start() {
        installLifecycleObserversIfNeeded()
        isInForeground = (UIApplication.shared.applicationState != .background)
        if isInForeground {
            beginPolling()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Tear up + restart the timer + kick a single immediate
    /// refresh. Steady-state cadence is 15 s; while the chip is
    /// `.connecting` we poll every 3 s so a paired Mac surfaces
    /// within the connecting window. `refresh()` flips back to
    /// the slow cadence as soon as the window resolves.
    private func beginPolling() {
        Task { await refresh() }
        installTimer(interval: 3)
    }

    private func installTimer(interval: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func installLifecycleObserversIfNeeded() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let bg = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isInForeground = false
            self.pollTimer?.invalidate()
            self.pollTimer = nil
        }
        let fg = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isInForeground = true
            // Fire one refresh right away so the chip catches up
            // immediately; the timer starts the regular 15s cadence
            // from inside beginPolling().
            self.beginPolling()
        }
        lifecycleObservers = [bg, fg]
    }

    /// Recompute state from local data. Called by the timer and on
    /// demand from the chip's pull-to-refresh.
    func refresh() async {
        guard let inbox else { return }
        if inbox.isDemoMode {
            if state != .demo { state = .demo }
            connectingStartedAt = nil
            return
        }
        guard inbox.isSignedIn else {
            // Signed out — neither connecting nor connected;
            // no Mac to look for. Sign-in transitions kick off
            // a fresh connecting window.
            if state != .neverConnected { state = .neverConnected }
            connectingStartedAt = nil
            return
        }

        // First refresh after sign-in (or back from background)
        // arms the connecting window so the chip shows
        // "Connecting" while the first poll round-trips.
        if connectingStartedAt == nil, !isTerminalState(state) {
            connectingStartedAt = Date()
            if state != .connecting { state = .connecting }
        }

        let fetchedDevices = await fetchPresenceDevices()
        if devices != fetchedDevices {
            devices = fetchedDevices
        }

        let nextState = derive(from: fetchedDevices)

        // While the connecting window is open and the derived
        // state would be `.neverConnected` (no Mac heartbeat
        // yet), keep showing `.connecting` so the user reads
        // the chip as "trying" instead of "no Mac." Real Mac
        // results (connected / stale / offline) end the window
        // immediately; the timeout ends it falling through to
        // `.neverConnected`.
        if case .neverConnected = nextState,
           let started = connectingStartedAt,
           Date().timeIntervalSince(started) < connectingTimeout {
            if state != .connecting { state = .connecting }
            return
        }

        connectingStartedAt = nil
        if state != nextState { state = nextState }
        // Connecting resolved (either to a real Mac or to
        // .neverConnected after timeout). Drop the timer back
        // to the steady-state 15 s cadence to honor the
        // request-budget commitment from SYNC_STABILITY_AND_COST_PLAN.
        if pollTimer != nil {
            installTimer(interval: 15)
        }
    }

    private func isTerminalState(_ s: State) -> Bool {
        switch s {
        case .connected, .stale, .offline, .error, .demo: return true
        case .connecting, .neverConnected: return false
        }
    }

    private func fetchPresenceDevices() async -> [DeviceSnapshot] {
        guard let inbox else { return [] }
        do {
            let resp: PresenceResponse = try await inbox.getJSONRaw("/v1/sync/presence")
            return resp.devices
        } catch {
            return []
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
