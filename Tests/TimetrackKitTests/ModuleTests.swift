import Fluent
import XCTVapor
@testable import TimetrackKit

extension AuthTests {
    private var moduleRoutes: [(ModuleKey, [String])] {
        [(.reports, ["reports/learning-fields"]),
         (.planning, ["vacation/settings", "absences?from=2026-10-01&to=2026-10-31", "calendar/holidays?year=2026", "plan/days?from=2026-10-01&to=2026-10-31", "shares", "shares/incoming"]),
         (.transfer, ["export/time?from=2026-10-01&to=2026-10-02&format=csv", "import-templates", "admin/storage"]),
         (.automation, ["me/device-tokens", "time/suggestions"]),
         (.mcp, ["me/api-tokens", "me/oauth-grants"])]
    }
    func setModules(_ app: Application, _ context: AuthContext, _ values: [String: Bool], server: Bool = false) async throws {
        try await api(app, context, .PUT, server ? "admin/modules" : "me/modules", ["modules": values])
    }
    func scenarioModulesRoutes(_ app: Application, _ auth: AuthService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let b = try await second(app, auth, a)
        let defaults = try await api(app, a, .GET, "modules").content.decode([ModuleStatus].self)
        XCTAssertEqual(defaults.count, 5); XCTAssertTrue(defaults.allSatisfy { $0.effective && !$0.lockedByOperator })
        for (key, routes) in moduleRoutes {
            for route in routes { try await api(app, a, .GET, route) }
            try await setModules(app, a, [key.rawValue: false])
            for route in routes {
                let response = try await api(app, a, .GET, route, nil, .notFound)
                XCTAssertEqual(try errorCode(response), "module_disabled")
            }
            try await yes(try await auth.modules.enabled(key, account: b.account.requireID(), on: app.db))
            try await setModules(app, a, [key.rawValue: true])
            for route in routes { try await api(app, a, .GET, route) }
            try await setModules(app, a, [key.rawValue: false], server: true)
            for route in routes { try await api(app, a, .GET, route, nil, .notFound) }
            let locked = try await api(app, a, .PUT, "me/modules", ["modules": [key.rawValue: true]], .conflict)
            XCTAssertEqual(try errorCode(locked), "module_locked")
            try await setModules(app, a, [key.rawValue: true], server: true)
        }
        try await eq(try await ModuleAudit.query(on: app.db).count(), 10)
        let audits = try await ModuleAudit.query(on: app.db).all()
        XCTAssertTrue(audits.allSatisfy { $0.actorId == a.account.id && $0.oldEnabled != $0.newEnabled })
        try await api(app, b, .GET, "admin/modules", nil, .forbidden)
        try await api(app, b, .PUT, "admin/modules", ["modules": ["reports": false]], .forbidden)
        try await api(app, a, .PUT, "me/modules", ["modules": ["unknown": false, "reports": false]], .badRequest)
        try await yes(try await auth.modules.enabled(.reports, account: a.account.requireID(), on: app.db))
        try await api(app, a, .PUT, "admin/modules", ["modules": ["unknown": false]], .badRequest)
        let recovery = try await auth.issueSession(for: a.account, recovery: true, on: app.db)
        try await api(app, recovery, .GET, "modules", nil, .forbidden)
        let response = try await app.testable().sendRequest(.PUT, "/api/v1/me/modules", headers: headers(a, csrf: false), body: ByteBuffer(string: "{\"modules\":{}}"))
        XCTAssertEqual(response.status, .forbidden)
    }
    func testC20RoutesSQLite() async throws { try await withApp(scenarioModulesRoutes) }

