import Foundation

public struct ConfigurationError: Error, CustomStringConvertible, Sendable {
    public let key: String
    public let reason: String
    public var description: String { "Invalid configuration for \(key): \(reason)" }
}

public struct Configuration: Sendable {
    public enum Driver: String, Sendable { case mariadb, sqlite }
    public enum TLS: String, Sendable { case off, required }
    public let databaseDriver: Driver
    public let dbHost: String
    public let dbPort: Int
    public let dbName: String
    public let dbUser: String
    public let dbPassword: String
    public let dbTLS: TLS
    public let sqlitePath: String
    public let webAuthnRPID: String
    public let webAuthnRPName: String
    public let webAuthnOrigin: URL
    public let publicBaseURL: URL
    public let sessionTTLHours: Int
    public let autoMigrate: Bool

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        func value(_ key: String, _ fallback: String) throws -> String {
            let result = environment[key] ?? fallback
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigurationError(key: key, reason: "must not be empty")
            }
            return result
        }
        func integer(_ key: String, _ fallback: String, _ range: ClosedRange<Int>) throws -> Int {
            guard let result = Int(environment[key] ?? fallback), range.contains(result) else {
                throw ConfigurationError(key: key, reason: "must be an integer in \(range)")
            }
            return result
        }
        func url(_ key: String, _ fallback: String, origin: Bool = false) throws -> URL {
            let raw = try value(key, fallback)
            guard let parts = URLComponents(string: raw), let host = parts.host, !host.isEmpty,
                  let scheme = parts.scheme, ["http", "https"].contains(scheme),
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  parts.port.map({ (1...65535).contains($0) }) ?? true,
                  !origin || parts.path.isEmpty || parts.path == "/",
                  scheme == "https" || ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host),
                  let result = parts.url else {
                throw ConfigurationError(key: key, reason: "must be an HTTPS URL (HTTP allowed on loopback), without credentials, query or fragment")
            }
            return result
        }
        guard let driver = Driver(rawValue: environment["DATABASE_DRIVER"] ?? "sqlite") else {
            throw ConfigurationError(key: "DATABASE_DRIVER", reason: "expected mariadb or sqlite")
        }
        databaseDriver = driver
        dbHost = try value("DB_HOST", "127.0.0.1")
        dbPort = try integer("DB_PORT", "3306", 1...65535)
        dbName = try value("DB_NAME", "timetrack")
        dbUser = try value("DB_USER", "timetrack")
        dbPassword = environment["DB_PASSWORD"] ?? ""
        if driver == .mariadb && environment["DB_PASSWORD"] == nil {
            throw ConfigurationError(key: "DB_PASSWORD", reason: "must be explicitly set for mariadb (may be empty locally)")
        }
        guard let tls = TLS(rawValue: environment["DB_TLS"] ?? "required") else {
            throw ConfigurationError(key: "DB_TLS", reason: "expected off or required")
        }
        dbTLS = tls
        sqlitePath = try value("SQLITE_PATH", "timetrack.sqlite")
        webAuthnRPID = try value("WEBAUTHN_RP_ID", "localhost")
        guard webAuthnRPID == webAuthnRPID.lowercased(),
              webAuthnRPID.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else {
            throw ConfigurationError(key: "WEBAUTHN_RP_ID", reason: "must be a lowercase hostname")
        }
        webAuthnRPName = try value("WEBAUTHN_RP_NAME", "Timetrack")
        webAuthnOrigin = try url("WEBAUTHN_ORIGIN", "http://localhost:18080", origin: true)
        guard let originHost = webAuthnOrigin.host,
              originHost == webAuthnRPID || originHost.hasSuffix("." + webAuthnRPID) else {
            throw ConfigurationError(key: "WEBAUTHN_ORIGIN", reason: "host must match RP ID or its subdomain")
        }
        publicBaseURL = try url("PUBLIC_BASE_URL", "http://localhost:18080")
        sessionTTLHours = try integer("SESSION_TTL_HOURS", "720", 1...8760)
        switch environment["AUTO_MIGRATE"] ?? "false" {
        case "true": autoMigrate = true
        case "false": autoMigrate = false
        default: throw ConfigurationError(key: "AUTO_MIGRATE", reason: "expected true or false")
        }
    }
}
