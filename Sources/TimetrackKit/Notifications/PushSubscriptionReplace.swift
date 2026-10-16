import Foundation
import Fluent
import Vapor

/// Body of `POST /me/push-subscriptions/replace`, sent by the service worker on `pushsubscriptionchange`.
/// `previousEndpoint` is `oldSubscription.endpoint` of the event; it may be absent (browsers sometimes omit the old subscription).
struct PushSubscriptionReplaceInput: Decodable, Sendable {
    var previousEndpoint: String?
    var endpoint: String
    var keys: PushSubscriptionInput.Keys
    var userAgent: String?
}

extension NotificationService {
    /// Atomically swaps a changed browser subscription for the new one (one transaction under the auth lock):
    /// the stored row keeps its id, creation time and queued outbox entries, so pending notifications go to the new endpoint.
    /// Without a stored old subscription this behaves like registering a new one (`created == true`, same limit of 10).
    /// The old endpoint is only looked up within the caller's own account.
    func replaceSubscription(_ accountId: UUID, _ input: PushSubscriptionReplaceInput, on db: any Database) async throws -> (subscription: PushSubscriptionDTO, created: Bool) {
        guard vapid != nil else { throw APIError(.notImplemented, "push_unavailable") }
        guard let endpoint = policy.endpoint(input.endpoint),
              PushSubscriptionValidation.keys(p256dh: input.keys.p256dh, auth: input.keys.auth) else { throw APIError.invalid }
        if let previous = input.previousEndpoint, previous.isEmpty || previous.count > 2048 { throw APIError.invalid }
        let agent = input.userAgent.map { String($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }) }.flatMap { $0.isEmpty ? nil : $0 }
        guard agent.map({ $0.fitsColumn(200) }) ?? true else { throw APIError.invalid }
        let newHash = Secrets.hash(endpoint.url)
        let oldHash = input.previousEndpoint.map { Secrets.hash($0) }
        let p256dh = input.keys.p256dh.replacingOccurrences(of: "=", with: ""), authKey = input.keys.auth.replacingOccurrences(of: "=", with: "")
        return try await auth.transaction(on: db) { tx in
            let old: PushSubscriptionRecord? = try await oldHash.asyncFlatMap { hash in
                try await PushSubscriptionRecord.query(on: tx).filter(\.$accountId == accountId).filter(\.$endpointHash == hash).first()
            }
            let existingNew: PushSubscriptionRecord? = old?.endpointHash == newHash ? old
                : try await PushSubscriptionRecord.query(on: tx).filter(\.$accountId == accountId).filter(\.$endpointHash == newHash).first()
            func refresh(_ row: PushSubscriptionRecord) {
                row.p256dh = p256dh; row.auth = authKey; row.userAgent = agent; row.failureCount = 0
            }
            if let existingNew {
                // The new endpoint is already registered (e.g. by a second tab): keep that row, drop the stale old one.
                if let old, old.id != existingNew.id { try await Self.remove(old, on: tx) }
                refresh(existingNew)
                try await existingNew.update(on: tx)
                return (try PushSubscriptionDTO(existingNew), false)
            }
            if let old {
                old.endpointHash = newHash; old.endpoint = endpoint.url; old.lastSuccessAt = nil
                refresh(old)
                try await old.update(on: tx)
                return (try PushSubscriptionDTO(old), false)
            }
            guard try await PushSubscriptionRecord.query(on: tx).filter(\.$accountId == accountId).count() < Self.maxSubscriptions
            else { throw APIError(.conflict, "too_many_subscriptions") }
            let row = PushSubscriptionRecord()
            row.accountId = accountId; row.endpointHash = newHash; row.endpoint = endpoint.url; row.createdAt = Date()
            refresh(row)
            try await row.create(on: tx)
            return (try PushSubscriptionDTO(row), true)
        }
    }
}

private extension Optional where Wrapped: Sendable {
    func asyncFlatMap<T: Sendable>(_ transform: (Wrapped) async throws -> T?) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}

func registerPushSubscriptionReplaceRoute(_ api: any RoutesBuilder, service: NotificationService, account: @escaping @Sendable (Request) throws -> UUID) {
    api.post("me", "push-subscriptions", "replace") { req async throws -> Response in
        let owner = try account(req)
        let result = try await service.replaceSubscription(owner, timeDecode(PushSubscriptionReplaceInput.self, request: req), on: req.db)
        return try timeResponse(result.subscription, status: result.created ? .created : .ok)
    }
}
