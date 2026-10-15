import Foundation
import ZIPFoundation

/// Trusted formulas are separate from untrusted text. Formula caches are required, never computed by the writer.
enum FormulaXLSXWriter {
    enum Style: Int, Sendable { case plain, header, date, time, duration, balance, decimal, quoted, boldDuration, boldBalance, boldDecimal }
    enum Value: Equatable, Sendable {
        case number(Double), text(String)
    }
    struct Cell: Sendable {
        var value: Value
        var style: Style = .plain
        var formula: String? = nil
        static func seconds(_ seconds: Int, style: Style = .duration, formula: String? = nil) -> Self {
            .init(value: .number(Double(seconds) / 86400), style: style, formula: formula)
        }
        static func text(_ text: String, bold: Bool = false) -> Self {
            .init(value: .text(text), style: ExportFormat.isFormulaRisk(text) ? .quoted : bold ? .header : .plain)
        }
    }
    struct Sheet: Sendable {
        var name: String
        var rows: [Int: [Int: Cell]] = [:]
        var frozenRows: Int? = 6
        mutating func set(_ row: Int, _ column: Int, _ cell: Cell) { rows[row, default: [:]][column] = cell }
    }
    struct Document: Sendable {
        var sheets: [Sheet]
        var date1904 = false
    }
    static func serial(_ date: LocalDate, date1904: Bool) -> Int {
        let days = ImportInterpreter.epochDays(date)
        return date1904 ? days + 24107 : days + (date < (try! LocalDate("1900-03-01")) ? 25568 : 25569)
    }
    private static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    private static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relationships = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let office = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static func escape(_ text: String) -> String { XLSXWriter.escape(text) }

    static func write(_ document: Document) throws -> Data {
        guard !document.sheets.isEmpty, Set(document.sheets.map { $0.name.lowercased() }).count == document.sheets.count,
              document.sheets.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 31 && !$0.name.hasPrefix("'") && !$0.name.hasSuffix("'") && !$0.name.contains(where: { "[]:*?/\\".contains($0) }) && !$0.name.unicodeScalars.contains(where: { $0.value < 32 }) }) else { throw APIError.invalid }
        let archive = try Archive(accessMode: .create)
        var types = "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        var rels = "<Relationships xmlns=\"\(relationships)\">"
        var workbook = "<workbook xmlns=\"\(main)\" xmlns:r=\"\(office)\"><workbookPr date1904=\"\(document.date1904 ? 1 : 0)\"/><sheets>"
        var parts: [(String, String)] = []
        for (index, sheet) in document.sheets.enumerated() {
            let n = index + 1
            types += "<Override PartName=\"/xl/worksheets/sheet\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            rels += "<Relationship Id=\"rId\(n)\" Type=\"\(office)/worksheet\" Target=\"worksheets/sheet\(n).xml\"/>"
            workbook += "<sheet name=\"\(escape(sheet.name))\" sheetId=\"\(n)\" r:id=\"rId\(n)\"/>"
            parts.append(("xl/worksheets/sheet\(n).xml", try xml(sheet)))
        }
        workbook += "</sheets><calcPr calcId=\"191029\" fullCalcOnLoad=\"1\"/></workbook>"
        rels += "<Relationship Id=\"rId\(document.sheets.count + 1)\" Type=\"\(office)/styles\" Target=\"styles.xml\"/></Relationships>"
        parts += [("[Content_Types].xml", types + "</Types>"), ("xl/workbook.xml", workbook),
                  ("xl/_rels/workbook.xml.rels", rels), ("xl/styles.xml", styles),
                  ("_rels/.rels", "<Relationships xmlns=\"\(relationships)\"><Relationship Id=\"rId1\" Type=\"\(office)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")]
        for (path, xml) in parts {
            let bytes = Data((declaration + xml).utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .deflate) { position, size in
                bytes.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        guard let data = archive.data else { throw APIError(.internalServerError, "not_ready") }
        return data
    }
    private static func xml(_ sheet: Sheet) throws -> String {
        var result = "<worksheet xmlns=\"\(main)\"><sheetViews><sheetView workbookViewId=\"0\">"
        if let count = sheet.frozenRows, count > 0 {
            result += "<pane ySplit=\"\(count)\" topLeftCell=\"A\(count + 1)\" activePane=\"bottomLeft\" state=\"frozen\"/>"
        }
        result += "</sheetView></sheetViews><cols>"
        for (index, width) in [30.0, 15, 15, 15, 9.3, 75, 9.1, 15].enumerated() {
            result += "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
        }
        result += "</cols><sheetData>"
        for row in sheet.rows.keys.sorted() {
            guard row > 0 else { throw APIError.invalid }
            result += "<row r=\"\(row)\">"
            for column in sheet.rows[row]!.keys.sorted() {
                guard column >= 0 else { throw APIError.invalid }
                let cell = sheet.rows[row]![column]!
                let ref = XLSXWriter.columnName(column) + String(row)
                let type: String
                let value: String
                switch cell.value {
                case .number(let number):
                    guard number.isFinite else { throw APIError.invalid }
                    type = ""; value = "<v>\(number)</v>"
                case .text(let text):
                    type = cell.formula == nil ? " t=\"inlineStr\"" : " t=\"str\""
                    value = cell.formula == nil ? "<is><t xml:space=\"preserve\">\(escape(text))</t></is>" : "<v>\(escape(text))</v>"
                }
                let style = cell.formula == nil && { if case .text(let text) = cell.value { return ExportFormat.isFormulaRisk(text) }; return false }() ? Style.quoted : cell.style
                result += "<c r=\"\(ref)\" s=\"\(style.rawValue)\"\(type)>"
                if let formula = cell.formula { result += "<f>\(escape(formula))</f>" }
                result += value + "</c>"
            }
            result += "</row>"
        }
        return result + "</sheetData></worksheet>"
    }
    static var styles: String {
        let formats = ["[h]:mm", "[hh]:mm;@", "0.0", "[$-F800]dddd\\,\\ mmmm\\ dd\\,\\ yyyy", "h:mm;@"]
        let numberFormats = formats.enumerated().map { "<numFmt numFmtId=\"\(164 + $0.offset)\" formatCode=\"\(escape($0.element))\"/>" }.joined()
        let ids = [0, 0, 167, 168, 164, 165, 166, 49, 164, 165, 166]
        let cells = ids.enumerated().map { index, id in
            "<xf numFmtId=\"\(id)\" fontId=\"\((index == 1 || index >= 8) ? 1 : 0)\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\" applyFont=\"1\"\(index == 7 ? " quotePrefix=\"1\"" : "")/>"
        }.joined()
        return "<styleSheet xmlns=\"\(main)\"><numFmts count=\"5\">\(numberFormats)</numFmts><fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border/></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"11\">\(cells)</cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
    }
}
