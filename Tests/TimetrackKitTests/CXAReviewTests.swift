import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

/// CX-A: Codex review findings F01 (pagination overflow), F02 (credentials minted after session revocation),
/// F03 (MCP tool run with a revoked or narrowed credential).
extension AuthTests {
    // MARK: F01

    func testPaginationRangeIsOverflowSafe() throws {
        XCTAssertEqual(try Pagination.range(limit: 50, offset: 0, maxLimit: 100), 0..<50)
        XCTAssertEqual(try Pagination.range(limit: 100, offset: Pagination.maxOffset, maxLimit: 100), Pagination.maxOffset..<(Pagination.maxOffset + 100))
        for (limit, offset) in [(1, Int.max), (Int.max, 0), (Int.max, Int.max), (1, Pagination.maxOffset + 1), (1, -1), (0, 0), (101, 0), (-1, 0), (1, Int.min)] {
            XCTAssertThrowsError(try Pagination.range(limit: limit, offset: offset, maxLimit: 100), "limit \(limit) offset \(offset)") {
                XCTAssertEqual(($0 as? APIError)?.code, "bad_request")
            }
        }
    }

    func testPaginationExtremesAreRejectedEverywhere() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let big = String(Int.max)
            for path in ["time/segments/cancelled?offset=\(big)&limit=1", "time/segments/cancelled?offset=\(big)", "time/segments/cancelled?limit=\(big)",
                         "time/account/adjustments?offset=\(big)&limit=1", "time/account/adjustments?limit=\(big)",
                         "admin/accounts?offset=\(big)&limit=1", "admin/accounts?limit=\(big)", "admin/accounts?offset=100001"] {
                try await timeRequest(app, context, .GET, path, status: .badRequest)
            }
            // The largest accepted offset is an empty page, not an error.
            let page = try object(await timeRequest(app, context, .GET, "time/segments/cancelled?offset=\(Pagination.maxOffset)"))
            XCTAssertEqual((page["items"] as? [Any])?.count, 0)
            let admin = try object(await timeRequest(app, context, .GET, "admin/accounts?offset=\(Pagination.maxOffset)"))
            XCTAssertEqual((admin["items"] as? [Any])?.count, 0)

            // Services directly (any future caller), including MCP.
            let time = TimeServices(accountId: try context.account.requireID(), db: app.db, disabledModules: [])
            await expect("bad_request") { _ = try await time.segments.listCancelled(CancelledFilter(), limit: 1, offset: Int.max) }
            let service = AccountAdminService(auth: auth, db: app.db, storage: StorageService(auth: auth, db: app.db, client: app.client, env: app.storageEnvironment))
            await expect("bad_request") { _ = try await service.list(context, limit: 1, offset: Int.max) }

