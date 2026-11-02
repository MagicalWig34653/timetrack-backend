import XCTest
import Crypto
@testable import TimetrackKit

/// ENV-STACK: empty == unset, placeholder == unset, `<FEATURE>_ENABLED` matrix, no secret values in messages.
final class FeatureSwitchTests: XCTestCase {
    private let secret = "super-secret-value-123"
    private var apnsKey: String { P256.Signing.PrivateKey().pemRepresentation }
    private var vapidKey: String { P256.Signing.PrivateKey().rawRepresentation.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }

    private let smtp = ["SMTP_HOST": "smtp.example.test", "SMTP_FROM": "noreply@example.test", "SMTP_USER": "user@example.test", "SMTP_PASSWORD": "super-secret-value-123"]
    private let oidc = ["OIDC_ISSUER": "https://id.example.test/app/", "OIDC_CLIENT_ID": "timetrack", "OIDC_CLIENT_SECRET": "super-secret-value-123"]
    private func apns() -> [String: String] { ["APNS_PRIVATE_KEY": apnsKey, "APNS_KEY_ID": "ABCDE12345", "APNS_TEAM_ID": "ABCDE12345", "APNS_BUNDLE_IDS": "com.example.timetrack"] }
    private func vapid() -> [String: String] { ["VAPID_PRIVATE_KEY": vapidKey, "VAPID_SUBJECT": "mailto:admin@example.test"] }

    private let allKeys = ["DATABASE_DRIVER", "DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_TLS", "DB_POOL_CONNECTIONS_PER_LOOP", "DB_POOL_TIMEOUT_SECONDS",
                           "DB_KEEPALIVE_SECONDS", "SQLITE_PATH", "AUTO_MIGRATE", "PUBLIC_BASE_URL", "WEBAUTHN_RP_ID", "WEBAUTHN_RP_NAME", "WEBAUTHN_ORIGIN",
                           "APPLE_APP_IDS", "APPLE_APP_IDS_ENABLED", "SESSION_TTL_HOURS", "SESSION_IDLE_HOURS", "HSTS_MAX_AGE_SECONDS", "PWA_STATIC_DIR", "PWA_CSP_MODE",
                           "SMTP_ENABLED", "SMTP_HOST", "SMTP_PORT", "SMTP_TLS", "SMTP_FROM", "SMTP_FROM_NAME", "SMTP_USER", "SMTP_PASSWORD",
                           "OIDC_ENABLED", "OIDC_ISSUER", "OIDC_CLIENT_ID", "OIDC_CLIENT_SECRET", "OIDC_NAME", "OIDC_SCOPES", "TRUSTED_PROXY_CIDRS", "TRUSTED_PROXY_HEADER",
                           "MODULES_DISABLED", "APNS_ENABLED", "APNS_PRIVATE_KEY", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_BUNDLE_IDS", "WEB_PUSH_ENABLED",
                           "VAPID_PRIVATE_KEY", "VAPID_SUBJECT", "PUSH_ALLOWED_HOSTS", "NOTIFICATIONS_ENABLED", "MAINTENANCE_INTERVAL_MINUTES", "MCP_AUDIT_RETENTION_DAYS",
                           "GROUPS_RETENTION_DAYS", "IMPORT_JOB_TIMEOUT_HOURS", "STORAGE_ORPHAN_GRACE_HOURS", "STORAGE_SECRET_KEY", "STORAGE_LOCAL_ROOT"]

    func testEmptyEqualsUnsetForEveryVariable() throws {
        let empty = Dictionary(uniqueKeysWithValues: allKeys.map { ($0, "") })
        let blank = Dictionary(uniqueKeysWithValues: allKeys.map { ($0, "  ") })
        for env in [empty, blank] {
            let config = try Configuration(environment: env)
            let defaults = try Configuration(environment: [:])
            XCTAssertEqual(config.dbPort, defaults.dbPort)
            XCTAssertEqual(config.sessionTTLHours, defaults.sessionTTLHours)
            XCTAssertEqual(config.webAuthnRPID, defaults.webAuthnRPID)
            XCTAssertNil(config.smtp); XCTAssertNil(config.oidc); XCTAssertNil(config.smtpHost)
            XCTAssertEqual(config.appleAppIDs, [])
            XCTAssertEqual(try MaintenanceOptions(environment: env).intervalMinutes, 60)
            let features = try NotificationFeatures.evaluate(environment: NotificationOptions(environment: env).environment)
            XCTAssertNil(features.vapid); XCTAssertNil(features.apns); XCTAssertTrue(features.warnings.isEmpty)
        }
        // MariaDB: an empty password stays allowed (local setups), an empty host falls back to the default.
        XCTAssertEqual(try Configuration(environment: ["DATABASE_DRIVER": "mariadb", "DB_PASSWORD": "", "DB_HOST": ""]).dbHost, "127.0.0.1")
    }

