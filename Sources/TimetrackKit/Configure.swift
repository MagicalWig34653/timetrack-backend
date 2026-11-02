import Vapor
import Fluent
import FluentMySQLDriver
import FluentSQLiteDriver

public func configure(_ app: Application, configuration: Configuration? = nil, mailSender: (any MailSender)? = nil,
                      notifications: NotificationOptions = NotificationOptions(), maintenance: MaintenanceOptions? = nil) async throws {
    let config = try configuration ?? Configuration()
    // Diagnostics only: DB_SQL_LOG=1 logs every statement at info level (query-count measurements and tests).
    let sqlLog: Logger.Level? = ProcessInfo.processInfo.environment["DB_SQL_LOG"] == "1" ? .info : nil
    switch config.databaseDriver {
    case .sqlite:
        app.databases.use(.sqlite(config.sqlitePath == ":memory:" ? .memory : .file(config.sqlitePath),
                                  sqlLogLevel: sqlLog), as: .sqlite)
    case .mariadb:
        // Explicitly override the driver's default TLS configuration for local development.
        var mysql = MySQLConfiguration(hostname: config.dbHost, port: config.dbPort,
                                       username: config.dbUser, password: config.dbPassword,
                                       database: config.dbName)
        if config.dbTLS == .off { mysql.tlsConfiguration = nil }
        app.databases.use(.mysql(configuration: mysql, maxConnectionsPerEventLoop: config.dbPoolConnectionsPerLoop, connectionPoolTimeout: .seconds(Int64(config.dbPoolTimeoutSeconds)), sqlLogLevel: sqlLog), as: .mysql)
        // Idle pooled connections are silently dropped by NAT/IPVS (Swarm routing mesh: 15 min), firewalls and
        // proxies; the next request that drew such a connection failed ("server not ready", fine after reload).
        // A cheap ping per event loop every 45 s keeps them alive and replaces dead ones before users hit them.
        app.lifecycle.use(DatabaseStartupCheck(host: config.dbHost, port: config.dbPort, tls: config.dbTLS == .off ? "off" : "required", perLoop: config.dbPoolConnectionsPerLoop, timeout: config.dbPoolTimeoutSeconds))
        if config.dbKeepAliveSeconds > 0 { app.lifecycle.use(DatabaseKeepAlive(intervalSeconds: config.dbKeepAliveSeconds, connectionsPerLoop: config.dbPoolConnectionsPerLoop, pingDeadlineSeconds: Double(min(5, config.dbPoolTimeoutSeconds)))) }
    }
    // Change marks first: the middleware registered below writes to this table during every later data migration.
    app.migrations.add(CreateTimeChangeMarks())
    app.registerTimeChangeMarks(on: config.databaseDriver == .sqlite ? .sqlite : .mysql)
    for migration in StageOneSchema.migrations { app.migrations.add(migration) }
    app.migrations.add(CreateAuthLock())
    for migration in StageTwoSchema.migrations { app.migrations.add(migration) }
    for migration in StageThreeSchema.migrations { app.migrations.add(migration) }
    for migration in ImportSchema.migrations { app.migrations.add(migration) }
    for migration in StorageSchema.migrations { app.migrations.add(migration) }
    for migration in OIDCSchema.migrations { app.migrations.add(migration) }
    for migration in ReportSchema.migrations { app.migrations.add(migration) }
    for migration in McpSchemaMigrations.migrations { app.migrations.add(migration) }
    for migration in OAuthSchema.migrations { app.migrations.add(migration) }
    for migration in NotificationSchema.migrations { app.migrations.add(migration) }
    app.migrations.add(CreateModuleSettings())
    app.migrations.add(EnableExcusedAbsences())
    app.migrations.add(CreateWorktimeImportItems())
    for migration in AccountSchema.migrations { app.migrations.add(migration) }
    for migration in AuthHardeningSchema.migrations { app.migrations.add(migration) }
    app.migrations.add(AddSegmentTimeIndex())
    app.migrations.add(AddPlanDayTimes())
    app.migrations.add(AddPlanBlocks())
    app.migrations.add(CreateVacationRequestForms())
    app.migrations.add(CreateTriggerLinks())
    app.migrations.add(CreateCalendarFeeds())
    app.migrations.add(AddLegalWorkProfile())
    app.migrations.add(AddCompanyDays())
    app.migrations.add(AddAdjustmentCreatedAt())
    app.migrations.add(AllowRecordedAbsenceStatus())
    app.migrations.add(NormaliseAbsenceStatuses())
    app.migrations.add(UnifyRecoveryEmail())
    app.migrations.add(CreateGroups())
    app.migrations.add(AddGroupLinkTokens())
    // Fluent installs the migrate command, including --revert and the global --yes flag.
    // Do not auto-apply migrations before explicit migrate/revert commands.
    if config.autoMigrate && !app.environment.arguments.contains("migrate") {
        try await app.autoMigrate()
    }
    let sender = try mailSender ?? config.smtp.map { try SMTPMailSender(configuration: $0, group: app.eventLoopGroup,
        brand: MailBrand(productName: config.webAuthnRPName, operatorName: $0.fromName, baseURL: config.publicBaseURL)) }
    app.trustedProxies = config.trustedProxies
    if config.pwaCSPMode != .enforce { app.logger.warning("PWA_CSP_MODE=\(config.pwaCSPMode.rawValue): the Content-Security-Policy of the PWA is not enforced. Restore the default (enforce) once the cause is fixed.") }
    for warning in config.trustedProxies.startupWarnings(behindTLSProxy: config.publicBaseURL.scheme == "https") { app.logger.warning("\(warning)") }
    let service = AuthService(configuration: config, mailSender: sender)
    // Replace Vapor's default error and URL logging middleware: invite URLs contain secrets.
    app.middleware = Middlewares()
    // Outermost: also decorates error responses and the responses of every other middleware (SEC-05).
    app.middleware.use(SecurityHeadersMiddleware(hstsMaxAgeSeconds: config.publicBaseURL.scheme == "https" ? config.hstsMaxAgeSeconds : 0))
    app.middleware.use(GroupPublicMiddleware())
    app.middleware.use(APIErrorMiddleware())
    app.middleware.use(TimeErrorMiddleware())
    app.middleware.use(ModuleGuard(auth: service))
    app.middleware.use(DeviceScopeGuard())
    app.middleware.use(PWAStaticMiddleware(directory: config.pwaStaticDirectory, cspMode: config.pwaCSPMode))
    app.asyncCommands.use(BootstrapAdmin(service: service), as: "bootstrap-admin")
    registerRoutes(app, service: service)
    try app.installNotifications(auth: service, options: notifications)
    if let runtime = app.notificationRuntime { registerNotificationRoutes(app, auth: service, service: runtime.service) }
    app.installMaintenance(auth: service, options: try maintenance ?? MaintenanceOptions())
    logFeatureOverview(app, config: config, notificationStatuses: app.notificationRuntime?.featureStatuses ?? [])
}

