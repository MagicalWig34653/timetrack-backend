import Foundation
import Fluent
import Vapor

/// APNs device registration of the Apple apps (ADR-0030). The token is stored in plain text because APNs needs it for delivery
/// (same convention as `push_subscriptions.endpoint`); `token_hash` gives the unique lookup. The token is never returned by the API.
final class ApnsDeviceRecord: Model, @unchecked Sendable {
    static let schema = "apns_devices"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "token") var token: String
    @Field(key: "platform") var platform: String
    @Field(key: "environment") var environment: String
    @Field(key: "app_bundle_id") var appBundleId: String
    @OptionalField(key: "label") var label: String?
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "last_success_at") var lastSuccessAt: Date?
    @Field(key: "failure_count") var failureCount: Int
    init() {}
}

final class ApnsOutboxRecord: Model, @unchecked Sendable {
    static let schema = "apns_outbox"
    @ID(key: .id) var id: UUID?
    @Field(key: "notification_id") var notificationId: UUID
    @Field(key: "device_id") var deviceId: UUID
    /// pending | sent | failed | deferred
    @Field(key: "status") var status: String
    @Field(key: "attempts") var attempts: Int
    @Field(key: "next_attempt_at") var nextAttemptAt: Date
    @OptionalField(key: "error_code") var errorCode: String?
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "completed_at") var completedAt: Date?
    init() {}
}

struct CreateApnsDevices: AsyncMigration {
    let name = "p14.create_apns_devices"
    func prepare(on db: any Database) async throws {
        try await db.schema("apns_devices").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("token_hash", .string, .required)
            .field("token", .string, .required)
            .field("platform", .string, .required)
            .field("environment", .string, .required)
            .field("app_bundle_id", .string, .required)
            .field("label", .string)
            .field("created_at", .datetime, .required)
            .field("last_success_at", .datetime)
            .field("failure_count", .int, .required)
            .unique(on: "token_hash")
            .create()
        try await requireSQL(db).create(index: "idx_apns_devices_account").on("apns_devices").column("account_id").run()
        try await db.schema("apns_outbox").id()
            .field("notification_id", .uuid, .required, .references("notifications", "id", onDelete: .restrict))
            .field("device_id", .uuid, .required, .references("apns_devices", "id", onDelete: .restrict))
            .field("status", .string, .required)
            .field("attempts", .int, .required)
            .field("next_attempt_at", .datetime, .required)
            .field("error_code", .string)
            .field("created_at", .datetime, .required)
            .field("completed_at", .datetime)
            .unique(on: "notification_id", "device_id")
            .create()
        try await requireSQL(db).create(index: "idx_apns_outbox_due").on("apns_outbox").column("status").column("next_attempt_at").run()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("apns_outbox").delete()
        try await db.schema("apns_devices").delete()
    }
}

enum ApnsDeviceRules {
    static let maxDevices = 10
    static let platforms: Set<String> = ["ios", "macos", "watchos"]
    static let environments: Set<String> = ["sandbox", "production"]
    /// Registrations per account and hour (re-registration on every app start is expected, so this is generous).
    static let registrationLimit = 30
    static let testLimit = 5

    static func validBundleId(_ value: String) -> Bool {
        (1...100).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45 }
    }
    /// APNs device tokens are hexadecimal (32 bytes today, Apple reserves room to grow); normalized to lower case.
    static func normalizedToken(_ value: String) -> String? {
        let token = value.lowercased()
        guard (64...200).contains(token.utf8.count), token.utf8.count % 2 == 0,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return token
    }
}

struct ApnsDeviceInput: Decodable, Sendable {
    var token: String
    var platform: String
    var environment: String
    var appBundleId: String
    var label: String?
}

struct ApnsDeviceDTO: Codable, Sendable {
    var id: UUID
    var platform: String
    var environment: String
    var appBundleId: String
    var label: String?
    var createdAt: Date
    var lastSuccessAt: Date?
    init(_ record: ApnsDeviceRecord) throws {
        id = try record.requireID(); platform = record.platform; environment = record.environment; appBundleId = record.appBundleId
        label = record.label; createdAt = record.createdAt; lastSuccessAt = record.lastSuccessAt
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id); try container.encode(platform, forKey: .platform); try container.encode(environment, forKey: .environment)
        try container.encode(appBundleId, forKey: .appBundleId); try container.encode(label, forKey: .label)
        try container.encode(createdAt, forKey: .createdAt); try container.encode(lastSuccessAt, forKey: .lastSuccessAt)
    }
}

extension NotificationService {
    func devices(_ accountId: UUID, on db: any Database) async throws -> [ApnsDeviceDTO] {
        try await ApnsDeviceRecord.query(on: db).filter(\.$accountId == accountId).sort(\.$createdAt).all().map(ApnsDeviceDTO.init)
    }

