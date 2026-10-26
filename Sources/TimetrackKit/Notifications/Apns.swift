import Foundation
import Crypto
import NIOCore
import NIOHTTP1
import AsyncHTTPClient

/// APNs provider configuration from the environment (ADR-0030). Absent or invalid values mean "APNs push unavailable".
/// `APNS_PRIVATE_KEY` holds the PEM text of the `.p8` key (literal `\n` sequences are accepted for single-line secrets).
struct ApnsConfiguration: Sendable {
    let privateKey: P256.Signing.PrivateKey
    let keyId: String
    let teamId: String
    /// Topics (bundle ids) the server may push to; registrations for other bundle ids are rejected.
    let bundleIds: Set<String>

    init?(environment: [String: String]) {
        guard let rawKey = environment["APNS_PRIVATE_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawKey.isEmpty,
              let keyId = environment["APNS_KEY_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines), Self.validIdentifier(keyId),
              let teamId = environment["APNS_TEAM_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines), Self.validIdentifier(teamId),
              let key = try? P256.Signing.PrivateKey(pemRepresentation: rawKey.replacingOccurrences(of: "\\n", with: "\n")) else { return nil }
        let ids = (environment["APNS_BUNDLE_IDS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !ids.isEmpty, ids.allSatisfy(ApnsDeviceRules.validBundleId) else { return nil }
        privateKey = key; self.keyId = keyId; self.teamId = teamId; bundleIds = Set(ids)
    }
    init(privateKey: P256.Signing.PrivateKey, keyId: String, teamId: String, bundleIds: Set<String>) {
        self.privateKey = privateKey; self.keyId = keyId; self.teamId = teamId; self.bundleIds = bundleIds
    }
    /// Apple key and team identifiers are 10 characters from [A-Z0-9].
    static func validIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) }
    }
    /// True when any APNS_* variable is set (used to warn about incomplete configuration).
    static func anyConfigured(_ environment: [String: String]) -> Bool {
        ["APNS_PRIVATE_KEY", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_BUNDLE_IDS"].contains { !(environment[$0] ?? "").isEmpty }
    }
}

/// Provider token (ES256 JWT). Apple wants a refresh no more often than every 20 minutes and at least once an hour: reuse for 50 minutes.
final class ApnsTokenProvider: @unchecked Sendable {
    static let reuse: TimeInterval = 50 * 60
    private let configuration: ApnsConfiguration
    private let lock = NSLock()
    private var cached: (token: String, issuedAt: Date)?

    init(configuration: ApnsConfiguration) { self.configuration = configuration }

    func token(now: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        if let cached, now >= cached.issuedAt, now.timeIntervalSince(cached.issuedAt) < Self.reuse { return cached.token }
        let token = Self.make(configuration, now: now)
        cached = (token, now)
        return token
    }
    /// Drops the cached token (after ExpiredProviderToken).
    func invalidate() { lock.lock(); cached = nil; lock.unlock() }

    static func make(_ configuration: ApnsConfiguration, now: Date) -> String {
        let header = Data(#"{"alg":"ES256","kid":"\#(configuration.keyId)"}"#.utf8).base64URL
        let claims = Data(#"{"iat":\#(Int(now.timeIntervalSince1970)),"iss":"\#(configuration.teamId)"}"#.utf8).base64URL
        let signature = (try? configuration.privateKey.signature(for: Data((header + "." + claims).utf8)).rawRepresentation.base64URL) ?? ""
        return header + "." + claims + "." + signature
    }
}

/// One APNs message. Alerts use the same generic text as Web Push (ADR-0010); details are fetched by the app after opening.
struct ApnsMessage: Sendable {
    enum Kind: Sendable { case alert(PushMessage, notificationId: UUID?), silentSync }
    let kind: Kind

    static func alert(_ message: PushMessage, notificationId: UUID?) -> ApnsMessage { .init(kind: .alert(message, notificationId: notificationId)) }
    static let silentSync = ApnsMessage(kind: .silentSync)

    var pushType: String { if case .silentSync = kind { return "background" }; return "alert" }
    /// Background pushes must use priority 5; alerts 10.
    var priority: Int { if case .silentSync = kind { return 5 }; return 10 }
    /// At most 64 bytes (`apns-collapse-id`).
    var collapseId: String {
        switch kind {
        case .alert(let message, _): return message.topic
        case .silentSync: return "sync"
        }
    }
    var payload: Data {
        let object: [String: Any]
        switch kind {
        case .silentSync:
            object = ["aps": ["content-available": 1], "kind": "sync"]
        case .alert(let message, let id):
            var body: [String: Any] = [
                "aps": ["alert": ["title": PushMessage.titles[message.kind] ?? "Timetrack", "body": "Öffne Timetrack für Details."],
                        "sound": "default", "thread-id": message.kind],
                "kind": message.kind, "url": message.url,
            ]
            if let id { body["notificationId"] = id.uuidString }
            object = body
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

struct ApnsRequest: Sendable {
    let deviceToken: String
    let environment: String
    let topic: String
    let pushType: String
    let priority: Int
    let collapseId: String
    let expiration: Int
    let authorization: String
    let body: Data
}
struct ApnsResponse: Sendable { let status: Int; let reason: String? }

/// Abstraction over the HTTP/2 call so tests can observe or fail deliveries. Implementations must never log tokens, URLs or bodies.
protocol ApnsTransport: Sendable {
    func send(_ request: ApnsRequest) async throws -> ApnsResponse
    func shutdown() async
}

/// Real transport: AsyncHTTPClient negotiates HTTP/2 through ALPN on the TLS connection to the APNs hosts.
final class HTTP2ApnsTransport: ApnsTransport, @unchecked Sendable {
    static func host(_ environment: String) -> String { environment == "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com" }
    private let group: any EventLoopGroup
    private let lock = NSLock()
    private var client: HTTPClient?
    init(group: any EventLoopGroup) { self.group = group }

    private func shared() -> HTTPClient {
        lock.lock(); defer { lock.unlock() }
        if let client { return client }
        var configuration = HTTPClient.Configuration(redirectConfiguration: .disallow, timeout: .init(connect: .seconds(5), read: .seconds(10)))
        configuration.decompression = .disabled
        let created = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: configuration)
        client = created
        return created
    }

    func send(_ request: ApnsRequest) async throws -> ApnsResponse {
        var outgoing = HTTPClientRequest(url: "https://\(Self.host(request.environment))/3/device/\(request.deviceToken)")
        outgoing.method = .POST
        outgoing.headers.add(name: "authorization", value: "bearer " + request.authorization)
        outgoing.headers.add(name: "apns-topic", value: request.topic)
        outgoing.headers.add(name: "apns-push-type", value: request.pushType)
        outgoing.headers.add(name: "apns-priority", value: String(request.priority))
        outgoing.headers.add(name: "apns-collapse-id", value: request.collapseId)
        outgoing.headers.add(name: "apns-expiration", value: String(request.expiration))
        outgoing.headers.add(name: "content-type", value: "application/json")
        outgoing.body = .bytes(ByteBuffer(data: request.body))
        let response = try await shared().execute(outgoing, timeout: .seconds(15))
        let body = (try? await response.body.collect(upTo: 4096)).map { Data($0.readableBytesView) } ?? Data()
        let reason = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["reason"] as? String
        return ApnsResponse(status: Int(response.status.code), reason: reason)
    }

    private func take() -> HTTPClient? { lock.lock(); defer { lock.unlock() }; let current = client; client = nil; return current }

    func shutdown() async {
        try? await take()?.shutdown()
    }
}

struct ApnsSender: Sendable {
    let configuration: ApnsConfiguration
    let tokens: ApnsTokenProvider
    let transport: any ApnsTransport

    init(configuration: ApnsConfiguration, transport: any ApnsTransport) {
        self.configuration = configuration; self.transport = transport; tokens = ApnsTokenProvider(configuration: configuration)
    }

    /// Delivery result: `.gone` for 410, BadDeviceToken and Unregistered (the caller deletes the token), `.retry` for throttling,
    /// server errors, an expired provider token and network errors.
    func deliver(_ message: ApnsMessage, token: String, environment: String, topic: String, now: Date) async -> PushOutcome {
        let request = ApnsRequest(deviceToken: token, environment: environment, topic: topic, pushType: message.pushType, priority: message.priority,
                                  collapseId: message.collapseId, expiration: Int(now.timeIntervalSince1970) + 86400,
                                  authorization: tokens.token(now: now), body: message.payload)
        do {
            let response = try await transport.send(request)
            switch (response.status, response.reason ?? "") {
            case (200, _): return .delivered
            case (410, _), (400, "BadDeviceToken"), (_, "Unregistered"): return .gone
            case (403, "ExpiredProviderToken"): tokens.invalidate(); return .retry("apns_expired_provider_token")
            case (429, _), (500...599, _): return .retry("http_\(response.status)")
            default: return .failed("apns_" + String((response.reason ?? "http_\(response.status)").filter { $0.isLetter || $0.isNumber || $0 == "_" }.prefix(40)))
            }
        } catch { return .retry("network") }
    }
}
