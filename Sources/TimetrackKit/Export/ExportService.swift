import Foundation
import Fluent

enum ExportLimits { static let maxDays = 366 }

enum ExportFileFormat: String, Sendable {
    case xlsx, pdf, csv
    var contentType: String {
        switch self {
        case .xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case .pdf: "application/pdf"
        case .csv: "text/csv; charset=utf-8"
        }
    }
}

/// Builds the time sheet from the same day evaluation the app uses (absences, holidays, rounding, provisional day).
struct ExportService: Sendable {
    let scope: TimeServices

    static let columns: [ExportColumn] = [
        .init(title: "Datum", alignment: .left, weight: 10),
        .init(title: "Wochentag", alignment: .left, weight: 9),
        .init(title: "Beginn (tatsächlich)", alignment: .right, weight: 8),
        .init(title: "Ende (tatsächlich)", alignment: .right, weight: 8),
        .init(title: "Arbeitszeit tatsächlich", alignment: .right, weight: 9),
        .init(title: "Pausenabzug", alignment: .right, weight: 8),
        .init(title: "Rundung Beginn", alignment: .right, weight: 8),
        .init(title: "Rundung Ende", alignment: .right, weight: 8),
        .init(title: "Arbeitszeit bewertet", alignment: .right, weight: 9),
        .init(title: "Gutschrift", alignment: .right, weight: 8),
        .init(title: "Soll", alignment: .right, weight: 7),
        .init(title: "Differenz", alignment: .right, weight: 8),
        .init(title: "Markierung / Hinweis", alignment: .left, weight: 30)
    ]
    static let groups: [ExportGroup] = [
        .init(title: "Ist (tatsächlich)", first: 2, last: 4),
        .init(title: "Bewertung", first: 5, last: 11)
    ]

    func document(from: LocalDate, to: LocalDate, now: Date = Date()) async throws -> ExportDocument {
        let days = try await scope.days.range(from: from, to: to, limit: ExportLimits.maxDays)
        guard let account = try await Account.find(scope.accountId, on: scope.db) else { throw APIError.unauthorized }
        var zones: [UUID: TimeZone] = [:]
        for model in try await scope.models.list() {
            if let id = model.id, let zone = TimeZone(identifier: model.timezone ?? "Europe/Berlin") { zones[id] = zone }
        }
        let rows = days.map { Self.row($0, zone: $0.modelId.flatMap { zones[$0] } ?? TimeZone(identifier: "Europe/Berlin") ?? .gmt) }
        return ExportDocument(accountName: account.displayName, from: from, to: to, createdAt: now,
                              columns: Self.columns, groups: Self.groups, rows: rows, totals: Self.totals(days))
    }

    static func hints(_ day: DayEvaluationResult) -> String {
        var parts: [String] = []
        switch day.mark {
        case .none: break
        case .holiday: parts.append("Feiertag")
        case .vacation: parts.append(day.markSource == .absence && day.targetOverrideSeconds != nil ? "Urlaub (halber Tag)" : "Urlaub")
        case .sick: parts.append("Krank")
        case .excused: parts.append("Freigestellt")
        case .schoolCredit: parts.append("Berufsschule (Gutschrift)")
        }
        if day.provisional { parts.append("vorläufig") }
        for hint in day.breakHints {
            switch hint.code {
            case .breakMissing30: parts.append("Hinweis: Pause von 30 Min. fehlt")
            case .breakMissing45: parts.append("Hinweis: Pause von 45 Min. fehlt")
            case .breakPartTooShort: parts.append("Hinweis: Pausenteil unter 15 Min.")
            case .workOver6hWithoutBreak: parts.append("Hinweis: über 6 Std. ohne Pause")
            case .workOver4h30WithoutBreak: parts.append("Hinweis: über 4,5 Std. ohne Pause")
            case .breakMissing60: parts.append("Hinweis: 60 Min. Pause fehlen")
            }
        }
        let legalLabels: [LegalWarning.Code: String] = [
            .dailyLimit: "Tagesgrenze überschritten", .weeklyLimit: "Wochengrenze überschritten",
            .fiveDayWeek: "Fünf-Tage-Woche überschritten", .restPeriod: "Ruhezeit unterschritten",
            .weekendWork: "Wochenendarbeit prüfen", .workAfterFullSchoolDay: "Arbeit nach vollem Berufsschultag",
            .workBeforeSchool: "Arbeit vor 9 Uhr am Berufsschultag"
        ]
        for warning in day.legalWarnings { if let label = legalLabels[warning.code] { parts.append("Hinweis: " + label) } }
        if let note = day.note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: "; ")
    }

    static func row(_ day: DayEvaluationResult, zone: TimeZone) -> [ExportCell] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        func secondsOfDay(_ date: Date) -> Int {
            let p = calendar.dateComponents([.hour, .minute, .second], from: date)
            return (p.hour ?? 0) * 3600 + (p.minute ?? 0) * 60 + (p.second ?? 0)
        }
        // Rounding favours the employee: the evaluated start is earlier and the evaluated end later than the real times.
        let actualStart = day.evaluatedStart.map { secondsOfDay($0.addingTimeInterval(TimeInterval(day.startAdjustSeconds))) }
        let actualEnd = day.evaluatedEnd.map { secondsOfDay($0.addingTimeInterval(-TimeInterval(day.endAdjustSeconds))) }
        let worked = !day.segments.isEmpty
        let hint = hints(day)
        return [
            .date(day.date), .text(ExportFormat.weekday(day.date)),
            actualStart.map(ExportCell.time) ?? .empty, actualEnd.map(ExportCell.time) ?? .empty,
            worked ? .duration(day.rawWorkSeconds) : .empty,
            worked ? .duration(day.breakDeductionSeconds) : .empty,
            worked ? .signed(day.startAdjustSeconds) : .empty, worked ? .signed(day.endAdjustSeconds) : .empty,
            worked ? .duration(day.evaluatedWorkSeconds) : .empty,
            day.creditSeconds > 0 ? .duration(day.creditSeconds) : .empty,
            day.targetSeconds > 0 ? .duration(day.targetSeconds) : .empty,
            worked || day.targetSeconds > 0 || day.creditSeconds > 0 ? .signed(day.deltaSeconds) : .empty,
            hint.isEmpty ? .empty : .text(hint)
        ]
    }

    static func totals(_ days: [DayEvaluationResult]) -> [ExportCell] {
        func sum(_ value: (DayEvaluationResult) -> Int) -> Int { days.reduce(0) { saturatingAdd($0, value($1)) } }
        return [
            .text("Summe"), .empty, .empty, .empty,
            .duration(sum(\.rawWorkSeconds)), .duration(sum(\.breakDeductionSeconds)),
            .signed(sum(\.startAdjustSeconds)), .signed(sum(\.endAdjustSeconds)),
            .duration(sum(\.evaluatedWorkSeconds)), .duration(sum(\.creditSeconds)), .duration(sum(\.targetSeconds)),
            .signed(sum(\.deltaSeconds)), .empty
        ]
    }

    static func render(_ document: ExportDocument, as format: ExportFileFormat) throws -> Data {
        switch format {
        case .csv: CSVWriter.write(document)
        case .pdf: PDFWriter.write(document)
        case .xlsx: try XLSXWriter.write(document)
        }
    }

    static func fileName(from: LocalDate, to: LocalDate, format: ExportFileFormat) -> String {
        "zeitnachweis_\(from)_\(to).\(format.rawValue)"
    }
}
