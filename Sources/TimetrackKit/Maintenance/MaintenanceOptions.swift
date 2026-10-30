import Foundation

/// Settings of the maintenance job (ADR-0017). `environment` defaults to the process environment.
public struct MaintenanceOptions: Sendable {
    public var environment: [String: String]
    /// Minutes between periodic runs; 0 disables the in-process runner (the CLI command still works).
    public let intervalMinutes: Int
    /// Retention of `mcp_audit` rows in days.
    public let mcpAuditRetentionDays: Int
    /// Closed or expired polls and order rounds are deleted this many days after closing (or after their deadline).
    public let groupsRetentionDays: Int
    /// Open import jobs (uploaded/mapped) older than this many hours are marked `failed` and lose their file.
    public let importTimeoutHours: Int
    /// Storage objects without metadata are only removed once they are older than this many hours.
    public let orphanGraceHours: Int
    /// Test hook: delay before the first periodic run (default 15...75 s random, so replicas do not align).
    var initialDelay: TimeInterval?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        func integer(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) throws -> Int {
            guard let raw = environment[key], !raw.isEmpty else { return fallback }
            guard let value = Int(raw), range.contains(value) else {
                throw ConfigurationError(key: key, reason: "must be an integer in \(range)")
            }
            return value
        }
        self.environment = environment
        intervalMinutes = try integer("MAINTENANCE_INTERVAL_MINUTES", 60, 0...10_080)
        mcpAuditRetentionDays = try integer("MCP_AUDIT_RETENTION_DAYS", 90, 1...3650)
        groupsRetentionDays = try integer("GROUPS_RETENTION_DAYS", GroupLimits.defaultRetentionDays, 1...3650)
        importTimeoutHours = try integer("IMPORT_JOB_TIMEOUT_HOURS", 168, 1...8760)
        orphanGraceHours = try integer("STORAGE_ORPHAN_GRACE_HOURS", 168, 1...8760)
    }

    /// The periodic runner is off with interval 0; the testing environment only runs it when the interval is set explicitly.
    func runnerEnabled(testing: Bool) -> Bool {
        guard intervalMinutes > 0 else { return false }
        return !testing || environment["MAINTENANCE_INTERVAL_MINUTES"] != nil
    }
}

/// Fixed grace periods and batch sizes. Rows are only removed once they are invalid for at least this long
/// (strictly older than `now - grace`); a row exactly at the boundary survives.
enum MaintenanceRetention {
    /// Expired sessions are kept one day (support/debugging), revoked ones for a week.
    static let expiredSession: TimeInterval = 86_400
    static let revokedSession: TimeInterval = 7 * 86_400
    static let challenge: TimeInterval = 3_600
    static let recoveryAttempt: TimeInterval = 3_600
    static let oauthRequest: TimeInterval = 86_400
    static let oauthCode: TimeInterval = 86_400
    /// Refresh tokens stay for reuse detection until they expire; afterwards one more week.
    static let oauthToken: TimeInterval = 7 * 86_400
    static let oidcState: TimeInterval = 3_600
    /// Expired personal tokens remain visible in the token list for 30 days.
    static let apiToken: TimeInterval = 30 * 86_400
    static let deviceToken: TimeInterval = 30 * 86_400
    /// Longest rate-limit window in the code base is 3600 s (push test); keep twice that.
    static let rateLimitEvents: TimeInterval = 7_200
    /// A push subscription with this many consecutive failures and no success for the period below is dropped.
    static let pushFailureCount = 10
    static let pushSilence: TimeInterval = 30 * 86_400
    /// Pending uploads that never completed (abandoned) are purged after this age.
    static let pendingUpload: TimeInterval = 6 * 3_600
    static let batch = 500
    /// At most `batch * maxRounds` rows per table and run.
    static let maxRounds = 20
    static let maxOrphanFilesPerRun = 500
    static let maxScannedEntries = 100_000
    static let leaseTTL: TimeInterval = 600
}
