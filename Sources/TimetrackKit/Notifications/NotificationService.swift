import Foundation
import Fluent
import Vapor
import Crypto

struct NotificationDTO: Codable, Sendable {
    var id: UUID
    var kind: String
    var title: String
    var body: String
    var url: String?
    var createdAt: Date
    var read: Bool
    init(_ record: NotificationRecord) throws {
        id = try record.requireID(); kind = record.kind; title = record.title; body = record.body; url = record.url
        createdAt = record.createdAt; read = record.readAt != nil
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id); try container.encode(kind, forKey: .kind); try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body); try container.encode(url, forKey: .url)
        try container.encode(createdAt, forKey: .createdAt); try container.encode(read, forKey: .read)
    }
}
struct NotificationListDTO: Codable, Sendable { var items: [NotificationDTO]; var unreadCount: Int }
struct UnreadCountDTO: Codable, Sendable { var unreadCount: Int }
struct MarkReadInput: Decodable, Sendable { var ids: [UUID]?; var all: Bool? }
struct PushConfigDTO: Codable, Sendable {
    var available: Bool
    var vapidPublicKey: String?
    var apnsAvailable: Bool = false
}
struct PushSubscriptionInput: Decodable, Sendable {
    struct Keys: Decodable, Sendable { var p256dh: String; var auth: String }
    var endpoint: String
    var keys: Keys
    var userAgent: String?
}
struct PushSubscriptionDTO: Codable, Sendable {
    var id: UUID
    var host: String
    var userAgent: String?
    var createdAt: Date
    var lastSuccessAt: Date?
    init(_ record: PushSubscriptionRecord) throws {
        id = try record.requireID(); host = URL(string: record.endpoint)?.host ?? ""; userAgent = record.userAgent
        createdAt = record.createdAt; lastSuccessAt = record.lastSuccessAt
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id); try container.encode(host, forKey: .host); try container.encode(userAgent, forKey: .userAgent)
        try container.encode(createdAt, forKey: .createdAt); try container.encode(lastSuccessAt, forKey: .lastSuccessAt)
    }
}

/// Account-scoped REST operations for notifications, settings and push subscriptions. Foreign ids are indistinguishable from unknown ids (404).
struct NotificationService: Sendable {
    static let maxSubscriptions = 10
    let auth: AuthService
    let vapid: VapidConfiguration?
    let transport: any PushTransport
    var policy = PushEndpointPolicy()
    /// APNs delivery for the Apple apps; nil while unconfigured (ADR-0030).
    var apns: ApnsSender?
    /// The environment the APNs settings were read from (only used to name missing or invalid variables in the diagnosis).
    var apnsEnvironment: [String: String] = [:]

    // MARK: Notifications

    func list(_ accountId: UUID, unreadOnly: Bool, limit: Int, before: Date?, on db: any Database) async throws -> NotificationListDTO {
        var query = NotificationRecord.query(on: db).filter(\.$accountId == accountId).filter(\.$deletedAt == nil)
        if unreadOnly { query = query.filter(\.$readAt == nil) }
        if let before { query = query.filter(\.$createdAt < before) }
        let rows = try await query.sort(\.$createdAt, .descending).sort(\.$id, .descending).limit(limit).all()
        let count = try await unread(accountId, on: db)
        return try .init(items: rows.map(NotificationDTO.init), unreadCount: count)
    }
    func unread(_ accountId: UUID, on db: any Database) async throws -> Int {
        try await NotificationRecord.query(on: db).filter(\.$accountId == accountId).filter(\.$deletedAt == nil).filter(\.$readAt == nil).count()
    }
    func markRead(_ accountId: UUID, _ input: MarkReadInput, on db: any Database) async throws -> Int {
        let ids = input.ids ?? []
        guard ids.count <= 200, input.all == true || !ids.isEmpty else { throw APIError.invalid }
        return try await auth.transaction(on: db) { tx in
            var query = NotificationRecord.query(on: tx).filter(\.$accountId == accountId).filter(\.$deletedAt == nil).filter(\.$readAt == nil)
            if input.all != true { query = query.filter(\.$id ~~ ids) }
            try await query.set(\.$readAt, to: Date()).update()
            return try await unread(accountId, on: tx)
        }
    }
    func delete(_ accountId: UUID, id: UUID, on db: any Database) async throws {
        try await auth.transaction(on: db) { tx in
            guard let row = try await NotificationRecord.query(on: tx).filter(\.$id == id).filter(\.$accountId == accountId).filter(\.$deletedAt == nil).first()
            else { throw APIError.missing }
            row.deletedAt = Date(); try await row.update(on: tx)
        }
    }

    // MARK: Settings

