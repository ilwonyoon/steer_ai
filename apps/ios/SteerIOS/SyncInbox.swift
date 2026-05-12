import Foundation
import AuthenticationServices
import UIKit
import UserNotifications
import SteerCore

/// iOS counterpart of the Mac SyncClient. Same wire shape (relay
/// REST + WebSocket against /v1), same Sign in with Apple flow, same
/// keychain-backed session JWT — but exposes the subset of operations
/// the iPhone reader needs: load active cards, send a reply, mark a
/// card resolved.
///
/// The CloudKit-based predecessor (`CloudKitInbox.swift`) was deleted
/// when the project pivoted to a relay backend on 2026-05-09; see
/// `docs/RELAY_BACKEND_PLAN.md` for the why.
@MainActor
public final class SyncInbox: ObservableObject {
    public static let shared = SyncInbox()

    @Published public private(set) var status: Status = .signedOut
    @Published public private(set) var cards: [CardPayload] = []
    @Published public private(set) var lastError: String?

    public enum Status: Equatable {
        case signedOut
        case signedIn(SyncUser)
        case loading
        case offline
    }

    /// Cold-start phase. The card area uses this to render
    /// SyncingPlaceholder during the first bootstrap so cards don't
    /// land one-by-one and reshuffle. Section B2 of
    /// docs/SYNC_ARCHITECTURE_V2.md.
    public enum LoadPhase: Equatable {
        case idle           // not signed in, or bootstrap hasn't run
        case bootstrapping  // first /v1/sync/cards GET is in flight
        case ready          // first card list landed; UI can render
    }
    @Published public private(set) var loadPhase: LoadPhase = .idle

    private let baseURL: URL
    private let tokenStore: SessionTokenStore
    private let urlSession: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    private init() {
        let stored = UserDefaults.standard.string(forKey: "ai.steer.relay.baseURL")
            ?? "https://steer-relay.ilwonyoon-turtleneck.workers.dev"
        self.baseURL = URL(string: stored)!
        self.tokenStore = SessionTokenStore()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: cfg)

        if Self.fixtureModeEnabled {
            // Simulator UX iteration path: skip Apple sign-in (which the
            // sim can't complete anyway) and load a hard-coded card set
            // so the inbox renders immediately. Set in scheme env vars
            // (STEER_FIXTURES=1) or UserDefaults `steer.ios.fixtures`.
            self.status = .signedIn(SyncUser(
                userId: "fixture-user",
                appleEmail: "fixtures@steer.local",
                displayName: "Fixture User"
            ))
            self.cards = SyncInboxFixtures.cards()
            return
        }

