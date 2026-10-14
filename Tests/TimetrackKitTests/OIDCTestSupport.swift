import Foundation
import Fluent
import XCTVapor
import Crypto
import _CryptoExtras
@testable import TimetrackKit

struct FakeIdentity: Sendable {
    enum Signer: Sendable { case rsa, rsaRotated, ec, hmac, none }
    var sub = "sub-alice"
    var email: String? = "alice@example.test"
    var signer: Signer = .rsa
    var claims: @Sendable (inout [String: Any]) -> Void = { _ in }
    var header: @Sendable (inout [String: Any]) -> Void = { _ in }
    /// Replace the payload after signing (signature no longer matches).
    var tamperSub: String?
}

/// In-process OpenID provider on a loopback port: discovery, JWKS and a token endpoint with PKCE verification.
final class FakeOIDCProvider: @unchecked Sendable {
    static let clientID = "timetrack-test"
    static let rsaKey = try! _RSA.Signing.PrivateKey(keySize: .bits2048)
    static let rotatedRSAKey = try! _RSA.Signing.PrivateKey(keySize: .bits2048)
    static let ecKey = P256.Signing.PrivateKey()

    struct Pending { let challenge: String; let nonce: String; let redirectURI: String; let identity: FakeIdentity }

    let app: Application
    private let lock = NSLock()
    private var _codes: [String: Pending] = [:]
    private var _discoveryCount = 0, _jwksCount = 0
    private var _tokenForms: [[String: String]] = []
    private var _tokenAuthorization: [String?] = []
    private var _publishRotated = false
    private var _issuerInDiscovery: String?
    private var _failToken = false
    private var _pkceFailures = 0

    var discoveryCount: Int { lock.withLock { _discoveryCount } }
    var jwksCount: Int { lock.withLock { _jwksCount } }
    var tokenForms: [[String: String]] { lock.withLock { _tokenForms } }
    var tokenAuthorization: [String?] { lock.withLock { _tokenAuthorization } }
    var pkceFailures: Int { lock.withLock { _pkceFailures } }
    var publishRotated: Bool { get { lock.withLock { _publishRotated } } set { lock.withLock { _publishRotated = newValue } } }
    var issuerInDiscovery: String? { get { lock.withLock { _issuerInDiscovery } } set { lock.withLock { _issuerInDiscovery = newValue } } }
    var failToken: Bool { get { lock.withLock { _failToken } } set { lock.withLock { _failToken = newValue } } }

    static func start() async throws -> FakeOIDCProvider {
        let app = try await Application.make(.testing)
        app.logger.logLevel = .critical
        let provider = FakeOIDCProvider(app: app)
        provider.routes()  // routes must exist before the responder is built at start
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        guard let port = app.http.server.shared.localAddress?.port else { throw Abort(.internalServerError) }
        provider.setIssuer("http://127.0.0.1:\(port)")
        return provider
    }
    private init(app: Application) { self.app = app }
    private var _issuer = ""
    var issuer: String { lock.withLock { _issuer } }
    private func setIssuer(_ value: String) { lock.withLock { _issuer = value } }
    func stop() async { await app.server.shutdown(); try? await app.asyncShutdown() }

