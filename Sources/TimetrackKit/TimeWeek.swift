import Foundation
import Fluent

/// GET /time/weeks/{isoWeek}: the data of the week overview in one call (ADR-0021). Everything is derived from the
/// day evaluation (`PreparedEvaluation`); nothing here invents semantics. Days after today carry no balance.
struct TimeWeekDayDTO: Encodable, Sendable {
    struct Absence: Encodable, Sendable { var kind: AbsenceKind; var status: AbsenceStatus; var halfDay: Bool }
    var date: LocalDate; var weekday: Int
    /// work, school, vacation, sick, holiday, excused or off (no workday and nothing booked).
    var mark: String
    var markSource: DayMarkSource
    var targetSeconds: Int
    var plannedSeconds: Int?
    var planMode: String?
    var planBlocks: [PlanBlock]?
    var planHints: [String]
    var planActualDifferenceSeconds: Int?
    var workSeconds: Int; var creditSeconds: Int; var rawWorkSeconds: Int
    /// Real gaps between the day's segments; no pauses are invented.
    var breakSeconds: Int
    /// Fixed breaks of the work model deducted from the work time.
    var breakDeductionSeconds: Int
    var travelSeconds: Int; var schoolSeconds: Int
    /// work + credit - target; nil for days after today.
    var balanceSeconds: Int?
    var firstStart: Date?; var lastEnd: Date?
    var segmentsCount: Int
    var absences: [Absence]
    var legalProfileId: String
    var breakHints: [BreakHint]
    var legalWarnings: [LegalWarning]
    var schoolLessonCount: Int?
    /// Name of a public holiday (built-in region table or custom holiday) on this date, independent of the work model:
    /// it is also set on weekends and days outside every model, where `mark` stays `off`. nil without planning.
    var holidayName: String?
    /// N4 (ADR-0029): `half` or `full` when `holidayName` stems from a configured company day (24.12./31.12.), else nil.
    /// `full` behaves like a public holiday (`mark` holiday on workdays); `half` keeps `mark` work with a halved `targetSeconds`.
    var companyDayTreatment: CompanyDayTreatment?
    var provisional: Bool; var isToday: Bool; var isFuture: Bool
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date); try c.encode(weekday, forKey: .weekday); try c.encode(mark, forKey: .mark)
        try c.encode(markSource, forKey: .markSource); try c.encode(targetSeconds, forKey: .targetSeconds)
        try c.encode(plannedSeconds, forKey: .plannedSeconds); try c.encode(planMode, forKey: .planMode)
        try c.encode(planBlocks, forKey: .planBlocks); try c.encode(planHints, forKey: .planHints)
        try c.encode(planActualDifferenceSeconds, forKey: .planActualDifferenceSeconds)
        try c.encode(workSeconds, forKey: .workSeconds); try c.encode(creditSeconds, forKey: .creditSeconds)
        try c.encode(rawWorkSeconds, forKey: .rawWorkSeconds); try c.encode(breakSeconds, forKey: .breakSeconds)
        try c.encode(breakDeductionSeconds, forKey: .breakDeductionSeconds)
        try c.encode(travelSeconds, forKey: .travelSeconds); try c.encode(schoolSeconds, forKey: .schoolSeconds)
        try c.encode(balanceSeconds, forKey: .balanceSeconds); try c.encode(firstStart, forKey: .firstStart)
        try c.encode(lastEnd, forKey: .lastEnd); try c.encode(segmentsCount, forKey: .segmentsCount)
        try c.encode(absences, forKey: .absences); try c.encode(provisional, forKey: .provisional)
        try c.encode(isToday, forKey: .isToday); try c.encode(isFuture, forKey: .isFuture)
        try c.encode(legalProfileId, forKey: .legalProfileId)
        try c.encode(breakHints, forKey: .breakHints); try c.encode(legalWarnings, forKey: .legalWarnings)
        try c.encode(schoolLessonCount, forKey: .schoolLessonCount)
        try c.encode(holidayName, forKey: .holidayName); try c.encode(companyDayTreatment, forKey: .companyDayTreatment)
    }
    enum CodingKeys: String, CodingKey {
        case date, weekday, mark, markSource, targetSeconds, plannedSeconds, planMode, planBlocks, planHints, planActualDifferenceSeconds, workSeconds, creditSeconds, rawWorkSeconds
        case breakSeconds, breakDeductionSeconds, travelSeconds, schoolSeconds, balanceSeconds, firstStart, lastEnd
        case segmentsCount, absences, provisional, isToday, isFuture, legalProfileId, breakHints, legalWarnings, schoolLessonCount, holidayName, companyDayTreatment
    }
}

