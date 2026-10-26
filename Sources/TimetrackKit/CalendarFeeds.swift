import Foundation
import Fluent
import Vapor
import Crypto

// N2: revocable ICS calendar subscription feeds. A GET request to /ics/<token>.ics returns the owning account's vacation and other
// absences, public holidays, planned work days and tracked-time summaries as RFC 5545 all-day events. Like the trigger links
// (ADR-0027) the 256-bit token in the URL is the only credential and only its SHA-256 hash is stored. Management (create/list/revoke)
// is a session-authenticated REST API under /me/calendar-feeds; it is deliberately not exposed through MCP.

enum CalendarFeedRules {
    /// Selectable content, see `CalendarFeedInput.include`.
    static let options: Set<String> = ["absences", "holidays", "plan", "tracked"]
    static let defaultOptions = ["absences", "holidays"]
    static let maxActiveFeeds = 10
    static let pastDays = 60
    static let futureDays = 400
    /// Requests per feed and window (calendar clients poll hourly or less) and failed lookups per client address and window.
    static let feedLimit = 60
    static let missLimit = 30
    static let window: TimeInterval = 300
    static let tokenLength = 43
    static let suffix = ".ics"
    static let maxAge = 900
}

final class CalendarFeedRecord: Model, @unchecked Sendable {
    static let schema = "calendar_feeds"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "label") var label: String
    @Field(key: "options") var options: [String]
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "expires_at") var expiresAt: Date?
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    @OptionalField(key: "last_used_at") var lastUsedAt: Date?
    init() {}
}

struct CreateCalendarFeeds: AsyncMigration {
    let name = "n2.create_calendar_feeds"
    func prepare(on db: any Database) async throws {
        try await db.schema("calendar_feeds").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("token_hash", .string, .required)
            .field("label", .string, .required)
            .field("options", .json, .required)
            .field("created_at", .datetime, .required)
            .field("expires_at", .datetime)
            .field("revoked_at", .datetime)
            .field("last_used_at", .datetime)
            .unique(on: "token_hash")
            .create()
        try await requireSQL(db).create(index: "idx_calendar_feeds_account").on("calendar_feeds").column("account_id").run()
    }
    func revert(on db: any Database) async throws { try await db.schema("calendar_feeds").delete() }
}

struct CalendarFeedInput: Content {
    var label: String
    /// Subset of absences, holidays, plan, tracked; defaults to absences and holidays.
    var include: [String]?
    var expiresInDays: Int?
}

/// Management view. `token` and `path` are present only in the response of the creating request.
struct CalendarFeedDTO: Content {
    var id: UUID
    var label: String
    var include: [String]
    var createdAt: Date
    var expiresAt: Date?
    var lastUsedAt: Date?
    var token: String?
    var path: String?
}

struct CalendarFeedService: Sendable {
    let scope: TimeServices

    func dto(_ row: CalendarFeedRecord, token: String? = nil) throws -> CalendarFeedDTO {
        try .init(id: row.requireID(), label: row.label, include: row.options, createdAt: row.createdAt, expiresAt: row.expiresAt,
                  lastUsedAt: row.lastUsedAt, token: token, path: token.map { "/ics/" + $0 + CalendarFeedRules.suffix })
    }

    func list() async throws -> [CalendarFeedDTO] {
        try await CalendarFeedRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$revokedAt == nil)
            .sort(\.$createdAt).all().map { try dto($0) }
    }

    func create(_ input: CalendarFeedInput) async throws -> CalendarFeedDTO {
        let label = input.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let requested = input.include ?? CalendarFeedRules.defaultOptions
        guard !label.isEmpty, label.fitsColumn(80), !requested.isEmpty, Set(requested).count == requested.count,
              Set(requested).isSubset(of: CalendarFeedRules.options),
              input.expiresInDays.map({ (1...730).contains($0) }) ?? true else { throw APIError.invalid }
        let active = try await CalendarFeedRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$revokedAt == nil).count()
        guard active < CalendarFeedRules.maxActiveFeeds else { throw APIError(.conflict, "too_many_calendar_feeds") }
        let token = Secrets.token(bytes: 32), now = Date()
        let row = CalendarFeedRecord()
        row.accountId = scope.accountId; row.tokenHash = Secrets.hash(token); row.label = label
        row.options = CalendarFeedRules.options.intersection(requested).sorted(); row.createdAt = now
        row.expiresAt = input.expiresInDays.map { now.addingTimeInterval(Double($0) * 86400) }
        try await row.create(on: scope.db)
        return try dto(row, token: token)
    }

    func revoke(_ id: UUID) async throws {
        guard let row = try await CalendarFeedRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$id == id).first() else { throw APIError.missing }
        if row.revokedAt == nil { row.revokedAt = Date(); try await row.update(on: scope.db) }
    }
}

