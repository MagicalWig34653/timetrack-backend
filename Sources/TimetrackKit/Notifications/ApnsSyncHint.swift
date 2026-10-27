import Foundation
import Fluent
import Vapor

/// Coalesces "data changed" events into silent sync pushes (P14b, ADR-0030): per account at most one hint per `minInterval`, sent after the
/// changes have been quiet for `debounce`. Runs entirely off the request path; failures are logged without tokens.
actor ApnsSyncCoordinator {
    struct Timing: Sendable {
        var debounce: TimeInterval = 3
        var minInterval: TimeInterval = 30
    }

    private struct Pending {
        var lastChange: Date
        var origins: Set<UUID> = []
        var anonymous = false
        var task: Task<Void, Never>?
    }

    private let timing: Timing
    private let logger: Logger
    private let send: @Sendable (UUID, UUID?) async throws -> Void
    private var pending: [UUID: Pending] = [:]
    private var lastSent: [UUID: Date] = [:]
    private var stopped = false

    /// `send(account, excludedDevice)` delivers one silent push; the coordinator decides when.
    init(timing: Timing = Timing(), logger: Logger, send: @escaping @Sendable (UUID, UUID?) async throws -> Void) {
        self.timing = timing; self.logger = logger; self.send = send
    }

    /// Records a change of the account's data. `origin` is the APNs device registration that caused it (excluded from the hint when it is
    /// the only source of the coalesced changes).
    func notify(account: UUID, origin: UUID?, now: Date = Date()) {
        guard !stopped else { return }
        var entry = pending[account] ?? Pending(lastChange: now)
        entry.lastChange = now
        if let origin { entry.origins.insert(origin) } else { entry.anonymous = true }
        if entry.task == nil {
            entry.task = Task { [weak self] in await self?.run(account) }
        }
        pending[account] = entry
    }

    /// Cancels waiting hints (shutdown).
    func stop() {
        stopped = true
        for entry in pending.values { entry.task?.cancel() }
        pending = [:]
    }

    /// Test hook: waits until no hint is waiting or being sent.
    func idle() async {
        while let task = pending.values.compactMap(\.task).first { await task.value }
    }

    private func run(_ account: UUID) async {
        while let entry = pending[account], !Task.isCancelled {
            let ready = max(entry.lastChange.addingTimeInterval(timing.debounce), (lastSent[account] ?? .distantPast).addingTimeInterval(timing.minInterval))
            let wait = ready.timeIntervalSinceNow
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue   // re-evaluate: further changes may have moved the debounce window
            }
            let excluded = entry.origins.count == 1 && !entry.anonymous ? entry.origins.first : nil
            pending[account] = nil
            lastSent[account] = Date()
            do { try await send(account, excluded) }
            catch { logger.warning("APNs sync hint failed (\(type(of: error)))") }
            return
        }
        if Task.isCancelled { pending[account] = nil }
    }
}

extension ApnsDispatcher {
    /// Whether the account wants pushes at all: not disabled and at least one category with `push` enabled.
    /// The silent push shows nothing, so quiet hours do not apply.
    func syncHintAllowed(account: UUID) async throws -> Bool {
        guard let row = try await Account.find(account, on: db), row.disabledAt == nil else { return false }
        return try await NotificationService.effectiveSettings(account, on: db).categories.values.contains { $0.push }
    }
}

/// Triggers the sync hint after a successful data-changing request of a client. Only installed when APNs is configured.
struct ApnsSyncMiddleware: AsyncMiddleware {
    static let deviceHeader = "X-Timetrack-Device"
    static let watchedPrefixes: Set<String> = ["time", "plan", "vacation", "absences", "calendar", "work-models", "places", "automation"]
    let coordinator: ApnsSyncCoordinator
    let auth: AuthService

    static func watches(method: HTTPMethod, path: String) -> Bool {
        guard [.POST, .PUT, .PATCH, .DELETE].contains(method) else { return false }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.starts(with: ["api", "v1"]), parts.count > 2 else { return false }
        return watchedPrefixes.contains(parts[2])
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        guard (200..<300).contains(Int(response.status.code)), Self.watches(method: request.method, path: request.url.path) else { return response }
        let session = try? request.authContext.account.requireID()
        let deviceToken = request.storage[DeviceContextKey.self]
        let origin = request.headers.first(name: Self.deviceHeader).flatMap { UUID(uuidString: $0) }
        let db = request.db, coordinator = coordinator, auth = auth
        Task {
            var account = session
            if account == nil, let deviceToken {
                account = try? await DeviceTokenService.authenticate(deviceToken, db: db, disabledModules: auth.configuration.disabledModules).accountId
            }
            if let account { await coordinator.notify(account: account, origin: origin) }
        }
        return response
    }
}
