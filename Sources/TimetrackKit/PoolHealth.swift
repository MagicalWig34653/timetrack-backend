import Vapor
import Fluent
import FluentSQL
import FluentMySQLDriver
import NIOConcurrencyHelpers

/// Health of the MariaDB connection pool, one pool per event loop (POOL-FIX).
///
/// A connection that a firewall, NAT or IPVS entry silently dropped (no RST, no FIN) never answers again. A query on it never
/// returns, so the single pooled connection of its event loop stays leased for good: every later request of that loop (and
/// the keep-alive ping) waits for the pool timeout. `/ready` used to probe one random loop only, so the Swarm health check
/// kept passing and the task was never replaced. These helpers probe every loop with a hard deadline and close a connection
/// that does not answer, so the pool replaces it.
enum PoolHealth {
    /// How long a leased connection may take for `SELECT 1` before it is considered dead and closed.
    static let pingDeadlineSeconds: Double = 5

    /// The result of `work`, or nil when it has not finished after `seconds`. The work itself keeps running (it cannot be
    /// cancelled while it waits for a pooled connection) but is bounded by the pool timeout.
    static func withDeadline<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let done = NIOLockedValueBox(false)
            @Sendable func finish(_ value: T?) {
                if done.withLockedValue({ let already = $0; $0 = true; return !already }) { continuation.resume(returning: value) }
            }
            Task { finish(await work()) }
            Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); finish(nil) }
        }
    }

    private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

    /// `SELECT 1` on one pooled connection. When the leased connection does not answer within `deadline` seconds it is closed
    /// (its pending query then fails and the pool drops it); the next request opens a new one. Throws what the pool or the
    /// query throws (pool timeout, closed connection).
    static func ping(_ database: any Database, deadline: Double = pingDeadlineSeconds) async throws {
        try await database.withConnection { connection in
            let handle = Unchecked(value: connection)
            let watchdog = Task {
                try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                await close(handle.value)
            }
            defer { watchdog.cancel() }
            try await requireSQL(connection).raw("SELECT 1").run()
        }
    }

    private static func close(_ connection: any Database) async {
        guard let mysql = connection as? any MySQLDatabase else { return }
        _ = try? await mysql.withConnection { $0.close() }.get()
    }

    /// The MariaDB databases of all event loops (empty for SQLite).
    static func loopDatabases(_ app: Application) -> [any Database] {
        guard app.databases.configuration(for: .mysql) != nil else { return [] }
        return app.eventLoopGroup.makeIterator().compactMap { app.databases.database(.mysql, logger: app.logger, on: $0) }
    }

    /// True when every event loop's pool answers within `seconds`. SQLite has no pool per loop and counts as healthy here.
    static func allLoopsAnswer(_ app: Application, within seconds: Double) async -> Bool {
        let databases = loopDatabases(app).map { Unchecked(value: $0) }
        guard !databases.isEmpty else { return true }
        return await withDeadline(seconds: seconds) {
            await withTaskGroup(of: Bool.self) { group in
                for database in databases { group.addTask { (try? await ping(database.value, deadline: seconds)) != nil } }
                var healthy = true
                while let answered = await group.next() { healthy = healthy && answered }
                return healthy
            }
        } ?? false
    }
}
