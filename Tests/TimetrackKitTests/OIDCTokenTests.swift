import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

final class OIDCTokenTests: OIDCTestCase, @unchecked Sendable {
    /// Every rejected token must end in oidc_token_invalid with no session, identity or account change.
    private func assertRejected(_ name: String, identity: FakeIdentity, app: Application, service: AuthService, provider: FakeOIDCProvider,
                                purpose: String = "login", file: StaticString = #filePath, line: UInt = #line) async throws {
        let sessions = try await Session.query(on: app.db).count(), accounts = try await Account.query(on: app.db).count()
        let identities = try await ExternalIdentity.query(on: app.db).count()
        let result = try await browser().run(app, provider: provider, purpose: purpose, as: identity)
        XCTAssertEqual(errorCode(result.location), "oidc_token_invalid", name, file: file, line: line)
        XCTAssertNil(result.sessionCookie, name, file: file, line: line)
        let sessionsAfter = try await Session.query(on: app.db).count(), accountsAfter = try await Account.query(on: app.db).count()
        let identitiesAfter = try await ExternalIdentity.query(on: app.db).count()
        XCTAssertEqual(sessionsAfter, sessions, name, file: file, line: line)
        XCTAssertEqual(accountsAfter, accounts, name, file: file, line: line)
        XCTAssertEqual(identitiesAfter, identities, name, file: file, line: line)
    }

    func testInvalidTokensAreRejected() async throws {
        try await withOIDC { app, service, provider in
            let context = try await makeAccount(service, app.db, handle: "alice")
            same(try await link(app, provider, context).location, "/settings/identities?linked=1")
            let now = Date().timeIntervalSince1970
            let cases: [(String, FakeIdentity)] = [
                ("nonce mismatch", FakeIdentity(claims: { $0["nonce"] = "other" })),
                ("missing nonce", FakeIdentity(claims: { $0["nonce"] = nil })),
                ("wrong audience", FakeIdentity(claims: { $0["aud"] = "someone-else" })),
                ("audience list without ours", FakeIdentity(claims: { $0["aud"] = ["a", "b"] })),
                ("multiple audiences without azp", FakeIdentity(claims: { $0["aud"] = [FakeOIDCProvider.clientID, "b"] })),
                ("azp mismatch", FakeIdentity(claims: { $0["aud"] = [FakeOIDCProvider.clientID, "b"]; $0["azp"] = "b" })),
                ("wrong issuer", FakeIdentity(claims: { $0["iss"] = "http://evil.example" })),
                ("missing issuer", FakeIdentity(claims: { $0["iss"] = nil })),
                ("expired", FakeIdentity(claims: { $0["exp"] = now - 3600 })),
                ("expired beyond leeway", FakeIdentity(claims: { $0["exp"] = now - 120 })),
                ("missing exp", FakeIdentity(claims: { $0["exp"] = nil })),
                ("iat in the future", FakeIdentity(claims: { $0["iat"] = now + 3600 })),
                ("nbf in the future", FakeIdentity(claims: { $0["nbf"] = now + 3600 })),
                ("missing sub", FakeIdentity(claims: { $0["sub"] = nil })),
                ("empty sub", FakeIdentity(claims: { $0["sub"] = "" })),
                ("alg none", FakeIdentity(signer: .none)),
                ("alg HS256", FakeIdentity(signer: .hmac)),
                ("tampered payload", FakeIdentity(tamperSub: "sub-evil")),
                ("unknown kid", FakeIdentity(header: { $0["kid"] = "nope" })),
                ("RS256 header over EC signature", FakeIdentity(signer: .ec, header: { $0["alg"] = "RS256" })),
                ("embedded jwk header", FakeIdentity(header: { $0["jwk"] = ["kty": "RSA"] })),
                ("signed by rotated key not in JWKS", FakeIdentity(signer: .rsaRotated)),
            ]
            for (name, identity) in cases { try await assertRejected(name, identity: identity, app: app, service: service, provider: provider) }
            // An invalid token in the link flow must not create an identity either.
            try await assertRejected("link with bad token", identity: FakeIdentity(sub: "sub-x", claims: { $0["aud"] = "x" }), app: app, service: service, provider: provider, purpose: "login")
        }
    }

