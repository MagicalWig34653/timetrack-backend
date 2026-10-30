import Foundation
import Fluent
import FluentSQL
import Vapor

/// Counts per cleanup class; never contains identifiers or personal data. Safe to log.
public struct MaintenanceReport: Sendable, Equatable {
    public var counts: [String: Int] = [:]
    /// Step names whose execution failed (the error text is not kept).
    public var failedSteps: [String] = []
    /// True when the run was aborted because the lease was lost between two steps.
    public var leaseLost = false
    public var total: Int { counts.values.reduce(0, +) }
}

/// Deletes expired and stale rows (ADR-0017). Every step is idempotent, batch-limited and only removes rows that
/// have been invalid for longer than their grace period. Cross-process exclusion is the caller's job (`MaintenanceRuntime`).
struct MaintenanceService: Sendable {
    let db: any Database
    let options: MaintenanceOptions
    let logger: Logger
    /// Builds the storage service lazily (needs the HTTP client and the storage environment of the application).
    let storage: @Sendable () -> StorageService

    typealias Checkpoint = @Sendable () async -> Bool

    /// Runs all steps in a fixed order. `checkpoint` is awaited before each step; `false` aborts the run.
    func run(now: Date = Date(), checkpoint: Checkpoint = { true }) async -> MaintenanceReport {
        var report = MaintenanceReport()
        let steps: [(String, @Sendable () async throws -> Int)] = [
            ("sessions", { try await self.sessions(now) }),
            ("webauthn_challenges", { try await self.challenges(now) }),
            ("recovery_attempts", { try await self.recoveryAttempts(now) }),
            ("oauth_requests", { try await self.oauthRequests(now) }),
            ("oauth_codes", { try await self.oauthCodes(now) }),
            ("oauth_tokens", { try await self.oauthTokens(now) }),
            ("oidc_states", { try await self.oidcStates(now) }),
            ("oidc_pending_registrations", { try await self.oidcPending(now) }),
            ("api_tokens", { try await self.apiTokens(now) }),
            ("device_tokens", { try await self.deviceTokens(now) }),
            ("rate_limit_events", { try await self.rateLimitEvents(now) }),
            ("mcp_audit", { try await self.mcpAudit(now) }),
            ("push_subscriptions", { try await self.pushSubscriptions(now) }),
            ("group_polls", { try await self.groupPolls(now) }),
            ("group_orders", { try await self.groupOrders(now) }),
            ("import_jobs", { try await self.importJobs(now) }),
            ("stored_files", { try await self.storedFiles(now) }),
            ("blob_orphans", { try await self.blobOrphans() }),
            ("local_orphans", { try await self.localOrphans(now) }),
        ]
        for (name, step) in steps {
            guard await checkpoint() else { report.leaseLost = true; break }
            do { report.counts[name] = try await step() }
            catch {
                report.failedSteps.append(name)
                logger.warning("maintenance step \(name) failed (\(type(of: error)))")
            }
        }
        return report
    }

    // MARK: Generic batched delete

    /// Selects up to `batch` ids matching `filter` and deletes them, repeating while full batches come back.
    private func purge<M: Model>(_ type: M.Type, _ filter: @Sendable (QueryBuilder<M>) -> QueryBuilder<M>) async throws -> Int where M.IDValue == UUID {
        var total = 0
        for _ in 0..<MaintenanceRetention.maxRounds {
            let ids = try await filter(M.query(on: db)).limit(MaintenanceRetention.batch).all().compactMap(\.id)
            if ids.isEmpty { break }
            try await M.query(on: db).filter(\._$id ~~ ids).delete()
            total += ids.count
            if ids.count < MaintenanceRetention.batch { break }
        }
        return total
    }

    // MARK: Authentication state

    func sessions(_ now: Date) async throws -> Int {
        let expired = now.addingTimeInterval(-MaintenanceRetention.expiredSession)
        let revoked = now.addingTimeInterval(-MaintenanceRetention.revokedSession)
        return try await purge(Session.self) { query in
            query.group(.or) { $0.filter(\.$expiresAt < expired); $0.filter(\.$revokedAt < revoked) }
        }
    }