    func settings(_ accountId: UUID, on db: any Database) async throws -> NotificationSettingsDTO {
        try await Self.effectiveSettings(accountId, on: db)
    }
    static func effectiveSettings(_ accountId: UUID, on db: any Database) async throws -> NotificationSettingsDTO {
        guard let stored = try await NotificationSettingsRecord.query(on: db).filter(\.$accountId == accountId).first()?.settings else { return .defaults }
        var result = stored
        for (kind, value) in NotificationSettingsDTO.defaults.categories where result.categories[kind] == nil { result.categories[kind] = value }
        return result
    }
    func putSettings(_ accountId: UUID, _ input: NotificationSettingsDTO, on db: any Database) async throws -> NotificationSettingsDTO {
        let value = try input.validated()
        try await auth.transaction(on: db) { tx in
            if let row = try await NotificationSettingsRecord.query(on: tx).filter(\.$accountId == accountId).first() {
                row.settings = value; row.updatedAt = Date(); try await row.update(on: tx)
            } else {
                let row = NotificationSettingsRecord(); row.accountId = accountId; row.settings = value; row.updatedAt = Date(); try await row.create(on: tx)
            }
        }
        return value
    }

    // MARK: Push

    var config: PushConfigDTO { .init(available: vapid != nil, vapidPublicKey: vapid?.publicKeyBase64URL, apnsAvailable: apns != nil) }

    func subscriptions(_ accountId: UUID, on db: any Database) async throws -> [PushSubscriptionDTO] {
        try await PushSubscriptionRecord.query(on: db).filter(\.$accountId == accountId).sort(\.$createdAt).all().map(PushSubscriptionDTO.init)
    }
    func subscribe(_ accountId: UUID, _ input: PushSubscriptionInput, on db: any Database) async throws -> PushSubscriptionDTO {
        guard vapid != nil else { throw APIError(.notImplemented, "push_unavailable") }
        guard let endpoint = policy.endpoint(input.endpoint),
              PushSubscriptionValidation.keys(p256dh: input.keys.p256dh, auth: input.keys.auth) else { throw APIError.invalid }
        let agent = input.userAgent.map { String($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }) }.flatMap { $0.isEmpty ? nil : $0 }
        guard agent.map({ $0.fitsColumn(200) }) ?? true else { throw APIError.invalid }
        let hash = Secrets.hash(endpoint.url)
        let p256dh = input.keys.p256dh.replacingOccurrences(of: "=", with: ""), authKey = input.keys.auth.replacingOccurrences(of: "=", with: "")
        return try await auth.transaction(on: db) { tx in
            if let existing = try await PushSubscriptionRecord.query(on: tx).filter(\.$accountId == accountId).filter(\.$endpointHash == hash).first() {
                existing.p256dh = p256dh; existing.auth = authKey; existing.userAgent = agent; existing.failureCount = 0
                try await existing.update(on: tx)
                return try PushSubscriptionDTO(existing)
            }
            guard try await PushSubscriptionRecord.query(on: tx).filter(\.$accountId == accountId).count() < Self.maxSubscriptions
            else { throw APIError(.conflict, "too_many_subscriptions") }
            let row = PushSubscriptionRecord()
            row.accountId = accountId; row.endpointHash = hash; row.endpoint = endpoint.url; row.p256dh = p256dh; row.auth = authKey
            row.userAgent = agent; row.createdAt = Date(); row.failureCount = 0
            try await row.create(on: tx)
            return try PushSubscriptionDTO(row)
        }
    }
    func unsubscribe(_ accountId: UUID, id: UUID, on db: any Database) async throws {
        try await auth.transaction(on: db) { tx in
            guard let row = try await PushSubscriptionRecord.query(on: tx).filter(\.$id == id).filter(\.$accountId == accountId).first() else { throw APIError.missing }
            try await Self.remove(row, on: tx)
        }
    }
    static func remove(_ row: PushSubscriptionRecord, on db: any Database) async throws {
        try await PushOutboxRecord.query(on: db).filter(\.$subscriptionId == row.requireID()).delete()
        try await row.delete(on: db)
    }

    /// Sends a generic test message directly (no outbox). Rate limit: 5 per hour and account.
    func sendTest(_ accountId: UUID, id: UUID, now: Date = Date(), on db: any Database) async throws {
        guard let vapid else { throw APIError(.notImplemented, "push_unavailable") }
        let subscription: PushSubscriptionRecord = try await auth.transaction(on: db) { tx in
            guard let row = try await PushSubscriptionRecord.query(on: tx).filter(\.$id == id).filter(\.$accountId == accountId).first() else { throw APIError.missing }
            let key = "push_test:" + accountId.uuidString
            if try await RateLimitEvent.query(on: tx).filter(\.$key == key).filter(\.$occurredAt > now.addingTimeInterval(-3600)).count() >= 5 {
                throw APIError(.tooManyRequests, "too_many_requests")
            }
            try await RateLimitEvent(key: key, occurredAt: now).create(on: tx)
            return row
        }
        let outcome = await PushSender(vapid: vapid, transport: transport, policy: policy)
            .deliver(.init(kind: "system", url: "/settings/notifications", tag: "test"), endpoint: subscription.endpoint, p256dh: subscription.p256dh, auth: subscription.auth, now: now)
        try await PushDispatcher.record(outcome, subscription: subscription.requireID(), now: now, on: db)
        guard outcome == .delivered else { throw APIError(.badGateway, "push_failed") }
    }
}
