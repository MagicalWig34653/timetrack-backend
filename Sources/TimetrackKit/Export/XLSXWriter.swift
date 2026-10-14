import Foundation
import ZIPFoundation

/// Hand written minimal OOXML spreadsheet. Only values are written, never formulas (ADR-0006).
/// Strings are inline strings; durations are day fractions with the `[h]:mm` format.
enum XLSXWriter {
    // Style indices into `styles.xml` cellXfs.
    private enum Style: Int {
        case normal = 0, header, date, time, duration, signed, quotePrefix, title, boldText, boldDuration, boldSigned, group, note
    }
    static let sheetName = "Zeitnachweis"

    static func write(_ document: ExportDocument) throws -> Data {
        let archive = try Archive(accessMode: .create)
        let parts: [(String, String)] = [
            ("[Content_Types].xml", contentTypes),
            ("_rels/.rels", rootRels),
            ("xl/workbook.xml", workbook(headerRows: headerRowNumber(document))),
            ("xl/_rels/workbook.xml.rels", workbookRels),
            ("xl/styles.xml", styles),
            ("xl/worksheets/sheet1.xml", sheet(document))
        ]
        let stamp = document.createdAt
        for (path, xml) in parts {
            let data = Data(xml.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), modificationDate: stamp,
                                 compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        guard let result = archive.data else { throw APIError(.internalServerError, "not_ready") }
        return result
    }

    // MARK: Parts

    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private static let contentTypes = header + """
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
    """
    private static let rootRels = header + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
    """
    private static let workbookRels = header + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
    """
    private static func workbook(headerRows: Int) -> String {
        header + """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\(sheetName)" sheetId="1" r:id="rId1"/></sheets><definedNames><definedName name="_xlnm.Print_Titles" localSheetId="0">\(sheetName)!$\(headerRows - 1):$\(headerRows)</definedName></definedNames></workbook>
        """
    }
    private static let styles = header + """
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="4"><numFmt numFmtId="164" formatCode="[h]:mm"/><numFmt numFmtId="165" formatCode="dd\\.mm\\.yyyy"/><numFmt numFmtId="166" formatCode="+[h]:mm;\\-[h]:mm;[h]:mm"/><numFmt numFmtId="167" formatCode="hh:mm"/></numFmts><fonts count="4"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="14"/><name val="Calibri"/></font><font><i/><sz val="10"/><color rgb="FF595959"/><name val="Calibri"/></font></fonts><fills count="4"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFD9D9D9"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFDDEBF7"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left/><right/><top/><bottom style="thin"><color auto="1"/></bottom><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="13"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf><xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyAlignment="1"><alignment horizontal="left"/></xf><xf numFmtId="167" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" quotePrefix="1"/><xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="164" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/><xf numFmtId="166" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/><xf numFmtId="0" fontId="1" fillId="3" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment horizontal="center"/></xf><xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
    """

    // MARK: Sheet

    /// Rows: 1 title, 2 name, 3 period, 4 blank, 5 group band, 6 column titles.
    private static func headerRowNumber(_ document: ExportDocument) -> Int { 6 }

    static func columnName(_ index: Int) -> String {
        var n = index + 1; var name = ""
        while n > 0 { name = String(UnicodeScalar(UInt8(65 + (n - 1) % 26))) + name; n = (n - 1) / 26 }
        return name
    }

    /// Removes characters that are not allowed in XML 1.0 and escapes markup; tab and CR are kept as character references.
    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09: out += "&#9;"
            case 0x0A: out += "&#10;"
            case 0x0D: out += "&#13;"
            case 0x00..<0x20, 0xD800...0xDFFF, 0xFFFE, 0xFFFF: continue
            case 0x26: out += "&amp;"
            case 0x3C: out += "&lt;"
            case 0x3E: out += "&gt;"
            case 0x22: out += "&quot;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func stringCell(_ ref: String, _ text: String, style: Style) -> String {
        "<c r=\"\(ref)\" s=\"\(style.rawValue)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(text))</t></is></c>"
    }
    private static func numberCell(_ ref: String, _ value: String, style: Style) -> String {
        "<c r=\"\(ref)\" s=\"\(style.rawValue)\"><v>\(value)</v></c>"
    }
    private static func fraction(_ seconds: Int) -> String {
        if seconds == 0 { return "0" }
        let value = Double(seconds) / 86_400
        return String(format: "%.15g", value)
    }

