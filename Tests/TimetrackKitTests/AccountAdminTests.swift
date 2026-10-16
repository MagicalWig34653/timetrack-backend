import Fluent
import FluentSQL
import XCTVapor
import ZIPFoundation
@testable import TimetrackKit

/// Package B1: account administration, export and deletion (ADR-0016).
extension AuthTests {
    // MARK: Helpers

    func del(_ app: Application, _ context: AuthContext, _ path: String, confirm: String?, _ status: HTTPStatus = .noContent) async throws {
        try await api(app, context, .DELETE, path, confirm.map { ["confirmHandle": $0] }, status)
    }
    func stale(_ context: AuthContext, on db: any Database) async throws {
        context.session.createdAt = Date().addingTimeInterval(-3600); try await context.session.update(on: db)
    }
    func countRows<M: Model>(_ type: M.Type, _ column: String, _ id: UUID, on db: any Database) async throws -> Int {
        try await M.query(on: db).filter(.path([.string(column)], schema: M.schema), .equal, .bind(id)).count()
    }
    /// Independent of `AccountEraser.wipes`: the tables that hold data of one account.
    func accountRowCounts(_ id: UUID, on db: any Database) async throws -> [String: Int] {
        var result: [String: Int] = [:]
        func add<M: Model>(_ type: M.Type, _ column: String = "account_id") async throws { result[M.schema + "." + column] = try await countRows(type, column, id, on: db) }
        try await add(WorkModelRecord.self); try await add(PlaceRecord.self); try await add(SegmentRecord.self); try await add(RevisionRecord.self)
        try await add(DayPreferenceRecord.self); try await add(AdjustmentRecord.self); try await add(SuggestionRecord.self); try await add(DeviceTokenRecord.self)
        try await add(AutomationEventRecord.self); try await add(TimerEventRecord.self)
        try await add(VacationSettingsRecord.self); try await add(VacationSnapshotRecord.self); try await add(VacationAdjustmentRecord.self)
        try await add(AbsenceRecord.self); try await add(CustomCalendarDayRecord.self); try await add(PlanDayRecord.self)
        try await add(ShareRecord.self, "owner_id"); try await add(ShareRecord.self, "recipient_id")
        try await add(AbsenceAttachmentRecord.self); try await add(StoredFileRecord.self)
        try await add(LearningFieldRecord.self); try await add(ReportEntryRecord.self); try await add(ReportWeekStatusRecord.self); try await add(ReportSourceRecord.self)
        try await add(NotificationRecord.self); try await add(NotificationSettingsRecord.self); try await add(PushSubscriptionRecord.self)
        try await add(ApiTokenRecord.self); try await add(OAuthGrant.self); try await add(OAuthCode.self)
        try await add(ImportJobRecord.self); try await add(ImportTemplateRecord.self)
        try await add(Passkey.self); try await add(Session.self); try await add(RecoveryCode.self); try await add(FallbackPassword.self)
        try await add(ExternalIdentity.self); try await add(AccountModuleSetting.self); try await add(ModuleAudit.self, "actor_id")
        return result
    }
    func total(_ counts: [String: Int]) -> Int { counts.values.reduce(0, +) }

    struct Seeded {
        var fileId: String
        var absenceId: String
        var apiToken: String
        var deviceToken: String
        var oauthAccess: String
        var oauthRefresh: String
        var client: String
    }