    private func json(_ object: Any, status: HTTPResponseStatus = .ok) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        var headers = HTTPHeaders(); headers.contentType = .json
        return Response(status: status, headers: headers, body: .init(data: data))
    }

    private func routes() {
        app.get(".well-known", "openid-configuration") { [self] _ in
            lock.withLock { _discoveryCount += 1 }
            return json(["issuer": issuerInDiscovery ?? issuer, "authorization_endpoint": issuer + "/authorize", "token_endpoint": issuer + "/token",
                         "jwks_uri": issuer + "/jwks", "code_challenge_methods_supported": ["S256"], "response_types_supported": ["code"],
                         "id_token_signing_alg_values_supported": ["RS256", "ES256"], "token_endpoint_auth_methods_supported": ["client_secret_basic", "none"]])
        }
        app.get("jwks") { [self] _ in
            lock.withLock { _jwksCount += 1 }
            var keys: [[String: Any]] = []
            let rsa = publishRotated ? Self.rotatedRSAKey : Self.rsaKey
            let kid = publishRotated ? "rsa-2" : "rsa-1"
            if let p = try? rsa.publicKey.getKeyPrimitives() {
                keys.append(["kty": "RSA", "use": "sig", "alg": "RS256", "kid": kid, "n": p.modulus.base64URL, "e": p.publicExponent.base64URL])
            }
            let raw = Self.ecKey.publicKey.rawRepresentation
            keys.append(["kty": "EC", "crv": "P-256", "use": "sig", "kid": "ec-1", "x": raw.prefix(32).base64URL, "y": raw.suffix(32).base64URL])
            return json(["keys": keys])
        }
        app.post("token") { [self] req async throws -> Response in
            let form = try req.content.decode([String: String].self)
            let authorization = req.headers.first(name: .authorization)
            lock.withLock { _tokenForms.append(form); _tokenAuthorization.append(authorization) }
            if failToken { return json(["error": "server_error"], status: .internalServerError) }
            guard form["grant_type"] == "authorization_code", let code = form["code"], let pending = lock.withLock({ _codes.removeValue(forKey: code) }),
                  form["redirect_uri"] == pending.redirectURI else { return json(["error": "invalid_grant"], status: .badRequest) }
            guard let verifier = form["code_verifier"], Data(SHA256.hash(data: Data(verifier.utf8))).base64URL == pending.challenge else {
                lock.withLock { _pkceFailures += 1 }
                return json(["error": "invalid_grant"], status: .badRequest)
            }
            return json(["access_token": "at-secret-value", "token_type": "Bearer", "expires_in": 300, "id_token": try mint(pending)])
        }
    }

    /// Simulates the user approving the request: returns the callback path+query the browser is redirected to.
    func authorize(_ authorizationURL: String, as identity: FakeIdentity = FakeIdentity()) throws -> (path: String, code: String, state: String) {
        let parts = try XCTUnwrap(URLComponents(string: authorizationURL))
        func item(_ name: String) -> String? { parts.queryItems?.first { $0.name == name }?.value }
        let code = "code-" + Secrets.token(bytes: 12)
        lock.withLock {
            _codes[code] = Pending(challenge: item("code_challenge") ?? "", nonce: item("nonce") ?? "", redirectURI: item("redirect_uri") ?? "", identity: identity)
        }
        let state = try XCTUnwrap(item("state"))
        return ("/api/v1/auth/oidc/callback?code=\(code)&state=\(state)", code, state)
    }

    private func b64(_ data: Data) -> String { data.base64URL }

    private func mint(_ pending: Pending) throws -> String {
        let id = pending.identity
        let now = Date().timeIntervalSince1970
        var claims: [String: Any] = ["iss": issuer, "sub": id.sub, "aud": Self.clientID, "exp": now + 300, "iat": now, "nonce": pending.nonce]
        if let email = id.email { claims["email"] = email; claims["email_verified"] = true }
        id.claims(&claims)
        var header: [String: Any]
        switch id.signer {
        case .rsa: header = ["alg": "RS256", "kid": "rsa-1", "typ": "JWT"]
        case .rsaRotated: header = ["alg": "RS256", "kid": "rsa-2", "typ": "JWT"]
        case .ec: header = ["alg": "ES256", "kid": "ec-1", "typ": "JWT"]
        case .hmac: header = ["alg": "HS256", "kid": "rsa-1"]
        case .none: header = ["alg": "none"]
        }
        id.header(&header)
        let head = b64(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        var body = b64(try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
        let input = Data((head + "." + body).utf8)
        let signature: Data
        switch id.signer {
        case .rsa: signature = try Self.rsaKey.signature(for: input, padding: .insecurePKCS1v1_5).rawRepresentation
        case .rsaRotated: signature = try Self.rotatedRSAKey.signature(for: input, padding: .insecurePKCS1v1_5).rawRepresentation
        case .ec: signature = try Self.ecKey.signature(for: input).rawRepresentation
        case .hmac: signature = Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: Data("shared".utf8))))
        case .none: signature = Data()
        }
        if let sub = id.tamperSub {
            claims["sub"] = sub
            body = b64(try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
        }
        return head + "." + body + "." + b64(signature)
    }
}

/// Minimal cookie-jar browser against the backend under test.
final class TestBrowser: @unchecked Sendable {
    var oidcCookie: String?
    var sessionToken: String?
    var csrf: String?
    var locations: [String] = []

    struct Callback { let status: HTTPStatus; let location: String; let sessionCookie: String? }

    func headers(csrf useCSRF: Bool = false) -> HTTPHeaders {
        var cookies: [String] = []
        if let oidcCookie { cookies.append("tt_oidc=\(oidcCookie)") }
        if let sessionToken { cookies.append("tt_session=\(sessionToken)") }
        var result = HTTPHeaders()
        if !cookies.isEmpty { result.add(name: .cookie, value: cookies.joined(separator: "; ")) }
        if useCSRF, let csrf { result.add(name: "X-CSRF-Token", value: csrf) }
        return result
    }

    func use(_ context: AuthContext) { sessionToken = context.token; csrf = Secrets.csrf(context.token) }