struct TimeWeekDTO: Encodable, Sendable {
    struct LongestDay: Encodable, Sendable { var date: LocalDate; var seconds: Int }
    struct Summary: Encodable, Sendable {
        var targetSeconds: Int
        /// Target of the completed days, i.e. up to and including yesterday (the whole target for a past week, 0 for a future
        /// week). The running current day is not included (C3, ADR-0032); see `todayDeltaSeconds`.
        var targetToDateSeconds: Int
        var workSeconds: Int; var creditSeconds: Int
        /// Sum of the day balances of the completed days (through yesterday); the current day is reported in `todayDeltaSeconds`.
        var balanceSeconds: Int
        /// Always false: today's Soll and Ist are in neither `balanceSeconds`, `targetToDateSeconds` nor the account balances.
        var includesToday = false
        /// Balance of the running current day (Ist + credit - Soll); nil when the week does not contain today.
        var todayDeltaSeconds: Int?
        var plannedSeconds: Int?
        var accountBalanceBeforeSeconds: Int; var accountBalanceAfterSeconds: Int; var accountBalanceAsOf: LocalDate
        /// Half-day vacation counts 0.5.
        var vacationDays: Double
        var sickDays: Int; var schoolDays: Int; var holidayDays: Int; var workDays: Int
        var travelSeconds: Int; var breakSeconds: Int
        var averageStart: String?; var averageEnd: String?
        var longestDay: LongestDay?
        var provisional: Bool
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(targetSeconds, forKey: .targetSeconds); try c.encode(targetToDateSeconds, forKey: .targetToDateSeconds)
            try c.encode(workSeconds, forKey: .workSeconds); try c.encode(creditSeconds, forKey: .creditSeconds)
            try c.encode(balanceSeconds, forKey: .balanceSeconds); try c.encode(plannedSeconds, forKey: .plannedSeconds)
            try c.encode(includesToday, forKey: .includesToday); try c.encode(todayDeltaSeconds, forKey: .todayDeltaSeconds)
            try c.encode(accountBalanceBeforeSeconds, forKey: .accountBalanceBeforeSeconds)
            try c.encode(accountBalanceAfterSeconds, forKey: .accountBalanceAfterSeconds); try c.encode(accountBalanceAsOf, forKey: .accountBalanceAsOf)
            try c.encode(vacationDays, forKey: .vacationDays); try c.encode(sickDays, forKey: .sickDays)
            try c.encode(schoolDays, forKey: .schoolDays); try c.encode(holidayDays, forKey: .holidayDays)
            try c.encode(workDays, forKey: .workDays); try c.encode(travelSeconds, forKey: .travelSeconds)
            try c.encode(breakSeconds, forKey: .breakSeconds); try c.encode(averageStart, forKey: .averageStart)
            try c.encode(averageEnd, forKey: .averageEnd); try c.encode(longestDay, forKey: .longestDay)
            try c.encode(provisional, forKey: .provisional)
        }
        enum CodingKeys: String, CodingKey {
            case targetSeconds, targetToDateSeconds, workSeconds, creditSeconds, balanceSeconds, plannedSeconds
            case accountBalanceBeforeSeconds, accountBalanceAfterSeconds, accountBalanceAsOf, vacationDays, sickDays, schoolDays
            case holidayDays, workDays, travelSeconds, breakSeconds, averageStart, averageEnd, longestDay, provisional
            case includesToday, todayDeltaSeconds
        }
    }
    var week: String; var from: LocalDate; var to: LocalDate
    var days: [TimeWeekDayDTO]; var summary: Summary
}

struct TimeWeekService: Sendable {
    let scope: TimeServices

