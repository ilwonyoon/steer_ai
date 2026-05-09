import Foundation
import SteerCore

/// HTTP client for CloudKit Web Services. Used on macOS Direct
/// Distribution builds where adding `com.apple.developer.icloud-services`
/// entitlement is rejected by launchd. Talks REST against
/// `api.apple-cloudkit.com` with the same private CloudKit container
/// the iPhone CKContainer SDK uses, so both apps see the same records.
///
/// Auth flow:
///   1. First request goes out with only the API token. Apple responds
///      with `AUTHENTICATION_REQUIRED` plus a `redirectURL`.
///   2. The Mac UI opens that URL in WKWebView; user signs in with
///      Apple ID; redirect query param yields `ckWebAuthToken`.
///   3. We persist the token in Keychain. Every later request appends
///      `ckWebAuthToken` along with the API token.
///   4. Tokens rotate per response. We swap them as we go.
@MainActor
final class CloudKitWebClient {
    enum Environment: String {
        case development
        case production
    }

    enum ClientError: Error {
        case authenticationRequired(redirectURL: URL)
        case missingAPIToken
        case http(status: Int, body: String)
        case decoding(Error)
        case transport(Error)
    }

    private let containerIdentifier: String
    private let environment: Environment
    private let apiToken: String
    private let session: URLSession
    private let tokenStore: WebAuthTokenStore

    init(
        containerIdentifier: String = CloudKitFields.containerIdentifier,
        environment: Environment = .development,
        apiToken: String,
        session: URLSession = .shared,
        tokenStore: WebAuthTokenStore = WebAuthTokenStore()
    ) {
        self.containerIdentifier = containerIdentifier
        self.environment = environment
        self.apiToken = apiToken
        self.session = session
        self.tokenStore = tokenStore
    }

    var hasWebAuthToken: Bool { tokenStore.read() != nil }

    func clearWebAuthToken() { tokenStore.clear() }

    func setWebAuthToken(_ token: String) { tokenStore.write(token) }

    /// Modify records. Mirrors `CKModifyRecordsOperation`.
    /// Returns the freshly written records (CloudKit echoes them back).
    func modifyRecords(_ operations: [RecordModify]) async throws -> [RecordResponse] {
        let body: [String: Any] = [
            "operations": operations.map { $0.asJSON() },
            "zone": ["zoneID": ["zoneName": CloudKitFields.zoneName]]
        ]
        let result: ModifyResponse = try await post(path: "records/modify", body: body)
        return result.records
    }

    /// Run a query for records of a given type.
    func queryRecords(recordType: String, filterBy: [QueryFilter] = []) async throws -> [RecordResponse] {
        let body: [String: Any] = [
            "query": [
                "recordType": recordType,
                "filterBy": filterBy.map { $0.asJSON() }
            ],
            "zoneID": ["zoneName": CloudKitFields.zoneName]
        ]
        let result: QueryResponse = try await post(path: "records/query", body: body)
        return result.records
    }

    /// Look up specific records by recordName.
    func lookupRecords(recordNames: [String]) async throws -> [RecordResponse] {
        let body: [String: Any] = [
            "records": recordNames.map { ["recordName": $0] },
            "zoneID": ["zoneName": CloudKitFields.zoneName]
        ]
        let result: LookupResponse = try await post(path: "records/lookup", body: body)
        return result.records
    }

    // MARK: - HTTP

    private func post<T: Decodable>(path: String, body: [String: Any]) async throws -> T {
        var components = URLComponents(string: "https://api.apple-cloudkit.com/database/1/\(containerIdentifier)/\(environment.rawValue)/private/\(path)")!
        var queryItems = [URLQueryItem(name: "ckAPIToken", value: apiToken)]
        if let webToken = tokenStore.read() {
            queryItems.append(URLQueryItem(name: "ckWebAuthToken", value: webToken))
        }
        components.queryItems = queryItems
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.http(status: -1, body: "no http response")
        }

        // CloudKit returns 421 (sometimes 401) with a JSON envelope
        // containing a redirectURL when ckWebAuthToken is missing or
        // expired. We treat any non-2xx that decodes to that envelope
        // as the "needs sign-in" signal so we don't have to guess the
        // exact status code Apple uses today.
        if !(200..<300).contains(http.statusCode),
           let envelope = try? JSONDecoder().decode(AuthRequiredEnvelope.self, from: data),
           envelope.serverErrorCode == "AUTHENTICATION_REQUIRED",
           let url = envelope.redirectURL.flatMap(URL.init(string:)) {
            throw ClientError.authenticationRequired(redirectURL: url)
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.http(status: http.statusCode, body: body)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClientError.decoding(error)
        }
    }

    // MARK: - Request shapes

    struct RecordModify {
        let operationType: String  // "create" | "update" | "forceUpdate" | "delete"
        let recordName: String
        let recordType: String
        let fields: [String: Any]

        func asJSON() -> [String: Any] {
            var record: [String: Any] = [
                "recordName": recordName,
                "recordType": recordType
            ]
            if !fields.isEmpty {
                record["fields"] = fields.mapValues { ["value": $0] }
            }
            return [
                "operationType": operationType,
                "record": record
            ]
        }
    }

    struct QueryFilter {
        let fieldName: String
        let comparator: String  // "EQUALS" | "NOT_EQUALS" | etc.
        let fieldValue: Any

        func asJSON() -> [String: Any] {
            return [
                "fieldName": fieldName,
                "comparator": comparator,
                "fieldValue": ["value": fieldValue]
            ]
        }
    }

    // MARK: - Response shapes

    struct AuthRequiredEnvelope: Decodable {
        let uuid: String?
        let serverErrorCode: String?
        let redirectURL: String?
    }

    struct ModifyResponse: Decodable {
        let records: [RecordResponse]
    }

    struct QueryResponse: Decodable {
        let records: [RecordResponse]
        let continuationMarker: String?
    }

    struct LookupResponse: Decodable {
        let records: [RecordResponse]
    }

    struct RecordResponse: Decodable {
        let recordName: String
        let recordType: String?
        let fields: [String: FieldEnvelope]?
        let recordChangeTag: String?
        let created: TimestampEntry?
        let modified: TimestampEntry?
        let deleted: Bool?

        struct FieldEnvelope: Decodable {
            let value: AnyCodable?
            let type: String?
        }

        struct TimestampEntry: Decodable {
            let timestamp: Int64?  // milliseconds since epoch
            let userRecordName: String?
            let deviceID: String?
        }
    }
}

/// Type-erased decoder for `value` fields whose type CloudKit reports
/// inline. We only care about strings, ints, and string arrays for the
/// Steer schema; everything else stays as the raw JSON for inspection.
struct AnyCodable: Decodable {
    let raw: Any?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            raw = s
        } else if let i = try? container.decode(Int64.self) {
            raw = i
        } else if let d = try? container.decode(Double.self) {
            raw = d
        } else if let arr = try? container.decode([String].self) {
            raw = arr
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            raw = dict.mapValues(\.raw)
        } else {
            raw = nil
        }
    }
}

/// Persists the CloudKit web auth token in the macOS keychain so it
/// survives app restarts. The token is sensitive (lets anyone read the
/// user's CloudKit container) so we don't put it in UserDefaults.
final class WebAuthTokenStore {
    private let service = "ai.steer.mac.cloudkit.webauth"
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