        if tokenStore.read() != nil {
            // Start cold-start sync immediately. Setting loadPhase
            // here (instead of waiting for reload() to enter the
            // function) means the UI sees the placeholder from the
            // very first frame, not from whenever refreshMe's first
            // await returns.
            loadPhase = .bootstrapping
            Task { await refreshMe() }
        } else if !UserDefaults.standard.bool(forKey: Self.hasSeenOnboardingKey) {
            // First launch ever (no keychain token + haven't dropped
            // the onboarding flag yet): load demo cards as an inline
            // onboarding tour. The last card has a "Sign in with
            // Apple" chip that exits demo mode. We set the flag on
            // first enterDemoMode so a relaunch goes straight to the
            // sign-in prompt instead of looping the tour.
            enterDemoMode()
        }
    }

    /// UserDefaults key for the first-launch demo gate.
    private static let hasSeenOnboardingKey = "ai.steer.ios.hasSeenOnboarding"

    static var fixtureModeEnabled: Bool {
        if ProcessInfo.processInfo.environment["STEER_FIXTURES"] == "1" {
            return true
        }
        // Honored by XCUITest. `app.launchArguments = ["--uitest"]`
        // forces fixture mode so the system Sign in with Apple sheet
        // never appears. `--uitest-signed-out` is an explicit opt-out
        // for tests that need to exercise the signed-out UI (sign-in
        // prompt, Try Demo entry point) without going through the
        // real Apple flow.
        let argv = ProcessInfo.processInfo.arguments
        if argv.contains("--uitest-signed-out") {
            return false
        }
        if argv.contains("--uitest") {
            return true
        }
        return UserDefaults.standard.bool(forKey: "steer.ios.fixtures")
    }

    /// True when the app booted under `--uitest-signed-out`. The UI
    /// uses this to suppress the real Apple sign-in button so XCUITest
    /// doesn't accidentally trigger the system Apple ID sheet (which
    /// it can't drive anyway).
    static var uitestSignedOutMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitest-signed-out")
    }

    /// True while the user is browsing sample data via Try Demo. Used
    /// by the UI to render a "Sample workspace" badge instead of the
    /// real Mac connection chip and to fake reply state transitions.
    @Published public private(set) var isDemoMode: Bool = false

    /// Demo reply log. Each card cycles through queued -> delivered
    /// (or failed for the dedicated "fixture-failed" sample) so a
    /// reviewer can see the full reply state machine without a Mac.
    public enum DemoReplyState: Equatable {
        case queued
        case delivered
        case failed(reason: String)
    }
    @Published public private(set) var demoReplyStates: [String: DemoReplyState] = [:]

    /// Enter Demo Mode from the signed-out screen. Loads sample cards
    /// and sets isDemoMode true. Safe to call repeatedly.
    public func enterDemoMode() {
        cards = SyncInboxFixtures.cards()
        isDemoMode = true
        status = .signedIn(SyncUser(
            userId: "demo-user",
            appleEmail: nil,
            displayName: "Sample workspace"
        ))
        // First time we enter demo, remember it so the next cold
        // launch goes straight to the sign-in prompt instead of
        // re-running the onboarding tour.
        UserDefaults.standard.set(true, forKey: Self.hasSeenOnboardingKey)
    }

    public func exitDemoMode() {
        cards = []
        demoReplyStates = [:]
        isDemoMode = false
        status = .signedOut
    }

    /// Demo path for replies. Doesn't hit the relay; just records a
    /// queued state, then flips to delivered after a short delay
    /// (or failed for the disconnected-Mac sample card).
    public func sendDemoReply(text: String, for card: CardPayload) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The final onboarding card has a single chip labeled
        // "Sign in with Apple". Tapping it should end demo mode and
        // present the real sign-in surface, not fake a reply.
        if card.cardId == "demo-connect-mac" {
            exitDemoMode()
            return
        }
        demoReplyStates[card.cardId] = .queued
        try? await Task.sleep(nanoseconds: 800_000_000)
        if card.cardId == "fixture-failed" {
            demoReplyStates[card.cardId] = .failed(reason: "sample Mac went offline")
        } else {
            demoReplyStates[card.cardId] = .delivered
        }
    }

    public var isSignedIn: Bool {
        if case .signedIn = status { return true }
        return false
    }

    public func startSignInWithApple() async {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        let controller = ASAuthorizationController(authorizationRequests: [request])
        let delegate = AppleSignInDelegate()
        controller.delegate = delegate
        controller.presentationContextProvider = delegate
        controller.performRequests()
        do {
            let credential = try await delegate.result
            await handleAppleCredential(credential)
        } catch {
            lastError = "Apple sign-in failed: \(error.localizedDescription)"
        }
    }

    /// Entry point for SwiftUI's `SignInWithAppleButton` onCompletion.
    /// Apple already presents the native sheet; we just consume the
    /// result and route into the same backend-call code path as the
    /// programmatic flow above.
    public func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else {
                lastError = "Unexpected credential type from Apple."
                return
            }
            await handleAppleCredential(credential)
        case .failure(let error):
            lastError = "Apple sign-in failed: \(error.localizedDescription)"
        }
    }

    private func handleAppleCredential(_ credential: ASAuthorizationAppleIDCredential) async {
        guard let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8) else {
            lastError = "Apple sign-in returned no identity token."
            return
        }
        // Capture the authorization code if Apple provided one — relay
        // needs it later to revoke the user's Apple-side grant when
        // they delete their account. We forward it on every sign-in
        // so the latest valid auth_code lands on the server for that
        // user; the relay stores it (server-only) and uses it in the
        // /v1/auth/apple/revoke flow during account deletion.
        let authCode: String? = credential.authorizationCode
            .flatMap { String(data: $0, encoding: .utf8) }
        // Apple returns the user's full name only on the FIRST sign-in
        // for a given Apple ID + bundle. Stitch given + family so the
        // server sees the actual name, not just the first token.
        // Subsequent sign-ins return fullName == nil — once that
        // happens the only way to get it back is for the user to
        // revoke the grant via Settings → Apple ID → Sign in with
        // Apple → Steer → Stop Using, then sign in again.
        let displayName: String? = {
            guard let name = credential.fullName else { return nil }
            let parts = [name.givenName, name.familyName]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }()
        let body = AuthAppleRequest(
            identityToken: identityToken,
            displayName: displayName,
            authorizationCode: authCode,
            deviceId: Self.deviceId
        )
        do {
            let response: AuthAppleResponse = try await postJSON(
                "/v1/auth/apple",
                body: body,
                requireAuth: false
            )
            tokenStore.write(response.sessionToken)
            status = .signedIn(response.user)
            connectWebSocket()
            await reload()
            // First-launch UX: as soon as the user is signed in we ask
            // for notification permission. The Apple ID sheet just
            // closed so the user's expecting one more permission
            // dialog. We don't ask before sign-in — that would prompt
            // people who haven't committed yet.
            await requestNotificationPermissionIfNeeded()
            // If APNS already handed us a device token before we
            // finished signing in, send a heartbeat now so the relay
            // learns the token immediately. Without this the token
            // sits in memory until the next reload tick, and a fanout
            // attempt in the meantime finds no APNS target.
            if apnsToken != nil {
                await sendDeviceHeartbeat()
            }
        } catch {
            lastError = "Auth POST failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Notification permission

    public enum NotificationPermission: Equatable {
        case unknown
        case notDetermined
        case granted
        case denied
        case provisional
    }
    @Published public private(set) var notificationPermission: NotificationPermission = .unknown

    /// Pulls the current authorization status without prompting. Run
    /// on launch and on app-foreground so the UI reflects whatever
    /// the user did in iOS Settings out of band.
    public func refreshNotificationPermission() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationPermission = Self.map(settings.authorizationStatus)
        // Belt-and-suspenders: if the system still says
        // notDetermined (because every prior sign-in path skipped
        // the prompt — keychain cold start, demo onboarding tail,
        // etc.) and we're inside the signed-in UI now, ask. The
        // helper bails out cleanly if anyone else already prompted.
        if settings.authorizationStatus == .notDetermined && isSignedIn {
            await requestNotificationPermissionIfNeeded()
            return
        }
        // If we already have permission, also kick off the APNS
        // registration so the relay learns this device's token.
        if notificationPermission == .granted || notificationPermission == .provisional {
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// Shows the system permission dialog if and only if the status
    /// is `.notDetermined`. Already-granted / denied stays put.
    public func requestNotificationPermissionIfNeeded() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let current = await UNUserNotificationCenter.current().notificationSettings()
        guard current.authorizationStatus == .notDetermined else {
            notificationPermission = Self.map(current.authorizationStatus)
            return
        }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            notificationPermission = granted ? .granted : .denied
            if granted {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        } catch {
            notificationPermission = .denied
        }
    }

    // MARK: - Notification deep link

    /// Set when the user taps an APNS banner; InboxView observes this
    /// and scrolls to the matching card. Cleared once the UI has
    /// honored it so a second tap with the same card still works.
    @Published public private(set) var pendingFocusSessionId: String? = nil

    public func requestFocus(cardId: String?, sessionId: String?) {
        // Prefer sessionId — the inbox is indexed by it. cardId is a
        // useful fallback if the relay payload only carried that.
        if let sid = sessionId, !sid.isEmpty {
            pendingFocusSessionId = sid
            return
        }
        guard let cid = cardId,
              let card = cards.first(where: { $0.cardId == cid })
        else { return }
        pendingFocusSessionId = card.sessionId
    }

    public func clearPendingFocus() {
        pendingFocusSessionId = nil
    }

    private static func map(_ s: UNAuthorizationStatus) -> NotificationPermission {
        switch s {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .ephemeral: return .granted
        case .provisional: return .provisional
        @unknown default: return .unknown
        }
    }

    public func signOut() {
        // Fire-and-forget DELETE so the relay drops our device row
        // before we drop the JWT we'd need to authenticate the call.
        // The user has already pressed Sign Out; if the network is
        // down the row will fall off in the 24h prune sweep anyway.
        // Phase B3 of docs/SYNC_STABILITY_AND_COST_PLAN.md.
        if let token = tokenStore.read() {
            let deviceId = Self.deviceId
            let url = baseURL.appendingPathComponent("/v1/sync/devices/\(deviceId)")
            var req = URLRequest(url: url)
            req.httpMethod = "DELETE"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(deviceId, forHTTPHeaderField: "X-Steer-Device-Id")
            Task { _ = try? await urlSession.data(for: req) }
        }
        tokenStore.clear()
        cards = []
        status = .signedOut
        loadPhase = .idle
        webSocketTask?.cancel()
        webSocketTask = nil
        receiveTask?.cancel()
        receiveTask = nil
    }

    public func deleteAccount() async {
        guard isSignedIn else { return }
        // App Store guideline 5.1.1(v) requires the deletion to be
        // effective from the user's perspective even if the server
        // call fails. We always clear the local Keychain token + UI
        // state; surface the server error so the user can retry from
        // a signed-out state instead of being stuck with a token that
        // no longer matches anything on the backend.
        var serverError: String? = nil
        do {
            try await deleteRequest("/v1/me")
        } catch {
            serverError = "Server-side deletion failed (\(error.localizedDescription)). Local data has still been cleared; please contact support if your account persists on the server."
        }
        signOut()  // clears Keychain token + cards + WS
        lastError = serverError
    }

    public func refreshMe() async {
        struct MeResponse: Decodable { let user: SyncUser }
        do {
            let me: MeResponse = try await getJSON("/v1/me")
            status = .signedIn(me.user)
            connectWebSocket()
            await reload()
            // Keychain-token cold start used to skip the permission
            // prompt entirely — handleAppleCredential is the only
            // place that asked. That left users who reinstalled and
            // signed in via the saved token (or who somehow advanced
            // status to .signedIn without going through the Apple
            // sheet, e.g. via the demo onboarding's final card) with
            // an app that never appears in iOS Settings ▸
            // Notifications. Ask here too; the helper is a no-op
            // when the user already answered the dialog.
            await requestNotificationPermissionIfNeeded()
            // Same heartbeat race fix as handleAppleCredential: if
            // APNS already issued a token while we were re-validating
            // the session, push it now so the relay can fan out.
            if apnsToken != nil {
                await sendDeviceHeartbeat()
            }
        } catch {
            tokenStore.clear()
            status = .signedOut
        }
    }

    public func reload() async {
        guard isSignedIn else { return }
        if loadPhase == .idle { loadPhase = .bootstrapping }
        do {
            let resp: CardListResponse = try await getJSON("/v1/sync/cards")
            // Filter out cards we're optimistically replying to so
            // the GET-driven reload doesn't undo the user's send.
            // pendingReplies clears when the relay broadcasts the
            // matching card.resolved (see handleWSText).
            let pendingCardIds = Set(pendingReplies.map(\.cardId))
            cards = resp.cards
                .filter { !pendingCardIds.contains($0.cardId) }
                .sorted { $0.updatedAt < $1.updatedAt }
            // First card list landed — UI can leave the cold-start
            // placeholder, even when the list is empty.
            loadPhase = .ready
            lastError = nil
        } catch {
            lastError = "Failed to load cards: \(error.localizedDescription)"
        }
    }

    /// Persist the most recent APNS device token. Tokens rotate (Apple
    /// issues a new one after restore-from-backup or app reinstall),
    /// so we always keep the latest. Re-pushes a heartbeat so the
    /// relay sees the new token immediately.
    @Published public private(set) var apnsToken: String? = nil

    public func updateAPNSToken(_ hex: String) async {
        guard apnsToken != hex else { return }
        apnsToken = hex
        apnsRegistrationError = nil
        guard isSignedIn else { return }  // first beat happens after sign-in
        await sendDeviceHeartbeat()
    }

    /// Surfaced from `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    /// We render this in Settings ▸ Sync ▸ Notifications so the user
    /// can see WHY a push registration is silently failing.
    @Published public private(set) var apnsRegistrationError: String? = nil

    public func recordAPNSRegistrationError(_ message: String) {
        apnsRegistrationError = message
    }

    /// One-shot heartbeat publisher (the iOS analog of Mac's
    /// `SyncClient.sendDeviceHeartbeat`). Run on launch + foreground
    /// + after APNS token rotation. The Mac chip reads
    /// /v1/sync/devices and uses lastSeenAt to label "Connected" vs
    /// "Stale".
    public func sendDeviceHeartbeat() async {
        guard isSignedIn else { return }
        // aps-environment matches the entitlement baked into the
        // bundle. Debug builds get 'development' and the relay
        // routes them through api.sandbox.push.apple.com; release
        // builds get 'production' and use api.push.apple.com. Phase
        // B2 of docs/SYNC_STABILITY_AND_COST_PLAN.md.
        let apsEnvironment: String
        #if DEBUG
        apsEnvironment = "development"
        #else
        apsEnvironment = "production"
        #endif
        let snapshot = DeviceSnapshot(
            deviceId: Self.deviceId,
            platform: "ios",
            displayName: UIDevice.current.name,
            deviceClass: UIDevice.current.model,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            syncEnabled: true,
            lastSeenAt: Int64(Date().timeIntervalSince1970 * 1000),
            apnsToken: apnsToken,
            apsEnvironment: apsEnvironment
        )
        do {
            try await postJSONIgnoringResponse("/v1/sync/devices", body: snapshot)
        } catch {
            // Silent — the next beat will recover. Don't flap red on
            // every transient network blip.
        }
    }

    /// In-flight reply that the user already saw "leave" the card
    /// stack. Stays here until the relay POST resolves. Failed sends
    /// stay with status=failed so the chip can offer retry/cancel.
    public struct PendingReply: Identifiable, Equatable {
        public let id: String              // instruction id
        public let cardId: String
        public let sessionId: String
        public let cardTitle: String
        public let text: String
        public let sentAt: Date
        public var status: Status

        public enum Status: Equatable { case sending, failed(String) }
    }
    @Published public private(set) var pendingReplies: [PendingReply] = []

    /// Optimistic send: yank the card from `cards` immediately (the
    /// user's intent is "I'm done with it"), put a row in
    /// pendingReplies, and POST in the background. Success: drop the
    /// row. Failure: keep the row at .failed + push the card back so
    /// the user can retry without losing context.
    public func sendReply(text: String, for card: CardPayload) {
        guard isSignedIn else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Snapshot the card BEFORE we remove it so we can restore on
        // failure.
        let snapshot = card
        let instructionId = UUID().uuidString
        let pending = PendingReply(
            id: instructionId,
            cardId: card.cardId,
            sessionId: card.sessionId,
            cardTitle: card.title,
            text: trimmed,
            sentAt: Date(),
            status: .sending
        )
        pendingReplies.append(pending)
        cards.removeAll { $0.cardId == card.cardId }

        Task { [weak self] in
            await self?.postReply(
                pendingId: instructionId,
                request: InstructionRequestV2(
                    instructionId: instructionId,
                    targetSessionId: snapshot.sessionId,
                    text: trimmed
                ),
                cardSnapshot: snapshot
            )
        }
    }

    private func postReply(
        pendingId: String,
        request: InstructionRequestV2,
        cardSnapshot: CardPayload
    ) async {
        struct ReplyResponse: Decodable {
            let ok: Bool
            let instruction: InstructionRecord
        }
        do {
            let _: ReplyResponse = try await postJSON(
                "/v1/sync/instructions",
                body: request
            )
            pendingReplies.removeAll { $0.id == pendingId }
        } catch {
            // Restore the card and mark the pending row failed.
            if !cards.contains(where: { $0.cardId == cardSnapshot.cardId }) {
                cards.append(cardSnapshot)
                cards.sort { $0.updatedAt < $1.updatedAt }
            }
            if let idx = pendingReplies.firstIndex(where: { $0.id == pendingId }) {
                pendingReplies[idx].status = .failed(error.localizedDescription)
            }
        }
    }

    /// Manual retry from the pending-reply chip. Requeues the same
    /// text against the same session.
    public func retryPendingReply(_ id: String) {
        guard let pending = pendingReplies.first(where: { $0.id == id }) else { return }
        let cardId = pending.cardId
        // Drop the failed row; sendReply will append a fresh sending
        // row. If the card is still visible (because we restored it
        // on failure), pull it back out.
        pendingReplies.removeAll { $0.id == id }
        guard let card = cards.first(where: { $0.cardId == cardId }) else { return }
        sendReply(text: pending.text, for: card)
    }

    /// Cancel a failed reply — drop the pending row but leave the
    /// restored card visible so the user can rewrite or skip.
    public func cancelPendingReply(_ id: String) {
        pendingReplies.removeAll { $0.id == id }
    }

    public func resolveCard(_ cardId: String) async {
        guard isSignedIn else { return }
        do {
            try await deleteRequest("/v1/sync/cards/\(cardId)")
            cards.removeAll { $0.cardId == cardId }
        } catch {
            lastError = "resolveCard failed: \(error.localizedDescription)"
        }
    }

    // MARK: - WebSocket (incremental updates)

    private func connectWebSocket() {
        guard let token = tokenStore.read() else { return }
        let wsURL = baseURL.appendingPathComponent("/v1/stream")
        var req = URLRequest(url: wsURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.deviceId, forHTTPHeaderField: "X-Steer-Device-Id")
        webSocketTask?.cancel()
        let task = urlSession.webSocketTask(with: req)
        webSocketTask = task
        task.resume()
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task: task)
        }
    }

    /// Tracked across reconnect attempts so the backoff grows. Reset
    /// to 0 inside connectWebSocket() whenever a connection succeeds
    /// long enough to actually receive a frame — see `handleWSText`.
    private var reconnectAttempt: Int = 0
    private let backoff = WSReconnectBackoff()

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                // First successful frame after a (re)connect means we
                // really are connected — reset the attempt counter.
                if reconnectAttempt > 0 { reconnectAttempt = 0 }
                switch message {
                case .string(let s):
                    handleWSText(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) { handleWSText(s) }
                @unknown default:
                    break
                }
            } catch {
                reconnectAttempt += 1
                let delay = backoff.delaySeconds(forAttempt: reconnectAttempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                connectWebSocket()
                return
            }
        }
    }

    private func handleWSText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(WSMessage.self, from: data) else {
            return
        }
        switch message {
        case .cardUpsert(let card):
            // Drop upserts for any card the user already replied to.
            // Mac re-publishes every active card on each reload tick
            // (~2s), which races our optimistic removal: the user
            // taps Send → we remove the card → 1s later Mac's tick
            // re-publishes the same row → WS broadcast → card pops
            // back in. The reconcile loop on Mac then resolves it
            // ~1s after that ("disappear, reappear, disappear"). We
            // gate WS upserts on the pendingReplies set so the
            // optimistic state wins.
            if pendingReplies.contains(where: { $0.cardId == card.cardId }) {
                return
            }
            // Keep ordering by updatedAt asc; replace existing or append.
            if let idx = cards.firstIndex(where: { $0.cardId == card.cardId }) {
                cards[idx] = card
            } else {
                cards.append(card)
            }
            cards.sort { $0.updatedAt < $1.updatedAt }
            // First WS upsert during cold-start counts as ready —
            // we have at least one real card even if the bootstrap
            // GET hasn't returned yet.
            if loadPhase != .ready { loadPhase = .ready }
        case .cardResolved(let id):
            cards.removeAll { $0.cardId == id }
            // A resolve from the server is the authoritative signal
            // that our pending reply made it through; clear the row.
            pendingReplies.removeAll { $0.cardId == id }
        case .ping:
            sendPong()
        default:
            break
        }
    }

    private func sendPong() {
        guard let task = webSocketTask else { return }
        let pong = WSMessage.pong
        guard let data = try? JSONEncoder().encode(pong),
              let s = String(data: data, encoding: .utf8) else { return }
        Task { try? await task.send(.string(s)) }
    }

    // MARK: - HTTP helpers

    private func getJSON<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        addAuth(&req)
        return try await sendDecoding(req)
    }

    /// Public bridge for satellite observers (DevicePresenceObserver)
    /// that need authenticated GETs without re-implementing the URL
    /// + auth + decoding plumbing.
    public func getJSONRaw<T: Decodable>(_ path: String) async throws -> T {
        try await getJSON(path)
    }

    private func postJSON<Body: Encodable, T: Decodable>(
        _ path: String, body: Body, requireAuth: Bool = true
    ) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if requireAuth { addAuth(&req) }
        req.httpBody = try JSONEncoder().encode(body)
        return try await sendDecoding(req)
    }

    private func postJSONIgnoringResponse<Body: Encodable>(
        _ path: String, body: Body, requireAuth: Bool = true
    ) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if requireAuth { addAuth(&req) }
        req.httpBody = try JSONEncoder().encode(body)
        _ = try await sendRaw(req)
    }

    private func deleteRequest(_ path: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "DELETE"
        addAuth(&req)
        _ = try await sendRaw(req)
    }

    private func addAuth(_ req: inout URLRequest) {
        if let token = tokenStore.read() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // Always include the device id so a device-bound JWT can be
        // verified. Tokens minted before device binding rolled out
        // ignore this header server-side, so it's safe to send
        // unconditionally.
        req.setValue(Self.deviceId, forHTTPHeaderField: "X-Steer-Device-Id")
    }

    /// Stable per-install device id. We prefer identifierForVendor
    /// since it survives iCloud restore (per Apple) and stays the
    /// same for our app's installs. If the system hasn't issued one
    /// yet (rare race during first launch), fall back to a random
    /// Stable across reinstalls and across iOS identifierForVendor
    /// rotations. Keychain survives app uninstall (unlike UserDefaults
    /// or IDFV), so storing the id there means a user who reinstalls
    /// Steer keeps the same device row on the relay instead of
    /// piling up new orphan rows on every fresh install — Phase B1
    /// of docs/SYNC_STABILITY_AND_COST_PLAN.md.
    ///
    /// The keychain item uses `kSecAttrAccessibleAfterFirstUnlock`
    /// so the value is readable in the background after the phone
    /// has been unlocked once since boot (matches when push handling
    /// and heartbeat actually need it). Not synced to iCloud — a new
    /// device should get its own id.
    static let deviceId: String = {
        let service = "ai.steer.relay.deviceId"
        let account = "default"
        if let stored = readDeviceIdFromKeychain(service: service, account: account) {
            return stored
        }
        // First launch on this device (or first launch after a
        // pre-B1 build cleared the keychain). Mint a UUID, persist
        // it, and use it from now on.
        let fresh = UUID().uuidString
        writeDeviceIdToKeychain(fresh, service: service, account: account)
        return fresh
    }()

    private static func readDeviceIdFromKeychain(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private static func writeDeviceIdToKeychain(_ value: String, service: String, account: String) {
        let data = value.data(using: .utf8) ?? Data()
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private func sendDecoding<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, _) = try await sendRaw(req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func sendRaw(_ req: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "SyncInbox",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(code): \(body)"]
            )
        }
        return (data, response)
    }
}

@MainActor
private final class AppleSignInDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

    var result: ASAuthorizationAppleIDCredential {
        get async throws {
            try await withCheckedThrowingContinuation { c in
                self.continuation = c
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            continuation?.resume(throwing: NSError(domain: "SyncInbox", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected credential type"]))
            return
        }
        continuation?.resume(returning: credential)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

final class SessionTokenStore {
    private let service = "ai.steer.relay.session"
    private let account = "default"

    func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ token: String) {
        let data = token.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
