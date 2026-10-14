import Vapor
import Fluent
import FluentMySQLDriver
import FluentSQLiteDriver

public func configure(_ app: Application, configuration: Configuration? = nil) async throws {
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
    // Fluent installs the migrate command, including --revert and the global --yes flag.
    // Do not auto-apply migrations before explicit migrate/revert commands.
    if config.autoMigrate && !app.environment.arguments.contains("migrate") {
        try await app.autoMigrate()
    }
    app.get("health") { _ in StatusResponse(status: "ok") }
    app.get("ready") { request async -> Response in
        do {
            let sql = try requireSQL(request.db)
            try await sql.raw("SELECT 1").run()
            guard try await app.migrator.previewPrepareBatch().get().isEmpty else {
                return try await NotReadyResponse().encodeResponse(status: .serviceUnavailable, for: request)
            }
            return try await StatusResponse(status: "ok").encodeResponse(for: request)
        } catch {
            // Do not expose driver errors, connection details or bound values.
            return (try? await NotReadyResponse().encodeResponse(status: .serviceUnavailable, for: request))
                ?? Response(status: .serviceUnavailable)
        }
    }
}

public struct StatusResponse: Content { public let status: String }
struct NotReadyResponse: Content {
    struct Detail: Content {
        var code = "not_ready"
        var message = "Database unavailable or migrations pending."
    }
    var error = Detail()
}
