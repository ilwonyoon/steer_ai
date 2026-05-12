import Foundation
import AuthenticationServices
import AppKit
import SteerCore

/// File log for the relay client. unified log filtering has been
/// flaky for sandboxless dev builds; ~/.steer/relay-client.log
/// gives us a reliable trail to diagnose sign-in stalls.
enum SignInDebugLog {
    static let path: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".steer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("relay-client.log").path
    }()
    static func write(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let h = FileHandle(forWritingAtPath: path) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}

/// REST + WebSocket client against the Steer relay backend.
///
/// Lifecycle:
///   1. App launch -> read session token from Keychain
///   2. If absent -> show Sign in with Apple button (handled by
///      SyncSignInPresenter); on success POST /v1/auth/apple and
///      store the returned session JWT
///   3. On every reload from SteerRootView, push pending cards via
///      PUT /v1/sync/cards/:id and pull queued instructions via
///      GET /v1/sync/instructions/queued
///   4. Hold a WebSocket open for instruction.queued / card.upsert
///      pushes so iPhone replies arrive faster than poll cadence
///
/// Direct dmg / dogfood mode: the relay is opt-in via Settings, so
/// when the toggle is off everything below no-ops cleanly and the
/// existing local SQLite path keeps working unchanged.
@MainActor
public final class SyncClient: ObservableObject {
    public static let shared = SyncClient()

    @Published public private(set) var status: Status = .signedOut
    @Published public private(set) var lastError: String?

    public enum Status: Equatable {
        case signedOut
        case signedIn(SyncUser)
        case syncing
        case offline
    }