    func testC20OperatorLocks() async throws {
        XCTAssertThrowsError(try Configuration(environment: ["MODULES_DISABLED": "reports,unknown"])) { error in
            XCTAssertTrue(String(describing: error).contains("MODULES_DISABLED"))
        }
        try await withApp(environment: ["MODULES_DISABLED": " reports,planning,transfer,automation,mcp "]) { app, auth in
            let (a, _) = try await registered(auth, db: app.db)
            let status = try await api(app, a, .GET, "modules").content.decode([ModuleStatus].self)
            XCTAssertTrue(status.allSatisfy { !$0.effective && !$0.serverEnabled && $0.accountEnabled && $0.lockedByOperator })
            for (key, routes) in self.moduleRoutes {
                for route in routes { try await self.api(app, a, .GET, route, nil, .notFound) }
                try await self.api(app, a, .PUT, "me/modules", ["modules": [key.rawValue: true]], .conflict)
                try await self.api(app, a, .PUT, "admin/modules", ["modules": [key.rawValue: false]], .conflict)
            }
            for path in ["/mcp", "/oauth/register", "/.well-known/oauth-protected-resource", "/.well-known/oauth-authorization-server"] {
                let response = try await app.testable().sendRequest(.GET, path)
                XCTAssertEqual(response.status, .notFound); XCTAssertEqual(try self.errorCode(response), "module_disabled")
            }
            try await self.eq(try await ModuleAudit.query(on: app.db).count(), 0)
        }
    }
    func scenarioModulesEvaluation(_ app: Application, _ auth: AuthService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let b = try await second(app, auth, a)
        try await planningModel(app, a)
        try await createAbsence(app, a, absenceBody("2026-10-12"))
        let share = try object(await api(app, a, .POST, "shares", ["recipientHandle": "member", "scopes": ["plan": true, "actual": true, "vacation": true]], .created))
        let shareID = try XCTUnwrap(share["id"] as? String)
        let scope = TimeServices(accountId: try a.account.requireID(), db: app.db)
        try await eq(try await scope.days.evaluate(LocalDate("2026-10-12")).mark, .vacation)
        try await eq(try await scope.days.evaluate(LocalDate("2026-01-01")).mark, .holiday)
        try await api(app, a, .PUT, "time/days/2026-10-13", ["mark": "sick"])
        try await setModules(app, a, ["planning": false])
        try await eq(try await scope.days.evaluate(LocalDate("2026-10-12")).mark, .none)
        try await eq(try await scope.days.evaluate(LocalDate("2026-01-01")).mark, .none)
        try await eq(try await scope.days.evaluate(LocalDate("2026-10-13")).mark, .sick)
        try await yes(try list(await api(app, b, .GET, "shares/incoming")).isEmpty)
        try await api(app, b, .GET, "shares/incoming/\(shareID)/view?from=2026-10-12&to=2026-10-13", nil, .notFound)
        let export = try await api(app, a, .GET, "export/time?from=2026-10-12&to=2026-10-12&format=csv")
        XCTAssertFalse(export.body.string.contains("Urlaub"))
        try await setModules(app, a, ["planning": true])
        try await eq(try await scope.days.evaluate(LocalDate("2026-10-12")).mark, .vacation)
        try await eq(try await scope.days.evaluate(LocalDate("2026-01-01")).mark, .holiday)
        try await eq(try list(await api(app, b, .GET, "shares/incoming")).count, 1)
        try await api(app, b, .GET, "shares/incoming/\(shareID)/view?from=2026-10-12&to=2026-10-13")
        try await setModules(app, b, ["planning": false])
        try await api(app, b, .GET, "shares/incoming", nil, .notFound)
        try await api(app, b, .GET, "shares/incoming/\(shareID)/view?from=2026-10-12&to=2026-10-13", nil, .notFound)
        try await eq(try await AbsenceRecord.query(on: app.db).count(), 1)
        try await eq(try await ShareRecord.query(on: app.db).count(), 1)
    }
    func testC20EvaluationSQLite() async throws { try await withApp(scenarioModulesEvaluation) }

