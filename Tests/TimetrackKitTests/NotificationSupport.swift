import Foundation
import Fluent
import XCTVapor
import Crypto
@testable import TimetrackKit

/// An in-process push service on a loopback port. Records every request and answers with scripted statuses.
final class FakePushService: @unchecked Sendable {
    struct Received: Sendable { let path: String; let headers: [String: String]; let body: Data }
    let app: Application
    private let lock = NSLock()
    private var _received: [Received] = []
    private var _statuses: [Int] = []
    private var _defaultStatus = 201
    var port: Int { app.http.server.shared.localAddress?.port ?? 0 }

    init() async throws {
        app = try await Application.make(.testing)
        app.logger.logLevel = .critical
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.on(.POST, "push", ":id", body: .collect(maxSize: "64kb")) { [unowned self] req async throws -> Response in
            var headers: [String: String] = [:]
            for (name, value) in req.headers { headers[name.lowercased()] = value }
            let data = req.body.data.map { Data($0.readableBytesView) } ?? Data()
            return Response(status: HTTPResponseStatus(statusCode: record(Received(path: req.url.path, headers: headers, body: data))))
        }
        try await app.startup()
    }
    private func record(_ item: Received) -> Int {
        lock.lock(); defer { lock.unlock() }
        _received.append(item)
        return _statuses.isEmpty ? _defaultStatus : _statuses.removeFirst()
    }
    var received: [Received] { lock.lock(); defer { lock.unlock() }; return _received }
    func script(_ statuses: [Int], then fallback: Int = 201) { lock.lock(); _statuses = statuses; _defaultStatus = fallback; lock.unlock() }
    func reset() { lock.lock(); _received = []; _statuses = []; _defaultStatus = 201; lock.unlock() }
    func shutdown() async throws { try await app.asyncShutdown() }
    func endpoint(_ name: String = UUID().uuidString) -> String { "http://127.0.0.1:\(port)/push/\(name)" }
}

/// A simulated browser push subscription.
struct TestSubscription {
    let key = P256.KeyAgreement.PrivateKey()
    let auth = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    let endpoint: String
    var body: [String: Any] {
        ["endpoint": endpoint, "keys": ["p256dh": key.publicKey.x963Representation.base64URL, "auth": auth.base64URL], "userAgent": "XCTest"]
    }
}

func notificationDate(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

extension AuthTests {
    func need<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        let result = try await value(); return try XCTUnwrap(result, file: file, line: line)
    }
    func vapidEnvironment() -> [String: String] {
        ["VAPID_PRIVATE_KEY": P256.Signing.PrivateKey().rawRepresentation.base64URL, "VAPID_SUBJECT": "mailto:admin@example.test", "NOTIFICATIONS_ENABLED": "false"]
    }
    func notificationApp(env: [String: String], database: [String: String] = [:], transport: (any PushTransport)? = nil, interval: TimeInterval = 60,
                         _ run: (Application, AuthService, NotificationRuntime) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        app.logger.logLevel = .critical
        let config = try Configuration(environment: ["SQLITE_PATH": ":memory:"].merging(database) { _, new in new })
        do {
            try await configure(app, configuration: config, notifications: NotificationOptions(environment: env, transport: transport, interval: interval))
            try await app.autoMigrate()
            try await run(app, AuthService(configuration: config, mailSender: nil), try XCTUnwrap(app.notificationRuntime))
            try await app.autoRevert()
        } catch { try await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }
    func mariaDBEnvironment() throws -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        return ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
                "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
                "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test", "DB_TLS": "off"]
    }
    func seedNotification(_ db: any Database, _ account: AuthContext, key: String, at: Date, read: Bool = false, kind: String = "system", title: String = "Titel") async throws -> UUID {
        let row = NotificationRecord()
        row.accountId = try account.account.requireID(); row.kind = kind; row.title = title; row.body = "Text"; row.url = "/"
        row.dedupKey = key; row.createdAt = at; row.readAt = read ? at : nil
        try await row.create(on: db)
        return try row.requireID()
    }
    func seedSegment(_ db: any Database, _ account: AuthContext, start: Date, end: Date? = nil, note: String? = nil) async throws -> UUID {
        let row = SegmentRecord()
        row.id = UUID(); row.accountId = try account.account.requireID(); row.rawStartedAt = start; row.startedAt = start
        row.rawEndedAt = end; row.endedAt = end; row.kind = "work"; row.source = "timer"; row.note = note; row.version = 1
        row.needsReview = false; row.running = end == nil ? 1 : nil; row.revisions = 0
        try await row.create(on: db)
        return try row.requireID()
    }
    func endRunning(_ db: any Database, _ account: AuthContext, at: Date = Date()) async throws {
        let owner = try account.account.requireID()
        for row in try await SegmentRecord.query(on: db).filter(\.$accountId == owner).filter(\.$endedAt == nil).all() {
            row.endedAt = max(at, row.startedAt); row.rawEndedAt = row.endedAt; row.running = nil; try await row.update(on: db)
        }
    }
    func notificationCount(_ db: any Database, _ account: AuthContext, kind: String? = nil) async throws -> Int {
        let owner = try account.account.requireID()
        var query = NotificationRecord.query(on: db).filter(\.$accountId == owner)
        if let kind { query = query.filter(\.$kind == kind) }
        return try await query.count()
    }
}
