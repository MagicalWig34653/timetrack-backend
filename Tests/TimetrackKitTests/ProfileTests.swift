import Fluent
import FluentSQL
import XCTVapor
@testable import TimetrackKit

/// Package P1: profile editing, e-mail change by verification code and the onboarding flag (ADR-0019).
extension AuthTests {
    static let mailEnvironment = ["SMTP_HOST": "mail.test", "SMTP_FROM": "sender@example.test"]

    func stringField(_ response: XCTHTTPResponse, _ key: String) throws -> String? { try object(response)[key] as? String }

    func profileField(_ app: Application, _ context: AuthContext, _ key: String) async throws -> String? {
        try object(await api(app, context, .GET, "me/profile"))[key] as? String
    }

    func scenarioProfile(_ mail: RecordingMailSender) -> Scenario {
        { app, auth in
            let (admin, _) = try await self.registered(auth, db: app.db)
            let member = try await self.second(app, auth, admin)
            let before = try self.object(await self.api(app, member, .GET, "me/profile"))
            XCTAssertEqual(before["handle"] as? String, "member"); XCTAssertEqual(before["displayName"] as? String, "Test")
            XCTAssertEqual(before["emailVerified"] as? Bool, false); XCTAssertEqual(before["mailAvailable"] as? Bool, true)
            XCTAssertNil(before["email"] as? String)

            // Display name: trimmed, 1...80 characters, handle is not editable.
            try await self.api(app, member, .PATCH, "me/profile", ["displayName": "  "], .badRequest)
            try await self.api(app, member, .PATCH, "me/profile", ["displayName": String(repeating: "x", count: 81)], .badRequest)
            try await self.api(app, member, .PATCH, "me/profile", ["handle": "other"], .badRequest)
            let renamed = try self.object(await self.api(app, member, .PATCH, "me/profile", ["displayName": "  Neuer Name "]))
            XCTAssertEqual(renamed["displayName"] as? String, "Neuer Name"); XCTAssertEqual(renamed["handle"] as? String, "member")
            // Account isolation: the other account is untouched and sees only itself.
            try await self.eq(try await self.profileField(app, admin, "displayName"), "Test")

            // E-mail change needs a fresh session, a valid address and mail delivery.
            try await self.stale(member, on: app.db)
            try await self.api(app, member, .PUT, "me/profile/email", ["email": "neu@example.test"], .forbidden)
            try await self.api(app, member, .DELETE, "me/profile/email", nil, .forbidden)
            let fresh = try await self.freshSession(app, auth, "member")
            try await self.api(app, fresh, .PUT, "me/profile/email", ["email": "not-an-address"], .badRequest)
            try await self.api(app, fresh, .PUT, "me/profile/email", ["email": "Neu@Example.test "], .accepted)
            let pending = try self.object(await self.api(app, fresh, .GET, "me/profile"))
            XCTAssertEqual(pending["pendingEmail"] as? String, "neu@example.test"); XCTAssertNil(pending["email"] as? String)
            let code = await mail.lastCode()
            // Nothing changes until the code is confirmed; the wrong code is refused and counted.
            try await self.api(app, fresh, .POST, "me/profile/email/verify", ["code": "wrong"], .badRequest)
            let verified = try self.object(await self.api(app, fresh, .POST, "me/profile/email/verify", ["code": code]))
            XCTAssertEqual(verified["email"] as? String, "neu@example.test"); XCTAssertEqual(verified["emailVerified"] as? Bool, true)
            XCTAssertNil(verified["pendingEmail"] as? String)
            // A used code cannot be replayed.
            try await self.api(app, fresh, .POST, "me/profile/email/verify", ["code": code], .badRequest)
            try await self.eq(try await self.profileField(app, admin, "email"), nil)

            // Another account cannot take a verified address: 409, and the request is consumed.
            let freshAdmin = try await self.freshSession(app, auth, "admin")
            try await self.api(app, freshAdmin, .PUT, "me/profile/email", ["email": "neu@example.test"], .accepted)
            let taken = await mail.lastCode()
            let conflict = try await self.api(app, freshAdmin, .POST, "me/profile/email/verify", ["code": taken], .conflict)
            XCTAssertEqual(try self.errorCode(conflict), "email_taken")
            try await self.eq(try await self.profileField(app, freshAdmin, "email"), nil)
            // Same address again for the owner: refused, nothing to change.
            try await self.api(app, fresh, .PUT, "me/profile/email", ["email": "neu@example.test"], .badRequest)

            // Attempt limit: five wrong guesses burn the request, even the right code fails afterwards.
            try await self.api(app, fresh, .PUT, "me/profile/email", ["email": "zweit@example.test"], .accepted)
            let burned = await mail.lastCode()
            for _ in 0..<5 { try await self.api(app, fresh, .POST, "me/profile/email/verify", ["code": "nope"], .badRequest) }
            try await self.api(app, fresh, .POST, "me/profile/email/verify", ["code": burned], .badRequest)
            // Expired request.
            try await self.api(app, fresh, .PUT, "me/profile/email", ["email": "zweit@example.test"], .accepted)
            let late = await mail.lastCode()
            try await EmailChangeRequest.query(on: app.db).set(\.$expiresAt, to: Date().addingTimeInterval(-1)).update()
            try await self.api(app, fresh, .POST, "me/profile/email/verify", ["code": late], .badRequest)
            try await self.eq(try await self.profileField(app, fresh, "email"), "neu@example.test")

            // Removal, then the address is free again for the other account.
            try await self.api(app, fresh, .DELETE, "me/profile/email", nil, .noContent)
            let removed = try self.object(await self.api(app, fresh, .GET, "me/profile"))
            XCTAssertNil(removed["email"] as? String); XCTAssertEqual(removed["emailVerified"] as? Bool, false)
            try await self.api(app, freshAdmin, .PUT, "me/profile/email", ["email": "neu@example.test"], .accepted)
            let reused = await mail.lastCode()
            let moved = try self.object(await self.api(app, freshAdmin, .POST, "me/profile/email/verify", ["code": reused]))
            XCTAssertEqual(moved["email"] as? String, "neu@example.test")

            // Recovery sessions may not touch the profile.
            let recovery = try await auth.issueSession(for: member.account, recovery: true, on: app.db)
            for (method, path, body) in [(HTTPMethod.GET, "me/profile", nil), (.PATCH, "me/profile", ["displayName": "X"]), (.PUT, "me/profile/email", ["email": "a@example.test"]),
                                         (.DELETE, "me/profile/email", nil), (.PUT, "me/onboarding", ["state": "completed"])] as [(HTTPMethod, String, [String: Any]?)] {
                try await self.api(app, recovery, method, path, body, .forbidden)
                try await self.timeRequest(app, nil, method, path, body, status: .unauthorized)
            }
            // Audit holds fixed action names and opaque ids only.
            let audit = try await AccountAuditRecord.query(on: app.db).all().filter { $0.action.hasPrefix("profile.") }
            XCTAssertEqual(Set(audit.map(\.action)), ["profile.name_changed", "profile.email_changed", "profile.email_removed"])
            for row in audit { XCTAssertNil(row.detail); XCTAssertEqual(row.actorId, row.targetId) }
            XCTAssertEqual(audit.filter { $0.action == "profile.name_changed" }.count, 1)
        }
    }
    func testP1ProfileSQLite() async throws {
        let mail = RecordingMailSender()
        try await withApp(environment: Self.mailEnvironment, mail: mail, scenarioProfile(mail))
    }