    func scenarioModulesMCP(_ app: Application, _ auth: AuthService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let credentials = OAuthCredentialService(auth: auth, oauth: OAuthService(auth: auth))
        let createdToken = try await credentials.createToken(.init(name: "Test", scopes: Array(McpScopes.known), expiresInDays: 1), a, on: app.db)
        let token = try XCTUnwrap(createdToken.token)
        let before = try await mcpRPC(app, token, "tools/list")
        XCTAssertEqual(((before["result"] as? [String: Any])?["tools"] as? [Any])?.count, 22)
        for (key, tool) in [("reports", "get_report_week"), ("planning", "list_absences"), ("transfer", "list_absence_attachments")] {
            try await setModules(app, a, [key: false])
            let list = try await mcpRPC(app, token, "tools/list")
            let tools = (list["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
            XCTAssertFalse(tools.contains { $0["name"] as? String == tool })
            try await mcpFails(app, token, tool, [:], "module_disabled")
            try await setModules(app, a, [key: true])
        }
        try await setModules(app, a, ["mcp": false])
        _ = try await mcpRPC(app, token, "ping", status: .unauthorized)
        try await setModules(app, a, ["mcp": true])
        _ = try await mcpRPC(app, token, "ping")
        let scope = TimeServices(accountId: try a.account.requireID(), db: app.db)
        let device = try await scope.devices.create(.init(name: "Test", expiresInDays: 1))
        let secret = try XCTUnwrap(device.token)
        _ = try await DeviceTokenService.authenticate(secret, db: app.db)
        try await setModules(app, a, ["automation": false])
        await expect("unauthorized") { _ = try await DeviceTokenService.authenticate(secret, db: app.db) }
        let response = try await app.testable().sendRequest(.POST, "/api/v1/automation/events", headers: ["Authorization": "Bearer \(secret)"])
        XCTAssertEqual(response.status, .unauthorized)
        try await setModules(app, a, ["automation": true])
        _ = try await DeviceTokenService.authenticate(secret, db: app.db)
        try await eq(try await ApiTokenRecord.query(on: app.db).count(), 1)
        try await eq(try await DeviceTokenRecord.query(on: app.db).count(), 1)
    }
    func testC20MCPSQLite() async throws { try await withApp(scenarioModulesMCP) }

    func testC20MariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test_c20", "DB_TLS": "off"]
        let scenarios: [Scenario] = [scenarioModulesRoutes, scenarioModulesEvaluation, scenarioModulesMCP, scenarioModulesNotifications, scenarioModulesFilesAndOAuth]
        for scenario in scenarios {
            try await withApp(environment: environment, scenario)
        }
        try await c20Push(database: environment)
    }
}

extension AuthTests {
    func scenarioModulesNotifications(_ app: Application, _ auth: AuthService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let owner = try a.account.requireID()
        let created = notificationDate("2026-10-01T08:00:00Z")
        let now = notificationDate("2026-10-16T15:00:00Z")
        let suggestion = SuggestionRecord(); suggestion.id = UUID(); suggestion.accountId = owner
        suggestion.payload = SuggestionDTO(id: suggestion.id!, type: "start", placeId: nil, proposedStartedAt: created, proposedEndedAt: nil, segmentId: nil, createdAt: created)
        try await suggestion.create(on: app.db)
        let absence = AbsenceRecord(); absence.accountId = owner; absence.kind = "sick"
        absence.startDate = "2026-10-01"; absence.endDate = "2026-10-02"; absence.halfDayStart = false; absence.halfDayEnd = false
        absence.status = "approved"; absence.documentStatus = "pending"; absence.version = 1
        absence.createdAt = created; absence.updatedAt = created; try await absence.create(on: app.db)
        try await setModules(app, a, ["reports": false, "planning": false, "automation": false])
        try await NotificationScheduler.remind(owner, now: now, vapid: false, on: app.db, modules: auth.modules)
        try await eq(try await NotificationRecord.query(on: app.db).count(), 0)
        try await setModules(app, a, ["reports": true, "planning": true, "automation": true])
        try await NotificationScheduler.remind(owner, now: now, vapid: false, on: app.db, modules: auth.modules)
        let notes = try await NotificationRecord.query(on: app.db).all()
        XCTAssertEqual(Set(notes.map(\.kind)), Set(["report_gap", "document_submission", "pending_suggestions"]))
        try await setModules(app, a, ["reports": false, "planning": false, "automation": false], server: true)
        try await NotificationScheduler.remind(owner, now: now.addingTimeInterval(7 * 86400), vapid: false, on: app.db, modules: auth.modules)
        try await eq(try await NotificationRecord.query(on: app.db).count(), 3)
        try await api(app, a, .GET, "notifications")
    }
    func testC20NotificationsSQLite() async throws { try await withApp(scenarioModulesNotifications) }