extension TimeServices {
    var calendarFeeds: CalendarFeedService { .init(scope: self) }
}

// MARK: RFC 5545 writer

enum ICSWriter {
    /// Escapes a TEXT value (backslash, semicolon, comma, newline).
    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\": result += "\\\\"
            case ";": result += "\\;"
            case ",": result += "\\,"
            case "\n", "\r\n", "\r": result += "\\n"
            default: result.append(character)
            }
        }
        return result
    }

    /// Folds a content line at 75 octets without splitting a UTF-8 sequence; continuation lines start with one space.
    static func fold(_ line: String) -> String {
        var output = "", used = 0, first = true
        for character in line {
            let size = String(character).utf8.count
            if used + size > (first ? 75 : 74) {
                output += "\r\n "; used = 0; first = false
            }
            output.append(character); used += size
        }
        return output
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// RFC 9110 IMF-fixdate for Last-Modified.
    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    static func day(_ date: LocalDate) -> String { String(format: "%04d%02d%02d", date.year, date.month, date.day) }
}

struct ICSEvent {
    var uid: String
    var start: LocalDate
    /// Last day of the event (inclusive); written as the exclusive DTEND.
    var end: LocalDate
    var summary: String
    var description: String?
    var category: String
    var transparent: Bool
    var status: String?
    var stamp: Date
}

// MARK: Content

enum CalendarFeedBuilder {
    static let calendarName = "Timetrack"

    static func absenceLabel(kind: String, status: String) -> String {
        let name = ["vacation": "Urlaub", "sick": "Krank", "excused": "Freistellung"][kind] ?? "Abwesenheit"
        let state = ["planned": "geplant", "requested": "beantragt", "approved": "genehmigt", "taken": "genommen"][status] ?? status
        return "\(name) (\(state))"
    }

    static func planLabel(_ mode: String) -> String {
        "Plan: " + (["office": "Büro", "home": "Homeoffice", "customer": "Kunde", "school": "Berufsschule", "off": "Frei"][mode] ?? mode)
    }

    static func hours(_ seconds: Int) -> String { String(format: "%d:%02d h", seconds / 3600, seconds % 3600 / 60) }

    /// Window and events of one feed. Only the data of `scope.accountId` is read.
    static func events(feed: CalendarFeedRecord, scope: TimeServices, now: Date, host: String) async throws -> (events: [ICSEvent], modified: Date) {
        let options = Set(feed.options)
        let wantsTracked = options.contains("tracked")
        // The window is anchored to the civil today in the time zone of the latest work model.
        let models = try await scope.models.list()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = models.last?.timezone.flatMap { TimeZone(identifier: $0) } ?? TimeZone(identifier: "Europe/Berlin")!
        let today = LocalDate.local(now, calendar: calendar)
        let from = today.addingDays(-CalendarFeedRules.pastDays), to = today.addingDays(CalendarFeedRules.futureDays)
        let snapshot = try await scope.days.snapshot(window: from...today, includeSegments: wantsTracked)
        let planning = snapshot.planningEnabled
        var events: [ICSEvent] = []
        var modified = feed.createdAt

        if planning, options.contains("absences") {
            let rows = try await AbsenceRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
                .filter(\.$startDate <= to.description).filter(\.$endDate >= from.description).sort(\.$startDate).all()
            for row in rows where ["planned", "requested", "approved", "taken"].contains(row.status) {
                let start = try LocalDate(row.startDate), end = try LocalDate(row.endDate)
                var notes: [String] = []
                if row.halfDayStart { notes.append(start == end ? "Halber Tag" : "Erster Tag halb") }
                if row.halfDayEnd, start != end { notes.append("Letzter Tag halb") }
                modified = max(modified, row.updatedAt)
                events.append(.init(uid: "absence-\(try row.requireID().uuidString.lowercased())@\(host)", start: start, end: end,
                                    summary: absenceLabel(kind: row.kind, status: row.status),
                                    description: notes.isEmpty ? nil : notes.joined(separator: ". "), category: "Abwesenheit",
                                    transparent: false, status: row.status == "approved" || row.status == "taken" ? "CONFIRMED" : "TENTATIVE",
                                    stamp: row.updatedAt))
            }
        }

        if planning, options.contains("holidays") {
            var days: [CustomCalendarDay] = []
            for year in from.year...to.year { days += (try? HolidayCalendar.holidays(year: year, region: snapshot.region)) ?? [] }
            days += snapshot.customDays
            for day in days where day.startDate <= to && day.endDate >= from {
                let school = day.kind == .schoolHoliday
                let key = day.id?.uuidString.lowercased() ?? Secrets.hash(day.name).prefix(10).lowercased()
                events.append(.init(uid: "holiday-\(day.startDate)-\(key)@\(host)", start: day.startDate, end: day.endDate,
                                    summary: school ? "Schulferien: " + day.name : day.name, description: nil,
                                    category: school ? "Schulferien" : "Feiertag", transparent: true, status: "CONFIRMED", stamp: feed.createdAt))
            }
        }

        if planning, options.contains("plan") {
            let rows = try await PlanDayRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
                .filter(\.$date >= from.description).filter(\.$date <= to.description).sort(\.$date).all()
            for row in rows {
                let date = try LocalDate(row.date)
                var description: String?
                if let start = row.plannedStart, let end = row.plannedEnd {
                    description = "Geplant \(start)-\(end)" + (row.plannedBreakMinutes.map { ", Pause \($0) min" } ?? "")
                }
                events.append(.init(uid: "plan-\(date)@\(host)", start: date, end: date, summary: planLabel(row.mode), description: description,
                                    category: "Planung", transparent: true, status: "TENTATIVE", stamp: feed.createdAt))
            }
        }

        if wantsTracked {
            let prepared = snapshot.prepared()
            var date = from
            while date <= today {
                if let result = try? prepared.evaluate(date, now: now), result.evaluatedWorkSeconds > 0 {
                    var lines = ["Arbeitszeit (bewertet): " + hours(result.evaluatedWorkSeconds)]
                    if result.rawWorkSeconds != result.evaluatedWorkSeconds { lines.append("Rohzeit: " + hours(result.rawWorkSeconds)) }
                    events.append(.init(uid: "tracked-\(date)@\(host)", start: date, end: date, summary: "Erfasst: " + hours(result.evaluatedWorkSeconds),
                                        description: lines.joined(separator: "\n"), category: "Zeiterfassung", transparent: true,
                                        status: "CONFIRMED", stamp: feed.createdAt))
                }
                date = date.addingDays(1)
            }
        }
        events.sort { ($0.start, $0.uid) < ($1.start, $1.uid) }
        return (events, modified)
    }