    /// Two accounts confirm the same address at the same time: exactly one wins, the other one gets 409.
    func scenarioEmailRace(_ mail: RecordingMailSender) -> Scenario {
        { app, auth in
            let (admin, _) = try await self.registered(auth, db: app.db)
            let member = try await self.second(app, auth, admin)
            let contexts = [admin, member]
            var codes: [String] = []
            for context in contexts {
                try await self.api(app, context, .PUT, "me/profile/email", ["email": "race@example.test"], .accepted)
                codes.append(await mail.lastCode())
            }
            let proofs = codes
            let statuses = try await withThrowingTaskGroup(of: HTTPStatus.self) { group in
                for index in 0..<2 {
                    group.addTask {
                        let response = try await app.testable().sendRequest(.POST, "/api/v1/me/profile/email/verify", headers: {
                            var head = self.headers(contexts[index]); head.contentType = .json; return head
                        }(), body: ByteBuffer(data: try JSONSerialization.data(withJSONObject: ["code": proofs[index]])))
                        return response.status
                    }
                }
                var result: [HTTPStatus] = []
                for try await status in group { result.append(status) }
                return result
            }
            XCTAssertEqual(statuses.filter { $0 == .ok }.count, 1, "\(statuses)")
            XCTAssertEqual(statuses.filter { $0 == .conflict }.count, 1, "\(statuses)")
            try await self.eq(try await Account.query(on: app.db).filter(\.$email == "race@example.test").count(), 1)
        }
    }
    func testP1EmailRaceSQLite() async throws {
        let mail = RecordingMailSender()
        try await withApp(environment: Self.mailEnvironment, mail: mail, scenarioEmailRace(mail))
    }

