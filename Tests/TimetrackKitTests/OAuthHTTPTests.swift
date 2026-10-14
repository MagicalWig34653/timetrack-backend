import Foundation
import Fluent
import XCTVapor
import Crypto
@testable import TimetrackKit

// C16: OAuth authorization server, grants and personal tokens. Each scenario runs on SQLite and (gated on MARIADB_TEST_HOST) on MariaDB.

extension AuthTests {
    func scenarioOAuthMetadata(_ app: Application, _ auth: AuthService) async throws {
        for path in ["/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"] {
            let response = try await oaSend(app, .GET, path)
            try await eq(response.status, .ok)
            let body = oaJSON(response)
            try await eq(body["resource"] as? String, "http://localhost:18080/mcp")
            try await eq(body["authorization_servers"] as? [String], ["http://localhost:18080"])
            try await eq(Set(body["scopes_supported"] as? [String] ?? []), Set(McpScopes.all)); try await eq(McpScopes.all.count, 7)
            try await eq(body["bearer_methods_supported"] as? [String], ["header"])
            try await eq(response.headers.first(name: .cacheControl), "no-store")
        }
        let meta = oaJSON(try await oaSend(app, .GET, "/.well-known/oauth-authorization-server"))
        try await eq(meta["issuer"] as? String, "http://localhost:18080")
        try await eq(meta["authorization_endpoint"] as? String, "http://localhost:18080/oauth/authorize")
        try await eq(meta["token_endpoint"] as? String, "http://localhost:18080/oauth/token")
        try await eq(meta["registration_endpoint"] as? String, "http://localhost:18080/oauth/register")
        try await eq(meta["revocation_endpoint"] as? String, "http://localhost:18080/oauth/revoke")
        try await eq(meta["code_challenge_methods_supported"] as? [String], ["S256"])
        try await eq(meta["token_endpoint_auth_methods_supported"] as? [String], ["none"])
        try await eq(Set(meta["grant_types_supported"] as? [String] ?? []), ["authorization_code", "refresh_token"])
        try await eq(meta["response_types_supported"] as? [String], ["code"])
        // CORS preflight for browser-based clients.
        let preflight = try await oaSend(app, .OPTIONS, "/oauth/token")
        try await eq(preflight.status, .noContent); try await eq(preflight.headers.first(name: .accessControlAllowOrigin), "*")
    }

    func scenarioOAuthMetadataFollowsPublicBaseURL(_ app: Application, _ auth: AuthService) async throws {
        let meta = oaJSON(try await oaSend(app, .GET, "/.well-known/oauth-authorization-server"))
        try await eq(meta["issuer"] as? String, "https://time.example.test")
        try await eq(oaJSON(try await oaSend(app, .GET, "/.well-known/oauth-protected-resource"))["resource"] as? String, "https://time.example.test/mcp")
    }

