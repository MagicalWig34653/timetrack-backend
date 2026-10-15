import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

final class WorktimeExportTests: XCTestCase {
    typealias Writer = FormulaXLSXWriter
    let zone = TimeZone(identifier: "Europe/Berlin")!
    func model(rounding: Bool = false, workdays: Set<Int> = [1,2,3,4,5]) throws -> EngineWorkModel {
        EngineWorkModel(validFrom: try LocalDate("2024-01-01"), weeklyTargetSeconds: 138600, workdays: workdays, roundingEnabled: rounding)
    }
    func segment(_ date: LocalDate, _ start: Int = 28800, _ end: Int? = 58320, kind: EngineSegmentKind = .work, note: String? = nil) -> EngineSegment {
        .init(kind: kind, start: ImportInterpreter.instant(date, seconds: start, zone: zone)!,
              end: end.flatMap { ImportInterpreter.instant(date, seconds: $0, zone: zone) }, note: note)
    }
    func number(_ cell: Writer.Cell?) throws -> Double {
        guard case .number(let value) = try XCTUnwrap(cell).value else { throw APIError.invalid }; return value
    }
    func seconds(_ cell: Writer.Cell?) throws -> Int { Int((try number(cell) * 86400).rounded()) }
    func text(_ cell: Writer.Cell?) -> String? { if case .text(let value) = cell?.value { return value }; return nil }
    func evaluate(_ date: LocalDate, model: EngineWorkModel, segments: [EngineSegment] = [], mark: DayPreferences = .init()) throws -> DayEvaluationResult {
        try TimeEvaluationSnapshot(models: [model], segments: segments, preferences: [date.description: mark]).evaluate(date,
            now: ImportInterpreter.instant(date, seconds: 65000, zone: zone)!)
    }
    func cells(_ day: DayEvaluationResult, model: EngineWorkModel, pause: Int = 1800, options: WorktimeExportOptions? = nil) throws -> WorktimeExportService.DayCells {
        WorktimeExportService.dayCells(day, model: model, templateTarget: 27720, pause: pause, row: 7, options: try options ?? .init())
    }
    func testFormulaWriterCachesStylesAndEscaping() throws {
        var sheet = Writer.Sheet(name: "Ä & 2026")
        sheet.set(1, 0, .text("=HYPERLINK(\"x\")"))
        sheet.set(2, 0, .init(value: .number(0.5), style: .duration, formula: "1/2"))
        sheet.set(3, 0, .init(value: .text("Ä < & \"\u{0}\t"), formula: "IF(1<2,\"Ä\",\"\")"))
        sheet.set(4, 0, .text("Kopf", bold: true))
        var second = Writer.Sheet(name: "2027"); second.frozenRows = nil
        let book = try ExportReaders.xlsx(try Writer.write(.init(sheets: [sheet, second], date1904: true)))
        let workbook = String(decoding: try XCTUnwrap(book.entries["xl/workbook.xml"]), as: UTF8.self)
        XCTAssertTrue(workbook.contains("date1904=\"1\"")); XCTAssertTrue(workbook.contains("fullCalcOnLoad=\"1\""))
        XCTAssertTrue(workbook.contains("Ä &amp; 2026"))
        let xml = String(decoding: try XCTUnwrap(book.entries["xl/worksheets/sheet1.xml"]), as: UTF8.self)
        XCTAssertTrue(xml.contains("<f>1/2</f><v>0.5</v>")); XCTAssertTrue(xml.contains("t=\"str\"><f>IF(1&lt;2"))
        XCTAssertEqual(book.value("A3"), "Ä < & \"\t"); XCTAssertEqual(book.value("A1"), "=HYPERLINK(\"x\")")
        XCTAssertEqual(book.sheet.cells["A1"]?.style, Writer.Style.quoted.rawValue)
        XCTAssertEqual(book.sheet.cells["A4"]?.style, Writer.Style.header.rawValue)
        XCTAssertTrue(book.sheet.frozen); XCTAssertEqual(book.sheet.columns, 8)
        let styles = String(decoding: try XCTUnwrap(book.entries["xl/styles.xml"]), as: UTF8.self)
        for format in ["[h]:mm", "[hh]:mm;@", "0.0", "[$-F800]dddd\\,\\ mmmm\\ dd\\,\\ yyyy", "h:mm;@", "quotePrefix=\"1\""] {
            XCTAssertTrue(styles.contains(format), format)
        }
        XCTAssertFalse(String(decoding: try XCTUnwrap(book.entries["xl/worksheets/sheet2.xml"]), as: UTF8.self).contains("<pane"))
        XCTAssertThrowsError(try Writer.write(.init(sheets: [sheet, sheet])))
    }
    func testDateSerialLeapYearAndImporterAgreement() throws {
        for raw in ["1900-01-01", "1900-02-28", "1900-03-01", "1904-01-01", "2026-10-05"] {
            let date = try LocalDate(raw)
            for system in [false, true] where !system || date.year >= 1904 {
                let serial = Writer.serial(date, date1904: system)
                XCTAssertEqual(try ImportInterpreter.date(serial: String(serial), date1904: system), date)
            }
        }
        XCTAssertEqual(Writer.serial(try LocalDate("1900-02-28"), date1904: false), 59)
        XCTAssertEqual(Writer.serial(try LocalDate("1900-03-01"), date1904: false), 61)
        XCTAssertThrowsError(try ImportInterpreter.date(serial: "60", date1904: false))
    }
    func testYearLayoutBlockCountsAndISOOwnership() throws {
        // The writer's layout can be inspected independently of the HTTP limit of 366 days.
        let from = try LocalDate("2024-07-29"), to = try LocalDate("2026-12-31")
        let model = try model()
        let boundary = try LocalDate("2025-12-29")
        let day = try evaluate(boundary, model: model, segments: [segment(boundary)])
        let doc = try WorktimeExportService.build(from: from, to: to, days: [day], models: [model], options: .init())
        XCTAssertEqual(doc.sheets.map(\.name), ["2024", "2025", "2026"])
        let labels = doc.sheets.map { sheet in sheet.rows.keys.sorted().compactMap { text(sheet.rows[$0]?[0]) }.filter { $0.hasPrefix("KW") } }
        XCTAssertEqual(labels.map(\.count), [23, 53, 53])
        XCTAssertEqual(labels[1].last, "KW01 - 2026"); XCTAssertEqual(labels[2].last, "KW53")
        let serial = Double(Writer.serial(boundary, date1904: false))
        for (index, sheet) in doc.sheets.enumerated() where index > 0 {
            let r = try XCTUnwrap(sheet.rows.first { $0.value[0]?.value == .number(serial) }?.key)
            XCTAssertEqual(sheet.rows[r]?[1] != nil, index == 2)
            XCTAssertEqual(sheet.rows[r]?[5] != nil, false)
        }
        XCTAssertTrue(doc.sheets[1].rows[2]?[1]?.formula?.hasSuffix("+'2024'!B2") == true)
        XCTAssertTrue(doc.sheets[2].rows[2]?[1]?.formula?.hasSuffix("+'2025'!B2") == true)
        _ = try ExportReaders.xlsx(try Writer.write(doc))
    }
    func testBoundaryOwnerOutsideCalendarRangeIsNotLost() throws {
        let date = try LocalDate("2027-01-01"), model = try model()
        let day = try evaluate(date, model: model, segments: [segment(date)])
        let doc = try WorktimeExportService.build(from: date, to: date, days: [day], models: [model], options: .init())
        XCTAssertEqual(doc.sheets.map(\.name), ["2026", "2027"])
        let parsed = try WorktimeWorkbook.parse(ImportWorkbook.open(data: Writer.write(doc), filename: "synthetic.xlsx"), options: .init())
        XCTAssertEqual(parsed.days.map(\.date), [date]); XCTAssertEqual(parsed.errors, [])
    }
    func testDayFormulaArithmeticAndValueFallbacks() throws {
        let date = try LocalDate("2026-10-05"), model = try model()
        let segments = [segment(date, 28800, 43200), segment(date, 45000, 58320)]
        let day = try evaluate(date, model: model, segments: segments)
        let row = try cells(day, model: model)
        XCTAssertEqual(row.cells[3]?.formula, "C7-B7-$H$1"); XCTAssertEqual(row.cells[4]?.formula, "D7-$E$1")
        XCTAssertEqual(try seconds(row.cells[3]), 27720); XCTAssertEqual(try seconds(row.cells[4]), 0)
        XCTAssertEqual(try number(row.cells[2]) - number(row.cells[1]) - 1800.0/86400, try number(row.cells[3]), accuracy: 1e-12)
        let deviation = try cells(evaluate(date, model: model, segments: [segment(date)]), model: model)
        XCTAssertNil(deviation.cells[3]?.formula); XCTAssertTrue(text(deviation.cells[5])?.contains("Pause abweichend") == true)
        XCTAssertEqual(try seconds(deviation.cells[3]), 29520)
        let four = try self.model(workdays: [1,2,3,4])
        let fourRow = try cells(evaluate(date, model: four, segments: segments), model: four)
        XCTAssertNil(fourRow.cells[4]?.formula); XCTAssertTrue(text(fourRow.cells[5])?.contains("Soll abweichend") == true)
        XCTAssertEqual(try seconds(fourRow.cells[4]), 27720 - 34650)
        let doc = try WorktimeExportService.build(from: date, to: date,
            days: [evaluate(date, model: four, segments: segments)], models: [four], options: .init())
        XCTAssertEqual(try seconds(doc.sheets[0].rows[1]?[1]), 138600)
        XCTAssertEqual(try seconds(doc.sheets[0].rows[1]?[4]), 27720)
        XCTAssertEqual(doc.sheets[0].rows[1]?[4]?.formula, "B1/5")
        XCTAssertEqual(try seconds(doc.sheets[0].rows[1]?[7]), 0)
        let withoutModel = try WorktimeExportService.build(from: date, to: date, days: [], models: [], options: .init())
        XCTAssertEqual(try seconds(withoutModel.sheets[0].rows[1]?[7]), 1800)
    }
    func testCreditedDaysHalfVacationAndSchool() throws {
        let date = try LocalDate("2026-10-05"), model = try model()
        for (mark, label) in [(DayMarkKind.vacation, "Urlaub"), (.sick, "Krank"), (.excused, "Freigestellt"), (.holiday, "Feiertag"), (.schoolCredit, "Berufsschule")] {
            let day = try evaluate(date, model: model, mark: .init(mark: mark))
            let row = try cells(day, model: model, options: .init(standardStart: "09:15"))
            XCTAssertEqual(try seconds(row.cells[1]), 33300); XCTAssertEqual(try seconds(row.cells[2]), 62820)
            XCTAssertEqual(try seconds(row.cells[3]), 27720); XCTAssertEqual(try seconds(row.cells[4]), 0)
            XCTAssertEqual(text(row.cells[5]), label); XCTAssertNotNil(row.cells[3]?.formula)
        }
        let half = try TimeEvaluationSnapshot(models: [model], segments: [], preferences: [:], absences: [
            .init(startDate: date, endDate: date, status: .taken, halfDayStart: true)]).evaluate(date, now: Date())
        let halfRow = try cells(half, model: model)
        XCTAssertEqual(try seconds(halfRow.cells[3]), 13860)
        XCTAssertEqual(try seconds(halfRow.cells[4]), half.deltaSeconds)
        XCTAssertEqual(try seconds(halfRow.cells[2]), 28800 + 13860 + 1800)
        let school = try cells(evaluate(date, model: model, segments: [segment(date, 28800, 45000, kind: .school)]), model: model)
        XCTAssertEqual(text(school.cells[5]), "Berufsschule"); XCTAssertEqual(try seconds(school.cells[3]), 27720)
    }
    func testRoundingActualTimesRunningDayAndInjectionNotes() throws {
        let date = try LocalDate("2026-10-05"), model = try model(rounding: true)
        let day = try evaluate(date, model: model, segments: [segment(date, 29220, 57720, note: "=1+1")])
        let evaluated = try cells(day, model: model)
        let actual = try cells(day, model: model, options: .init(times: "actual"))
        XCTAssertEqual(try seconds(evaluated.cells[1]), 28800); XCTAssertEqual(try seconds(actual.cells[1]), 29220)
        XCTAssertEqual(try seconds(evaluated.cells[2]), 58500); XCTAssertEqual(try seconds(actual.cells[2]), 57720)
        XCTAssertEqual(evaluated.cells[3]?.value, actual.cells[3]?.value)
        XCTAssertEqual(evaluated.cells[5]?.style, .quoted)
        let running = try cells(evaluate(date, model: model, segments: [segment(date, 28800, nil)]), model: model)
        XCTAssertNotNil(running.cells[1]); XCTAssertNil(running.cells[2]); XCTAssertNil(running.cells[3])
        let long = try cells(evaluate(date, model: model, segments: [segment(date, note: "@" + String(repeating: "x", count: 150))]), model: model)
        XCTAssertEqual(text(long.cells[5])?.count, 100); XCTAssertEqual(long.cells[5]?.style, .quoted)
        let sunday = try LocalDate("2026-10-11")
        XCTAssertTrue(try cells(evaluate(sunday, model: model), model: model).cells.isEmpty)
    }
    func testWeeklyAndChainedBalanceCachesMatchEvaluations() throws {
        let from = try LocalDate("2025-12-22"), to = try LocalDate("2026-01-09"), model = try model()
        var days: [DayEvaluationResult] = []
        for offset in 0...from.distance(to: to) {
            let date = from.addingDays(offset)
            days.append(try evaluate(date, model: model, segments: ExportFormat.weekdayIndex(date) < 5 ? [segment(date)] : []))
        }
        let doc = try WorktimeExportService.build(from: from, to: to, days: days, models: [model], options: .init())
        XCTAssertGreaterThan(try seconds(doc.sheets[0].rows[2]?[1]), 0)
        XCTAssertEqual(try seconds(doc.sheets.last?.rows[2]?[1]), days.reduce(0) { $0 + $1.deltaSeconds })
        for sheet in doc.sheets {
            for (r, values) in sheet.rows where values[6]?.formula != nil {
                let sum = try (1...5).reduce(0.0) { total, offset in total + (try sheet.rows[r + offset]?[3].map { try number($0) } ?? 0) }
                XCTAssertEqual(try number(values[6]), sum * 24, accuracy: 1e-10)
                XCTAssertEqual(values[6]?.formula, "SUM(D\(r + 1):D\(r + 5))*24")
            }
        }
    }
    func testStrictOptionValidation() throws {
        for value in ["", "raw", "Evaluated"] { XCTAssertThrowsError(try WorktimeExportOptions(times: value)) }
        for value in ["", "-1", "241", "1.0", "+30", " 30", "30x"] { XCTAssertThrowsError(try WorktimeExportOptions(pauseMinutes: value)) }
        for value in ["", "8:00", "24:00", "29:59", "08:60", "08:00:00", "０８:00"] { XCTAssertThrowsError(try WorktimeExportOptions(standardStart: value)) }
        for value in ["", "1901", "true"] { XCTAssertThrowsError(try WorktimeExportOptions(dateSystem: value)) }
        XCTAssertEqual(try WorktimeExportOptions(pauseMinutes: "240", standardStart: "23:59", dateSystem: "1904").standardStart, 86340)
    }
}
