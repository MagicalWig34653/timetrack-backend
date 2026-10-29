import Foundation
import Fluent
import SQLKit

// Stage 3a services. Like the stage-2 services they run inside one serialized unit of work
// (`TimeServices.session`) and filter every query by the authenticated account.

enum PlanningLimits {
    static let planningRangeDays = 366
    static let dayRangeDays = 93
    static let absenceDays = 366
}

extension LocalDate {
    /// Inclusive span check shared by all range endpoints: `to >= from`, at most `maxDays` days.
    static func checkedRange(from: LocalDate, to: LocalDate, maxDays: Int) throws {
        guard to >= from else { throw APIError.invalid }
        guard from.distance(to: to) < maxDays else { throw APIError(.badRequest, "range_too_large") }
    }
}

struct VacationService: Sendable {
    let scope: TimeServices

    // MARK: Settings

    static let defaultSettings = VacationSettingsDTO(configured: false, region: "DE-ST", annualEntitlementHalfDays: 60,
                                                     carryOverByYear: [:], carryOverExpiry: nil)
    func settingsRecord() async throws -> VacationSettingsRecord? {
        try await VacationSettingsRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).first()
    }
    func settings() async throws -> VacationSettingsDTO {
        guard let row = try await settingsRecord() else { return Self.defaultSettings }
        return .init(configured: true, region: row.region, annualEntitlementHalfDays: row.annualEntitlementHalfDays,
                     carryOverByYear: row.carryOver, carryOverExpiry: row.carryOverExpiry,
                     companyDays: CompanyDayRules.listed(row.companyDays ?? []))
    }
    func engineSettings(_ dto: VacationSettingsDTO) throws -> VacationSettings {
        var carry: [Int: Int] = [:]
        for (key, value) in dto.carryOverByYear ?? [:] {
            guard key.count == 4, let year = Int(key), String(year) == key else { throw APIError.invalid }
            carry[year] = value
        }
        return VacationSettings(region: dto.region, annualEntitlementHalfDays: dto.annualEntitlementHalfDays,
                                carryOverByYear: carry, carryOverExpiry: dto.carryOverExpiry,
                                companyDays: dto.companyDays ?? [])
    }
    func save(_ input: VacationSettingsDTO) async throws -> VacationSettingsDTO {
        guard HolidayCalendar.supportedRegions.contains(input.region), (0...VacationLimits.maxHalfDays).contains(input.annualEntitlementHalfDays) else { throw APIError.invalid }
        for (key, value) in input.carryOverByYear ?? [:] {
            guard key.count == 4, let year = Int(key), String(year) == key, (1990...2100).contains(year), (0...VacationLimits.maxHalfDays).contains(value) else { throw APIError.invalid }
        }
        if let expiry = input.carryOverExpiry {
            // Validated against a non-leap year so that the expiry exists in every year.
            guard expiry.count == 5, (try? LocalDate("2023-" + expiry)) != nil else { throw APIError.invalid }
        }
        var companyDays: [CompanyDayRule]?
        if let rules = input.companyDays {
            guard let valid = CompanyDayRules.validated(rules) else { throw APIError.invalid }
            companyDays = valid
        }
        let row = try await settingsRecord() ?? VacationSettingsRecord()
        if let companyDays { row.companyDays = companyDays }
        row.accountId = scope.accountId; row.region = input.region
        row.annualEntitlementHalfDays = input.annualEntitlementHalfDays
        row.carryOver = input.carryOverByYear ?? [:]; row.carryOverExpiry = input.carryOverExpiry
        try await row.save(on: scope.db)
        return try await settings()
    }

    // MARK: Calendar inputs

    func customDays() async throws -> [CustomCalendarDay] {
        try await CustomCalendarDayRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).sort(\.$startDate).all().map { try $0.engine() }
    }
    func engineAbsences(window: ClosedRange<LocalDate>? = nil) async throws -> [EngineAbsence] {
        let query = AbsenceRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
        if let window { query.filter(\.$startDate <= window.upperBound.description).filter(\.$endDate >= window.lowerBound.description) }
        return try await query.sort(\.$startDate).all().map { try $0.engine() }
    }

    // MARK: Snapshots, adjustments, entries

    func balance(year: Int) async throws -> VacationBalanceDTO {
        guard (1990...2100).contains(year) else { throw APIError.invalid }
        let settings = try engineSettings(await settings())
        let models = try await scope.models.list().map { try $0.engine() }
        let absences = try await engineAbsences().filter { $0.startDate.year <= year && $0.endDate.year >= year }
        let snapshots = try await VacationSnapshotRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).all()
            .map { VacationSnapshot(date: try LocalDate($0.date), remainingHalfDays: $0.remainingHalfDays) }
        let adjustments = try await VacationAdjustmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).all()
            .map { VacationAdjustment(date: try LocalDate($0.date), halfDays: $0.halfDays) }
        let custom = try await customDays()
        return VacationBalanceDTO(try VacationEngine.balance(year: year, settings: settings, absences: absences, models: models,
            snapshots: snapshots, adjustments: adjustments, customCalendarDays: custom, lenient: true))
    }
    func createSnapshot(_ input: SnapshotInput) async throws -> VacationBalanceDTO {
        guard (0...VacationLimits.maxHalfDays).contains(input.remainingHalfDays), (1990...2100).contains(input.date.year) else { throw APIError.invalid }
        guard try await VacationSnapshotRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
            .filter(\.$date == input.date.description).first() == nil else { throw APIError(.conflict, "conflict") }
        let row = VacationSnapshotRecord(); row.id = UUID(); row.accountId = scope.accountId
        row.date = input.date.description; row.remainingHalfDays = input.remainingHalfDays
        try await row.create(on: scope.db)
        return try await balance(year: input.date.year)
    }
    func createAdjustment(_ input: VacationAdjustmentInput) async throws -> VacationBalanceDTO {
        try validateReason(input.reason)
        guard (1990...2100).contains(input.date.year), (-10_000...10_000).contains(input.halfDays) else { throw APIError.invalid }
        let row = VacationAdjustmentRecord(); row.id = UUID(); row.accountId = scope.accountId
        row.date = input.date.description; row.halfDays = input.halfDays; row.reason = input.reason; row.createdAt = Date()
        try await row.create(on: scope.db)
        return try await balance(year: input.date.year)
    }
    func entries(year: Int) async throws -> VacationEntriesDTO {
        guard (1990...2100).contains(year) else { throw APIError.invalid }
        let from = String(format: "%04d-01-01", year), to = String(format: "%04d-12-31", year)
        let snapshots = try await VacationSnapshotRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
            .filter(\.$date >= from).filter(\.$date <= to).sort(\.$date).all()
        let adjustments = try await VacationAdjustmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
            .filter(\.$date >= from).filter(\.$date <= to).sort(\.$date).all()
        return .init(snapshots: try snapshots.map { .init(id: try $0.requireID(), date: try LocalDate($0.date), remainingHalfDays: $0.remainingHalfDays) },
                     adjustments: try adjustments.map { .init(id: try $0.requireID(), date: try LocalDate($0.date), halfDays: $0.halfDays, reason: $0.reason) })
    }
    func deleteEntry(_ id: UUID) async throws {
        if let row = try await VacationSnapshotRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$id == id).first() {
            try await row.delete(on: scope.db); return
        }
        if let row = try await VacationAdjustmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$id == id).first() {
            try await row.delete(on: scope.db); return
        }
        throw APIError.missing
    }
}

