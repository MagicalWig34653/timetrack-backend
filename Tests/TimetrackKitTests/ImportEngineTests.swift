import Foundation
import XCTest
import ZIPFoundation
@testable import TimetrackKit

// MARK: Minimal XLSX writer for tests (ZIPFoundation + hand-written XML)

enum TestCell {
    case shared(String), inline(String), num(String, style: Int = 0), bool(Bool), empty
    case formula(String, cached: String?)        // numeric cached value
    case formulaText(String, cached: String?)    // string cached value (t="str")
}

enum TestXLSX {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    static func column(_ index: Int) -> String {
        var n = index + 1, out = ""
        while n > 0 { out = String(UnicodeScalar(UInt8(65 + (n - 1) % 26))) + out; n = (n - 1) / 26 }
        return out
    }

    static func add(_ archive: Archive, _ path: String, _ data: Data, method: CompressionMethod = .deflate) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: method) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }

    static func build(sheets: [(name: String, rows: [[TestCell]])], date1904: Bool = false,
                      extra: [(String, Data)] = [], styles: Bool = true) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        var shared: [String] = []
        func sharedIndex(_ text: String) -> Int {
            if let i = shared.firstIndex(of: text) { return i }
            shared.append(text); return shared.count - 1
        }
        var sheetXML: [String] = []
        for sheet in sheets {
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
            for (r, row) in sheet.rows.enumerated() {
                xml += "<row r=\"\(r + 1)\">"
                for (c, cell) in row.enumerated() {
                    let ref = column(c) + String(r + 1)
                    switch cell {
                    case .empty: break
                    case .shared(let text): xml += "<c r=\"\(ref)\" t=\"s\"><v>\(sharedIndex(text))</v></c>"
                    case .inline(let text): xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(escape(text))</t></is></c>"
                    case .num(let value, let style): xml += "<c r=\"\(ref)\" s=\"\(style)\"><v>\(value)</v></c>"
                    case .bool(let value): xml += "<c r=\"\(ref)\" t=\"b\"><v>\(value ? 1 : 0)</v></c>"
                    case .formula(let f, let cached): xml += "<c r=\"\(ref)\"><f>\(escape(f))</f>" + (cached.map { "<v>\($0)</v>" } ?? "") + "</c>"
                    case .formulaText(let f, let cached): xml += "<c r=\"\(ref)\" t=\"str\"><f>\(escape(f))</f>" + (cached.map { "<v>\(escape($0))</v>" } ?? "") + "</c>"
                    }
                }
                xml += "</row>"
            }
            sheetXML.append(xml + "</sheetData></worksheet>")
        }
        try add(archive, "[Content_Types].xml", Data("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>".utf8))
        var workbook = "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        workbook += "<workbookPr" + (date1904 ? " date1904=\"1\"" : "") + "/><sheets>"
        var rels = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for (i, sheet) in sheets.enumerated() {
            workbook += "<sheet name=\"\(escape(sheet.name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
            rels += "<Relationship Id=\"rId\(i + 1)\" Type=\"worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
            try add(archive, "xl/worksheets/sheet\(i + 1).xml", Data(sheetXML[i].utf8))
        }
        try add(archive, "xl/workbook.xml", Data((workbook + "</sheets></workbook>").utf8))
        try add(archive, "xl/_rels/workbook.xml.rels", Data((rels + "</Relationships>").utf8))
        if styles {
            try add(archive, "xl/styles.xml", Data("<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"hh:mm:ss\"/></numFmts><cellXfs count=\"5\"><xf numFmtId=\"0\"/><xf numFmtId=\"14\"/><xf numFmtId=\"20\"/><xf numFmtId=\"22\"/><xf numFmtId=\"164\"/></cellXfs></styleSheet>".utf8))
        }
        let sst = "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">" + shared.map { "<si><t>\(escape($0))</t></si>" }.joined() + "</sst>"
        try add(archive, "xl/sharedStrings.xml", Data(sst.utf8))
        for (path, data) in extra { try add(archive, path, data) }
        return archive.data ?? Data()
    }
}

// MARK: Pure parser and interpreter tests

final class ImportEngineTests: XCTestCase {
    func csv(_ text: String, encoding: String.Encoding = .utf8) -> [[String]] {
        (try? CSVReader.read(text.data(using: encoding)!)) ?? []
    }

