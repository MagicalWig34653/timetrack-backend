import XCTest
import Vapor
import XCTVapor
@testable import TimetrackKit

// Lives in an AuthTests extension: XCTestCase cannot be instantiated directly on Linux (needs name/testClosure).
extension AuthTests {
    private var nativeDomain: [String: String] { ["WEBAUTHN_RP_ID": "example.test", "WEBAUTHN_ORIGIN": "https://time.example.test", "PUBLIC_BASE_URL": "https://time.example.test"] }

    func testAppleAppIDParsing() throws {
        XCTAssertEqual(try Configuration(environment: [:]).appleAppIDs, [])
        XCTAssertEqual(try Configuration(environment: ["APPLE_APP_IDS": " , "]).appleAppIDs, [])
        let config = try Configuration(environment: ["APPLE_APP_IDS": "ABCDE12345.com.example.timetrack, ,ABCDE12345.com.example.timetrack,ABCDE12345.com.example.timetrack.watchkitapp"])
        XCTAssertEqual(config.appleAppIDs, ["ABCDE12345.com.example.timetrack", "ABCDE12345.com.example.timetrack.watchkitapp"])
        for bad in ["timetrack", "abcde12345.com.example.timetrack", "ABCDE1234.de.x", "ABCDE12345.", "ABCDE12345.de example", "ABCDE12345.com.example.timetrack,oops"] {
            XCTAssertThrowsError(try Configuration(environment: ["APPLE_APP_IDS": bad]), bad) { XCTAssertTrue("\($0)".contains("APPLE_APP_IDS")) }
        }
    }

    func testAllowedOriginsAreExactAndOnlyWidenedForRealDomains() throws {
        XCTAssertEqual(try Configuration(environment: [:]).webAuthnAllowedOrigins, ["http://localhost:18080"])
        XCTAssertEqual(try Configuration(environment: nativeDomain).webAuthnAllowedOrigins, ["https://time.example.test", "https://example.test"])
        var same = nativeDomain; same["WEBAUTHN_ORIGIN"] = "https://example.test"
        XCTAssertEqual(try Configuration(environment: same).webAuthnAllowedOrigins, ["https://example.test"])
    }

    func testWellKnownEndpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pwa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "<html>PWA</html>".write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let aasa = "/.well-known/apple-app-site-association"
        try await withApp(environment: ["PWA_STATIC_DIR": directory.path]) { app, _ in
            try await app.test(.GET, aasa) { r async throws in XCTAssertEqual(r.status, .notFound) }
        }
        try await withApp(environment: ["PWA_STATIC_DIR": directory.path, "APPLE_APP_IDS": "ABCDE12345.com.example.timetrack,ABCDE12345.com.example.timetrack.watchkitapp"]) { app, _ in
            try await app.test(.GET, aasa) { response async throws in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers.first(name: .contentType), "application/json")
                XCTAssertNil(response.headers.first(name: .location))
                XCTAssertEqual(response.body.string, #"{"webcredentials":{"apps":["ABCDE12345.com.example.timetrack","ABCDE12345.com.example.timetrack.watchkitapp"]}}"#)
            }
            // The SPA fallback still serves other paths and does not shadow other .well-known routes.
            try await app.test(.GET, "/some/spa/route") { r async throws in XCTAssertTrue(r.body.string.contains("PWA")) }
            try await app.test(.GET, "/.well-known/unknown") { r async throws in XCTAssertEqual(r.status, .notFound); XCTAssertFalse(r.body.string.contains("PWA")) }
        }
    }

    func testNativeOriginAcceptedOnlyFromAllowList() async throws {
        try await withApp(environment: nativeDomain) { app, service in
            var device = SoftwareAuthenticator(); device.rpID = "example.test"
            let invite = try await service.createInvitation(.init(), context: nil, bootstrap: true, on: app.db)
            func options(_ handle: String, _ token: String) async throws -> OptionsDTO {
                try await service.registrationOptions(.init(inviteToken: token, handle: handle, displayName: "Native", email: nil), on: app.db)
            }
            let first = try await options("native", invite.token!)
            for bad in ["https://evil.example", "https://example.test:8443", "http://example.test", "https://sub.example.test", "https://time.example.test/"] {
                await self.expect("bad_request") { _ = try await service.register(device.registration(first, origin: bad), on: app.db) }
            }
            // A wrong RP ID hash is still rejected even with an allowed origin.
            var wrongRP = device; wrongRP.rpID = "other.test"
            await self.expect("bad_request") { _ = try await service.register(wrongRP.registration(first, origin: "https://example.test"), on: app.db) }
            let context = try await service.register(device.registration(first, origin: "https://example.test"), on: app.db)
            let account = context.account
            // Login: native origin and web origin both work, others do not.
            let a = try await service.loginOptions(on: app.db)
            await self.expect("unauthorized") { _ = try await service.login(device.assertion(a, accountID: account.requireID(), count: 1, origin: "https://evil.example"), on: app.db) }
            _ = try await service.login(device.assertion(a, accountID: account.requireID(), count: 1, origin: "https://example.test"), on: app.db)
            let b = try await service.loginOptions(on: app.db)
            _ = try await service.login(device.assertion(b, accountID: account.requireID(), count: 2, origin: "https://time.example.test"), on: app.db)
        }
    }

    func testNativeOriginRejectedOnLocalhostConfig() async throws {
        try await withApp { app, service in
            let invite = try await service.createInvitation(.init(), context: nil, bootstrap: true, on: app.db)
            let options = try await service.registrationOptions(.init(inviteToken: invite.token!, handle: "local", displayName: "Local", email: nil), on: app.db)
            await self.expect("bad_request") { _ = try await service.register(SoftwareAuthenticator().registration(options, origin: "https://localhost"), on: app.db) }
        }
    }
}