extension CustomCalendarDayRecord {
    func engine() throws -> CustomCalendarDay {
        guard let kind = CalendarDayKind(rawValue: kind) else { throw APIError.invalid }
        return CustomCalendarDay(id: try requireID(), startDate: try LocalDate(startDate), endDate: try LocalDate(endDate),
                                 name: name, kind: kind, source: .custom)
    }
}
extension AbsenceRecord {
    func engine() throws -> EngineAbsence {
        guard let kind = AbsenceKind(rawValue: kind), let status = AbsenceStatus(rawValue: status) else { throw APIError.invalid }
        return EngineAbsence(id: try requireID(), kind: kind, startDate: try LocalDate(startDate), endDate: try LocalDate(endDate),
                             status: status, halfDayStart: halfDayStart, halfDayEnd: halfDayEnd)
    }
    func dto(counted: Int, attachments: Int) throws -> AbsenceDTO {
        func optional(_ value: String?) throws -> LocalDate? { try value.map { try LocalDate($0) } }
        let engine = try engine()
        return .init(id: engine.id, version: version, kind: engine.kind, startDate: engine.startDate, endDate: engine.endDate,
                     halfDayStart: halfDayStart, halfDayEnd: halfDayEnd, status: engine.status, note: note, documentStatus: documentStatus,
                     documentSubmittedOn: try optional(documentSubmittedOn), documentReferenceStart: try optional(documentReferenceStart),
                     documentReferenceEnd: try optional(documentReferenceEnd), countedHalfDays: counted, attachmentCount: attachments)
    }
}

