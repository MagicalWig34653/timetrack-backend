import Foundation
import Fluent
import Vapor

/// Runs `MaintenanceService` under the `job_leases` lease `maintenance`, so any number of replicas (and the CLI) can
/// start it at the same time and exactly one executes. Periodic runs hold the lease for half an interval after finishing,
/// so replicas do not repeat the work right after each other.
final class MaintenanceRuntime: @unchecked Sendable {
    static let leaseName = "maintenance"
    let service: MaintenanceService
    let options: MaintenanceOptions
    let holder = UUID().uuidString
    var leaseDuration: TimeInterval = MaintenanceRetention.leaseTTL
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(service: MaintenanceService, options: MaintenanceOptions) { self.service = service; self.options = options }

    /// One locked run. Returns nil when another process holds the lease (nothing was done) or the lease could not be taken.
    /// `holdAfterRun` keeps the lease for `hold` seconds (periodic runs); otherwise it is released at once (CLI).
    @discardableResult
    func tick(now: Date = Date(), hold: TimeInterval? = nil) async -> MaintenanceReport? {
        let db = service.db
        do {
            guard try await JobLease.acquire(Self.leaseName, holder: holder, now: now, ttl: leaseDuration, on: db) else { return nil }
            let started = Date()
            let report = await service.run(now: now) {
                let clock = now.addingTimeInterval(Date().timeIntervalSince(started))
                return (try? await JobLease.renew(Self.leaseName, holder: self.holder, now: clock, ttl: self.leaseDuration, on: db)) == true
            }
            if let hold, !report.leaseLost {
                let clock = now.addingTimeInterval(Date().timeIntervalSince(started))
                _ = try? await JobLease.renew(Self.leaseName, holder: holder, now: clock, ttl: hold, on: db)
            } else if !report.leaseLost {
                try? await JobLease.release(Self.leaseName, holder: holder, on: db)
            }
            service.logger.info("maintenance run finished: \(Self.format(report))")
            return report
        } catch {
            service.logger.warning("maintenance run failed (\(type(of: error)))")
            return nil
        }
    }

    static func format(_ report: MaintenanceReport) -> String {
        let counts = report.counts.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "deleted \(report.total)" + (counts.isEmpty ? "" : " (\(counts))")
            + (report.failedSteps.isEmpty ? "" : "; failed steps: \(report.failedSteps.joined(separator: ","))")
            + (report.leaseLost ? "; aborted: lease lost" : "")
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil, options.intervalMinutes > 0 else { return }
        let interval = TimeInterval(options.intervalMinutes) * 60
        let delay = options.initialDelay ?? Double.random(in: 15...75)
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick(hold: max(60, interval / 2))
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func takeTask() -> Task<Void, Never>? { lock.lock(); defer { lock.unlock() }; let running = task; task = nil; return running }

    func stop() async {
        let running = takeTask()
        running?.cancel()
        await running?.value
    }
}

struct MaintenanceLifecycle: LifecycleHandler {
    let runtime: MaintenanceRuntime
    let start: Bool
    func didBootAsync(_ application: Application) async throws { if start { runtime.start() } }
    func shutdownAsync(_ application: Application) async { await runtime.stop() }
}

/// `App maintenance`: one run for operations or cron; exits 0 when the work was done or skipped because another runner holds the lease.
struct MaintenanceCommand: AsyncCommand {
    struct Signature: CommandSignature {}
    let help = "Deletes expired and stale rows and orphaned stored files once (ADR-0017). Safe next to running replicas."
    let runtime: MaintenanceRuntime

    func run(using context: CommandContext, signature: Signature) async throws {
        guard let report = await runtime.tick() else {
            context.console.print("maintenance skipped: another process holds the lease")
            return
        }
        context.console.print("maintenance: " + MaintenanceRuntime.format(report))
        if !report.failedSteps.isEmpty { throw Abort(.internalServerError, reason: "maintenance steps failed: \(report.failedSteps.joined(separator: ","))") }
    }
}

extension Application {
    private struct MaintenanceRuntimeKey: StorageKey { typealias Value = MaintenanceRuntime }
    var maintenanceRuntime: MaintenanceRuntime? {
        get { storage[MaintenanceRuntimeKey.self] }
        set { storage[MaintenanceRuntimeKey.self] = newValue }
    }

    func installMaintenance(auth: AuthService, options: MaintenanceOptions) {
        let service = MaintenanceService(db: db, options: options, logger: logger, storage: { [unowned self] in
            StorageService(auth: auth, db: self.db, client: self.client, env: self.storageEnvironment)
        })
        let runtime = MaintenanceRuntime(service: service, options: options)
        maintenanceRuntime = runtime
        asyncCommands.use(MaintenanceCommand(runtime: runtime), as: "maintenance")
        lifecycle.use(MaintenanceLifecycle(runtime: runtime, start: options.runnerEnabled(testing: environment == .testing)))
    }
}