    func week(_ week: ISOWeek, now: Date = Date()) async throws -> TimeWeekDTO {
        // W4: one windowed snapshot (the balance days after the last month-end checkpoint plus the week) serves the seven
        // days and both account balances; the balance before that window comes from a cached checkpoint.
        let inputs = try await scope.account.balanceInputs(anchor: week.monday, through: week.sunday,
                                                           also: week.monday...week.sunday, now: now)
        return try await compose(week, inputs: inputs, now: now)
    }

    /// The week over already loaded inputs; the equivalence tests feed it the complete history without a carry as the oracle.
    func compose(_ week: ISOWeek, inputs: BalanceInputs, now: Date) async throws -> TimeWeekDTO {
        let snapshot = inputs.snapshot, adjustments = inputs.adjustments
        let plans = snapshot.planningEnabled
            ? Dictionary(try await scope.plans.rows(from: week.monday, to: week.sunday).map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
            : [:]
        let prepared = snapshot.prepared()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: snapshot.models.last?.timezone ?? "Europe/Berlin")!
        let today = LocalDate.local(now, calendar: calendar)
        var days: [TimeWeekDayDTO] = []
        for date in week.dates {
            let day = try prepared.evaluate(date, now: now)
            let model = snapshot.models.first { $0.validFrom <= date && ($0.validTo.map { date <= $0 } ?? true) }
            days.append(dto(day, model: model, absences: snapshot.absences, plan: plans[date.description], today: today, now: now,
                            holidayName: prepared.holidayName(on: date), companyDayTreatment: prepared.companyDayTreatment(on: date)))
        }
        let accountService = scope.account
        let before = try accountService.balance(snapshot: snapshot, adjustments: adjustments, asOf: week.monday.addingDays(-1), now: now, carry: inputs.carry)
        let after = try accountService.balance(snapshot: snapshot, adjustments: adjustments, asOf: week.sunday, now: now, carry: inputs.carry)
        return .init(week: week.label, from: week.monday, to: week.sunday, days: days,
                     summary: summary(days, before: before, after: after, calendar: calendar))
    }

    func dto(_ day: DayEvaluationResult, model: EngineWorkModel?, absences: [EngineAbsence], plan: PlanDayRecord?,
                     today: LocalDate, now: Date, holidayName: String? = nil,
                     companyDayTreatment: CompanyDayTreatment? = nil) -> TimeWeekDayDTO {
        var travel = 0, school = 0, gaps = 0
        var previousEnd: Date?
        for segment in day.segments {
            let end = segment.endedAt ?? now
            let length = max(0, Int(end.timeIntervalSince(segment.startedAt)))
            if segment.kind == .travel { travel += length } else if segment.kind == .school { school += length }
            if let previousEnd, segment.startedAt > previousEnd { gaps += Int(segment.startedAt.timeIntervalSince(previousEnd)) }
            previousEnd = max(previousEnd ?? end, end)
        }
        let isWorkday = model?.workdays.contains(day.date.isoWeekday) ?? false
        let hasWork = day.rawWorkSeconds > 0 || day.evaluatedWorkSeconds > 0
        let mark: String
        switch day.mark {
        case .holiday, .vacation, .sick, .excused:
            // Absence marks on a non-workday (weekend) are no consumed day.
            mark = isWorkday || hasWork ? day.mark.rawValue : "off"
        case .schoolCredit: mark = "school"
        case .none:
            if school > 0 && day.evaluatedWorkSeconds == 0 && day.creditSeconds > 0 { mark = "school" }
            else if hasWork || school > 0 || isWorkday { mark = "work" }
            else { mark = "off" }
        }
        let isFuture = day.date > today
        let blocked = [DayMarkKind.holiday, .vacation, .sick, .excused].contains(day.mark)
            && !(day.mark == .vacation && day.targetOverrideSeconds != nil)
        let planned = plan.flatMap { PlanTimes.blockSeconds($0.blocks ?? []) ?? PlanTimes.seconds(start: $0.plannedStart, end: $0.plannedEnd, breakMinutes: $0.plannedBreakMinutes) }
        let effectivePlanned = blocked ? (plan == nil ? nil : 0) : planned
        let dayAbsences = absences.filter { $0.contains(day.date) && $0.status.isActive }
            .map { TimeWeekDayDTO.Absence(kind: $0.kind, status: $0.status, halfDay: $0.isHalfDay(day.date)) }
        return .init(date: day.date, weekday: day.date.isoWeekday, mark: mark, markSource: day.markSource, targetSeconds: day.targetSeconds,
                     plannedSeconds: effectivePlanned, planMode: plan?.mode, planBlocks: plan?.blocks,
                     planHints: PlanTimes.hints(plan?.blocks ?? []),
                     planActualDifferenceSeconds: isFuture || blocked ? nil : effectivePlanned.map { day.evaluatedWorkSeconds + day.creditSeconds - $0 },
                     workSeconds: day.evaluatedWorkSeconds, creditSeconds: day.creditSeconds, rawWorkSeconds: day.rawWorkSeconds,
                     breakSeconds: gaps, breakDeductionSeconds: day.breakDeductionSeconds, travelSeconds: travel, schoolSeconds: school,
                     balanceSeconds: isFuture ? nil : day.deltaSeconds, firstStart: day.evaluatedStart, lastEnd: day.evaluatedEnd,
                     segmentsCount: day.segments.count, absences: dayAbsences, legalProfileId: day.legalProfileId,
                     breakHints: day.breakHints, legalWarnings: day.legalWarnings, schoolLessonCount: day.schoolLessonCount, holidayName: holidayName,
                     companyDayTreatment: companyDayTreatment,
                     provisional: day.provisional,
                     isToday: day.date == today, isFuture: isFuture)
    }