/// Consumption calculator prepared once per request: models, region and custom days are loaded a single time.
struct AbsenceCounter: Sendable {
    let models: [EngineWorkModel]
    let region: String
    let custom: [CustomCalendarDay]
    var companyDays: [CompanyDayRule] = []
    func count(_ absence: EngineAbsence) throws -> Int {
        guard absence.kind == .vacation, absence.status.isActive else { return 0 }
        let builtin = try (absence.startDate.year...absence.endDate.year).flatMap { try HolidayCalendar.calendar(year: $0, region: region, companyDays: companyDays) }
        // Days outside every work model (e.g. after a training ended) count 0 instead of failing.
        return try VacationEngine.countedHalfDays(for: absence, models: models, calendarDays: builtin + custom, lenient: true)
    }
    /// Read paths never fail; they show 0 on any inconsistency.
    func lenientCount(_ absence: EngineAbsence) -> Int { (try? count(absence)) ?? 0 }
}

struct AbsenceService: Sendable {
    let scope: TimeServices
    func counter() async throws -> AbsenceCounter {
        let settings = try await scope.vacation.settings()
        return .init(models: try await scope.models.list().map { try $0.engine() }, region: settings.region,
                     custom: try await scope.vacation.customDays(), companyDays: settings.companyDays ?? [])
    }
    func record(_ id: UUID) async throws -> AbsenceRecord {
        guard let row = try await AbsenceRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$id == id).first() else { throw APIError.missing }
        return row
    }
    func get(_ id: UUID) async throws -> AbsenceDTO {
        let row = try await record(id)
        return try row.dto(counted: try await counter().lenientCount(row.engine()), attachments: try await attachmentCounts(only: id)[id] ?? 0)
    }
    /// Stored, readable attachments per absence of this account in ONE aggregated query. Links to files that are
    /// being deleted, failed or still pending do not count (same rule as the attachment list); absences without
    /// attachments are missing from the result.
    func attachmentCounts(only absence: UUID? = nil) async throws -> [UUID: Int] {
        let sql = try requireSQL(scope.db)
        let rows = try await sql.raw("""
            SELECT a.absence_id AS absence_id, COUNT(*) AS n FROM absence_attachments a \
            JOIN stored_files f ON f.id = a.file_id AND f.account_id = a.account_id \
            WHERE a.account_id = \(bind: scope.accountId) AND f.state = \(bind: FileState.stored.rawValue) GROUP BY a.absence_id
            """).all()
        var counts: [UUID: Int] = [:]
        for row in rows {
            guard let id = try? row.decode(column: "absence_id", as: UUID.self), let n = try? row.decode(column: "n", as: Int.self) else { continue }
            if absence == nil || absence == id { counts[id] = n }
        }
        return counts
    }
    func list(from: LocalDate, to: LocalDate, hasAttachment: Bool? = nil) async throws -> [AbsenceDTO] {
        try LocalDate.checkedRange(from: from, to: to, maxDays: PlanningLimits.planningRangeDays)
        let rows = try await AbsenceRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
            .filter(\.$startDate <= to.description).filter(\.$endDate >= from.description).sort(\.$startDate).all()
        let counter = try await counter()
        let attachments = try await attachmentCounts()
        return try rows.compactMap { row -> AbsenceDTO? in
            let n = try attachments[row.requireID()] ?? 0
            if let hasAttachment, (n > 0) != hasAttachment { return nil }
            return try row.dto(counted: counter.lenientCount(row.engine()), attachments: n)
        }
    }
    private func validate(_ input: AbsenceInputDTO) throws {
        guard input.startDate <= input.endDate, input.startDate.distance(to: input.endDate) < PlanningLimits.absenceDays,
              input.note?.fitsColumn(500) ?? true, ["not_needed", "pending", "submitted"].contains(input.documentStatus ?? "not_needed") else { throw APIError.invalid }
        if let start = input.documentReferenceStart, let end = input.documentReferenceEnd, start > end { throw APIError.invalid }
    }
    private func ensureNoOverlap(_ candidate: EngineAbsence) async throws {
        let others = try await scope.vacation.engineAbsences().filter { $0.id != candidate.id }
        do { try VacationEngine.validateNoOverlap(others + [candidate]) }
        catch VacationEngineError.absenceOverlap { throw APIError(.conflict, "absence_overlap") }
    }
    private func apply(_ input: AbsenceInputDTO, status: AbsenceStatus, to row: AbsenceRecord) {
        row.kind = input.kind.rawValue; row.startDate = input.startDate.description; row.endDate = input.endDate.description
        row.halfDayStart = input.halfDayStart ?? false; row.halfDayEnd = input.halfDayEnd ?? false
        row.status = status.rawValue; row.note = input.note; row.documentStatus = input.documentStatus ?? "not_needed"
        row.documentSubmittedOn = input.documentSubmittedOn?.description
        row.documentReferenceStart = input.documentReferenceStart?.description
        row.documentReferenceEnd = input.documentReferenceEnd?.description
        row.updatedAt = Date()
    }
    func create(_ input: AbsenceInputDTO) async throws -> AbsenceDTO {
        try validate(input)
        let status = try AbsenceSemantics.normalise(kind: input.kind, status: input.status ?? AbsenceSemantics.defaultStatus(for: input.kind))
        let row = AbsenceRecord(); row.id = UUID(); row.accountId = scope.accountId; row.version = 1; row.createdAt = Date()
        apply(input, status: status, to: row)
        let candidate = try row.engine()
        try await ensureNoOverlap(candidate)
        let counted = try await counter().count(candidate)
        try await row.create(on: scope.db)
        return try row.dto(counted: counted, attachments: 0)
    }
    func update(_ id: UUID, _ input: AbsenceInputDTO, version: Int?) async throws -> AbsenceDTO {
        let row = try await record(id)
        guard version == row.version else { throw APIError(.preconditionFailed, "stale_version") }
        try validate(input)
        let status = try AbsenceSemantics.normalise(kind: input.kind, status: input.status ?? AbsenceSemantics.defaultStatus(for: input.kind))
        apply(input, status: status, to: row); row.version += 1
        let candidate = try row.engine()
        try await ensureNoOverlap(candidate)
        let counted = try await counter().count(candidate)
        try await row.update(on: scope.db)
        return try row.dto(counted: counted, attachments: try await attachmentCounts(only: id)[id] ?? 0)
    }
    func delete(_ id: UUID) async throws {
        try await record(id).delete(on: scope.db)
    }
}