    /// Serialises a calendar with CRLF line ends and folded lines.
    static func render(label: String, events: [ICSEvent]) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Timetrack//Calendar Feed//DE", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
                     "X-WR-CALNAME:" + ICSWriter.escape(label.isEmpty ? calendarName : label),
                     "REFRESH-INTERVAL;VALUE=DURATION:PT1H", "X-PUBLISHED-TTL:PT1H"]
        for event in events {
            lines += ["BEGIN:VEVENT", "UID:" + event.uid, "DTSTAMP:" + ICSWriter.stamp(event.stamp),
                      "DTSTART;VALUE=DATE:" + ICSWriter.day(event.start), "DTEND;VALUE=DATE:" + ICSWriter.day(event.end.addingDays(1)),
                      "SUMMARY:" + ICSWriter.escape(event.summary)]
            if let description = event.description { lines.append("DESCRIPTION:" + ICSWriter.escape(description)) }
            lines.append("CATEGORIES:" + ICSWriter.escape(event.category))
            if let status = event.status { lines.append("STATUS:" + status) }
            lines += ["TRANSP:" + (event.transparent ? "TRANSPARENT" : "OPAQUE"), "END:VEVENT"]
        }
        lines.append("END:VCALENDAR")
        return lines.map(ICSWriter.fold).joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: Lookup

enum CalendarFeedOutcome: Sendable {
    case notFound
    case limited
    case found(accountId: UUID, feedId: UUID)
}

