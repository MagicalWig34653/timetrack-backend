import Foundation
import Vapor
import ZIPFoundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A parsed cell. CSV cells are always text; XLSX cells keep their stored kind so that dates, fractions and
/// decimal hours can be told apart by the interpreter. Formulas are never evaluated.
enum ImportCellStyle: Sendable, Equatable { case plain, date, time, dateTime }
enum ImportCell: Sendable, Equatable {
    case empty
    case text(String)
    case number(String, ImportCellStyle)
    case bool(Bool)
    case formulaWithoutValue
}

struct ImportSheet: Sendable {
    var name: String
    var rows: [[ImportCell]]
    var date1904: Bool
}

enum ImportErrors {
    static let unsupported = APIError(.unsupportedMediaType, "unsupported_type")
    static let tooLarge = APIError(.payloadTooLarge, "file_too_large")
    static let tooManyRows = APIError(.badRequest, "too_many_rows")
}

/// A validated upload. CSV is parsed eagerly (it is needed for validation anyway); XLSX sheets lazily.
struct ImportWorkbook: Sendable {
    enum Storage: Sendable { case csv([[ImportCell]]), xlsx(Data) }
    let kind: String
    let sheetNames: [String]
    let storage: Storage

    static let csvSheetName = "CSV"

    static func open(data: Data, filename: String) throws -> ImportWorkbook {
        guard !data.isEmpty else { throw APIError.invalid }
        guard data.count <= ImportLimits.maxFileBytes else { throw ImportErrors.tooLarge }
        let ext = (filename as NSString).pathExtension.lowercased()
        let isZip = data.starts(with: [0x50, 0x4B, 0x03, 0x04])
        if ext == "xlsx" {
            guard isZip else { throw ImportErrors.unsupported }
            let package = try XLSXPackage(data: data)
            return .init(kind: "xlsx", sheetNames: try package.sheetNames(), storage: .xlsx(data))
        }
        guard ["csv", "txt", "tsv"].contains(ext), !isZip else { throw ImportErrors.unsupported }
        let rows = try CSVReader.read(data).map { $0.map { $0.isEmpty ? ImportCell.empty : .text($0) } }
        return .init(kind: "csv", sheetNames: [csvSheetName], storage: .csv(rows))
    }

    func sheet(_ name: String) throws -> ImportSheet {
        switch storage {
        case .csv(let rows): return .init(name: ImportWorkbook.csvSheetName, rows: rows, date1904: false)
        case .xlsx(let data): return try XLSXPackage(data: data).sheet(named: name)
        }
    }
}

// MARK: CSV

enum CSVReader {
    /// Decodes bytes (UTF-8 with or without BOM, UTF-16 with BOM, ISO-8859-1 fallback) into UTF-8 bytes.
    static func decode(_ data: Data) throws -> [UInt8] {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return Array(bytes.dropFirst(3)) }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data, encoding: .utf16) else { throw ImportErrors.unsupported }
            return Array(text.utf8).stripBOM()
        }
        // Control characters other than tab, LF and CR indicate binary content (PDF, images, ...).
        for byte in bytes where byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D { throw ImportErrors.unsupported }
        if let text = String(data: data, encoding: .utf8) { return Array(text.utf8) }
        guard let text = String(data: data, encoding: .isoLatin1) else { throw ImportErrors.unsupported }
        return Array(text.utf8)
    }

    static func read(_ data: Data) throws -> [[String]] {
        let bytes = try decode(data)
        return try parse(bytes, delimiter: detectDelimiter(bytes))
    }

    static func detectDelimiter(_ bytes: [UInt8]) -> UInt8 {
        // Parsing stops at a complete record, including quoted multiline fields.
        let sample = bytes
        var best: (score: Int, delimiter: UInt8) = (0, UInt8(ascii: ","))
        for delimiter in [UInt8(ascii: ";"), 0x09, UInt8(ascii: ",")] {
            guard let rows = try? parse(sample, delimiter: delimiter, maxRows: 40, sampleOnly: true) else { continue }
            let counts = rows.filter { !($0.count == 1 && $0[0].isEmpty) }.map(\.count)
            let histogram = Dictionary(counts.map { ($0, 1) }, uniquingKeysWith: +)
            guard let modal = histogram.max(by: { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }), modal.key >= 2 else { continue }
            if modal.value > best.score { best = (modal.value, delimiter) }
        }
        return best.delimiter
    }

    /// RFC 4180 with CR, LF and CRLF line ends. Works on UTF-8 bytes because all structural characters are ASCII.
    static func parse(_ bytes: [UInt8], delimiter: UInt8, maxRows: Int = ImportLimits.maxRows, sampleOnly: Bool = false) throws -> [[String]] {
        let quote = UInt8(ascii: "\""), cr: UInt8 = 0x0D, lf: UInt8 = 0x0A
        var rows: [[String]] = [], row: [String] = [], field: [UInt8] = []
        var inQuotes = false, quoted = false
        var index = 0
        func endField() throws {
            row.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true); quoted = false
            if row.count > ImportLimits.maxColumns { throw APIError.invalid }
        }
        func endRow() throws {
            try endField(); rows.append(row); row = []
            if rows.count > maxRows { throw ImportErrors.tooManyRows }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if inQuotes {
                if byte == quote {
                    if index + 1 < bytes.count, bytes[index + 1] == quote { field.append(quote); index += 2; continue }
                    inQuotes = false
                } else { field.append(byte) }
            } else if byte == quote && field.isEmpty && !quoted {
                inQuotes = true; quoted = true
            } else if byte == delimiter {
                try endField()
            } else if byte == cr || byte == lf {
                try endRow()
                if sampleOnly && rows.count == maxRows { return rows }
                if byte == cr, index + 1 < bytes.count, bytes[index + 1] == lf { index += 1 }
            } else { field.append(byte) }
            index += 1
        }
        if inQuotes { throw APIError.invalid }
        if !field.isEmpty || quoted || !row.isEmpty { try endRow() }
        return rows
    }
}

