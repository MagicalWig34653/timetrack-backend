import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

final class AuthTests: XCTestCase, @unchecked Sendable {
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
    func registered(_ service: AuthService, db: any Database, handle: String = "admin", admin: AuthContext? = nil) async throws -> (AuthContext, SoftwareAuthenticator) {
        let invite = try await service.createInvitation(.init(), context: admin, bootstrap: admin == nil, on: db)
        let options = try await service.registrationOptions(.init(inviteToken: invite.token!, handle: handle, displayName: "Test", email: nil), on: db)
        let authenticator = SoftwareAuthenticator()
        return (try await service.register(authenticator.registration(options), on: db), authenticator)
    }
    func expect(_ code: String, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(code)", file: file, line: line) }
        catch let error as APIError { XCTAssertEqual(error.code, code, file: file, line: line) }
        catch { XCTFail("Unexpected error: \(type(of: error))", file: file, line: line) }
    }
    func headers(_ context: AuthContext, csrf: Bool = true) -> HTTPHeaders {
        var headers: HTTPHeaders = ["Cookie": "tt_session=\(context.token)"]
        if csrf { headers.add(name: "X-CSRF-Token", value: Secrets.csrf(context.token)) }
        return headers
    }
    func testFullHTTPRegistrationAndLogin() async throws {
        try await withApp { app, service in
            let invite = try await service.createInvitation(.init(), context: nil, bootstrap: true, on: app.db)
            let device = SoftwareAuthenticator()
            let options = try await service.registrationOptions(.init(inviteToken: invite.token!, handle: "admin", displayName: "Administrator", email: nil), on: app.db)
            // RegistrationCredential's upstream encoder omits type, so serialize the browser wire shape explicitly.
            var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(device.registration(options))) as! [String: Any]
            var credential = value["credential"] as! [String: Any]; credential["type"] = "public-key"; value["credential"] = credential
            let body = try JSONSerialization.data(withJSONObject: value)
            try await app.test(.POST, "/api/v1/auth/register/verify", beforeRequest: { req in
                req.headers.contentType = .json; req.body = ByteBuffer(data: body)
            }, afterResponse: { response async throws in
                XCTAssertEqual(response.status, .created)
                let session = try response.content.decode(SessionDTO.self)
                XCTAssertEqual(session.account.role, .admin); XCTAssertFalse(session.recovery)
                let cookie = try unwrap(response.headers.first(name: .setCookie))
                XCTAssertTrue(cookie.contains("HttpOnly")); XCTAssertTrue(cookie.contains("SameSite=Lax"))
                XCTAssertFalse(cookie.contains("Secure"))
                XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
            })
            let account = try unwrap(try await Account.query(on: app.db).first())
            let login = try await service.loginOptions(on: app.db)
            let proof = try device.assertion(login, accountID: account.requireID())
            try await app.test(.POST, "/api/v1/auth/login/verify", beforeRequest: { try $0.content.encode(proof) }, afterResponse: { response async throws in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try response.content.decode(SessionDTO.self).account.handle, "admin")
            })
            await expect("unauthorized") { _ = try await service.login(proof, on: app.db) }
            let keys = try await Passkey.query(on: app.db).all()
            XCTAssertEqual(keys.first?.signCount, 1); XCTAssertNotNil(keys.first?.lastUsedAt)
            let next = try await service.loginOptions(on: app.db)
            await expect("unauthorized") { _ = try await service.login(device.assertion(next, accountID: account.requireID(), count: 1), on: app.db) }
            await expect("unauthorized") { _ = try await service.login(device.assertion(next, accountID: account.requireID(), count: 2, origin: "https://evil.example"), on: app.db) }
            await expect("unauthorized") { _ = try await service.login(device.assertion(next, accountID: account.requireID(), count: 2, flags: 1), on: app.db) }
            _ = try await service.login(device.assertion(next, accountID: account.requireID(), count: 2), on: app.db)
        }
    }
    func testIsolationCSRFRevocationAndFreshness() async throws {
        try await withApp { app, service in
            let (a, _) = try await registered(service, db: app.db)
            let (b, _) = try await registered(service, db: app.db, handle: "member", admin: a)
            let key = try unwrap(try await service.passkeys(a, on: app.db).first)
            for method in [HTTPMethod.PATCH, .DELETE] {
                try await app.test(method, "/api/v1/me/passkeys/\(key.id)", headers: headers(b), beforeRequest: { try $0.content.encode(["name": "Other"]) }, afterResponse: { response async throws in
                    XCTAssertEqual(response.status, .notFound)
                })
            }
            try await app.test(.POST, "/api/v1/me/recovery/recovery-codes", headers: headers(a, csrf: false)) { response async throws in
                XCTAssertEqual(response.status, .forbidden); XCTAssertTrue(response.body.string.contains("csrf_invalid"))
            }
            await expect("last_passkey") { _ = try await service.changePasskey(key.id, name: nil, context: a, on: app.db) }
            let owned = try await service.createInvitation(.init(), context: a, on: app.db)
            await expect("not_found") { try await service.revokeInvitation(owned.id, context: b, on: app.db) }
            b.account.role = .admin; try await b.account.update(on: app.db)
            await expect("not_found") { try await service.revokeInvitation(owned.id, context: b, on: app.db) }
            checkTrue(try await service.invitations(b, on: app.db).isEmpty)
            try await Session.query(on: app.db).filter(\.$id == a.session.requireID()).set(\.$createdAt, to: Date().addingTimeInterval(-601)).update()
            await expect("reauth_required") { _ = try await service.addOptions(a, on: app.db) }
            await expect("reauth_required") { _ = try await service.recoveryCodes(a, generate: true, on: app.db) }
            let another = try await service.issueSession(for: b.account, on: app.db)
            try await service.revokeSessions(b, others: true, on: app.db)
            await expect("unauthorized") { _ = try await service.authenticate(another.token, on: app.db) }
            try await app.test(.DELETE, "/api/v1/auth/session", headers: headers(b)) { response async throws in checkEqual(response.status, .noContent) }
            await expect("unauthorized") { _ = try await service.authenticate(b.token, on: app.db) }
        }
    }
    func testRecoveryCodesRestrictionsUpgradeAndReuse() async throws {
        try await withApp { app, service in
            let (context, _) = try await registered(service, db: app.db)
            let codes = try await service.recoveryCodes(context, generate: true, on: app.db)
            XCTAssertEqual(codes.count, 10)
            let start = try await service.recoveryStart(.init(method: .recoveryCode, identifier: "admin"), on: app.db)
            let proof = RecoveryProof(recoveryId: start.recoveryId, proof: codes[0])
            let recovered = try await service.recoveryComplete(proof, on: app.db)
            XCTAssertTrue(recovered.session.recovery)
            XCTAssertEqual(recovered.session.expiresAt.timeIntervalSince(recovered.session.createdAt), 1800, accuracy: 1)
            await expect("unauthorized") { _ = try await service.recoveryComplete(proof, on: app.db) }
            for (method, path) in [(HTTPMethod.GET, "me/passkeys"), (.GET, "me/recovery"), (.DELETE, "me/sessions"), (.POST, "auth/login/options"), (.GET, "admin/invitations")] {
                try await app.test(method, "/api/v1/" + path, headers: headers(recovered)) { response async throws in
                    XCTAssertEqual(response.status, .forbidden); XCTAssertTrue(response.body.string.contains("recovery_session_restricted"))
                }
            }
            try await app.test(.GET, "/api/v1/auth/session", headers: headers(recovered)) { response async throws in
                XCTAssertEqual(response.status, .ok); XCTAssertTrue(try response.content.decode(SessionDTO.self).recovery)
            }
            let options = try await service.addOptions(recovered, on: app.db)
            let device = SoftwareAuthenticator()
            _ = try await service.addPasskey(device.registration(options), context: recovered, on: app.db)
            let upgraded = try await service.authenticate(recovered.token, on: app.db)
            XCTAssertFalse(upgraded.session.recovery)
            checkEqual(try await service.passkeys(upgraded, on: app.db).count, 2)
            checkEqual(try await service.recoveryStatus(upgraded, on: app.db).recoveryCodes.remaining, 9)
            _ = try await service.recoveryCodes(upgraded, generate: true, on: app.db)
            let next = try await service.recoveryStart(.init(method: .recoveryCode, identifier: "admin"), on: app.db)
            await expect("unauthorized") { _ = try await service.recoveryComplete(.init(recoveryId: next.recoveryId, proof: codes[1]), on: app.db) }
        }
    }
    func testPasswordAndNoMail() async throws {
        try await withApp { app, service in
            let (context, _) = try await registered(service, db: app.db)
            checkFalse(try await service.recoveryStatus(context, on: app.db).email.available)
            await expect("not_implemented") { try await service.enableEmail("test@example.test", context: context, on: app.db) }
            await expect("bad_request") { try await service.fallbackPassword("short", context: context, on: app.db) }
            try await service.fallbackPassword("correct horse battery staple", context: context, on: app.db)
            let stored = try unwrap(try await FallbackPassword.query(on: app.db).first())
            XCTAssertTrue(stored.hash.hasPrefix("$argon2id$v=19$m=65536,t=3,p=1$"))
            let start = try await service.recoveryStart(.init(method: .fallbackPassword, identifier: "admin"), on: app.db)
            await expect("unauthorized") { _ = try await service.recoveryComplete(.init(recoveryId: start.recoveryId, proof: "wrong"), on: app.db) }
            let recovered = try await service.recoveryComplete(.init(recoveryId: start.recoveryId, proof: "correct horse battery staple"), on: app.db)
            XCTAssertTrue(recovered.session.recovery)
            await expect("unauthorized") { _ = try await service.recoveryComplete(.init(recoveryId: start.recoveryId, proof: "correct horse battery staple"), on: app.db) }
            for method in [RecoveryKind.email, .fallbackPassword, .recoveryCode] {
                for identifier in ["admin", "unknown"] {
                    try await app.test(.POST, "/api/v1/auth/recovery/start", beforeRequest: { try $0.content.encode(RecoveryStart(method: method, identifier: identifier)) }, afterResponse: { response async throws in
                        XCTAssertEqual(response.status, .accepted); _ = try response.content.decode(RecoveryStarted.self)
                    })
                }
            }
            try await service.fallbackPassword(nil, context: context, on: app.db)
            checkFalse(try await service.recoveryStatus(context, on: app.db).fallbackPassword.active)
        }
    }
    func testEmailVerificationExpiryAttemptsAndRecovery() async throws {
        let sender = RecordingMailSender()
        try await withApp(environment: ["SMTP_HOST": "mail.test", "SMTP_FROM": "sender@example.test"], mail: sender) { app, service in
            let (context, _) = try await registered(service, db: app.db)
            try await service.enableEmail("user@example.test", context: context, on: app.db)
            let verification = await sender.lastCode()
            await expect("invalid_code") { try await service.verifyEmail("wrong", context: context, on: app.db) }
            try await service.verifyEmail(verification, context: context, on: app.db)
            await expect("invalid_code") { try await service.verifyEmail(verification, context: context, on: app.db) }
            checkTrue(try await service.recoveryStatus(context, on: app.db).email.active)
            let start = try await service.recoveryStart(.init(method: .email, identifier: "admin"), on: app.db)
            let code = await sender.lastCode()
            let proof = RecoveryProof(recoveryId: start.recoveryId, proof: code)
            _ = try await service.recoveryComplete(proof, on: app.db)
            await expect("unauthorized") { _ = try await service.recoveryComplete(proof, on: app.db) }
            let expired = try await service.recoveryStart(.init(method: .email, identifier: "admin"), on: app.db)
            let expiredCode = await sender.lastCode()
            try await RecoveryAttempt.query(on: app.db).filter(\.$id == expired.recoveryId).set(\.$expiresAt, to: Date().addingTimeInterval(-1)).update()
            await expect("unauthorized") { _ = try await service.recoveryComplete(.init(recoveryId: expired.recoveryId, proof: expiredCode), on: app.db) }
            let limited = try await service.recoveryStart(.init(method: .email, identifier: "admin"), on: app.db)
            let correct = await sender.lastCode()
            for _ in 0..<5 { await expect("unauthorized") { _ = try await service.recoveryComplete(.init(recoveryId: limited.recoveryId, proof: "wrong"), on: app.db) } }
            await expect("unauthorized") { _ = try await service.recoveryComplete(.init(recoveryId: limited.recoveryId, proof: correct), on: app.db) }
            try await service.enableEmail("new@example.test", context: context, on: app.db)
            await expect("invalid_code") { try await service.verifyEmail(verification, context: context, on: app.db) }
            try await service.disableEmail(context, on: app.db)
            checkFalse(try await service.recoveryStatus(context, on: app.db).email.active)
        }
    }
    func testInvitationAndRecoveryConcurrencySQLite() async throws {
        let path = "/tmp/c2-auth-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await exerciseConcurrency(environment: ["SQLITE_PATH": path])
    }
    func testMariaDBAuthFlowsAndConcurrency() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        try await exerciseConcurrency(environment: ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test", "DB_TLS": "off"])
    }
    func exerciseConcurrency(environment: [String: String]) async throws {
        let mail = RecordingMailSender()
        try await withApp(environment: environment.merging(["SMTP_HOST": "mail.test", "SMTP_FROM": "sender@example.test"]) { _, new in new }, mail: mail) { app, service in
            let invite = try await service.createInvitation(.init(), context: nil, bootstrap: true, on: app.db)
            let connections = (0..<4).map { _ in app.databases.database(logger: app.logger, on: app.eventLoopGroup.next())! }
            let device = SoftwareAuthenticator()
            var pending: [RegisterProof] = []
            for _ in 0..<12 {
                let options = try await service.registrationOptions(.init(inviteToken: invite.token!, handle: "admin", displayName: "Admin", email: nil), on: app.db)
                pending.append(try device.registration(options))
            }
            let proofs = pending
            let successes = await withTaskGroup(of: AuthContext?.self) { group in
                for i in 0..<12 { group.addTask { try? await service.register(proofs[i], on: connections[i % 4]) } }
                var results: [AuthContext] = []
                for await result in group { if let result { results.append(result) } }; return results
            }
            XCTAssertEqual(successes.count, 1)
            let context = try unwrap(successes.first)
            checkEqual(try await Account.query(on: app.db).count(), 1)
            checkEqual(try await Session.query(on: app.db).count(), 1)
            await expect("not_found") { _ = try await service.invitation(invite.token!, on: app.db) }
            await expect("conflict") { _ = try await service.createInvitation(.init(), context: nil, bootstrap: true, on: app.db) }
            let loginOptions = try await service.loginOptions(on: app.db)
            _ = try await service.login(device.assertion(loginOptions, accountID: context.account.requireID()), on: app.db)
            let codes = try await service.recoveryCodes(context, generate: true, on: app.db)
            try await service.fallbackPassword("a long fallback password", context: context, on: app.db)
            try await service.enableEmail("user@example.test", context: context, on: app.db)
            try await service.verifyEmail(mail.lastCode(), context: context, on: app.db)
            for kind in [RecoveryKind.recoveryCode, .email, .fallbackPassword] {
                let start = try await service.recoveryStart(.init(method: kind, identifier: "admin"), on: app.db)
                let secret = kind == .recoveryCode ? codes[0] : kind == .fallbackPassword ? "a long fallback password" : await mail.lastCode()
                let proof = RecoveryProof(recoveryId: start.recoveryId, proof: secret)
                let count = await withTaskGroup(of: Bool.self) { group in
                    for i in 0..<8 { group.addTask { (try? await service.recoveryComplete(proof, on: connections[i % 4])) != nil } }
                    var count = 0; for await success in group { if success { count += 1 } }; return count
                }
                XCTAssertEqual(count, 1)
                let expired = try await service.recoveryStart(.init(method: kind, identifier: "admin"), on: app.db)
                try await RecoveryAttempt.query(on: app.db).filter(\.$id == expired.recoveryId).set(\.$expiresAt, to: Date().addingTimeInterval(-1)).update()
                await expect("unauthorized") { _ = try await service.recoveryComplete(.init(recoveryId: expired.recoveryId, proof: secret), on: app.db) }
            }
        }
    }
    func testInvalidInvitesAndChallengeRollback() async throws {
        try await withApp { app, service in
            let (context, _) = try await registered(service, db: app.db)
            for state in ["expired", "revoked", "used"] {
                let invite = try await service.createInvitation(.init(), context: context, on: app.db)
                let row = try unwrap(try await Invitation.find(invite.id, on: app.db))
                if state == "expired" { row.expiresAt = Date().addingTimeInterval(-1) }
                if state == "revoked" { row.revokedAt = Date() }
                if state == "used" { row.usedAt = Date() }
                try await row.update(on: app.db)
                await expect("not_found") { _ = try await service.registrationOptions(.init(inviteToken: invite.token!, handle: "new-user", displayName: "New", email: nil), on: app.db) }
            }
            let invite = try await service.createInvitation(.init(), context: context, on: app.db)
            await expect("handle_taken") { _ = try await service.registrationOptions(.init(inviteToken: invite.token!, handle: "admin", displayName: "Duplicate", email: nil), on: app.db) }
            let options = try await service.registrationOptions(.init(inviteToken: invite.token!, handle: "new-user", displayName: "New", email: nil), on: app.db)
            let device = SoftwareAuthenticator()
            await expect("bad_request") { _ = try await service.register(device.registration(options, origin: "https://evil.example"), on: app.db) }
            _ = try await service.invitation(invite.token!, on: app.db)
            await expect("bad_request") { _ = try await service.register(device.registration(options, flags: 0x41), on: app.db) }
            _ = try await service.register(device.registration(options), on: app.db)
        }
    }
    func testRateLimitsAndSessionExpiry() async throws {
        try await withApp { app, service in
            for _ in 0..<15 { try await service.limited(ip: "one", handle: "account", on: app.db) }
            await expect("too_many_requests") { try await service.limited(ip: "two", handle: "account", on: app.db) }
            for _ in 0..<60 { try await service.limited(ip: "shared", on: app.db) }
            await expect("too_many_requests") { try await service.limited(ip: "shared", on: app.db) }
            for _ in 0..<60 { try await service.limited(ip: "unknown", on: app.db) }
            try await app.test(.POST, "/api/v1/auth/login/options") { response async throws in checkEqual(response.status, .tooManyRequests) }
            let (context, _) = try await registered(service, db: app.db)
            XCTAssertNotEqual(context.session.tokenHash, context.token)
            XCTAssertNotEqual(context.session.csrfTokenHash, Secrets.csrf(context.token))
            try await Session.query(on: app.db).filter(\.$id == context.session.requireID()).set(\.$expiresAt, to: Date().addingTimeInterval(-1)).update()
            await expect("unauthorized") { _ = try await service.authenticate(context.token, on: app.db) }
        }
    }
    func testStaticServingAndTraversal() async throws {
        let root = URL(fileURLWithPath: "/tmp/c2-pwa-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<html>SPA</html>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("export {};".utf8).write(to: root.appendingPathComponent("app.12345678.js"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: "/etc/passwd")
        try await withApp(environment: ["PWA_STATIC_DIR": root.path]) { app, _ in
            for path in ["/", "/invite/example", "/settings/passkeys"] {
                try await app.test(.GET, path) { response async throws in
                    XCTAssertEqual(response.status, .ok); XCTAssertEqual(response.body.string, "<html>SPA</html>")
                    XCTAssertEqual(response.headers.first(name: .cacheControl), "no-cache")
                    XCTAssertTrue(response.headers.first(name: .contentType)?.contains("text/html") == true)
                }
            }
            try await app.test(.GET, "/app.12345678.js") { response async throws in
                XCTAssertTrue(response.headers.first(name: .cacheControl)?.contains("immutable") == true)
                XCTAssertTrue(response.headers.first(name: .contentType)?.contains("javascript") == true)
            }
            for path in ["/%2e%2e/etc/passwd", "/escape", "/api/missing", "/health/missing", "/ready/missing"] {
                try await app.test(.GET, path) { response async throws in checkEqual(response.status, .notFound) }
            }
        }
    }
}

private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
private func checkEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual, expected, file: file, line: line)
}
private func checkTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value, file: file, line: line) }
private func checkFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(value, file: file, line: line) }
