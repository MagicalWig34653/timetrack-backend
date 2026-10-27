import Foundation
import Fluent
import Vapor

// W1 part B: unauthenticated trigger links (ADR-0027). A GET request to /t/<token>/<action> starts or stops the timer of the
// account that owns the link. The 256-bit random token in the URL is the only credential; only its SHA-256 hash is stored.
// Management (create/list/revoke) is an ordinary session-authenticated REST API under /me/trigger-links.

enum TriggerLinkRules {
    static let actions: Set<String> = ["start", "stop", "toggle"]
    static let maxActiveLinks = 20
    /// Oldest accepted event time (`?at=`) and tolerated clock skew into the future.
    static let maxBackdate: TimeInterval = 2 * 3600
    static let maxFutureSkew: TimeInterval = 60
    /// Requests per link and per window; retries and prefetches stay far below it.
    static let linkLimit = 60
    /// Failed lookups per client address and window.
    static let missLimit = 30
    static let window: TimeInterval = 300
    /// A repeated toggle inside this interval is treated as a duplicate (retry, double prefetch) and changes nothing.
    static let toggleGuard: TimeInterval = 10
    static let tokenLength = 43
}

final class TriggerLinkRecord: Model, @unchecked Sendable {
    static let schema = "trigger_links"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "label") var label: String
    @Field(key: "actions") var actions: [String]
    @OptionalField(key: "place_id") var placeId: UUID?
    @Field(key: "kind") var kind: String
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "expires_at") var expiresAt: Date?
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    @OptionalField(key: "last_used_at") var lastUsedAt: Date?
    @OptionalField(key: "last_action") var lastAction: String?
    init() {}
}

struct CreateTriggerLinks: AsyncMigration {
    let name = "w1.create_trigger_links"
    func prepare(on db: any Database) async throws {
        try await db.schema("trigger_links").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("token_hash", .string, .required)
            .field("label", .string, .required)
            .field("actions", .json, .required)
            .field("place_id", .uuid)
            .field("kind", .string, .required)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime)
            .field("revoked_at", .datetime)
            .field("last_used_at", .datetime)
            .field("last_action", .string)
            .unique(on: "token_hash")
            .create()
        try await requireSQL(db).create(index: "idx_trigger_links_account").on("trigger_links").column("account_id").run()
    }
    func revert(on db: any Database) async throws { try await db.schema("trigger_links").delete() }
}

struct TriggerLinkInput: Content {
    var label: String
    var actions: [String]
    var placeId: UUID?
    var kind: EngineSegmentKind?
    var expiresInDays: Int?
}

/// Management view. `token` and `path` are present only in the response of the creating request; the token cannot be shown again.
struct TriggerLinkDTO: Content {
    var id: UUID
    var label: String
    var actions: [String]
    var placeId: UUID?
    var kind: EngineSegmentKind
    var createdAt: Date
    var expiresAt: Date?
    var lastUsedAt: Date?
    var lastAction: String?
    var token: String?
    var path: String?
}

struct TriggerLinkService: Sendable {
    let scope: TimeServices

    func dto(_ row: TriggerLinkRecord, token: String? = nil) throws -> TriggerLinkDTO {
        try .init(id: row.requireID(), label: row.label, actions: row.actions, placeId: row.placeId,
                  kind: EngineSegmentKind(rawValue: row.kind) ?? .work, createdAt: row.createdAt, expiresAt: row.expiresAt,
                  lastUsedAt: row.lastUsedAt, lastAction: row.lastAction, token: token, path: token.map { "/t/" + $0 })
    }

    func list() async throws -> [TriggerLinkDTO] {
        try await TriggerLinkRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$revokedAt == nil)
            .sort(\.$createdAt).all().map { try dto($0) }
    }

    func create(_ input: TriggerLinkInput) async throws -> TriggerLinkDTO {
        let label = input.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = TriggerLinkRules.actions.intersection(input.actions)
        guard !label.isEmpty, label.fitsColumn(80), !input.actions.isEmpty, actions.count == Set(input.actions).count,
              input.expiresInDays.map({ (1...730).contains($0) }) ?? true else { throw APIError.invalid }
        if let placeId = input.placeId {
            let place = try await scope.places.record(placeId)
            guard place.payload.archived != true else { throw APIError.invalid }
        }
        let active = try await TriggerLinkRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$revokedAt == nil).count()
        guard active < TriggerLinkRules.maxActiveLinks else { throw APIError(.conflict, "too_many_trigger_links") }
        let token = Secrets.token(bytes: 32), now = Date()
        let row = TriggerLinkRecord()
        row.accountId = scope.accountId; row.tokenHash = Secrets.hash(token); row.label = label
        row.actions = TriggerLinkRules.actions.intersection(actions).sorted(); row.placeId = input.placeId
        row.kind = (input.kind ?? .work).rawValue; row.createdAt = now
        row.expiresAt = input.expiresInDays.map { now.addingTimeInterval(Double($0) * 86400) }
        try await row.create(on: scope.db)
        return try dto(row, token: token)
    }

    func revoke(_ id: UUID) async throws {
        guard let row = try await TriggerLinkRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$id == id).first() else { throw APIError.missing }
        if row.revokedAt == nil { row.revokedAt = Date(); try await row.update(on: scope.db) }
    }
}