    /// POST /auth/oidc/start; returns status and authorization URL or error code.
    func start(_ app: Application, purpose: String, inviteToken: String? = nil) async throws -> (status: HTTPStatus, url: String?, error: String?) {
        var result: (HTTPStatus, String?, String?) = (.internalServerError, nil, nil)
        var body: [String: String] = ["purpose": purpose]
        if let inviteToken { body["inviteToken"] = inviteToken }
        try await app.test(.POST, "/api/v1/auth/oidc/start", headers: headers(csrf: true), beforeRequest: { try $0.content.encode(body, as: .json) }, afterResponse: { res async throws in
            if res.status == .ok {
                if let cookie = res.headers.setCookie?["tt_oidc"]?.string { self.oidcCookie = cookie }
                result = (res.status, try res.content.decode([String: String].self)["authorizationUrl"], nil)
            } else {
                result = (res.status, nil, try? res.content.decode([String: [String: String]].self)["error"]?["code"])
            }
        })
        return result
    }

    func callback(_ app: Application, path: String) async throws -> Callback {
        var out = Callback(status: .internalServerError, location: "", sessionCookie: nil)
        try await app.test(.GET, path, headers: headers(), afterResponse: { res async throws in
            let location = res.headers.first(name: .location) ?? ""
            self.locations.append(location)
            if let cookie = res.headers.setCookie?["tt_session"], !cookie.string.isEmpty { self.sessionToken = cookie.string; self.csrf = Secrets.csrf(cookie.string) }
            out = Callback(status: res.status, location: location, sessionCookie: res.headers.setCookie?["tt_session"]?.string)
        })
        return out
    }

    /// Start + provider approval + callback in one go.
    func run(_ app: Application, provider: FakeOIDCProvider, purpose: String, inviteToken: String? = nil, as identity: FakeIdentity = FakeIdentity()) async throws -> Callback {
        let started = try await start(app, purpose: purpose, inviteToken: inviteToken)
        XCTAssertEqual(started.status, .ok, "start failed: \(started.error ?? "-")")
        let approved = try provider.authorize(try XCTUnwrap(started.url), as: identity)
        return try await callback(app, path: approved.path)
    }
}

class OIDCTestCase: XCTestCase, @unchecked Sendable {
    func withOIDC(secret: String? = nil, extra: [String: String] = [:], refetchGap: TimeInterval = 0,
                  _ run: (Application, AuthService, FakeOIDCProvider) async throws -> Void) async throws {
        let provider = try await FakeOIDCProvider.start()
        OIDCClient.defaultRefetchGap = refetchGap
        let app = try await Application.make(.testing)
        app.logger.logLevel = .critical
        var env = ["SQLITE_PATH": ":memory:", "OIDC_ISSUER": provider.issuer, "OIDC_CLIENT_ID": FakeOIDCProvider.clientID, "OIDC_NAME": "Test IdP"]
        if let secret { env["OIDC_CLIENT_SECRET"] = secret }
        let config = try Configuration(environment: env.merging(extra) { _, new in new })
        do {
            try await configure(app, configuration: config)
            try await app.autoMigrate()
            try await run(app, AuthService(configuration: config, mailSender: nil), provider)
            try await app.autoRevert()
        } catch { try await app.asyncShutdown(); await provider.stop(); OIDCClient.defaultRefetchGap = 30; throw error }
        try await app.asyncShutdown()
        await provider.stop()
        OIDCClient.defaultRefetchGap = 30
    }

    /// Account without passkey plus a session (optionally aged).
    func makeAccount(_ service: AuthService, _ db: any Database, handle: String, role: AccountRole = .member, email: String? = nil,
                     sessionAge: TimeInterval = 0) async throws -> AuthContext {
        let account = Account(handle: handle, displayName: handle.capitalized, email: email, role: role, createdAt: Date())
        try await account.create(on: db)
        let context = try await service.issueSession(for: account, on: db)
        if sessionAge > 0 {
            try await Session.query(on: db).filter(\.$id == context.session.requireID()).set(\.$createdAt, to: Date().addingTimeInterval(-sessionAge)).update()
        }
        return try await service.authenticate(context.token, on: db)
    }

    func browser(_ context: AuthContext? = nil) -> TestBrowser { let b = TestBrowser(); if let context { b.use(context) }; return b }

    func link(_ app: Application, _ provider: FakeOIDCProvider, _ context: AuthContext, as identity: FakeIdentity = FakeIdentity()) async throws -> TestBrowser.Callback {
        try await browser(context).run(app, provider: provider, purpose: "link", as: identity)
    }

    func invitation(_ service: AuthService, _ db: any Database, admin: AuthContext) async throws -> InvitationDTO {
        try await service.createInvitation(.init(), context: admin, on: db)
    }

    func same<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(lhs, rhs, file: file, line: line) }
    func errorCode(_ location: String) -> String? {
        URLComponents(string: "http://x" + location)?.queryItems?.first { $0.name == "oidc_error" }?.value
    }
    func expect(_ code: String, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(code)", file: file, line: line) }
        catch let error as APIError { XCTAssertEqual(error.code, code, file: file, line: line) }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }
}
