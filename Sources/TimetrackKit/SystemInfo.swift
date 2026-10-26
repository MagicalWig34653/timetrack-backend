import Vapor
import Fluent
import SQLKit

/// Version of contracts/openapi.yaml (`info.version`). A test compares this constant with the contract.
let apiContractVersion = "0.33.0"

/// Build metadata baked into the container image (Dockerfile build args -> ENV, ADR-0023). Local builds without
/// the build args report "dev" / "unknown".
public struct BuildInfo: Sendable, Equatable {
    public let version: String
    public let revision: String
    public let buildDate: String?

    public init(version: String = "dev", revision: String = "unknown", buildDate: String? = nil) {
        self.version = version; self.revision = revision; self.buildDate = buildDate
    }

    init(environment: [String: String]) {
        func clean(_ key: String) -> String? {
            let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : String(value.prefix(100))
        }
        self.init(version: clean("TIMETRACK_VERSION") ?? "dev", revision: clean("TIMETRACK_REVISION") ?? "unknown", buildDate: clean("TIMETRACK_BUILD_DATE"))
    }

    /// First seven characters of the revision, or the whole value for "unknown".
    public var revisionShort: String { String(revision.prefix(7)) }
}

struct HealthResponse: Content { let status: String; let version: String; let revision: String }

struct SystemInfoDTO: Content {
    struct Backend: Content {
        let version: String
        let revision: String
        let revisionShort: String
        let buildDate: String?
        let apiVersion: String
        /// Operational fields: present for administrators only (Q1 finding 2, ADR-0023 addendum); omitted for members.
        let database: String?
        let schemaMigrations: Int?
        let migrationsPending: Bool?
        let uptimeSeconds: Int?
        let replicaId: String?

        enum CodingKeys: String, CodingKey { case version, revision, revisionShort, buildDate, apiVersion, database, schemaMigrations, migrationsPending, uptimeSeconds, replicaId }
        /// `buildDate` is an explicit `null` for local builds (the contract lists the key as required).
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(version, forKey: .version); try c.encode(revision, forKey: .revision); try c.encode(revisionShort, forKey: .revisionShort)
            try c.encode(buildDate, forKey: .buildDate); try c.encode(apiVersion, forKey: .apiVersion); try c.encodeIfPresent(database, forKey: .database)
            try c.encodeIfPresent(schemaMigrations, forKey: .schemaMigrations); try c.encodeIfPresent(migrationsPending, forKey: .migrationsPending)
            try c.encodeIfPresent(uptimeSeconds, forKey: .uptimeSeconds); try c.encodeIfPresent(replicaId, forKey: .replicaId)
        }
    }
    struct PWA: Content {
        let version: String?; let revision: String?; let buildDate: String?
        enum CodingKeys: String, CodingKey { case version, revision, buildDate }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(version, forKey: .version); try c.encode(revision, forKey: .revision); try c.encode(buildDate, forKey: .buildDate)
        }
    }
    let backend: Backend
    let pwa: PWA?

    enum CodingKeys: String, CodingKey { case backend, pwa }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(backend, forKey: .backend); try c.encode(pwa, forKey: .pwa)
    }
}

enum SystemInfoService {
    /// Reads `version.json` written by the PWA build into the static directory; nil when absent or malformed.
    static func readPWA(directory: String) -> SystemInfoDTO.PWA? {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("version.json")
        guard let data = try? Data(contentsOf: url), data.count < 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func text(_ key: String) -> String? { (object[key] as? String).map { String($0.prefix(100)) } }
        let pwa = SystemInfoDTO.PWA(version: text("version"), revision: text("revision"), buildDate: text("buildDate"))
        return pwa.version == nil && pwa.revision == nil ? nil : pwa
    }

    static func make(request: Request, configuration: Configuration, startedAt: Date, includeOperational: Bool) async throws -> SystemInfoDTO {
        let info = configuration.buildInfo
        guard includeOperational else {
            return SystemInfoDTO(
                backend: .init(version: info.version, revision: info.revision, revisionShort: info.revisionShort, buildDate: info.buildDate,
                               apiVersion: apiContractVersion, database: nil, schemaMigrations: nil, migrationsPending: nil, uptimeSeconds: nil, replicaId: nil),
                pwa: readPWA(directory: configuration.pwaStaticDirectory))
        }
        let sql = try requireSQL(request.db)
        var count = 0
        if let row = try? await sql.raw("SELECT COUNT(*) AS c FROM _fluent_migrations").first() {
            count = (try? row.decode(column: "c", as: Int.self)) ?? 0
        }
        let pending = (try? await request.application.migrator.previewPrepareBatch().get().isEmpty == false) ?? false
        let hostname = ProcessInfo.processInfo.hostName
        return SystemInfoDTO(
            backend: .init(version: info.version, revision: info.revision, revisionShort: info.revisionShort, buildDate: info.buildDate,
                           apiVersion: apiContractVersion, database: configuration.databaseDriver.rawValue, schemaMigrations: count,
                           migrationsPending: pending, uptimeSeconds: max(0, Int(Date().timeIntervalSince(startedAt))), replicaId: hostname),
            pwa: readPWA(directory: configuration.pwaStaticDirectory))
    }
}