    /// Registers or refreshes a device token. A token already known under another account moves to the caller (shared device, new login);
    /// the previous owner's queued messages for it are dropped.
    func registerDevice(_ accountId: UUID, _ input: ApnsDeviceInput, now: Date = Date(), on db: any Database) async throws -> ApnsDeviceDTO {
        guard let apns else { throw APIError(.notImplemented, "push_unavailable") }
        guard let token = ApnsDeviceRules.normalizedToken(input.token), ApnsDeviceRules.platforms.contains(input.platform),
              ApnsDeviceRules.environments.contains(input.environment), apns.configuration.bundleIds.contains(input.appBundleId) else { throw APIError.invalid }
        let label = input.label.map { String($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        guard label.map({ $0.fitsColumn(100) }) ?? true else { throw APIError.invalid }
        let hash = Secrets.hash(token)
        return try await auth.transaction(on: db) { tx in
            let key = "apns_register:" + accountId.uuidString
            if try await RateLimitEvent.query(on: tx).filter(\.$key == key).filter(\.$occurredAt > now.addingTimeInterval(-3600)).count() >= ApnsDeviceRules.registrationLimit {
                throw APIError(.tooManyRequests, "too_many_requests")
            }
            try await RateLimitEvent(key: key, occurredAt: now).create(on: tx)
            if let existing = try await ApnsDeviceRecord.query(on: tx).filter(\.$tokenHash == hash).first() {
                if existing.accountId != accountId {
                    guard try await ApnsDeviceRecord.query(on: tx).filter(\.$accountId == accountId).count() < ApnsDeviceRules.maxDevices
                    else { throw APIError(.conflict, "too_many_push_devices") }
                    try await ApnsOutboxRecord.query(on: tx).filter(\.$deviceId == existing.requireID()).delete()
                    existing.accountId = accountId; existing.createdAt = now; existing.lastSuccessAt = nil
                }
                existing.platform = input.platform; existing.environment = input.environment; existing.appBundleId = input.appBundleId
                existing.label = label; existing.failureCount = 0
                try await existing.update(on: tx)
                return try ApnsDeviceDTO(existing)
            }
            guard try await ApnsDeviceRecord.query(on: tx).filter(\.$accountId == accountId).count() < ApnsDeviceRules.maxDevices
            else { throw APIError(.conflict, "too_many_push_devices") }
            let row = ApnsDeviceRecord()
            row.accountId = accountId; row.tokenHash = hash; row.token = token; row.platform = input.platform; row.environment = input.environment
            row.appBundleId = input.appBundleId; row.label = label; row.createdAt = now; row.failureCount = 0
            try await row.create(on: tx)
            return try ApnsDeviceDTO(row)
        }
    }

    func removeDevice(_ accountId: UUID, id: UUID, on db: any Database) async throws {
        try await auth.transaction(on: db) { tx in
            guard let row = try await ApnsDeviceRecord.query(on: tx).filter(\.$id == id).filter(\.$accountId == accountId).first() else { throw APIError.missing }
            try await Self.remove(row, on: tx)
        }
    }
    static func remove(_ row: ApnsDeviceRecord, on db: any Database) async throws {
        try await ApnsOutboxRecord.query(on: db).filter(\.$deviceId == row.requireID()).delete()
        try await row.delete(on: db)
    }

    /// Sends a generic test alert directly (no outbox). Rate limit: 5 per hour and account.
    func sendDeviceTest(_ accountId: UUID, id: UUID, now: Date = Date(), on db: any Database) async throws {
        guard let apns else { throw APIError(.notImplemented, "push_unavailable") }
        let device: ApnsDeviceRecord = try await auth.transaction(on: db) { tx in
            guard let row = try await ApnsDeviceRecord.query(on: tx).filter(\.$id == id).filter(\.$accountId == accountId).first() else { throw APIError.missing }
            let key = "apns_test:" + accountId.uuidString
            if try await RateLimitEvent.query(on: tx).filter(\.$key == key).filter(\.$occurredAt > now.addingTimeInterval(-3600)).count() >= ApnsDeviceRules.testLimit {
                throw APIError(.tooManyRequests, "too_many_requests")
            }
            try await RateLimitEvent(key: key, occurredAt: now).create(on: tx)
            return row
        }
        let outcome = await apns.deliver(.alert(.init(kind: "system", url: "/settings/notifications", tag: "test"), notificationId: nil),
                                         token: device.token, environment: device.environment, topic: device.appBundleId, now: now)
        try await ApnsDispatcher.record(outcome, device: device.requireID(), now: now, on: db)
        guard outcome == .delivered else { throw APIError(.badGateway, "push_failed") }
    }
}

/// Delivers due `apns_outbox` rows. 410/BadDeviceToken/Unregistered delete the device token, 429/5xx retry with backoff (3 attempts).
/// Runs under the notification job lease, so only one process delivers at a time.
struct ApnsDispatcher: Sendable {
    static let maxAttempts = 3
    let db: any Database
    let sender: ApnsSender
    var modules = ModuleRegistry()

    static func retain(now: Date, on db: any Database) async throws {
        try await ApnsOutboxRecord.query(on: db).filter(\.$status ~~ ["sent", "failed"]).filter(\.$completedAt < now.addingTimeInterval(-14 * 86400)).delete()
    }

    /// Silent `content-available` push so the apps of one account refresh their data. Respects no quiet hours (it shows nothing).
    func sendSyncHint(account: UUID, now: Date = Date()) async throws {
        for device in try await ApnsDeviceRecord.query(on: db).filter(\.$accountId == account).all() {
            let outcome = await sender.deliver(.silentSync, token: device.token, environment: device.environment, topic: device.appBundleId, now: now)
            try await Self.record(outcome, device: device.requireID(), now: now, on: db)
        }
    }

    func deliverDue(now: Date, clockNow: (@Sendable () -> Date)? = nil, ownsLease: @escaping @Sendable () async -> Bool = { true }) async throws {
        let started = Date()
        @Sendable func currentTime() -> Date { clockNow?() ?? now.addingTimeInterval(Date().timeIntervalSince(started)) }
        let due = try await ApnsOutboxRecord.query(on: db).filter(\.$status ~~ ["pending", "deferred"]).filter(\.$nextAttemptAt <= now)
            .sort(\.$nextAttemptAt).limit(100).all()
        for item in due {
            guard await ownsLease() else { return }
            let id = try item.requireID()
            func finish(_ status: String, error: String? = nil, next: Date? = nil, attempts: Int? = nil) async throws {
                try await ApnsOutboxRecord.query(on: db).filter(\.$id == id)
                    .set(\.$status, to: status).set(\.$errorCode, to: error).set(\.$attempts, to: attempts ?? item.attempts)
                    .set(\.$nextAttemptAt, to: next ?? item.nextAttemptAt)
                    .set(\.$completedAt, to: ["sent", "failed"].contains(status) ? currentTime() : nil).update()
            }
            guard let device = try await ApnsDeviceRecord.find(item.deviceId, on: db),
                  let notification = try await NotificationRecord.find(item.notificationId, on: db) else {
                try await finish("failed", error: "device_removed"); continue
            }
            let settings = try await NotificationService.effectiveSettings(device.accountId, on: db)
            guard let account = try await Account.find(device.accountId, on: db), account.disabledAt == nil,
                  settings.categories[notification.kind]?.push ?? (notification.kind == "system") else {
                try await finish("failed", error: "push_disabled"); continue
            }
            if let key = ModuleKey.notification(notification.kind), try await !modules.enabled(key, account: device.accountId, on: db) {
                try await finish("failed", error: "module_disabled"); continue
            }
            let deliveryTime = currentTime()
            let clock = try await LocalClock.resolve(account: device.accountId, now: deliveryTime, on: db)
            if clock.inQuietHours(deliveryTime, start: settings.quietStart, end: settings.quietEnd), let end = settings.quietEnd {
                try await finish("deferred", next: clock.quietEnd(after: deliveryTime, end: end)); continue
            }
            let message = ApnsMessage.alert(PushMessage(kind: notification.kind, url: notification.url ?? "/", tag: notification.dedupKey), notificationId: notification.id)
            let outcome = await sender.deliver(message, token: device.token, environment: device.environment, topic: device.appBundleId, now: deliveryTime)
            let attempts = item.attempts + 1
            switch outcome {
            case .delivered: try await finish("sent", attempts: attempts)
            case .gone: try await finish("failed", error: "gone", attempts: attempts)
            case .failed(let code): try await finish("failed", error: code, attempts: attempts)
            case .retry(let code):
                try await finish(attempts >= Self.maxAttempts ? "failed" : "pending", error: code,
                                 next: now.addingTimeInterval(60 * pow(5, Double(attempts - 1))), attempts: attempts)
            }
            try await Self.record(outcome, device: device.requireID(), now: deliveryTime, on: db)
        }
    }

    static func record(_ outcome: PushOutcome, device id: UUID, now: Date, on db: any Database) async throws {
        guard let row = try await ApnsDeviceRecord.find(id, on: db) else { return }
        switch outcome {
        case .delivered: row.lastSuccessAt = now; row.failureCount = 0; try await row.update(on: db)
        case .gone: try await NotificationService.remove(row, on: db)
        case .retry, .failed: row.failureCount += 1; try await row.update(on: db)
        }
    }
}