struct CalendarService: Sendable {
    let scope: TimeServices
    func holidays(year: Int, region: String?) async throws -> [CalendarDayDTO] {
        guard (1990...2100).contains(year) else { throw APIError.invalid }
        let settings = try await scope.vacation.settings()
        let region = region ?? settings.region
        guard HolidayCalendar.supportedRegions.contains(region) else { throw APIError.invalid }
        let builtin = try HolidayCalendar.calendar(year: year, region: region, companyDays: settings.companyDays ?? [])
        let custom = try await scope.vacation.customDays().filter { $0.startDate.year <= year && $0.endDate.year >= year }
        return (builtin + custom).map { .init(id: $0.id, startDate: $0.startDate, endDate: $0.endDate, name: $0.name, kind: $0.kind, source: $0.source, companyTreatment: $0.companyTreatment) }
            .sorted { $0.startDate == $1.startDate ? $0.name < $1.name : $0.startDate < $1.startDate }
    }
    func createCustom(_ input: CustomDayInput) async throws -> CalendarDayDTO {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.fitsColumn(80), input.startDate <= input.endDate,
              input.startDate.distance(to: input.endDate) < PlanningLimits.absenceDays else { throw APIError.invalid }
        let row = CustomCalendarDayRecord(); row.id = UUID(); row.accountId = scope.accountId; row.kind = input.kind.rawValue
        row.startDate = input.startDate.description; row.endDate = input.endDate.description; row.name = name
        try await row.create(on: scope.db)
        let day = try row.engine()
        return .init(id: day.id, startDate: day.startDate, endDate: day.endDate, name: day.name, kind: day.kind, source: .custom, companyTreatment: nil)
    }
    func deleteCustom(_ id: UUID) async throws {
        guard let row = try await CustomCalendarDayRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$id == id).first() else { throw APIError.missing }
        try await row.delete(on: scope.db)
    }
}