private extension Array where Element == UInt8 {
    /// Removes a leading U+FEFF (EF BB BF in UTF-8) that survives UTF-16 decoding.
    func stripBOM() -> [UInt8] { starts(with: [0xEF, 0xBB, 0xBF]) ? Array(dropFirst(3)) : self }
}

// MARK: XLSX

/// Read-only access to an XLSX package with ZIP-bomb protection (entry count, uncompressed size, paths).
final class XLSXPackage {
    private let archive: Archive
    private var entries: [String: Entry] = [:]
    private var budget = ImportLimits.maxUncompressedBytes

    init(data: Data) throws {
        do { archive = try Archive(data: data, accessMode: .read, pathEncoding: nil) } catch { throw ImportErrors.unsupported }
        var count = 0, total: UInt64 = 0
        for entry in archive {
            count += 1
            guard count <= ImportLimits.maxZipEntries else { throw ImportErrors.tooLarge }
            try Self.validate(path: entry.path)
            guard entry.type != .symlink else { throw ImportErrors.unsupported }
            guard entry.uncompressedSize <= UInt64(ImportLimits.maxUncompressedBytes) - total else { throw ImportErrors.tooLarge }
            total += entry.uncompressedSize
            entries[entry.path] = entry
        }
        guard entries["xl/workbook.xml"] != nil else { throw ImportErrors.unsupported }
    }

