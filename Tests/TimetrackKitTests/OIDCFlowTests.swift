import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

final class OIDCFlowTests: OIDCTestCase, @unchecked Sendable {
    // MARK: configuration

    func testConfigurationValidation() throws {
        XCTAssertNil(try Configuration(environment: [:]).oidc)
        let ok = try XCTUnwrap(Configuration(environment: ["OIDC_ISSUER": "https://id.example.test/realm", "OIDC_CLIENT_ID": "app"]).oidc)
        XCTAssertEqual(ok.name, "OpenID Connect"); XCTAssertEqual(ok.scopes, ["openid", "email", "profile"]); XCTAssertNil(ok.clientSecret)
        let loop = try XCTUnwrap(Configuration(environment: ["OIDC_ISSUER": "http://localhost:15556/dex", "OIDC_CLIENT_ID": "app", "OIDC_CLIENT_SECRET": "s", "OIDC_NAME": "Dex", "OIDC_SCOPES": "openid email"]).oidc)
        XCTAssertEqual(loop.clientSecret, "s"); XCTAssertEqual(loop.name, "Dex"); XCTAssertEqual(loop.scopes, ["openid", "email"])
        for bad in ["http://id.example.test", "ftp://id.example.test", "https://u:p@id.example.test", "https://id.example.test/?x=1", "https://id.example.test/#f", "not a url"] {
            XCTAssertThrowsError(try Configuration(environment: ["OIDC_ISSUER": bad, "OIDC_CLIENT_ID": "app"]), bad)
        }
        XCTAssertThrowsError(try Configuration(environment: ["OIDC_ISSUER": "https://id.example.test"]))
        XCTAssertThrowsError(try Configuration(environment: ["OIDC_CLIENT_ID": "app"]))
        XCTAssertThrowsError(try Configuration(environment: ["OIDC_ISSUER": "https://id.example.test", "OIDC_CLIENT_ID": "app", "OIDC_SCOPES": "email"]))
    }

    func testDisabledPerContract() async throws {
        let app = try await Application.make(.testing)
        app.logger.logLevel = .critical
        let config = try Configuration(environment: ["SQLITE_PATH": ":memory:"])
        try await configure(app, configuration: config)
        try await app.autoMigrate()
        let service = AuthService(configuration: config, mailSender: nil)
        let context = try await makeAccount(service, app.db, handle: "solo")
        let b = browser(context)
        try await app.test(.GET, "/api/v1/auth/oidc/config") { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(try res.content.decode([String: Bool?].self)["enabled"], false)
        }
        let started = try await b.start(app, purpose: "login")
        XCTAssertEqual(started.status, .notImplemented)
        let callback = try await b.callback(app, path: "/api/v1/auth/oidc/callback?code=x&state=y")
        XCTAssertEqual(callback.status, .found); XCTAssertEqual(callback.location, "/login?oidc_error=oidc_failed")
        try await app.test(.GET, "/api/v1/me/identities", headers: b.headers()) { res async throws in
            XCTAssertEqual(res.status, .ok); XCTAssertEqual(try res.content.decode([ExternalIdentityDTO].self).count, 0)
        }
        try await app.test(.POST, "/api/v1/auth/oidc/register", headers: b.headers(csrf: true), beforeRequest: {
            try $0.content.encode(["pendingId": UUID().uuidString, "handle": "abc", "displayName": "A"], as: .json)
        }, afterResponse: { res async throws in XCTAssertEqual(res.status, .notImplemented) })
        try await app.autoRevert(); try await app.asyncShutdown()
    }

