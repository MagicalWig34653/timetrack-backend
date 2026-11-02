import Foundation

/// One rule for every optional feature (ENV-STACK):
/// - An empty (or blank) variable is the same as an unset one; it never causes a start or parse error.
/// - A secret file that only holds the placeholder marker (see `placeholderMarker`) is the same as an unset one.
/// - Every optional feature may have a `<FEATURE>_ENABLED` switch: `true` = must run (incomplete configuration is a start error),
///   `false` = off whatever else is set, empty or `auto` = on exactly when the required variables are set (the behaviour
///   before the switches existed).
enum EnvironmentSanitizer {
    /// Content of the placeholder secrets that `deploy/swarm/create-secrets.sh` creates for optional features. Docker secrets
    /// cannot be empty, so a marker stands for "not configured". Must match scripts/docker-entrypoint.sh and create-secrets.sh.
    static let placeholderMarker = "TIMETRACK_PLACEHOLDER_UNSET"
    /// Variables where an empty value is meaningful: MariaDB accepts an empty password on local setups.
    static let keepEmpty: Set<String> = ["DB_PASSWORD"]

    /// The environment without empty, blank and placeholder values.
    static func sanitized(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, value in
            if keepEmpty.contains(key) { return true }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != placeholderMarker
        }
    }

    /// One variable of the process environment with the same rules (nil = unset, empty or placeholder).
    static func processValue(_ key: String) -> String? { sanitized([key: ProcessInfo.processInfo.environment[key] ?? ""])[key] }
}

enum FeatureMode: Sendable, Equatable {
    case automatic, enabled, disabled

    /// Reads `<key>` (`true`, `false`, `auto` or empty, case-insensitive) from an already sanitized environment.
    static func read(_ key: String, in environment: [String: String]) throws -> FeatureMode {
        switch environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "auto": return .automatic
        case "true": return .enabled
        case "false": return .disabled
        default: throw ConfigurationError(key: key, reason: "expected true, false, auto or empty")
        }
    }
}

/// Outcome of one feature decision for the start-up overview. `detail` never contains secret values.
public struct FeatureStatus: Sendable, Equatable {
    public let name: String
    public let enabled: Bool
    public let detail: String
    public var logLine: String { "feature \(name): \(enabled ? "ON" : "off") (\(detail))" }
    static func on(_ name: String, _ detail: String) -> FeatureStatus { FeatureStatus(name: name, enabled: true, detail: detail) }
    static func off(_ name: String, _ detail: String) -> FeatureStatus { FeatureStatus(name: name, enabled: false, detail: detail) }
}

extension FeatureStatus {
    /// "<KEY>=false" or "<KEY> empty" style reason for a feature that is off.
    static func offBySwitch(_ name: String, _ key: String) -> FeatureStatus { .off(name, "\(key)=false") }
}

enum FeatureSummary {
    static let header = "feature overview (set <FEATURE>_ENABLED=true|false to force; empty = automatic; docs/installation/konfiguration.md)"
    static func lines(_ statuses: [FeatureStatus]) -> [String] { statuses.map(\.logLine) }
}
