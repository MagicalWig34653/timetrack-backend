import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

// B2 / ADR-0017: maintenance job. Every class is tested with a stale row, a row exactly at the boundary (must survive,
// the comparison is strict), a row inside the grace period and a still valid row.

/// Fixed clock with whole seconds, so boundary comparisons are exact on SQLite (REAL) and MariaDB (DATETIME(6)).
private let maintenanceNow = Date(timeIntervalSince1970: 1_900_000_000)

extension AuthTests {
    /// A database row class: how to create a row whose relevant instant is `t`, how to count rows, which step handles it.
    struct MaintenanceCase {
        let step: String
        let grace: TimeInterval
        let create: @Sendable (any Database, Date) async throws -> Void
        let count: @Sendable (any Database) async throws -> Int
    }

    func maintenanceCases(account: UUID, client: UUID, grant: UUID, invitation: UUID) -> [MaintenanceCase] {
        let future = maintenanceNow.addingTimeInterval(86_400 * 400)
        return [
            .init(step: "sessions", grace: MaintenanceRetention.expiredSession,
                  create: { db, t in try await Session(accountId: account, tokenHash: Secrets.token(), csrfTokenHash: "c", recovery: false, createdAt: t, expiresAt: t).create(on: db) },
                  count: { try await Session.query(on: $0).count() }),
            .init(step: "sessions", grace: MaintenanceRetention.revokedSession,
                  create: { db, t in try await Session(accountId: account, tokenHash: Secrets.token(), csrfTokenHash: "c", recovery: false, createdAt: t, expiresAt: future, revokedAt: t).create(on: db) },
                  count: { try await Session.query(on: $0).count() }),
            .init(step: "webauthn_challenges", grace: MaintenanceRetention.challenge,
                  create: { db, t in try await WebAuthnChallenge(purpose: .authentication, challenge: Data([1]), payload: [:], expiresAt: t).create(on: db) },
                  count: { try await WebAuthnChallenge.query(on: $0).count() }),
            .init(step: "recovery_attempts", grace: MaintenanceRetention.recoveryAttempt,
                  create: { db, t in try await RecoveryAttempt(kind: .email, accountId: account, codeHash: "h", expiresAt: t, attemptCount: 0, createdAt: t).create(on: db) },
                  count: { try await RecoveryAttempt.query(on: $0).count() }),
            .init(step: "oauth_requests", grace: MaintenanceRetention.oauthRequest,
                  create: { db, t in
                      let row = OAuthRequestRecord(); row.clientId = client; row.redirectURI = "https://x.example/cb"; row.scopes = []; row.codeChallenge = "c"
                      row.resource = "r"; row.createdAt = t; row.expiresAt = t; try await row.create(on: db)
                  },
                  count: { try await OAuthRequestRecord.query(on: $0).count() }),
            .init(step: "oauth_codes", grace: MaintenanceRetention.oauthCode,
                  create: { db, t in
                      let row = OAuthCode(); row.codeHash = Secrets.token(); row.clientId = client; row.accountId = account; row.grantId = grant; row.scopes = []
                      row.redirectURI = "https://x.example/cb"; row.codeChallenge = "c"; row.resource = "r"; row.createdAt = t; row.expiresAt = t
                      try await row.create(on: db)
                  },
                  count: { try await OAuthCode.query(on: $0).count() }),
            .init(step: "oauth_tokens", grace: MaintenanceRetention.oauthToken,
                  create: { db, t in
                      let row = OAuthToken(); row.tokenHash = Secrets.token(); row.kind = "refresh"; row.grantId = grant; row.scopes = []; row.createdAt = t; row.expiresAt = t
                      try await row.create(on: db)
                  },
                  count: { try await OAuthToken.query(on: $0).count() }),
            .init(step: "oidc_states", grace: MaintenanceRetention.oidcState,
                  create: { db, t in
                      try await OIDCState(stateHash: Secrets.token(), nonce: "n", codeVerifier: "v", purpose: .login, inviteId: nil, inviteToken: nil, accountId: nil,
                                          bindingHash: "b", createdAt: t, expiresAt: t).create(on: db)
                  },
                  count: { try await OIDCState.query(on: $0).count() }),
            .init(step: "oidc_pending_registrations", grace: MaintenanceRetention.oidcState,
                  create: { db, t in
                      try await OIDCPendingRegistration(issuer: "i", subject: Secrets.token(), emailHint: nil, invitationId: invitation, bindingHash: "b", createdAt: t, expiresAt: t).create(on: db)
                  },
                  count: { try await OIDCPendingRegistration.query(on: $0).count() }),
            .init(step: "api_tokens", grace: MaintenanceRetention.apiToken,
                  create: { db, t in
                      let row = ApiTokenRecord(); row.accountId = account; row.name = "t"; row.scopes = []; row.tokenHash = Secrets.token(); row.createdAt = t; row.expiresAt = t
                      try await row.create(on: db)
                  },
                  count: { try await ApiTokenRecord.query(on: $0).count() }),
            .init(step: "device_tokens", grace: MaintenanceRetention.deviceToken,
                  create: { db, t in
                      let row = DeviceTokenRecord(); row.accountId = account; row.tokenHash = Secrets.token(); row.scope = "s"; row.name = "n"; row.createdAt = t; row.expiresAt = t
                      try await row.create(on: db)
                  },
                  count: { try await DeviceTokenRecord.query(on: $0).count() }),
            .init(step: "rate_limit_events", grace: MaintenanceRetention.rateLimitEvents,
                  create: { db, t in try await RateLimitEvent(key: "k", occurredAt: t).create(on: db) },
                  count: { try await RateLimitEvent.query(on: $0).count() }),
            .init(step: "mcp_audit", grace: 90 * 86_400,
                  create: { db, t in
                      let row = McpAuditRecord(); row.occurredAt = t; row.credentialKind = "oauth"; row.credentialId = UUID(); row.tool = "t"; row.ok = true; row.durationMs = 1
                      try await row.create(on: db)
                  },
                  count: { try await McpAuditRecord.query(on: $0).count() }),
        ]
    }

