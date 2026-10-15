import Foundation
import Fluent
import Vapor

struct DeviceTokenService: Sendable {
    let scope: TimeServices
    func dto(_ row: DeviceTokenRecord, token: String? = nil) throws -> DeviceTokenDTO {
        try .init(id: row.requireID(), name: row.name, scope: row.scope, createdAt: row.createdAt,
                  expiresAt: row.expiresAt, lastUsedAt: row.lastUsedAt, token: token)
    }
    func list() async throws -> [DeviceTokenDTO] {
        try await DeviceTokenRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$revokedAt == nil).all().map { try dto($0) }
    }
    func create(_ input: DeviceTokenInput) async throws -> DeviceTokenDTO {
        guard input.name.fitsColumn(80), input.expiresInDays.map({ (1...730).contains($0) }) ?? true else { throw APIError.invalid }
        let token = Secrets.token(); let now = Date()
        let row = DeviceTokenRecord(); row.accountId = scope.accountId; row.tokenHash = Secrets.hash(token); row.scope = "automation"
        row.name = input.name; row.createdAt = now; row.expiresAt = input.expiresInDays.map { now.addingTimeInterval(Double($0) * 86400) }
        try await row.create(on: scope.db); return try dto(row, token: token)
    }
    func revoke(_ id: UUID) async throws {
        guard let row = try await DeviceTokenRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$id == id).first() else { throw APIError.missing }
        row.revokedAt = Date(); try await row.update(on: scope.db)
    }
    static func authenticate(_ token: String, db: any Database, now: Date = Date(), disabledModules: Set<ModuleKey> = []) async throws -> DeviceTokenRecord {
        guard token.count == 43, let row = try await DeviceTokenRecord.query(on: db).filter(\.$tokenHash == Secrets.hash(token)).first(),
              row.scope == "automation", row.revokedAt == nil, row.expiresAt.map({ $0 > now }) ?? true,
              let account = try await Account.find(row.accountId, on: db), account.disabledAt == nil else { throw APIError.unauthorized }
        guard try await ModuleRegistry(locked: disabledModules).enabled(.automation, account: row.accountId, on: db) else { throw APIError.unauthorized }
        return row
    }
}
struct DeviceContextKey: StorageKey { typealias Value = String }
struct DeviceTokenMiddleware: AsyncMiddleware {
    let auth: AuthService
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.cookies["tt_session"] == nil, let token = request.headers.bearerAuthorization?.token else { throw APIError.unauthorized }
        let allowed = try await auth.transaction(on: request.db) { tx in
            let row = try await DeviceTokenService.authenticate(token, db: tx, disabledModules: auth.configuration.disabledModules)
            let key = "device:" + (try row.requireID().uuidString)
            let now = Date()
            if try await RateLimitEvent.query(on: tx).filter(\.$key == key).filter(\.$occurredAt > now.addingTimeInterval(-300)).count() >= 120 { return false }
            try await RateLimitEvent(key: key, occurredAt: now).create(on: tx)
            try await RateLimitEvent.query(on: tx).filter(\.$key == key).filter(\.$occurredAt < now.addingTimeInterval(-600)).delete()
            row.lastUsedAt = now; try await row.update(on: tx)
            return true
        }
        guard allowed else { throw APIError(.tooManyRequests, "too_many_requests") }
        request.storage[DeviceContextKey.self] = token
        return try await next.respond(to: request)
    }
}
// Applied before session middleware, including to stage-one routes.
struct DeviceScopeGuard: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if request.url.path != "/api/v1/automation/events", request.url.path != "/mcp", request.headers.bearerAuthorization != nil { throw APIError.unauthorized }
        return try await next.respond(to: request)
    }
}

