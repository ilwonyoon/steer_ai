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
    /// Maximum time `.connecting` is shown after sign-in before
    /// we fall through to `.neverConnected`. 10 s = ~3 of the
    /// 3 s polls during the connecting window.
    private let connectingTimeout: TimeInterval = 10
    /// Minimum time `.connecting` stays visible after sign-in,
    /// even if a real Mac response arrives in 20 ms. Without
    /// this floor, fast networks resolve the chip so quickly
    /// the user never sees the "Connecting" state at all —
    /// reads as if we never tried.
    private let connectingMinimumVisibleSeconds: TimeInterval = 1.5
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
            // Signed out: chip isn't on screen (SignInPrompt
            // covers it), so the state value doesn't matter for
            // UI. We deliberately leave `state` as `.connecting`
            // (the init default) so the very first frame after
            // sign-in still reads as "Connecting" — no
            // `.neverConnected` flash in between.
            connectingStartedAt = nil
            return
        }

        // Sign-in transition: arm the connecting window the
        // first time we see isSignedIn = true after being
        // signed-out. `connectingStartedAt == nil` is the marker.
        if connectingStartedAt == nil {
            connectingStartedAt = Date()
            if state != .connecting { state = .connecting }
            // Schedule a follow-up refresh once the minimum
            // visible duration elapses, so a fast Mac discovery
            // doesn't have to wait for the next 3 s poll tick
            // to transition out of .connecting.
            let deadline = connectingMinimumVisibleSeconds
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                await self?.refresh()
            }
        }

        let fetchedDevices = await fetchPresenceDevices()
        if devices != fetchedDevices {
            devices = fetchedDevices
        }
        let derived = derive(from: fetchedDevices)
        let elapsed = Date().timeIntervalSince(connectingStartedAt ?? Date())

        // Two reasons to hold .connecting:
        //   1. No Mac found yet AND timeout hasn't elapsed.
        //   2. A real Mac WAS found but the connecting chip has
        //      been on screen for less than the minimum visible
        //      duration. Without this, very fast networks
        //      resolve the chip in 20 ms and the user never
        //      sees "Connecting" at all.
        let noMacYet = (derived == .neverConnected)
        let underTimeout = elapsed < connectingTimeout
        let underMinVisible = elapsed < connectingMinimumVisibleSeconds
        if (noMacYet && underTimeout) || underMinVisible {
            if state != .connecting { state = .connecting }
            return
        }

        // Resolved. Drop the polling cadence back to steady-state
        // to honor the request-budget commitment.
        connectingStartedAt = nil
        if state != derived { state = derived }
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