    func maintenanceService(_ app: Application, environment: [String: String] = [:]) throws -> MaintenanceService {
        let runtime = try XCTUnwrap(app.maintenanceRuntime)
        guard !environment.isEmpty else { return runtime.service }
        return MaintenanceService(db: app.db, options: try MaintenanceOptions(environment: environment), logger: app.logger, storage: runtime.service.storage)
    }

    func maintenanceClasses(database: [String: String]) async throws {
        try await withApp(environment: database) { app, auth in
            let service = try self.maintenanceService(app)
            let account = try await self.registered(auth, db: app.db).0.account.requireID()
            let client = OAuthClient(); client.name = "c"; client.redirectURIs = ["https://x.example/cb"]; client.createdAt = maintenanceNow; try await client.create(on: app.db)
            let grant = OAuthGrant(); grant.accountId = account; grant.clientId = try client.requireID(); grant.scopes = []; grant.createdAt = maintenanceNow; try await grant.create(on: app.db)
            let firstInvitation = try await Invitation.query(on: app.db).first()
            let invitation = try XCTUnwrap(firstInvitation).requireID()
            for item in self.maintenanceCases(account: account, client: try client.requireID(), grant: try grant.requireID(), invitation: invitation) {
                try await Session.query(on: app.db).delete()  // each case counts its own table; sessions has two cases
                let db = app.db
                let offsets: [TimeInterval] = [
                    -item.grace - 1,      // stale: invalid for longer than the grace
                    -item.grace,          // exactly at the boundary: survives (strict comparison)
                    -item.grace + 1,      // inside the grace period: survives
                    86_400 * 400,         // still valid: survives
                ]
                for offset in offsets { try await item.create(db, maintenanceNow.addingTimeInterval(offset)) }
                try await self.eq(try await item.count(db), 4)
                let report = await service.run(now: maintenanceNow)
                XCTAssertEqual(report.failedSteps, [], item.step)
                XCTAssertGreaterThanOrEqual(report.counts[item.step] ?? 0, 1, item.step)
                try await self.eq(try await item.count(db), 3)
                // Idempotent: a second run finds nothing more to delete and changes nothing.
                let again = await service.run(now: maintenanceNow)
                try await self.eq(again.total, 0)
                try await self.eq(try await item.count(db), 3)
                // The two surviving "old" rows only go once the clock passes the boundary.
                _ = await service.run(now: maintenanceNow.addingTimeInterval(2))
                try await self.eq(try await item.count(db), 1)
                _ = await service.run(now: maintenanceNow.addingTimeInterval(86_400 * 500))
                try await self.eq(try await item.count(db), 0)
            }
        }
    }

