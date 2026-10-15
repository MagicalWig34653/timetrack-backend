import Foundation
import Crypto
import NIOCore
import NIOHTTP1
import AsyncHTTPClient

struct PushHTTPRequest: Sendable {
    let url: String
    let headers: [String: String]
    let body: Data
}

/// Abstraction over the HTTP call so tests can observe or fail deliveries. Implementations must never log URLs or bodies.
protocol PushTransport: Sendable {
    /// Returns the HTTP status code of the push service.
    func send(_ request: PushHTTPRequest) async throws -> Int
    func shutdown() async
}

final class HTTPPushTransport: PushTransport, @unchecked Sendable {
    private let client: HTTPClient
    init(group: any EventLoopGroup) {
        var configuration = HTTPClient.Configuration(redirectConfiguration: .disallow, timeout: .init(connect: .seconds(5), read: .seconds(10)))
        configuration.decompression = .disabled
        client = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: configuration)
    }
    func send(_ request: PushHTTPRequest) async throws -> Int {
        var outgoing = HTTPClientRequest(url: request.url)
        outgoing.method = .POST
        for (name, value) in request.headers { outgoing.headers.add(name: name, value: value) }
        outgoing.body = .bytes(ByteBuffer(data: request.body))
        let response = try await client.execute(outgoing, timeout: .seconds(15))
        _ = try? await response.body.collect(upTo: 4096)
        return Int(response.status.code)
    }
    func shutdown() async { try? await client.shutdown() }
}

enum PushOutcome: Equatable, Sendable {
    case delivered, gone, retry(String), failed(String)
}

/// Generic push content: never contains names, times, places or notes (ADR-0010).
struct PushMessage: Sendable {
    let kind: String
    let url: String
    let tag: String

    static let titles: [String: String] = [
        "running_timer": "Timer läuft noch", "pending_suggestions": "Offene Vorschläge",
        "report_gap": "Berichtsheft-Erinnerung", "document_submission": "Unterlagen offen", "system": "Timetrack",
    ]
    var payload: Data {
        let object: [String: String] = ["title": Self.titles[kind] ?? "Timetrack", "body": "Öffne Timetrack für Details.", "url": url, "tag": tag, "kind": kind]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
    /// Topic header: URL-safe base64 alphabet, at most 32 characters.
    var topic: String { String(Data(SHA256.hash(data: Data(tag.utf8))).base64URL.prefix(32)) }
}

struct PushSender: Sendable {
    let vapid: VapidConfiguration
    let transport: any PushTransport

    func deliver(_ message: PushMessage, endpoint: String, p256dh: String, auth: String, now: Date) async -> PushOutcome {
        guard let key = Data(base64URL: p256dh), let secret = Data(base64URL: auth), let origin = VapidConfiguration.origin(of: endpoint),
              let body = try? WebPushCrypto.encrypt(message.payload, userAgentPublicKey: key, authSecret: secret, paddedLength: 128),
              let authorization = try? vapid.authorization(audience: origin, now: now) else { return .failed("invalid_subscription") }
        let request = PushHTTPRequest(url: endpoint, headers: [
            "Authorization": authorization, "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream",
            "TTL": "86400", "Urgency": "normal", "Topic": message.topic,
        ], body: body)
        do {
            let status = try await transport.send(request)
            switch status {
            case 200, 201, 202: return .delivered
            case 404, 410: return .gone
            case 429, 500...599: return .retry("http_\(status)")
            default: return .failed("http_\(status)")
            }
        } catch { return .retry("network") }
    }
}

enum PushSubscriptionValidation {
    static func endpoint(_ raw: String) -> (url: String, host: String)? {
        guard raw.count <= 2048, raw.utf8.allSatisfy({ $0 > 32 && $0 < 127 }), let parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
        return (raw, host)
    }
    static func keys(p256dh: String, auth: String) -> Bool {
        let keyText = p256dh.replacingOccurrences(of: "=", with: ""), authText = auth.replacingOccurrences(of: "=", with: "")
        guard OAuthText.isBase64URL(keyText, count: 87...87), OAuthText.isBase64URL(authText, count: 22...22),
              let key = Data(base64URL: keyText), key.count == 65, key.first == 4,
              (try? P256.KeyAgreement.PublicKey(x963Representation: key)) != nil,
              let secret = Data(base64URL: authText), secret.count == 16 else { return false }
        return true
    }
}