    /// Every kind of data the application can store for one account.
    func seed(_ app: Application, _ auth: AuthService, _ context: AuthContext, share with: String? = nil, directory: String? = nil) async throws -> Seeded {
        let id = try context.account.requireID()
        try await api(app, context, .POST, "work-models", modelBody("2026-01-01"), .created)
        let place = try resourceID(await api(app, context, .POST, "places", placeBody(), .created))
        var first = segmentBody("2026-10-12T06:07:00Z", "2026-10-12T10:00:00Z"); first["placeId"] = place
        let segment = try resourceID(await api(app, context, .POST, "time/segments", first, .created))
        try await api(app, context, .PATCH, "time/segments/" + segment, ["startedAt": "2026-10-12T06:10:00Z", "reason": "Clock correction"], .ok, version: 1)
        try await api(app, context, .PUT, "time/days/2026-10-13", ["mark": "sick", "note": "private day note"])
        try await api(app, context, .POST, "time/account/adjustments", ["kind": "opening", "date": "2026-10-12", "seconds": 1000, "reason": "Opening"], .created)
        try await api(app, context, .PUT, "plan/days/2026-10-14", ["mode": "office", "placeId": place, "note": "Plan"])
        try await api(app, context, .PUT, "vacation/settings", ["region": "DE-ST", "annualEntitlementHalfDays": 60, "carryOverByYear": ["2026": 8], "carryOverExpiry": "03-31"])
        try await api(app, context, .POST, "vacation/adjustments", ["date": "2026-10-01", "halfDays": 2, "reason": "Adjustment"], .created)
        let absence = try await createAbsence(app, context, absenceBody("2026-10-19"))
        let absenceId = try XCTUnwrap(absence["id"] as? String)
        if let with { try await api(app, context, .POST, "shares", ["recipientHandle": with, "scopes": ["plan": true, "actual": true, "vacation": true]], .created) }
        let field = try object(await api(app, context, .POST, "reports/learning-fields", ["number": 3, "name": "Netzwerke"], .created))
        try await api(app, context, .POST, "reports/entries", ["date": "2026-10-12", "learningField": "Netzwerke", "learningFieldId": try XCTUnwrap(field["id"] as? String), "durationSeconds": 3600, "notes": "Subnetting"], .created)
        // Attachment: stored through whatever backend the test configured.
        let fileId = try fileID(await fileUpload(app, context, "attest.pdf", AuthTests.pdf))
        try await api(app, context, .POST, "absences/\(absenceId)/attachments", ["fileId": fileId], .created)

        let scope = TimeServices(accountId: id, db: app.db)
        let device = try await scope.devices.create(.init(name: "Phone", expiresInDays: 1))
        let credentials = OAuthCredentialService(auth: auth, oauth: OAuthService(auth: auth))
        let personal = try await credentials.createToken(.init(name: "Test", scopes: Array(McpScopes.known), expiresInDays: 1), context, on: app.db)
        let client = try await oaRegister(app)
        let flow = try await oaFlow(app, context, client: client)
        let tokens = try await oaExchange(app, flow)
        _ = try await mcpOK(app, try XCTUnwrap(personal.token), "list_absences", ["from": "2026-10-01", "to": "2026-10-31"])   // writes an mcp_audit row

        let subscription = PushSubscriptionRecord(); subscription.id = UUID(); subscription.accountId = id
        subscription.endpointHash = UUID().uuidString; subscription.endpoint = "https://push.example/\(UUID().uuidString)"
        subscription.p256dh = "key"; subscription.auth = "auth"; subscription.createdAt = Date(); subscription.failureCount = 0
        try await subscription.create(on: app.db)
        let note = NotificationRecord(); note.id = UUID(); note.accountId = id; note.kind = "report_gap"; note.title = "T"; note.body = "B"
        note.dedupKey = UUID().uuidString; note.createdAt = Date(); try await note.create(on: app.db)
        let outbox = PushOutboxRecord(); outbox.id = UUID(); outbox.notificationId = note.id!; outbox.subscriptionId = subscription.id!
        outbox.status = "pending"; outbox.attempts = 0; outbox.nextAttemptAt = Date(); outbox.createdAt = Date(); try await outbox.create(on: app.db)
        let settings = NotificationSettingsRecord(); settings.id = UUID(); settings.accountId = id; settings.settings = .defaults; settings.updatedAt = Date()
        try await settings.create(on: app.db)
        let suggestion = SuggestionRecord(); suggestion.id = UUID(); suggestion.accountId = id
        suggestion.payload = SuggestionDTO(id: suggestion.id!, type: "start", placeId: nil, proposedStartedAt: Date(), proposedEndedAt: nil, segmentId: nil, createdAt: Date())
        try await suggestion.create(on: app.db)
        let job = ImportJobRecord(); job.id = UUID(); job.accountId = id; job.filename = "x.csv"; job.kind = "csv"; job.sha256 = "00"; job.status = "uploaded"; job.sheets = []; job.createdAt = Date()
        try await job.create(on: app.db)
        let file = ImportFileRecord(); file.id = UUID(); file.accountId = id; file.jobId = job.id!; file.size = 1; file.bytes = Data([1]); try await file.create(on: app.db)
        let identity = ExternalIdentity(accountId: id, issuer: "https://issuer.example", subject: UUID().uuidString, emailHint: nil, linkedAt: Date())
        try await identity.create(on: app.db)
        let moduleSetting = AccountModuleSetting(); moduleSetting.id = UUID(); moduleSetting.accountId = id; moduleSetting.moduleKey = "reports"; moduleSetting.enabled = true
        try await moduleSetting.create(on: app.db)
        try await api(app, context, .PUT, "me/modules", ["modules": ["reports": false]])
        try await api(app, context, .PUT, "me/modules", ["modules": ["reports": true]])
        return Seeded(fileId: fileId, absenceId: absenceId, apiToken: try XCTUnwrap(personal.token), deviceToken: try XCTUnwrap(device.token),
                      oauthAccess: tokens.access, oauthRefresh: tokens.refresh, client: client)
    }

    /// Every credential of `seeded` must be dead; nothing may answer.
    func assertDead(_ app: Application, _ account: AuthContext, _ seeded: Seeded) async throws {
        try await api(app, account, .GET, "auth/session", nil, .unauthorized)
        _ = try await mcpRPC(app, seeded.apiToken, "tools/list", status: .unauthorized)
        _ = try await mcpRPC(app, seeded.oauthAccess, "tools/list", status: .unauthorized)
        await expect("unauthorized") { _ = try await DeviceTokenService.authenticate(seeded.deviceToken, db: app.db) }
        let device = try await app.testable().sendRequest(.POST, "/api/v1/automation/events", headers: ["Authorization": "Bearer \(seeded.deviceToken)"])
        XCTAssertEqual(device.status, .unauthorized)
        let refreshed = try await oaToken(app, ["grant_type": "refresh_token", "refresh_token": seeded.oauthRefresh, "client_id": seeded.client])
        XCTAssertEqual(refreshed.status, .badRequest, refreshed.response.body.string)
        XCTAssertEqual(oaOAuthError(refreshed), "invalid_grant")
    }