    func testMaintenanceClassesSQLite() async throws { try await maintenanceClasses(database: [:]) }
    func testMaintenanceClassesMariaDB() async throws { try await maintenanceClasses(database: try mariaDBEnvironment()) }

    // MARK: Retention and options

    func testMaintenanceAuditRetentionIsConfigurableSQLite() async throws {
        try await withApp { app, _ in
            let service = try self.maintenanceService(app, environment: ["MCP_AUDIT_RETENTION_DAYS": "2"])
            for days in [1.0, 2.0, 3.0] {
                let row = McpAuditRecord(); row.occurredAt = maintenanceNow.addingTimeInterval(-days * 86_400); row.credentialKind = "oauth"
                row.credentialId = UUID(); row.tool = "t"; row.ok = true; row.durationMs = 1; try await row.create(on: app.db)
            }
            _ = await service.run(now: maintenanceNow)
            try await self.eq(try await McpAuditRecord.query(on: app.db).count(), 2)   // 1 day and exactly 2 days survive
        }
    }

    func testMaintenanceOptionsParsing() throws {
        let defaults = try MaintenanceOptions(environment: [:])
        XCTAssertEqual(defaults.intervalMinutes, 60); XCTAssertEqual(defaults.mcpAuditRetentionDays, 90)
        XCTAssertEqual(defaults.importTimeoutHours, 168); XCTAssertEqual(defaults.orphanGraceHours, 168)
        XCTAssertTrue(defaults.runnerEnabled(testing: false)); XCTAssertFalse(defaults.runnerEnabled(testing: true))
        let off = try MaintenanceOptions(environment: ["MAINTENANCE_INTERVAL_MINUTES": "0"])
        XCTAssertFalse(off.runnerEnabled(testing: false)); XCTAssertFalse(off.runnerEnabled(testing: true))
        XCTAssertTrue(try MaintenanceOptions(environment: ["MAINTENANCE_INTERVAL_MINUTES": "5"]).runnerEnabled(testing: true))
        for (key, bad) in [("MAINTENANCE_INTERVAL_MINUTES", "-1"), ("MAINTENANCE_INTERVAL_MINUTES", "abc"), ("MCP_AUDIT_RETENTION_DAYS", "0"),
                           ("IMPORT_JOB_TIMEOUT_HOURS", "0"), ("STORAGE_ORPHAN_GRACE_HOURS", "x")] {
            XCTAssertThrowsError(try MaintenanceOptions(environment: [key: bad]), key) { XCTAssertEqual(($0 as? ConfigurationError)?.key, key) }
        }
    }

    func testMaintenanceDoesNotRunInTestsWithoutExplicitInterval() async throws {
        try await withApp { app, _ in
            let runtime = try XCTUnwrap(app.maintenanceRuntime)
            XCTAssertFalse(runtime.options.runnerEnabled(testing: true))
        }
    }

    // MARK: Large backlogs, batches

    func maintenanceBacklog(database: [String: String]) async throws {
        try await withApp(environment: database) { app, _ in
            let service = try self.maintenanceService(app)
            let stale = MaintenanceRetention.batch * 2 + 37
            for chunk in stride(from: 0, to: stale, by: 100) {
                try await app.db.transaction { tx in
                    for _ in chunk..<min(chunk + 100, stale) { try await RateLimitEvent(key: "k", occurredAt: maintenanceNow.addingTimeInterval(-86_400)).create(on: tx) }
                }
            }
            try await RateLimitEvent(key: "k", occurredAt: maintenanceNow).create(on: app.db)
            let report = await service.run(now: maintenanceNow)
            try await self.eq(report.counts["rate_limit_events"] ?? -1, stale)
            try await self.eq(try await RateLimitEvent.query(on: app.db).count(), 1)
        }
    }
    func testMaintenanceBacklogSQLite() async throws { try await maintenanceBacklog(database: [:]) }
    func testMaintenanceBacklogMariaDB() async throws { try await maintenanceBacklog(database: try mariaDBEnvironment()) }