struct PlanService: Sendable {
    let scope: TimeServices
    static let modes = ["office", "home", "customer", "school", "off"]
    func rows(from: LocalDate, to: LocalDate) async throws -> [PlanDayRecord] {
        try LocalDate.checkedRange(from: from, to: to, maxDays: PlanningLimits.planningRangeDays)
        return try await PlanDayRecord.query(on: scope.db).filter(\.$accountId == scope.accountId)
            .filter(\.$date >= from.description).filter(\.$date <= to.description).sort(\.$date).all()
    }
    func list(from: LocalDate, to: LocalDate) async throws -> [PlanDayDTO] {
        try await rows(from: from, to: to).map { try PlanDayDTO($0) }
    }
    /// Normalised planned times of one entry: both or neither of start/end, start < end within the day, break 0...600
    /// only together with times. Mode `off` ignores all times.
    static func normalizedTimes(_ input: PlanDayInput) throws -> (start: String?, end: String?, breakMinutes: Int?) {
        if input.mode == "off" { return (nil, nil, nil) }
        switch (input.plannedStart, input.plannedEnd) {
        case (nil, nil):
            guard input.plannedBreakMinutes == nil else { throw APIError(.badRequest, "plan_break_invalid") }
            return (nil, nil, nil)
        case let (start?, end?):
            guard let from = PlanTimes.minutes(start), let to = PlanTimes.minutes(end), from < to else { throw APIError(.badRequest, "plan_time_invalid") }
            guard (input.plannedBreakMinutes ?? 0) >= 0, (input.plannedBreakMinutes ?? 0) <= PlanTimes.maxBreakMinutes else { throw APIError(.badRequest, "plan_break_invalid") }
            return (start, end, input.plannedBreakMinutes)
        default: throw APIError(.badRequest, "plan_time_invalid")
        }
    }
    private func validate(_ input: PlanDayInput) async throws -> (start: String?, end: String?, breakMinutes: Int?, blocks: [PlanBlock]) {
        guard Self.modes.contains(input.mode), input.note?.fitsColumn(200) ?? true else { throw APIError.invalid }
        var times = input.blocks == nil ? try Self.normalizedTimes(input) : (start: nil, end: nil, breakMinutes: nil)
        let blocks: [PlanBlock]
        if let supplied = input.blocks {
            guard supplied.count <= 32, input.mode != "off" || supplied.isEmpty else { throw APIError(.badRequest, "plan_blocks_invalid") }
            var previousEnd = -1
            var gapMinutes = 0
            for block in supplied {
                guard let start = PlanTimes.minutes(block.start), let end = PlanTimes.minutes(block.end), start < end else {
                    throw APIError(.badRequest, "plan_time_invalid")
                }
                guard ["work", "school", "travel", "office", "home", "customer"].contains(block.kind) else {
                    throw APIError(.badRequest, "plan_kind_invalid")
                }
                guard block.note?.fitsColumn(200) ?? true else { throw APIError(.badRequest, "plan_note_invalid") }
                if start < previousEnd { throw APIError(.badRequest, "plan_blocks_overlap") }
                if previousEnd >= 0 { gapMinutes += start - previousEnd }
                previousEnd = end
                if let place = block.placeId {
                    let row = try await scope.places.record(place)
                    guard row.payload.archived != true else { throw APIError.missing }
                }
            }
            blocks = supplied
            times = (supplied.first?.start, supplied.last?.end, supplied.isEmpty ? nil : gapMinutes)
        } else {
            blocks = PlanTimes.legacyBlocks(start: times.start, end: times.end, breakMinutes: times.breakMinutes,
                                            kind: input.mode, placeId: input.placeId, note: input.note)
        }
        if let place = input.placeId {
            // Archived places are treated like foreign ones.
            let row = try await scope.places.record(place)
            guard row.payload.archived != true else { throw APIError.missing }
        }
        return (times.start, times.end, times.breakMinutes, blocks)
    }
    private func assign(_ row: PlanDayRecord, date: LocalDate, input: PlanDayInput, times: (start: String?, end: String?, breakMinutes: Int?, blocks: [PlanBlock])) {
        row.accountId = scope.accountId; row.date = date.description; row.mode = input.mode; row.placeId = input.placeId; row.note = input.note
        row.plannedStart = times.start; row.plannedEnd = times.end; row.plannedBreakMinutes = times.breakMinutes
        row.blocks = times.blocks
    }
    func put(_ date: LocalDate, _ input: PlanDayInput) async throws -> PlanDayDTO {
        let times = try await validate(input)
        let row = try await PlanDayRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$date == date.description).first() ?? PlanDayRecord()
        assign(row, date: date, input: input, times: times)
        try await row.save(on: scope.db)
        return try PlanDayDTO(row)
    }
    /// Stores up to seven entries of one ISO week in the surrounding unit of work (all or nothing).
    func putWeek(_ week: ISOWeek, _ input: PlanWeekInput) async throws -> PlanWeekDTO {
        guard input.days.count <= 7 else { throw APIError(.badRequest, "week_day_invalid") }
        let dates = input.days.map(\.date)
        guard Set(dates).count == dates.count, dates.allSatisfy({ $0 >= week.monday && $0 <= week.sunday }) else { throw APIError(.badRequest, "week_day_invalid") }
        var validated: [(PlanWeekDayInput, (start: String?, end: String?, breakMinutes: Int?, blocks: [PlanBlock]))] = []
        for entry in input.days { validated.append((entry, try await validate(entry.day))) }
        let existing = Dictionary(try await rows(from: week.monday, to: week.sunday).map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        if input.replace == true {
            let kept = Set(dates.map(\.description))
            for (date, row) in existing where !kept.contains(date) { try await row.delete(on: scope.db) }
        }
        for (entry, times) in validated {
            let row = existing[entry.date.description] ?? PlanDayRecord()
            assign(row, date: entry.date, input: entry.day, times: times)
            try await row.save(on: scope.db)
        }
        return try await self.week(week)
    }
    /// The seven days with plan, rule-derived target (work model, holidays, absences; no actuals) and totals.
    func week(_ week: ISOWeek) async throws -> PlanWeekDTO {
        let plans = Dictionary(try await rows(from: week.monday, to: week.sunday).map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let prepared = try await scope.days.snapshot(window: week.monday...week.sunday, includeSegments: false).prepared()
        let now = Date()
        var days: [PlanWeekDayDTO] = []
        for date in week.dates {
            let evaluation = try prepared.evaluate(date, now: now)
            let plan = try plans[date.description].map { try PlanDayDTO($0) }
            let halfDay = evaluation.mark == .vacation && evaluation.targetOverrideSeconds != nil
            let blocked = [DayMarkKind.holiday, .vacation, .sick, .excused].contains(evaluation.mark) && !halfDay ? evaluation.mark.rawValue : nil
            days.append(.init(date: date, weekday: date.isoWeekday, targetSeconds: evaluation.targetSeconds,
                              plannedSeconds: blocked != nil && plan != nil ? 0 : plan?.plannedSeconds, blockedBy: blocked, plan: plan))
        }
        let target = days.reduce(0) { $0 + $1.targetSeconds }, planned = days.reduce(0) { $0 + ($1.plannedSeconds ?? 0) }
        return .init(week: week.label, from: week.monday, to: week.sunday, days: days,
                     totals: .init(targetSeconds: target, plannedSeconds: planned, differenceSeconds: planned - target))
    }
    func delete(_ date: LocalDate) async throws {
        try await PlanDayRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$date == date.description).delete()
    }
}