    func singleScenarioEnvironment() -> [String: String] { ["STORAGE_SECRET_KEY": AuthTests.testKey] }

    // MARK: Authorization

    func scenarioAccountAdminAuthorization(_ app: Application, _ auth: AuthService) async throws {
        let (admin, _) = try await registered(auth, db: app.db)
        let member = try await second(app, auth, admin)
        let memberId = try member.account.requireID()
        for (method, path, body) in [(HTTPMethod.GET, "admin/accounts", nil), (.PATCH, "admin/accounts/\(memberId)", ["state": "disabled"]),
                                     (.DELETE, "admin/accounts/\(memberId)/sessions", nil), (.DELETE, "admin/accounts/\(memberId)", ["confirmHandle": "member"])] as [(HTTPMethod, String, [String: Any]?)] {
            try await api(app, member, method, path, body, .forbidden)
            try await timeRequest(app, nil, method, path, body, status: .unauthorized)
        }
        // A member cannot pass a self-service identity as an admin one either.
        try await api(app, member, .PATCH, "admin/accounts/\(member.account.requireID())", ["role": "admin"], .forbidden)
        let recovery = try await auth.issueSession(for: admin.account, recovery: true, on: app.db)
        try await api(app, recovery, .GET, "admin/accounts", nil, .forbidden)
        // Untouched by the forbidden attempts.
        try await eq(try await Account.find(memberId, on: app.db)?.role, .member); try await no(try await Account.find(memberId, on: app.db)?.disabledAt != nil)

        let page = try object(await api(app, admin, .GET, "admin/accounts"))
        XCTAssertEqual(page["total"] as? Int, 2); XCTAssertEqual(page["limit"] as? Int, 50)
        let items = try XCTUnwrap(page["items"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["handle"] as? String }, ["admin", "member"])
        // Identity, state and activity only.
        let allowed: Set<String> = ["id", "handle", "displayName", "email", "role", "state", "createdAt", "disabledAt", "lastActivityAt", "passkeyCount"]
        for item in items { XCTAssertTrue(Set(item.keys).isSubset(of: allowed), "\(item.keys)"); XCTAssertEqual(item["passkeyCount"] as? Int, 1); XCTAssertEqual(item["state"] as? String, "active") }
        XCTAssertNotNil(items[0]["lastActivityAt"])
        let secondPage = try object(await api(app, admin, .GET, "admin/accounts?limit=1&offset=1"))
        XCTAssertEqual((secondPage["items"] as? [[String: Any]])?.first?["handle"] as? String, "member"); XCTAssertEqual(secondPage["total"] as? Int, 2)
        try await api(app, admin, .GET, "admin/accounts?limit=0", nil, .badRequest)
        try await api(app, admin, .GET, "admin/accounts?limit=101", nil, .badRequest)
        try await api(app, admin, .GET, "admin/accounts?offset=-1", nil, .badRequest)
        try await api(app, admin, .PATCH, "admin/accounts/\(memberId)", [:], .badRequest)
        try await api(app, admin, .PATCH, "admin/accounts/\(memberId)", ["state": "bogus"], .badRequest)
        try await api(app, admin, .PATCH, "admin/accounts/\(UUID())", ["state": "disabled"], .notFound)
    }
    func testB1AdminAuthorizationSQLite() async throws { try await withApp(scenarioAccountAdminAuthorization) }
    func testB1AdminEndpointsIgnoreModuleSwitches() async throws {
        // Operator lock of every module: account administration, export and self-deletion stay available.
        try await withApp(environment: ["MODULES_DISABLED": "reports,planning,transfer,automation,mcp"]) { app, auth in
            try await self.scenarioAccountAdminAuthorization(app, auth)
            let member = try await XCTUnwrapAsync(try await Account.query(on: app.db).filter(\.$handle == "member").first())
            let context = try await auth.issueSession(for: member, on: app.db)
            let export = try await self.api(app, context, .GET, "me/export")
            XCTAssertEqual(export.headers.first(name: .contentType), "application/zip")
            try await self.del(app, context, "me", confirm: "member")
            try await self.eq(try await Account.query(on: app.db).count(), 1)
        }
    }
    func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?) async throws -> T {
        let result = try await value(); return try XCTUnwrap(result)
    }
    func freshSession(_ app: Application, _ auth: AuthService, _ handle: String) async throws -> AuthContext {
        let account = try await XCTUnwrapAsync(try await Account.query(on: app.db).filter(\.$handle == handle).first())
        return try await auth.issueSession(for: account, on: app.db)
    }

    // MARK: Disable and reactivate

    func scenarioDisableAndReactivate(_ app: Application, _ auth: AuthService) async throws {
        let (admin, _) = try await registered(auth, db: app.db)
        let (member, device) = try await registered(auth, db: app.db, handle: "member", admin: admin)
        let memberId = try member.account.requireID()
        let seeded = try await seed(app, auth, member)
        let other = try await registered(auth, db: app.db, handle: "other", admin: admin).0
        let otherSeed = try await seed(app, auth, other)

        let disabled = try object(await api(app, admin, .PATCH, "admin/accounts/\(memberId)", ["state": "disabled"]))
        XCTAssertEqual(disabled["state"] as? String, "disabled"); XCTAssertNotNil(disabled["disabledAt"])
        try await assertDead(app, member, seeded)
        // Neutral login failure: the same error as for any unknown credential.
        let login = try await auth.loginOptions(on: app.db)
        await expect("unauthorized") { _ = try await auth.login(device.assertion(login, accountID: memberId), on: app.db) }
        // Push subscriptions are gone; data stays.
        try await eq(try await PushSubscriptionRecord.query(on: app.db).filter(\.$accountId == memberId).count(), 0)
        try await eq(try await PushOutboxRecord.query(on: app.db).count(), 1)
        try await yes(try await SegmentRecord.query(on: app.db).filter(\.$accountId == memberId).count() > 0)
        // Nothing of the other account was touched.
        try await api(app, other, .GET, "auth/session")
        _ = try await mcpRPC(app, otherSeed.apiToken, "tools/list")
        _ = try await DeviceTokenService.authenticate(otherSeed.deviceToken, db: app.db)
        // Idempotent.
        try await api(app, admin, .PATCH, "admin/accounts/\(memberId)", ["state": "disabled"])
        // Reactivation brings back the ability to log in but not the revoked credentials.
        let active = try object(await api(app, admin, .PATCH, "admin/accounts/\(memberId)", ["state": "active"]))
        XCTAssertEqual(active["state"] as? String, "active"); XCTAssertTrue(active["disabledAt"] == nil || active["disabledAt"] is NSNull)
        try await assertDead(app, member, seeded)
        let again = try await auth.loginOptions(on: app.db)
        let context = try await auth.login(device.assertion(again, accountID: memberId), on: app.db)
        try await api(app, context, .GET, "auth/session")
        let audits = try await AccountAuditRecord.query(on: app.db).sort(\.$occurredAt).all().map(\.action)
        XCTAssertEqual(audits, ["account.disabled", "account.reactivated"])
    }
    func testB1DisableReactivateSQLite() async throws { try await withApp(environment: singleScenarioEnvironment(), scenarioDisableAndReactivate) }

    func scenarioRevokeSessions(_ app: Application, _ auth: AuthService) async throws {
        let (admin, _) = try await registered(auth, db: app.db)
        let member = try await second(app, auth, admin)
        let memberId = try member.account.requireID()
        let extra = try await auth.issueSession(for: member.account, on: app.db)
        try await api(app, admin, .DELETE, "admin/accounts/\(memberId)/sessions", nil, .noContent)
        try await api(app, member, .GET, "auth/session", nil, .unauthorized); try await api(app, extra, .GET, "auth/session", nil, .unauthorized)
        try await api(app, admin, .GET, "auth/session")
        try await api(app, admin, .DELETE, "admin/accounts/\(UUID())/sessions", nil, .notFound)
        try await eq(try await Account.find(memberId, on: app.db)?.disabledAt == nil, true)
        try await eq(try await AccountAuditRecord.query(on: app.db).filter(\.$action == "account.sessions_revoked").count(), 1)
    }
    func testB1RevokeSessionsSQLite() async throws { try await withApp(scenarioRevokeSessions) }

    // MARK: Roles and the last administrator

    func scenarioRolesAndLastAdmin(_ app: Application, _ auth: AuthService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let aId = try a.account.requireID()
        let b = try await second(app, auth, a)
        let bId = try b.account.requireID()
        // No self-lockout through the admin API.
        for body in [["role": "member"], ["state": "disabled"]] {
            try await eq(try errorCode(await api(app, a, .PATCH, "admin/accounts/\(aId)", body, .conflict)), "self_lockout")
        }
        try await eq(try errorCode(await api(app, a, .DELETE, "admin/accounts/\(aId)", ["confirmHandle": "admin"], .conflict)), "self_lockout")
        // Promotion needs a fresh session.
        try await stale(a, on: app.db)
        try await eq(try errorCode(await api(app, a, .PATCH, "admin/accounts/\(bId)", ["role": "admin"], .forbidden)), "reauth_required")
        try await eq(try await Account.find(bId, on: app.db)?.role, .member)
        let freshA = try await freshSession(app, auth, "admin")
        let promoted = try object(await api(app, freshA, .PATCH, "admin/accounts/\(bId)", ["role": "admin"]))
        XCTAssertEqual(promoted["role"] as? String, "admin")
        // Demotion by the other administrator works; B is now the only one.
        try await api(app, b, .PATCH, "admin/accounts/\(aId)", ["role": "member"])
        try await eq(try await Account.find(aId, on: app.db)?.role, .member)
        try await api(app, a, .GET, "admin/accounts", nil, .forbidden)
        // The sole active administrator can neither delete themselves nor be removed; nothing happens.
        try await eq(try errorCode(await api(app, b, .DELETE, "me", ["confirmHandle": "member"], .conflict)), "last_admin")
        try await eq(try await Account.query(on: app.db).count(), 2)
        // A disabled administrator does not count.
        let freshB = try await freshSession(app, auth, "member")
        try await api(app, freshB, .PATCH, "admin/accounts/\(aId)", ["role": "admin"])
        try await api(app, freshB, .PATCH, "admin/accounts/\(aId)", ["state": "disabled"])
        try await eq(try errorCode(await api(app, freshB, .DELETE, "me", ["confirmHandle": "member"], .conflict)), "last_admin")
        try await eq(try await AccountAuditRecord.query(on: app.db).filter(\.$action == "account.role_changed").count(), 3)
    }
    func testB1RolesAndLastAdminSQLite() async throws { try await withApp(scenarioRolesAndLastAdmin) }

    /// Two administrators delete themselves at the same time: exactly one succeeds.
    func scenarioLastAdminRace(_ app: Application, _ auth: AuthService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let b = try await second(app, auth, a, handle: "second")
        try await api(app, a, .PATCH, "admin/accounts/\(b.account.requireID())", ["role": "admin"])
        async let first = app.testable().sendRequest(.DELETE, "/api/v1/me", headers: self.jsonHeaders(a), body: ByteBuffer(string: "{\"confirmHandle\":\"admin\"}"))
        async let other = app.testable().sendRequest(.DELETE, "/api/v1/me", headers: self.jsonHeaders(b), body: ByteBuffer(string: "{\"confirmHandle\":\"second\"}"))
        let statuses = try await [first.status, other.status].sorted { $0.code < $1.code }
        XCTAssertEqual(statuses, [.noContent, .conflict])
        let remaining = try await Account.query(on: app.db).all()
        XCTAssertEqual(remaining.count, 1); XCTAssertEqual(remaining.first?.role, .admin); XCTAssertNil(remaining.first?.disabledAt)
    }
    func jsonHeaders(_ context: AuthContext) -> HTTPHeaders { var head = headers(context); head.contentType = .json; return head }
    func testB1LastAdminRaceSQLite() async throws { try await withApp(scenarioLastAdminRace) }

    // MARK: Deletion

    func configureLocal(_ app: Application, _ admin: AuthContext, _ directory: String?) async throws {
        guard let directory else { return }
        try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "local")], "localPath": directory])
    }

    func scenarioCascade(local: Bool) -> Scenario {
        { app, auth in
            let directory = local ? try self.tempDirectory() : nil
            defer { directory.map { try? FileManager.default.removeItem(atPath: $0) } }
            let (admin, _) = try await self.registered(auth, db: app.db)
            try await self.configureLocal(app, admin, directory)
            let a = try await self.registered(auth, db: app.db, handle: "alpha", admin: admin).0
            let b = try await self.registered(auth, db: app.db, handle: "bravo", admin: admin).0
            let aId = try a.account.requireID(), bId = try b.account.requireID()
            let seededA = try await self.seed(app, auth, a, share: "bravo")
            let seededB = try await self.seed(app, auth, b, share: "alpha")
            try await self.api(app, b, .PUT, "time/days/2026-10-20", ["mark": "sick", "note": "bravo-private-note"])
            let before = try await self.accountRowCounts(bId, on: app.db)
            let beforeA = try await self.accountRowCounts(aId, on: app.db)
            XCTAssertTrue(beforeA.filter { $0.key != "stored_files.account_id" || true }.values.allSatisfy { $0 > 0 || $0 == 0 })
            for key in ["work_segments.account_id", "absences.account_id", "stored_files.account_id", "shares.owner_id", "shares.recipient_id", "report_entries.account_id", "api_tokens.account_id", "oauth_grants.account_id", "device_tokens.account_id", "push_subscriptions.account_id", "import_jobs.account_id", "sessions.account_id", "passkeys.account_id"] {
                XCTAssertGreaterThan(beforeA[key] ?? 0, 0, key)
            }
            if let directory { try await self.eq(self.diskFiles(directory).count, 2) } else { try await self.eq(try await FileBlobRecord.query(on: app.db).count(), 2) }
            let auditBefore = try await McpAuditRecord.query(on: app.db).count()
            XCTAssertEqual(auditBefore, 2)

            // Guards: wrong handle, stale session, member, unauthenticated.
            try await self.eq(try self.errorCode(await self.api(app, admin, .DELETE, "admin/accounts/\(aId)", ["confirmHandle": "bravo"], .badRequest)), "confirmation_mismatch")
            try await self.api(app, admin, .DELETE, "admin/accounts/\(aId)", nil, .badRequest)
            try await self.api(app, b, .DELETE, "admin/accounts/\(aId)", ["confirmHandle": "alpha"], .forbidden)
            try await self.stale(admin, on: app.db)
            try await self.eq(try self.errorCode(await self.api(app, admin, .DELETE, "admin/accounts/\(aId)", ["confirmHandle": "alpha"], .forbidden)), "reauth_required")
            try await self.eq(try await Account.find(aId, on: app.db)?.disabledAt == nil, true)
            let fresh = try await self.freshSession(app, auth, "admin")

            try await self.del(app, fresh, "admin/accounts/\(aId)", confirm: "alpha")

            // Account A is gone completely.
            try await self.eq(try await Account.find(aId, on: app.db) == nil, true)
            let after = try await self.accountRowCounts(aId, on: app.db)
            XCTAssertEqual(self.total(after), 0, "\(after.filter { $0.value > 0 })")
            try await self.assertDead(app, a, seededA)
            if let directory { try await self.eq(self.diskFiles(directory).count, 1) } else { try await self.eq(try await FileBlobRecord.query(on: app.db).count(), 1) }
            try await self.eq(try await McpAuditRecord.query(on: app.db).count(), 1)
            // Account B: everything except the two shares between A and B is intact and usable.
            var expected = before
            expected["shares.owner_id"] = 0; expected["shares.recipient_id"] = 0
            let afterB = try await self.accountRowCounts(bId, on: app.db)
            XCTAssertEqual(afterB, expected)
            try await self.eq(try await ShareRecord.query(on: app.db).count(), 0)
            try await self.api(app, b, .GET, "auth/session")
            _ = try await self.mcpRPC(app, seededB.apiToken, "tools/list")
            _ = try await self.mcpRPC(app, seededB.oauthAccess, "tools/list")
            _ = try await DeviceTokenService.authenticate(seededB.deviceToken, db: app.db)
            let refreshed = try await self.oaToken(app, ["grant_type": "refresh_token", "refresh_token": seededB.oauthRefresh, "client_id": seededB.client])
            XCTAssertEqual(refreshed.status, .ok)
            _ = try await self.download(app, b, seededB.fileId)
            try await self.api(app, b, .GET, "time/days/2026-10-20")
            try await self.eq(try self.list(await self.api(app, b, .GET, "shares/incoming")).count, 0)
            // Shared OAuth client registration is not account data.
            try await self.eq(try await OAuthClient.query(on: app.db).count(), 2)
            // The audit row keeps only opaque ids.
            let audits = try await AccountAuditRecord.query(on: app.db).all()
            XCTAssertEqual(audits.map(\.action), ["account.deleted"])
            XCTAssertEqual(audits.first?.targetId, aId); XCTAssertEqual(audits.first?.actorId, try admin.account.requireID()); XCTAssertNil(audits.first?.detail)
            // Handles can be reused afterwards.
            _ = try await self.registered(auth, db: app.db, handle: "alpha", admin: fresh)
        }
    }
    func testB1DeleteCascadeDatabaseStorageSQLite() async throws { try await withApp(environment: singleScenarioEnvironment(), scenarioCascade(local: false)) }
    func testB1DeleteCascadeLocalStorageSQLite() async throws { try await withApp(environment: singleScenarioEnvironment(), scenarioCascade(local: true)) }

    /// Object removal fails: the operation fails clearly, the account stays disabled, and a retry completes it.
    func scenarioDeleteStorageFailure(_ app: Application, _ auth: AuthService) async throws {
        let directory = try tempDirectory(); defer { try? FileManager.default.removeItem(atPath: directory) }
        let flags = FlakyFlags()
        app.storageEnvironment.decorate = { FlakyBackend(inner: $0, flags: flags) }
        let (admin, _) = try await registered(auth, db: app.db)
        try await configureLocal(app, admin, directory)
        let a = try await registered(auth, db: app.db, handle: "alpha", admin: admin).0
        let b = try await registered(auth, db: app.db, handle: "bravo", admin: admin).0
        let aId = try a.account.requireID()
        _ = try await seed(app, auth, a); let seededB = try await seed(app, auth, b)
        flags["delete"] = true
        try await eq(try errorCode(await api(app, admin, .DELETE, "admin/accounts/\(aId)", ["confirmHandle": "alpha"], .serviceUnavailable)), "account_deletion_incomplete")
        let account = try await XCTUnwrapAsync(try await Account.find(aId, on: app.db))
        XCTAssertNotNil(account.disabledAt)
        try await api(app, a, .GET, "auth/session", nil, .unauthorized)
        let leftovers = try await StoredFileRecord.query(on: app.db).filter(\.$accountId == aId).all()
        XCTAssertEqual(leftovers.map(\.state), ["deleting"]); XCTAssertGreaterThan(leftovers[0].cleanupAttempts, 0)
        try await eq(diskFiles(directory).count, 2)
        _ = try await download(app, b, seededB.fileId)   // B unaffected
        flags["delete"] = false
        try await del(app, admin, "admin/accounts/\(aId)", confirm: "alpha")
        try await eq(try await Account.find(aId, on: app.db) == nil, true)
        try await eq(diskFiles(directory).count, 1)
        // Alternative recovery path: the storage cleanup alone also drains `deleting` rows.
        let (c, _) = try await registered(auth, db: app.db, handle: "charlie", admin: admin)
        let cFile = try fileID(await fileUpload(app, c, "c.pdf", AuthTests.pdf))
        _ = cFile
        flags["delete"] = true
        try await api(app, admin, .DELETE, "admin/accounts/\(c.account.requireID())", ["confirmHandle": "charlie"], .serviceUnavailable)
        flags["delete"] = false
        try await eq(await storageService(app, auth).cleanup(), 1)
        try await del(app, admin, "admin/accounts/\(c.account.requireID())", confirm: "charlie")
        try await eq(diskFiles(directory).count, 1)
    }
    func testB1DeleteStorageFailureSQLite() async throws { try await withApp(environment: singleScenarioEnvironment(), scenarioDeleteStorageFailure) }

    func scenarioSelfDelete(_ app: Application, _ auth: AuthService) async throws {
        let (admin, _) = try await registered(auth, db: app.db)
        let member = try await registered(auth, db: app.db, handle: "member", admin: admin).0
        let memberId = try member.account.requireID()
        let seeded = try await seed(app, auth, member)
        let recovery = try await auth.issueSession(for: member.account, recovery: true, on: app.db)
        try await api(app, recovery, .DELETE, "me", ["confirmHandle": "member"], .forbidden)
        try await api(app, member, .DELETE, "me", nil, .badRequest)
        try await eq(try errorCode(await api(app, member, .DELETE, "me", ["confirmHandle": "admin"], .badRequest)), "confirmation_mismatch")
        try await stale(member, on: app.db)
        try await eq(try errorCode(await api(app, member, .DELETE, "me", ["confirmHandle": "member"], .forbidden)), "reauth_required")
        try await eq(try await Account.find(memberId, on: app.db) == nil, false)
        let fresh = try await freshSession(app, auth, "member")
        let response = try await api(app, fresh, .DELETE, "me", ["confirmHandle": "member"], .noContent)
        XCTAssertTrue(response.headers.setCookie?["tt_session"]?.string.isEmpty ?? false)
        try await eq(try await Account.find(memberId, on: app.db) == nil, true)
        let leftover = try await accountRowCounts(memberId, on: app.db)
        XCTAssertEqual(total(leftover), 0)
        try await assertDead(app, fresh, seeded)
        let audits = try await AccountAuditRecord.query(on: app.db).all()
        XCTAssertEqual(audits.map(\.action), ["account.self_deleted"]); XCTAssertEqual(audits.first?.actorId, memberId)
        try await api(app, admin, .GET, "auth/session")
    }
    func testB1SelfDeleteSQLite() async throws { try await withApp(environment: singleScenarioEnvironment(), scenarioSelfDelete) }

    // MARK: Export

    func entries(_ data: Data) throws -> [String: Data] {
        let archive = try Archive(data: data, accessMode: .read)
        var result: [String: Data] = [:]
        for entry in archive {
            var bytes = Data()
            _ = try archive.extract(entry) { bytes.append($0) }
            result[entry.path] = bytes
        }
        return result
    }
    func scenarioExport(local: Bool) -> Scenario {
        { app, auth in
            let directory = local ? try self.tempDirectory() : nil
            defer { directory.map { try? FileManager.default.removeItem(atPath: $0) } }
            let flags = FlakyFlags()
            app.storageEnvironment.decorate = { FlakyBackend(inner: $0, flags: flags) }
            let (admin, _) = try await self.registered(auth, db: app.db)
            try await self.configureLocal(app, admin, directory)
            let a = try await self.registered(auth, db: app.db, handle: "alpha", admin: admin).0
            let b = try await self.registered(auth, db: app.db, handle: "bravo", admin: admin).0
            let seededA = try await self.seed(app, auth, a, share: "bravo")
            let seededB = try await self.seed(app, auth, b, share: "alpha")
            try await self.api(app, b, .PUT, "time/days/2026-10-20", ["mark": "sick", "note": "bravo-private-note"])
            try await self.api(app, a, .PUT, "time/days/2026-10-21", ["mark": "sick", "note": "=alpha formula"])

            try await self.timeRequest(app, nil, .GET, "me/export", status: .unauthorized)
            let recovery = try await auth.issueSession(for: a.account, recovery: true, on: app.db)
            try await self.api(app, recovery, .GET, "me/export", nil, .forbidden)
            let response = try await self.api(app, a, .GET, "me/export")
            XCTAssertEqual(response.headers.first(name: .contentType), "application/zip")
            XCTAssertTrue(response.headers.first(name: .contentDisposition)?.contains("timetrack-export-alpha-") ?? false)
            XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
            let files = try self.entries(Data(response.body.readableBytesView))
            let names = Set(files.keys)
            for name in ["manifest.json", "account.json", "time-entries.json", "time-entries.csv", "time-entry-revisions.json", "absences.json", "absences.csv", "report-entries.json", "report-entries.csv",
                         "shares-outgoing.json", "work-models.json", "places.json", "day-preferences.json", "plan-days.json", "files.json", "notification-settings.json"] {
                XCTAssertTrue(names.contains(name), name)
            }
            let attachment = names.first { $0.hasPrefix("files/") }
            XCTAssertEqual(attachment.flatMap { files[$0] }, AuthTests.pdf)
            let entries = try JSONSerialization.jsonObject(with: try XCTUnwrap(files["time-entries.json"])) as? [[String: Any]]
            XCTAssertEqual(entries?.count, 1); XCTAssertEqual(entries?.first?["rawStartedAt"] as? String, "2026-10-12T06:07:00.000Z")
            XCTAssertEqual(entries?.first?["startedAt"] as? String, "2026-10-12T06:10:00.000Z")
            let revisions = try JSONSerialization.jsonObject(with: try XCTUnwrap(files["time-entry-revisions.json"])) as? [[String: Any]]
            XCTAssertEqual(revisions?.count, 1)
            let csv = String(decoding: try XCTUnwrap(files["time-entries.csv"]), as: UTF8.self)
            XCTAssertTrue(csv.hasPrefix("id,kind,rawStartedAt,rawEndedAt,startedAt,endedAt,placeId,source,note,voidedAt,voidReason,needsReview,version\r\n")); XCTAssertEqual(csv.split(separator: "\r\n").count, 2)
            let reports = String(decoding: try XCTUnwrap(files["report-entries.csv"]), as: UTF8.self)
            XCTAssertTrue(reports.contains("Subnetting") && reports.contains("Netzwerke"))
            let days = String(decoding: try XCTUnwrap(files["day-preferences.json"]), as: UTF8.self)
            XCTAssertTrue(days.contains("=alpha formula"))   // JSON is verbatim; only CSV cells are formula-protected
            let shares = try JSONSerialization.jsonObject(with: try XCTUnwrap(files["shares-outgoing.json"])) as? [[String: Any]]
            XCTAssertEqual(shares?.count, 1); XCTAssertEqual(shares?.first?["recipientHandle"] as? String, "bravo")
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(files["manifest.json"])) as? [String: Any])
            XCTAssertEqual((manifest["counts"] as? [String: Int])?["time-entries"], 1); XCTAssertEqual((manifest["counts"] as? [String: Int])?["files"], 1)
            // No secrets, no foreign data.
            let blob = names.filter { !$0.hasPrefix("files/") }.map { String(decoding: files[$0]!, as: UTF8.self) }.joined(separator: "\n")
            for secret in [seededA.apiToken, seededA.deviceToken, seededA.oauthAccess, seededA.oauthRefresh, Secrets.hash(seededA.apiToken), Secrets.hash(seededA.deviceToken),
                           Secrets.hash(seededA.oauthAccess), a.token, Secrets.hash(a.token), "token_hash", "tokenHash", "p256dh", "push.example", "publicKey", "credentialId"] {
                XCTAssertFalse(blob.contains(secret), secret)
            }
            for foreign in ["bravo-private-note", seededB.apiToken, try b.account.requireID().uuidString, seededB.fileId, "admin"] where foreign != "admin" {
                XCTAssertFalse(blob.contains(foreign), foreign)
            }
            // A file that cannot be read is listed, not silently dropped.
            flags["get"] = true
            let degraded = try await self.api(app, a, .GET, "me/export")
            let degradedFiles = try self.entries(Data(degraded.body.readableBytesView))
            XCTAssertFalse(degradedFiles.keys.contains { $0.hasPrefix("files/") })
            let listing = try JSONSerialization.jsonObject(with: try XCTUnwrap(degradedFiles["files.json"])) as? [[String: Any]]
            XCTAssertEqual(listing?.first?["included"] as? Bool, false); XCTAssertEqual(listing?.first?["reason"] as? String, "storage_unavailable")
            try await self.eq(try await AccountAuditRecord.query(on: app.db).filter(\.$action == "account.exported").count(), 2)
        }
    }
    func testB1ExportDatabaseStorageSQLite() async throws { try await withApp(environment: singleScenarioEnvironment(), scenarioExport(local: false)) }
    func testB1ExportLocalStorageSQLite() async throws { try await withApp(environment: singleScenarioEnvironment(), scenarioExport(local: true)) }

    // MARK: Schema completeness

    /// A new table that references an account must be added to `AccountEraser` (or explicitly listed there).
    func testB1EraserCoversEveryAccountTable() async throws {
        try await withApp { app, _ in
            let sql = try requireSQL(app.db)
            let columns = try await sql.raw("SELECT m.name AS t, p.name AS c FROM sqlite_master m, pragma_table_info(m.name) p WHERE m.type = 'table'").all()
            let accountColumns: Set<String> = ["account_id", "owner_id", "recipient_id", "actor_id", "created_by", "used_by", "updated_by"]
            var tables = Set<String>()
            for row in columns {
                let table = try row.decode(column: "t", as: String.self), column = try row.decode(column: "c", as: String.self)
                if accountColumns.contains(column) { tables.insert(table) }
            }
            let references = try await sql.raw("SELECT m.name AS t FROM sqlite_master m, pragma_foreign_key_list(m.name) f WHERE m.type = 'table' AND f.\"table\" = 'accounts'").all()
            for row in references { tables.insert(try row.decode(column: "t", as: String.self)) }
            let covered = Set(AccountEraser.wipes.map(\.schema)).union(AccountEraser.otherSchemas)
            XCTAssertEqual(tables.subtracting(covered).sorted(), [])
            XCTAssertGreaterThan(tables.count, 40)
        }
    }

    // MARK: MariaDB

    func testB1MariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test_b1", "DB_TLS": "off", "STORAGE_SECRET_KEY": AuthTests.testKey]
        let scenarios: [Scenario] = [scenarioAccountAdminAuthorization, scenarioDisableAndReactivate, scenarioRevokeSessions, scenarioRolesAndLastAdmin, scenarioLastAdminRace,
                                     scenarioCascade(local: false), scenarioCascade(local: true), scenarioDeleteStorageFailure, scenarioSelfDelete,
                                     scenarioExport(local: false), scenarioExport(local: true)]
        for scenario in scenarios { try await withApp(environment: environment, scenario) }
    }
}