    // MARK: Push subscriptions and import jobs

    func maintenancePushAndImports(database: [String: String]) async throws {
        try await withApp(environment: database) { app, auth in
            let (owner, _) = try await self.registered(auth, db: app.db)
            let account = try owner.account.requireID()
            let service = try self.maintenanceService(app)
            let silent = maintenanceNow.addingTimeInterval(-MaintenanceRetention.pushSilence)
            func subscription(_ name: String, failures: Int, success: Date?, created: Date) async throws -> UUID {
                let row = PushSubscriptionRecord(); row.accountId = account; row.endpointHash = Secrets.hash(name); row.endpoint = "https://fcm.googleapis.com/\(name)"
                row.p256dh = "k"; row.auth = "a"; row.createdAt = created; row.lastSuccessAt = success; row.failureCount = failures
                try await row.create(on: app.db); return try row.requireID()
            }
            let old = silent.addingTimeInterval(-1), edge = silent, recent = maintenanceNow.addingTimeInterval(-86_400)
            let doomedA = try await subscription("a", failures: 10, success: old, created: old)
            let doomedB = try await subscription("b", failures: 25, success: nil, created: old)
            _ = try await subscription("few-failures", failures: 9, success: old, created: old)
            _ = try await subscription("recent-success", failures: 10, success: recent, created: old)
            _ = try await subscription("never-but-new", failures: 10, success: nil, created: recent)
            _ = try await subscription("boundary", failures: 10, success: edge, created: old)
            _ = try await subscription("boundary-created", failures: 10, success: nil, created: edge)
            for id in [doomedA, doomedB] {   // queued outbox rows go with the subscription
                let notification = try await self.seedNotification(app.db, owner, key: "n-\(id)", at: maintenanceNow)
                let outbox = PushOutboxRecord(); outbox.notificationId = notification; outbox.subscriptionId = id; outbox.status = "pending"
                outbox.attempts = 0; outbox.nextAttemptAt = maintenanceNow; outbox.createdAt = maintenanceNow; try await outbox.create(on: app.db)
            }
            let report = await service.run(now: maintenanceNow)
            try await self.eq(report.counts["push_subscriptions"] ?? -1, 2)
            try await self.eq(try await PushSubscriptionRecord.query(on: app.db).count(), 5)
            try await self.eq(try await PushOutboxRecord.query(on: app.db).count(), 0)

            // Import jobs: open ones past the timeout are discarded with their bytes; everything else stays.
            let cutoff = maintenanceNow.addingTimeInterval(-168 * 3_600)
            func job(_ status: String, at created: Date) async throws -> UUID {
                let row = ImportJobRecord(); row.id = UUID(); row.accountId = account; row.filename = "f.csv"; row.kind = "csv"; row.sha256 = "s"; row.status = status
                row.sheets = []; row.createdAt = created; try await row.create(on: app.db)
                let file = ImportFileRecord(); file.id = UUID(); file.accountId = account; file.jobId = row.id!; file.size = 1; file.bytes = Data([1]); try await file.create(on: app.db)
                return row.id!
            }
            let staleUploaded = try await job("uploaded", at: cutoff.addingTimeInterval(-1)), staleMapped = try await job("mapped", at: cutoff.addingTimeInterval(-1))
            let boundary = try await job("uploaded", at: cutoff), fresh = try await job("mapped", at: maintenanceNow)
            let committed = try await job("committed", at: cutoff.addingTimeInterval(-86_400))
            let reportImports = await service.run(now: maintenanceNow)
            try await self.eq(reportImports.counts["import_jobs"] ?? -1, 2)
            for id in [staleUploaded, staleMapped] {
                try await self.eq(try await ImportJobRecord.find(id, on: app.db) == nil, true)
                try await self.eq(try await ImportFileRecord.query(on: app.db).filter(\.$jobId == id).count(), 0)
            }
            for (id, status) in [(boundary, "uploaded"), (fresh, "mapped"), (committed, "committed")] {
                try await self.eq(try await ImportJobRecord.find(id, on: app.db)?.status ?? "", status)
                try await self.eq(try await ImportFileRecord.query(on: app.db).filter(\.$jobId == id).count(), 1)
            }
            // Nothing left to do.
            try await self.eq(await service.run(now: maintenanceNow).counts["import_jobs"] ?? -1, 0)
        }
    }
    func testMaintenancePushAndImportsSQLite() async throws { try await maintenancePushAndImports(database: [:]) }
    func testMaintenancePushAndImportsMariaDB() async throws { try await maintenancePushAndImports(database: try mariaDBEnvironment()) }