    func testPlaceholderEqualsUnset() throws {
        let marker = EnvironmentSanitizer.placeholderMarker
        XCTAssertNil(try Configuration(environment: ["SMTP_HOST": marker]).smtp)
        let config = try Configuration(environment: oidc.merging(["OIDC_CLIENT_SECRET": marker]) { $1 })
        XCTAssertNil(try XCTUnwrap(config.oidc).clientSecret)
        // SMTP with user but only a placeholder password: clear error, no secret.
        XCTAssertThrowsError(try Configuration(environment: smtp.merging(["SMTP_PASSWORD": marker]) { $1 })) { error in
            XCTAssertTrue(String(describing: error).contains("SMTP_USER"))
        }
        let features = try NotificationFeatures.evaluate(environment: EnvironmentSanitizer.sanitized(vapid().merging(["VAPID_PRIVATE_KEY": marker]) { $1 }))
        XCTAssertNil(features.vapid)
        XCTAssertNil(try NotificationFeatures.evaluate(environment: EnvironmentSanitizer.sanitized(apns().merging(["APNS_PRIVATE_KEY": marker]) { $1 })).apns)
    }

    func testSMTPMatrix() throws {
        XCTAssertNotNil(try Configuration(environment: smtp).smtp)                                              // auto, complete: on
        XCTAssertNotNil(try Configuration(environment: smtp.merging(["SMTP_ENABLED": "TRUE"]) { $1 }).smtp)
        XCTAssertNil(try Configuration(environment: ["SMTP_ENABLED": "auto"]).smtp)                             // auto, empty: off
        XCTAssertNil(try Configuration(environment: smtp.merging(["SMTP_ENABLED": "false"]) { $1 }).smtp)       // false forces off
        XCTAssertNil(try Configuration(environment: ["SMTP_ENABLED": "false", "SMTP_HOST": "bad host/x"]).smtp)  // ... without validating the rest
        XCTAssertThrowsError(try Configuration(environment: ["SMTP_ENABLED": "true"])) { XCTAssertTrue("\($0)".contains("SMTP_HOST")) }
        XCTAssertThrowsError(try Configuration(environment: ["SMTP_HOST": "smtp.example.test"]))                // auto, partial: error as before
        XCTAssertThrowsError(try Configuration(environment: ["SMTP_ENABLED": "yes"])) { XCTAssertTrue("\($0)".contains("SMTP_ENABLED")) }
        let on = try Configuration(environment: smtp.merging(["SMTP_PORT": ""]) { $1 })
        XCTAssertEqual(on.smtpPort, 587)
    }

    func testOIDCMatrix() throws {
        XCTAssertNotNil(try Configuration(environment: oidc).oidc)
        XCTAssertNil(try Configuration(environment: oidc.merging(["OIDC_ENABLED": "false"]) { $1 }).oidc)
        XCTAssertNil(try Configuration(environment: [:]).oidc)
        XCTAssertThrowsError(try Configuration(environment: ["OIDC_ENABLED": "true"])) { XCTAssertTrue("\($0)".contains("OIDC_ISSUER")) }
        XCTAssertThrowsError(try Configuration(environment: ["OIDC_ISSUER": "https://id.example.test/"]))   // half set stays an error
        XCTAssertThrowsError(try Configuration(environment: ["OIDC_ENABLED": "true", "OIDC_CLIENT_ID": "x"]))
    }

    func testAppleAppIDsMatrix() throws {
        let ids = ["APPLE_APP_IDS": "ABCDE12345.com.example.timetrack"]
        XCTAssertEqual(try Configuration(environment: ids).appleAppIDs.count, 1)
        XCTAssertEqual(try Configuration(environment: ids.merging(["APPLE_APP_IDS_ENABLED": "false"]) { $1 }).appleAppIDs, [])
        XCTAssertEqual(try Configuration(environment: [:]).appleAppIDs, [])
        XCTAssertThrowsError(try Configuration(environment: ["APPLE_APP_IDS_ENABLED": "true"])) { XCTAssertTrue("\($0)".contains("APPLE_APP_IDS")) }
    }