/// One start-up overview of the optional features (which are on or off and why). Never prints secret values.
func logFeatureOverview(_ app: Application, config: Configuration, notificationStatuses: [FeatureStatus]) {
    let modules = config.disabledModules.map(\.rawValue).sorted()
    let storage: [FeatureStatus] = [
        .on("Files", "storage rules are managed in the admin UI; local-path root restriction " + (EnvironmentSanitizer.processValue("STORAGE_LOCAL_ROOT") == nil ? "none" : "set")
            + ", S3 credential key " + (EnvironmentSanitizer.processValue("STORAGE_SECRET_KEY") == nil ? "NOT set (S3 unusable)" : "set")),
        modules.isEmpty ? .on("Modules", "all modules available") : .on("Modules", "disabled by operator: \(modules.joined(separator: ", "))")
    ]
    app.logger.notice("\(FeatureSummary.header)")
    for status in config.featureStatuses + notificationStatuses + storage { app.logger.notice("\(status.logLine)") }
}

public struct StatusResponse: Content { public let status: String }
struct NotReadyResponse: Content {
    struct Detail: Content {
        var code = "not_ready"
        var message = "Database unavailable or migrations pending."
    }
    var error = Detail()
}

private struct UncheckedDatabase: @unchecked Sendable { let database: any Database }

