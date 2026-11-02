import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

/// Regression tests for the SEC-A package (security review 2026-11-01: SEC-02, SEC-03, SEC-04, SEC-08, SEC-15).
final class AuthHardeningTests: XCTestCase, @unchecked Sendable {
    static let mailEnvironment = ["SMTP_HOST": "mail.test", "SMTP_FROM": "sender@example.test"]

    func withApp(environment: [String: String] = [:], mail: (any MailSender)? = nil,
                 _ run: (Application, AuthService) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        app.logger.logLevel = .critical
        let config = try Configuration(environment: ["SQLITE_PATH": ":memory:"].merging(environment) { _, new in new })
        do {
            try await configure(app, configuration: config, mailSender: mail)
            try await app.autoMigrate()
            try await run(app, AuthService(configuration: config, mailSender: mail))
            try await app.autoRevert()
        } catch { try await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }
    func registered(_ service: AuthService, db: any Database, handle: String = "admin") async throws -> (AuthContext, SoftwareAuthenticator) {
        let invite = try await service.createInvitation(.init(), context: nil, bootstrap: true, on: db)
        let options = try await service.registrationOptions(.init(inviteToken: invite.token!, handle: handle, displayName: "Test", email: nil), on: db)
        let device = SoftwareAuthenticator()
        return (try await service.register(device.registration(options), on: db), device)
    }
    func expect(_ code: String, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(code)", file: file, line: line) }
        catch let error as APIError { XCTAssertEqual(error.code, code, file: file, line: line) }
        catch { XCTFail("Unexpected error: \(type(of: error))", file: file, line: line) }
    }
    /// Gives the account a verified address directly (the code flow is covered by other tests).
    func verifiedEmail(_ context: AuthContext, _ address: String = "owner@example.test", on db: any Database) async throws {
        let found = try await Account.find(context.account.requireID(), on: db)
        let account = try XCTUnwrap(found)
        account.email = address; account.emailVerifiedAt = Date(); try await account.update(on: db)
    }
    /// A recovery session obtained with a recovery code.
    func recovered(_ service: AuthService, codes: [String], handle: String = "admin", on db: any Database) async throws -> AuthContext {
        let start = try await service.recoveryStart(.init(method: .recoveryCode, identifier: handle), on: db)
        return try await service.recoveryComplete(.init(recoveryId: start.recoveryId, proof: codes[0]), on: db)
    }

    // MARK: SEC-02

    func testRecoveryPromotionEndsOtherSessionsGrantsAndTokensAndNotifies() async throws {
        let mail = RecordingMailSender()
        try await withApp(environment: Self.mailEnvironment, mail: mail) { app, service in
            let (owner, _) = try await registered(service, db: app.db)
            try await verifiedEmail(owner, on: app.db)
            let accountID = try owner.account.requireID()
            let codes = try await service.recoveryCodes(owner, generate: true, on: app.db)
            // Material an attacker could hold: a second session, an API token, an OAuth grant, a device token.
            let attacker = try await service.issueSession(for: owner.account, on: app.db)
            let token = ApiTokenRecord(); token.accountId = accountID; token.name = "mcp"; token.scopes = ["time:read"]
            token.tokenHash = Secrets.hash("x"); token.createdAt = Date(); token.expiresAt = Date().addingTimeInterval(3600); try await token.create(on: app.db)
            let client = OAuthClient(); client.name = "c"; client.redirectURIs = ["https://c.example/cb"]; client.createdAt = Date(); try await client.create(on: app.db)
            let grant = OAuthGrant(); grant.accountId = accountID; grant.clientId = try client.requireID(); grant.scopes = ["time:read"]; grant.createdAt = Date(); try await grant.create(on: app.db)

            let recovery = try await recovered(service, codes: codes, on: app.db)
            // Proving the recovery alone changes nothing yet (the owner may only be testing); the notice goes out.
            _ = try await service.authenticate(attacker.token, on: app.db)
            let early = await mail.noticeKinds()
            XCTAssertEqual(early, [.recoveryCompleted])

            let options = try await service.addOptions(recovery, on: app.db)
            _ = try await service.addPasskey(SoftwareAuthenticator().registration(options), context: recovery, on: app.db)

            await expect("unauthorized") { _ = try await service.authenticate(attacker.token, on: app.db) }
            await expect("unauthorized") { _ = try await service.authenticate(owner.token, on: app.db) }
            let current = try await service.authenticate(recovery.token, on: app.db)
            XCTAssertFalse(current.session.recovery)
            let tokenRevoked = try await ApiTokenRecord.query(on: app.db).first()?.revokedAt
            XCTAssertNotNil(tokenRevoked)
            let grantRevoked = try await OAuthGrant.find(grant.requireID(), on: app.db)?.revokedAt
            XCTAssertNotNil(grantRevoked)
            let actions = try await AccountAuditRecord.query(on: app.db).all().map(\.action)
            XCTAssertTrue(actions.contains("recovery.completed")); XCTAssertTrue(actions.contains("recovery.credentials_revoked"))
            let kinds = await mail.noticeKinds()
            XCTAssertEqual(kinds, [.recoveryCompleted, .recoveryFinished])
        }
    }

    func testPasskeyRevocationEndsOtherSessionsButNotTheCurrentOne() async throws {
        let mail = RecordingMailSender()
        try await withApp(environment: Self.mailEnvironment, mail: mail) { app, service in
            let (owner, _) = try await registered(service, db: app.db)
            try await verifiedEmail(owner, on: app.db)
            let second = try await service.issueSession(for: owner.account, on: app.db)
            let options = try await service.addOptions(owner, on: app.db)
            let added = try await service.addPasskey(SoftwareAuthenticator().registration(options), context: owner, on: app.db)
            // Adding is not a recovery: nothing is revoked.
            _ = try await service.authenticate(second.token, on: app.db)
            _ = try await service.changePasskey(added.id, name: nil, context: owner, on: app.db)
            await expect("unauthorized") { _ = try await service.authenticate(second.token, on: app.db) }
            _ = try await service.authenticate(owner.token, on: app.db)
            let actions = try await AccountAuditRecord.query(on: app.db).all().map(\.action)
            XCTAssertTrue(actions.contains("passkey.revoked"))
            let kinds = await mail.noticeKinds()
            XCTAssertEqual(kinds, [.passkeyRevoked])
        }
    }

    // MARK: SEC-03

    func testFallbackPasswordPolicy() {
        let ok = { FallbackPasswordPolicy.acceptable($0, handle: "admin", displayName: "Test User", email: "owner@example.test") }
        XCTAssertTrue(ok("violet anvil harbour tangent 42"))
        XCTAssertFalse(ok("short"))
        XCTAssertFalse(ok("ababab cdcdcd efef"), "18 characters but only 7 distinct")
        XCTAssertFalse(ok("correct horse battery staple"), "well-known phrase")
        XCTAssertFalse(ok("Correct-Horse-Battery-Staple"), "normalisation ignores case and separators")
        XCTAssertFalse(ok("aaaaaaaaaaaaaaaaaaaa"))
        XCTAssertFalse(ok("abcdabcdabcdabcdabcd"), "repeated unit")
        XCTAssertFalse(ok("abcdefghijklmnopqrstuvw"), "consecutive run")
        XCTAssertFalse(ok("my admin passphrase 2026"), "contains the handle")
        XCTAssertFalse(ok("owner and the long tail"), "contains the e-mail local part")
        XCTAssertFalse(ok(String(repeating: "x7Qk", count: 80) + "extra-extra-extra-extra-extra-extra-extra-extra-extra-extra-extra"), "over 256 characters")
    }

    func testFallbackPasswordRejectionCodes() async throws {
        try await withApp { app, service in
            let (context, _) = try await registered(service, db: app.db)
            await expect("bad_request") { try await service.fallbackPassword("shorter than 16", context: context, on: app.db) }
            await expect("weak_password") { try await service.fallbackPassword("correct horse battery staple", context: context, on: app.db) }
            await expect("weak_password") { try await service.fallbackPassword("my admin passphrase 2026", context: context, on: app.db) }
            try await service.fallbackPassword("violet anvil harbour tangent 42", context: context, on: app.db)
        }
    }

    func testFiveWrongProofsLockTheHandleWithBackoffAndWithoutOracle() async throws {
        let mail = RecordingMailSender()
        try await withApp(environment: Self.mailEnvironment, mail: mail) { app, service in
            let (owner, _) = try await registered(service, db: app.db)
            try await verifiedEmail(owner, on: app.db)
            let codes = try await service.recoveryCodes(owner, generate: true, on: app.db)
            func fail(_ handle: String) async throws {
                let start = try await service.recoveryStart(.init(method: .recoveryCode, identifier: handle), on: app.db)
                await expect("unauthorized") { _ = try await service.recoveryComplete(.init(recoveryId: start.recoveryId, proof: "wrong"), on: app.db) }
            }
            // The known and an unknown handle behave identically.
            for handle in ["admin", "nobody"] {
                for _ in 0..<5 { try await fail(handle) }
                await expect("too_many_requests") { _ = try await service.recoveryStart(.init(method: .recoveryCode, identifier: handle), on: app.db) }
            }
            // Even the correct code is refused while the lock holds.
            try await RecoveryLockout.query(on: app.db).filter(\.$key == RecoveryLockPolicy.handleKey("admin")).set(\.$lockedUntil, to: Date().addingTimeInterval(-1)).update()
            let start = try await service.recoveryStart(.init(method: .recoveryCode, identifier: "admin"), on: app.db)
            try await RecoveryLockout.query(on: app.db).filter(\.$key == RecoveryLockPolicy.handleKey("admin")).set(\.$lockedUntil, to: Date().addingTimeInterval(60)).update()
            await expect("too_many_requests") { _ = try await service.recoveryComplete(.init(recoveryId: start.recoveryId, proof: codes[0]), on: app.db) }
            // Backoff doubles: the sixth failure locks for two minutes.
            try await RecoveryLockout.query(on: app.db).filter(\.$key == RecoveryLockPolicy.handleKey("admin")).set(\.$lockedUntil, to: nil).update()
            try await fail("admin")
            let found = try await RecoveryLockout.query(on: app.db).filter(\.$key == RecoveryLockPolicy.handleKey("admin")).first()
            let row = try XCTUnwrap(found)
            XCTAssertEqual(row.failures, 6)
            let seconds = try XCTUnwrap(row.lockedUntil).timeIntervalSinceNow
            XCTAssertTrue((100...121).contains(seconds), "lock was \(seconds)s")
            // The owner is told at the start of the lock; a correct proof after the lock clears the counter.
            let kinds = await mail.noticeKinds()
            XCTAssertEqual(kinds.filter { $0 == .recoveryFailures }.count, 1)
            try await RecoveryLockout.query(on: app.db).filter(\.$key == RecoveryLockPolicy.handleKey("admin")).set(\.$lockedUntil, to: nil).update()
            _ = try await service.recoveryComplete(.init(recoveryId: start.recoveryId, proof: codes[0]), on: app.db)
            let remaining = try await RecoveryLockout.query(on: app.db).filter(\.$key == RecoveryLockPolicy.handleKey("admin")).first()
            XCTAssertNil(remaining)
        }
    }

    func testClientAddressLockSpansHandles() async throws {
        try await withApp { app, service in
            _ = try await registered(service, db: app.db)
            for index in 0..<20 {
                let start = try await service.recoveryStart(.init(method: .recoveryCode, identifier: "user\(index)"), ip: "203.0.113.7", on: app.db)
                await expect("unauthorized") { _ = try await service.recoveryComplete(.init(recoveryId: start.recoveryId, proof: "x"), ip: "203.0.113.7", on: app.db) }
            }
            await expect("too_many_requests") { _ = try await service.recoveryStart(.init(method: .recoveryCode, identifier: "fresh"), ip: "203.0.113.7", on: app.db) }
            _ = try await service.recoveryStart(.init(method: .recoveryCode, identifier: "fresh"), ip: "203.0.113.8", on: app.db)
        }
    }

    // MARK: SEC-04

    func testRecoveryMailIsLimitedPerAccountAndAnswerStaysUniform() async throws {
        let mail = RecordingMailSender()
        try await withApp(environment: Self.mailEnvironment, mail: mail) { app, service in
            let (owner, _) = try await registered(service, db: app.db)
            try await verifiedEmail(owner, on: app.db)
            try await EmailRecovery(accountId: owner.account.requireID(), email: "owner@example.test", verifiedAt: Date(), active: true).create(on: app.db)
            for _ in 0..<4 { _ = try await service.recoveryStart(.init(method: .email, identifier: "admin"), on: app.db) }
            let first = await mail.codeCount()
            XCTAssertEqual(first, 1, "one mail per minute and account; the others are answered but not sent")
            // Over HTTP the answer has the same status and shape for a known and an unknown handle.
            var shapes: [String] = []
            for handle in ["admin", "nobody"] {
                try await app.test(.POST, "/api/v1/auth/recovery/start", beforeRequest: { try $0.content.encode(RecoveryStart(method: .email, identifier: handle)) }, afterResponse: { response async throws in
                    let object = try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]
                    shapes.append("\(response.status.code):\((object?.keys.sorted() ?? []).joined(separator: ","))")
                })
            }
            XCTAssertEqual(shapes[0], shapes[1])
            // After the cooldown the hourly budget (5) still applies.
            for _ in 0..<6 {
                try await MailQuotaEvent.query(on: app.db).filter(\.$key == "mail:recovery:" + owner.account.requireID().uuidString).delete()
                _ = try await service.recoveryStart(.init(method: .email, identifier: "admin"), on: app.db)
            }
            let total = await mail.codeCount()
            XCTAssertEqual(total, 5)
        }
    }