    func scenarioOAuthRegistration(_ app: Application, _ auth: AuthService) async throws {
        let id = try await oaRegister(app, name: "  My\u{0007} <b>Client</b>\n  Name ")
        let client = try oaUnwrap(try await OAuthClient.find(UUID(uuidString: id), on: app.db))
        try await eq(client.name, "My bClient/b Name")
        // Response shape.
        let ok = try await oaSend(app, .POST, "/oauth/register", headers: ["Content-Type": "application/json"],
                                  body: ByteBuffer(data: JSONSerialization.data(withJSONObject: ["redirect_uris": ["http://127.0.0.1:8123/cb", "http://localhost/cb", "http://[::1]:9/cb", "https://a.example/x?y=1"]])))
        try await eq(ok.status, .created)
        let body = oaJSON(ok)
        try await eq(body["token_endpoint_auth_method"] as? String, "none"); try await eq(body["client_name"] as? String, "127.0.0.1")
        XCTAssertNil(body["client_secret"]); try await eq(ok.headers.first(name: .cacheControl), "no-store")
        // Invalid redirect URIs.
        try await RateLimitEvent.query(on: app.db).delete()   // the matrix below exceeds the per-peer budget
        let bad = ["http://client.example/cb", "ftp://client.example/cb", "https://client.example/cb#frag", "https://*.example/cb", "https://client.example/*",
                   "https://user:pw@client.example/cb", "javascript:alert(1)", "myapp://cb", "/relative", "", "https://client.example/ cb", "https://",
                   "http://localhost.evil.example/cb", "https://" + String(repeating: "a", count: 2100)]
        for uri in bad { try await oaRegister(app, redirects: [uri], status: .badRequest) }
        try await oaRegister(app, redirects: [], status: .badRequest)
        try await RateLimitEvent.query(on: app.db).delete()
        try await oaRegister(app, redirects: (1...6).map { "https://c\($0).example/cb" }, status: .badRequest)
        try await oaRegister(app, redirects: (1...5).map { "https://c\($0).example/cb" })
        // Confidential or unsupported metadata is refused.
        try await oaRegister(app, status: .badRequest, extra: ["token_endpoint_auth_method": "client_secret_basic"])
        try await oaRegister(app, status: .badRequest, extra: ["grant_types": ["password"]])
        try await oaRegister(app, status: .badRequest, extra: ["grant_types": ["authorization_code", "implicit"]])
        try await oaRegister(app, status: .badRequest, extra: ["response_types": ["token"]])
        try await RateLimitEvent.query(on: app.db).delete()
        try await oaRegister(app, name: String(repeating: "n", count: 101), status: .badRequest)
        try await oaRegister(app, name: String(repeating: "n", count: 100))
        let missing = try await oaSend(app, .POST, "/oauth/register", headers: ["Content-Type": "application/json"], body: ByteBuffer(string: "{}"))
        try await eq(missing.status, .badRequest); try await eq(oaJSON(missing)["error"] as? String, "invalid_redirect_uri")
        let garbage = try await oaSend(app, .POST, "/oauth/register", headers: ["Content-Type": "application/json"], body: ByteBuffer(string: "[1"))
        try await eq(garbage.status, .badRequest)
        // Per-peer rate limit (20 per 5 minutes); the counter is separate from login limits.
        try await RateLimitEvent.query(on: app.db).delete()
        var limited = false
        for _ in 0..<25 { if try await oaSend(app, .POST, "/oauth/register", headers: ["Content-Type": "application/json"],
            body: ByteBuffer(string: #"{"redirect_uris":["https://r.example/cb"]}"#)).status == .tooManyRequests { limited = true; break } }
        XCTAssertTrue(limited)
    }

    func scenarioOAuthFullFlow(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        let client = try await oaRegister(app)
        let started = try await oaStart(app, context, client: client, scope: "time:read reports:read", state: "abc 123&x=y")
        try await eq(started.location, "http://localhost:18080/oauth/consent?request=" + started.id)
        // Consent data: client name, redirect host and requested scopes only.
        let consent = try await oaSend(app, .GET, "/api/v1/oauth/requests/\(started.id)", headers: headers(context))
        try await eq(consent.status, .ok); try await eq(consent.headers.first(name: .cacheControl), "no-store")
        let data = oaJSON(consent)
        try await eq(data["clientName"] as? String, "Test Client"); try await eq(data["redirectHost"] as? String, "client.example")
        try await eq(data["scopes"] as? [String], ["time:read", "reports:read"]); XCTAssertNotNil(data["expiresAt"])
        let decision = try await oaDecision(app, context, started.id, approve: true)
        try await eq(decision.status, .ok)
        let url = try XCTUnwrap(oaJSON(decision)["redirectUrl"] as? String)
        XCTAssertTrue(url.hasPrefix(Self.oaRedirect + "?"))
        let query = oaQuery(url)
        try await eq(query["state"], "abc 123&x=y"); try await eq(query["iss"], "http://localhost:18080")
        let code = try XCTUnwrap(query["code"]); try await eq(code.count, 43)
        try await eq(Set(query.keys), ["code", "state", "iss"])
        try await isNil(try await OAuthCode.query(on: app.db).filter(\.$codeHash == code).first())
        // Exchange.
        let flow = OAuthFlow(client: client, redirect: Self.oaRedirect, verifier: started.verifier, challenge: started.challenge, requestId: started.id, code: code, state: "x", location: url)
        let tokens = try await oaToken(app, oaCodeForm(flow, resource: Self.oaResource))
        try await eq(tokens.status, .ok)
        try await eq(tokens.response.headers.first(name: .cacheControl), "no-store"); try await eq(tokens.response.headers.first(name: .pragma), "no-cache")
        try await eq(tokens.json["token_type"] as? String, "Bearer"); try await eq(tokens.json["expires_in"] as? Int, 3600)
        try await eq(tokens.json["scope"] as? String, "time:read reports:read")
        let access = try XCTUnwrap(tokens.json["access_token"] as? String), refresh = try XCTUnwrap(tokens.json["refresh_token"] as? String)
        XCTAssertTrue(access.hasPrefix("tto_")); try await eq(access.count, 47); XCTAssertTrue(refresh.hasPrefix("ttr_"))
        // Only hashes are stored.
        for secret in [access, refresh, code] {
            let hits = try await OAuthToken.query(on: app.db).filter(\.$tokenHash == secret).count() + OAuthCode.query(on: app.db).filter(\.$codeHash == secret).count()
            try await eq(hits, 0)
        }
        let stored = try await OAuthToken.query(on: app.db).all()
        try await eq(Set(stored.map(\.tokenHash)), [Secrets.hash(access), Secrets.hash(refresh)])
        let access1 = try XCTUnwrap(stored.first { $0.kind == "access" }), refresh1 = try XCTUnwrap(stored.first { $0.kind == "refresh" })
        try await eq(access1.expiresAt.timeIntervalSince(access1.createdAt), 3600); try await eq(refresh1.expiresAt.timeIntervalSince(refresh1.createdAt), 30 * 86400)
        // The bearer works for MCP, scoped to the grant; and is the grant credential.
        let principal = try oaUnwrap(try await authenticateMcpBearer(access, on: app.db))
        let accountID = try context.account.requireID(), grantID = try oaUnwrap(try await OAuthGrant.query(on: app.db).first()).requireID()
        try await eq(principal.accountId, accountID); try await eq(principal.scopes, ["time:read", "reports:read"])
        try await eq(principal.credentialKind, .oauthAccess)
        try await eq(principal.credentialId, grantID)
        // Grant listing shows it.
        let grants = try list(await api(app, context, .GET, "me/oauth-grants"))
        try await eq(grants.count, 1); try await eq(grants[0]["clientName"] as? String, "Test Client"); try await eq(grants[0]["scopes"] as? [String], ["time:read", "reports:read"])
        XCTAssertNotNil(grants[0]["lastUsedAt"] as? String)
        // Access/refresh tokens are not session credentials for the REST API.
        let rest = try await oaSend(app, .GET, "/api/v1/auth/session", headers: ["Authorization": "Bearer " + access])
        try await eq(rest.status, .unauthorized)
        // Client usage is recorded.
        let used = try await OAuthClient.find(UUID(uuidString: client), on: app.db)?.lastUsedAt
        XCTAssertNotNil(used)
    }

    func scenarioOAuthCodeBinding(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        let client = try await oaRegister(app, redirects: [Self.oaRedirect, "https://client.example/other"])
        let other = try await oaRegister(app, name: "Other")
        func fresh() async throws -> OAuthFlow { try await oaFlow(app, context, client: client) }
        // Wrong verifier burns the code.
        var flow = try await fresh()
        var result = try await oaToken(app, oaCodeForm(flow, verifier: Secrets.token(bytes: 32)))
        try await eq(result.status, .badRequest); try await eq(oaOAuthError(result), "invalid_grant")
        result = try await oaToken(app, oaCodeForm(flow)); try await eq(oaOAuthError(result), "invalid_grant")
        // Wrong redirect_uri (even another registered one), wrong client, malformed verifier.
        flow = try await fresh()
        try await eq(oaOAuthError(try await oaToken(app, oaCodeForm(flow, redirect: "https://client.example/other"))), "invalid_grant")
        flow = try await fresh()
        try await eq(oaOAuthError(try await oaToken(app, oaCodeForm(flow, client: other))), "invalid_grant")
        flow = try await fresh()
        try await eq(oaOAuthError(try await oaToken(app, oaCodeForm(flow, verifier: "short"))), "invalid_grant")
        // Wrong resource.
        flow = try await fresh()
        result = try await oaToken(app, oaCodeForm(flow, resource: "http://localhost:18080/other"))
        try await eq(result.status, .badRequest); try await eq(oaOAuthError(result), "invalid_target")
        // Missing parameters and unknown client / grant type.
        flow = try await fresh()
        var form = oaCodeForm(flow); form.removeValue(forKey: "code_verifier")
        try await eq(oaOAuthError(try await oaToken(app, form)), "invalid_request")
        form = oaCodeForm(flow); form.removeValue(forKey: "redirect_uri")
        try await eq(oaOAuthError(try await oaToken(app, form)), "invalid_request")
        try await eq(oaOAuthError(try await oaToken(app, oaCodeForm(flow, client: UUID().uuidString))), "invalid_client")
        try await eq(oaOAuthError(try await oaToken(app, ["grant_type": "password", "client_id": client])), "unsupported_grant_type")
        try await eq(oaOAuthError(try await oaToken(app, ["client_id": client])), "unsupported_grant_type")
        let empty = try await oaSend(app, .POST, "/oauth/token", headers: ["Content-Type": "application/x-www-form-urlencoded"])
        try await eq(empty.status, .badRequest); try await eq(oaJSON(empty)["error"] as? String, "invalid_request")
        // Expired code.
        flow = try await fresh()
        let record = try oaUnwrap(try await OAuthCode.query(on: app.db).filter(\.$codeHash == Secrets.hash(flow.code)).first())
        try await eq(record.expiresAt.timeIntervalSince(record.createdAt), 60)
        record.expiresAt = Date().addingTimeInterval(-1); try await record.update(on: app.db)
        try await eq(oaOAuthError(try await oaToken(app, oaCodeForm(flow))), "invalid_grant")
        // None of the failures produced a token.
        try await eq(try await OAuthToken.query(on: app.db).count(), 0)
        // Happy path still works afterwards.
        flow = try await fresh(); _ = try await oaExchange(app, flow)
    }

    func scenarioOAuthCodeReuse(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        let client = try await oaRegister(app)
        let flow = try await oaFlow(app, context, client: client)
        let first = try await oaExchange(app, flow)
        try await notNil(try await authenticateMcpBearer(first.access, on: app.db))
        // Reusing the code is refused and revokes everything issued from it.
        let again = try await oaToken(app, oaCodeForm(flow))
        try await eq(again.status, .badRequest); try await eq(oaOAuthError(again), "invalid_grant")
        try await isNil(try await authenticateMcpBearer(first.access, on: app.db))
        let refreshed = try await oaToken(app, ["grant_type": "refresh_token", "refresh_token": first.refresh, "client_id": client])
        try await eq(oaOAuthError(refreshed), "invalid_grant")
        try await eq(try list(await api(app, context, .GET, "me/oauth-grants")).count, 0)
    }

    func scenarioOAuthParallelExchange(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        let client = try await oaRegister(app)
        let flow = try await oaFlow(app, context, client: client)
        let form = oaCodeForm(flow)
        let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group -> [HTTPStatus] in
            for _ in 0..<8 { group.addTask { try await self.oaToken(app, form).status } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        try await eq(statuses.filter { $0 == .ok }.count, 1)
        try await eq(statuses.filter { $0 == .badRequest }.count, 7)
        // Exactly one access/refresh pair was ever created, even though the loser revoked the grant afterwards.
        try await eq(try await OAuthToken.query(on: app.db).count(), 2)
    }

    func scenarioOAuthRefresh(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        let client = try await oaRegister(app)
        let flow = try await oaFlow(app, context, client: client, scope: "time:read time:write reports:read")
        let first = try await oaExchange(app, flow)
        func refresh(_ token: String, scope: String? = nil, client id: String? = nil) async throws -> (status: HTTPStatus, json: [String: Any], response: XCTHTTPResponse) {
            var form = ["grant_type": "refresh_token", "refresh_token": token, "client_id": id ?? client]
            if let scope { form["scope"] = scope }
            return try await oaToken(app, form)
        }
        // Another client cannot use the token.
        let stranger = try await oaRegister(app, name: "Stranger")
        try await eq(oaOAuthError(try await refresh(first.refresh, client: stranger)), "invalid_grant")
        // Rotation.
        let second = try await refresh(first.refresh)
        try await eq(second.status, .ok); try await eq(second.json["scope"] as? String, "reports:read time:read time:write")
        let access2 = try XCTUnwrap(second.json["access_token"] as? String), refresh2 = try XCTUnwrap(second.json["refresh_token"] as? String)
        XCTAssertNotEqual(access2, first.access); XCTAssertNotEqual(refresh2, first.refresh)
        let parent = try oaUnwrap(try await OAuthToken.query(on: app.db).filter(\.$tokenHash == Secrets.hash(refresh2)).first())
        let firstRefreshID = try oaUnwrap(try await OAuthToken.query(on: app.db).filter(\.$tokenHash == Secrets.hash(first.refresh)).first()).requireID()
        try await eq(parent.parentId, firstRefreshID)
        try await notNil(try await authenticateMcpBearer(access2, on: app.db))
        // Narrowing is allowed, widening is not.
        let narrowed = try await refresh(refresh2, scope: "time:read")
        try await eq(narrowed.status, .ok); try await eq(narrowed.json["scope"] as? String, "time:read")
        let refresh3 = try XCTUnwrap(narrowed.json["refresh_token"] as? String)
        try await eq(oaOAuthError(try await refresh(refresh3, scope: "time:read documents:read")), "invalid_scope")
        let narrowedPrincipal = try oaUnwrap(try await authenticateMcpBearer(narrowed.json["access_token"] as? String ?? "", on: app.db))
        try await eq(narrowedPrincipal.scopes, ["time:read"])
        // Resource parameter must match when given.
        try await eq(oaOAuthError(try await oaToken(app, ["grant_type": "refresh_token", "refresh_token": refresh3, "client_id": client, "resource": "http://x.example/mcp"])), "invalid_target")
        // Reuse of an already rotated token revokes the whole chain (also the newest tokens).
        let reuse = try await refresh(first.refresh)
        try await eq(reuse.status, .badRequest); try await eq(oaOAuthError(reuse), "invalid_grant")
        try await isNil(try await authenticateMcpBearer(access2, on: app.db))
        try await eq(oaOAuthError(try await refresh(refresh3)), "invalid_grant")
        try await eq(try await OAuthToken.query(on: app.db).filter(\.$revokedAt == nil).count(), 0)
        let grant = try oaUnwrap(try await OAuthGrant.query(on: app.db).first()); XCTAssertNotNil(grant.revokedAt)
        // Unknown, wrong-prefix and expired refresh tokens.
        try await eq(oaOAuthError(try await refresh("ttr_" + Secrets.token())), "invalid_grant")
        try await eq(oaOAuthError(try await refresh(first.access)), "invalid_grant")
        try await eq(oaOAuthError(try await oaToken(app, ["grant_type": "refresh_token", "client_id": client])), "invalid_request")
    }

    func scenarioOAuthRefreshExpiryAndParallel(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        let client = try await oaRegister(app)
        let first = try await oaExchange(app, try await oaFlow(app, context, client: client))
        let form = ["grant_type": "refresh_token", "refresh_token": first.refresh, "client_id": client]
        let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group -> [HTTPStatus] in
            for _ in 0..<6 { group.addTask { try await self.oaToken(app, form).status } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        try await eq(statuses.filter { $0 == .ok }.count, 1)
        // Expired refresh token is refused without touching the grant.
        let second = try await oaExchange(app, try await oaFlow(app, context, client: client))
        let record = try oaUnwrap(try await OAuthToken.query(on: app.db).filter(\.$tokenHash == Secrets.hash(second.refresh)).first())
        record.expiresAt = Date().addingTimeInterval(-5); try await record.update(on: app.db)
        try await eq(oaOAuthError(try await oaToken(app, ["grant_type": "refresh_token", "refresh_token": second.refresh, "client_id": client])), "invalid_grant")
        // Expired access token is not a principal.
        let access = try oaUnwrap(try await OAuthToken.query(on: app.db).filter(\.$tokenHash == Secrets.hash(second.access)).first())
        try await notNil(try await authenticateMcpBearer(second.access, on: app.db))
        try await isNil(try await authenticateMcpBearer(second.access, on: app.db, now: access.expiresAt.addingTimeInterval(1)))
    }

    func scenarioOAuthGrantRevocation(_ app: Application, _ auth: AuthService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let b = try await second(app, auth, a)
        let client = try await oaRegister(app)
        let tokensA = try await oaExchange(app, try await oaFlow(app, a, client: client))
        let tokensB = try await oaExchange(app, try await oaFlow(app, b, client: client))
        let listA = try list(await api(app, a, .GET, "me/oauth-grants")), listB = try list(await api(app, b, .GET, "me/oauth-grants"))
        try await eq(listA.count, 1); try await eq(listB.count, 1); XCTAssertNotEqual(listA[0]["id"] as? String, listB[0]["id"] as? String)
        let idA = try XCTUnwrap(listA[0]["id"] as? String)
        // Isolation: B cannot see or revoke A's grant.
        try await api(app, b, .DELETE, "me/oauth-grants/\(idA)", nil, .notFound)
        try await api(app, a, .DELETE, "me/oauth-grants/\(UUID().uuidString)", nil, .notFound)
        try await api(app, a, .DELETE, "me/oauth-grants/not-a-uuid", nil, .notFound)
        try await notNil(try await authenticateMcpBearer(tokensA.access, on: app.db))
        // CSRF is required.
        let noCSRF = try await oaSend(app, .DELETE, "/api/v1/me/oauth-grants/\(idA)", headers: headers(a, csrf: false))
        try await eq(noCSRF.status, .forbidden)
        // Revocation is immediate for access and refresh tokens, and only for that grant.
        try await api(app, a, .DELETE, "me/oauth-grants/\(idA)", nil, .noContent)
        try await isNil(try await authenticateMcpBearer(tokensA.access, on: app.db))
        try await eq(oaOAuthError(try await oaToken(app, ["grant_type": "refresh_token", "refresh_token": tokensA.refresh, "client_id": client])), "invalid_grant")
        try await notNil(try await authenticateMcpBearer(tokensB.access, on: app.db))
        try await eq(try list(await api(app, a, .GET, "me/oauth-grants")).count, 0)
        try await api(app, a, .DELETE, "me/oauth-grants/\(idA)", nil, .notFound)
        // A new authorization after revocation creates a fresh grant.
        _ = try await oaExchange(app, try await oaFlow(app, a, client: client))
        try await eq(try list(await api(app, a, .GET, "me/oauth-grants")).count, 1)
        try await eq(try await OAuthGrant.query(on: app.db).filter(\.$accountId == a.account.requireID()).count(), 2)
        // Re-consent for an active grant reuses it and replaces its scopes.
        _ = try await oaExchange(app, try await oaFlow(app, a, client: client, scope: "time:read"))
        let grants = try list(await api(app, a, .GET, "me/oauth-grants"))
        try await eq(grants.count, 1); try await eq(grants[0]["scopes"] as? [String], ["time:read"])
        // Disabling the account stops grant tokens.
        let fresh = try await oaExchange(app, try await oaFlow(app, b, client: client))
        try await notNil(try await authenticateMcpBearer(fresh.access, on: app.db))
        b.account.disabledAt = Date(); try await b.account.update(on: app.db)
        try await isNil(try await authenticateMcpBearer(fresh.access, on: app.db))
        try await eq(oaOAuthError(try await oaToken(app, ["grant_type": "refresh_token", "refresh_token": fresh.refresh, "client_id": client])), "invalid_grant")
    }

    func scenarioOAuthConsent(_ app: Application, _ auth: AuthService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let b = try await second(app, auth, a)
        let client = try await oaRegister(app)
        // Without a session the request is not readable.
        var started = try await oaStart(app, a, client: client, scope: "time:read time:write reports:read")
        try await eq(try await oaSend(app, .GET, "/api/v1/oauth/requests/\(started.id)").status, .unauthorized)
        // The first account to open it owns it; everybody else gets 404 (also B and A's other session).
        try await eq(try await oaSend(app, .GET, "/api/v1/oauth/requests/\(started.id)", headers: headers(a)).status, .ok)
        try await eq(try await oaSend(app, .GET, "/api/v1/oauth/requests/\(started.id)", headers: headers(b)).status, .notFound)
        try await eq(try await oaDecision(app, b, started.id, approve: true).status, .notFound)
        let otherSession = try await auth.issueSession(for: a.account, on: app.db)
        try await eq(try await oaSend(app, .GET, "/api/v1/oauth/requests/\(started.id)", headers: headers(otherSession)).status, .notFound)
        try await eq(try await oaDecision(app, otherSession, started.id, approve: true).status, .notFound)
        // Unknown or malformed ids.
        try await eq(try await oaSend(app, .GET, "/api/v1/oauth/requests/\(UUID().uuidString)", headers: headers(a)).status, .notFound)
        try await eq(try await oaSend(app, .GET, "/api/v1/oauth/requests/xyz", headers: headers(a)).status, .notFound)
        // CSRF is required for the decision and does not consume the request.
        let noCSRF = try await oaDecision(app, a, started.id, approve: true, csrf: false)
        try await eq(noCSRF.status, .forbidden); XCTAssertTrue(noCSRF.body.string.contains("csrf_invalid"))
        try await eq(try await OAuthGrant.query(on: app.db).count(), 0)
        // Scopes must be a non-empty subset of the requested ones; failures keep the request open.
        for scopes in [["documents:read"], ["time:read", "schedule:write"], [], ["bogus"], ["time:read", "admin"]] {
            try await eq(try await oaDecision(app, a, started.id, approve: true, scopes: scopes).status, .badRequest)
        }
        try await eq(try await OAuthGrant.query(on: app.db).count(), 0)
        let approved = try await oaDecision(app, a, started.id, approve: true, scopes: ["time:read", "reports:read", "time:read"])
        try await eq(approved.status, .ok)
        let grant = try oaUnwrap(try await OAuthGrant.query(on: app.db).first())
        try await eq(grant.scopes, ["time:read", "reports:read"])
        // A second decision conflicts; the consent data is gone.
        try await eq(try await oaDecision(app, a, started.id, approve: true).status, .conflict)
        try await eq(try await oaDecision(app, a, started.id, approve: false).status, .conflict)
        try await eq(try await oaSend(app, .GET, "/api/v1/oauth/requests/\(started.id)", headers: headers(a)).status, .notFound)
        let code = try XCTUnwrap(oaQuery(oaJSON(approved)["redirectUrl"] as? String)["code"])
        let flow = OAuthFlow(client: client, redirect: Self.oaRedirect, verifier: started.verifier, challenge: started.challenge, requestId: started.id, code: code, state: "", location: "")
        try await eq(try await oaExchange(app, flow).json["scope"] as? String, "time:read reports:read")
        // Deny: redirect with access_denied and the state, no grant, no code.
        started = try await oaStart(app, a, client: client, state: "keep-me")
        try await eq(try await oaSend(app, .GET, "/api/v1/oauth/requests/\(started.id)", headers: headers(a)).status, .ok)
        let denied = try await oaDecision(app, a, started.id, approve: false)
        try await eq(denied.status, .ok)
        let deniedQuery = oaQuery(oaJSON(denied)["redirectUrl"] as? String)
        try await eq(deniedQuery["error"], "access_denied"); try await eq(deniedQuery["state"], "keep-me"); XCTAssertNil(deniedQuery["code"])
        try await eq(try await OAuthCode.query(on: app.db).count(), 1)
        // Expired request.
        started = try await oaStart(app, a, client: client)
        let record = try oaUnwrap(try await OAuthRequestRecord.find(UUID(uuidString: started.id), on: app.db))
        try await eq(record.expiresAt.timeIntervalSince(record.createdAt), 600)
        record.expiresAt = Date().addingTimeInterval(-1); try await record.update(on: app.db)
        try await eq(try await oaSend(app, .GET, "/api/v1/oauth/requests/\(started.id)", headers: headers(a)).status, .notFound)
        try await eq(try await oaDecision(app, a, started.id, approve: true).status, .notFound)
        // Recovery sessions cannot authorize clients.
        let recovery = try await auth.issueSession(for: a.account, recovery: true, on: app.db)
        started = try await oaStart(app, a, client: client)
        try await eq(try await oaSend(app, .GET, "/api/v1/oauth/requests/\(started.id)", headers: headers(recovery)).status, .forbidden)
    }

    func scenarioOAuthAuthorizeValidation(_ app: Application, _ auth: AuthService) async throws {
        let client = try await oaRegister(app)
        let pkce = oaPKCE()
        func redirected(_ response: XCTHTTPResponse) -> [String: String] { oaQuery(response.headers.first(name: .location)) }
        // Before a valid client/redirect pair exists there is never a redirect.
        for (clientID, redirect) in [(UUID().uuidString, Self.oaRedirect), ("nonsense", Self.oaRedirect), (client, "https://evil.example/callback"),
                                     (client, Self.oaRedirect + "/"), (client, "https://client.example/callback?x=1"), (client, "")] {
            let response = try await oaAuthorize(app, client: clientID, redirect: redirect, challenge: pkce.challenge)
            try await eq(response.status, .badRequest); XCTAssertNil(response.headers.first(name: .location))
            XCTAssertNotNil(oaJSON(response)["error"] as? String)
        }
        let noClient = try await oaSend(app, .GET, "/oauth/authorize")
        try await eq(noClient.status, .badRequest); XCTAssertNil(noClient.headers.first(name: .location))
        let noRedirect = try await oaSend(app, .GET, "/oauth/authorize?client_id=\(client)")
        try await eq(noRedirect.status, .badRequest)
        // Afterwards errors are redirects carrying the state.
        let cases: [(String, XCTHTTPResponse)] = [
            ("unsupported_response_type", try await oaAuthorize(app, client: client, challenge: pkce.challenge, responseType: "token")),
            ("unsupported_response_type", try await oaAuthorize(app, client: client, challenge: pkce.challenge, responseType: nil)),
            ("invalid_request", try await oaAuthorize(app, client: client, challenge: nil)),
            ("invalid_request", try await oaAuthorize(app, client: client, challenge: pkce.challenge, method: nil)),
            ("invalid_request", try await oaAuthorize(app, client: client, challenge: pkce.challenge, method: "plain")),
            ("invalid_request", try await oaAuthorize(app, client: client, challenge: "tooshort")),
            ("invalid_request", try await oaAuthorize(app, client: client, challenge: pkce.challenge, state: String(repeating: "s", count: 513))),
            ("invalid_target", try await oaAuthorize(app, client: client, challenge: pkce.challenge, resource: nil)),
            ("invalid_target", try await oaAuthorize(app, client: client, challenge: pkce.challenge, resource: "http://localhost:18080/other")),
            ("invalid_target", try await oaAuthorize(app, client: client, challenge: pkce.challenge, resource: "http://localhost:18080/mcp/")),
            ("invalid_scope", try await oaAuthorize(app, client: client, challenge: pkce.challenge, scope: "time:read admin")),
            ("invalid_scope", try await oaAuthorize(app, client: client, challenge: pkce.challenge, scope: "*")),
        ]
        for (code, response) in cases {
            try await eq(response.status, .found); let query = redirected(response)
            try await eq(query["error"], code); try await eq(query["iss"], "http://localhost:18080")
            XCTAssertTrue(response.headers.first(name: .location)?.hasPrefix(Self.oaRedirect + "?") ?? false)
        }
        try await eq(redirected(try await oaAuthorize(app, client: client, challenge: pkce.challenge, scope: "bogus", state: "s-9"))["state"], "s-9")
        try await eq(try await OAuthRequestRecord.query(on: app.db).count(), 0)
        // A valid request without scope asks for all seven scopes; the response is not cached and sends no referrer.
        let ok = try await oaAuthorize(app, client: client, challenge: pkce.challenge, scope: nil, state: nil)
        try await eq(ok.status, .found); try await eq(ok.headers.first(name: .cacheControl), "no-store"); try await eq(ok.headers.first(name: "Referrer-Policy"), "no-referrer")
        let record = try oaUnwrap(try await OAuthRequestRecord.query(on: app.db).first())
        try await eq(Set(record.scopes), Set(McpScopes.all)); XCTAssertNil(record.state); try await eq(record.resource, "http://localhost:18080/mcp")
        try await eq(record.codeChallenge, pkce.challenge)
        XCTAssertNil(record.bindingHash); XCTAssertNil(record.accountId)
        // POST is not an authorization endpoint.
        try await eq(try await oaSend(app, .POST, "/oauth/authorize").status, .notFound)
    }

    func scenarioOAuthRevokeEndpoint(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        let client = try await oaRegister(app), stranger = try await oaRegister(app, name: "S")
        func revoke(_ token: String, client id: String? = nil) async throws -> XCTHTTPResponse {
            var form = ["token": token]; if let id { form["client_id"] = id }
            return try await oaSend(app, .POST, "/oauth/revoke", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: oaForm(form))
        }
        let tokens = try await oaExchange(app, try await oaFlow(app, context, client: client))
        // Unknown tokens and other clients are silently accepted without effect.
        for response in [try await revoke("ttr_" + Secrets.token()), try await revoke("garbage"), try await revoke(tokens.access, client: stranger), try await revoke(tokens.refresh, client: "nope")] {
            try await eq(response.status, .ok); try await eq(response.headers.first(name: .cacheControl), "no-store")
        }
        try await notNil(try await authenticateMcpBearer(tokens.access, on: app.db))
        try await eq(try await oaSend(app, .POST, "/oauth/revoke", headers: ["Content-Type": "application/x-www-form-urlencoded"]).status, .badRequest)
        // Access token: only that token.
        try await eq(try await revoke(tokens.access, client: client).status, .ok)
        try await isNil(try await authenticateMcpBearer(tokens.access, on: app.db))
        let refreshed = try await oaToken(app, ["grant_type": "refresh_token", "refresh_token": tokens.refresh, "client_id": client])
        try await eq(refreshed.status, .ok)
        // Refresh token: the whole grant.
        try await eq(try await revoke(refreshed.json["refresh_token"] as? String ?? "").status, .ok)
        try await isNil(try await authenticateMcpBearer(refreshed.json["access_token"] as? String ?? "", on: app.db))
        try await eq(try list(await api(app, context, .GET, "me/oauth-grants")).count, 0)
    }

    func scenarioApiTokens(_ app: Application, _ auth: AuthService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let b = try await second(app, auth, a)
        // Unauthenticated.
        try await eq(try await oaSend(app, .GET, "/api/v1/me/api-tokens").status, .unauthorized)
        try await eq(try await oaSend(app, .GET, "/api/v1/me/oauth-grants").status, .unauthorized)
        // Create (fresh session).
        let created = try object(await api(app, a, .POST, "me/api-tokens", ["name": "  Claude   Code ", "scopes": ["time:read", "time:write", "time:read"], "expiresInDays": 30], .created))
        let plain = try XCTUnwrap(created["token"] as? String)
        XCTAssertTrue(plain.hasPrefix("ttp_")); try await eq(plain.count, 47)
        try await eq(created["name"] as? String, "Claude Code"); try await eq(created["scopes"] as? [String], ["time:read", "time:write"])
        let expires = try XCTUnwrap(ISO8601DateFormatter().date(from: created["expiresAt"] as? String ?? "")), createdAt = try XCTUnwrap(ISO8601DateFormatter().date(from: created["createdAt"] as? String ?? ""))
        XCTAssertEqual(expires.timeIntervalSince(createdAt), 30 * 86400, accuracy: 2)
        // Only the hash is stored; the plaintext is returned once.
        let record = try oaUnwrap(try await ApiTokenRecord.query(on: app.db).first())
        try await eq(record.tokenHash, Secrets.hash(plain)); try await eq(try await ApiTokenRecord.query(on: app.db).filter(\.$tokenHash == plain).count(), 0)
        let listed = try list(await api(app, a, .GET, "me/api-tokens"))
        try await eq(listed.count, 1); XCTAssertNil(listed[0]["token"]); XCTAssertNil(listed[0]["tokenHash"]); XCTAssertNil(listed[0]["lastUsedAt"] as? String)
        // Works for MCP only through the principal.
        let principal = try oaUnwrap(try await authenticateMcpBearer(plain, on: app.db))
        let recordID = try record.requireID(), accountID = try a.account.requireID()
        try await eq(principal.credentialKind, .personal); try await eq(principal.credentialId, recordID)
        try await eq(principal.scopes, ["time:read", "time:write"]); try await eq(principal.accountId, accountID)
        // Not valid for REST.
        try await eq(try await oaSend(app, .GET, "/api/v1/auth/session", headers: ["Authorization": "Bearer " + plain]).status, .unauthorized)
        // Validation.
        let bad: [[String: Any]] = [
            ["name": "", "scopes": ["time:read"], "expiresInDays": 30], ["name": "   ", "scopes": ["time:read"], "expiresInDays": 30],
            ["name": String(repeating: "n", count: 81), "scopes": ["time:read"], "expiresInDays": 30], ["name": "x", "scopes": [], "expiresInDays": 30],
            ["name": "x", "scopes": ["admin"], "expiresInDays": 30], ["name": "x", "scopes": ["time:read", "*"], "expiresInDays": 30],
            ["name": "x", "scopes": ["time:read"], "expiresInDays": 0], ["name": "x", "scopes": ["time:read"], "expiresInDays": 366],
            ["name": "x", "scopes": ["time:read"], "expiresInDays": -1], ["name": "x", "scopes": ["time:read"]], ["scopes": ["time:read"], "expiresInDays": 3],
            ["name": "x", "scopes": "time:read", "expiresInDays": 3],
        ]
        for body in bad { try await api(app, a, .POST, "me/api-tokens", body, .badRequest) }
        for days in [1, 365] { try await api(app, a, .POST, "me/api-tokens", ["name": "d\(days)", "scopes": McpScopes.all, "expiresInDays": days], .created) }
        // Fresh session required (403 reauth_required); listing and revoking do not need it.
        a.session.createdAt = Date().addingTimeInterval(-3600); try await a.session.update(on: app.db)
        try await eq(try errorCode(await api(app, a, .POST, "me/api-tokens", ["name": "late", "scopes": ["time:read"], "expiresInDays": 3], .forbidden)), "reauth_required")
        try await eq(try list(await api(app, a, .GET, "me/api-tokens")).count, 3)
        // CSRF.
        let noCSRF = try await oaSend(app, .POST, "/api/v1/me/api-tokens", headers: { var h = headers(a, csrf: false); h.contentType = .json; return h }(),
                                      body: ByteBuffer(string: #"{"name":"x","scopes":["time:read"],"expiresInDays":3}"#))
        try await eq(noCSRF.status, .forbidden)
        // Isolation: B sees nothing and cannot revoke A's token.
        try await eq(try list(await api(app, b, .GET, "me/api-tokens")).count, 0)
        let id = try XCTUnwrap(created["id"] as? String)
        try await api(app, b, .DELETE, "me/api-tokens/\(id)", nil, .notFound)
        try await notNil(try await authenticateMcpBearer(plain, on: app.db))
        try await api(app, a, .DELETE, "me/api-tokens/\(UUID().uuidString)", nil, .notFound)
        try await eq(try await oaSend(app, .DELETE, "/api/v1/me/api-tokens/\(id)", headers: headers(a, csrf: false)).status, .forbidden)
        // Revoke.
        try await api(app, a, .DELETE, "me/api-tokens/\(id)", nil, .noContent)
        try await isNil(try await authenticateMcpBearer(plain, on: app.db))
        try await api(app, a, .DELETE, "me/api-tokens/\(id)", nil, .notFound)
        try await eq(try list(await api(app, a, .GET, "me/api-tokens")).count, 2)
        // Recovery sessions cannot manage tokens.
        let recovery = try await auth.issueSession(for: a.account, recovery: true, on: app.db)
        try await api(app, recovery, .GET, "me/api-tokens", nil, .forbidden)
    }

    func scenarioApiTokenLimit(_ app: Application, _ auth: AuthService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        for index in 0..<OAuthCredentialService.maxActiveTokens {
            try await api(app, a, .POST, "me/api-tokens", ["name": "t\(index)", "scopes": ["time:read"], "expiresInDays": 5], .created)
        }
        try await eq(try errorCode(await api(app, a, .POST, "me/api-tokens", ["name": "one more", "scopes": ["time:read"], "expiresInDays": 5], .conflict)), "too_many_tokens")
    }

    func scenarioBearerMatrix(_ app: Application, _ auth: AuthService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let client = try await oaRegister(app)
        let oauth = try await oaExchange(app, try await oaFlow(app, a, client: client, scope: "time:read documents:read"))
        let createdToken = try object(await api(app, a, .POST, "me/api-tokens", ["name": "p", "scopes": ["reports:read"], "expiresInDays": 2], .created))
        let personal = try XCTUnwrap(createdToken["token"] as? String)
        let db: any Database = app.db
        // Accepted.
        try await eq(try await authenticateMcpBearer(oauth.access, on: db)?.scopes, ["time:read", "documents:read"])
        try await eq(try await authenticateMcpBearer(personal, on: db)?.scopes, ["reports:read"])
        // Rejected shapes.
        let rejected = ["", "tto_", "ttp_", "tto_" + String(repeating: "a", count: 43), "ttp_" + String(repeating: "a", count: 43), "ttx_" + String(repeating: "a", count: 43),
                        String(oauth.access.dropFirst(4)), oauth.access + "x", String(oauth.access.dropLast()), oauth.refresh, a.token, "Bearer " + oauth.access,
                        "ttp_" + String(oauth.access.dropFirst(4)), "tto_" + String(personal.dropFirst(4)), oauth.access.uppercased(), "tto_é" + String(repeating: "a", count: 41)]
        for token in rejected { try await isNil(try await authenticateMcpBearer(token, on: db), token) }
        // Prefix mismatch with correct hash is not enough: kind/prefix confusion.
        let refreshHash = try oaUnwrap(try await OAuthToken.query(on: db).filter(\.$tokenHash == Secrets.hash(oauth.refresh)).first())
        try await eq(refreshHash.kind, "refresh")
        // Expiry boundaries.
        let access = try oaUnwrap(try await OAuthToken.query(on: db).filter(\.$tokenHash == Secrets.hash(oauth.access)).first())
        try await notNil(try await authenticateMcpBearer(oauth.access, on: db, now: access.expiresAt.addingTimeInterval(-1)))
        try await isNil(try await authenticateMcpBearer(oauth.access, on: db, now: access.expiresAt))
        let record = try oaUnwrap(try await ApiTokenRecord.query(on: db).first())
        try await isNil(try await authenticateMcpBearer(personal, on: db, now: record.expiresAt.addingTimeInterval(1)))
        // last_used_at is set and throttled to once per minute.
        try await ApiTokenRecord.query(on: db).set(\.$lastUsedAt, to: nil).update()
        let t0 = Date()
        _ = try await authenticateMcpBearer(personal, on: db, now: t0)
        let stamp = try oaUnwrap(try await ApiTokenRecord.query(on: db).first()?.lastUsedAt)
        try await ApiTokenRecord.query(on: db).set(\.$lastUsedAt, to: Date().addingTimeInterval(-5)).update()
        _ = try await authenticateMcpBearer(personal, on: db, now: Date())
        let throttled = try oaUnwrap(try await ApiTokenRecord.query(on: db).first()?.lastUsedAt)
        XCTAssertLessThan(throttled.timeIntervalSinceNow, -3); XCTAssertLessThan(abs(stamp.timeIntervalSince(t0)), 5)
        try await ApiTokenRecord.query(on: db).set(\.$lastUsedAt, to: Date().addingTimeInterval(-120)).update()
        _ = try await authenticateMcpBearer(personal, on: db, now: Date())
        let refreshedStamp = try oaUnwrap(try await ApiTokenRecord.query(on: db).first()?.lastUsedAt)
        XCTAssertGreaterThan(refreshedStamp.timeIntervalSinceNow, -10)
        // Narrowed grant takes effect for existing tokens.
        let grant = try oaUnwrap(try await OAuthGrant.query(on: db).first())
        grant.scopes = ["time:read"]; try await grant.update(on: db)
        try await eq(try await authenticateMcpBearer(oauth.access, on: db)?.scopes, ["time:read"])
        // Revoked token / revoked grant / disabled account.
        access.revokedAt = Date(); try await access.update(on: db)
        try await isNil(try await authenticateMcpBearer(oauth.access, on: db))
        record.revokedAt = Date(); try await record.update(on: db)
        try await isNil(try await authenticateMcpBearer(personal, on: db))
        record.revokedAt = nil; try await record.update(on: db)
        try await notNil(try await authenticateMcpBearer(personal, on: db))
        a.account.disabledAt = Date(); try await a.account.update(on: db)
        try await isNil(try await authenticateMcpBearer(personal, on: db))
        a.account.disabledAt = nil; try await a.account.update(on: db)
        try await notNil(try await authenticateMcpBearer(personal, on: db))
        // Unknown but well-formed.
        try await isNil(try await authenticateMcpBearer(OAuthTokenFormat.make("ttp_"), on: db))
        try await isNil(try await authenticateMcpBearer(OAuthTokenFormat.make("tto_"), on: db))
    }

    func scenarioOAuthNoSecretsLeaked(_ app: Application, _ auth: AuthService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let client = try await oaRegister(app)
        let started = try await oaStart(app, a, client: client, state: "plain-state")
        // The authorize redirect and the error pages carry neither codes nor tokens.
        XCTAssertFalse(started.location.contains("code=")); XCTAssertFalse(started.location.contains("tto_"))
        try await eq(try await oaSend(app, .GET, "/api/v1/oauth/requests/\(started.id)", headers: headers(a)).status, .ok)
        let decision = try await oaDecision(app, a, started.id, approve: true)
        let url = try XCTUnwrap(oaJSON(decision)["redirectUrl"] as? String)
        // Only the authorization code (plus state/iss) is in the redirect URL.
        XCTAssertFalse(url.contains("tto_")); XCTAssertFalse(url.contains("ttr_")); XCTAssertFalse(url.contains("access_token"))
        XCTAssertFalse(url.contains(a.token)); XCTAssertFalse(url.contains(started.verifier)); XCTAssertFalse(url.contains(started.challenge))
        let flow = OAuthFlow(client: client, redirect: Self.oaRedirect, verifier: started.verifier, challenge: started.challenge, requestId: started.id, code: oaQuery(url)["code"] ?? "", state: "", location: url)
        // Failed exchanges do not echo secrets.
        let failure = try await oaToken(app, oaCodeForm(flow, verifier: Secrets.token(bytes: 32)))
        for secret in [flow.code, flow.verifier, flow.challenge] { XCTAssertFalse(failure.response.body.string.contains(secret)) }
        let tokens = try await oaExchange(app, try await oaFlow(app, a, client: client))
        let error = try await oaToken(app, ["grant_type": "refresh_token", "refresh_token": "ttr_" + String(repeating: "z", count: 43), "client_id": client])
        XCTAssertFalse(error.response.body.string.contains("zzzz"))
        // Nothing sensitive in the database in clear text: request/code/token tables hold hashes only.
        let rows = try await OAuthToken.query(on: app.db).all().map(\.tokenHash) + OAuthCode.query(on: app.db).all().map(\.codeHash)
        for secret in [tokens.access, tokens.refresh, flow.code] { XCTAssertFalse(rows.contains(secret)) }
        for row in rows { XCTAssertFalse(row.hasPrefix("tto_") || row.hasPrefix("ttr_")); try await eq(row.count, 43) }
        let requestRecord = try oaUnwrap(try await OAuthRequestRecord.find(UUID(uuidString: started.id), on: app.db))
        try await eq(requestRecord.bindingHash, Secrets.hash(a.token)); XCTAssertNotEqual(requestRecord.bindingHash, a.token)
    }

    func testOAuthRoutesAreNotShadowedByPWAFallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tt-pwa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "<html>PWA</html>".write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try await withApp(environment: ["PWA_STATIC_DIR": directory.path]) { app, _ in
            for path in ["/.well-known/oauth-authorization-server", "/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"] {
                let response = try await self.oaSend(app, .GET, path)
                XCTAssertEqual(response.status, .ok); XCTAssertNotNil(self.oaJSON(response)["resource"] ?? self.oaJSON(response)["issuer"])
            }
            let authorize = try await self.oaSend(app, .GET, "/oauth/authorize")
            XCTAssertEqual(authorize.status, .badRequest); XCTAssertEqual(self.oaJSON(authorize)["error"] as? String, "invalid_client")
            // The consent page itself is a PWA route.
            let consent = try await self.oaSend(app, .GET, "/oauth/consent?request=\(UUID().uuidString)")
            XCTAssertEqual(consent.status, .ok); XCTAssertTrue(consent.body.string.contains("PWA"))
        }
    }

    var oauthScenarios: [(String, Scenario)] {
        [("metadata", scenarioOAuthMetadata), ("registration", scenarioOAuthRegistration), ("fullFlow", scenarioOAuthFullFlow),
         ("codeBinding", scenarioOAuthCodeBinding), ("codeReuse", scenarioOAuthCodeReuse), ("parallelExchange", scenarioOAuthParallelExchange),
         ("refresh", scenarioOAuthRefresh), ("refreshExpiryParallel", scenarioOAuthRefreshExpiryAndParallel), ("grantRevocation", scenarioOAuthGrantRevocation),
         ("consent", scenarioOAuthConsent), ("authorizeValidation", scenarioOAuthAuthorizeValidation), ("revokeEndpoint", scenarioOAuthRevokeEndpoint),
         ("apiTokens", scenarioApiTokens), ("apiTokenLimit", scenarioApiTokenLimit), ("bearerMatrix", scenarioBearerMatrix), ("noSecrets", scenarioOAuthNoSecretsLeaked)]
    }

    func testOAuthSQLite() async throws {
        for (name, scenario) in oauthScenarios {
            do { try await withApp(scenario) } catch { XCTFail("scenario \(name) failed: \(error)"); throw error }
        }
        try await withApp(environment: ["PUBLIC_BASE_URL": "https://time.example.test", "WEBAUTHN_RP_ID": "example.test", "WEBAUTHN_ORIGIN": "https://time.example.test"],
                          scenarioOAuthMetadataFollowsPublicBaseURL)
    }

    func testOAuthMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test", "DB_TLS": "off"]
        for (name, scenario) in oauthScenarios {
            do { try await withApp(environment: environment, scenario) } catch { XCTFail("scenario \(name) failed: \(error)"); throw error }
        }
    }
}