struct AutomationService: Sendable {
    let scope: TimeServices
    func process(_ input: AutomationInput) async throws -> AutomationResult {
        guard input.deviceId.fitsColumn(80), ["arrival", "presence_confirmed", "departure", "cancel"].contains(input.type) else { throw APIError.invalid }
        if let existing = try await AutomationEventRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$eventId == input.eventId).first() { return existing.result }
        let place = try await scope.places.record(input.placeId).payload
        let history = try await AutomationEventRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
            .filter(\.$deviceId == input.deviceId).filter(\.$placeId == input.placeId).sort(\.$sequence).all()
        var result = AutomationResult(result: "recorded")
        if let latest = history.map(\.occurredAt).max(), input.occurredAt < latest {
            result.result = "needs_review"
        } else if place.automationMode == "off" || place.archived == true {
            result.result = "recorded"
        } else {
            let lastArrival = history.lastIndex { $0.type == "arrival" }
            let visit = (lastArrival.map { Array(history[$0...]) } ?? []).filter { $0.type == "arrival" || $0.result.result != "needs_review" }
            let arrival = visit.first
            let closed = visit.contains { ["departure", "cancel"].contains($0.type) }
            let confirmed = visit.first { $0.type == "presence_confirmed" && ["booked", "suggested"].contains($0.result.result) }
            switch input.type {
            case "arrival":
                if let running = try await scope.timer.current(), running.source == "automation" {
                    // A new arrival cannot prove when the preceding visit ended.
                    let suggestion = try await missingDeparture(running, proposedEnd: input.occurredAt)
                    result = .init(result: "needs_review", segmentId: running.id, suggestionId: suggestion.id)
                }
            case "presence_confirmed":
                if arrival?.result.result == "needs_review" { result.result = "needs_review" }
                else if confirmed != nil || closed { result.result = "ignored" }
                else if let arrival, input.occurredAt.timeIntervalSince(arrival.occurredAt) >= Double(place.confirmAfterSeconds ?? 300) {
                    if place.automationMode == "suggest" {
                        let suggestion = try await scope.suggestions.create(type: "start", placeId: input.placeId, start: arrival.occurredAt, end: nil, segmentId: nil)
                        result = .init(result: "suggested", suggestionId: suggestion.id)
                    } else {
                        do {
                            let segment = try await scope.segments.create(.init(kind: place.defaultSegmentKind ?? .work, startedAt: arrival.occurredAt, placeId: input.placeId), source: .automation)
                            result = .init(result: "booked", segmentId: segment.id)
                        } catch let error as APIError where error.code == "segment_overlap" { result.result = "needs_review" }
                    }
                } else { result.result = arrival == nil ? "needs_review" : "ignored" }
            case "departure":
                if let running = try await scope.timer.current(), running.source == "automation",
                   confirmed?.result.segmentId != running.id {
                    // No confirmation in this visit owns the unresolved running segment.
                    let suggestion = try await missingDeparture(running, proposedEnd: input.occurredAt)
                    result = .init(result: "suggested", segmentId: running.id, suggestionId: suggestion.id)
                } else if closed { result.result = "needs_review" }
                else if let confirmed, let segmentId = confirmed.result.segmentId {
                    let row = try await scope.segments.record(segmentId)
                    if row.endedAt != nil || row.voidedAt != nil || input.occurredAt <= row.startedAt { result.result = "needs_review" }
                    else if row.needsReview {
                        let suggestion = try await missingDeparture(row, proposedEnd: input.occurredAt)
                        result = .init(result: "suggested", segmentId: segmentId, suggestionId: suggestion.id)
                    } else {
                        var next = try row.dto(); next.endedAt = input.occurredAt
                        _ = try await scope.segments.revise(row, value: next, reason: "Automation departure")
                        result = .init(result: "booked", segmentId: segmentId)
                    }
                } else if let confirmed, let suggestionId = confirmed.result.suggestionId {
                    let row = try await scope.suggestions.record(suggestionId)
                    if row.resolvedAt == nil { row.payload.proposedEndedAt = input.occurredAt; try await row.update(on: scope.db); result = .init(result: "suggested", suggestionId: suggestionId) }
                    else if let segmentId = row.payload.segmentId {
                        let segment = try await scope.segments.record(segmentId)
                        if segment.endedAt == nil && segment.voidedAt == nil {
                            let endSuggestion = try await scope.suggestions.create(type: "end", placeId: input.placeId, start: nil, end: input.occurredAt, segmentId: segmentId)
                            result = .init(result: "suggested", segmentId: segmentId, suggestionId: endSuggestion.id)
                        } else { result.result = "needs_review" }
                    } else { result.result = "needs_review" }
                } else { result.result = arrival == nil ? "needs_review" : "ignored" }
            case "cancel":
                if let confirmed, let segmentId = confirmed.result.segmentId {
                    let row = try await scope.segments.record(segmentId)
                    let suggestion = try await missingDeparture(row, proposedEnd: input.occurredAt)
                    result = .init(result: "needs_review", segmentId: segmentId, suggestionId: suggestion.id)
                } else if let confirmed, let suggestionId = confirmed.result.suggestionId {
                    let row = try await scope.suggestions.record(suggestionId)
                    if row.resolvedAt == nil { try await scope.suggestions.reject(suggestionId) }
                    result.result = "ignored"
                } else { result.result = "ignored" }
            default: break
            }
        }
        let event = AutomationEventRecord(); event.accountId = scope.accountId; event.eventId = input.eventId
        event.deviceId = input.deviceId; event.placeId = input.placeId; event.type = input.type; event.occurredAt = input.occurredAt
        event.sequence = try await AutomationEventRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).count() + 1
        event.payload = input; event.result = result; try await event.create(on: scope.db)
        return result
    }
    func reviewMissingDeparture(now: Date = Date()) async throws {
        guard let row = try await scope.timer.current(), row.source == "automation" else { return }
        let models = try await scope.models.list().map { try $0.engine() }
        let model = try models.reversed().first { $0.contains(try TimeEngine.assignedDate(for: row.startedAt, model: $0)) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: model?.timezone ?? "Europe/Berlin")!
        let startDay = try model.map { try TimeEngine.assignedDate(for: row.startedAt, model: $0) } ?? LocalDate.local(row.startedAt, calendar: calendar)
        let currentDay = try model.map { try TimeEngine.assignedDate(for: now, model: $0) } ?? LocalDate.local(now, calendar: calendar)
        if currentDay > startDay { _ = try await missingDeparture(row, proposedEnd: nil) }
    }
    func missingDeparture(_ row: SegmentRecord, proposedEnd: Date?) async throws -> SuggestionDTO {
        let suggestions = try await SuggestionRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$resolvedAt == nil).all()
        if let existing = suggestions.first(where: { $0.payload.type == "end" && $0.payload.segmentId == row.id }) { return existing.payload }
        row.needsReview = true; try await row.update(on: scope.db)
        return try await scope.suggestions.create(type: "end", placeId: row.placeId, start: nil, end: proposedEnd, segmentId: row.id)
    }
}