/// Pings the MariaDB pool of every event loop periodically (see `configure`).
final class DatabaseKeepAlive: LifecycleHandler, @unchecked Sendable {
    private var task: Task<Void, Never>?
    let intervalSeconds: Int, connectionsPerLoop: Int, pingDeadlineSeconds: Double
    init(intervalSeconds: Int, connectionsPerLoop: Int, pingDeadlineSeconds: Double = PoolHealth.pingDeadlineSeconds) {
        self.intervalSeconds = intervalSeconds; self.connectionsPerLoop = connectionsPerLoop; self.pingDeadlineSeconds = pingDeadlineSeconds
    }
    func didBoot(_ application: Application) throws {
        let app = application
        let interval = intervalSeconds, perLoop = connectionsPerLoop, deadline = pingDeadlineSeconds
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                // One task per event loop: a ping that hangs on a dead connection must not stop the pings of the other loops.
                // The ping closes a connection that does not answer in time (PoolHealth), so the pool replaces it.
                let databases = PoolHealth.loopDatabases(app)
                await withTaskGroup(of: Void.self) { group in
                    for (index, database) in databases.enumerated() {
                        let box = UncheckedDatabase(database: database)
                        group.addTask {
                            for _ in 0..<perLoop {
                                do { try await PoolHealth.ping(box.database, deadline: deadline); break }
                                catch { app.logger.warning("database keep-alive ping failed (event loop \(index)): \(String(describing: error))") }
                            }
                        }
                    }
                }
            }
        }
    }
    func shutdown(_ application: Application) { task?.cancel() }
}

/// One connection test at startup with an operator-friendly result in the log (host, TLS mode, pool settings, round trip,
/// and a classified reason on failure). It never blocks startup and never prints the password.
final class DatabaseStartupCheck: LifecycleHandler, @unchecked Sendable {
    let host: String, port: Int, tls: String, perLoop: Int, timeout: Int
    init(host: String, port: Int, tls: String, perLoop: Int, timeout: Int) {
        self.host = host; self.port = port; self.tls = tls; self.perLoop = perLoop; self.timeout = timeout
    }
    func didBoot(_ application: Application) throws {
        let app = application
        let summary = "host=\(host) port=\(port) tls=\(tls) poolPerLoop=\(perLoop) poolTimeout=\(timeout)s"
        Task {
            let start = Date()
            do {
                guard let db = app.databases.database(.mysql, logger: app.logger, on: app.eventLoopGroup.next()) else { return }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await db.withConnection { try await requireSQL($0).raw("SELECT 1").run() } }
                    group.addTask { try await Task.sleep(nanoseconds: 15_000_000_000); throw DatabaseCheckTimeout() }
                    _ = try await group.next()
                    group.cancelAll()
                }
                app.logger.notice("database connection OK in \(Int(Date().timeIntervalSince(start) * 1000)) ms (\(summary))")
            } catch {
                let text = String(describing: error)
                let lower = text.lowercased()
                let reason =
                    error is DatabaseCheckTimeout || lower.contains("timeout") || lower.contains("timed out") ? "no answer within 15 s (network, firewall, wrong host/port, or DNS/IPv6 fallback)" :
                    lower.contains("tls") || lower.contains("ssl") || lower.contains("certificate") ? "TLS handshake or certificate verification failed (DB_TLS=required verifies against the image's default CAs; a private CA needs DB_TLS=off or a public certificate)" :
                    lower.contains("nodename") || lower.contains("resolve") || lower.contains("name or service") || lower.contains("getaddrinfo") ? "host name could not be resolved (DNS)" :
                    lower.contains("access denied") || lower.contains("authentication") ? "access denied (user, password or host grant)" :
                    lower.contains("refused") ? "connection refused (wrong port or server not listening)" :
                    "unclassified"
                app.logger.error("database connection FAILED after \(Int(Date().timeIntervalSince(start) * 1000)) ms (\(summary)): \(reason). Detail: \(text)")
            }
        }
    }
}
private struct DatabaseCheckTimeout: Error {}
