import Foundation

/// Optional OpenID Connect settings (ADR-0007). `nil` in `Configuration.oidc` means OIDC is off.
public struct OIDCConfiguration: Sendable {
    public let issuer: String
    public let clientID: String
    public let clientSecret: String?
    public let name: String
    public let scopes: [String]

    /// Returns `nil` when neither OIDC_ISSUER nor OIDC_CLIENT_ID is set. Setting only one of them is a configuration error.
    public init?(environment: [String: String]) throws {
        func trimmed(_ key: String) -> String? {
            let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }
        let issuer = trimmed("OIDC_ISSUER"), clientID = trimmed("OIDC_CLIENT_ID")
        if issuer == nil && clientID == nil { return nil }
        guard let issuer else { throw ConfigurationError(key: "OIDC_ISSUER", reason: "required when OIDC_CLIENT_ID is set") }
        guard let clientID else { throw ConfigurationError(key: "OIDC_CLIENT_ID", reason: "required when OIDC_ISSUER is set") }
        guard OIDCConfiguration.isAllowedEndpoint(issuer, allowQuery: false) else {
            throw ConfigurationError(key: "OIDC_ISSUER", reason: "must be an HTTPS URL (HTTP allowed on loopback), without credentials, query or fragment")
        }
        guard clientID.count <= 255, !clientID.contains(where: { $0.isWhitespace }) else {
            throw ConfigurationError(key: "OIDC_CLIENT_ID", reason: "must not contain whitespace and at most 255 characters")
        }
        let scopes = (trimmed("OIDC_SCOPES") ?? "openid email profile").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard scopes.contains("openid") else { throw ConfigurationError(key: "OIDC_SCOPES", reason: "must contain openid") }
        let name = trimmed("OIDC_NAME") ?? "OpenID Connect"
        guard name.count <= 80 else { throw ConfigurationError(key: "OIDC_NAME", reason: "at most 80 characters") }
        self.issuer = issuer
        self.clientID = clientID
        self.clientSecret = trimmed("OIDC_CLIENT_SECRET")
        self.name = name
        self.scopes = scopes
    }

    /// HTTPS, or HTTP for loopback test providers. No credentials or fragment; query only where allowed.
    static func isAllowedEndpoint(_ raw: String, allowQuery: Bool) -> Bool {
        guard raw.count <= 2048, let parts = URLComponents(string: raw), let host = parts.host, !host.isEmpty,
              let scheme = parts.scheme, ["http", "https"].contains(scheme),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              allowQuery || parts.query == nil,
              scheme == "https" || ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host) else { return false }
        return true
    }
}