    private let baseURL: URL
    private let tokenStore: SessionTokenStore
    private let urlSession: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    private init() {
        // Default to the deployed Workers relay. Override via
        // UserDefaults `ai.steer.relay.baseURL` when running a local
        // wrangler dev server.
        let stored = UserDefaults.standard.string(forKey: "ai.steer.relay.baseURL")
            ?? "https://steer-relay.ilwonyoon-turtleneck.workers.dev"
        self.baseURL = URL(string: stored)!
        SignInDebugLog.write("[init] baseURL=\(self.baseURL.absoluteString)")
        self.tokenStore = SessionTokenStore()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: cfg)
        if let _ = tokenStore.read() {
            SignInDebugLog.write("[init] keychain JWT present, will refreshMe")
            Task { await refreshMe() }
        } else {
            SignInDebugLog.write("[init] no JWT in keychain")
        }
    }

    public var isSignedIn: Bool {
        if case .signedIn = status { return true }
        return false
    }

    public var sessionToken: String? { tokenStore.read() }

    public func setBaseURL(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: "ai.steer.relay.baseURL")
        // Force a process restart for the change to take effect; the
        // base URL is captured in init() above.
    }

    public func signOut() {
        tokenStore.clear()
        status = .signedOut
        webSocketTask?.cancel()
        webSocketTask = nil
        receiveTask?.cancel()
        receiveTask = nil
    }

    /// Kicks off Sign in with Apple. The presenting window must be
    /// available; SwiftUI Settings/onboarding contexts both work.
    /// Strong reference holder so the delegate + controller stay
    /// alive between performRequests() and the system callback.
    /// Both delegate (controller.delegate is weak) and controller
    /// would otherwise deallocate the moment startSignInWithApple
    /// returns past `await`, which is exactly when the system tries
    /// to invoke them.
    private var pendingSignIn: PendingSignIn?

    public func startSignInWithApple() async {
        do {
            let credential = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>) in
                let provider = ASAuthorizationAppleIDProvider()
                let request = provider.createRequest()
                request.requestedScopes = [.fullName, .email]
                let controller = ASAuthorizationController(authorizationRequests: [request])
                let delegate = AppleSignInDelegate(continuation: cont)
                controller.delegate = delegate
                controller.presentationContextProvider = delegate
                self.pendingSignIn = PendingSignIn(controller: controller, delegate: delegate)
                controller.performRequests()
                SignInDebugLog.write("[apple-signin] performRequests called")
            }
            self.pendingSignIn = nil
            SignInDebugLog.write("[apple-signin] credential received")
            await handleAppleCredential(credential)
        } catch {
            self.pendingSignIn = nil
            SignInDebugLog.write("[apple-signin] failed: \(error)")
            // Same canceled-suppression rationale as
            // handleAppleSignInResult above — keep silent on user
            // cancel + macOS 26 transient retry-cancel, surface
            // everything else.
            let ns = error as NSError
            let isCanceled =
                ns.domain == ASAuthorizationError.errorDomain
                && ns.code == ASAuthorizationError.canceled.rawValue
            if !isCanceled {
                lastError = "Apple sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    private struct PendingSignIn {
        let controller: ASAuthorizationController
        let delegate: AppleSignInDelegate
    }

    /// SwiftUI `SignInWithAppleButton` onCompletion entry point.
    /// Mirrors iOS's handleAppleSignInResult so the native button can
    /// drive the same backend flow as the programmatic sign-in.
    public func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else {
                lastError = "Unexpected credential type from Apple."
                return
            }
            await handleAppleCredential(credential)
        case .failure(let error):
            SignInDebugLog.write("[apple-signin] onCompletion failure: \(error)")
            // ASAuthorizationError.canceled fires when the user
            // dismisses the system sheet OR — more often than you'd
            // expect — when macOS 26's SignInWithAppleButton emits a
            // transient cancellation before re-presenting the sheet
            // and succeeding on the next pass. Either way it's not
            // something the user wants to read in red right above
            // the button they just clicked.
            //
            // Other failure modes (network, missing entitlement)
            // SHOULD surface, so we only silence the canceled code.
            let ns = error as NSError
            let isCanceled =
                ns.domain == ASAuthorizationError.errorDomain
                && ns.code == ASAuthorizationError.canceled.rawValue
            if !isCanceled {
                lastError = "Apple sign-in failed: \(error.localizedDescription)"
            }
            status = .signedOut
        }
    }

    private func handleAppleCredential(_ credential: ASAuthorizationAppleIDCredential) async {
        SignInDebugLog.write("[apple-signin] handleAppleCredential start, user=\(credential.user)")
        guard let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8)
        else {
            SignInDebugLog.write("[apple-signin] no identityToken on credential")
            lastError = "Apple sign-in returned no identity token."
            status = .signedOut
            return
        }
        SignInDebugLog.write("[apple-signin] identityToken bytes=\(tokenData.count)")
        // Apple returns fullName only on the FIRST sign-in for a given
        // Apple ID + bundle. Stitch given + family so the server sees
        // the actual name, not just the first token. Subsequent
        // sign-ins return fullName == nil; the only way to get it
        // back is to revoke the grant via System Settings → Apple ID
        // → Sign in with Apple → Steer → Stop Using, then sign in
        // again.
        let displayName: String? = {
            guard let name = credential.fullName else { return nil }
            let parts = [name.givenName, name.familyName]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }()
        // authorizationCode lets the relay later call Apple's revoke
        // endpoint when the user deletes their account.
        let authCode = credential.authorizationCode
            .flatMap { String(data: $0, encoding: .utf8) }
        let body = AuthAppleRequest(
            identityToken: identityToken,
            displayName: displayName,
            authorizationCode: authCode,
            deviceId: Self.deviceId
        )
        do {
            SignInDebugLog.write("[apple-signin] POST \(baseURL.absoluteString)/v1/auth/apple")
            let response: AuthAppleResponse = try await postJSON(
                "/v1/auth/apple",
                body: body,
                requireAuth: false
            )
            SignInDebugLog.write("[apple-signin] backend OK, user=\(response.user.userId)")
            tokenStore.write(response.sessionToken)
            status = .signedIn(response.user)
            connectWebSocket()
        } catch {
            SignInDebugLog.write("[apple-signin] backend FAILED: \(error)")
            lastError = "Auth POST failed: \(error.localizedDescription)"
            status = .signedOut
        }
    }

    public func refreshMe() async {
        struct MeResponse: Decodable { let user: SyncUser }
        do {
            SignInDebugLog.write("[refreshMe] GET /v1/me")
            let me: MeResponse = try await getJSON("/v1/me")
            SignInDebugLog.write("[refreshMe] OK user=\(me.user.userId)")
            status = .signedIn(me.user)
            connectWebSocket()
        } catch {
            SignInDebugLog.write("[refreshMe] FAILED, clearing token: \(error)")
            tokenStore.clear()
            status = .signedOut
        }
    }

    // MARK: - Device presence

    /// Stable per-install Mac device id, generated on first call and
    /// kept in UserDefaults so the server keeps a single device row
    /// across launches. We deliberately don't put this in Keychain —
    /// it's not a credential, just an identifier for presence rows.
    public static var deviceId: String {
        let key = "ai.steer.mac.deviceId"
        if let id = UserDefaults.standard.string(forKey: key), !id.isEmpty {
            return id
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// Send one device heartbeat to the relay. Caller decides cadence
    /// (typically 60s while iPhone Sync is on, plus an immediate beat
    /// on launch). Best-effort; failures don't surface to the user.
    public func sendDeviceHeartbeat(syncEnabled: Bool) async {
        guard isSignedIn else {
            SignInDebugLog.write("[heartbeat] skipped (not signed in)")
            return
        }
        let snapshot = DeviceSnapshot(
            deviceId: Self.deviceId,
            platform: "mac",
            displayName: Host.current().localizedName,
            deviceClass: macDeviceClass(),
            appVersion: appVersionString(),
            syncEnabled: syncEnabled,
            lastSeenAt: Int64(Date().timeIntervalSince1970 * 1000.0)
        )
        do {
            try await postJSONIgnoringResponse("/v1/sync/devices", body: snapshot)
            SignInDebugLog.write("[heartbeat] OK syncEnabled=\(syncEnabled)")
        } catch {
            SignInDebugLog.write("[heartbeat] FAILED: \(error)")
        }
    }

    private func macDeviceClass() -> String {
        // sysctl hw.model gives "MacBookAir10,1", "Macmini9,1" etc.
        // We fold those into the user-facing classes called out in
        // CROSS_DEVICE_ONBOARDING_PLAN: MacBook Air, MacBook Pro,
        // Mac mini, Mac Studio, iMac, or fallback "Mac".
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var raw = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &raw, &size, nil, 0)
        let model = String(cString: raw)
        if model.hasPrefix("MacBookAir") { return "MacBook Air" }
        if model.hasPrefix("MacBookPro") { return "MacBook Pro" }
        if model.hasPrefix("MacBook")    { return "MacBook" }
        if model.hasPrefix("Macmini")    { return "Mac mini" }
        if model.hasPrefix("MacStudio")  { return "Mac Studio" }
        if model.hasPrefix("iMac")       { return "iMac" }
        if model.hasPrefix("MacPro")     { return "Mac Pro" }
        return "Mac"
    }

    private func appVersionString() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "0"
        let b = info["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }

    // MARK: - Cards

    /// Errors we deliberately HIDE from the Settings status row, even
    /// though they're real failures, because they all resolve on the
    /// very next tick without user intervention:
    ///
    ///   * NSURLErrorCancelled — in-flight URLSession task lost its
    ///     race with the next reload tick.
    ///   * HTTP 401 unauthorized — stale or absent JWT. Shows up
    ///     during the brief window between app launch and the first
    ///     refreshMe/sign-in completing, or right after the JWT
    ///     expires. The 2s reload loop tries again immediately, so
    ///     flashing red here just makes a healthy sign-in look
    ///     broken. The user already sees the truthful state in the
    ///     "Status:" row ("Not signed in" vs "Signed in as ...").
    ///
    /// Both still get written to relay-client.log via SignInDebugLog
    /// so we can still diagnose persistent issues.
    private func isTransientError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        if ns.domain == "SyncClient" && ns.code == 401 { return true }
        return false
    }

    /// Pull every card the relay still considers active for this
    /// user. The Mac reconciles against this list each reload tick so
    /// cards that no longer exist on disk get resolved server-side
    /// (otherwise the iPhone keeps showing them forever).
    public func fetchActiveCards() async -> [CardPayload] {
        guard isSignedIn else { return [] }
        struct ListResponse: Decodable { let cards: [CardPayload] }
        do {
            let resp: ListResponse = try await getJSON("/v1/sync/cards")
            return resp.cards
        } catch {
            if !isTransientError(error) {
                SignInDebugLog.write("[fetchActiveCards] failed: \(error)")
            }
            return []
        }
    }

    public func publishCard(_ card: CardPayload) async {
        guard isSignedIn else {
            SignInDebugLog.write("[publish] skipped (not signed in) card=\(card.cardId)")
            return
        }
        do {
            try await putJSON("/v1/sync/cards/\(card.cardId)", body: card)
            SignInDebugLog.write("[publish] OK card=\(card.cardId) state=\(card.state)")
            lastError = nil
        } catch {
            SignInDebugLog.write("[publish] FAILED card=\(card.cardId): \(error)")
            if !isTransientError(error) {
                lastError = "publishCard failed: \(error.localizedDescription)"
            }
        }
    }

    public func resolveCard(cardId: String) async {
        guard isSignedIn else { return }
        do {
            try await deleteRequest("/v1/sync/cards/\(cardId)")
            lastError = nil
        } catch {
            if !isTransientError(error) {
                lastError = "resolveCard failed: \(error.localizedDescription)"
            }
        }
    }

    public func fetchQueuedInstructions() async -> [InstructionRecord] {
        guard isSignedIn else { return [] }
        do {
            let resp: InstructionListResponse = try await getJSON("/v1/sync/instructions/queued")
            lastError = nil
            return resp.instructions
        } catch {
            if !isTransientError(error) {
                lastError = "fetchQueuedInstructions failed: \(error.localizedDescription)"
            }
            return []
        }
    }

    public func markInstructionInjected(instructionId: String) async {
        guard isSignedIn else { return }
        struct StatusBody: Encodable { let status: String }
        do {
            try await postJSONIgnoringResponse(
                "/v1/sync/instructions/\(instructionId)/status",
                body: StatusBody(status: "injected")
            )
            lastError = nil
        } catch {
            if !isTransientError(error) {
                lastError = "markInjected failed: \(error.localizedDescription)"
            }
        }
    }

    public func markInstructionFailed(instructionId: String, reason: String) async {
        guard isSignedIn else { return }
        struct StatusBody: Encodable {
            let status: String
            let failureReason: String
        }
        do {
            try await postJSONIgnoringResponse(
                "/v1/sync/instructions/\(instructionId)/status",
                body: StatusBody(status: "failed", failureReason: reason)
            )
        } catch {
            lastError = "markFailed failed: \(error.localizedDescription)"
        }
    }

    // MARK: - WebSocket

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
        // Cloudflare Workers Durable Objects close idle WebSockets
        // after ~5–10 min. We saw the wrangler tail print
        //   GET /v1/stream - Canceled @ 11:01:31 PM (last activity 10:55)
        // every ~6 min in the user's session, dropping the socket
        // during the exact window an iPhone reply would have been
        // pushed. The relay only sends a single ping on accept and
        // never again; clients didn't send any ping either. Drive
        // a client-side ping every 30s so Cloudflare's idle timer
        // never trips: any pong (or even the bare ping send) keeps
        // the socket warm. Sized at 30s so we tolerate one missed
        // ping cycle before Cloudflare's window expires.
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            await self?.pingLoop(task: task)
        }
    }

    private var pingTask: Task<Void, Never>?

    private func pingLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            // If the receive loop already moved on to a new socket,
            // stop pinging the old one.
            guard task === webSocketTask else { return }
            let ping = WSMessage.ping
            guard let data = try? JSONEncoder().encode(ping),
                  let s = String(data: data, encoding: .utf8) else { continue }
            do {
                try await task.send(.string(s))
            } catch {
                // Send failure means the socket is already dead;
                // the receive loop will surface the same error and
                // trigger reconnect. Just exit the ping loop.
                return
            }
        }
    }

    /// Tracked across reconnect attempts so the backoff grows. Reset
    /// to 0 on every successful frame.
    private var reconnectAttempt: Int = 0
    private let backoff = WSReconnectBackoff()

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
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
                // Exponential backoff: 1s, 2s, 4s, 8s, 16s, then 30s
                // capped. Avoids hammering the relay during a network
                // outage (subway, weak cell, captive portal). See
                // WSReconnectBackoffTests for the cadence proof.
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
        case .ping:
            sendPong()
        default:
            // For now just nudge the UI to refresh when *anything*
            // arrives. Phase X.10 wires per-message handling.
            NotificationCenter.default.post(name: .syncDidReceiveUpdate, object: nil)
        }
    }

    private func sendPong() {
        guard let task = webSocketTask else { return }
        let pong = WSMessage.pong
        guard let data = try? JSONEncoder().encode(pong),
              let s = String(data: data, encoding: .utf8) else { return }
        Task {
            try? await task.send(.string(s))
        }
    }

    // MARK: - HTTP helpers

    private func getJSON<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        addAuth(&req)
        return try await sendDecoding(req)
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
        _ path: String, body: Body
    ) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuth(&req)
        req.httpBody = try JSONEncoder().encode(body)
        _ = try await sendRaw(req)
    }

    private func putJSON<Body: Encodable>(_ path: String, body: Body) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuth(&req)
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
        // Reuses the existing per-install deviceId defined above for
        // the device-presence flow. Same identity, so a sign-in's
        // `did` claim aligns with whatever the heartbeat already
        // registered server-side.
        req.setValue(Self.deviceId, forHTTPHeaderField: "X-Steer-Device-Id")
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
                domain: "SyncClient",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(code): \(body)"]
            )
        }
        return (data, response)
    }
}

extension Notification.Name {
    public static let syncDidReceiveUpdate = Notification.Name("ai.steer.sync.didReceiveUpdate")
}

/// Apple sign-in delegate. Bridges the AuthenticationServices
/// callback into a Swift continuation. The owning SyncClient holds
/// a strong reference (PendingSignIn) so this object stays alive
/// for the entire round trip — controller.delegate is weak and the
/// system invokes it asynchronously.
@MainActor
private final class AppleSignInDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

    init(continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>) {
        self.continuation = continuation
        super.init()
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in
            guard let cont = self.continuation else { return }
            self.continuation = nil
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                cont.resume(throwing: NSError(domain: "SyncClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected credential type"]))
                return
            }
            cont.resume(returning: credential)
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            guard let cont = self.continuation else { return }
            self.continuation = nil
            cont.resume(throwing: error)
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Run sync on main thread to grab key window.
        return MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
        }
    }
}

/// Session JWT lives in the macOS keychain so it survives reboots.
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
