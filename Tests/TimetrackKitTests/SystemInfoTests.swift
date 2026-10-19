import Foundation
import XCTVapor
@testable import TimetrackKit

extension AuthTests {
    func testSystemInfoReportsBuildMetadataAndPWAVersion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("v1-pwa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"version":"0.2.0","revision":"1234567890abcdef1234567890abcdef12345678","buildDate":"2026-10-18T08:00:00Z"}"#.utf8)
            .write(to: directory.appendingPathComponent("version.json"))
        let environment = ["TIMETRACK_VERSION": "0.2.0", "TIMETRACK_REVISION": "abcdef0123456789abcdef0123456789abcdef01",
                           "TIMETRACK_BUILD_DATE": "2026-10-18T08:01:02Z", "PWA_STATIC_DIR": directory.path]
        try await withApp(environment: environment) { app, auth in
            let (admin, _) = try await registered(auth, db: app.db)
            // The guard: no session, no information.
            let anonymous = try await app.testable().sendRequest(.GET, "/api/v1/system/info")
            XCTAssertEqual(anonymous.status, .unauthorized)
            let response = try await app.testable().sendRequest(.GET, "/api/v1/system/info", headers: headers(admin))
            XCTAssertEqual(response.status, .ok)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
            let backend = try XCTUnwrap(json["backend"] as? [String: Any])
            XCTAssertEqual(backend["version"] as? String, "0.2.0")
            XCTAssertEqual(backend["revision"] as? String, "abcdef0123456789abcdef0123456789abcdef01")
            XCTAssertEqual(backend["revisionShort"] as? String, "abcdef0")
            XCTAssertEqual(backend["buildDate"] as? String, "2026-10-18T08:01:02Z")
            XCTAssertEqual(backend["database"] as? String, "sqlite")
            XCTAssertGreaterThan(backend["schemaMigrations"] as? Int ?? 0, 10)
            XCTAssertEqual(backend["migrationsPending"] as? Bool, false)
            XCTAssertGreaterThanOrEqual(backend["uptimeSeconds"] as? Int ?? -1, 0)
            XCTAssertFalse((backend["replicaId"] as? String ?? "").isEmpty)
            let pwa = try XCTUnwrap(json["pwa"] as? [String: Any])
            XCTAssertEqual(pwa["version"] as? String, "0.2.0")
            XCTAssertEqual(pwa["revision"] as? String, "1234567890abcdef1234567890abcdef12345678")
            XCTAssertEqual(pwa["buildDate"] as? String, "2026-10-18T08:00:00Z")
            // Any role may read the version fields, but operational fields are for administrators only (Q1 finding 2).
            let member = try await second(app, auth, admin)
            let memberResponse = try await app.testable().sendRequest(.GET, "/api/v1/system/info", headers: headers(member))
            XCTAssertEqual(memberResponse.status, .ok)
            let memberJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(memberResponse.body.readableBytesView)) as? [String: Any])
            let memberBackend = try XCTUnwrap(memberJSON["backend"] as? [String: Any])
            XCTAssertEqual(Set(memberBackend.keys), ["version", "revision", "revisionShort", "buildDate", "apiVersion"])
            XCTAssertEqual(memberBackend["version"] as? String, "0.2.0")
            XCTAssertEqual(memberBackend["apiVersion"] as? String, apiContractVersion)
            XCTAssertNotNil(memberJSON["pwa"] as? [String: Any])
            let raw = memberResponse.body.string
            for hidden in ["hostName", "replicaId", "database", "sqlite", "uptime", "schemaMigrations"] { XCTAssertFalse(raw.contains(hidden), "\(hidden) leaked to a member") }
            // /health carries the same version and revision, without a session.
            let health = try await app.testable().sendRequest(.GET, "/health")
            XCTAssertEqual(health.status, .ok)
            let body = try JSONSerialization.jsonObject(with: Data(health.body.readableBytesView)) as? [String: String]
            XCTAssertEqual(body, ["status": "ok", "version": "0.2.0", "revision": "abcdef0123456789abcdef0123456789abcdef01"])
        }
    }

    func testSystemInfoDefaultsForLocalBuilds() async throws {
        try await withApp(environment: ["PWA_STATIC_DIR": "/nonexistent-\(UUID().uuidString)"]) { app, auth in
            let (admin, _) = try await registered(auth, db: app.db)
            let response = try await app.testable().sendRequest(.GET, "/api/v1/system/info", headers: headers(admin))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
            let backend = try XCTUnwrap(json["backend"] as? [String: Any])
            XCTAssertEqual(backend["version"] as? String, "dev")
            XCTAssertEqual(backend["revision"] as? String, "unknown")
            XCTAssertEqual(backend["revisionShort"] as? String, "unknown")
            XCTAssertTrue(backend["buildDate"] is NSNull)
            XCTAssertTrue(json["pwa"] is NSNull)
        }
    }

    func testBuildInfoIgnoresBlankValues() throws {
        let info = BuildInfo(environment: ["TIMETRACK_VERSION": "  ", "TIMETRACK_REVISION": "", "TIMETRACK_BUILD_DATE": " "])
        XCTAssertEqual(info, BuildInfo())
    }

    /// The Swift constant must follow the contract version (`info.version`).
    func testApiContractVersionMatchesContract() throws {
        let document = try Contract.load()
        let info = try XCTUnwrap(document["info"] as? [String: Any])
        XCTAssertEqual(info["version"] as? String, apiContractVersion)
    }
}
