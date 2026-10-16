import Foundation
import Fluent
import Vapor

/// Cross-process mutual exclusion through the `job_leases` table (ADR-0010: lease 90 s).
enum JobLease {
    static let ttl: TimeInterval = 90

    static func renew(_ name: String, holder: String, now: Date, ttl: TimeInterval = ttl, on db: any Database) async throws -> Bool {
        try await conditionalWrite(on: db) { connection in
            try await JobLeaseRecord.query(on: connection).filter(\.$name == name).filter(\.$holder == holder)
                .filter(\.$expiresAt > now).set(\.$expiresAt, to: now.addingTimeInterval(ttl)).update()
        }
    }

    static func acquire(_ name: String, holder: String, now: Date, ttl: TimeInterval = ttl, on db: any Database) async throws -> Bool {
        let expiry = now.addingTimeInterval(ttl)
        let updated = try await conditionalWrite(on: db) { connection in
            try await JobLeaseRecord.query(on: connection).filter(\.$name == name)
                .group(.or) { $0.filter(\.$holder == holder).filter(\.$expiresAt < now) }
                .set(\.$holder, to: holder).set(\.$expiresAt, to: expiry).update()
        }
        if updated { return true }
        guard try await JobLeaseRecord.query(on: db).filter(\.$name == name).count() == 0 else { return false }
        let row = JobLeaseRecord(); row.name = name; row.holder = holder; row.expiresAt = expiry
        do { try await row.create(on: db); return true } catch { return false }   // lost the insert race (unique name)
    }

    static func release(_ name: String, holder: String, on db: any Database) async throws {
        try await JobLeaseRecord.query(on: db).filter(\.$name == name).filter(\.$holder == holder)
            .set(\.$expiresAt, to: Date(timeIntervalSince1970: 0)).update()
    }
}

/// Settings of the notification subsystem; `environment` defaults to the process environment.
public struct NotificationOptions: Sendable {
    public var environment: [String: String]
    var pushAllowInsecureLoopback = false
    /// Test hook: replaces the HTTP delivery to push services.
    var transport: (any PushTransport)?
    /// Test hook: overrides the tick interval (default 60 s).
    var interval: TimeInterval = 60

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) { self.environment = environment }
    init(environment: [String: String], transport: (any PushTransport)?, interval: TimeInterval = 60) {
        self.environment = environment; self.transport = transport; self.interval = interval
    }
    /// `NOTIFICATIONS_ENABLED=false` disables the background runner; the testing environment only runs it when explicitly `true`.
    func runnerEnabled(testing: Bool) -> Bool {
        let value = environment["NOTIFICATIONS_ENABLED"]?.lowercased()
        if value == "false" { return false }
        return value == "true" || !testing
    }
}

/// Owns the background tick loop. Errors never escape; shutdown cancels the loop, waits for it and releases the lease.
final class NotificationRuntime: @unchecked Sendable {
    static let leaseName = "notifications"
    let scheduler: NotificationScheduler
    let service: NotificationService
    let holder = UUID().uuidString
    let interval: TimeInterval
    var leaseDuration: TimeInterval = JobLease.ttl
    private let transport: any PushTransport
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(scheduler: NotificationScheduler, service: NotificationService, transport: any PushTransport, interval: TimeInterval) {
        self.scheduler = scheduler; self.service = service; self.transport = transport; self.interval = interval
    }

    /// One locked tick: returns whether this process held the lease and therefore ran.
    @discardableResult
    func tick(now: Date = Date()) async -> Bool {
        do {
            guard try await JobLease.acquire(Self.leaseName, holder: holder, now: now, ttl: leaseDuration, on: scheduler.db) else { return false }
            let started = Date()
            let heartbeat = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: UInt64(max(0.01, leaseDuration / 3) * 1_000_000_000)) } catch { return }
                    let clock = now.addingTimeInterval(Date().timeIntervalSince(started))
                    guard (try? await JobLease.renew(Self.leaseName, holder: holder, now: clock, ttl: leaseDuration, on: scheduler.db)) == true else { return }
                }
            }
            defer { heartbeat.cancel() }
            await scheduler.runOnce(now: now) {
                let clock = now.addingTimeInterval(Date().timeIntervalSince(started))
                return (try? await JobLeaseRecord.query(on: self.scheduler.db).filter(\.$name == Self.leaseName)
                    .filter(\.$holder == self.holder).filter(\.$expiresAt > clock).count()) == 1
            }
            return true
        } catch {
            scheduler.logger.warning("notification runner tick failed (\(type(of: error)))")
            return false
        }
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
            }
        }
    }

    private func takeTask() -> Task<Void, Never>? { lock.lock(); defer { lock.unlock() }; let running = task; task = nil; return running }

    func stop() async {
        let running = takeTask()
        running?.cancel()
        await running?.value
        try? await JobLease.release(Self.leaseName, holder: holder, on: scheduler.db)
        await transport.shutdown()
    }
}

struct NotificationLifecycle: LifecycleHandler {
    let runtime: NotificationRuntime
    let start: Bool
    func didBootAsync(_ application: Application) async throws { if start { runtime.start() } }
    func shutdownAsync(_ application: Application) async { await runtime.stop() }
}

extension Application {
    private struct RuntimeKey: StorageKey { typealias Value = NotificationRuntime }
    var notificationRuntime: NotificationRuntime? {
        get { storage[RuntimeKey.self] }
        set { storage[RuntimeKey.self] = newValue }
    }

    func installNotifications(auth: AuthService, options: NotificationOptions) {
        let vapid = VapidConfiguration(environment: options.environment)
        if vapid == nil, options.environment["VAPID_PRIVATE_KEY"] != nil || options.environment["VAPID_SUBJECT"] != nil {
            logger.warning("VAPID_PRIVATE_KEY/VAPID_SUBJECT are invalid or incomplete: Web Push stays unavailable")
        }
        var policy = PushEndpointPolicy()
        policy.pushAllowInsecureLoopback = options.pushAllowInsecureLoopback
        // A blank value (compose passes an unset variable as empty) keeps the ADR-0011 default list.
        if let hosts = options.environment["PUSH_ALLOWED_HOSTS"] {
            let parsed = hosts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !parsed.isEmpty { policy.allowedHosts = parsed }
        }
        let transport = options.transport ?? HTTPPushTransport(group: eventLoopGroup)
        let service = NotificationService(auth: auth, vapid: vapid, transport: transport, policy: policy)
        let scheduler = NotificationScheduler(auth: auth, db: db, vapid: vapid, transport: transport, policy: policy, logger: logger)
        let runtime = NotificationRuntime(scheduler: scheduler, service: service, transport: transport, interval: options.interval)
        notificationRuntime = runtime
        lifecycle.use(NotificationLifecycle(runtime: runtime, start: options.runnerEnabled(testing: environment == .testing)))
    }
}
