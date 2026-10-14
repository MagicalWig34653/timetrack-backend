import Foundation
import XCTVapor
@testable import TimetrackKit

final class ReadinessTests: XCTestCase, @unchecked Sendable {
    func testUnavailableDatabaseDoesNotBreakHealth() async throws {
        let app = try await Application.make(.testing)
        do {
            let missingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try await configure(app, configuration: Configuration(environment: [
                "SQLITE_PATH": missingDirectory.appendingPathComponent("unavailable.sqlite").path
            ]))
            try await app.test(.GET, "health") { response async throws in
                XCTAssertEqual(response.status, .ok)
            }
            try await app.test(.GET, "ready") { response async throws in
                XCTAssertEqual(response.status, .serviceUnavailable)
                let body = try response.content.decode([String: [String: String]].self)
                XCTAssertEqual(body["error"]?["code"], "not_ready")
                XCTAssertEqual(body["error"]?["message"], "Database unavailable or migrations pending.")
                XCTAssertFalse(response.body.string.contains(missingDirectory.path))
            }
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
