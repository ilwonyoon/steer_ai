import Foundation
import AuthenticationServices
import UIKit
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
        if tokenStore.read() != nil {
            Task { await refreshMe() }
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

    private func handleAppleCredential(_ credential: ASAuthorizationAppleIDCredential) async {
        guard let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8) else {
            lastError = "Apple sign-in returned no identity token."
            return
        }
        let displayName = credential.fullName?.givenName
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
            await reload()
        } catch {
            lastError = "Auth POST failed: \(error.localizedDescription)"
        }
    }

    public func signOut() {
        tokenStore.clear()
        cards = []
        status = .signedOut
        webSocketTask?.cancel()
        webSocketTask = nil
        receiveTask?.cancel()
        receiveTask = nil
    }

    public func refreshMe() async {
        struct MeResponse: Decodable { let user: SyncUser }
        do {
            let me: MeResponse = try await getJSON("/v1/me")
            status = .signedIn(me.user)
            connectWebSocket()
            await reload()
        } catch {
            tokenStore.clear()
            status = .signedOut
        }
    }

    public func reload() async {
        guard isSignedIn else { return }
        do {
            let resp: CardListResponse = try await getJSON("/v1/sync/cards")
            cards = resp.cards.sorted { $0.updatedAt < $1.updatedAt }
            lastError = nil
        } catch {
            lastError = "Failed to load cards: \(error.localizedDescription)"
        }
    }

    public func sendReply(text: String, for card: CardPayload) async {
        guard isSignedIn else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let request = InstructionRequestV2(
            instructionId: UUID().uuidString,
            targetSessionId: card.sessionId,
            text: trimmed
        )
        struct ReplyResponse: Decodable {
            let ok: Bool
            let instruction: InstructionRecord
        }
        do {
            let _: ReplyResponse = try await postJSON(
                "/v1/sync/instructions",
                body: request
            )
        } catch {
            lastError = "Reply send failed: \(error.localizedDescription)"
        }
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
        case .cardUpsert(let card):
            // Keep ordering by updatedAt asc; replace existing or append.
            if let idx = cards.firstIndex(where: { $0.cardId == card.cardId }) {
                cards[idx] = card
            } else {
                cards.append(card)
            }
            cards.sort { $0.updatedAt < $1.updatedAt }
        case .cardResolved(let id):
            cards.removeAll { $0.cardId == id }
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