    func testConfigEndpointWhenEnabled() async throws {
        try await withOIDC { app, _, _ in
            try await app.test(.GET, "/api/v1/auth/oidc/config") { res async throws in
                XCTAssertEqual(res.status, .ok)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any])
                XCTAssertEqual(json["enabled"] as? Bool, true); XCTAssertEqual(json["name"] as? String, "Test IdP")
            }
        }
    }

    // MARK: login / link

    func testLinkThenLogoutThenLogin() async throws {
        try await withOIDC { app, service, provider in
            let context = try await makeAccount(service, app.db, handle: "alice")
            let linked = try await link(app, provider, context)
            XCTAssertEqual(linked.status, .found); XCTAssertEqual(linked.location, "/settings/identities?linked=1")
            let rows = try await ExternalIdentity.query(on: app.db).all()
            XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].subject, "sub-alice"); XCTAssertEqual(rows[0].issuer, provider.issuer); XCTAssertEqual(rows[0].accountId, context.account.id)
            // Fresh browser (logged out) logs in with the linked identity.
            let b = browser()
            let login = try await b.run(app, provider: provider, purpose: "login")
            XCTAssertEqual(login.status, .found); XCTAssertEqual(login.location, "/")
            let cookie = try XCTUnwrap(login.sessionCookie)
            try await app.test(.GET, "/api/v1/auth/session", headers: ["Cookie": "tt_session=\(cookie)"]) { res async throws in
                XCTAssertEqual(res.status, .ok); XCTAssertEqual(try res.content.decode(SessionDTO.self).account.handle, "alice")
            }
            let after = try await ExternalIdentity.query(on: app.db).first()
            XCTAssertNotNil(after?.lastUsedAt)
            // GET me/identities shows provider name and hint.
            try await app.test(.GET, "/api/v1/me/identities", headers: b.headers()) { res async throws in
                let list = try res.content.decode([ExternalIdentityDTO].self)
                XCTAssertEqual(list.count, 1); XCTAssertEqual(list[0].providerName, "Test IdP"); XCTAssertEqual(list[0].emailHint, "alice@example.test")
            }
            // PKCE: the provider verified S256 and the client id was sent for the public client; no secret.
            XCTAssertEqual(provider.pkceFailures, 0)
            for form in provider.tokenForms { XCTAssertEqual(form["client_id"], FakeOIDCProvider.clientID); XCTAssertNotNil(form["code_verifier"]); XCTAssertNil(form["client_secret"]) }
            XCTAssertEqual(provider.tokenAuthorization.compactMap { $0 }.count, 0)
        }
    }

    func testSessionCookieFlagsAndStateStoredHashed() async throws {
        try await withOIDC { app, service, provider in
            let context = try await makeAccount(service, app.db, handle: "alice")
            _ = try await link(app, provider, context)
            let b = browser()
            let started = try await b.start(app, purpose: "login")
            let url = try XCTUnwrap(started.url)
            let state = try XCTUnwrap(URLComponents(string: url)?.queryItems?.first { $0.name == "state" }?.value)
            let rows = try await OIDCState.query(on: app.db).all()
            XCTAssertEqual(rows.count, 2)
            XCTAssertFalse(rows.contains { $0.stateHash == state }); XCTAssertTrue(rows.contains { $0.stateHash == Secrets.hash(state) })
            XCTAssertEqual(URLComponents(string: url)?.queryItems?.first { $0.name == "code_challenge_method" }?.value, "S256")
            let approved = try provider.authorize(url)
            try await app.test(.GET, approved.path, headers: b.headers()) { res async throws in
                XCTAssertEqual(res.status, .found)
                let raw = try XCTUnwrap(res.headers[.setCookie].first { $0.hasPrefix("tt_session=") })
                XCTAssertTrue(raw.contains("HttpOnly")); XCTAssertTrue(raw.contains("SameSite=Lax"))
                XCTAssertEqual(res.headers.first(name: "Referrer-Policy"), "no-referrer")
            }
            // Secrets are wiped once the state is consumed.
            let consumed = try await OIDCState.query(on: app.db).filter(\.$stateHash == Secrets.hash(state)).first()
            XCTAssertEqual(consumed?.codeVerifier, ""); XCTAssertNotNil(consumed?.consumedAt)
        }
    }

    func testUnknownIdentityIsNotLinkedAndCreatesNothing() async throws {
        try await withOIDC { app, service, provider in
            _ = try await makeAccount(service, app.db, handle: "alice", email: "alice@example.test")
            let accountsBefore = try await Account.query(on: app.db).count()
            let result = try await browser().run(app, provider: provider, purpose: "login", as: FakeIdentity(sub: "stranger"))
            XCTAssertEqual(result.location, "/login?oidc_error=oidc_not_linked"); XCTAssertNil(result.sessionCookie)
            let accountsAfter = try await Account.query(on: app.db).count(), identities = try await ExternalIdentity.query(on: app.db).count()
            XCTAssertEqual(accountsAfter, accountsBefore); XCTAssertEqual(identities, 0)
            let sessions = try await Session.query(on: app.db).count()
            XCTAssertEqual(sessions, 1)
        }
    }

    func testEmailNeverLinksOrLogsIn() async throws {
        try await withOIDC { app, service, provider in
            let a = try await makeAccount(service, app.db, handle: "alice", email: "alice@example.test")
            _ = try await makeAccount(service, app.db, handle: "alice2", email: "alice@example.test")
            let linked = try await link(app, provider, a, as: FakeIdentity(sub: "sub-1"))
            XCTAssertEqual(linked.location, "/settings/identities?linked=1")
            // Another subject with the identical (verified) e-mail does not get in and is not linked.
            let other = try await browser().run(app, provider: provider, purpose: "login", as: FakeIdentity(sub: "sub-2", email: "alice@example.test"))
            XCTAssertEqual(errorCode(other.location), "oidc_not_linked"); XCTAssertNil(other.sessionCookie)
            let identities = try await ExternalIdentity.query(on: app.db).all()
            XCTAssertEqual(identities.count, 1); XCTAssertEqual(identities[0].subject, "sub-1")
            // The e-mail claim of an existing identity changing does not redirect it to another account either.
            let again = try await browser().run(app, provider: provider, purpose: "login", as: FakeIdentity(sub: "sub-1", email: "someone-else@example.test"))
            XCTAssertEqual(again.location, "/")
            let who = try await Session.query(on: app.db).sort(\.$createdAt, .descending).first()
            XCTAssertEqual(who?.accountId, a.account.id)
        }
    }

    func testDisabledAccountCannotLogIn() async throws {
        try await withOIDC { app, service, provider in
            let context = try await makeAccount(service, app.db, handle: "alice")
            _ = try await link(app, provider, context)
            try await Account.query(on: app.db).filter(\.$id == context.account.requireID()).set(\.$disabledAt, to: Date()).update()
            let sessionsBefore = try await Session.query(on: app.db).count()
            let result = try await browser().run(app, provider: provider, purpose: "login")
            XCTAssertEqual(errorCode(result.location), "oidc_failed"); XCTAssertNil(result.sessionCookie)
            let sessionsAfter = try await Session.query(on: app.db).count()
            XCTAssertEqual(sessionsAfter, sessionsBefore)
        }
    }

    func testLinkRequiresFreshAuthenticatedSession() async throws {
        try await withOIDC { app, service, provider in
            // Start: no session -> 401, stale session -> 403 reauth_required.
            let anonymous = try await browser().start(app, purpose: "link")
            XCTAssertEqual(anonymous.status, .unauthorized)
            let stale = try await makeAccount(service, app.db, handle: "stale", sessionAge: 1200)
            let rejected = try await browser(stale).start(app, purpose: "link")
            XCTAssertEqual(rejected.status, .forbidden); XCTAssertEqual(rejected.error, "reauth_required")
            // Callback: session ages out between start and callback.
            let fresh = try await makeAccount(service, app.db, handle: "fresh")
            let b = browser(fresh)
            let started = try await b.start(app, purpose: "link")
            try await Session.query(on: app.db).filter(\.$id == fresh.session.requireID()).set(\.$createdAt, to: Date().addingTimeInterval(-1200)).update()
            let result = try await b.callback(app, path: provider.authorize(try XCTUnwrap(started.url)).path)
            XCTAssertEqual(result.location, "/settings/identities?oidc_error=oidc_reauth_required")
            // Callback without any session cookie, and with another account's session.
            let c = browser(try await makeAccount(service, app.db, handle: "carol"))
            let s2 = try await c.start(app, purpose: "link")
            c.sessionToken = nil
            let r2 = try await c.callback(app, path: provider.authorize(try XCTUnwrap(s2.url)).path)
            XCTAssertEqual(r2.location, "/settings/identities?oidc_error=oidc_reauth_required")
            let d = browser(try await makeAccount(service, app.db, handle: "dave"))
            let s3 = try await d.start(app, purpose: "link")
            d.use(try await makeAccount(service, app.db, handle: "erin"))
            let r3 = try await d.callback(app, path: provider.authorize(try XCTUnwrap(s3.url)).path)
            XCTAssertEqual(r3.location, "/settings/identities?oidc_error=oidc_reauth_required")
            let count = try await ExternalIdentity.query(on: app.db).count()
            XCTAssertEqual(count, 0)
        }
    }

    func testIdentityAlreadyLinkedElsewhereIsRefused() async throws {
        try await withOIDC { app, service, provider in
            let a = try await makeAccount(service, app.db, handle: "alice")
            let b = try await makeAccount(service, app.db, handle: "bob")
            same(try await link(app, provider, a).location, "/settings/identities?linked=1")
            let refused = try await link(app, provider, b)
            XCTAssertEqual(refused.location, "/settings/identities?oidc_error=oidc_identity_taken")
            let rows = try await ExternalIdentity.query(on: app.db).all()
            XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].accountId, a.account.id)
            // Linking the same identity again to the same account is idempotent.
            same(try await link(app, provider, a).location, "/settings/identities?linked=1")
            let again = try await ExternalIdentity.query(on: app.db).count()
            XCTAssertEqual(again, 1)
        }
    }

    func testClientSecretUsesBasicAuthentication() async throws {
        try await withOIDC(secret: "s3cret value") { app, service, provider in
            let context = try await makeAccount(service, app.db, handle: "alice")
            same(try await link(app, provider, context).location, "/settings/identities?linked=1")
            let header = try XCTUnwrap(provider.tokenAuthorization.first ?? nil)
            XCTAssertEqual(header, "Basic " + Data("\(FakeOIDCProvider.clientID):s3cret%20value".utf8).base64EncodedString())
            XCTAssertNil(provider.tokenForms.first?["client_secret"]); XCTAssertNil(provider.tokenForms.first?["client_id"])
        }
    }

    // MARK: state

    func testStateReuseExpiryAndBinding() async throws {
        try await withOIDC { app, service, provider in
            let context = try await makeAccount(service, app.db, handle: "alice")
            _ = try await link(app, provider, context)
            // Reuse.
            let b = browser()
            let started = try await b.start(app, purpose: "login")
            let approved = try provider.authorize(try XCTUnwrap(started.url))
            same(try await b.callback(app, path: approved.path).location, "/")
            same(try await browser().callback(app, path: approved.path).location, "/login?oidc_error=oidc_state_invalid")
            let replay = browser(); replay.oidcCookie = b.oidcCookie
            same(try await replay.callback(app, path: approved.path).location, "/login?oidc_error=oidc_state_invalid")
            // Expired.
            let b2 = browser()
            let s2 = try await b2.start(app, purpose: "login")
            let a2 = try provider.authorize(try XCTUnwrap(s2.url))
            try await OIDCState.query(on: app.db).filter(\.$stateHash == Secrets.hash(a2.state)).set(\.$expiresAt, to: Date().addingTimeInterval(-1)).update()
            same(try await b2.callback(app, path: a2.path).location, "/login?oidc_error=oidc_state_invalid")
            // Unknown state / missing parameters.
            same(try await browser().callback(app, path: "/api/v1/auth/oidc/callback?code=c&state=nope").location, "/login?oidc_error=oidc_state_invalid")
            same(try await browser().callback(app, path: "/api/v1/auth/oidc/callback").location, "/login?oidc_error=oidc_state_invalid")
            // Missing or foreign binding cookie (login CSRF): fails and the state is burned.
            let b3 = browser()
            let s3 = try await b3.start(app, purpose: "login")
            let a3 = try provider.authorize(try XCTUnwrap(s3.url))
            let attacker = browser()
            let r3 = try await attacker.callback(app, path: a3.path)
            XCTAssertEqual(r3.location, "/login?oidc_error=oidc_state_invalid"); XCTAssertNil(r3.sessionCookie)
            same(try await b3.callback(app, path: a3.path).location, "/login?oidc_error=oidc_state_invalid")
            // Provider error.
            let b4 = browser()
            let s4 = try await b4.start(app, purpose: "login")
            let state4 = try XCTUnwrap(URLComponents(string: try XCTUnwrap(s4.url))?.queryItems?.first { $0.name == "state" }?.value)
            same(try await b4.callback(app, path: "/api/v1/auth/oidc/callback?error=access_denied&state=\(state4)").location, "/login?oidc_error=oidc_failed")
        }
    }

    func testProviderFailuresAndDiscoveryIssuerMismatch() async throws {
        try await withOIDC { app, service, provider in
            let context = try await makeAccount(service, app.db, handle: "alice")
            provider.failToken = true
            let failed = try await link(app, provider, context)
            XCTAssertEqual(failed.location, "/settings/identities?oidc_error=oidc_failed")
            provider.failToken = false
        }
        try await withOIDC { app, _, provider in
            provider.issuerInDiscovery = "http://127.0.0.1:1/other"
            let started = try await browser().start(app, purpose: "login")
            XCTAssertEqual(started.status, .badGateway); XCTAssertEqual(started.error, "oidc_unavailable")
        }
    }

    // MARK: rate limit

    func testRateLimiting() async throws {
        try await withOIDC { app, _, _ in
            var last = ""
            for _ in 0..<61 { last = try await browser().callback(app, path: "/api/v1/auth/oidc/callback?state=x").location }
            XCTAssertEqual(last, "/login?oidc_error=oidc_failed")
        }
        try await withOIDC { app, _, _ in
            var statuses: [HTTPStatus] = []
            for _ in 0..<61 { statuses.append(try await browser().start(app, purpose: "login").status) }
            XCTAssertEqual(statuses.last, .tooManyRequests); XCTAssertEqual(statuses.first, .ok)
        }
    }
}
