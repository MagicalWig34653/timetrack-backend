import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

/// SEC-15b: the `__Host-` prefix on the session cookie, only over an https base URL.
final class SessionCookieTests: XCTestCase, @unchecked Sendable {
    private let secureEnvironment = ["PUBLIC_BASE_URL": "https://time.example.test", "WEBAUTHN_RP_ID": "example.test", "WEBAUTHN_ORIGIN": "https://time.example.test"]

    private func withApp(environment: [String: String], _ run: (Application, AuthService) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        app.logger.logLevel = .critical
        let config = try Configuration(environment: ["SQLITE_PATH": ":memory:"].merging(environment) { _, new in new })
        do {
            try await configure(app, configuration: config, mailSender: nil)
            try await app.autoMigrate()
            try await run(app, AuthService(configuration: config, mailSender: nil))
            try await app.autoRevert()
        } catch { try await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }

    /// Registers over HTTP and returns the Set-Cookie header lines of the response.
    private func register(_ app: Application, _ service: AuthService) async throws -> [String] {
        let secure = service.configuration.publicBaseURL.scheme == "https"
        let invite = try await service.createInvitation(.init(), context: nil, bootstrap: true, on: app.db)
        let options = try await service.registrationOptions(.init(inviteToken: invite.token!, handle: "admin", displayName: "Admin", email: nil), on: app.db)
        var device = SoftwareAuthenticator(); if secure { device.rpID = "example.test" }
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(device.registration(options, origin: secure ? "https://time.example.test" : "http://localhost:18080"))) as! [String: Any]
        var credential = value["credential"] as! [String: Any]; credential["type"] = "public-key"; value["credential"] = credential
        let body = try JSONSerialization.data(withJSONObject: value)
        var lines: [String] = []
        try await app.test(.POST, "/api/v1/auth/register/verify", beforeRequest: { req in
            req.headers.contentType = .json; req.body = ByteBuffer(data: body)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .created)
            lines = res.headers[.setCookie]
        })
        return lines
    }

    private func token(_ lines: [String], name: String) throws -> String {
        let line = try XCTUnwrap(lines.first { $0.hasPrefix(name + "=") }, "missing \(name) in \(lines)")
        return String(line.dropFirst(name.count + 1).prefix { $0 != ";" })
    }

    func testNameDependsOnlyOnHTTPSBaseURL() throws {
        let secure = try Configuration(environment: ["SQLITE_PATH": ":memory:"].merging(secureEnvironment) { _, new in new })
        let plain = try Configuration(environment: ["SQLITE_PATH": ":memory:", "PUBLIC_BASE_URL": "http://localhost:18080"])
        XCTAssertEqual(SessionCookie.name(secure), "__Host-tt_session")
        XCTAssertEqual(SessionCookie.name(plain), "tt_session")
    }

    func testHTTPSLoginSetsHostPrefixedCookieWithRequiredAttributes() async throws {
        try await withApp(environment: secureEnvironment) { app, service in
            let lines = try await register(app, service)
            let line = try XCTUnwrap(lines.first { $0.hasPrefix("__Host-tt_session=") })
            XCTAssertFalse(try token(lines, name: "__Host-tt_session").isEmpty)
            let attributes = line.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            for required in ["secure", "httponly", "samesite=lax", "path=/"] { XCTAssertTrue(attributes.contains(required), "\(required) missing in \(line)") }
            XCTAssertFalse(attributes.contains { $0.hasPrefix("domain") }, "__Host- forbids a Domain attribute")
            // The old name is only ever sent as an expiry.
            let legacy = try XCTUnwrap(lines.first { $0.hasPrefix("tt_session=") })
            XCTAssertTrue(legacy.lowercased().contains("max-age=0"))
            XCTAssertTrue(try token(lines, name: "tt_session").isEmpty)
        }
    }

    func testPlainHTTPKeepsUnprefixedNonSecureCookie() async throws {
        try await withApp(environment: [:]) { app, service in
            let lines = try await register(app, service)
            XCTAssertFalse(lines.contains { $0.hasPrefix("__Host-") })
            let line = try XCTUnwrap(lines.first { $0.hasPrefix("tt_session=") })
            XCTAssertFalse(try token(lines, name: "tt_session").isEmpty)
            let attributes = line.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            XCTAssertFalse(attributes.contains("secure"))
            XCTAssertTrue(attributes.contains("httponly")); XCTAssertTrue(attributes.contains("path=/"))
        }
    }

    func testHostCookieAuthenticatesAndLegacyCookieDoesNot() async throws {
        try await withApp(environment: secureEnvironment) { app, service in
            let value = try token(try await register(app, service), name: "__Host-tt_session")
            try await app.test(.GET, "/api/v1/auth/session", headers: ["Cookie": "__Host-tt_session=\(value)"]) { res async throws in XCTAssertEqual(res.status, .ok) }
            // A session cookie under the pre-prefix name (one that survived the update) is not accepted.
            try await app.test(.GET, "/api/v1/auth/session", headers: ["Cookie": "tt_session=\(value)"]) { res async throws in XCTAssertEqual(res.status, .unauthorized) }
            // Mutating requests need the CSRF header on top of the new cookie.
            try await app.test(.DELETE, "/api/v1/auth/session", headers: ["Cookie": "__Host-tt_session=\(value)"]) { res async throws in XCTAssertEqual(res.status, .forbidden) }
        }
    }

    func testPlainHTTPRejectsPrefixedName() async throws {
        try await withApp(environment: [:]) { app, service in
            let value = try token(try await register(app, service), name: "tt_session")
            try await app.test(.GET, "/api/v1/auth/session", headers: ["Cookie": "tt_session=\(value)"]) { res async throws in XCTAssertEqual(res.status, .ok) }
            try await app.test(.GET, "/api/v1/auth/session", headers: ["Cookie": "__Host-tt_session=\(value)"]) { res async throws in XCTAssertEqual(res.status, .unauthorized) }
        }
    }

    func testLogoutExpiresCurrentAndLegacyNames() async throws {
        try await withApp(environment: secureEnvironment) { app, service in
            let value = try token(try await register(app, service), name: "__Host-tt_session")
            let headers: HTTPHeaders = ["Cookie": "__Host-tt_session=\(value); tt_session=stale", "X-CSRF-Token": Secrets.csrf(value)]
            try await app.test(.DELETE, "/api/v1/auth/session", headers: headers) { res async throws in
                XCTAssertEqual(res.status, .noContent)
                for name in ["__Host-tt_session", "tt_session"] {
                    let line = try XCTUnwrap(res.headers[.setCookie].first { $0.hasPrefix(name + "=") }, "\(name) not expired")
                    XCTAssertTrue(line.lowercased().contains("max-age=0"), line)
                    XCTAssertTrue(line.contains("Path=/")); XCTAssertTrue(line.contains("Secure"))
                    XCTAssertFalse(line.lowercased().contains("domain"))
                }
            }
            try await app.test(.GET, "/api/v1/auth/session", headers: ["Cookie": "__Host-tt_session=\(value)"]) { res async throws in XCTAssertEqual(res.status, .unauthorized) }
        }
    }

    func testBearerRoutesStillRefuseRequestsCarryingAnySessionCookie() async throws {
        try await withApp(environment: secureEnvironment) { app, service in
            for name in ["__Host-tt_session", "tt_session"] {
                XCTAssertTrue(service.hasSessionCookie(Request(application: app, headers: ["Cookie": "\(name)=x"], on: app.eventLoopGroup.next())))
            }
            XCTAssertFalse(service.hasSessionCookie(Request(application: app, on: app.eventLoopGroup.next())))
        }
    }
}
