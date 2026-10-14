import XCTest
@testable import TimetrackKit

final class ConfigurationTests: XCTestCase {
    func testDefaults() throws {
        let config = try Configuration(environment: [:])
        XCTAssertEqual(config.databaseDriver, .sqlite)
        XCTAssertEqual(config.sqlitePath, "timetrack.sqlite")
        XCTAssertEqual(config.dbTLS, .required)
        XCTAssertFalse(config.autoMigrate)
        XCTAssertEqual(config.sessionTTLHours, 720)
    }

    func testOverrides() throws {
        let config = try Configuration(environment: [
            "DATABASE_DRIVER": "mariadb", "DB_HOST": "db", "DB_PORT": "13306",
            "DB_NAME": "test", "DB_USER": "tester", "DB_PASSWORD": "", "DB_TLS": "off",
            "SQLITE_PATH": ":memory:", "WEBAUTHN_RP_ID": "example.com", "WEBAUTHN_RP_NAME": "Example",
            "WEBAUTHN_ORIGIN": "https://auth.example.com", "PUBLIC_BASE_URL": "https://example.com/app",
            "SESSION_TTL_HOURS": "24", "AUTO_MIGRATE": "true"
        ])
        XCTAssertEqual(config.dbPort, 13306)
        XCTAssertEqual(config.dbTLS, .off)
        XCTAssertEqual(config.webAuthnRPID, "example.com")
        XCTAssertTrue(config.autoMigrate)
    }

    func testInvalidConfigurationAndSecretRedaction() {
        let invalid = ["DATABASE_DRIVER": "postgres", "DB_PORT": "65536", "DB_TLS": "maybe",
                       "DB_HOST": "", "SQLITE_PATH": " ", "SESSION_TTL_HOURS": "0", "AUTO_MIGRATE": "1",
                       "WEBAUTHN_RP_ID": "https://localhost", "WEBAUTHN_ORIGIN": "http://evil.test",
                       "PUBLIC_BASE_URL": "https://user:private-secret@example.com"]
        for (key, value) in invalid {
            XCTAssertThrowsError(try Configuration(environment: [key: value])) { error in
                XCTAssertTrue(String(describing: error).contains(key))
                XCTAssertFalse(String(describing: error).contains("private-secret"))
            }
        }
        XCTAssertThrowsError(try Configuration(environment: ["DATABASE_DRIVER": "mariadb"]))
        for port in ["-1", "0", "abc"] {
            XCTAssertThrowsError(try Configuration(environment: ["DB_PORT": port]))
        }
        for origin in ["http://localhost/path", "http://localhost?x=1", "https://other.test"] {
            XCTAssertThrowsError(try Configuration(environment: ["WEBAUTHN_ORIGIN": origin]))
        }
    }
}
