import Foundation
import Fluent
import Vapor

// Every service is constructed only inside the serialized unit of work below. Nested
// services share its connection, so validation, writes and idempotency commit together.
struct TimeServices: Sendable {
    let accountId: UUID
    let db: any Database
    var disabledModules: Set<ModuleKey> = []
    var models: WorkModelService { .init(scope: self) }
    var places: PlaceService { .init(scope: self) }
    var segments: SegmentService { .init(scope: self) }
    var timer: TimerService { .init(scope: self) }
    var days: DayService { .init(scope: self) }
    var account: AccountService { .init(scope: self) }
    var suggestions: SuggestionService { .init(scope: self) }
    var devices: DeviceTokenService { .init(scope: self) }
    var automation: AutomationService { .init(scope: self) }
    var vacation: VacationService { .init(scope: self) }
    var absences: AbsenceService { .init(scope: self) }
    var calendar: CalendarService { .init(scope: self) }
    var plans: PlanService { .init(scope: self) }
    var weeks: TimeWeekService { .init(scope: self) }
    var shares: ShareService { .init(scope: self) }

    /// Read-only requests: the session was authenticated by the session middleware in this very request, so no
    /// second authentication and, above all, no global `auth_lock` (which serialises every request of every
    /// account) is needed. A transaction still gives all reads of one request a consistent snapshot. Handlers
    /// that write (even lazily, like the suggestion review) must use `session`.
    static func read<T: Sendable>(_ context: AuthContext, auth: AuthService, db: any Database,
                                  operation: @escaping @Sendable (TimeServices) async throws -> T) async throws -> T {
        try context.normal()
        let accountId = try context.account.requireID(), disabled = auth.configuration.disabledModules
        return try await db.transaction { tx in
            try await operation(TimeServices(accountId: accountId, db: tx, disabledModules: disabled))
        }
    }

    static func session<T: Sendable>(_ context: AuthContext, auth: AuthService, db: any Database,
                                    operation: @escaping @Sendable (TimeServices) async throws -> T) async throws -> T {
        try await auth.transaction(on: db) { tx in
            let current = try await auth.authenticate(context.token, on: tx)
            try current.normal()
            return try await operation(.init(accountId: current.account.requireID(), db: tx, disabledModules: auth.configuration.disabledModules))
        }
    }
}

struct WorkModelService: Sendable {
    let scope: TimeServices
    func list() async throws -> [WorkModelDTO] {
        try await WorkModelRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).sort(\.$validFrom).all().map(\.versioned)
    }
    func record(_ id: UUID) async throws -> WorkModelRecord {
        guard let row = try await WorkModelRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$id == id).first() else { throw APIError.missing }
        return row
    }
    func create(_ input: WorkModelDTO) async throws -> WorkModelDTO {
        _ = try input.engine()
        let versions = try await WorkModelRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).sort(\.$validFrom, .descending).all()
        if let previous = versions.first {
            guard input.validFrom.description > previous.validFrom else { throw APIError(.conflict, "model_overlap") }
            if previous.validTo == nil {
                previous.validTo = input.validFrom.addingDays(-1).description
                previous.payload.validTo = input.validFrom.addingDays(-1)
                try await previous.update(on: scope.db)
            } else if previous.validTo! >= input.validFrom.description { throw APIError(.conflict, "model_overlap") }
        }
        let row = WorkModelRecord(); row.id = UUID(); row.accountId = scope.accountId
        var value = input; value.id = row.id; value.createdAt = Date(); value.version = 1
        row.validFrom = value.validFrom.description; row.validTo = value.validTo?.description; row.payload = value
        try await row.create(on: scope.db)
        return value
    }
    func end(_ id: UUID, at date: LocalDate) async throws -> WorkModelDTO {
        let row = try await record(id)
        guard date >= row.payload.validFrom else { throw APIError.invalid }
        let versions = try await list()
        guard !versions.contains(where: { $0.id != id && $0.validFrom > row.payload.validFrom && $0.validFrom <= date }) else { throw APIError(.conflict, "model_overlap") }
        row.validTo = date.description; row.payload.validTo = date
        try await row.update(on: scope.db); return row.versioned
    }
}