    static func validate(path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 512, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 }),
              !components.contains("..") else { throw ImportErrors.unsupported }
    }

    func read(_ path: String) throws -> Data? {
        guard let entry = entries[path] else { return nil }
        guard entry.type == .file else { throw ImportErrors.unsupported }
        var out = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                budget -= chunk.count
                guard budget >= 0 else { throw ImportErrors.tooLarge }
                out.append(chunk)
            }
        } catch let error as APIError { throw error } catch { throw ImportErrors.unsupported }
        if out.range(of: Data("<!DOCTYPE".utf8)) != nil || out.range(of: Data("<!ENTITY".utf8)) != nil { throw ImportErrors.unsupported }
        return out
    }

    private struct Workbook { var sheets: [(name: String, rid: String)] = []; var date1904 = false }

    private func workbook() throws -> Workbook {
        guard let data = try read("xl/workbook.xml") else { throw ImportErrors.unsupported }
        let delegate = WorkbookDelegate()
        try XMLRun.parse(data, delegate)
        return .init(sheets: delegate.sheets, date1904: delegate.date1904)
    }

    func sheetNames() throws -> [String] {
        let names = try workbook().sheets.map(\.name)
        guard !names.isEmpty else { throw ImportErrors.unsupported }
        return names
    }

    func sheet(named name: String) throws -> ImportSheet {
        let book = try workbook()
        guard let sheet = book.sheets.first(where: { $0.name == name }) else { throw APIError.invalid }
        var targets: [String: String] = [:]
        if let rels = try read("xl/_rels/workbook.xml.rels") {
            let delegate = RelationshipDelegate(); try XMLRun.parse(rels, delegate); targets = delegate.targets
        }
        guard let target = targets[sheet.rid], let path = Self.resolve(target), let sheetData = try read(path) else { throw ImportErrors.unsupported }
        var shared: [String] = []
        if let data = try read("xl/sharedStrings.xml") {
            let delegate = SharedStringsDelegate(); try XMLRun.parse(data, delegate); shared = delegate.strings
        }
        var styles: [ImportCellStyle] = []
        if let data = try read("xl/styles.xml") {
            let delegate = StylesDelegate(); try XMLRun.parse(data, delegate); styles = delegate.styles
        }
        let delegate = SheetDelegate(shared: shared, styles: styles)
        try XMLRun.parse(sheetData, delegate)
        if delegate.tooManyRows { throw ImportErrors.tooManyRows }
        return .init(name: name, rows: delegate.result(), date1904: book.date1904)
    }

    /// Relationship targets are relative to `xl/` unless absolute; anything escaping the package is rejected.
    static func resolve(_ target: String) -> String? {
        var parts: [String] = target.hasPrefix("/") ? [] : ["xl"]
        for part in target.split(separator: "/", omittingEmptySubsequences: true) {
            if part == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast() }
            else if part != "." { parts.append(String(part)) }
        }
        let path = parts.joined(separator: "/")
        return (try? validate(path: path)) == nil ? nil : path
    }
}