    private static func cell(_ ref: String, _ value: ExportCell, bold: Bool) -> String? {
        switch value {
        case .empty: return nil
        case .text(let text):
            // quotePrefix marks the cell as text for spreadsheet applications; the stored value stays unchanged.
            return stringCell(ref, text, style: ExportFormat.isFormulaRisk(text) ? .quotePrefix : (bold ? .boldText : .normal))
        case .date(let date): return numberCell(ref, String(ExportFormat.excelSerial(date)), style: .date)
        case .time(let seconds): return numberCell(ref, fraction(((seconds % 86_400) + 86_400) % 86_400), style: .time)
        case .duration(let seconds): return numberCell(ref, fraction(seconds), style: bold ? .boldDuration : .duration)
        case .signed(let seconds): return numberCell(ref, fraction(seconds), style: bold ? .boldSigned : .signed)
        }
    }

    private static func row(_ number: Int, _ cells: [(Int, String)], height: Int? = nil) -> String {
        let attributes = height.map { " ht=\"\($0)\" customHeight=\"1\"" } ?? ""
        return "<row r=\"\(number)\"\(attributes)>" + cells.sorted { $0.0 < $1.0 }.map(\.1).joined() + "</row>"
    }

    private static func sheet(_ document: ExportDocument) -> String {
        let headerRow = headerRowNumber(document)
        let columnCount = document.columns.count
        var rows: [String] = []
        rows.append(row(1, [(0, stringCell("A1", document.title, style: .title))]))
        rows.append(row(2, [(0, stringCell("A2", "Name", style: .boldText))]
            + [cell("B2", .text(document.accountName), bold: false)].compactMap { $0 }.map { (1, $0) }))
        rows.append(row(3, [(0, stringCell("A3", "Zeitraum", style: .boldText)), (1, stringCell("B3", document.periodText, style: .normal))]))
        var band: [(Int, String)] = []
        for group in document.groups {
            for index in group.first...group.last {
                let ref = columnName(index) + String(headerRow - 1)
                band.append((index, index == group.first ? stringCell(ref, group.title, style: .group)
                    : "<c r=\"\(ref)\" s=\"\(Style.group.rawValue)\"/>"))
            }
        }
        rows.append(row(headerRow - 1, band))
        rows.append(row(headerRow, document.columns.enumerated().map { index, column in
            (index, stringCell(columnName(index) + String(headerRow), column.title, style: .header))
        }, height: 45))
        var number = headerRow
        for values in document.rows {
            number += 1
            rows.append(row(number, values.enumerated().compactMap { index, value in
                cell(columnName(index) + String(number), value, bold: false).map { (index, $0) }
            }))
        }
        number += 1
        rows.append(row(number, document.totals.enumerated().compactMap { index, value in
            cell(columnName(index) + String(number), value, bold: true).map { (index, $0) }
        }))
        number += 2
        rows.append(row(number, [(0, stringCell("A\(number)", document.createdText, style: .note))]))

        let totalWeight = document.columns.reduce(0) { $0 + $1.weight }
        let columns = document.columns.enumerated().map { index, column in
            let width = max(8, (column.weight / totalWeight) * Double(columnCount) * 13)
            return "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(String(format: "%.1f", width))\" customWidth=\"1\"/>"
        }.joined()
        let merges = document.groups.filter { $0.last > $0.first }.map {
            "<mergeCell ref=\"\(columnName($0.first))\(headerRow - 1):\(columnName($0.last))\(headerRow - 1)\"/>"
        }
        let mergeXML = merges.isEmpty ? "" : "<mergeCells count=\"\(merges.count)\">" + merges.joined() + "</mergeCells>"
        let lastRef = columnName(max(columnCount - 1, 0)) + String(number)
        return header + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            + "<sheetPr><pageSetUpPr fitToPage=\"1\"/></sheetPr><dimension ref=\"A1:\(lastRef)\"/>"
            + "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"\(headerRow)\" topLeftCell=\"A\(headerRow + 1)\" activePane=\"bottomLeft\" state=\"frozen\"/>"
            + "<selection pane=\"bottomLeft\" activeCell=\"A\(headerRow + 1)\" sqref=\"A\(headerRow + 1)\"/></sheetView></sheetViews>"
            + "<sheetFormatPr defaultRowHeight=\"15\"/><cols>\(columns)</cols><sheetData>" + rows.joined() + "</sheetData>"
            + mergeXML
            + "<pageMargins left=\"0.5\" right=\"0.5\" top=\"0.6\" bottom=\"0.6\" header=\"0.3\" footer=\"0.3\"/>"
            + "<pageSetup paperSize=\"9\" orientation=\"landscape\" fitToWidth=\"1\" fitToHeight=\"0\"/></worksheet>"
    }
}
