import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Fluent
import XCTVapor
import ZIPFoundation
@testable import TimetrackKit

// MARK: - Independent readers used to verify the generated files

enum ExportReaders {
    /// RFC 4180 parser (quoted fields, doubled quotes, embedded line breaks).
    static func csv(_ data: Data) -> [[String]] {
        let text = Array(String(decoding: data, as: UTF8.self).unicodeScalars)
        var rows: [[String]] = []; var row: [String] = []; var field = ""; var quoted = false; var index = 0
        while index < text.count {
            let c = text[index]
            if quoted {
                if c == "\"" { if index + 1 < text.count, text[index + 1] == "\"" { field.unicodeScalars.append(c); index += 1 } else { quoted = false } }
                else { field.unicodeScalars.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\r" || c == "\n" {
                if c == "\r", index + 1 < text.count, text[index + 1] == "\n" { index += 1 }
                row.append(field); field = ""; rows.append(row); row = []
            } else { field.unicodeScalars.append(c) }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    struct XLSXCell { var type: String?; var style: Int?; var value: String }
    final class SheetParser: NSObject, XMLParserDelegate {
        var cells: [String: XLSXCell] = [:]
        var merges: [String] = []
        var frozen = false
        var columns = 0
        private var ref = ""; private var type: String?; private var style: Int?; private var text = ""; private var inValue = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            switch name {
            case "c": ref = attributes["r"] ?? ""; type = attributes["t"]; style = attributes["s"].flatMap(Int.init); text = ""
            case "v", "t": inValue = true; text = name == "t" ? text : ""
            case "mergeCell": merges.append(attributes["ref"] ?? "")
            case "pane": frozen = attributes["state"] == "frozen"
            case "col": columns += 1
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inValue { text += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "v" || name == "t" { inValue = false }
            if name == "c" { cells[ref] = XLSXCell(type: type, style: style, value: text) }
        }
    }
    struct Workbook {
        var entries: [String: Data]
        var sheet: SheetParser
        func value(_ ref: String) -> String? { sheet.cells[ref]?.value }
        func number(_ ref: String) -> Double? { sheet.cells[ref].flatMap { Double($0.value) } }
        func rowNumber(serial: Int) -> Int? {
            sheet.cells.first { $0.key.hasPrefix("A") && $0.value.type == nil && Double($0.value.value) == Double(serial) }.flatMap { Int($0.key.dropFirst()) }
        }
        func seconds(_ ref: String) -> Int? { number(ref).map { Int(($0 * 86_400).rounded()) } }
    }
    static func xlsx(_ data: Data) throws -> Workbook {
        let archive = try Archive(data: data, accessMode: .read)
        var entries: [String: Data] = [:]; var names: [String] = []
        for entry in archive {
            var content = Data()
            _ = try archive.extract(entry) { content.append($0) }
            entries[entry.path] = content; names.append(entry.path)
        }
        XCTAssertEqual(names.count, Set(names).count, "duplicate zip entries")
        for (path, content) in entries {
            let parser = XMLParser(data: content)
            XCTAssertTrue(parser.parse(), "\(path) is not well-formed: \(String(describing: parser.parserError))")
        }
        let sheetParser = SheetParser()
        let parser = XMLParser(data: try XCTUnwrap(entries["xl/worksheets/sheet1.xml"]))
        parser.delegate = sheetParser
        XCTAssertTrue(parser.parse())
        return Workbook(entries: entries, sheet: sheetParser)
    }

    struct PDFInfo { var pages: Int; var texts: [[String]]; var objects: Int }
    /// Verifies header, xref table offsets and trailer, then extracts the shown strings per page.
    static func pdf(_ data: Data) throws -> PDFInfo {
        let text = String(decoding: data, as: UTF8.self)  // lossy only for the binary comment line
        let latin = String(data: data, encoding: .isoLatin1)!
        XCTAssertTrue(latin.hasPrefix("%PDF-1.4\n")); XCTAssertTrue(latin.hasSuffix("%%EOF\n"))
        let startRange = try XCTUnwrap(latin.range(of: "startxref\n", options: .backwards))
        let offset = try XCTUnwrap(Int(latin[startRange.upperBound...].prefix(while: { $0.isNumber })))
        let bytes = [UInt8](data)
        XCTAssertEqual(String(decoding: bytes[offset..<offset + 4], as: UTF8.self), "xref")
        let tableLines = latin[latin.index(latin.startIndex, offsetBy: offset)...].split(separator: "\n", omittingEmptySubsequences: false)
        let size = try XCTUnwrap(Int(tableLines[1].split(separator: " ")[1]))
        XCTAssertEqual(tableLines[2], "0000000000 65535 f ")
        for number in 1..<size {
            let entry = tableLines[2 + number]
            XCTAssertEqual(entry.count, 19)  // + "\n" = 20 bytes
            let position = try XCTUnwrap(Int(entry.prefix(10)))
            let expected = "\(number) 0 obj\n"
            XCTAssertEqual(String(decoding: bytes[position..<position + expected.utf8.count], as: UTF8.self), expected, "xref offset of object \(number)")
        }
        XCTAssertTrue(latin.contains("/Size \(size)"))
        // Page tree
        let countText = try XCTUnwrap(latin.range(of: "/Count ")).upperBound
        let pageCount = try XCTUnwrap(Int(latin[countText...].prefix(while: { $0.isNumber })))
        XCTAssertEqual(latin.components(separatedBy: "/Type /Page /").count - 1, pageCount)
        // Streams: honour /Length and decode shown hex strings with WinAnsi.
        var texts: [[String]] = []
        var cursor = latin.startIndex
        while let streamStart = latin.range(of: ">>\nstream\n", range: cursor..<latin.endIndex) {
            let lengthRange = try XCTUnwrap(latin.range(of: "/Length ", options: .backwards, range: cursor..<streamStart.lowerBound))
            let length = try XCTUnwrap(Int(latin[lengthRange.upperBound...].prefix(while: { $0.isNumber })))
            let startOffset = latin.distance(from: latin.startIndex, to: streamStart.upperBound)
            let content = String(decoding: bytes[startOffset..<startOffset + length], as: UTF8.self)
            XCTAssertEqual(String(decoding: bytes[startOffset + length..<startOffset + length + 10], as: UTF8.self), "\nendstream")
            var strings: [String] = []
            var scan = content[...]
            while let open = scan.firstIndex(of: "<") {
                guard let close = scan[open...].firstIndex(of: ">") else { break }
                let hex = scan[scan.index(after: open)..<close]
                if scan[scan.index(after: close)...].hasPrefix(" Tj") {
                    var decoded = ""
                    var index = hex.startIndex
                    while index < hex.endIndex {
                        let next = hex.index(index, offsetBy: 2)
                        decoded.unicodeScalars.append(unicode(UInt8(hex[index..<next], radix: 16)!))
                        index = next
                    }
                    strings.append(decoded)
                }
                scan = scan[scan.index(after: close)...]
            }
            texts.append(strings)
            cursor = streamStart.upperBound
        }
        _ = text
        return PDFInfo(pages: pageCount, texts: texts, objects: size - 1)
    }
    static func unicode(_ byte: UInt8) -> Unicode.Scalar {
        switch byte {
        case 0x80: "\u{20AC}"
        case 0x85: "\u{2026}"
        case 0x96: "\u{2013}"
        default: Unicode.Scalar(byte)
        }
    }
    static func externalTool(_ name: String) -> String? {
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] where FileManager.default.isExecutableFile(atPath: directory + "/" + name) {
            return directory + "/" + name
        }
        return nil
    }
}

// MARK: - Tests

extension AuthTests {
    // Synthetic document for writer-level tests.
    func exportSyntheticDocument(rows: Int = 3, name: String = "Jörg Müller-Straße €") -> ExportDocument {
        let from = try! LocalDate("2026-10-05"), to = try! LocalDate("2026-10-07")
        var body: [[ExportCell]] = []
        for index in 0..<rows {
            body.append([.date(from.addingDays(index)), .text(ExportFormat.weekday(from.addingDays(index))), .time(8 * 3600 + 7 * 60), .time(16 * 3600 + 120),
                         .duration(24_900), .duration(0), .signed(420), .signed(780), .duration(26_100), .empty, .duration(27_720), .signed(-1_620),
                         .text(index == 0 ? "Äpfel, Öl & Übung ß \"zitiert\"" : "Zeile \(index)")])
        }
        return ExportDocument(accountName: name, from: from, to: to, createdAt: Date(timeIntervalSince1970: 1_792_000_000),
                              columns: ExportService.columns, groups: ExportService.groups, rows: body, totals: ExportService.totals([]))
    }

    func testFormattingHelpers() throws {
        XCTAssertEqual(ExportFormat.duration(24_900), "6:55"); XCTAssertEqual(ExportFormat.duration(-1_620), "-0:27")
        XCTAssertEqual(ExportFormat.signed(420), "+0:07"); XCTAssertEqual(ExportFormat.signed(0), "0:00")
        XCTAssertEqual(ExportFormat.time(8 * 3600 + 7 * 60), "08:07")
        XCTAssertEqual(ExportFormat.weekday(try LocalDate("2026-10-12")), "Montag")
        XCTAssertEqual(ExportFormat.weekday(try LocalDate("2026-10-18")), "Sonntag")
        XCTAssertEqual(ExportFormat.weekday(try LocalDate("2000-01-01")), "Samstag")
        XCTAssertEqual(ExportFormat.excelSerial(try LocalDate("2026-10-05")), 46_300)
        XCTAssertEqual(ExportFormat.excelSerial(try LocalDate("1900-03-01")), 61)
    }

    func testCSVWriterRFC4180AndInjection() throws {
        var document = exportSyntheticDocument()
        let risky = ["=1+1", "@SUM(A1:A2)", "-2", "+x", "\tTabbed", "\rReturn", "plain, with comma", "line\nbreak", "quote \" inside"]
        document.rows = risky.map { [.date(document.from), .text($0)] }
        let data = CSVWriter.write(document)
        XCTAssertFalse(data.starts(with: [0xEF, 0xBB, 0xBF]), "no BOM")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\r\n"))
        let rows = ExportReaders.csv(data)
        XCTAssertEqual(rows[1], ["Name", "Jörg Müller-Straße €"])
        let parsed = rows.filter { $0.first == "05.10.2026" }.map { $0[1] }
        XCTAssertEqual(parsed, ["'=1+1", "'@SUM(A1:A2)", "'-2", "'+x", "'\tTabbed", "'\rReturn", "plain, with comma", "line\nbreak", "quote \" inside"])
        // The raw bytes of risky fields never start a field unprefixed.
        let text = String(decoding: data, as: UTF8.self)
        for risky in ["=1+1", "@SUM", "-2", "+x"] { XCTAssertFalse(text.contains(",\(risky)")); XCTAssertFalse(text.contains("\"\(risky)")) }
        // Own signed durations stay unprefixed (typed values, not user text).
        document.rows = [[.date(document.from), .signed(-1_620), .signed(420)]]
        XCTAssertTrue(String(decoding: CSVWriter.write(document), as: UTF8.self).contains("05.10.2026,-0:27,+0:07"))
    }

    func testXLSXWriterStructureAndValues() throws {
        var document = exportSyntheticDocument(rows: 2)
        document.rows[1][12] = .text("=HYPERLINK(\"http://x\")")
        let workbook = try ExportReaders.xlsx(try XLSXWriter.write(document))
        XCTAssertEqual(Set(workbook.entries.keys), ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/styles.xml", "xl/worksheets/sheet1.xml"])
        let types = String(decoding: try XCTUnwrap(workbook.entries["[Content_Types].xml"]), as: UTF8.self)
        XCTAssertTrue(types.contains("spreadsheetml.sheet.main+xml")); XCTAssertTrue(types.contains("worksheet+xml"))
        XCTAssertTrue(workbook.sheet.frozen); XCTAssertEqual(workbook.sheet.columns, 13); XCTAssertEqual(workbook.sheet.merges.count, 2)
        XCTAssertFalse(String(decoding: try XCTUnwrap(workbook.entries["xl/worksheets/sheet1.xml"]), as: UTF8.self).contains("<f>"), "no formulas")
        XCTAssertEqual(workbook.value("B2"), "Jörg Müller-Straße €")
        XCTAssertEqual(workbook.value("A6"), "Datum"); XCTAssertEqual(workbook.value("C5"), "Ist (tatsächlich)")
        XCTAssertEqual(workbook.number("A7"), 46_300); XCTAssertEqual(workbook.seconds("C7"), 29_220); XCTAssertEqual(workbook.seconds("E7"), 24_900)
        XCTAssertEqual(workbook.seconds("G7"), 420); XCTAssertEqual(workbook.seconds("L7"), -1_620)
        XCTAssertEqual(workbook.value("M7"), "Äpfel, Öl & Übung ß \"zitiert\"")
        let hyperlink = try XCTUnwrap(workbook.sheet.cells["M8"])
        XCTAssertEqual(hyperlink.type, "inlineStr"); XCTAssertEqual(hyperlink.value, "=HYPERLINK(\"http://x\")"); XCTAssertEqual(hyperlink.style, 6)
        XCTAssertEqual(workbook.sheet.cells["M7"]?.style, 0)
    }

    func testXLSXEscapesControlCharacters() throws {
        var document = exportSyntheticDocument(rows: 1)
        document.rows[0][12] = .text("a\u{0}b\u{1}c\td<e>&f\r\ng")
        let workbook = try ExportReaders.xlsx(try XLSXWriter.write(document))
        XCTAssertEqual(workbook.value("M7"), "abc\td<e>&f\r\ng".replacingOccurrences(of: "\r\n", with: "\r\n"))
    }

    func testPDFWriterSinglePageStructure() throws {
        let data = PDFWriter.write(exportSyntheticDocument())
        let info = try ExportReaders.pdf(data)
        XCTAssertEqual(info.pages, 1)
        let page = info.texts[0]
        for expected in ["Zeitnachweis", "Name: Jörg Müller-Straße €", "Zeitraum: 05.10.2026 bis 07.10.2026", "05.10.2026", "Montag", "08:07", "16:02", "6:55", "+0:07", "+0:13", "7:15", "Äpfel, Öl & Übung ß \"zitiert\"", "Seite 1 von 1", "Summe"] {
            XCTAssertTrue(page.contains(expected), "missing \(expected) in \(page)")
        }
        XCTAssertTrue(page.contains(where: { $0.hasPrefix("Erstellt am ") }))
        XCTAssertTrue(page.contains("Ist (tatsächlich)")); XCTAssertTrue(page.contains("Bewertung"))
        let media = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(media.contains("/MediaBox [0 0 841.89 595.28]"))
        XCTAssertTrue(media.contains("/WinAnsiEncoding"))
    }

    func testPDFWriterPageBreaksRepeatHeaderAndPageNumbers() throws {
        let document = exportSyntheticDocument(rows: 200)
        for orientation in [PDFWriter.Orientation.landscape, .portrait] {
            let data = PDFWriter.write(document, orientation: orientation)
            let info = try ExportReaders.pdf(data)
            XCTAssertGreaterThan(info.pages, 3)
            XCTAssertEqual(info.texts.count, info.pages)
            for (index, page) in info.texts.enumerated() {
                XCTAssertTrue(page.contains("Datum"), "header repeated on page \(index + 1)")
                XCTAssertTrue(page.contains("Markierung / Hinweis"))
                XCTAssertTrue(page.contains("Seite \(index + 1) von \(info.pages)"))
                XCTAssertTrue(page.contains(where: { $0.hasPrefix("Erstellt am ") }))
            }
            XCTAssertTrue(info.texts.last!.contains("Summe"))
            let rowsShown = info.texts.flatMap { $0 }.filter { $0.count == 10 && $0.dropFirst(2).hasPrefix(".") && $0.dropFirst(5).hasPrefix(".") }.count
            XCTAssertEqual(rowsShown, 200)
            if orientation == .portrait { XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("/MediaBox [0 0 595.28 841.89]")) }
        }
    }

    func testPDFTextClippingAndEncoding() throws {
        var document = exportSyntheticDocument(rows: 1)
        let long = String(repeating: "Sehr lange Bemerkung ", count: 20)
        document.rows[0][12] = .text(long)
        let info = try ExportReaders.pdf(PDFWriter.write(document))
        let clipped = try XCTUnwrap(info.texts[0].first { $0.hasPrefix("Sehr lange") })
        XCTAssertTrue(clipped.hasSuffix("\u{2026}")); XCTAssertLessThan(clipped.count, long.count)
        XCTAssertEqual(PDFWriter.winAnsi("ä"), 0xE4); XCTAssertEqual(PDFWriter.winAnsi("ß"), 0xDF); XCTAssertEqual(PDFWriter.winAnsi("€"), 0x80)
        XCTAssertEqual(PDFWriter.winAnsi("漢"), 0x3F)
        XCTAssertEqual(PDFWriter.clip("abc", size: 8, bold: false, available: 100), "abc")
        XCTAssertLessThanOrEqual(PDFWriter.textWidth(PDFWriter.clip(long, size: 8, bold: false, available: 50), size: 8), 50)
        // Strings with PDF syntax characters are hex encoded and cannot break the stream.
        document.rows[0][12] = .text(") Tj (evil\\ <00>")
        let evil = try ExportReaders.pdf(PDFWriter.write(document))
        XCTAssertTrue(evil.texts[0].contains(") Tj (evil\\ <00>"))
    }

    func testPDFExternalValidatorsWhenInstalled() throws {
        let data = PDFWriter.write(exportSyntheticDocument(rows: 120))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("export-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("out.pdf"); try data.write(to: file)
        func run(_ tool: String, _ arguments: [String]) throws -> (Int32, String) {
            let process = Process(); process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            try process.run(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        var ran = false
        if let qpdf = ExportReaders.externalTool("qpdf") { ran = true; let result = try run(qpdf, ["--check", file.path]); XCTAssertEqual(result.0, 0, result.1) }
        if let mutool = ExportReaders.externalTool("mutool") { ran = true; let result = try run(mutool, ["info", file.path]); XCTAssertEqual(result.0, 0, result.1) }
        if let pdftotext = ExportReaders.externalTool("pdftotext") {
            ran = true; let result = try run(pdftotext, ["-layout", file.path, "-"])
            XCTAssertEqual(result.0, 0); XCTAssertTrue(result.1.contains("Müller-Straße")); XCTAssertTrue(result.1.contains("Seite 1 von"))
        }
        // macOS: PDFKit-independent sanity via the system `file` tool.
        if !ran, let tool = ExportReaders.externalTool("file") {
            let result = try run(tool, [file.path]); XCTAssertTrue(result.1.contains("PDF document, version 1.4"), result.1)
        }
        if !ran { print("No qpdf/mutool/pdftotext installed; external PDF validation skipped.") }
    }

    // MARK: HTTP scenarios

    func exportFetch(_ app: Application, _ context: AuthContext?, _ query: String, status: HTTPStatus = .ok,
               file: StaticString = #filePath, line: UInt = #line) async throws -> XCTHTTPResponse {
        let response = try await app.testable().sendRequest(.GET, "/api/v1/export/time?" + query, headers: context.map { headers($0, csrf: false) } ?? [:])
        XCTAssertEqual(response.status, status, response.body.string, file: file, line: line)
        return response
    }
    func exportBytes(_ response: XCTHTTPResponse) -> Data { Data(response.body.readableBytesView) }
    func exportCSVRows(_ response: XCTHTTPResponse) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for row in ExportReaders.csv(exportBytes(response)) where row.count == 13 && row[0].count == 10 && row[0].contains(".") { result[row[0]] = row }
        return result
    }

    func exportScenario(_ app: Application, _ auth: AuthService) async throws {
        let (context, _) = try await registered(auth, db: app.db)
        let account = try await Account.query(on: app.db).first().unwrap()
        account.displayName = "Jörg Müller-Straße €"; try await account.save(on: app.db)
        try await planningModel(app, context)
        // 2026-10-05: ADR example 08:07-12:00 + 13:00-16:02 (Berlin, CEST).
        try await api(app, context, .POST, "time/segments", segmentBody("2026-10-05T06:07:00Z", "2026-10-05T10:00:00Z"), .created)
        try await api(app, context, .POST, "time/segments", segmentBody("2026-10-05T11:00:00Z", "2026-10-05T14:02:00Z"), .created)
        try await createAbsence(app, context, absenceBody("2026-10-06"))
        try await createAbsence(app, context, absenceBody("2026-10-07", first: true))
        try await createAbsence(app, context, absenceBody("2026-10-08", kind: "sick"))
        // Injection strings as day notes (user text).
        let notes = ["=1+1", "@SUM(A1)", "-2", "+x", "\tTab"]
        for (index, note) in notes.enumerated() {
            try await api(app, context, .PUT, "time/days/2026-09-\(21 + index)", ["note": note])
        }
        // Another account must never leak into the export.
        let other = try await second(app, auth, context)
        let foreign = try await Account.query(on: app.db).filter(\.$handle == "member").first().unwrap()
        foreign.displayName = "Fremd Person"; try await foreign.save(on: app.db)
        try await planningModel(app, other)
        try await api(app, other, .POST, "time/segments", segmentBody("2026-10-09T05:00:00Z", "2026-10-09T15:00:00Z"), .created)
        try await api(app, other, .PUT, "time/days/2026-10-09", ["note": "Geheim"])

        let query = "from=2026-10-05&to=2026-10-09"
        // CSV
        let csv = try await exportFetch(app, context, query + "&format=csv")
        XCTAssertEqual(csv.headers.first(name: .contentType), "text/csv; charset=utf-8")
        XCTAssertEqual(csv.headers.first(name: .contentDisposition),
                       "attachment; filename=\"zeitnachweis_2026-10-05_2026-10-09.csv\"; filename*=UTF-8''zeitnachweis_2026-10-05_2026-10-09.csv")
        XCTAssertEqual(csv.headers.first(name: .cacheControl), "no-store"); XCTAssertEqual(csv.headers.first(name: "X-Content-Type-Options"), "nosniff")
        let rows = exportCSVRows(csv)
        XCTAssertEqual(rows["05.10.2026"], ["05.10.2026", "Montag", "08:07", "16:02", "6:55", "0:00", "+0:07", "+0:13", "7:15", "", "7:42", "-0:27", ""])
        XCTAssertEqual(rows["06.10.2026"]?[12], "Urlaub"); XCTAssertEqual(rows["07.10.2026"]?[12], "Urlaub (halber Tag)")
        XCTAssertEqual(rows["08.10.2026"]?[12], "Krank")
        XCTAssertEqual(rows["09.10.2026"]?[2], ""); XCTAssertEqual(rows["09.10.2026"]?[12], "")
        let halfTarget = try XCTUnwrap(rows["07.10.2026"]?[10]); XCTAssertEqual(halfTarget, "3:51")
        let total = try XCTUnwrap(ExportReaders.csv(exportBytes(csv)).first { $0.first == "Summe" })
        XCTAssertEqual(total[4], "6:55"); XCTAssertEqual(total[8], "7:15"); XCTAssertEqual(total[6], "+0:07")
        let body = csv.body.string
        XCTAssertTrue(body.contains("Name,Jörg Müller-Straße €")); XCTAssertTrue(body.contains("Zeitraum,05.10.2026 bis 09.10.2026"))
        XCTAssertFalse(body.contains("Fremd")); XCTAssertFalse(body.contains("Geheim"))
        // Holiday (Tag der Arbeit 2026-05-01, a Friday)
        let holiday = exportCSVRows(try await exportFetch(app, context, "from=2026-04-30&to=2026-05-01&format=csv"))
        XCTAssertEqual(holiday["01.05.2026"]?[12], "Feiertag"); XCTAssertEqual(holiday["01.05.2026"]?[10], "")
        // Running day is provisional.
        var berlin = Calendar(identifier: .gregorian); berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let today = berlin.dateComponents([.year, .month, .day], from: Date())
        let todayText = String(format: "%04d-%02d-%02d", today.year!, today.month!, today.day!)
        let running = exportCSVRows(try await exportFetch(app, context, "from=\(todayText)&to=\(todayText)&format=csv"))
        XCTAssertEqual(running.values.first?[12].contains("vorläufig"), true)
        // Injection notes stay text in CSV.
        let notesCSV = try await exportFetch(app, context, "from=2026-09-21&to=2026-09-25&format=csv")
        let noteRows = exportCSVRows(notesCSV)
        XCTAssertEqual((21...25).map { noteRows["\($0).09.2026"]?[12] }, ["'=1+1", "'@SUM(A1)", "'-2", "'+x", "'\tTab"])
        // XLSX
        let xlsxResponse = try await exportFetch(app, context, query + "&format=xlsx")
        XCTAssertEqual(xlsxResponse.headers.first(name: .contentType), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        XCTAssertTrue(xlsxResponse.headers.first(name: .contentDisposition)!.hasSuffix("filename*=UTF-8''zeitnachweis_2026-10-05_2026-10-09.xlsx"))
        let workbook = try ExportReaders.xlsx(exportBytes(xlsxResponse))
        XCTAssertEqual(workbook.value("B2"), "Jörg Müller-Straße €")
        let row = try XCTUnwrap(workbook.rowNumber(serial: 46_300))
        XCTAssertEqual(workbook.seconds("C\(row)"), 8 * 3600 + 7 * 60); XCTAssertEqual(workbook.seconds("D\(row)"), 16 * 3600 + 2 * 60)
        XCTAssertEqual(workbook.seconds("E\(row)"), 24_900); XCTAssertEqual(workbook.seconds("G\(row)"), 420); XCTAssertEqual(workbook.seconds("H\(row)"), 780)
        XCTAssertEqual(workbook.seconds("I\(row)"), 26_100); XCTAssertEqual(workbook.seconds("K\(row)"), 27_720); XCTAssertEqual(workbook.seconds("L\(row)"), -1_620)
        XCTAssertEqual(workbook.value("M\(row + 1)"), "Urlaub"); XCTAssertEqual(workbook.value("M\(row + 2)"), "Urlaub (halber Tag)"); XCTAssertEqual(workbook.value("M\(row + 3)"), "Krank")
        XCTAssertFalse(String(decoding: exportBytes(xlsxResponse), as: UTF8.self).contains("Geheim"))
        // Injection in XLSX
        let notesBook = try ExportReaders.xlsx(exportBytes(try await exportFetch(app, context, "from=2026-09-21&to=2026-09-25&format=xlsx")))
        let firstNote = try XCTUnwrap(notesBook.rowNumber(serial: 46_286))
        for (index, note) in notes.enumerated() {
            let cell = try XCTUnwrap(notesBook.sheet.cells["M\(firstNote + index)"])
            XCTAssertEqual(cell.type, "inlineStr"); XCTAssertEqual(cell.value, note); XCTAssertEqual(cell.style, 6)
        }
        // PDF
        let pdfResponse = try await exportFetch(app, context, query + "&format=pdf")
        XCTAssertEqual(pdfResponse.headers.first(name: .contentType), "application/pdf")
        let info = try ExportReaders.pdf(exportBytes(pdfResponse))
        XCTAssertEqual(info.pages, 1)
        for expected in ["Name: Jörg Müller-Straße €", "05.10.2026", "Montag", "08:07", "16:02", "6:55", "+0:07", "+0:13", "7:15", "7:42", "-0:27", "Urlaub", "Urlaub (halber Tag)", "Krank"] {
            XCTAssertTrue(info.texts[0].contains(expected), "PDF misses \(expected)")
        }
        XCTAssertFalse(info.texts[0].contains { $0.contains("Fremd") || $0.contains("Geheim") })
        // Isolation from the other side
        let mine = exportCSVRows(try await exportFetch(app, other, query + "&format=csv"))
        XCTAssertEqual(mine["09.10.2026"]?[2], "07:00"); XCTAssertTrue(mine["09.10.2026"]?[12].hasSuffix("Geheim") == true); XCTAssertEqual(mine["05.10.2026"]?[2], "")
        let otherBody = try await exportFetch(app, other, query + "&format=csv").body.string
        XCTAssertTrue(otherBody.contains("Fremd Person")); XCTAssertFalse(otherBody.contains("Jörg"))
        // Name injection
        account.displayName = "=HYPERLINK(\"http://evil\")"; try await account.save(on: app.db)
        let nameCSV = try await exportFetch(app, context, query + "&format=csv")
        XCTAssertEqual(ExportReaders.csv(exportBytes(nameCSV))[1], ["Name", "'=HYPERLINK(\"http://evil\")"])
        let nameBook = try ExportReaders.xlsx(exportBytes(try await exportFetch(app, context, query + "&format=xlsx")))
        XCTAssertEqual(nameBook.sheet.cells["B2"]?.style, 6); XCTAssertEqual(nameBook.value("B2"), "=HYPERLINK(\"http://evil\")")
        // Auth, limits and parameter validation
        _ = try await exportFetch(app, nil, query + "&format=csv", status: .unauthorized)
        _ = try await exportFetch(app, context, "from=2026-01-01&to=2026-12-31&format=csv")
        let full = try await exportFetch(app, context, "from=2026-01-01&to=2027-01-01&format=csv")
        XCTAssertEqual(exportCSVRows(full).count, 366)
        let tooLarge = try await exportFetch(app, context, "from=2026-01-01&to=2027-01-02&format=csv", status: .badRequest)
        XCTAssertEqual(try errorCode(tooLarge), "range_too_large")
        for bad in ["from=2026-10-05&to=2026-10-09&format=docx", "from=2026-10-05&to=2026-10-09", "from=2026-10-09&to=2026-10-05&format=csv",
                    "from=2026-13-01&to=2026-10-05&format=csv", "from=x&to=2026-10-05&format=csv", "to=2026-10-05&format=csv", "from=2026-10-05&format=csv"] {
            _ = try await exportFetch(app, context, bad, status: .badRequest)
        }
        // Full year as PDF and XLSX stays valid (many pages).
        let yearPDF = try ExportReaders.pdf(exportBytes(try await exportFetch(app, context, "from=2026-01-01&to=2026-12-31&format=pdf")))
        XCTAssertGreaterThan(yearPDF.pages, 5)
        _ = try ExportReaders.xlsx(exportBytes(try await exportFetch(app, context, "from=2026-01-01&to=2026-12-31&format=xlsx")))
    }

    func testExportHTTPSQLite() async throws { try await withApp(exportScenario) }
    func testExportHTTPMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test", "DB_TLS": "off"]
        try await withApp(environment: environment, exportScenario)
    }
}

private extension Optional {
    func unwrap(file: StaticString = #filePath, line: UInt = #line) throws -> Wrapped { try XCTUnwrap(self, file: file, line: line) }
}
