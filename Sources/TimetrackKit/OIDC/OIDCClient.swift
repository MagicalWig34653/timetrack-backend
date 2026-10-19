import Vapor
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import Crypto

struct OIDCDiscovery: Sendable {
    let issuer: String
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let jwksURI: String
    let tokenAuthMethods: [String]
}

/// Talks to the provider: discovery, JWKS and the code exchange. Tokens are never logged or stored.
actor OIDCClient {
    static let discoveryTTL: TimeInterval = 3600
    static let jwksTTL: TimeInterval = 3600
    /// Minimum gap between JWKS refetches triggered by unknown key IDs.
    private let refetchGap: TimeInterval
    /// Test hook for the default gap (production keeps 30 s).
    nonisolated(unsafe) static var defaultRefetchGap: TimeInterval = 30

    private let configuration: OIDCConfiguration
    private let http: HTTPClient
    private var discovery: (value: OIDCDiscovery, fetchedAt: Date)?
    private var jwks: (keys: [OIDCJWK], fetchedAt: Date)?
    private var lastJWKSFetch: Date = .distantPast

    init(configuration: OIDCConfiguration, group: any EventLoopGroup, refetchGap: TimeInterval = OIDCClient.defaultRefetchGap) {
        self.configuration = configuration
        self.refetchGap = refetchGap
        var client = HTTPClient.Configuration(redirectConfiguration: .disallow, timeout: .init(connect: .seconds(5), read: .seconds(10)))
        client.decompression = .disabled
        http = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: client)
    }

    func shutdown() async { try? await http.shutdown() }

    // MARK: HTTP

    private func fetch(_ url: String, method: HTTPMethod = .GET, headers: HTTPHeaders = HTTPHeaders(), body: String? = nil, limit: Int) async throws -> Data {
        var request = HTTPClientRequest(url: url)
        request.method = method
        request.headers = headers
        request.headers.replaceOrAdd(name: "Accept", value: "application/json")
        if let body { request.body = .bytes(ByteBuffer(string: body)) }
        // Transport failures of this outbound call must never reach `InfrastructureError` as raw NIO errors (they would be
        // reported as "database unavailable", Q1 finding 4).
        let response: HTTPClientResponse
        do { response = try await http.execute(request, timeout: .seconds(10)) }
        catch { throw OIDCClientError.network }
        guard response.status == .ok else {
            // Drain a bounded amount so the connection can be released; the body is never inspected or logged.
            _ = try? await response.body.collect(upTo: 4096)
            throw OIDCClientError.status
        }
        if let length = response.headers.first(name: "Content-Length").flatMap(Int.init), length > limit { throw OIDCClientError.tooLarge }
        do {
            var buffer = try await response.body.collect(upTo: limit)
            return buffer.readData(length: buffer.readableBytes) ?? Data()
        } catch is NIOTooManyBytesError { throw OIDCClientError.tooLarge }
        catch { throw OIDCClientError.network }
    }

    private func json(_ data: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw OIDCClientError.invalidDocument }
        return object
    }

    // MARK: Discovery

    func discover(now: Date = Date()) async throws -> OIDCDiscovery {
        if let cached = discovery, now.timeIntervalSince(cached.fetchedAt) < Self.discoveryTTL { return cached.value }
        let base = configuration.issuer.hasSuffix("/") ? String(configuration.issuer.dropLast()) : configuration.issuer
        let object = try json(try await fetch(base + "/.well-known/openid-configuration", limit: 256 * 1024))
        // The document must name exactly the configured issuer (mix-up protection).
        guard object["issuer"] as? String == configuration.issuer else { throw OIDCClientError.issuerMismatch }
        func endpoint(_ key: String) throws -> String {
            guard let value = object[key] as? String, OIDCConfiguration.isAllowedEndpoint(value, allowQuery: true) else { throw OIDCClientError.invalidDocument }
            return value
        }
        if let methods = object["code_challenge_methods_supported"] as? [String], !methods.contains("S256") { throw OIDCClientError.invalidDocument }
        let value = OIDCDiscovery(issuer: configuration.issuer, authorizationEndpoint: try endpoint("authorization_endpoint"),
                                  tokenEndpoint: try endpoint("token_endpoint"), jwksURI: try endpoint("jwks_uri"),
                                  tokenAuthMethods: object["token_endpoint_auth_methods_supported"] as? [String] ?? [])
        discovery = (value, now)
        return value
    }

    // MARK: Code exchange

    /// Returns the raw id_token only. access_token and refresh_token are ignored and dropped.
    func exchange(code: String, verifier: String, redirectURI: String) async throws -> String {
        let doc = try await discover()
        var form: [(String, String)] = [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI), ("code_verifier", verifier)]
        var headers: HTTPHeaders = ["Content-Type": "application/x-www-form-urlencoded"]
        if let secret = configuration.clientSecret {
            // client_secret_basic is the RFC default; use _post only if the provider supports nothing else.
            if !doc.tokenAuthMethods.isEmpty, !doc.tokenAuthMethods.contains("client_secret_basic"), doc.tokenAuthMethods.contains("client_secret_post") {
                form += [("client_id", configuration.clientID), ("client_secret", secret)]
            } else {
                let credentials = Self.formEncode(configuration.clientID) + ":" + Self.formEncode(secret)
                headers.add(name: "Authorization", value: "Basic " + Data(credentials.utf8).base64EncodedString())
            }
        } else {
            form.append(("client_id", configuration.clientID))
        }
        let body = form.map { Self.formEncode($0.0) + "=" + Self.formEncode($0.1) }.joined(separator: "&")
        let object = try json(try await fetch(doc.tokenEndpoint, method: .POST, headers: headers, body: body, limit: 256 * 1024))
        guard let idToken = object["id_token"] as? String else { throw OIDCClientError.invalidDocument }
        return idToken
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    // MARK: Verification

    /// Verifies the signature and all claims of an id_token against the provider's keys.
    func verify(idToken: String, nonce: String, now: Date = Date()) async throws -> OIDCIdentityClaims {
        let token = try OIDCParsedToken(idToken)
        let doc = try await discover()
        var keys = try await keySet(now: now)
        var candidates = Self.candidates(keys, for: token)
        if candidates.isEmpty {
            // Unknown kid: the provider may have rotated keys. Refetch, rate limited.
            keys = try await keySet(now: now, forceRefresh: true)
            candidates = Self.candidates(keys, for: token)
        }
        guard !candidates.isEmpty else { throw OIDCTokenError.unknownKey }
        guard candidates.contains(where: { $0.verify(signature: token.signature, signingInput: token.signingInput) }) else { throw OIDCTokenError.badSignature }
        return try OIDCClaimValidator.validate(token.claims, issuer: doc.issuer, clientID: configuration.clientID, nonce: nonce, now: now)
    }

    private static func candidates(_ keys: [OIDCJWK], for token: OIDCParsedToken) -> [OIDCJWK] {
        keys.filter { key in
            guard key.algorithm == token.algorithm, key.alg == nil || key.alg == token.algorithm else { return false }
            if let kid = token.kid { return key.kid == kid }
            return key.kid == nil || keys.filter { $0.algorithm == token.algorithm }.count == 1
        }
    }

    private func keySet(now: Date, forceRefresh: Bool = false) async throws -> [OIDCJWK] {
        if let cached = jwks, now.timeIntervalSince(cached.fetchedAt) < Self.jwksTTL, !forceRefresh { return cached.keys }
        if forceRefresh, now.timeIntervalSince(lastJWKSFetch) < refetchGap, let cached = jwks { return cached.keys }
        let doc = try await discover()
        lastJWKSFetch = now
        let object = try json(try await fetch(doc.jwksURI, limit: 512 * 1024))
        guard let list = object["keys"] as? [[String: Any]] else { throw OIDCClientError.invalidDocument }
        let keys = list.prefix(32).compactMap(OIDCJWK.init(json:))
        jwks = (keys, now)
        return keys
    }
}

enum OIDCClientError: Error, Sendable { case status, tooLarge, invalidDocument, issuerMismatch, network }