            installMcp(app, ["A": try principal(context)])
            try await mcpFails(app, "A", "list_cancelled_segments", ["offset": Int.max], "invalid_arguments")
            try await mcpFails(app, "A", "list_time_adjustments", ["offset": Int.max], "invalid_arguments")
            _ = try await mcpOK(app, "A", "list_cancelled_segments", ["offset": 5])
        }
    }

    // MARK: F02

    private func revokeSession(_ context: AuthContext, on db: any Database) async throws {
        try await Session.query(on: db).filter(\.$id == context.session.requireID()).set(\.$revokedAt, to: Date()).update()
    }

    func testPersonalTokenNotCreatedAfterSessionRevocation() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let credentials = OAuthCredentialService(auth: auth, oauth: OAuthService(auth: auth))
            let input = ApiTokenInput(name: "ci", scopes: ["time:read"], expiresInDays: 30)
            // The middleware accepted the request; the session is revoked before the serialized transaction starts.
            try await revokeSession(context, on: app.db)
            await expect("unauthorized") { _ = try await credentials.createToken(input, context, on: app.db) }
            let count = try await ApiTokenRecord.query(on: app.db).count()
            XCTAssertEqual(count, 0)
        }
    }

    func testOAuthDecisionNotAppliedAfterSessionRevocation() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let oauth = OAuthService(auth: auth)
            let client = try await oaRegister(app)
            let started = try await oaStart(app, context, client: client)
            try await revokeSession(context, on: app.db)
            await expect("unauthorized") { _ = try await oauth.decide(UUID(uuidString: started.id)!, approve: true, scopes: nil, context, on: app.db) }
            let grants = try await OAuthGrant.query(on: app.db).count(), codes = try await OAuthCode.query(on: app.db).count()
            XCTAssertEqual(grants, 0); XCTAssertEqual(codes, 0)
            // The request was not consumed either.
            let record = try await OAuthRequestRecord.find(UUID(uuidString: started.id)!, on: app.db)
            XCTAssertNil(record?.decidedAt)
        }
    }

    func testCredentialsStillWorkWithLiveSession() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let credentials = OAuthCredentialService(auth: auth, oauth: OAuthService(auth: auth))
            let created = try await credentials.createToken(ApiTokenInput(name: "ci", scopes: ["time:read"], expiresInDays: 30), context, on: app.db)
            XCTAssertNotNil(created.token)
            let flow = try await oaFlow(app, context, client: try await oaRegister(app))
            XCTAssertFalse(flow.code.isEmpty)
        }
    }

    // MARK: F03

    private func mcpPrincipal(_ app: Application, _ token: String) async throws -> McpAuthPrincipal {
        let found = try await OAuthMcpAuthenticator().authenticate(token: token, db: app.db)
        return try XCTUnwrap(found)
    }
    private func runTool(_ app: Application, _ auth: AuthService, _ principal: McpAuthPrincipal, scope: String = "time:write") async throws -> UUID {
        try await McpToolContext.session(principal, authenticator: OAuthMcpAuthenticator(), requiredScope: scope, auth: auth, db: app.db) { $0.time.accountId }
    }

    func testMcpToolRechecksPersonalTokenUnderLock() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let credentials = OAuthCredentialService(auth: auth, oauth: OAuthService(auth: auth))
            let created = try await credentials.createToken(ApiTokenInput(name: "ci", scopes: ["time:read", "time:write"], expiresInDays: 30), context, on: app.db)
            let token = try XCTUnwrap(created.token), tokenID = created.id
            let principal = try await mcpPrincipal(app, token)
            XCTAssertNotNil(principal.tokenHash)
            let accountID = try context.account.requireID()
            let ran = try await runTool(app, auth, principal)
            XCTAssertEqual(ran, accountID)

            // Scopes narrowed after authentication: the stale principal still lists time:write, the tool must not run.
            try await ApiTokenRecord.query(on: app.db).filter(\.$id == tokenID).set(\.$scopes, to: ["time:read"]).update()
            await expectScope("time:write") { _ = try await runTool(app, auth, principal) }
            let readOK = try await runTool(app, auth, principal, scope: "time:read")
            XCTAssertEqual(readOK, accountID)

            // Expired.
            try await ApiTokenRecord.query(on: app.db).filter(\.$id == tokenID).set(\.$expiresAt, to: Date().addingTimeInterval(-5)).update()
            await expect("unauthorized") { _ = try await runTool(app, auth, principal, scope: "time:read") }
            try await ApiTokenRecord.query(on: app.db).filter(\.$id == tokenID).set(\.$expiresAt, to: Date().addingTimeInterval(3600)).update()
            _ = try await runTool(app, auth, principal, scope: "time:read")

            // Revoked.
            try await ApiTokenRecord.query(on: app.db).filter(\.$id == tokenID).set(\.$revokedAt, to: Date()).update()
            await expect("unauthorized") { _ = try await runTool(app, auth, principal, scope: "time:read") }

            // A principal without a token hash fails closed.
            let anonymous = McpAuthPrincipal(accountId: accountID, scopes: ["time:write"], credentialKind: .personal, credentialId: tokenID)
            await expect("unauthorized") { _ = try await runTool(app, auth, anonymous) }
        }
    }

    func testMcpToolRechecksOAuthGrantUnderLock() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let flow = try await oaFlow(app, context, client: try await oaRegister(app), scope: "time:read time:write")
            let tokens = try await oaExchange(app, flow)
            let principal = try await mcpPrincipal(app, tokens.access)
            XCTAssertTrue(principal.scopes.contains("time:write"))
            _ = try await runTool(app, auth, principal)

            let grantID = principal.credentialId
            try await OAuthGrant.query(on: app.db).filter(\.$id == grantID).set(\.$scopes, to: ["time:read"]).update()
            await expectScope("time:write") { _ = try await runTool(app, auth, principal) }

            try await OAuthGrant.query(on: app.db).filter(\.$id == grantID).set(\.$revokedAt, to: Date()).update()
            await expect("unauthorized") { _ = try await runTool(app, auth, principal, scope: "time:read") }
        }
    }

    func testMcpHTTPCallWithNarrowedTokenIsRefused() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let credentials = OAuthCredentialService(auth: auth, oauth: OAuthService(auth: auth))
            let created = try await credentials.createToken(ApiTokenInput(name: "ci", scopes: ["time:read", "time:write"], expiresInDays: 30), context, on: app.db)
            let token = try XCTUnwrap(created.token)
            _ = try await mcpOK(app, token, "get_current_timer")
            try await ApiTokenRecord.query(on: app.db).filter(\.$id == created.id).set(\.$scopes, to: ["time:read"]).update()
            try await mcpFails(app, token, "start_timer", [:], "insufficient_scope")
            _ = try await mcpOK(app, token, "get_current_timer")
        }
    }

    private func expectScope(_ scope: String, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected insufficient scope", file: file, line: line) }
        catch let error as McpInsufficientScope { XCTAssertEqual(error.scope, scope, file: file, line: line) }
        catch { XCTFail("Unexpected \(error)", file: file, line: line) }
    }
}