    func testCSVDialectMatrix() throws {
        let expected = [["Datum", "Beginn", "Ende"], ["03.11.2026", "08:00", "12:00"]]
        XCTAssertEqual(csv("Datum,Beginn,Ende\n03.11.2026,08:00,12:00\n"), expected)
        XCTAssertEqual(csv("Datum;Beginn;Ende\r\n03.11.2026;08:00;12:00\r\n"), expected)
        XCTAssertEqual(csv("Datum\tBeginn\tEnde\n03.11.2026\t08:00\t12:00"), expected)
        XCTAssertEqual(csv("Datum;Beginn;Ende\r03.11.2026;08:00;12:00\r"), expected)   // CR only
        XCTAssertEqual(csv("\u{FEFF}Datum;Beginn;Ende\n03.11.2026;08:00;12:00\n"), expected)
        // German decimals inside a semicolon file must not turn the comma into the delimiter.
        XCTAssertEqual(csv("Datum;Stunden;Ort\n03.11.2026;7,7;Büro\n04.11.2026;8,25;Büro\n")[1], ["03.11.2026", "7,7", "Büro"])
        // Quotes: delimiter, doubled quote and line break inside a field.
        XCTAssertEqual(csv("a,b\n\"x, y\",\"he said \"\"hi\"\"\"\n\"line1\nline2\",z\n"),
                       [["a", "b"], ["x, y", "he said \"hi\""], ["line1\nline2", "z"]])
        XCTAssertEqual(csv("a;b\n\"\";x\n"), [["a", "b"], ["", "x"]])
        // UTF-16 with BOM (both byte orders) and ISO-8859-1 fallback.
        var le = Data([0xFF, 0xFE]); le.append("Ort;Zeit\nBüro;8:00\n".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(try CSVReader.read(le), [["Ort", "Zeit"], ["Büro", "8:00"]])
        var be = Data([0xFE, 0xFF]); be.append("Ort;Zeit\nBüro;8:00\n".data(using: .utf16BigEndian)!)
        XCTAssertEqual(try CSVReader.read(be), [["Ort", "Zeit"], ["Büro", "8:00"]])
        XCTAssertEqual(csv("Ort;Zeit\nBüro;8:00\n", encoding: .isoLatin1), [["Ort", "Zeit"], ["Büro", "8:00"]])
        // Blank lines keep their row number; a missing final line break is fine; single column stays single.
        XCTAssertEqual(csv("a;b\n\nc;d").count, 3)
        XCTAssertEqual(csv("only\nvalues\n"), [["only"], ["values"]])
        // A quote inside an unquoted field is literal; an unterminated quote is rejected.
        XCTAssertEqual(csv("a;5\" pipe\n")[0], ["a", "5\" pipe"])
        XCTAssertThrowsError(try CSVReader.read(Data("a;b\n\"c;d\n".utf8)))
        // Binary content is not CSV.
        XCTAssertThrowsError(try CSVReader.read(Data([0x25, 0x50, 0x44, 0x46, 0x00, 0x01])))
    }

    func mapping(date: Int = 0, start: Int? = 1, end: Int? = 2, duration: Int? = nil, kind: Int? = nil, place: Int? = nil, note: Int? = nil,
                 dateFormat: ImportDateFormat = .ddMMyyyy, timeFormat: ImportTimeFormat = .hhmm, overnight: Bool? = nil, skip: Bool? = nil,
                 zone: String? = nil, defaultKind: EngineSegmentKind? = nil) -> ImportMapping {
        .init(sheet: "CSV", headerRow: 0, timezone: zone, dateFormat: dateFormat, timeFormat: timeFormat, defaultKind: defaultKind,
              columns: .init(date: date, start: start, end: end, duration: duration, kind: kind, place: place, note: note),
              skipSummaryRows: skip, allowOvernight: overnight)
    }
    func run(_ rows: [[String]], _ mapping: ImportMapping, places: [String: UUID] = [:], date1904: Bool = false) -> [ImportRowOutcome] {
        ImportInterpreter(mapping: mapping, date1904: date1904, places: places)
            .interpret(rows.map { $0.map { $0.isEmpty ? ImportCell.empty : .text($0) } }).map(\.outcome)
    }
    func one(_ row: [String], _ mapping: ImportMapping, places: [String: UUID] = [:]) -> ImportRowOutcome { run([row], mapping, places: places)[0] }
    func candidate(_ outcome: ImportRowOutcome, file: StaticString = #filePath, line: UInt = #line) throws -> ImportCandidate {
        guard case .candidate(let value) = outcome else { XCTFail("not a candidate: \(outcome)", file: file, line: line); throw XCTSkip("x") }
        return value
    }
    func code(_ outcome: ImportRowOutcome) -> String? { if case .failed(let code) = outcome { return code }; return nil }
    func utc(_ text: String) -> Date { timeInstant(text)! }

    func testDecimalHoursAreNotClockTime() throws {
        // 7,7 h = 7 h 42 min = 27 720 s; the same text as HH:mm is invalid (never 7:07).
        let decimal = mapping(start: 1, end: nil, duration: 2, timeFormat: .decimalHours)
        let value = try candidate(one(["10.03.2026", "8", "7,7"], decimal))
        XCTAssertEqual(value.end.timeIntervalSince(value.start), 27_720)
        XCTAssertEqual(try candidate(one(["10.03.2026", "8", "7.7"], decimal)).end.timeIntervalSince(value.start), 27_720)
        XCTAssertEqual(try candidate(one(["10.03.2026", "8,5", "1,25"], decimal)).start, utc("2026-03-10T07:30:00Z"))
        XCTAssertEqual(code(one(["10.03.2026", "8", "7,7"], mapping(start: 1, end: nil, duration: 2, timeFormat: .hhmm))), "time_invalid")
        XCTAssertEqual(code(one(["10.03.2026", "8", "25"], decimal)), "time_invalid")
        XCTAssertEqual(code(one(["10.03.2026", "8", "abc"], decimal)), "time_invalid")
        XCTAssertEqual(code(one(["10.03.2026", "8", "7,7,7"], decimal)), "time_invalid")
        // Clock times: 7:07 really is 7 h 7 min; 24:00 is allowed as an end only.
        let clock = try candidate(one(["10.03.2026", "7:07", "24:00"], mapping()))
        XCTAssertEqual(clock.start, utc("2026-03-10T06:07:00Z")); XCTAssertEqual(clock.end, utc("2026-03-10T23:00:00Z"))
        XCTAssertEqual(code(one(["10.03.2026", "24:00", "24:00"], mapping())), "time_invalid")
        XCTAssertEqual(code(one(["10.03.2026", "8:60", "12:00"], mapping())), "time_invalid")
        XCTAssertEqual(code(one(["10.03.2026", "8", "12:00"], mapping())), "time_invalid")
    }

    func testDateFormatsAndExcelSerials() throws {
        func day(_ row: [String], _ m: ImportMapping) -> String? {
            if case .candidate(let value) = one(row, m) { return value.date.description }; return nil
        }
        XCTAssertEqual(day(["3.11.2026", "8:00", "9:00"], mapping()), "2026-11-03")
        XCTAssertNil(day(["2026-11-03", "8:00", "9:00"], mapping()))
        XCTAssertEqual(day(["2026-11-03", "8:00", "9:00"], mapping(dateFormat: .yyyyMMdd)), "2026-11-03")
        XCTAssertNil(day(["31.02.2026", "8:00", "9:00"], mapping()))
        XCTAssertNil(day(["03.11.26", "8:00", "9:00"], mapping()))
        let serial = mapping(dateFormat: .excelSerial)
        XCTAssertEqual(day(["45292", "8:00", "9:00"], serial), "2024-01-01")
        XCTAssertEqual(day(["46329,75", "8:00", "9:00"], serial), "2026-11-03")
        // 1900 system: serial 60 is the non-existent 29.02.1900; 59 and 61 straddle it.
        XCTAssertEqual(day(["1", "8:00", "9:00"], serial), "1900-01-01")
        XCTAssertEqual(day(["59", "8:00", "9:00"], serial), "1900-02-28")
        XCTAssertNil(day(["60", "8:00", "9:00"], serial))
        XCTAssertEqual(day(["61", "8:00", "9:00"], serial), "1900-03-01")
        XCTAssertNil(day(["0", "8:00", "9:00"], serial))
        XCTAssertNil(day(["-5", "8:00", "9:00"], serial))
        XCTAssertNil(day(["3000000", "8:00", "9:00"], serial))
        XCTAssertEqual(day(["2958465", "8:00", "9:00"], serial), "9999-12-31")
        // 1904 flag shifts by 1462 days.
        let rows = [["43830", "8:00", "9:00"]]
        if case .candidate(let value) = run(rows, serial, date1904: true)[0] { XCTAssertEqual(value.date.description, "2024-01-01") } else { XCTFail() }
        if case .candidate(let value) = run([["0", "8:00", "9:00"]], serial, date1904: true)[0] { XCTAssertEqual(value.date.description, "1904-01-01") } else { XCTFail() }
    }

    func testExcelFractionsAndDuration() throws {
        let fraction = mapping(dateFormat: .yyyyMMdd, timeFormat: .excelFraction)
        let value = try candidate(one(["2026-03-10", "0,3333333333333333", "0.5"], fraction))
        XCTAssertEqual(value.start, utc("2026-03-10T07:00:00Z")); XCTAssertEqual(value.end, utc("2026-03-10T11:00:00Z"))
        XCTAssertEqual(code(one(["2026-03-10", "1,5", "0.5"], fraction)), "time_invalid")
        let withDuration = try candidate(one(["10.03.2026", "08:00", "", "02:30"], mapping(end: 2, duration: 3)))
        XCTAssertEqual(withDuration.end, utc("2026-03-10T09:30:00Z"))
        XCTAssertEqual(code(one(["10.03.2026", "08:00", "", ""], mapping(end: 2, duration: 3))), "missing_value")
        XCTAssertEqual(code(one(["10.03.2026", "", "09:00"], mapping())), "missing_value")
        XCTAssertEqual(code(one(["10.03.2026", "08:00", ""], mapping())), "missing_value")
        XCTAssertEqual(code(one(["10.03.2026", "08:00", "", "00:00"], mapping(end: 2, duration: 3))), "end_before_start")
    }

    func testMidnightCrossingOnlyWhenExplicit() throws {
        XCTAssertEqual(code(one(["10.03.2026", "22:00", "02:00"], mapping())), "end_before_start")
        XCTAssertEqual(code(one(["10.03.2026", "08:00", "08:00"], mapping(overnight: true))), "end_before_start")
        let crossing = try candidate(one(["10.03.2026", "22:00", "02:00"], mapping(overnight: true)))
        XCTAssertEqual(crossing.end.timeIntervalSince(crossing.start), 4 * 3600)
        XCTAssertEqual(crossing.date.description, "2026-03-10")
        // New year's eve: the next day is computed on the calendar, not by adding 24 h.
        let nye = try candidate(one(["31.12.2026", "23:00", "01:00"], mapping(overnight: true)))
        XCTAssertEqual(nye.end, utc("2027-01-01T00:00:00Z"))
    }

    func testDaylightSavingTime() throws {
        // Spring forward 29.03.2026 (Europe/Berlin): 02:00-03:00 does not exist.
        let across = try candidate(one(["29.03.2026", "01:00", "04:00"], mapping()))
        XCTAssertEqual(across.start, utc("2026-03-29T00:00:00Z")); XCTAssertEqual(across.end, utc("2026-03-29T02:00:00Z"))
        XCTAssertEqual(code(one(["29.03.2026", "02:30", "04:00"], mapping())), "time_invalid")
        XCTAssertEqual(code(one(["29.03.2026", "01:00", "02:30"], mapping())), "time_invalid")
        // Fall back 25.10.2026: the wall-clock span 01:00-04:00 lasts four hours.
        let back = try candidate(one(["25.10.2026", "01:00", "04:00"], mapping()))
        XCTAssertEqual(back.end.timeIntervalSince(back.start), 4 * 3600)
        XCTAssertEqual(back.end, utc("2026-10-25T03:00:00Z"))
        // A duration is elapsed time: eight hours from 22:00 summer time ends at 05:00 winter time.
        let duration = try candidate(one(["24.10.2026", "22", "", "8"], mapping(end: 2, duration: 3, timeFormat: .decimalHours)))
        XCTAssertEqual(duration.end.timeIntervalSince(duration.start), 8 * 3600)
        // Other zones and a day without DST.
        let utcZone = try candidate(one(["10.03.2026", "08:00", "09:00"], mapping(zone: "UTC")))
        XCTAssertEqual(utcZone.start, utc("2026-03-10T08:00:00Z"))
        let tokyo = try candidate(one(["10.03.2026", "08:00", "09:00"], mapping(zone: "Asia/Tokyo")))
        XCTAssertEqual(tokyo.start, utc("2026-03-09T23:00:00Z"))
    }

    func testSummaryRowsKindsPlacesAndNotes() throws {
        let rows = [["Datum", "Von", "Bis"], ["10.03.2026", "08:00", "09:00"], ["Summe", "", "01:00"], ["", "", "01:00"], ["Gesamt:", "", ""], [""], ["", "", ""]]
        let skipping = run(rows, mapping()).dropFirst(0)
        var plain = mapping(); plain.headerRow = 1
        let outcomes = run(rows, plain)
        XCTAssertEqual(outcomes.count, 6)
        guard case .candidate = outcomes[0], case .summary = outcomes[1], case .summary = outcomes[2], case .summary = outcomes[3] else { return XCTFail("\(outcomes)") }
        if case .blank = outcomes[4], case .blank = outcomes[5] {} else { XCTFail("blank rows are ignored") }
        _ = skipping
        var keep = plain; keep.skipSummaryRows = false
        XCTAssertEqual(run(rows, keep).prefix(4).map { code($0) }, [nil, "summary_row", "summary_row", "summary_row"])

        let place = UUID()
        let full = mapping(kind: 3, place: 4, note: 5, defaultKind: .school)
        let ok = try candidate(one(["10.03.2026", "08:00", "09:00", "Fahrt", " büro ", "=cmd|' /C calc'!A0"], full, places: ["büro": place]))
        XCTAssertEqual(ok.kind, .travel); XCTAssertEqual(ok.placeId, place); XCTAssertEqual(ok.note, "=cmd|' /C calc'!A0")
        XCTAssertEqual(try candidate(one(["10.03.2026", "08:00", "09:00", "", "", ""], full)).kind, .school)
        XCTAssertEqual(code(one(["10.03.2026", "08:00", "09:00", "Fahrt", "Garten", ""], full, places: ["büro": place])), "unknown_place")
        XCTAssertEqual(code(one(["10.03.2026", "08:00", "09:00", "Urlaub", "", ""], full)), "unknown_kind")
        XCTAssertEqual(code(one(["10.03.2026", "08:00", "09:00", "", "", String(repeating: "x", count: 501)], full)), "note_too_long")
    }

    // MARK: XLSX

    func openSheet(_ data: Data, _ name: String = "Sheet1") throws -> ImportSheet {
        try ImportWorkbook.open(data: data, filename: "t.xlsx").sheet(name)
    }

    func testXLSXCellKinds() throws {
        let data = try TestXLSX.build(sheets: [("Sheet1", [
            [.shared("Datum"), .inline("Beginn"), .shared("Datum")],
            [.num("46329", style: 1), .num("0.3333333333333333", style: 2), .num("0.5", style: 2), .bool(true)],
            [.num("46329"), .formula("A2+1", cached: "46330"), .formula("A2", cached: nil), .formulaText("B1&C1", cached: "x")],
            [.num("46329.5", style: 3), .num("0.5", style: 4)],
        ]), ("Zweites Blatt", [[.shared("a")]])])
        let workbook = try ImportWorkbook.open(data: data, filename: "report.XLSX")
        XCTAssertEqual(workbook.kind, "xlsx"); XCTAssertEqual(workbook.sheetNames, ["Sheet1", "Zweites Blatt"])
        let sheet = try workbook.sheet("Sheet1")
        XCTAssertEqual(sheet.rows[0], [.text("Datum"), .text("Beginn"), .text("Datum")])
        XCTAssertEqual(sheet.rows[1], [.number("46329", .date), .number("0.3333333333333333", .time), .number("0.5", .time), .bool(true)])
        XCTAssertEqual(sheet.rows[2], [.number("46329", .plain), .number("46330", .plain), .formulaWithoutValue, .text("x")])
        XCTAssertEqual(sheet.rows[3], [.number("46329.5", .dateTime), .number("0.5", .time)])
        XCTAssertThrowsError(try workbook.sheet("Nope"))
        XCTAssertEqual(ImportInterpreter.display(sheet.rows[1][0], date1904: false), "2026-11-03")
        XCTAssertEqual(ImportInterpreter.display(sheet.rows[3][0], date1904: false), "2026-11-03 12:00")
        // Interpretation: date-styled and time-styled cells win over the declared text formats.
        let sheetMapping = mapping(date: 0, start: 1, end: 2, dateFormat: .ddMMyyyy, timeFormat: .hhmm)
        let value = try candidate(ImportInterpreter(mapping: sheetMapping, date1904: false, places: [:]).interpret([sheet.rows[1]])[0].outcome)
        XCTAssertEqual(value.date.description, "2026-11-03"); XCTAssertEqual(value.start, utc("2026-11-03T07:00:00Z")); XCTAssertEqual(value.end, utc("2026-11-03T11:00:00Z"))
        // A formula without cached value is an error; one with a cached value is read as that value.
        let formulaRow: [ImportCell] = [sheet.rows[2][0], .number("0.25", .plain), sheet.rows[2][2]]
        let broken = ImportInterpreter(mapping: mapping(dateFormat: .excelSerial, timeFormat: .excelFraction), date1904: false, places: [:]).interpret([formulaRow])[0].outcome
        XCTAssertEqual(code(broken), "formula_without_value")
    }

    func testXLSX1904AndOddCells() throws {
        let data = try TestXLSX.build(sheets: [("S", [[.num("43830"), .num("0.25"), .num("0.5")]])], date1904: true, styles: false)
        let sheet = try openSheet(data, "S")
        XCTAssertTrue(sheet.date1904)
        let outcome = ImportInterpreter(mapping: mapping(dateFormat: .excelSerial, timeFormat: .excelFraction), date1904: sheet.date1904, places: [:]).interpret(sheet.rows)[0].outcome
        XCTAssertEqual(try candidate(outcome).date.description, "2024-01-01")
        // Shared formulas, empty strings and gaps keep column positions.
        let gap = try TestXLSX.build(sheets: [("S", [[.empty, .empty, .shared("c")], [], [.shared("a")]])])
        let rows = try openSheet(gap, "S").rows
        XCTAssertEqual(rows[0], [.empty, .empty, .text("c")]); XCTAssertEqual(rows[1], []); XCTAssertEqual(rows[2], [.text("a")])
    }

    func testXLSXZipBombAndStructureDefences() throws {
        let sheet: [(name: String, rows: [[TestCell]])] = [("S", [[.shared("a")]])]
        // More than 64 entries.
        let many = try TestXLSX.build(sheets: sheet, extra: (0..<70).map { ("junk/\($0).txt", Data("x".utf8)) })
        XCTAssertThrowsError(try ImportWorkbook.open(data: many, filename: "a.xlsx")) { XCTAssertEqual(($0 as? APIError)?.code, "file_too_large") }
        // More than 50 MiB uncompressed (compresses to a few KiB).
        let bomb = try TestXLSX.build(sheets: sheet, extra: [("xl/bomb.bin", Data(count: 60 * 1024 * 1024))])
        XCTAssertLessThan(bomb.count, 1024 * 1024)
        XCTAssertThrowsError(try ImportWorkbook.open(data: bomb, filename: "a.xlsx")) { XCTAssertEqual(($0 as? APIError)?.code, "file_too_large") }
        // Path traversal and absolute paths in entry names.
        for path in ["../evil.txt", "xl/../../evil.txt", "/abs.txt", "a\\b.txt"] {
            let data = try TestXLSX.build(sheets: sheet, extra: [(path, Data("x".utf8))])
            XCTAssertThrowsError(try ImportWorkbook.open(data: data, filename: "a.xlsx"), path) { XCTAssertEqual(($0 as? APIError)?.code, "unsupported_type") }
        }
        // More than 20 000 rows.
        let tall = try TestXLSX.build(sheets: [("S", [[.shared("a")]])], extra: [])
        let bigSheet = "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData><row r=\"20001\"><c r=\"A20001\" t=\"inlineStr\"><is><t>x</t></is></c></row></sheetData></worksheet>"
        let archive = try Archive(data: tall, accessMode: .update)
        try archive.remove(try XCTUnwrap(archive["xl/worksheets/sheet1.xml"]))
        try TestXLSX.add(archive, "xl/worksheets/sheet1.xml", Data(bigSheet.utf8))
        let rowsOpen = try ImportWorkbook.open(data: archive.data!, filename: "a.xlsx")
        XCTAssertThrowsError(try rowsOpen.sheet("S")) { XCTAssertEqual(($0 as? APIError)?.code, "too_many_rows") }
        // Row attributes beyond the limit are rejected even without cells.
        let edge = "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData><row r=\"20000\"><c r=\"A20000\" t=\"inlineStr\"><is><t>x</t></is></c></row><row r=\"1048576\" s=\"1\"/></sheetData></worksheet>"
        let archive2 = try Archive(data: tall, accessMode: .update)
        try archive2.remove(try XCTUnwrap(archive2["xl/worksheets/sheet1.xml"]))
        try TestXLSX.add(archive2, "xl/worksheets/sheet1.xml", Data(edge.utf8))
        XCTAssertThrowsError(try ImportWorkbook.open(data: archive2.data!, filename: "a.xlsx").sheet("S")) { XCTAssertEqual(($0 as? APIError)?.code, "too_many_rows") }
        // DTD / entity declarations are refused (no entity expansion).
        let xxe = "<?xml version=\"1.0\"?><!DOCTYPE x [<!ENTITY a \"aaaa\">]><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData/></worksheet>"
        let archive3 = try Archive(data: tall, accessMode: .update)
        try archive3.remove(try XCTUnwrap(archive3["xl/worksheets/sheet1.xml"]))
        try TestXLSX.add(archive3, "xl/worksheets/sheet1.xml", Data(xxe.utf8))
        XCTAssertThrowsError(try ImportWorkbook.open(data: archive3.data!, filename: "a.xlsx").sheet("S"))
        // Not a workbook at all.
        let plainZip = try Archive(data: Data(), accessMode: .create)
        try TestXLSX.add(plainZip, "hello.txt", Data("hi".utf8))
        XCTAssertThrowsError(try ImportWorkbook.open(data: plainZip.data!, filename: "a.xlsx")) { XCTAssertEqual(($0 as? APIError)?.code, "unsupported_type") }
    }

    func testSniffingByContentAndRowLimit() throws {
        let csvData = Data("a;b\n1;2\n".utf8)
        let xlsx = try TestXLSX.build(sheets: [("S", [[.shared("a")]])])
        func code(_ data: Data, _ name: String) -> String? {
            do { _ = try ImportWorkbook.open(data: data, filename: name); return nil } catch { return (error as? APIError)?.code ?? "other" }
        }
        XCTAssertNil(code(csvData, "x.csv")); XCTAssertNil(code(csvData, "x.TXT")); XCTAssertNil(code(xlsx, "x.xlsx"))
        XCTAssertEqual(code(xlsx, "x.csv"), "unsupported_type")            // ZIP content behind a text extension
        XCTAssertEqual(code(csvData, "x.xlsx"), "unsupported_type")        // text behind a spreadsheet extension
        XCTAssertEqual(code(csvData, "x.pdf"), "unsupported_type")
        XCTAssertEqual(code(csvData, "noextension"), "unsupported_type")
        XCTAssertEqual(code(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D]), "x.csv"), "unsupported_type")
        XCTAssertEqual(code(Data(), "x.csv"), "bad_request")
        XCTAssertEqual(code(Data(count: 5 * 1024 * 1024 + 1), "x.csv"), "file_too_large")
        let lines = (0..<20_001).map { _ in "a;b" }.joined(separator: "\n")
        XCTAssertEqual(code(Data(lines.utf8), "x.csv"), "too_many_rows")
        XCTAssertNil(code(Data((0..<20_000).map { _ in "a;b" }.joined(separator: "\n").utf8), "x.csv"))
    }

    func testMappingValidation() {
        XCTAssertNoThrow(try mapping().validate())
        XCTAssertThrowsError(try mapping(start: nil).validate())
        XCTAssertThrowsError(try mapping(end: nil, duration: nil).validate())
        XCTAssertThrowsError(try mapping(date: -1).validate())
        XCTAssertThrowsError(try mapping(note: 100_000).validate())
        XCTAssertThrowsError(try mapping(zone: "Mars/Olympus").validate())
    }
}
