import Vapor
import Fluent
import FluentMySQLDriver
import FluentSQLiteDriver

public func configure(_ app: Application, configuration: Configuration? = nil, mailSender: (any MailSender)? = nil) async throws {
    let config = try configuration ?? Configuration()
    switch config.databaseDriver {
    case .sqlite:
        app.databases.use(.sqlite(config.sqlitePath == ":memory:" ? .memory : .file(config.sqlitePath),
                                  sqlLogLevel: nil), as: .sqlite)
    case .mariadb:
        // Explicitly override the driver's default TLS configuration for local development.
        var mysql = MySQLConfiguration(hostname: config.dbHost, port: config.dbPort,
                                       username: config.dbUser, password: config.dbPassword,
                                       database: config.dbName)
        if config.dbTLS == .off { mysql.tlsConfiguration = nil }
        app.databases.use(.mysql(configuration: mysql, sqlLogLevel: nil), as: .mysql)
    }
    for migration in StageOneSchema.migrations { app.migrations.add(migration) }
    app.migrations.add(CreateAuthLock())
    for migration in StageTwoSchema.migrations { app.migrations.add(migration) }
    for migration in StageThreeSchema.migrations { app.migrations.add(migration) }
    for migration in ImportSchema.migrations { app.migrations.add(migration) }
    for migration in StorageSchema.migrations { app.migrations.add(migration) }
    // Fluent installs the migrate command, including --revert and the global --yes flag.
    // Do not auto-apply migrations before explicit migrate/revert commands.
    if config.autoMigrate && !app.environment.arguments.contains("migrate") {
        try await app.autoMigrate()
    }
    let sender = try mailSender ?? config.smtp.map { try SMTPMailSender(configuration: $0, group: app.eventLoopGroup) }
    let service = AuthService(configuration: config, mailSender: sender)
    // Replace Vapor's default error and URL logging middleware: invite URLs contain secrets.
    app.middleware = Middlewares()
    app.middleware.use(APIErrorMiddleware())
    app.middleware.use(TimeErrorMiddleware())
    app.middleware.use(DeviceScopeGuard())
    app.middleware.use(PWAStaticMiddleware(directory: config.pwaStaticDirectory))
    app.asyncCommands.use(BootstrapAdmin(service: service), as: "bootstrap-admin")
    registerRoutes(app, service: service)
}

public struct StatusResponse: Content { public let status: String }
struct NotReadyResponse: Content {
    struct Detail: Content {
        var code = "not_ready"
        var message = "Database unavailable or migrations pending."
    }
    var error = Detail()
}