    func testP1WithoutMailTransport() async throws {
        try await withApp { app, auth in
            let (admin, _) = try await self.registered(auth, db: app.db)
            let profile = try self.object(await self.api(app, admin, .GET, "me/profile"))
            XCTAssertEqual(profile["mailAvailable"] as? Bool, false)
            // Without SMTP an address cannot be verified; it stays optional and nothing breaks.
            let response = try await self.api(app, admin, .PUT, "me/profile/email", ["email": "a@example.test"], .notImplemented)
            XCTAssertEqual(try self.errorCode(response), "not_implemented")
            try await self.api(app, admin, .POST, "me/profile/email/verify", ["code": "x"], .notImplemented)
            try await self.api(app, admin, .PATCH, "me/profile", ["displayName": "Ohne Mail"])
            try await self.api(app, admin, .DELETE, "me/profile/email", nil, .noContent)
        }
    }

    func testP1EmailRequestsAreRateLimited() async throws {
        let mail = RecordingMailSender()
        try await withApp(environment: Self.mailEnvironment, mail: mail) { app, auth in
            let (admin, _) = try await self.registered(auth, db: app.db)
            // The IP limiter charges every PUT/POST to the profile e-mail endpoints like the recovery ones (60 per 5 minutes).
            var statuses: [HTTPStatus] = []
            for _ in 0..<70 {
                let response = try await app.testable().sendRequest(.PUT, "/api/v1/me/profile/email", headers: {
                    var head = self.headers(admin); head.contentType = .json; return head
                }(), body: ByteBuffer(data: try JSONSerialization.data(withJSONObject: ["email": "limit@example.test"])))
                statuses.append(response.status)
            }
            XCTAssertEqual(statuses.first, .accepted)
            XCTAssertTrue(statuses.contains(.tooManyRequests), "\(statuses.map(\.code))")
        }
    }

    // MARK: Onboarding

    func scenarioOnboarding(_ app: Application, _ auth: AuthService) async throws {
        let (admin, _) = try await registered(auth, db: app.db)
        let member = try await second(app, auth, admin)
        func state(_ context: AuthContext) async throws -> String? {
            ((try object(await api(app, context, .GET, "me/profile")))["onboarding"] as? [String: Any])?["state"] as? String
        }
        // New accounts start pending, and the session carries the flag.
        try await eq(try await state(member), "pending")
        let session = try object(await api(app, member, .GET, "auth/session"))
        XCTAssertEqual((session["account"] as? [String: Any])?["onboardingState"] as? String, "pending")
        try await api(app, member, .PUT, "me/onboarding", ["state": "bogus"], .badRequest)
        try await api(app, member, .PUT, "me/onboarding", [:], .badRequest)
        let done = try object(await api(app, member, .PUT, "me/onboarding", ["state": "completed"]))
        XCTAssertEqual((done["onboarding"] as? [String: Any])?["state"] as? String, "completed")
        XCTAssertNotNil((done["onboarding"] as? [String: Any])?["updatedAt"])
        // Per account: the other one is still pending.
        try await eq(try await state(admin), "pending"); try await eq(try await state(member), "completed")
        let sessionAfter = try object(await api(app, member, .GET, "auth/session"))
        XCTAssertEqual((sessionAfter["account"] as? [String: Any])?["onboardingState"] as? String, "completed")
        try await api(app, member, .PUT, "me/onboarding", ["state": "skipped"])
        try await eq(try await state(member), "skipped")
        try await api(app, member, .PUT, "me/onboarding", ["state": "pending"])
        try await eq(try await state(member), "pending")
        let actions = try await AccountAuditRecord.query(on: app.db).all().map(\.action).filter { $0.hasPrefix("onboarding.") }.sorted()
        XCTAssertEqual(actions, ["onboarding.completed", "onboarding.pending", "onboarding.skipped"])
    }
    func testP1OnboardingSQLite() async throws { try await withApp(scenarioOnboarding) }

    func testP1AccountDeletionRemovesPendingEmailChange() async throws {
        let mail = RecordingMailSender()
        try await withApp(environment: Self.mailEnvironment, mail: mail) { app, auth in
            let (admin, _) = try await self.registered(auth, db: app.db)
            let member = try await self.second(app, auth, admin)
            try await self.api(app, member, .PUT, "me/profile/email", ["email": "weg@example.test"], .accepted)
            try await self.eq(try await EmailChangeRequest.query(on: app.db).count(), 1)
            try await self.del(app, member, "me", confirm: "member")
            try await self.eq(try await EmailChangeRequest.query(on: app.db).count(), 0)
        }
    }

    // MARK: MariaDB

    func testP1MariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test_p1", "DB_TLS": "off"].merging(Self.mailEnvironment) { current, _ in current }
        let mail = RecordingMailSender()
        for scenario in [scenarioProfile(mail), scenarioEmailRace(mail), scenarioOnboarding] {
            try await withApp(environment: environment, mail: mail, scenario)
        }
    }
}
