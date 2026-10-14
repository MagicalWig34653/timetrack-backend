import Foundation
import Fluent
import FluentSQL
import XCTVapor
@testable import TimetrackKit

final class DatabaseTests: XCTestCase, @unchecked Sendable {
    func testSQLiteMemory() async throws {
        try await exerciseDatabase(environment: ["SQLITE_PATH": ":memory:"])
    }

    func testSQLiteFile() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("timetrack-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await exerciseDatabase(environment: ["SQLITE_PATH": path])
    }

    func testMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else {
            throw XCTSkip("MARIADB_TEST_HOST not set; a dedicated disposable database is required")
        }
        try await exerciseDatabase(environment: [
            "DATABASE_DRIVER": "mariadb", "DB_HOST": host,
            "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack",
            "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test", "DB_TLS": "off"
        ])
    }

    private func exerciseDatabase(environment: [String: String]) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, configuration: Configuration(environment: environment))
            try await app.test(.GET, "health") { response async throws in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try response.content.decode(StatusResponse.self).status, "ok")
            }
            try await app.test(.GET, "ready") { response async throws in
                XCTAssertEqual(response.status, .serviceUnavailable)
                XCTAssertTrue(response.body.string.contains("not_ready"))
            }
            try await app.autoMigrate()
            try await app.test(.GET, "ready") { response async throws in XCTAssertEqual(response.status, .ok) }
            try await verifyConstraints(on: app.db)
            let raceConnections: [any Database] = environment["SQLITE_PATH"] == ":memory:" ? [app.db] :
                (0..<4).map { _ in app.databases.database(logger: app.logger, on: app.eventLoopGroup.next())! }
            try await verifyConsumption(on: app.db, raceConnections: raceConnections)
            try await verifyRoundTrips(on: app.db)
            try await app.autoRevert()
            let sql = try requireSQL(app.db)
            for table in ["accounts", "passkeys", "sessions", "invitations", "webauthn_challenges",
                          "recovery_codes", "fallback_passwords", "email_recovery", "recovery_attempts", "rate_limit_events"] {
                do {
                    _ = try await sql.select().column("id").from(table).all()
                    XCTFail("Table survived revert: \(table)")
                } catch {}
            }
            try await app.test(.GET, "ready") { response async throws in XCTAssertEqual(response.status, .serviceUnavailable) }
            // Re-apply to verify that constraints and indexes can be recreated.
            try await app.autoMigrate()
            try await app.test(.GET, "ready") { response async throws in XCTAssertEqual(response.status, .ok) }
            try await app.autoRevert()
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func expectFailure(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected constraint failure", file: file, line: line) }
        catch {}
    }

    private func verifyConstraints(on db: any Database) async throws {
        let now = Date()
        let account = Account(handle: "tester", displayName: "Test 🕰️", role: .member, createdAt: now)
        try await account.create(on: db)
        let id = try account.requireID()
        await expectFailure { try await Account(handle: "tester", displayName: "Other", role: .admin, createdAt: now).create(on: db) }
        await expectFailure { try await Account(handle: "UPPER", displayName: "Other", role: .member, createdAt: now).create(on: db) }
        let key = Data([0, 255, 2, 128])
        func passkey(_ accountID: UUID, _ credential: Data) -> Passkey {
            Passkey(accountId: accountID, credentialId: credential, publicKey: Data([1, 2]), signCount: 0,
                    name: "Key", transports: ["internal"], backedUp: false, createdAt: now)
        }
        try await passkey(id, key).create(on: db)
        await expectFailure { try await passkey(id, key).create(on: db) }
        await expectFailure { try await passkey(UUID(), Data([3])).create(on: db) }
        func session() -> TimetrackKit.Session {
            TimetrackKit.Session(accountId: id, tokenHash: "session-hash", csrfTokenHash: "csrf-hash", recovery: false,
                                 createdAt: now, expiresAt: now.addingTimeInterval(60))
        }
        try await session().create(on: db)
        await expectFailure { try await session().create(on: db) }
        func invitation() -> Invitation {
            Invitation(tokenHash: "invitation-hash", role: .member, createdAt: now, expiresAt: now.addingTimeInterval(60))
        }
        try await invitation().create(on: db)
        await expectFailure { try await invitation().create(on: db) }
        let loaded = try await Account.find(id, on: db)
        XCTAssertEqual(loaded?.displayName, "Test 🕰️")
        XCTAssertEqual(loaded?.createdAt.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 0.001)
    }

    private func verifyConsumption(on db: any Database, raceConnections: [any Database]) async throws {
        let now = Date()
        let invitation = Invitation(tokenHash: "race-hash", role: .member, createdAt: now, expiresAt: now.addingTimeInterval(60))
        try await invitation.create(on: db)
        let id = try invitation.requireID()
        let winners = try await withThrowingTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<24 {
                let connection = raceConnections[index % raceConnections.count]
                group.addTask { try await SingleUse.consume(.invitation, id: id, on: connection) }
            }
            var count = 0
            for try await won in group { if won { count += 1 } }
            return count
        }
        XCTAssertEqual(winners, 1)
        let expired = Invitation(tokenHash: "expired-hash", role: .member, createdAt: now, expiresAt: now)
        try await expired.create(on: db)
        let expiredWon = try await SingleUse.consume(.invitation, id: expired.requireID(), on: db, at: now)
        XCTAssertFalse(expiredWon)
        let revoked = Invitation(tokenHash: "revoked-hash", role: .member, createdAt: now,
                                 expiresAt: now.addingTimeInterval(60), revokedAt: now)
        try await revoked.create(on: db)
        let revokedWon = try await SingleUse.consume(.invitation, id: revoked.requireID(), on: db)
        XCTAssertFalse(revokedWon)
        enum Rollback: Error { case requested }
        let rollback = Invitation(tokenHash: "rollback-hash", role: .member, createdAt: now, expiresAt: now.addingTimeInterval(60))
        try await rollback.create(on: db)
        let rollbackID = try rollback.requireID()
        do {
            try await db.transaction { transaction in
                let won = try await SingleUse.consume(.invitation, id: rollbackID, on: transaction)
                XCTAssertTrue(won)
                throw Rollback.requested
            }
        } catch Rollback.requested {}
        let wonAfterRollback = try await SingleUse.consume(.invitation, id: rollbackID, on: db)
        XCTAssertTrue(wonAfterRollback)
        let missingWon = try await SingleUse.consume(.invitation, id: UUID(), on: db)
        XCTAssertFalse(missingWon)
    }

    private func verifyRoundTrips(on db: any Database) async throws {
        let fetchedAccount = try await Account.query(on: db).first()
        let account = try XCTUnwrap(fetchedAccount)
        let id = try account.requireID()
        let now = Date()
        let code = RecoveryCode(accountId: id, codeHash: "code-hash")
        try await code.create(on: db)
        let challenge = WebAuthnChallenge(purpose: .addPasskey, challenge: Data([255, 0]),
                                         payload: ["nested": .object(["enabled": .bool(true)])], accountId: id,
                                         expiresAt: now.addingTimeInterval(60))
        try await challenge.create(on: db)
        let loaded = try await WebAuthnChallenge.find(challenge.requireID(), on: db)
        XCTAssertEqual(loaded?.payload, challenge.payload)
        XCTAssertEqual(loaded?.challenge, challenge.challenge)
        let attempt = RecoveryAttempt(kind: .email, accountId: id, codeHash: "email-code-hash", proofHash: "proof-hash",
                                      expiresAt: now.addingTimeInterval(60), attemptCount: 0, createdAt: now)
        try await attempt.create(on: db)
        for (resource, resourceID) in [(SingleUse.Resource.recoveryCode, try code.requireID()),
                                       (.challenge, try challenge.requireID()), (.recoveryAttempt, try attempt.requireID())] {
            let first = try await SingleUse.consume(resource, id: resourceID, on: db)
            let second = try await SingleUse.consume(resource, id: resourceID, on: db)
            XCTAssertTrue(first)
            XCTAssertFalse(second)
        }
        try await FallbackPassword(accountId: id, hash: "encoded-password-hash", algorithm: "argon2id", updatedAt: now).create(on: db)
        await expectFailure { try await FallbackPassword(accountId: id, hash: "other", algorithm: "argon2id", updatedAt: now).create(on: db) }
        try await EmailRecovery(accountId: id, email: "test@example.invalid", active: false).create(on: db)
        await expectFailure { try await EmailRecovery(accountId: id, email: "other@example.invalid", active: false).create(on: db) }
        try await RateLimitEvent(key: "test-key", occurredAt: now).create(on: db)
        let count = try await RateLimitEvent.query(on: db).filter(\.$key == "test-key").count()
        XCTAssertEqual(count, 1)
    }
}