    func testAPNsAndWebPushMatrix() throws {
        func run(_ env: [String: String]) throws -> NotificationFeatures { try NotificationFeatures.evaluate(environment: EnvironmentSanitizer.sanitized(env)) }
        XCTAssertNotNil(try run(apns()).apns)
        XCTAssertNil(try run(apns().merging(["APNS_ENABLED": "false"]) { $1 }).apns)
        XCTAssertTrue(try run(apns().merging(["APNS_ENABLED": "false"]) { $1 }).apnsEnvironment.isEmpty)
        XCTAssertNil(try run([:]).apns)
        // auto + incomplete: warning naming the variable, no error
        var partial = apns(); partial["APNS_TEAM_ID"] = ""
        let warned = try run(partial)
        XCTAssertNil(warned.apns); XCTAssertTrue(warned.warnings.joined().contains("APNS_TEAM_ID"))
        // true + incomplete or nothing: error naming variables
        XCTAssertThrowsError(try run(partial.merging(["APNS_ENABLED": "true"]) { $1 })) { XCTAssertTrue("\($0)".contains("APNS_TEAM_ID")) }
        XCTAssertThrowsError(try run(["APNS_ENABLED": "true"])) { XCTAssertTrue("\($0)".contains("APNS_PRIVATE_KEY")) }
        XCTAssertNotNil(try run(apns().merging(["APNS_ENABLED": "true"]) { $1 }).apns)
        // Web Push
        XCTAssertNotNil(try run(vapid()).vapid)
        XCTAssertNil(try run(vapid().merging(["WEB_PUSH_ENABLED": "false"]) { $1 }).vapid)
        XCTAssertNil(try run(["VAPID_SUBJECT": "mailto:admin@example.test"]).vapid)
        XCTAssertFalse(try run(["VAPID_SUBJECT": "mailto:admin@example.test"]).warnings.isEmpty)
        XCTAssertThrowsError(try run(["WEB_PUSH_ENABLED": "true", "VAPID_SUBJECT": "mailto:admin@example.test"])) { XCTAssertTrue("\($0)".contains("VAPID_PRIVATE_KEY")) }
        XCTAssertThrowsError(try run(["WEB_PUSH_ENABLED": "maybe"]))
        // reminder runner status
        XCTAssertEqual(try run(["NOTIFICATIONS_ENABLED": "false"]).statuses.last?.enabled, false)
        XCTAssertEqual(try run(["NOTIFICATIONS_ENABLED": ""]).statuses.last?.enabled, true)
    }

    func testNoSecretValuesInStatusLinesOrErrors() throws {
        var env = smtp.merging(oidc) { $1 }
        env.merge(apns()) { $1 }; env.merge(vapid()) { $1 }
        env["STORAGE_SECRET_KEY"] = secret
        let config = try Configuration(environment: env)
        let features = try NotificationFeatures.evaluate(environment: EnvironmentSanitizer.sanitized(env))
        let text = FeatureSummary.lines(config.featureStatuses + features.statuses).joined(separator: "\n") + features.warnings.joined()
        for needle in [secret, env["APNS_PRIVATE_KEY"]!, env["VAPID_PRIVATE_KEY"]!, "BEGIN PRIVATE KEY"] { XCTAssertFalse(text.contains(needle)) }
        XCTAssertTrue(text.contains("feature SMTP: ON")); XCTAssertTrue(text.contains("feature OIDC: ON")); XCTAssertTrue(text.contains("feature APNs: ON"))
        // error messages
        var broken = env; broken["APNS_KEY_ID"] = "bad"; broken["APNS_ENABLED"] = "true"
        XCTAssertThrowsError(try NotificationFeatures.evaluate(environment: EnvironmentSanitizer.sanitized(broken))) { error in
            XCTAssertFalse("\(error)".contains(self.secret)); XCTAssertFalse("\(error)".contains("BEGIN"))
        }
        XCTAssertThrowsError(try Configuration(environment: env.merging(["SMTP_FROM": "not-an-address"]) { $1 })) { XCTAssertFalse("\($0)".contains(self.secret)) }
    }
}

private extension Dictionary {
    func merging(_ other: [Key: Value]) -> [Key: Value] { merging(other) { _, new in new } }
}
