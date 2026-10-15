import Fluent
import Foundation

/// Connects the MCP endpoint to the OAuth/personal-token credential store (packages C16 and C17).
struct OAuthMcpAuthenticator: McpAuthenticator {
    var disabledModules: Set<ModuleKey> = []
    func authenticate(token: String, db: any Database) async throws -> McpAuthPrincipal? {
        guard let principal = try await authenticateMcpBearer(token, on: db, disabledModules: disabledModules) else { return nil }
        let kind: McpAuthPrincipal.Kind = principal.credentialKind == .personal ? .personal : .oauthAccess
        return McpAuthPrincipal(accountId: principal.accountId, scopes: principal.scopes, credentialKind: kind, credentialId: principal.credentialId)
    }
}
