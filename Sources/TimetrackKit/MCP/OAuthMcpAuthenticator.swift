import Fluent
import Foundation

/// Connects the MCP endpoint to the OAuth/personal-token credential store (packages C16 and C17).
struct OAuthMcpAuthenticator: McpAuthenticator {
    var disabledModules: Set<ModuleKey> = []
    func authenticate(token: String, db: any Database) async throws -> McpAuthPrincipal? {
        guard let principal = try await authenticateMcpBearer(token, on: db, disabledModules: disabledModules) else { return nil }
        let kind: McpAuthPrincipal.Kind = principal.credentialKind == .personal ? .personal : .oauthAccess
        return McpAuthPrincipal(accountId: principal.accountId, scopes: principal.scopes, credentialKind: kind, credentialId: principal.credentialId,
                                 tokenHash: principal.tokenHash)
    }

    func revalidate(_ principal: McpAuthPrincipal, db: any Database) async throws -> McpAuthPrincipal? {
        let credential = McpPrincipal(accountId: principal.accountId, scopes: principal.scopes, credentialKind: principal.credentialKind == .personal ? .personal : .oauthAccess,
                                      credentialId: principal.credentialId, tokenHash: principal.tokenHash)
        guard let fresh = try await revalidateMcpPrincipal(credential, on: db, disabledModules: disabledModules) else { return nil }
        return McpAuthPrincipal(accountId: fresh.accountId, scopes: fresh.scopes, credentialKind: principal.credentialKind, credentialId: fresh.credentialId, tokenHash: fresh.tokenHash)
    }
}
