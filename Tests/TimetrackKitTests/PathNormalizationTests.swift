import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

extension AuthTests {
    func testPathNormalizationAuthRateLimit() async throws {
        try await withApp { app, service in
            let paths = ["/api/v1/auth/login/options", "/api/v1/auth//login/options", "/api//v1/auth/login/options", "/api/v1/auth/login/options/", "//api/v1/auth/login/options"]
            // All variants reach the login handler before the shared IP bucket is exhausted.
            for path in paths {
                try await app.test(.POST, path) { response async throws in
                    XCTAssertEqual(response.status, .ok, path)
                    _ = try response.content.decode(OptionsDTO.self)
                }
            }
            try await RateLimitEvent.query(on: app.db).delete()
            for _ in 0..<60 { try await service.limited(ip: "unknown", on: app.db) }
            let limited: [(HTTPMethod, String)] = paths.map { (HTTPMethod.POST, $0) } + [
                (.POST, "/api/v1/auth/register/options"), (.POST, "/api/v1/auth//register/options"), (.POST, "/api/v1/auth/recovery/start"), (.POST, "/api/v1/auth//recovery/start"),
                (.PUT, "/api/v1/me/recovery/email"), (.PUT, "/api/v1/me//recovery/email"), (.POST, "/api/v1/me/profile/email/verify"), (.POST, "/api/v1/me//profile/email/verify")
            ]
            for (method, path) in limited {
                try await app.test(method, path) { response async throws in
                    XCTAssertEqual(response.status, .tooManyRequests, path)
                    XCTAssertTrue(response.body.string.contains("too_many_requests"), path)
                }
            }
            // GET remains outside the POST/PUT limiter.
            try await app.test(.GET, "/api/v1/auth//session") { response async throws in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testPathNormalizationRecoveryRemainsClosed() async throws {
        try await withApp { app, service in
            let (normal, _) = try await registered(service, db: app.db)
            let recovery = try await service.issueSession(for: normal.account, recovery: true, on: app.db)
            try await app.test(.GET, "/api/v1/auth/session", headers: headers(recovery)) { response async throws in
                XCTAssertEqual(response.status, .ok)
            }
            for (method, path) in [(HTTPMethod.GET, "/api/v1/auth//session"), (.POST, "/api/v1/me//passkeys/options"),
                                   (.GET, "//api/v1/me/passkeys"), (.GET, "/api/v1/me//recovery")] {
                try await app.test(method, path, headers: headers(recovery)) { response async throws in
                    XCTAssertEqual(response.status, .forbidden, path)
                    XCTAssertTrue(response.body.string.contains("recovery_session_restricted"), path)
                }
            }
            try await app.test(.POST, "/api/v1/me/passkeys/options", headers: headers(recovery)) { response async throws in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func testPathNormalizationDeviceScopeRemainsClosed() async throws {
        try await withApp { app, auth in
            let (context, _) = try await registered(auth, db: app.db)
            let result = try object(await timeRequest(app, context, .POST, "me/device-tokens", ["name": "Phone"], status: .created))
            let bearer: HTTPHeaders = ["Authorization": "Bearer " + (try XCTUnwrap(result["token"] as? String))]
            // The canonical automation route passes the scope guard, then rejects the missing body.
            try await app.test(.POST, "/api/v1/automation/events", headers: bearer) { response async throws in
                XCTAssertEqual(response.status, .badRequest)
            }
            for path in ["/api/v1/automation//events", "//api/v1/automation/events", "/api/v1/me//device-tokens", "/api/v1/auth//login/options", "/mcp/"] {
                try await app.test(.POST, path, headers: bearer) { response async throws in
                    XCTAssertTrue([HTTPResponseStatus.unauthorized, .badRequest].contains(response.status), "\(path) -> \(response.status)")
                }
            }
        }
    }

    func testPathNormalizationPublicHeadersAndPWAReservedRoutes() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".path-test-assets")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<html>SPA</html>".utf8).write(to: root.appendingPathComponent("index.html"))
        try await withApp(environment: ["PWA_STATIC_DIR": root.path]) { app, _ in
            for path in ["/health", "/health//", "//health"] {
                try await app.test(.GET, path) { response async throws in
                    XCTAssertEqual(response.status, .ok, path)
                    XCTAssertFalse(response.body.string.contains("SPA"), path)
                }
            }
            for path in ["/api//unknown", "//ready/unknown", "/oauth//authorize/unknown", "/mcp//unknown", "/t//unknown", "/ics//unknown", "/.well-known//unknown", "/%2fapi/unknown"] {
                try await app.test(.GET, path) { response async throws in
                    XCTAssertEqual(response.status, .notFound, path)
                    XCTAssertFalse(response.body.string.contains("SPA"), path)
                }
            }
            // A stale cookie must be ignored on public routes, including the ModuleGuard exception.
            for path in ["/api/v1/public/groups/invalid", "/api//v1/public//groups/invalid", "//api/v1/public/groups/invalid"] {
                try await app.test(.GET, path, headers: ["Cookie": "tt_session=stale"]) { response async throws in
                    XCTAssertEqual(response.status, .notFound, path)
                    XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store", path)
                    XCTAssertEqual(response.headers.first(name: "X-Robots-Tag"), "noindex, nofollow", path)
                }
            }
            try await app.test(.GET, "/g//invalid") { response async throws in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers.first(name: "Referrer-Policy"), "no-referrer")
            }
        }
    }
}
