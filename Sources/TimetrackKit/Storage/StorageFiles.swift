import Foundation

/// Whitelist (pdf, png, jpg, heic, txt) with magic-byte sniffing. The sniffed type must agree with the
/// extension and with a specific declared multipart Content-Type.
enum FileTypeSniffer {
    struct Kind: Equatable, Sendable { let ext: String; let mime: String }
    static let pdf = Kind(ext: "pdf", mime: "application/pdf")
    static let png = Kind(ext: "png", mime: "image/png")
    static let jpg = Kind(ext: "jpg", mime: "image/jpeg")
    static let heic = Kind(ext: "heic", mime: "image/heic")
    static let txt = Kind(ext: "txt", mime: "text/plain; charset=utf-8")

    private static let heicBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1"]

    static func sniff(_ data: Data) -> Kind? {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: Array("%PDF-".utf8)) { return pdf }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return png }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return jpg }
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8),
           let brand = String(bytes: bytes[8..<12], encoding: .ascii), heicBrands.contains(brand) { return heic }
        return isText(data) ? txt : nil
    }

    /// UTF-8 without NUL or control characters (except tab, LF, CR, form feed). A BOM is allowed.
    static func isText(_ data: Data) -> Bool {
        guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else { return false }
        return !data.contains { $0 < 0x20 && ![0x09, 0x0A, 0x0C, 0x0D].contains($0) || $0 == 0x7F }
    }

    static func kind(forExtension ext: String) -> Kind? {
        switch ext.lowercased() {
        case "pdf": return pdf
        case "png": return png
        case "jpg", "jpeg": return jpg
        case "heic": return heic
        case "txt": return txt
        default: return nil
        }
    }
    static func kind(forMime mime: String) -> Kind? {
        switch mime.lowercased().split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces) }) ?? "" {
        case "application/pdf": return pdf
        case "image/png": return png
        case "image/jpeg", "image/jpg": return jpg
        case "image/heic", "image/heif": return heic
        case "text/plain": return txt
        default: return nil
        }
    }

    /// Returns the verified type or nil (-> 415).
    static func verify(data: Data, filename: String, declaredMime: String?) -> Kind? {
        guard let sniffed = sniff(data) else { return nil }
        let ext = (filename as NSString).pathExtension
        if !ext.isEmpty {
            guard let byExtension = kind(forExtension: ext), byExtension == sniffed else { return nil }
        }
        if let declaredMime, !declaredMime.isEmpty, !isGeneric(declaredMime) {
            guard kind(forMime: declaredMime) == sniffed else { return nil }
        }
        return sniffed
    }
    private static func isGeneric(_ mime: String) -> Bool {
        ["application/octet-stream", "binary/octet-stream"].contains(mime.lowercased().split(separator: ";").first.map(String.init) ?? "")
    }
}

enum FilenameSanitizer {
    /// Last path component only; control characters and `/ \ : * ? " < > |` become `_`; no leading dots/spaces,
    /// no trailing dots/spaces; at most 120 scalars with the extension preserved; never empty.
    static func sanitize(_ raw: String, fallbackExtension: String? = nil) -> String {
        let component = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let forbidden: Set<Unicode.Scalar> = [":", "*", "?", "\"", "<", ">", "|"]
        var scalars = component.unicodeScalars.map { scalar -> Unicode.Scalar in
            (scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) || forbidden.contains(scalar)
             || scalar.properties.generalCategory == .format || scalar.properties.generalCategory == .lineSeparator
             || scalar.properties.generalCategory == .paragraphSeparator) ? "_" : scalar
        }
        while let first = scalars.first, first == "." || first == " " { scalars.removeFirst() }
        while let last = scalars.last, last == "." || last == " " { scalars.removeLast() }
        var name = String(String.UnicodeScalarView(scalars))
        if name.unicodeScalars.count > StorageLimits.maxFilenameScalars {
            let ext = (name as NSString).pathExtension
            let keep = ext.isEmpty || ext.unicodeScalars.count > 10 ? 0 : ext.unicodeScalars.count + 1
            let stem = String(String.UnicodeScalarView(name.unicodeScalars.prefix(StorageLimits.maxFilenameScalars - keep)))
            name = keep == 0 ? stem : stem + "." + ext
            name = String(String.UnicodeScalarView(name.unicodeScalars.prefix(StorageLimits.maxFilenameScalars)))
        }
        if name.isEmpty { name = "file" }
        if let fallbackExtension, (name as NSString).pathExtension.isEmpty { name += "." + fallbackExtension }
        return name
    }

    /// `Content-Disposition: attachment` with an ASCII fallback and an RFC 5987 UTF-8 name.
    static func contentDisposition(_ name: String) -> String {
        let ascii = String(String.UnicodeScalarView(name.unicodeScalars.map { $0.isASCII && $0 != "\"" && $0 != "\\" && $0 != "%" ? $0 : "_" }))
        var encoded = ""
        for byte in name.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"): encoded.append(Character(UnicodeScalar(byte)))
            default: encoded += String(format: "%%%02X", byte)
            }
        }
        return "attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)"
    }
}