    // MARK: Stored files

    func maintenanceStorage(database: [String: String]) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tt-maint-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let canonical = try XCTUnwrap(LocalFSBackend.realpath(root))
        try await withApp(environment: database) { app, auth in
            let (owner, _) = try await self.registered(auth, db: app.db)
            let account = try owner.account.requireID()
            let service = try self.maintenanceService(app)
            let settings = StorageSettingsRecord()
            settings.id = StorageSettingsRecord.rowId; settings.rules = [.init(maxBytes: nil, backend: .local)]; settings.maxUploadBytes = 1_000_000
            settings.localPath = canonical; settings.s3PathStyle = false; settings.updatedAt = maintenanceNow; try await settings.create(on: app.db)

            // Metadata rows: abandoned pending upload, failed and deleting files go; a fresh pending and a stored file stay.
            func file(_ state: FileState, created: Date, backend: StorageBackendKind = .db) async throws -> UUID {
                let id = UUID(), row = StoredFileRecord()
                row.id = id; row.accountId = account; row.name = "a.pdf"; row.contentType = "application/pdf"; row.size = 3; row.sha256 = "x"; row.backend = backend.rawValue
                row.storageLocation = backend == .db ? "db" : "local:" + canonical; row.storageKey = StorageKeys.make(for: id, kind: backend); row.state = state.rawValue
                row.createdAt = created; row.cleanupAttempts = 0; try await row.create(on: app.db); return id
            }
            let pendingCutoff = maintenanceNow.addingTimeInterval(-MaintenanceRetention.pendingUpload)
            let abandoned = try await file(.pending, created: pendingCutoff.addingTimeInterval(-1))
            let failed = try await file(.failed, created: maintenanceNow), deleting = try await file(.deleting, created: maintenanceNow)
            let boundaryPending = try await file(.pending, created: pendingCutoff), freshPending = try await file(.pending, created: maintenanceNow)
            let stored = try await file(.stored, created: maintenanceNow.addingTimeInterval(-86_400 * 365))
            let report = await service.run(now: maintenanceNow)
            XCTAssertEqual(report.failedSteps, [])
            try await self.eq(report.counts["stored_files"] ?? -1, 3)
            for id in [abandoned, failed, deleting] { try await self.eq(try await StoredFileRecord.find(id, on: app.db) == nil, true) }
            for id in [boundaryPending, freshPending, stored] { try await self.eq(try await StoredFileRecord.find(id, on: app.db) != nil, true) }

            // Database blobs: without a metadata row they go, with one they stay.
            let orphanBlob = FileBlobRecord(); orphanBlob.id = UUID(); orphanBlob.bytes = Data([1, 2]); try await orphanBlob.create(on: app.db)
            let keptBlob = FileBlobRecord(); keptBlob.id = stored; keptBlob.bytes = Data([3]); try await keptBlob.create(on: app.db)
            let blobReport = await service.run(now: maintenanceNow)
            try await self.eq(blobReport.counts["blob_orphans"] ?? -1, 1)
            try await self.eq(try await FileBlobRecord.query(on: app.db).count(), 1)
            try await self.eq(try await FileBlobRecord.find(stored, on: app.db) != nil, true)

            // Local objects: only old, canonical, row-less files are removed.
            let backend = LocalFSBackend(root: canonical)
            let grace = Double(service.options.orphanGraceHours) * 3_600
            let tracked = try await file(.stored, created: maintenanceNow, backend: .local)
            func put(_ id: UUID, age: TimeInterval) throws -> String {
                let key = StorageKeys.make(for: id, kind: .local)
                try backend.writeSync(key: key, data: Data([9]))
                let path = canonical + "/" + key
                try FileManager.default.setAttributes([.modificationDate: maintenanceNow.addingTimeInterval(-age)], ofItemAtPath: path)
                return path
            }
            let trackedPath = try put(tracked, age: grace * 3)                 // old but has metadata
            let orphanPath = try put(UUID(), age: grace + 1)                   // old, no metadata
            let boundaryPath = try put(UUID(), age: grace - 1)                 // not old enough
            let recentPath = try put(UUID(), age: 5)
            let shard = URL(fileURLWithPath: orphanPath).deletingLastPathComponent().path
            let tmpPath = shard + "/.tmp-" + UUID().uuidString.lowercased()
            try Data([1]).write(to: URL(fileURLWithPath: tmpPath))
            try FileManager.default.setAttributes([.modificationDate: maintenanceNow.addingTimeInterval(-grace - 1)], ofItemAtPath: tmpPath)
            let strangePath = shard + "/not-a-uuid.txt"                        // old but not ours: never touched
            try Data([1]).write(to: URL(fileURLWithPath: strangePath))
            try FileManager.default.setAttributes([.modificationDate: maintenanceNow.addingTimeInterval(-grace * 5)], ofItemAtPath: strangePath)
            let outside = FileManager.default.temporaryDirectory.appendingPathComponent("tt-maint-out-\(UUID().uuidString)").path
            try Data([7]).write(to: URL(fileURLWithPath: outside))
            defer { try? FileManager.default.removeItem(atPath: outside) }
            let linkKey = StorageKeys.make(for: UUID(), kind: .local)
            try FileManager.default.createDirectory(atPath: canonical + "/" + (linkKey as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: canonical + "/" + linkKey, withDestinationPath: outside)
            let localReport = await service.run(now: maintenanceNow)
            try await self.eq(localReport.counts["local_orphans"] ?? -1, 2)    // the orphan and the stale temp file
            let fm = FileManager.default
            XCTAssertFalse(fm.fileExists(atPath: orphanPath)); XCTAssertFalse(fm.fileExists(atPath: tmpPath))
            for path in [trackedPath, boundaryPath, recentPath, strangePath, outside] { XCTAssertTrue(fm.fileExists(atPath: path), path) }
            XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: canonical + "/" + linkKey))
            // Stored bytes of the tracked file are still readable.
            try await self.eq(try backend.readSync(key: StorageKeys.make(for: tracked, kind: .local)), Data([9]))
        }
    }
    func testMaintenanceStorageSQLite() async throws { try await maintenanceStorage(database: [:]) }
    func testMaintenanceStorageMariaDB() async throws { try await maintenanceStorage(database: try mariaDBEnvironment()) }

    // MARK: Concurrency and lease

    func maintenanceConcurrency(database: [String: String]) async throws {
        try await withApp(environment: database) { app, _ in
            let first = try XCTUnwrap(app.maintenanceRuntime)
            let second = MaintenanceRuntime(service: first.service, options: first.options)
            let stale = 300
            for chunk in stride(from: 0, to: stale, by: 100) {
                try await app.db.transaction { tx in
                    for _ in chunk..<chunk + 100 { try await RateLimitEvent(key: "k", occurredAt: maintenanceNow.addingTimeInterval(-86_400)).create(on: tx) }
                }
            }
            // 1. Two runners started at the same moment: exactly one executes, the other skips without error.
            async let a = first.tick(now: maintenanceNow), b = second.tick(now: maintenanceNow)
            let results = await [a, b]
            XCTAssertEqual(results.compactMap { $0 }.count, 1, "exactly one runner must hold the lease")
            try await self.eq(results.compactMap { $0 }.first?.counts["rate_limit_events"] ?? -1, stale)
            try await self.eq(try await RateLimitEvent.query(on: app.db).count(), 0)

            // 2. While the lease is held (periodic hold) the other runner and the CLI path are told to skip.
            let held = await first.tick(now: maintenanceNow, hold: 1_800)
            XCTAssertNotNil(held)
            let blocked = await second.tick(now: maintenanceNow.addingTimeInterval(60))
            XCTAssertNil(blocked)
            // 3. The lease expires: another runner takes over; a CLI-style run (no hold) releases it again at once.
            let taken = await second.tick(now: maintenanceNow.addingTimeInterval(1_801))
            XCTAssertNotNil(taken)
            let immediately = await first.tick(now: maintenanceNow.addingTimeInterval(1_802))
            XCTAssertNotNil(immediately, "a released lease can be taken at once")
        }
    }
    func testMaintenanceTwoRunnersSQLite() async throws { try await maintenanceConcurrency(database: [:]) }
    func testMaintenanceTwoRunnersMariaDB() async throws { try await maintenanceConcurrency(database: try mariaDBEnvironment()) }

    /// Without any lease two services deleting the same backlog at the same time must still end in a consistent state.
    func maintenanceUnleasedRace(database: [String: String]) async throws {
        try await withApp(environment: database) { app, _ in
            let service = try self.maintenanceService(app)
            try await app.db.transaction { tx in
                for _ in 0..<400 { try await RateLimitEvent(key: "k", occurredAt: maintenanceNow.addingTimeInterval(-86_400)).create(on: tx) }
                try await RateLimitEvent(key: "keep", occurredAt: maintenanceNow).create(on: tx)
            }
            async let a = service.rateLimitEvents(maintenanceNow), b = service.rateLimitEvents(maintenanceNow)
            _ = try? await (a, b)   // a lost race may report an error on SQLite (locked); the data must be fine either way
            _ = try await service.rateLimitEvents(maintenanceNow)
            try await self.eq(try await RateLimitEvent.query(on: app.db).count(), 1)
            try await self.eq(try await RateLimitEvent.query(on: app.db).first()?.key ?? "", "keep")
        }
    }
    func testMaintenanceUnleasedRaceSQLite() async throws { try await maintenanceUnleasedRace(database: [:]) }
    func testMaintenanceUnleasedRaceMariaDB() async throws { try await maintenanceUnleasedRace(database: try mariaDBEnvironment()) }

    func testMaintenanceReportFormatHasOnlyCounts() {
        var report = MaintenanceReport()
        report.counts = ["sessions": 3, "oauth_codes": 0, "mcp_audit": 12]; report.failedSteps = ["import_jobs"]
        XCTAssertEqual(MaintenanceRuntime.format(report), "deleted 15 (mcp_audit=12 sessions=3); failed steps: import_jobs")
        XCTAssertEqual(MaintenanceRuntime.format(MaintenanceReport()), "deleted 0")
    }

    func testMaintenancePeriodicRunnerDeletesAndStops() async throws {
        let options = try { var options = try MaintenanceOptions(environment: ["MAINTENANCE_INTERVAL_MINUTES": "1"]); options.initialDelay = 0.05; return options }()
        let app = try await Application.make(.testing)
        app.logger.logLevel = .critical
        let config = try Configuration(environment: ["SQLITE_PATH": ":memory:"])
        do {
            try await configure(app, configuration: config, maintenance: options)
            try await app.autoMigrate()
            try await RateLimitEvent(key: "k", occurredAt: Date().addingTimeInterval(-86_400)).create(on: app.db)
            try await RateLimitEvent(key: "keep", occurredAt: Date()).create(on: app.db)
            let runtime = try XCTUnwrap(app.maintenanceRuntime)
            XCTAssertTrue(runtime.options.runnerEnabled(testing: true))
            runtime.start()
            var remaining = 2
            for _ in 0..<100 where remaining != 1 {
                try await Task.sleep(nanoseconds: 100_000_000)
                remaining = try await RateLimitEvent.query(on: app.db).count()
            }
            XCTAssertEqual(remaining, 1)
            await runtime.stop()
            try await app.autoRevert()
        } catch { try await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }
}