enum XMLRun {
    static func parse(_ data: Data, _ delegate: XMLParserDelegate) throws {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        if !parser.parse() {
            if let abort = delegate as? AbortingDelegate, abort.aborted { return }
            throw ImportErrors.unsupported
        }
    }
    static func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }
    static func attributes(_ raw: [String: String]) -> [String: String] {
        Dictionary(raw.map { (local($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}

protocol AbortingDelegate: AnyObject { var aborted: Bool { get } }

private final class WorkbookDelegate: NSObject, XMLParserDelegate {
    var sheets: [(name: String, rid: String)] = []
    var date1904 = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes raw: [String: String]) {
        let attributes = XMLRun.attributes(raw)
        switch XMLRun.local(elementName) {
        case "sheet": if let name = attributes["name"], let rid = attributes["id"] { sheets.append((name, rid)) }
        case "workbookPr": date1904 = ["1", "true"].contains(attributes["date1904"] ?? "")
        default: break
        }
    }
}

private final class RelationshipDelegate: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes raw: [String: String]) {
        guard XMLRun.local(elementName) == "Relationship", let id = raw["Id"], let target = raw["Target"] else { return }
        targets[id] = target
    }
}

private final class SharedStringsDelegate: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var stack: [String] = []
    private var current = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let name = XMLRun.local(elementName); stack.append(name)
        if name == "si" { current = "" }
        if strings.count > 200_000 { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if stack.last == "t", !stack.contains("rPh") { current += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if XMLRun.local(elementName) == "si" { strings.append(current) }
        _ = stack.popLast()
    }
}

private final class StylesDelegate: NSObject, XMLParserDelegate {
    var styles: [ImportCellStyle] = []
    private var formats: [Int: String] = [:]
    private var inCellXfs = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch XMLRun.local(elementName) {
        case "numFmt": if let id = attributes["numFmtId"].flatMap(Int.init), let code = attributes["formatCode"] { formats[id] = code }
        case "cellXfs": inCellXfs = true
        case "xf": if inCellXfs { styles.append(Self.classify(attributes["numFmtId"].flatMap(Int.init) ?? 0, formats)) }
        default: break
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if XMLRun.local(elementName) == "cellXfs" { inCellXfs = false }
    }
    static func classify(_ id: Int, _ custom: [Int: String]) -> ImportCellStyle {
        switch id {
        case 14...17, 27...31, 34...36, 50...58: return .date
        case 18...21, 45...47: return .time
        case 22: return .dateTime
        default: break
        }
        guard let code = custom[id] else { return .plain }
        var stripped = ""; var quoted = false; var bracket = false; var escaped = false
        for character in code.lowercased() {
            if escaped { escaped = false; continue }
            if character == "\\" || character == "_" || character == "*" { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            if character == "[" { bracket = true; continue }
            if character == "]" { bracket = false; continue }
            if !quoted && !bracket { stripped.append(character) }
        }
        let dateLike = stripped.contains("y") || stripped.contains("d")
        let timeLike = stripped.contains("h") || stripped.contains("s")
        if stripped.contains("general") && !dateLike && !timeLike { return .plain }
        switch (dateLike, timeLike) {
        case (true, true): return .dateTime
        case (true, false): return .date
        case (false, true): return .time
        default: return stripped.contains("m") && !stripped.contains("0") && !stripped.contains("#") ? .date : .plain
        }
    }
}

private final class SheetDelegate: NSObject, XMLParserDelegate, AbortingDelegate {
    let shared: [String], styles: [ImportCellStyle]
    var tooManyRows = false
    var aborted: Bool { tooManyRows }
    private var rows: [Int: [Int: ImportCell]] = [:]
    private var rowNumber = 0, nextRow = 1
    private var column = 0, nextColumn = 0
    private var type = "", style = ImportCellStyle.plain
    private var hasFormula = false
    private var value = "", inline = ""
    private var stack: [String] = []

    init(shared: [String], styles: [ImportCellStyle]) { self.shared = shared; self.styles = styles }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes raw: [String: String]) {
        let name = XMLRun.local(elementName); stack.append(name)
        let attributes = XMLRun.attributes(raw)
        switch name {
        case "row":
            if let raw = attributes["r"] {
                guard let number = Int(raw), (1...ImportLimits.maxRows).contains(number) else {
                    tooManyRows = true; parser.abortParsing(); return
                }
                rowNumber = number
            } else { rowNumber = nextRow }
            guard rowNumber <= ImportLimits.maxRows else { tooManyRows = true; parser.abortParsing(); return }
            nextRow = rowNumber + 1; nextColumn = 0
        case "c":
            column = attributes["r"].flatMap(Self.columnIndex) ?? nextColumn; nextColumn = column + 1
            type = attributes["t"] ?? ""
            style = attributes["s"].flatMap(Int.init).flatMap { styles.indices.contains($0) ? styles[$0] : nil } ?? .plain
            hasFormula = false; value = ""; inline = ""
        case "f": hasFormula = true
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard stack.last == "v" || (stack.last == "t" && stack.contains("is") && !stack.contains("rPh")) else { return }
        if stack.last == "v" { value += string } else { inline += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        defer { _ = stack.popLast() }
        guard XMLRun.local(elementName) == "c" else { return }
        let cell = build()
        guard cell != .empty, column < ImportLimits.maxColumns else { return }
        if rowNumber > ImportLimits.maxRows || rowNumber < 1 { tooManyRows = true; parser.abortParsing(); return }
        rows[rowNumber, default: [:]][column] = cell
    }
    private func build() -> ImportCell {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasFormula && raw.isEmpty && type != "inlineStr" { return .formulaWithoutValue }
        switch type {
        case "s":
            guard let index = Int(raw), shared.indices.contains(index), !shared[index].isEmpty else { return .empty }
            return .text(shared[index])
        case "str", "e", "d": return value.isEmpty ? .empty : .text(value)
        case "inlineStr": return inline.isEmpty ? .empty : .text(inline)
        case "b": return .bool(raw == "1" || raw == "true")
        default: return raw.isEmpty ? .empty : .number(raw, style)
        }
    }
    func result() -> [[ImportCell]] {
        guard let last = rows.keys.max() else { return [] }
        return (1...last).map { number in
            guard let cells = rows[number], let width = cells.keys.max() else { return [] }
            return (0...width).map { cells[$0] ?? .empty }
        }
    }
    static func columnIndex(_ reference: String) -> Int? {
        var value = 0, seen = false
        for scalar in reference.unicodeScalars {
            guard (65...90).contains(scalar.value) || (97...122).contains(scalar.value) else { break }
            value = value * 26 + Int(scalar.value & 31); seen = true
            if value > 1_000_000 { return nil }
        }
        return seen ? value - 1 : nil
    }
}