extension TimeServices {
    var triggerLinks: TriggerLinkService { .init(scope: self) }
}

// MARK: Trigger execution

struct TriggerResult: Content {
    var result: String
    var action: String
    var segmentId: UUID?
    var suggestionId: UUID?
    var at: Date?
}

enum TriggerOutcome: Sendable {
    case notFound
    case limited
    case invalid
    case done(TriggerResult)
}

enum TriggerLinkExecutor {
    /// Resolves the token and runs the action in one serialized transaction. Unknown, revoked, expired and wrong-action
    /// requests are indistinguishable (`notFound`).
    static func run(token: String, action: String, atText: String?, placeText: String?, clientKey: String, auth: AuthService,
                    db: any Database, now: Date = Date()) async throws -> TriggerOutcome {
        try await auth.transaction(on: db) { tx in
            let missKey = "trigger-miss:" + clientKey
            let windowStart = now.addingTimeInterval(-TriggerLinkRules.window)
            if try await RateLimitEvent.query(on: tx).filter(\.$key == missKey).filter(\.$occurredAt > windowStart).count() >= TriggerLinkRules.missLimit {
                return .limited
            }
            func miss() async throws -> TriggerOutcome {
                try await RateLimitEvent(key: missKey, occurredAt: now).create(on: tx)
                try await RateLimitEvent.query(on: tx).filter(\.$key == missKey).filter(\.$occurredAt < now.addingTimeInterval(-2 * TriggerLinkRules.window)).delete()
                return .notFound
            }
            let hash = Secrets.hash(token)
            guard token.count == TriggerLinkRules.tokenLength, TriggerLinkRules.actions.contains(action),
                  let row = try await TriggerLinkRecord.query(on: tx).filter(\.$tokenHash == hash).first(),
                  Secrets.equal(row.tokenHash, hash), row.revokedAt == nil, row.expiresAt.map({ $0 > now }) ?? true,
                  row.actions.contains(action),
                  let account = try await Account.find(row.accountId, on: tx), account.disabledAt == nil,
                  try await ModuleRegistry(locked: auth.configuration.disabledModules).enabled(.automation, account: row.accountId, on: tx)
            else { return try await miss() }

            let linkKey = "trigger:" + (try row.requireID().uuidString)
            if try await RateLimitEvent.query(on: tx).filter(\.$key == linkKey).filter(\.$occurredAt > windowStart).count() >= TriggerLinkRules.linkLimit {
                return .limited
            }
            try await RateLimitEvent(key: linkKey, occurredAt: now).create(on: tx)
            try await RateLimitEvent.query(on: tx).filter(\.$key == linkKey).filter(\.$occurredAt < now.addingTimeInterval(-2 * TriggerLinkRules.window)).delete()

            var at = now
            if let atText {
                guard let parsed = timeInstant(atText), parsed >= now.addingTimeInterval(-TriggerLinkRules.maxBackdate),
                      parsed <= now.addingTimeInterval(TriggerLinkRules.maxFutureSkew) else { return .invalid }
                at = min(parsed, now)
            }
            let scope = TimeServices(accountId: row.accountId, db: tx, disabledModules: auth.configuration.disabledModules)
            var placeId = row.placeId
            if let placeText {
                guard let requested = UUID(uuidString: placeText), row.placeId == nil || row.placeId == requested else { return .invalid }
                placeId = requested
            }
            var mode = "direct"
            if let placeId {
                guard let place = try await PlaceRecord.query(on: tx).filter(\.$accountId == row.accountId).filter(\.$id == placeId).first(),
                      place.payload.archived != true else { return .invalid }
                mode = place.payload.automationMode
            }
            let previous = (row.lastUsedAt, row.lastAction)
            row.lastUsedAt = now; row.lastAction = action
            try await row.update(on: tx)

            let running = try await scope.timer.current()
            var effective = action
            if action == "toggle" {
                if previous.1 == "toggle", let last = previous.0, now.timeIntervalSince(last) < TriggerLinkRules.toggleGuard {
                    return .done(.init(result: running == nil ? "already_stopped" : "already_running", action: action, segmentId: running?.id))
                }
                effective = running == nil ? "start" : "stop"
            }
            var result = TriggerResult(result: "ignored", action: action, at: at)
            if mode == "off" { return .done(result) }

            if effective == "start" {
                if let running { result.result = "already_running"; result.segmentId = running.id; result.at = nil; return .done(result) }
                if mode == "suggest" {
                    let suggestion = try await scope.suggestions.create(type: "start", placeId: placeId, start: at, end: nil, segmentId: nil)
                    result.result = "suggested"; result.suggestionId = suggestion.id
                } else {
                    let segment = try await scope.segments.create(.init(kind: EngineSegmentKind(rawValue: row.kind) ?? .work, startedAt: at, placeId: placeId), source: .automation)
                    result.result = "started"; result.segmentId = segment.id
                }
            } else {
                guard let running else { result.result = "already_stopped"; result.at = nil; return .done(result) }
                // A link bound to a place only stops timers of that place or without a place.
                if let placeId, let bound = running.placeId, bound != placeId { return .done(result) }
                let stopped = try await scope.automation.stopRunning(running, at: at, placeId: placeId, mode: mode)
                result.segmentId = stopped.segmentId; result.suggestionId = stopped.suggestionId
                result.result = ["booked": "stopped"][stopped.result] ?? stopped.result
            }
            return .done(result)
        }
    }
}

