import Foundation
import Crypto
import NIOCore
import Vapor
import Fluent

/// AWS Signature Version 4 (header based). Pure functions, verified against the published AWS test suite.
enum SigV4 {
    static let algorithm = "AWS4-HMAC-SHA256"

    static func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }
    static func signingKey(secret: String, date: String, region: String, service: String) -> Data {
        let dateKey = hmac(Data(("AWS4" + secret).utf8), date)
        return hmac(hmac(hmac(dateKey, region), service), "aws4_request")
    }

    /// RFC 3986 unreserved set; `/` kept when encoding a path.
    static func encode(_ value: String, keepSlash: Bool) -> String {
        var out = ""
        for byte in value.utf8 {
            let unreserved = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E
            if unreserved { out.append(Character(UnicodeScalar(byte))) }
            else if byte == 0x2F && keepSlash { out.append("/") }
            else { out += String(format: "%%%02X", byte) }
        }
        return out
    }

    struct Signed: Equatable {
        var canonicalRequest: String
        var stringToSign: String
        var signature: String
        var authorization: String
    }

    /// `path` must already be URI-encoded; header names are lowercased and values trimmed here.
    static func sign(method: String, path: String, query: [(String, String)], headers: [(String, String)], payloadHash: String,
                     amzDate: String, region: String, service: String, accessKeyId: String, secret: String) -> Signed {
        var pairs: [(String, String)] = []
        for item in query { pairs.append((encode(item.0, keepSlash: false), encode(item.1, keepSlash: false))) }
        pairs.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        let canonicalQuery: String = pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let normalized = headers.map { ($0.0.lowercased(), $0.1.trimmingCharacters(in: .whitespaces)) }.sorted { $0.0 < $1.0 }
        let canonicalHeaders = normalized.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = normalized.map(\.0).joined(separator: ";")
        let canonical = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let day = String(amzDate.prefix(8))
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = [algorithm, amzDate, scope, sha256Hex(Data(canonical.utf8))].joined(separator: "\n")
        let key = signingKey(secret: secret, date: day, region: region, service: service)
        let signature = hex(hmac(key, toSign))
        return .init(canonicalRequest: canonical, stringToSign: toSign, signature: signature,
                     authorization: "\(algorithm) Credential=\(accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)")
    }

    static func amzDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }
}

struct S3Configuration: Sendable, Equatable {
    var endpoint: String
    var region: String
    var bucket: String
    var pathStyle: Bool
    var accessKeyId: String
    var secretAccessKey: String
}

/// Minimal S3 client (PUT/GET/DELETE/HEAD object). Credentials are never logged or included in errors.
struct S3Client: Sendable {
    let configuration: S3Configuration
    let client: any Client
    var timeout: TimeAmount = .seconds(30)
    var now: @Sendable () -> Date = { Date() }

    struct Prepared: Equatable {
        var url: String
        var headers: [(String, String)]   // everything that is sent, including Authorization
        static func == (lhs: Prepared, rhs: Prepared) -> Bool { lhs.url == rhs.url && lhs.headers.elementsEqual(rhs.headers) { $0 == $1 } }
    }

    /// Builds URL and signed headers. `Host` is derived from the URL exactly as the HTTP client sends it.
    func prepare(method: String, key: String, payload: Data) throws -> Prepared {
        guard let base = URLComponents(string: configuration.endpoint), let scheme = base.scheme, ["http", "https"].contains(scheme),
              let host = base.host, !host.isEmpty else { throw StorageBackendError(detail: "invalid S3 endpoint") }
        let encodedKey = SigV4.encode(key, keepSlash: true)
        let hostHeader: String
        let authority: String
        let port = base.port.flatMap { ($0 == 80 && scheme == "http") || ($0 == 443 && scheme == "https") ? nil : $0 }
        let hostPart = configuration.pathStyle ? host : "\(configuration.bucket).\(host)"
        authority = port.map { "\(hostPart):\($0)" } ?? hostPart
        hostHeader = authority
        let basePath = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
        let path = configuration.pathStyle ? "\(basePath)/\(SigV4.encode(configuration.bucket, keepSlash: false))/\(encodedKey)" : "\(basePath)/\(encodedKey)"
        let date = SigV4.amzDate(now())
        let payloadHash = SigV4.sha256Hex(payload)
        var signedHeaders = [("host", hostHeader), ("x-amz-content-sha256", payloadHash), ("x-amz-date", date)]
        let signed = SigV4.sign(method: method, path: path, query: [], headers: signedHeaders, payloadHash: payloadHash, amzDate: date,
                                region: configuration.region, service: "s3", accessKeyId: configuration.accessKeyId, secret: configuration.secretAccessKey)
        signedHeaders.removeAll { $0.0 == "host" }
        signedHeaders.append(("authorization", signed.authorization))
        return .init(url: "\(scheme)://\(authority)\(path)", headers: signedHeaders)
    }

    private func send(method: HTTPMethod, key: String, payload: Data = Data(), extra: [(String, String)] = []) async throws -> ClientResponse {
        let prepared = try prepare(method: method.rawValue, key: key, payload: payload)
        var headers = HTTPHeaders()
        for (name, value) in prepared.headers + extra { headers.replaceOrAdd(name: name, value: value) }
        var request = ClientRequest(method: method, url: URI(string: prepared.url), headers: headers, body: nil, timeout: timeout)
        if !payload.isEmpty { request.body = ByteBuffer(data: payload) }
        do { return try await client.send(request) }
        catch { throw StorageBackendError(detail: "S3 request failed") }   // no details: URLs and headers stay out of logs
    }

    func put(key: String, data: Data, contentType: String = "application/octet-stream") async throws {
        let response = try await send(method: .PUT, key: key, payload: data, extra: [("content-type", contentType)])
        guard (200..<300).contains(Int(response.status.code)) else { throw StorageBackendError(detail: "S3 PUT status \(response.status.code)") }
    }
    func get(key: String) async throws -> Data {
        let response = try await send(method: .GET, key: key)
        guard response.status == .ok, var body = response.body else { throw StorageBackendError(detail: "S3 GET status \(response.status.code)") }
        return body.readData(length: body.readableBytes) ?? Data()
    }
    func delete(key: String) async throws {
        let response = try await send(method: .DELETE, key: key)
        guard (200..<300).contains(Int(response.status.code)) || response.status == .notFound else { throw StorageBackendError(detail: "S3 DELETE status \(response.status.code)") }
    }
    func head(key: String) async throws -> Int? {
        let response = try await send(method: .HEAD, key: key)
        if response.status == .notFound { return nil }
        guard response.status == .ok else { throw StorageBackendError(detail: "S3 HEAD status \(response.status.code)") }
        return response.headers.first(name: .contentLength).flatMap(Int.init)
    }
}

struct S3Backend: StorageBackend {
    let kind = StorageBackendKind.s3
    let client: S3Client
    func put(key: String, data: Data, db: any Database) async throws { try await client.put(key: key, data: data) }
    func get(key: String, db: any Database) async throws -> Data { try await client.get(key: key) }
    func delete(key: String, db: any Database) async throws { try await client.delete(key: key) }
}
