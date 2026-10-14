import Vapor
import Fluent
import FluentSQL
import FluentMySQLDriver

/// RFC 6749 section 5.2 error (also used for registration and pre-redirect authorization errors).
struct OAuthError: Error, Sendable {
    let status: HTTPResponseStatus
    let code: String
    let description: String
    init(_ code: String, _ description: String, status: HTTPResponseStatus = .badRequest) {
        self.code = code; self.description = description; self.status = status
    }
    struct Body: Content { let error: String; let error_description: String }
    var body: Body { Body(error: code, error_description: description) }
}

extension OAuthService {
    /// The public origin without trailing slash; used as issuer.
    var issuer: String {
        var value = auth.configuration.publicBaseURL.absoluteString
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
    var resource: String { issuer + "/mcp" }
}

/// One conditional write followed by an affected-row count on the same connection (see `SingleUse`).
func conditionalWrite(on database: any Database, _ write: @Sendable @escaping (any Database) async throws -> Void) async throws -> Bool {
    try await database.withConnection { connection in
        try await write(connection)
        let row = try await requireSQL(connection).raw(connection is any MySQLDatabase
            ? "SELECT ROW_COUNT() AS affected" : "SELECT changes() AS affected").first()
        guard let row else { throw DatabaseSupportError.missingAffectedRowCount }
        return try row.decode(column: "affected", as: Int.self) == 1
    }
}

enum OAuthText {
    /// Removes control characters and markup brackets, collapses whitespace and trims.
    static func sanitizedName(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "<" && $0 != ">" && $0 != "\u{200B}" }
        return String(String.UnicodeScalarView(cleaned)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func isBase64URL(_ value: String, count: ClosedRange<Int>) -> Bool {
        count.contains(value.count) && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 }
    }
    static func isVerifier(_ value: String) -> Bool {
        (43...128).contains(value.count) && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || [45, 46, 95, 126].contains($0) }
    }
    static func parseScopes(_ raw: String?) -> [String] {
        var seen = Set<String>()
        return (raw ?? "").split(whereSeparator: { $0 == " " }).map(String.init).filter { seen.insert($0).inserted }
    }
}

/// Redirect URI rules of ADR-0009: https, or http on loopback; no fragment, wildcard or credentials.
func validOAuthRedirectURI(_ raw: String) -> Bool {
    guard raw.count <= 2048, !raw.contains("*"), raw.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
          let parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(), let host = parts.host, !host.isEmpty,
          parts.fragment == nil, parts.user == nil, parts.password == nil else { return false }
    if scheme == "https" { return true }
    return scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())
}