// MARK: Routes

func registerTriggerRoutes(_ app: Application, auth: AuthService) {
    app.get("t", ":token", ":action") { req async throws -> Response in
        @Sendable func reply(_ status: HTTPResponseStatus, _ body: String, json: Bool = true) -> Response {
            let response = Response(status: status, body: .init(string: body))
            response.headers.replaceOrAdd(name: .contentType, value: json ? "application/json; charset=utf-8" : "text/plain; charset=utf-8")
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
            response.headers.replaceOrAdd(name: "X-Robots-Tag", value: "noindex, nofollow")
            response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
            return response
        }
        // Link prefetchers and HEAD probes must never trigger an action.
        let purpose = (req.headers.first(name: "Sec-Purpose") ?? req.headers.first(name: "Purpose") ?? "").lowercased()
        if req.method == .HEAD || purpose.contains("prefetch") || purpose.contains("prerender") || req.headers.first(name: "X-Moz") == "prefetch" {
            return reply(.noContent, "", json: false)
        }
        guard let token = req.parameters.get("token"), let action = req.parameters.get("action") else { return reply(.notFound, "{\"error\":\"not_found\"}") }
        let at: String? = req.query["at"], place: String? = req.query["place"]
        let text = (req.query[String.self, at: "format"]) == "text"
        let outcome: TriggerOutcome
        do {
            outcome = try await TriggerLinkExecutor.run(token: token, action: action, atText: at, placeText: place,
                                                        clientKey: req.clientRateLimitKey, auth: auth, db: req.db)
        } catch let error as APIError {
            return reply(error.status, "{\"error\":\"\(error.code)\"}")
        } catch is TimeEngineError {
            return reply(.badRequest, "{\"error\":\"bad_request\"}")
        }
        switch outcome {
        case .notFound: return reply(.notFound, "{\"error\":\"not_found\"}")
        case .limited:
            let response = reply(.tooManyRequests, "{\"error\":\"too_many_requests\"}")
            response.headers.replaceOrAdd(name: .retryAfter, value: String(Int(TriggerLinkRules.window)))
            return response
        case .invalid: return reply(.badRequest, "{\"error\":\"bad_request\"}")
        case .done(let result):
            if text { return reply(.ok, result.result + "\n", json: false) }
            let encoded = try timeResponse(result)
            encoded.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            encoded.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
            encoded.headers.replaceOrAdd(name: "X-Robots-Tag", value: "noindex, nofollow")
            encoded.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
            return encoded
        }
    }
}

// MARK: Log scrubbing

public enum TriggerTokenScrubber {
    private static let linkPattern = try! NSRegularExpression(pattern: "(/t/|/ics/)[A-Za-z0-9_-]{16,}")
    /// APNs device tokens (hex, 64 or more characters), PEM private keys and JWTs (provider tokens), see ADR-0030.
    private static let apnsPatterns: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: "(?<![0-9A-Za-z])[0-9a-fA-F]{64,}(?![0-9A-Za-z])"), "[redacted]"),
        (try! NSRegularExpression(pattern: "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"), "[redacted]"),
        (try! NSRegularExpression(pattern: "eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]*"), "[redacted]"),
    ]

    /// Replaces the token segment of any `/t/<token>` or `/ics/<token>.ics` path in a log line, and APNs tokens, keys and JWTs. Used by the console log
    /// handler as a second line of defence; the application itself never logs request paths or push tokens.
    public static func scrub(_ text: String) -> String {
        var result = text
        if result.contains("/t/") || result.contains("/ics/") {
            result = linkPattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1[redacted]")
        }
        for (pattern, template) in apnsPatterns {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }
}
