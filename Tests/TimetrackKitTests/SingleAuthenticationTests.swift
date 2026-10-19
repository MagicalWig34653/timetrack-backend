import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

/// S1b: the session cookie is verified once per request (module-gated routes used to verify it twice: `ModuleGuard`, then
/// `SessionMiddleware`). Behaviour (scopes, CSRF, revoked sessions, recovery restriction) must stay identical.
/// Records the Fluent builder queries of every request (raw SQL such as the `auth_lock` toggle is not recorded). Installed as
/// the outermost middleware so it also sees the queries of `ModuleGuard` and `SessionMiddleware`.
final class RequestQueryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [DatabaseQuery] = []
    func reset() { lock.withLock { queries.removeAll() } }
    var all: [DatabaseQuery] { lock.withLock { queries } }
    func add(_ more: [DatabaseQuery]) { lock.withLock { queries += more } }
    var sessionLookups: Int { all.filter { $0.schema == "sessions" && String(describing: $0.action) == "read" }.count }
    var schemas: [String] { all.map { "\($0.schema)" } }
}

struct RequestQueryLogMiddleware: AsyncMiddleware {
    let log: RequestQueryLog
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        request.fluent.history.start()
        defer { log.add(request.fluent.history.queries) }
        return try await next.respond(to: request)
    }
}

extension AuthTests {
    func testModuleGatedGetVerifiesSessionOnce() async throws {
        try await withApp { app, auth in
            let (admin, _) = try await registered(auth, db: app.db)
            let log = RequestQueryLog()
            app.middleware.use(RequestQueryLogMiddleware(log: log), at: .beginning)
            let gated = try await app.testable().sendRequest(.GET, "/api/v1/reports/learning-fields", headers: headers(admin))
            XCTAssertEqual(gated.status, .ok)
            print("S1B-QUERIES module-gated GET reports/learning-fields: fluentQueries=\(log.all.count) sessionLookups=\(log.sessionLookups) schemas=\(log.schemas)")
            XCTAssertEqual(log.sessionLookups, 1)
            log.reset()
            let plain = try await app.testable().sendRequest(.GET, "/api/v1/me/passkeys", headers: headers(admin))
            XCTAssertEqual(plain.status, .ok)
            print("S1B-QUERIES plain GET me/passkeys: fluentQueries=\(log.all.count) sessionLookups=\(log.sessionLookups) schemas=\(log.schemas)")
            XCTAssertEqual(log.sessionLookups, 1)
        }
    }

    func testSingleVerificationKeepsRevocationCsrfAndRecoveryBehaviour() async throws {
        try await withApp { app, auth in
            let (admin, _) = try await registered(auth, db: app.db)
            let path = "/api/v1/reports/learning-fields"
            // Revoked token: 401 on a module-gated route and on a plain route.
            let revoked = try await auth.issueSession(for: admin.account, on: app.db)
            let before = try await app.testable().sendRequest(.GET, path, headers: headers(revoked))
            XCTAssertEqual(before.status, .ok)
            try await auth.revokeSessions(revoked, others: false, on: app.db)
            let after = try await app.testable().sendRequest(.GET, path, headers: headers(revoked))
            XCTAssertEqual(after.status, .unauthorized)
            let afterPlain = try await app.testable().sendRequest(.GET, "/api/v1/me/passkeys", headers: headers(revoked))
            XCTAssertEqual(afterPlain.status, .unauthorized)
            // CSRF: a write on a module-gated route without the header is 403 csrf_invalid, with it the write passes.
            var noCSRF = headers(admin, csrf: false); noCSRF.contentType = .json
            let payload = ByteBuffer(string: #"{"name":"Lernfeld A"}"#)
            let forbidden = try await app.testable().sendRequest(.POST, path, headers: noCSRF, body: payload)
            XCTAssertEqual(forbidden.status, .forbidden)
            XCTAssertTrue(forbidden.body.string.contains("csrf_invalid"))
            var withCSRF = headers(admin); withCSRF.contentType = .json
            let created = try await app.testable().sendRequest(.POST, path, headers: withCSRF, body: payload)
            XCTAssertEqual(created.status, .created, created.body.string)
            // Recovery sessions stay restricted on module-gated routes.
            let recovery = try await auth.issueSession(for: admin.account, recovery: true, on: app.db)
            let restricted = try await app.testable().sendRequest(.GET, path, headers: headers(recovery))
            XCTAssertEqual(restricted.status, .forbidden)
            XCTAssertTrue(restricted.body.string.contains("recovery_session_restricted"))
            // Module switched off for the account: still 404 module_disabled (the guard keeps using the cached context).
            var modules = headers(admin); modules.contentType = .json
            let off = try await app.testable().sendRequest(.PUT, "/api/v1/me/modules", headers: modules, body: ByteBuffer(string: #"{"modules":{"reports":false}}"#))
            XCTAssertEqual(off.status, .ok, off.body.string)
            let disabled = try await app.testable().sendRequest(.GET, path, headers: headers(admin))
            XCTAssertEqual(disabled.status, .notFound)
            XCTAssertTrue(disabled.body.string.contains("module_disabled"))
        }
    }
}