    func testAcceptableTokenVariants() async throws {
        try await withOIDC { app, service, provider in
            let context = try await makeAccount(service, app.db, handle: "alice")
            same(try await link(app, provider, context, as: FakeIdentity(sub: "sub-ec", signer: .ec)).location, "/settings/identities?linked=1")
            let now = Date().timeIntervalSince1970
            // ES256, expired within the 60 s leeway, audience list with matching azp, integer dates.
            let ec = try await browser().run(app, provider: provider, purpose: "login", as: FakeIdentity(sub: "sub-ec", signer: .ec, claims: { $0["exp"] = Int(now) - 30; $0["iat"] = Int(now) - 400 }))
            XCTAssertEqual(ec.location, "/")
            let list = try await browser().run(app, provider: provider, purpose: "login", as: FakeIdentity(sub: "sub-ec", signer: .ec, claims: { $0["aud"] = [FakeOIDCProvider.clientID, "x"]; $0["azp"] = FakeOIDCProvider.clientID; $0["nbf"] = now + 30 }))
            XCTAssertEqual(list.location, "/")
            // Same subject through RS256 is a different token but the same identity.
            let rsa = try await browser().run(app, provider: provider, purpose: "login", as: FakeIdentity(sub: "sub-ec"))
            XCTAssertEqual(rsa.location, "/")
        }
    }

    func testKeyRotationRefetchesJWKS() async throws {
        try await withOIDC(refetchGap: 0) { app, service, provider in
            let context = try await makeAccount(service, app.db, handle: "alice")
            same(try await link(app, provider, context).location, "/settings/identities?linked=1")
            XCTAssertEqual(provider.jwksCount, 1)
            XCTAssertEqual(provider.discoveryCount, 1)  // cached across start and callback
            provider.publishRotated = true
            let rotated = try await browser().run(app, provider: provider, purpose: "login", as: FakeIdentity(signer: .rsaRotated))
            XCTAssertEqual(rotated.location, "/")
            XCTAssertEqual(provider.jwksCount, 2)
            // Cached now: no further fetch for the known key.
            _ = try await browser().run(app, provider: provider, purpose: "login", as: FakeIdentity(signer: .rsaRotated))
            XCTAssertEqual(provider.jwksCount, 2)
        }
    }

    func testUnknownKidRefetchIsRateLimited() async throws {
        try await withOIDC(refetchGap: 3600) { app, service, provider in
            let context = try await makeAccount(service, app.db, handle: "alice")
            same(try await link(app, provider, context).location, "/settings/identities?linked=1")
            provider.publishRotated = true
            for _ in 0..<3 {
                let result = try await browser().run(app, provider: provider, purpose: "login", as: FakeIdentity(signer: .rsaRotated))
                XCTAssertEqual(errorCode(result.location), "oidc_token_invalid")
            }
            XCTAssertEqual(provider.jwksCount, 1, "attackers must not be able to force JWKS refetches")
        }
    }

    func testNoSecretsInRedirectsOrLogs() async throws {
        let sink = LogSink()
        try await withOIDC { app, service, provider in
            app.logger = Logger(label: "oidc-test", factory: { _ in sink })
            app.logger.logLevel = .trace
            let context = try await makeAccount(service, app.db, handle: "alice")
            let b = browser(context)
            let started = try await b.start(app, purpose: "link")
            let approved = try provider.authorize(try XCTUnwrap(started.url))
            let callback = try await b.callback(app, path: approved.path)
            XCTAssertEqual(callback.location, "/settings/identities?linked=1")
            let login = try await browser().run(app, provider: provider, purpose: "login")
            // A bad token goes through the failure path too.
            let bad = try await browser().run(app, provider: provider, purpose: "login", as: FakeIdentity(claims: { $0["aud"] = "x" }))
            let invite = try await invitation(service, app.db, admin: try await makeAccount(service, app.db, handle: "admin", role: .admin))
            let reg = browser()
            let registered = try await reg.run(app, provider: provider, purpose: "register", inviteToken: invite.token, as: FakeIdentity(sub: "new"))
            for location in b.locations + [login.location, bad.location, registered.location] {
                XCTAssertFalse(location.contains(approved.code), location); XCTAssertFalse(location.contains(approved.state), location)
                XCTAssertFalse(location.contains("eyJ"), "no JWT in redirects"); XCTAssertFalse(location.contains("at-secret-value"))
            }
            let all = sink.messages.joined(separator: "\n")
            for secret in [approved.code, approved.state, "at-secret-value", "eyJ", context.token] {
                XCTAssertFalse(all.contains(secret), "log leaks \(secret.prefix(6))")
            }
        }
    }
}

final class LogSink: LogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String] = []
    var messages: [String] { lock.withLock { store } }
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? { get { metadata[key] } set { metadata[key] = newValue } }
    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        let extra = (self.metadata.merging(metadata ?? [:]) { _, new in new }).map { "\($0)=\($1)" }.joined(separator: " ")
        lock.withLock { store.append("\(message) \(extra)") }
    }
}