    func challenges(_ now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-MaintenanceRetention.challenge)
        return try await purge(WebAuthnChallenge.self) { $0.filter(\.$expiresAt < cutoff) }
    }

    /// Covers e-mail codes, e-mail verification codes and every other recovery attempt (`recovery_attempts`).
    /// The permanent recovery codes (`recovery_codes`) are user data and are never touched.
    func recoveryAttempts(_ now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-MaintenanceRetention.recoveryAttempt)
        return try await purge(RecoveryAttempt.self) { $0.filter(\.$expiresAt < cutoff) }
    }

    func oauthRequests(_ now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-MaintenanceRetention.oauthRequest)
        return try await purge(OAuthRequestRecord.self) { $0.filter(\.$expiresAt < cutoff) }
    }

    func oauthCodes(_ now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-MaintenanceRetention.oauthCode)
        return try await purge(OAuthCode.self) { $0.filter(\.$expiresAt < cutoff) }
    }

    func oauthTokens(_ now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-MaintenanceRetention.oauthToken)
        return try await purge(OAuthToken.self) { $0.filter(\.$expiresAt < cutoff) }
    }

    func oidcStates(_ now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-MaintenanceRetention.oidcState)
        return try await purge(OIDCState.self) { $0.filter(\.$expiresAt < cutoff) }
    }

    func oidcPending(_ now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-MaintenanceRetention.oidcState)
        return try await purge(OIDCPendingRegistration.self) { $0.filter(\.$expiresAt < cutoff) }
    }

    func apiTokens(_ now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-MaintenanceRetention.apiToken)
        return try await purge(ApiTokenRecord.self) { $0.filter(\.$expiresAt < cutoff) }
    }

    /// Device (Shortcuts) tokens without an expiry are never removed here.
    func deviceTokens(_ now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-MaintenanceRetention.deviceToken)
        return try await purge(DeviceTokenRecord.self) { $0.filter(\.$expiresAt < cutoff) }
    }

    func rateLimitEvents(_ now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-MaintenanceRetention.rateLimitEvents)
        return try await purge(RateLimitEvent.self) { $0.filter(\.$occurredAt < cutoff) }
    }

    func mcpAudit(_ now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(options.mcpAuditRetentionDays) * 86_400)
        return try await purge(McpAuditRecord.self) { $0.filter(\.$occurredAt < cutoff) }
    }

    // MARK: Groups (ADR-0033)

    /// Polls and rounds that were closed (or whose deadline passed) more than `GROUPS_RETENTION_DAYS` ago, with all children.
    /// Items that are still open without a deadline are never removed.
    func groupPolls(_ now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(options.groupsRetentionDays) * 86_400)
        var total = 0
        for _ in 0..<MaintenanceRetention.maxRounds {
            let ids = try await GroupPollRecord.query(on: db).group(.or) { or in
                or.group(.and) { $0.filter(\.$closedAt != nil).filter(\.$closedAt < cutoff) }
                or.group(.and) { $0.filter(\.$closedAt == nil).filter(\.$deadline != nil).filter(\.$deadline < cutoff) }
            }.limit(MaintenanceRetention.batch).all().compactMap(\.id)
            if ids.isEmpty { break }
            try await GroupPurge.polls(ids, on: db)
            total += ids.count
            if ids.count < MaintenanceRetention.batch { break }
        }
        return total
    }

    func groupOrders(_ now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(options.groupsRetentionDays) * 86_400)
        var total = 0
        for _ in 0..<MaintenanceRetention.maxRounds {
            let ids = try await GroupOrderRecord.query(on: db).group(.or) { or in
                or.group(.and) { $0.filter(\.$closedAt != nil).filter(\.$closedAt < cutoff) }
                or.group(.and) { $0.filter(\.$closedAt == nil).filter(\.$deadline != nil).filter(\.$deadline < cutoff) }
            }.limit(MaintenanceRetention.batch).all().compactMap(\.id)
            if ids.isEmpty { break }
            try await GroupPurge.orders(ids, on: db)
            total += ids.count
            if ids.count < MaintenanceRetention.batch { break }
        }
        return total
    }

    // MARK: Push and imports

    /// The delivery path removes subscriptions on 404/410 at once; this drops subscriptions that kept failing
    /// without a success for 30 days (e.g. a service answering with a persistent error) together with their outbox rows.
    func pushSubscriptions(_ now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-MaintenanceRetention.pushSilence)
        var total = 0
        for _ in 0..<MaintenanceRetention.maxRounds {
            let rows = try await PushSubscriptionRecord.query(on: db)
                .filter(\.$failureCount >= MaintenanceRetention.pushFailureCount)
                .group(.or) { group in
                    group.filter(\.$lastSuccessAt < cutoff)
                    group.group(.and) { $0.filter(\.$lastSuccessAt == nil); $0.filter(\.$createdAt < cutoff) }
                }
                .limit(MaintenanceRetention.batch).all()
            if rows.isEmpty { break }
            for row in rows {
                try await db.transaction { tx in try await NotificationService.remove(row, on: tx) }
            }
            total += rows.count
            if rows.count < MaintenanceRetention.batch { break }
        }
        return total
    }

    /// Open jobs (uploaded/mapped) older than the timeout hold up to 5 MiB each and count against the per-account limit
    /// of 20. They are discarded exactly like a user discard: file, mapping and job row go. The `import_jobs.status` check
    /// constraint has no `failed` value and rewriting it needs a table rebuild on SQLite (ADR-0017), so jobs are removed
    /// instead of being marked. Committed and rolled-back jobs (with their batches) are never touched.
    func importJobs(_ now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(options.importTimeoutHours) * 3_600)
        var total = 0
        for _ in 0..<MaintenanceRetention.maxRounds {
            let ids = try await ImportJobRecord.query(on: db)
                .group(.or) { $0.filter(\.$status == "uploaded"); $0.filter(\.$status == "mapped") }
                .filter(\.$createdAt < cutoff).limit(MaintenanceRetention.batch).all().compactMap(\.id)
            if ids.isEmpty { break }
            try await db.transaction { tx in
                try await ImportFileRecord.query(on: tx).filter(\.$jobId ~~ ids).delete()
                try await ImportMappingRecord.query(on: tx).filter(\.$jobId ~~ ids).delete()
                try await ImportJobRecord.query(on: tx).filter(\.$id ~~ ids)
                    .group(.or) { $0.filter(\.$status == "uploaded"); $0.filter(\.$status == "mapped") }.delete()
            }
            total += ids.count
            if ids.count < MaintenanceRetention.batch { break }
        }
        return total
    }

    // MARK: Storage

    /// Retries removals of `deleting`/`failed` files and purges uploads that never completed (`pending` for six hours).
    func storedFiles(_ now: Date) async throws -> Int {
        try await storage().cleanup(limit: MaintenanceRetention.batch, pendingOlderThan: MaintenanceRetention.pendingUpload, now: now)
    }

    /// Blobs of the database adapter without a metadata row. The upload creates its `pending` row first and writes
    /// the blob in the transaction that marks it `stored`, and a delete removes both in one transaction, so a blob
    /// without a row only remains after manual changes or a partial restore.
    func blobOrphans() async throws -> Int {
        let sql = try requireSQL(db)
        var total = 0
        for _ in 0..<MaintenanceRetention.maxRounds {
            let rows = try await sql.raw("SELECT id FROM file_blobs WHERE id NOT IN (SELECT id FROM stored_files) LIMIT \(unsafeRaw: String(MaintenanceRetention.batch))").all()
            let ids = try rows.map { try $0.decode(column: "id", as: UUID.self) }
            if ids.isEmpty { break }
            try await FileBlobRecord.query(on: db).filter(\.$id ~~ ids).delete()
            total += ids.count
            if ids.count < MaintenanceRetention.batch { break }
        }
        return total
    }

    /// Objects below the configured local storage root that have no `stored_files` row and are older than the orphan
    /// grace (default one week), plus leftover `.tmp-*` upload files of the same age. Only canonical shard paths
    /// (`ab/cd/<uuid>` with matching prefix) are considered; symlinks are never followed. S3 buckets are not listed:
    /// the metadata row always exists before the object is written, so `cleanup` already covers failed uploads there.
    func localOrphans(_ now: Date) async throws -> Int {
        guard let settings = try await StorageSettingsRecord.query(on: db).first(),
              let path = settings.localPath, path.hasPrefix("/"), let root = LocalFSBackend.realpath(path) else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(options.orphanGraceHours) * 3_600)
        let found = await Task.detached(priority: .utility) { LocalOrphanScanner.scan(root: root, olderThan: cutoff) }.value
        var removed = 0
        let backend = LocalFSBackend(root: root)
        let keyed = found.compactMap { candidate -> (LocalOrphanScanner.Candidate, UUID)? in
            guard let key = candidate.key, let id = UUID(uuidString: String(key.split(separator: "/").last ?? "")) else { return nil }
            return (candidate, id)
        }
        var known = Set<UUID>()
        let allIds = keyed.map(\.1)
        var offset = 0
        while offset < allIds.count {
            let slice = Array(allIds[offset..<min(offset + 200, allIds.count)])
            for id in try await StoredFileRecord.query(on: db).filter(\.$id ~~ slice).all().compactMap(\.id) { known.insert(id) }
            offset += 200
        }
        for (candidate, id) in keyed where !known.contains(id) {
            if let key = candidate.key, (try? backend.deleteSync(key: key)) != nil { removed += 1 }
        }
        for candidate in found where candidate.key == nil {
            if LocalOrphanScanner.removeTemporary(candidate.path, root: root) { removed += 1 }
        }
        return removed
    }
}