struct PlaceService: Sendable {
    let scope: TimeServices
    func list() async throws -> [PlaceDTO] {
        try await PlaceRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).all().map(\.payload).filter { $0.archived != true }
    }
    func record(_ id: UUID) async throws -> PlaceRecord {
        guard let row = try await PlaceRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$id == id).first() else { throw APIError.missing }
        return row
    }
    func save(_ input: PlaceDTO, id: UUID? = nil) async throws -> PlaceDTO {
        try input.validate()
        let row: PlaceRecord
        if let id { row = try await record(id) } else { row = PlaceRecord(); row.id = UUID(); row.accountId = scope.accountId }
        var value = input; value.id = row.id; value.archived = id == nil ? false : row.payload.archived
        value.confirmAfterSeconds = value.confirmAfterSeconds ?? 300; value.defaultSegmentKind = value.defaultSegmentKind ?? .work
        row.payload = value; try await row.save(on: scope.db); return value
    }
    func archive(_ id: UUID) async throws {
        let row = try await record(id); row.payload.archived = true; try await row.update(on: scope.db)
    }
}

extension SegmentRecord {
    func dto() throws -> EngineSegment {
        guard let kind = EngineSegmentKind(rawValue: kind), let source = EngineSegmentSource(rawValue: source) else { throw APIError.invalid }
        return try .init(id: requireID(), kind: kind, start: startedAt, end: endedAt, voided: voidedAt != nil,
                        rawStartedAt: rawStartedAt, rawEndedAt: rawEndedAt, source: source, version: version,
                        needsReview: needsReview, placeId: placeId, note: note, revisions: revisions)
    }
}
struct SegmentService: Sendable {
    let scope: TimeServices
    func all() async throws -> [EngineSegment] {
        try await all(window: nil)
    }
    /// Segments that can belong to the given days. A segment is assigned to a civil day at most one day away
    /// from its local start date (time zone offset below 15 h plus the day boundary below 12 h), so a margin of
    /// three days before and four days after the window is safe. `nil` loads everything.
    func all(window: ClosedRange<LocalDate>?) async throws -> [EngineSegment] {
        let query = SegmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
        if let window {
            query.filter(\.$startedAt >= window.lowerBound.addingDays(-3).utcMidnight)
                .filter(\.$startedAt < window.upperBound.addingDays(4).utcMidnight)
        }
        return try await query.sort(\.$startedAt).all().map { try $0.dto() }
    }
    /// Segments whose start lies in [from, to), optionally including voided ones.
    func list(from: Date, to: Date, includeVoided: Bool) async throws -> [EngineSegment] {
        let query = SegmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
            .filter(\.$startedAt >= from).filter(\.$startedAt < to)
        if !includeVoided { query.filter(\.$voidedAt == nil) }
        return try await query.sort(\.$startedAt).all().map { try $0.dto() }
    }
    func record(_ id: UUID) async throws -> SegmentRecord {
        guard let row = try await SegmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$id == id).first() else { throw APIError.missing }
        return row
    }
    func validate(_ value: EngineSegment) async throws {
        guard value.endedAt.map({ $0 > value.startedAt }) ?? true, (value.note?.count ?? 0) <= 500 else { throw APIError.invalid }
        if let place = value.placeId { _ = try await scope.places.record(place) }
        // Superset pre-filter in SQL (inclusive bounds, voided rows never overlap); the exact half-open test
        // below decides, so the outcome equals checking against every stored segment.
        let candidates = SegmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$voidedAt == nil)
        if let end = value.endedAt { candidates.filter(\.$startedAt <= end) }
        let start: Date? = value.startedAt
        candidates.group(.or) { $0.filter(\.$endedAt == nil).filter(\.$endedAt >= start) }
        for other in try await candidates.all().map({ try $0.dto() }) where other.id != value.id {
            if try TimeEngine.detectOverlap(value, other) { throw APIError(.conflict, "segment_overlap") }
        }
    }
    func create(_ input: SegmentInput, source: EngineSegmentSource = .manual, eventId: UUID? = nil) async throws -> EngineSegment {
        let value = EngineSegment(kind: input.kind, start: input.startedAt, end: input.endedAt,
                                  rawStartedAt: input.startedAt, rawEndedAt: input.endedAt, source: source, placeId: input.placeId, note: input.note)
        try await validate(value)
        let row = SegmentRecord(); row.id = value.id; row.accountId = scope.accountId
        row.rawStartedAt = value.rawStartedAt; row.rawEndedAt = value.rawEndedAt
        row.startedAt = value.startedAt; row.endedAt = value.endedAt; row.kind = value.kind.rawValue
        row.placeId = value.placeId; row.source = source.rawValue; row.note = value.note; row.version = 1
        row.needsReview = false; row.clientEventId = eventId; row.running = value.endedAt == nil ? 1 : nil; row.revisions = 0
        try await row.create(on: scope.db); return try row.dto()
    }
    func revise(_ row: SegmentRecord, value: EngineSegment, reason: String, storedReason: String? = nil) async throws -> EngineSegment {
        try validateReason(reason); try await validate(value)
        let before = try row.dto()
        row.startedAt = value.startedAt; row.endedAt = value.endedAt; row.kind = value.kind.rawValue
        row.placeId = value.placeId; row.note = value.note; row.needsReview = value.needsReview
        row.version += 1; row.revisions += 1
        row.running = row.endedAt == nil && row.voidedAt == nil ? 1 : nil
        let after = try row.dto()
        let revision = RevisionRecord(); revision.accountId = scope.accountId; revision.segmentId = try row.requireID()
        revision.before = before; revision.after = after; revision.reason = storedReason ?? reason; revision.createdAt = Date()
        try await row.update(on: scope.db); try await revision.create(on: scope.db)
        return after
    }
    func correct(_ id: UUID, input: SegmentCorrection, version: Int?) async throws -> EngineSegment {
        let row = try await record(id)
        guard version == row.version else { throw APIError(.preconditionFailed, "stale_version") }
        guard row.voidedAt == nil else { throw APIError(.conflict, "conflict") }
        var value = try row.dto()
        if let start = input.startedAt { value.startedAt = start }
        let reopens = input.hasEnd && input.endedAt == nil && value.endedAt != nil
        if input.hasEnd { value.endedAt = input.endedAt }
        if input.hasPlace { value.placeId = input.placeId }
        if input.hasNote { value.note = input.note }
        if let kind = input.kind { value.kind = kind }
        if reopens { try validateReason(input.reason); try await requireReopenable(row) }
        // Reopening is marked in the revision history by a fixed reason prefix (rawEndedAt stays untouched).
        return try await revise(row, value: value, reason: input.reason, storedReason: reopens ? Self.reopenReasonPrefix + input.reason : nil)
    }
    static let reopenReasonPrefix = "Reopened: "
    /// Reopening a finished segment (PATCH with explicit `endedAt: null`) needs no other running segment
    /// (409 timer_already_running) and no other live segment starting at or after its original end
    /// (409 segment_overlap), i.e. it must be the account's latest segment.
    func requireReopenable(_ row: SegmentRecord) async throws {
        guard let end = row.endedAt else { return }
        let id = try row.requireID()
        if try await SegmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$running == 1).filter(\.$id != id).first() != nil {
            throw APIError(.conflict, "timer_already_running")
        }
        if try await SegmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$voidedAt == nil)
            .filter(\.$id != id).filter(\.$startedAt >= end).first() != nil {
            throw APIError(.conflict, "segment_overlap")
        }
    }
    func void(_ id: UUID, reason: String) async throws {
        try validateReason(reason)
        let row = try await record(id)
        if row.voidedAt != nil { return }
        let before = try row.dto()
        row.voidedAt = Date(); row.voidReason = reason; row.running = nil; row.version += 1; row.revisions += 1
        let revision = RevisionRecord(); revision.accountId = scope.accountId; revision.segmentId = id
        revision.before = before; revision.after = try row.dto(); revision.reason = reason; revision.createdAt = Date()
        try await row.update(on: scope.db); try await revision.create(on: scope.db)
    }
}

struct TimerService: Sendable {
    let scope: TimeServices
    func current() async throws -> SegmentRecord? {
        try await SegmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$running == 1).first()
    }
    func act(_ input: TimerInput, action: String, now: Date = Date()) async throws -> EngineSegment {
        if let event = try await TimerEventRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
            .filter(\.$clientEventId == input.clientEventId).filter(\.$action == action).first() { return event.result }
        let running = try await current()
        let value: EngineSegment
        if action == "start" {
            guard running == nil else { throw APIError(.conflict, "timer_already_running") }
            value = try await scope.segments.create(.init(kind: input.kind ?? .work, startedAt: now, placeId: input.placeId), source: .timer, eventId: input.clientEventId)
        } else {
            guard let running else { throw APIError(.conflict, "no_running_timer") }
            var next = try running.dto(); next.endedAt = now
            // Raw capture stays immutable; the stop event and revision preserve the observed end.
            value = try await scope.segments.revise(running, value: next, reason: "Timer stopped")
        }
        let event = TimerEventRecord(); event.accountId = scope.accountId; event.clientEventId = input.clientEventId
        event.action = action; event.result = value; try await event.create(on: scope.db)
        return value
    }
}