    func testRecoveryStartDoesNotWaitForTheMail() async throws {
        actor Slow: MailSender {
            func sendCode(_ code: String, to address: String) async throws { try await Task.sleep(nanoseconds: 1_500_000_000) }
            func sendNotice(_ notice: SecurityNotice, to address: String) async throws {}
        }
        try await withApp(environment: Self.mailEnvironment, mail: Slow()) { app, service in
            let (owner, _) = try await registered(service, db: app.db)
            try await verifiedEmail(owner, on: app.db)
            try await EmailRecovery(accountId: owner.account.requireID(), email: "owner@example.test", verifiedAt: Date(), active: true).create(on: app.db)
            let started = Date()
            _ = try await service.recoveryStart(.init(method: .email, identifier: "admin"), on: app.db)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
            await MailOutbox.shared.drain()
        }
    }

    // MARK: SEC-08

    func testEmailChangeMailIsLimitedPerAccountAndPerAddress() async throws {
        let mail = RecordingMailSender()
        try await withApp(environment: Self.mailEnvironment, mail: mail) { app, service in
            let (owner, _) = try await registered(service, db: app.db)
            for index in 0..<5 { try await service.requestEmailChange("target\(index)@example.test", context: owner, on: app.db) }
            await expect("too_many_requests") { try await service.requestEmailChange("target9@example.test", context: owner, on: app.db) }
            let sent = await mail.codeCount()
            XCTAssertEqual(sent, 5)
            // The per-address budget protects a third party across accounts.
            try await MailQuotaEvent.query(on: app.db).filter(\.$key == "mail:acct:" + owner.account.requireID().uuidString).delete()
            for _ in 0..<4 {
                _ = try await MailQuotaEvent(key: "mail:addr:" + Secrets.hash("victim@example.test"), sentAt: Date()).create(on: app.db)
            }
            try await service.requestEmailChange("victim@example.test", context: owner, on: app.db)
            await expect("too_many_requests") { try await service.requestEmailChange("victim@example.test", context: owner, on: app.db) }
        }
    }