struct ShareService: Sendable {
    let scope: TimeServices
    private func dto(_ row: ShareRecord) async throws -> ShareDTO {
        let handle = try await Account.find(row.recipientId, on: scope.db)?.handle ?? ""
        return .init(id: try row.requireID(), recipientHandle: handle, scopes: row.scopes, createdAt: row.createdAt)
    }
    private func owned(_ id: UUID) async throws -> ShareRecord {
        guard let row = try await ShareRecord.query(on: scope.db).filter(\.$id == id).filter(\.$ownerId == scope.accountId)
            .filter(\.$revokedAt == nil).first() else { throw APIError.missing }
        return row
    }
    func list() async throws -> [ShareDTO] {
        let rows = try await ShareRecord.query(on: scope.db).filter(\.$ownerId == scope.accountId).filter(\.$revokedAt == nil).sort(\.$createdAt).all()
        var result: [ShareDTO] = []; for row in rows { result.append(try await dto(row)) }; return result
    }
    func create(_ input: ShareCreateInput) async throws -> ShareDTO {
        let handle = input.recipientHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let recipient = try await Account.query(on: scope.db).filter(\.$handle == handle).filter(\.$disabledAt == nil).first() else {
            throw APIError(.notFound, "recipient_not_found")
        }
        let recipientId = try recipient.requireID()
        guard recipientId != scope.accountId else { throw APIError(.badRequest, "cannot_share_with_self") }
        guard try await ShareRecord.query(on: scope.db).filter(\.$ownerId == scope.accountId).filter(\.$recipientId == recipientId)
            .filter(\.$revokedAt == nil).first() == nil else { throw APIError(.conflict, "share_exists") }
        let row = ShareRecord(); row.id = UUID(); row.ownerId = scope.accountId; row.recipientId = recipientId
        row.scopePlan = input.scopes.plan; row.scopeActual = input.scopes.actual; row.scopeVacation = input.scopes.vacation
        row.createdAt = Date(); row.active = 1
        try await row.create(on: scope.db)
        return try await dto(row)
    }
    func update(_ id: UUID, scopes: ShareScopesDTO) async throws -> ShareDTO {
        let row = try await owned(id)
        row.scopePlan = scopes.plan; row.scopeActual = scopes.actual; row.scopeVacation = scopes.vacation
        try await row.update(on: scope.db)
        return try await dto(row)
    }
    func revoke(_ id: UUID) async throws {
        let row = try await owned(id)
        row.revokedAt = Date(); row.active = nil
        try await row.update(on: scope.db)
    }
    func incoming() async throws -> [IncomingShareDTO] {
        guard try await scope.modules.enabled(.planning, account: scope.accountId, on: scope.db) else { return [] }
        let rows = try await ShareRecord.query(on: scope.db).filter(\.$recipientId == scope.accountId).filter(\.$revokedAt == nil).sort(\.$createdAt).all()
        var result: [IncomingShareDTO] = []
        for row in rows {
            guard let owner = try await Account.find(row.ownerId, on: scope.db), owner.disabledAt == nil else { continue }
            guard try await scope.modules.enabled(.planning, account: row.ownerId, on: scope.db) else { continue }
            result.append(.init(id: try row.requireID(), ownerDisplayName: owner.displayName, scopes: row.scopes))
        }
        return result
    }
    /// The recipient view is assembled from scratch per scope and only copies whitelisted fields.
    func view(_ id: UUID, from: LocalDate, to: LocalDate) async throws -> SharedViewDTO {
        guard let share = try await ShareRecord.query(on: scope.db).filter(\.$id == id).filter(\.$recipientId == scope.accountId)
            .filter(\.$revokedAt == nil).first(), let owner = try await Account.find(share.ownerId, on: scope.db), owner.disabledAt == nil else {
            throw APIError.missing
        }
        try LocalDate.checkedRange(from: from, to: to, maxDays: PlanningLimits.planningRangeDays)
        try await scope.modules.require([.planning], account: scope.accountId, on: scope.db)
        try await scope.modules.require([.planning], account: share.ownerId, on: scope.db)
        let ownerScope = TimeServices(accountId: share.ownerId, db: scope.db, disabledModules: scope.disabledModules)
        var view = SharedViewDTO()
        if share.scopePlan {
            view.plan = try await ownerScope.plans.rows(from: from, to: to).map { row in
                let sharedBlocks = row.blocks?.isEmpty == false
                    ? row.blocks?.map { PlanBlock(start: $0.start, end: $0.end, kind: $0.kind, placeId: nil, note: nil) }
                    : nil
                return .init(date: try LocalDate(row.date), mode: row.mode, plannedStart: row.plannedStart, plannedEnd: row.plannedEnd,
                      plannedBreakMinutes: row.plannedBreakMinutes,
                      plannedSeconds: try PlanDayDTO(row).plannedSeconds,
                      blocks: sharedBlocks)
            }
        }
        if share.scopeActual {
            view.actual = try await ownerScope.days.range(from: from, to: to, limit: PlanningLimits.planningRangeDays)
                .filter { $0.evaluatedWorkSeconds > 0 }
                .map { .init(date: $0.date, evaluatedStart: $0.evaluatedStart, evaluatedEnd: $0.evaluatedEnd, evaluatedWorkSeconds: $0.evaluatedWorkSeconds) }
        }
        if share.scopeVacation {
            view.vacation = try await ownerScope.vacation.engineAbsences()
                .filter { $0.kind == .vacation && $0.status.isBooked && $0.startDate <= to && $0.endDate >= from }
                .map { .init(startDate: max($0.startDate, from), endDate: min($0.endDate, to)) }
        }
        return view
    }
}
