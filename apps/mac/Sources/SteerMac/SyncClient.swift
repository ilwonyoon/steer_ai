import Foundation
import AuthenticationServices
import AppKit
import SteerCore

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
        // Default to localhost during development; flip to the
        // deployed Workers URL via UserDefaults once the user runs
        // `wrangler deploy` and points the app at it.
        let stored = UserDefaults.standard.string(forKey: "ai.steer.relay.baseURL")
            ?? "http://127.0.0.1:8787"
        self.baseURL = URL(string: stored)!
        self.tokenStore = SessionTokenStore()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: cfg)
        if let _ = tokenStore.read() {
            // We have a session JWT but haven't verified it yet —
            // refreshMe will set status to .signedIn or clear the
            // token if the server rejects it.
            Task { await refreshMe() }
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
    public func startSignInWithApple() async {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        let controller = ASAuthorizationController(authorizationRequests: [request])
        let delegate = AppleSignInDelegate()
        controller.delegate = delegate
        controller.presentationContextProvider = delegate
        controller.performRequests()
        // Wait for the delegate to resolve.
        do {
            let credential = try await delegate.result
            await handleAppleCredential(credential)
        } catch {
            lastError = "Apple sign-in failed: \(error.localizedDescription)"
        }
    }

    private func handleAppleCredential(_ credential: ASAuthorizationAppleIDCredential) async {
        guard let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8)
        else {
            lastError = "Apple sign-in returned no identity token."
            return
        }
        let displayName: String? = {
            if let formatted = credential.fullName?.givenName {
                return formatted
            }
            return nil
        }()
        let body = AuthAppleRequest(identityToken: identityToken, displayName: displayName)
        do {
            let response: AuthAppleResponse = try await postJSON(
                "/v1/auth/apple",
                body: body,
                requireAuth: false
            )
            tokenStore.write(response.sessionToken)
            status = .signedIn(response.user)
            connectWebSocket()
        } catch {
            lastError = "Auth POST failed: \(error.localizedDescription)"
        }
    }

    public func refreshMe() async {
        struct MeResponse: Decodable { let user: SyncUser }
        do {
            let me: MeResponse = try await getJSON("/v1/me")
            status = .signedIn(me.user)
            connectWebSocket()
        } catch {
            // Token rejected — nuke it so the next sign-in is clean.
            tokenStore.clear()
            status = .signedOut
        }
    }

    // MARK: - Cards

    public func publishCard(_ card: CardPayload) async {
        guard isSignedIn else { return }
        do {
            try await putJSON("/v1/sync/cards/\(card.cardId)", body: card)
        } catch {
            lastError = "publishCard failed: \(error.localizedDescription)"
        }
    }

    public func resolveCard(cardId: String) async {
        guard isSignedIn else { return }
        do {
            try await deleteRequest("/v1/sync/cards/\(cardId)")
        } catch {
            lastError = "resolveCard failed: \(error.localizedDescription)"
        }
    }

    public func fetchQueuedInstructions() async -> [InstructionRecord] {
        guard isSignedIn else { return [] }
        do {
            let resp: InstructionListResponse = try await getJSON("/v1/sync/instructions/queued")
            return resp.instructions
        } catch {
            lastError = "fetchQueuedInstructions failed: \(error.localizedDescription)"
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
        } catch {
            lastError = "markInjected failed: \(error.localizedDescription)"
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
        webSocketTask?.cancel()
        let task = urlSession.webSocketTask(with: req)
        webSocketTask = task
        task.resume()
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task: task)
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let s):
                    handleWSText(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) { handleWSText(s) }
                @unknown default:
                    break
                }
            } catch {
                // Reconnect after a short delay; the relay drops idle
                // sockets and we want to come back automatically.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
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

/// Apple sign-in delegate that bridges callback into a Swift async
/// continuation. One-shot: re-create per request.
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
            continuation?.resume(throwing: NSError(domain: "SyncClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected credential type"]))
            return
        }
        continuation?.resume(returning: credential)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        return NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
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
