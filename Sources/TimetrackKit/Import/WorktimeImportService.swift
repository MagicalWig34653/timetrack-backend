import Foundation
import Fluent

struct WorktimeAbsence: Sendable {
    var rows: [Int]
    var kind: AbsenceKind
    var from: LocalDate
    var to: LocalDate
    var status: AbsenceStatus
    var remarks: [String]
    var note: String? { let text = remarks.filter { !$0.isEmpty }.joined(separator: "\n"); return text.isEmpty ? nil : text }
}
struct WorktimeHoliday: Sendable { var row: Int; var date: LocalDate; var name: String }

extension ImportService {
    func evaluateWorktime(_ workbook: ImportWorkbook, mapping: ImportMapping) async throws -> ImportEvaluation {
        let options = mapping.worktime ?? WorktimeOptions()
        let parsed = try WorktimeWorkbook.parse(workbook, options: options)
        let rules = options.effectiveRules
        let planning = try await scope.modules.enabled(.planning, account: scope.accountId, on: scope.db)
        let models = try await scope.models.list().map { try $0.engine() }
        let region = try await scope.vacation.settings().region
        let existingAbsences = try await AbsenceRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).all()
        let activeAbsences = try existingAbsences.filter { try $0.engine().status.isActive }
        let existingDays = try await CustomCalendarDayRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).all()
        let existingSegments = try await SegmentRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$voidedAt == nil).all()
        let custom = try existingDays.map { try $0.engine() }
        let builtin = Set(parsed.days.map { $0.date.year }).flatMap { (try? HolidayCalendar.holidays(year: $0, region: region)) ?? [] }
        let actions = parsed.days.map { day in (day, rules.first { $0.matches(day.remark) }?.action ?? .work) }
        let importedHolidays = actions.filter { $0.1 == .holiday }.map { $0.0.date }
        func holiday(_ date: LocalDate) -> Bool {
            HolidayCalendar.isHoliday(date, days: builtin + custom) || importedHolidays.contains(date)
        }
        func working(_ date: LocalDate) throws -> Bool {
            let model = try TimeEngine.selectModel(for: date, models: models)
            return (model?.workdays ?? [1, 2, 3, 4, 5]).contains(HolidayCalendar.weekday(date)) && !holiday(date)
        }
        func segmentOverlaps(_ from: LocalDate, _ to: LocalDate) -> Bool {
            guard let start = ImportInterpreter.instant(from, seconds: 0, zone: mapping.zone),
                  let end = ImportInterpreter.instant(to.addingDays(1), seconds: 0, zone: mapping.zone) else { return true }
            return existingSegments.contains { $0.startedAt < end && ($0.endedAt ?? .distantFuture) > start }
        }
        var errors = parsed.errors, warnings: [ImportWarning] = [], duplicates = 0
        var warningCounts: [String: Int] = [:]
        var segments: [ImportCandidate] = [], absences: [WorktimeAbsence] = [], days: [WorktimeHoliday] = []
        var preview = WorktimePreview(dateSystem: parsed.date1904 ? "1904" : "1900", sheetBalanceSeconds: parsed.balance)
        preview.days = parsed.days.count; preview.firstDate = parsed.days.first?.date.description; preview.lastDate = parsed.days.last?.date.description
        var unmapped: [String: Int] = [:]
        let today = LocalDate.local(now(), calendar: { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = mapping.zone; return calendar }())
        if !parsed.balanceRows.isEmpty {
            preview.sheetBalanceUpToTodaySeconds = Int(parsed.balanceRows.filter { $0.date <= today }.reduce(0.0) { $0 + $1.seconds }.rounded())
            preview.sheetBalanceFutureSeconds = Int(parsed.balanceRows.filter { $0.date > today }.reduce(0.0) { $0 + $1.seconds }.rounded())
        }
        preview.firstContentDate = parsed.firstContentDate?.description
        let effectiveActions = try Dictionary(uniqueKeysWithValues: actions.map { day, action -> (LocalDate, WorktimeAction) in
            guard action.isAbsence, options.partialCredit != "absence", let start = day.start, let end = day.end else { return (day.date, action) }
            let target = try TimeEngine.selectModel(for: day.date, models: models).map { TimeEngine.target(for: day.date, model: $0) } ?? parsed.dailyTargetSeconds
            let effectivePause = options.pauseMode == "none" || end - start <= day.pause ? 0 : day.pause
            guard let target, abs(end - start - effectivePause - target) > 300 else { return (day.date, action) }
            return (day.date, .work)
        })
        for (day, action) in actions {
            preview.byAction[action.rawValue, default: 0] += 1
            if !day.remark.isEmpty && !rules.contains(where: { $0.matches(day.remark) }) { unmapped[day.remark, default: 0] += 1 }
            let effectiveAction = effectiveActions[day.date] ?? action
            if (effectiveAction.isAbsence || effectiveAction == .holiday) && !planning {
                errors.append(.init(row: day.row, code: "planning_disabled")); continue
            }
            if effectiveAction == .work && action.isAbsence { warningCounts["credit_partial_as_work", default: 0] += 1 }
            if (action == .work || action == .school), day.start != nil, day.end != nil,
               options.holidayTimes != "keep", holiday(day.date) {
                warningCounts[effectiveAction == .school ? "school_on_holiday" : "holiday_times_discarded", default: 0] += 1
                continue
            }
            if effectiveAction.isAbsence {
                let status: AbsenceStatus = day.date < today ? .taken : .approved
                let kind = AbsenceKind(rawValue: effectiveAction.rawValue)!
                var merge = false
                if let previous = absences.last, previous.kind == kind,
                   previous.from.distance(to: day.date) < PlanningLimits.absenceDays {
                    var cursor = previous.to.addingDays(1); merge = true
                    while cursor < day.date {
                        if try working(cursor) { merge = false; break }
                        // An explicit, different action is never swallowed by a range.
                        if let intervening = effectiveActions[cursor], intervening != effectiveAction && intervening != .holiday && intervening != .skip { merge = false; break }
                        cursor = cursor.addingDays(1)
                    }
                }
                if merge {
                    absences[absences.count - 1].to = day.date; absences[absences.count - 1].status = status
                    absences[absences.count - 1].rows.append(day.row)
                    if !absences[absences.count - 1].remarks.contains(day.remark) { absences[absences.count - 1].remarks.append(day.remark) }
                } else { absences.append(.init(rows: [day.row], kind: kind, from: day.date, to: day.date, status: status, remarks: [day.remark])) }
            } else if effectiveAction == .holiday {
                if HolidayCalendar.isHoliday(day.date, days: builtin) { preview.skippedHolidays += 1; continue }
                let trimmed = day.remark.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = trimmed.isEmpty ? "Feiertag" : trimmed
                if existingDays.contains(where: { $0.kind == "holiday" && $0.startDate == day.date.description && $0.endDate == day.date.description && $0.name == name }) { duplicates += 1; continue }
                if !name.fitsColumn(80) { errors.append(.init(row: day.row, code: "note_too_long")); continue }
                if existingDays.contains(where: { $0.kind == "holiday" && $0.startDate <= day.date.description && $0.endDate >= day.date.description }) || segmentOverlaps(day.date, day.date)
                    || activeAbsences.contains(where: { $0.startDate <= day.date.description && $0.endDate >= day.date.description }) {
                    errors.append(.init(row: day.row, code: "overlap")); continue
                }
                days.append(.init(row: day.row, date: day.date, name: name))
            } else if effectiveAction != .skip {
                do {
                    let (candidates, warning) = try WorktimeWorkbook.segments(day, action: effectiveAction, mapping: mapping)
                    if warning { warnings.append(.init(code: "pause_exceeds_day", row: day.row)) }
                    if activeAbsences.contains(where: { $0.startDate <= day.date.description && $0.endDate >= day.date.description }) {
                        errors.append(.init(row: day.row, code: "overlap")); continue
                    }
                    let fresh = candidates.filter { candidate in
                        !existingSegments.contains { $0.startedAt == candidate.start && $0.endedAt == candidate.end && $0.kind == candidate.kind.rawValue && $0.note == candidate.note && $0.placeId == nil }
                    }
                    if fresh.contains(where: { candidate in existingSegments.contains { $0.startedAt < candidate.end && ($0.endedAt ?? .distantFuture) > candidate.start } }) {
                        errors.append(.init(row: day.row, code: "overlap")); continue
                    }
                    duplicates += candidates.count - fresh.count; segments += fresh
                } catch { errors.append(.init(row: day.row, code: (error as? APIError)?.code ?? "time_invalid")) }
            }
        }
        var acceptedAbsences: [WorktimeAbsence] = []
        for absence in absences {
            if !(absence.note?.fitsColumn(500) ?? true) { errors += absence.rows.map { .init(row: $0, code: "note_too_long") }; continue }
            if activeAbsences.contains(where: { $0.kind == absence.kind.rawValue && $0.startDate == absence.from.description && $0.endDate == absence.to.description && !$0.halfDayStart && !$0.halfDayEnd && $0.note == absence.note && ["approved", "taken"].contains($0.status) }) { duplicates += 1; continue }
            if activeAbsences.contains(where: { $0.startDate <= absence.to.description && $0.endDate >= absence.from.description }) || segmentOverlaps(absence.from, absence.to) {
                errors += absence.rows.map { .init(row: $0, code: "overlap") }; continue
            }
            acceptedAbsences.append(absence)
        }
        preview.segments = segments.count; preview.absences = acceptedAbsences.count; preview.customDays = days.count
        warnings += warningCounts.sorted { $0.key < $1.key }.map { ImportWarning(code: $0.key, count: $0.value) }
        preview.unmappedRemarks = unmapped.sorted { $0.key < $1.key }.map { .init(text: $0.key, count: $0.value) }
        let samples = segments.prefix(10).map { ImportSample(date: $0.date.description, startedAt: $0.start, endedAt: $0.end, kind: $0.kind) }
        let result = ImportPreviewDTO(profile: "worktime_workbook", worktime: preview, warnings: warnings,
            rows: parsed.days.count + parsed.errors.count, valid: segments.count + acceptedAbsences.count + days.count,
            duplicates: duplicates, errors: Array(errors.prefix(ImportLimits.maxErrorsListed)), sample: samples,
            skippedSummaryRows: 0, errorCount: errors.count)
        return .init(preview: result, accepted: segments, duplicates: duplicates, errorRows: errors.count,
                     absences: acceptedAbsences, customDays: days)
    }

    func createWorktimeItems(_ evaluation: ImportEvaluation, batch: UUID) async throws {
        for item in evaluation.absences {
            let dto = try await scope.absences.create(.init(kind: item.kind, startDate: item.from, endDate: item.to,
                status: item.status, note: item.note))
            let row = try await scope.absences.record(dto.id)
            try await link(type: "absence", id: dto.id, snapshot: WorktimeSnapshot.absence(row), batch: batch)
        }
        for item in evaluation.customDays {
            let dto = try await scope.calendar.createCustom(.init(kind: .holiday, startDate: item.date, endDate: item.date, name: item.name))
            try await link(type: "custom_day", id: dto.id!, snapshot: WorktimeSnapshot.custom(kind: dto.kind.rawValue, from: dto.startDate.description, to: dto.endDate.description, name: dto.name), batch: batch)
        }
    }
    private func link(type: String, id: UUID, snapshot: String, batch: UUID) async throws {
        let link = ImportBatchItemRecord(); link.id = UUID(); link.accountId = scope.accountId; link.batchId = batch
        link.itemType = type; link.itemId = id; link.snapshot = snapshot; try await link.create(on: scope.db)
    }
    func rollbackWorktimeItems(batch: UUID, remove: Bool) async throws -> [ImportTypedConflict] {
        let links = try await ImportBatchItemRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$batchId == batch).all()
        var conflicts: [ImportTypedConflict] = []
        for link in links {
            if link.itemType == "absence" {
                let row = try await AbsenceRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$id == link.itemId).first()
                if let row, WorktimeSnapshot.absence(row) == link.snapshot { if remove { try await row.delete(on: scope.db) } }
                else { conflicts.append(.init(type: link.itemType, id: link.itemId)) }
            } else {
                let row = try await CustomCalendarDayRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$id == link.itemId).first()
                if let row, WorktimeSnapshot.custom(kind: row.kind, from: row.startDate, to: row.endDate, name: row.name) == link.snapshot { if remove { try await row.delete(on: scope.db) } }
                else { conflicts.append(.init(type: link.itemType, id: link.itemId)) }
            }
        }
        return conflicts
    }
}

enum WorktimeSnapshot {
    // Length-prefixed UTF-8 fields preserve boundaries, including arbitrary user text.
    static func encode(_ fields: [String]) -> String { fields.map { String($0.utf8.count) + ":" + $0 }.joined() }
    static func absence(_ row: AbsenceRecord) -> String {
        encode([row.kind, row.startDate, row.endDate, String(row.halfDayStart), String(row.halfDayEnd), row.status,
                row.note ?? "", row.documentStatus, row.documentSubmittedOn ?? "", row.documentReferenceStart ?? "",
                row.documentReferenceEnd ?? "", String(row.version)])
    }
    static func custom(kind: String, from: String, to: String, name: String) -> String { encode([kind, from, to, name]) }
}