    func scenarioModulesFilesAndOAuth(_ app: Application, _ auth: AuthService) async throws {
        let (a, _) = try await registered(auth, db: app.db)
        let absence = try await createAbsence(app, a, absenceBody("2026-10-12", kind: "sick"))
        let absenceID = try XCTUnwrap(absence["id"] as? String)
        let upload = try object(await fileUpload(app, a, "test.txt", Self.txt))
        let fileID = try XCTUnwrap(upload["id"] as? String)
        try await api(app, a, .POST, "absences/\(absenceID)/attachments", ["fileId": fileID], .created)
        let job = try object(await importUpload(app, a, "test.csv", Data("Datum;Beginn;Ende\n12.10.2026;08:00;09:00\n".utf8)))
        let jobID = try XCTUnwrap(job["id"] as? String)
        for enabled in [true, false, true] {
            try await setModules(app, a, ["transfer": enabled])
            for path in ["files/\(fileID)", "absences/\(absenceID)/attachments", "imports/\(jobID)"] {
                try await api(app, a, .GET, path, nil, enabled ? .ok : .notFound)
            }
        }
        try await eq(try await StoredFileRecord.query(on: app.db).count(), 1)
        let client = try await oaRegister(app)
        let flow = try await oaFlow(app, a, client: client, scope: "time:read")
        let tokens = try await oaExchange(app, flow)
        _ = try await mcpRPC(app, tokens.access, "ping")
        try await setModules(app, a, ["mcp": false])
        _ = try await mcpRPC(app, tokens.access, "ping", status: .unauthorized)
        let refresh = try await oaToken(app, ["grant_type": "refresh_token", "client_id": client, "refresh_token": tokens.refresh])
        XCTAssertEqual(refresh.status, .badRequest)
        try await setModules(app, a, ["mcp": true])
        _ = try await mcpRPC(app, tokens.access, "ping")
        let restored = try await oaToken(app, ["grant_type": "refresh_token", "client_id": client, "refresh_token": tokens.refresh])
        XCTAssertEqual(restored.status, .ok)
        try await eq(try await OAuthGrant.query(on: app.db).filter(\.$revokedAt != nil).count(), 0)
    }
    func testC20FilesAndOAuthSQLite() async throws { try await withApp(scenarioModulesFilesAndOAuth) }
}

extension AuthTests {
    func c20Push(database: [String: String]) async throws {
        for (kind, key) in [("report_gap", "reports"), ("document_submission", "planning"), ("pending_suggestions", "automation")] {
            let transport = C19PushTransport()
            try await notificationApp(env: vapidEnvironment(), database: database, transport: transport) { app, auth, runtime in
                let now = notificationDate("2026-10-15T12:00:00Z")
                let (owner, _) = try await self.c19Outbox(app, auth, runtime, count: 1, now: now, kind: kind)
                var settings = NotificationSettingsDTO.defaults
                settings.categories[kind]?.push = true
                settings.quietStart = nil; settings.quietEnd = nil
                _ = try await runtime.service.putSettings(owner.account.requireID(), settings, on: app.db)
                try await self.setModules(app, owner, [key: false])
                let sender = PushSender(vapid: try XCTUnwrap(runtime.service.vapid), transport: transport)
                try await PushDispatcher(db: app.db, sender: sender, modules: auth.modules).deliverDue(now: now)
                try await self.eq(await transport.count, 0)
                try await self.eq(try await PushOutboxRecord.query(on: app.db).filter(\.$errorCode == "module_disabled").count(), 1)
                try await self.eq(try await NotificationRecord.query(on: app.db).count(), 1)
            }
        }
    }
    func testC20QueuedPushSQLite() async throws { try await c20Push(database: [:]) }

    func testC20OperatorEvaluationAndNotifications() async throws {
        try await withApp(environment: ["MODULES_DISABLED": "planning,reports,automation"]) { app, auth in
            let (a, _) = try await registered(auth, db: app.db)
            try await self.planningModel(app, a)
            let day = try self.object(await self.api(app, a, .GET, "time/days/2026-01-01"))
            XCTAssertEqual(day["mark"] as? String, "none")
            let owner = try a.account.requireID()
            try await NotificationScheduler.remind(owner, now: notificationDate("2026-10-16T15:00:00Z"), vapid: false, on: app.db, modules: auth.modules)
            try await self.eq(try await NotificationRecord.query(on: app.db).count(), 0)
        }
    }
}