    func testServerWideMailBudget() async throws {
        try await withApp(environment: Self.mailEnvironment, mail: RecordingMailSender()) { app, service in
            let (owner, _) = try await registered(service, db: app.db)
            for _ in 0..<MailQuota.globalPerHour { try await MailQuotaEvent(key: "mail:global", sentAt: Date()).create(on: app.db) }
            await expect("too_many_requests") { try await service.requestEmailChange("someone@example.test", context: owner, on: app.db) }
        }
    }

    // MARK: SEC-15

    func testIdleSessionEnds() async throws {
        try await withApp(environment: ["SESSION_IDLE_HOURS": "24"]) { app, service in
            let (context, _) = try await registered(service, db: app.db)
            _ = try await service.authenticate(context.token, on: app.db)
            try await Session.query(on: app.db).set(\.$lastSeenAt, to: Date().addingTimeInterval(-23 * 3600)).update()
            _ = try await service.authenticate(context.token, on: app.db)
            try await Session.query(on: app.db).set(\.$lastSeenAt, to: Date().addingTimeInterval(-25 * 3600)).update()
            await expect("unauthorized") { _ = try await service.authenticate(context.token, on: app.db) }
        }
    }

    func testIdleDefaultsAndMigrationIsRepeatable() async throws {
        try await withApp { app, _ in
            let idle = try Configuration(environment: ["SQLITE_PATH": ":memory:"]).sessionIdleHours
            XCTAssertEqual(idle, 336)
            XCTAssertThrowsError(try Configuration(environment: ["SQLITE_PATH": ":memory:", "SESSION_IDLE_HOURS": "0"]))
            // Running the column migration again must not fail (columns are only added when missing).
            try await AddRecoveryAttemptLockKey().prepare(on: app.db)
            try await CreateRecoveryLockouts().prepare(on: app.db)
            try await CreateMailQuotaEvents().prepare(on: app.db)
        }
    }

    func testSecurityNoticeTemplatesAreGermanAndEscaped() {
        for notice in [SecurityNotice.recoveryCompleted, .recoveryFailures, .recoveryFinished, .passkeyRevoked] {
            let mail = MailTemplates.securityNotice(notice, brand: MailBrand(productName: "A<b>", operatorName: nil, baseURL: URL(string: "https://timetrack.example.org")))
            XCTAssertFalse(mail.subject.isEmpty)
            XCTAssertFalse(mail.html.contains("A<b>"))
            XCTAssertFalse(mail.text.contains("{code}"))
        }
    }
}