enum CalendarFeedLookup {
    /// Resolves the token and applies both rate limits in one serialized transaction. Unknown, revoked, expired, malformed tokens and
    /// disabled accounts are indistinguishable (`notFound`).
    static func resolve(file: String, clientKey: String, auth: AuthService, db: any Database, now: Date = Date()) async throws -> CalendarFeedOutcome {
        try await auth.transaction(on: db) { tx in
            let missKey = "ics-miss:" + clientKey
            let windowStart = now.addingTimeInterval(-CalendarFeedRules.window)
            if try await RateLimitEvent.query(on: tx).filter(\.$key == missKey).filter(\.$occurredAt > windowStart).count() >= CalendarFeedRules.missLimit {
                return .limited
            }
            func miss() async throws -> CalendarFeedOutcome {
                try await RateLimitEvent(key: missKey, occurredAt: now).create(on: tx)
                try await RateLimitEvent.query(on: tx).filter(\.$key == missKey).filter(\.$occurredAt < now.addingTimeInterval(-2 * CalendarFeedRules.window)).delete()
                return .notFound
            }
            guard file.hasSuffix(CalendarFeedRules.suffix) else { return try await miss() }
            let token = String(file.dropLast(CalendarFeedRules.suffix.count))
            let hash = Secrets.hash(token)
            guard token.count == CalendarFeedRules.tokenLength,
                  let row = try await CalendarFeedRecord.query(on: tx).filter(\.$tokenHash == hash).first(),
                  Secrets.equal(row.tokenHash, hash), row.revokedAt == nil, row.expiresAt.map({ $0 > now }) ?? true,
                  let account = try await Account.find(row.accountId, on: tx), account.disabledAt == nil
            else { return try await miss() }
            let feedKey = "ics:" + (try row.requireID().uuidString)
            if try await RateLimitEvent.query(on: tx).filter(\.$key == feedKey).filter(\.$occurredAt > windowStart).count() >= CalendarFeedRules.feedLimit {
                return .limited
            }
            try await RateLimitEvent(key: feedKey, occurredAt: now).create(on: tx)
            try await RateLimitEvent.query(on: tx).filter(\.$key == feedKey).filter(\.$occurredAt < now.addingTimeInterval(-2 * CalendarFeedRules.window)).delete()
            row.lastUsedAt = now
            try await row.update(on: tx)
            return .found(accountId: row.accountId, feedId: try row.requireID())
        }
    }
}

// MARK: Route

func registerCalendarFeedRoutes(_ app: Application, auth: AuthService) {
    app.get("ics", ":file") { req async throws -> Response in
        @Sendable func harden(_ response: Response) {
            response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
            response.headers.replaceOrAdd(name: "X-Robots-Tag", value: "noindex, nofollow")
            response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        }
        @Sendable func reply(_ status: HTTPResponseStatus, _ body: String, type: String = "application/json; charset=utf-8") -> Response {
            let response = Response(status: status, body: .init(string: body))
            response.headers.replaceOrAdd(name: .contentType, value: type)
            harden(response)
            return response
        }
        guard let file = req.parameters.get("file") else {
            let response = reply(.notFound, "{\"error\":\"not_found\"}"); response.headers.replaceOrAdd(name: .cacheControl, value: "no-store"); return response
        }
        let outcome = try await CalendarFeedLookup.resolve(file: file, clientKey: req.clientRateLimitKey, auth: auth, db: req.db)
        switch outcome {
        case .notFound:
            let response = reply(.notFound, "{\"error\":\"not_found\"}"); response.headers.replaceOrAdd(name: .cacheControl, value: "no-store"); return response
        case .limited:
            let response = reply(.tooManyRequests, "{\"error\":\"too_many_requests\"}")
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            response.headers.replaceOrAdd(name: .retryAfter, value: String(Int(CalendarFeedRules.window)))
            return response
        case .found(let accountId, let feedId):
            guard let feed = try await CalendarFeedRecord.find(feedId, on: req.db) else {
                let response = reply(.notFound, "{\"error\":\"not_found\"}"); response.headers.replaceOrAdd(name: .cacheControl, value: "no-store"); return response
            }
            let scope = TimeServices(accountId: accountId, db: req.db, disabledModules: auth.configuration.disabledModules)
            let host = auth.configuration.publicBaseURL.host ?? "timetrack.invalid"
            let built = try await CalendarFeedBuilder.events(feed: feed, scope: scope, now: Date(), host: host)
            let body = CalendarFeedBuilder.render(label: feed.label, events: built.events)
            let etag = "\"" + Secrets.hash(body) + "\""
            let response: Response
            if req.headers.first(name: .ifNoneMatch)?.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == etag || $0.trimmingCharacters(in: .whitespaces) == "W/" + etag }) == true {
                response = Response(status: .notModified)
            } else {
                response = Response(status: .ok, body: .init(string: body))
                response.headers.replaceOrAdd(name: .contentType, value: "text/calendar; charset=utf-8")
                response.headers.replaceOrAdd(name: .contentDisposition, value: "inline; filename=\"timetrack.ics\"")
            }
            response.headers.replaceOrAdd(name: .eTag, value: etag)
            response.headers.replaceOrAdd(name: .lastModified, value: ICSWriter.httpDate(built.modified))
            // Private: the URL is a credential, so shared caches must not keep the response.
            response.headers.replaceOrAdd(name: .cacheControl, value: "private, max-age=\(CalendarFeedRules.maxAge), must-revalidate")
            harden(response)
            return response
        }
    }
}