    private func summary(_ days: [TimeWeekDayDTO], before: TimeAccountResult, after: TimeAccountResult, calendar: Calendar) -> TimeWeekDTO.Summary {
        func minutes(_ date: Date) -> Int { calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date) }
        func clock(_ values: [Int]) -> String? {
            guard !values.isEmpty else { return nil }
            let mean = Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
            return String(format: "%02d:%02d", mean / 60, mean % 60)
        }
        let worked = days.filter { $0.workSeconds > 0 }
        let longest = worked.max { $0.workSeconds == $1.workSeconds ? $0.date > $1.date : $0.workSeconds < $1.workSeconds }
        let hasPlan = days.contains { $0.plannedSeconds != nil }
        let vacation = days.filter { $0.mark == "vacation" }.reduce(0.0) { total, day in
            total + (day.absences.contains { $0.kind == .vacation && $0.halfDay } ? 0.5 : 1)
        }
        return .init(targetSeconds: days.reduce(0) { $0 + $1.targetSeconds },
                     targetToDateSeconds: days.filter { !$0.isFuture && !$0.isToday }.reduce(0) { $0 + $1.targetSeconds },
                     workSeconds: days.reduce(0) { $0 + $1.workSeconds }, creditSeconds: days.reduce(0) { $0 + $1.creditSeconds },
                     balanceSeconds: days.filter { !$0.isToday }.reduce(0) { $0 + ($1.balanceSeconds ?? 0) },
                     todayDeltaSeconds: days.first { $0.isToday }?.balanceSeconds,
                     plannedSeconds: hasPlan ? days.reduce(0) { $0 + ($1.plannedSeconds ?? 0) } : nil,
                     accountBalanceBeforeSeconds: before.balanceSeconds, accountBalanceAfterSeconds: after.balanceSeconds, accountBalanceAsOf: after.asOf,
                     vacationDays: vacation, sickDays: days.filter { $0.mark == "sick" }.count,
                     schoolDays: days.filter { $0.mark == "school" }.count, holidayDays: days.filter { $0.mark == "holiday" }.count,
                     workDays: worked.count, travelSeconds: days.reduce(0) { $0 + $1.travelSeconds },
                     breakSeconds: days.reduce(0) { $0 + $1.breakSeconds },
                     averageStart: clock(days.compactMap { $0.firstStart.map(minutes) }), averageEnd: clock(days.compactMap { $0.lastEnd.map(minutes) }),
                     longestDay: longest.map { .init(date: $0.date, seconds: $0.workSeconds) }, provisional: days.contains { $0.provisional })
    }
}