/// Walks `root/ab/cd/*` without following symlinks.
enum LocalOrphanScanner {
    struct Candidate: Sendable { let path: String; let key: String? }

    static func scan(root: String, olderThan cutoff: Date) -> [Candidate] {
        let fm = FileManager.default
        var result: [Candidate] = []
        var scanned = 0
        func attributes(_ path: String) -> (type: FileAttributeType, modified: Date)? {
            guard let attrs = try? fm.attributesOfItem(atPath: path), let type = attrs[.type] as? FileAttributeType,
                  let modified = attrs[.modificationDate] as? Date else { return nil }
            return (type, modified)
        }
        func shard(_ name: String) -> Bool { name.count == 2 && name.allSatisfy { "0123456789abcdef".contains($0) } }
        guard let firsts = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        for first in firsts.sorted() where shard(first) {
            guard attributes(root + "/" + first)?.type == .typeDirectory,
                  let seconds = try? fm.contentsOfDirectory(atPath: root + "/" + first) else { continue }
            for second in seconds.sorted() where shard(second) {
                let directory = root + "/" + first + "/" + second
                guard attributes(directory)?.type == .typeDirectory, let names = try? fm.contentsOfDirectory(atPath: directory) else { continue }
                for name in names.sorted() {
                    scanned += 1
                    if scanned > MaintenanceRetention.maxScannedEntries || result.count >= MaintenanceRetention.maxOrphanFilesPerRun { return result }
                    let path = directory + "/" + name
                    guard let info = attributes(path), info.type == .typeRegular, info.modified < cutoff else { continue }
                    let key = first + "/" + second + "/" + name
                    if StorageKeys.isValidShardedKey(key) { result.append(.init(path: path, key: key)) }
                    else if name.hasPrefix(".tmp-") { result.append(.init(path: path, key: nil)) }
                }
            }
        }
        return result
    }

    /// Unlinks a regular file whose parent directories stay below `root`.
    static func removeTemporary(_ path: String, root: String) -> Bool {
        guard let parent = LocalFSBackend.realpath((path as NSString).deletingLastPathComponent),
              parent.hasPrefix(root + "/"),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path), attrs[.type] as? FileAttributeType == .typeRegular else { return false }
        return unlink(path) == 0
    }
}
