import Vapor
import Fluent
import Crypto

struct RegistrationInput: Decodable {
    let client_name: String?
    let redirect_uris: [String]?
    let grant_types: [String]?
    let response_types: [String]?
    let token_endpoint_auth_method: String?
}
struct RegistrationOutput: Content {
    let client_id: String; let client_name: String; let redirect_uris: [String]
    let token_endpoint_auth_method: String; let grant_types: [String]; let response_types: [String]; let client_id_issued_at: Int
}
struct AuthorizeQuery: Decodable {
    let response_type: String?; let client_id: String?; let redirect_uri: String?; let code_challenge: String?
    let code_challenge_method: String?; let scope: String?; let state: String?; let resource: String?
}
struct OAuthRequestDTO: Content { let id: UUID; let clientName: String; let redirectHost: String; let scopes: [String]; let expiresAt: Date }
struct TokenForm: Decodable {
    let grant_type: String?; let code: String?; let redirect_uri: String?; let client_id: String?; let code_verifier: String?
    let refresh_token: String?; let resource: String?; let scope: String?
}
struct TokenResponse: Content, Sendable {
    let access_token: String; let token_type: String; let expires_in: Int; let refresh_token: String; let scope: String
}

/// OAuth 2.1 authorization server for MCP (ADR-0009). Authorization decisions use the account session; tokens are opaque and hashed.
struct OAuthService: Sendable {
    let auth: AuthService
    static let requestLifetime: TimeInterval = 600, codeLifetime: TimeInterval = 60
    static let accessLifetime: TimeInterval = 3600, refreshLifetime: TimeInterval = 30 * 86400

    // MARK: Metadata

    var protectedResourceMetadata: [String: JSONValue] {
        ["resource": .string(resource), "authorization_servers": .array([.string(issuer)]),
         "scopes_supported": .array(McpScopes.all.map { .string($0) }), "bearer_methods_supported": .array([.string("header")])]
    }
    var authorizationServerMetadata: [String: JSONValue] {
        ["issuer": .string(issuer), "authorization_endpoint": .string(issuer + "/oauth/authorize"), "token_endpoint": .string(issuer + "/oauth/token"),
         "registration_endpoint": .string(issuer + "/oauth/register"), "revocation_endpoint": .string(issuer + "/oauth/revoke"),
         "response_types_supported": .array([.string("code")]), "grant_types_supported": .array([.string("authorization_code"), .string("refresh_token")]),
         "code_challenge_methods_supported": .array([.string("S256")]), "token_endpoint_auth_methods_supported": .array([.string("none")]),
         "revocation_endpoint_auth_methods_supported": .array([.string("none")]), "scopes_supported": .array(McpScopes.all.map { .string($0) }),
         "authorization_response_iss_parameter_supported": .bool(true)]
    }

    // MARK: Rate limit

    /// Separate counters per purpose so registrations cannot lock out logins of the same peer.
    func limit(_ purpose: String, max: Int, ip: String, on db: any Database) async throws {
        let allowed = try await auth.transaction(on: db) { tx in
            let now = Date(), key = purpose + ":" + Secrets.hash(ip)
            if try await RateLimitEvent.query(on: tx).filter(\.$key == key).filter(\.$occurredAt > now.addingTimeInterval(-300)).count() >= max { return false }
            try await RateLimitEvent(key: key, occurredAt: now).create(on: tx)
            return true
        }
        guard allowed else { throw APIError(.tooManyRequests, "too_many_requests") }
    }

    // MARK: Registration (RFC 7591)

    func register(_ input: RegistrationInput, ip: String, on db: any Database) async throws -> RegistrationOutput {
        try await limit("oauth_register", max: 20, ip: ip, on: db)
        guard let uris = input.redirect_uris, (1...5).contains(uris.count) else {
            throw OAuthError("invalid_redirect_uri", "redirect_uris must contain 1 to 5 entries.")
        }
        guard uris.allSatisfy(validOAuthRedirectURI) else {
            throw OAuthError("invalid_redirect_uri", "Redirect URIs must be https (or loopback http) without fragment, credentials or wildcard.")
        }
        if let method = input.token_endpoint_auth_method, method != "none" {
            throw OAuthError("invalid_client_metadata", "Only public clients (token_endpoint_auth_method none) are supported.")
        }
        if let grants = input.grant_types, grants.isEmpty || !Set(grants).isSubset(of: ["authorization_code", "refresh_token"]) {
            throw OAuthError("invalid_client_metadata", "Unsupported grant_types.")
        }
        if let types = input.response_types, types != ["code"] { throw OAuthError("invalid_client_metadata", "Unsupported response_types.") }
        var name = OAuthText.sanitizedName(input.client_name ?? "")
        if name.count > 100 { throw OAuthError("invalid_client_metadata", "client_name is limited to 100 characters.") }
        let unique = uris.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if name.isEmpty { name = URLComponents(string: unique[0])?.host ?? "Client" }
        let client = OAuthClient()
        client.name = name; client.redirectURIs = unique; client.createdAt = Date()
        try await client.create(on: db)
        try await cleanupClients(on: db)
        return RegistrationOutput(client_id: try client.requireID().uuidString, client_name: name, redirect_uris: unique, token_endpoint_auth_method: "none",
                                  grant_types: input.grant_types ?? ["authorization_code", "refresh_token"], response_types: ["code"],
                                  client_id_issued_at: Int(client.createdAt.timeIntervalSince1970))
    }

    /// Registrations that were never used (no request, grant) expire after 30 days.
    private func cleanupClients(on db: any Database) async throws {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        for client in try await OAuthClient.query(on: db).filter(\.$createdAt < cutoff).filter(\.$lastUsedAt == nil).limit(50).all() {
            let id = try client.requireID()
            if try await OAuthRequestRecord.query(on: db).filter(\.$clientId == id).count() == 0,
               try await OAuthGrant.query(on: db).filter(\.$clientId == id).count() == 0 { try await client.delete(on: db) }
        }
    }

    // MARK: Authorization request

    /// Returns the redirect target. Errors before a valid client/redirect pair is established throw (no redirect).
    func authorize(_ query: AuthorizeQuery, ip: String, on db: any Database) async throws -> String {
        try await limit("oauth_authorize", max: 30, ip: ip, on: db)
        guard let clientID = query.client_id.flatMap(UUID.init(uuidString:)), let client = try await OAuthClient.find(clientID, on: db) else {
            throw OAuthError("invalid_client", "Unknown client_id.")
        }
        guard let redirectURI = query.redirect_uri, client.redirectURIs.contains(redirectURI) else {
            throw OAuthError("invalid_request", "redirect_uri does not match a registered redirect URI.")
        }
        func fail(_ code: String, _ description: String) -> String {
            callbackURL(redirectURI, [("error", code), ("error_description", description)] + (query.state.map { [("state", $0)] } ?? []))
        }
        guard query.response_type == "code" else { return fail("unsupported_response_type", "response_type must be code.") }
        if let state = query.state, state.count > 512 { return fail("invalid_request", "state is too long.") }
        guard let challenge = query.code_challenge, OAuthText.isBase64URL(challenge, count: 43...43), query.code_challenge_method == "S256" else {
            return fail("invalid_request", "PKCE with code_challenge_method S256 is required.")
        }
        guard query.resource == resource else { return fail("invalid_target", "resource must be the MCP resource.") }
        let requested = OAuthText.parseScopes(query.scope)
        let scopes = requested.isEmpty ? McpScopes.all : requested
        guard scopes.allSatisfy(McpScopes.known.contains) else { return fail("invalid_scope", "Unknown scope.") }
        let now = Date()
        let record = OAuthRequestRecord()
        record.clientId = clientID; record.redirectURI = redirectURI; record.scopes = scopes; record.state = query.state
        record.codeChallenge = challenge; record.resource = resource; record.createdAt = now
        record.expiresAt = now.addingTimeInterval(Self.requestLifetime)
        try await record.create(on: db)
        try await OAuthClient.query(on: db).filter(\.$id == clientID).set(\.$lastUsedAt, to: now).update()
        try await OAuthRequestRecord.query(on: db).filter(\.$expiresAt < now.addingTimeInterval(-3600)).filter(\.$decidedAt == nil).delete()
        return issuer + "/oauth/consent?request=" + (try record.requireID().uuidString)
    }

    func callbackURL(_ base: String, _ items: [(String, String)]) -> String {
        guard var parts = URLComponents(string: base) else { return base }
        parts.queryItems = (parts.queryItems ?? []) + items.map { URLQueryItem(name: $0.0, value: $0.1) } + [URLQueryItem(name: "iss", value: issuer)]
        return parts.string ?? base
    }

    // MARK: Consent

    /// Loads a request for the session's account and binds it to that session on first access; anything else is 404.
    private func boundRequest(_ id: UUID, _ context: AuthContext, on db: any Database) async throws -> OAuthRequestRecord {
        let accountID = try context.account.requireID(), binding = context.session.tokenHash, now = Date()
        guard let found = try await OAuthRequestRecord.find(id, on: db), found.expiresAt > now else { throw APIError.missing }
        var record = found
        if record.bindingHash == nil {
            let bound = try await conditionalWrite(on: db) {
                try await OAuthRequestRecord.query(on: $0).filter(\.$id == id).filter(\.$bindingHash == nil)
                    .set(\.$accountId, to: accountID).set(\.$bindingHash, to: binding).update()
            }
            if bound { record.accountId = accountID; record.bindingHash = binding }
            else { guard let again = try await OAuthRequestRecord.find(id, on: db) else { throw APIError.missing }; record = again }
        }
        guard let stored = record.bindingHash, Secrets.equal(stored, binding), record.accountId == accountID else { throw APIError.missing }
        return record
    }

    func consent(_ id: UUID, _ context: AuthContext, on db: any Database) async throws -> OAuthRequestDTO {
        try context.normal()
        let record = try await boundRequest(id, context, on: db)
        guard record.decidedAt == nil, let client = try await OAuthClient.find(record.clientId, on: db) else { throw APIError.missing }
        let parts = URLComponents(string: record.redirectURI)
        let host = (parts?.host ?? "") + (parts?.port.map { ":\($0)" } ?? "")
        return OAuthRequestDTO(id: id, clientName: client.name, redirectHost: host, scopes: record.scopes, expiresAt: record.expiresAt)
    }

    /// Returns the redirect URL for the client (code + state, or access_denied).
    func decide(_ id: UUID, approve: Bool, scopes: [String]?, _ context: AuthContext, on db: any Database) async throws -> String {
        try context.normal()
        return try await auth.transaction(on: db) { tx in
            let record = try await boundRequest(id, context, on: tx)
            let accountID = try context.account.requireID()
            var chosen: [String] = []
            if approve {
                chosen = scopes.map { OAuthText.parseScopes($0.joined(separator: " ")) } ?? record.scopes
                guard !chosen.isEmpty, chosen.allSatisfy({ McpScopes.known.contains($0) && record.scopes.contains($0) }) else { throw APIError.invalid }
            }
            let now = Date()
            let consumed = try await conditionalWrite(on: tx) {
                try await OAuthRequestRecord.query(on: $0).filter(\.$id == id).filter(\.$decidedAt == nil).filter(\.$expiresAt > now)
                    .set(\.$decidedAt, to: now).update()
            }
            guard consumed else { throw APIError(.conflict, "conflict") }
            guard approve else {
                return callbackURL(record.redirectURI, [("error", "access_denied"), ("error_description", "The user denied the request.")] + (record.state.map { [("state", $0)] } ?? []))
            }
            let grant: OAuthGrant
            if let existing = try await OAuthGrant.query(on: tx).filter(\.$accountId == accountID).filter(\.$clientId == record.clientId).filter(\.$revokedAt == nil).first() {
                existing.scopes = chosen; try await existing.update(on: tx); grant = existing
            } else {
                grant = OAuthGrant(); grant.accountId = accountID; grant.clientId = record.clientId; grant.scopes = chosen; grant.createdAt = now
                try await grant.create(on: tx)
            }
            let code = Secrets.token(bytes: 32)
            let stored = OAuthCode()
            stored.codeHash = Secrets.hash(code); stored.clientId = record.clientId; stored.accountId = accountID; stored.grantId = try grant.requireID()
            stored.scopes = chosen; stored.redirectURI = record.redirectURI; stored.codeChallenge = record.codeChallenge; stored.resource = record.resource
            stored.createdAt = now; stored.expiresAt = now.addingTimeInterval(Self.codeLifetime)
            try await stored.create(on: tx)
            return callbackURL(record.redirectURI, [("code", code)] + (record.state.map { [("state", $0)] } ?? []))
        }
    }

    // MARK: Token endpoint

    private enum Outcome: Sendable { case issued(TokenResponse), failed(OAuthError) }

    func token(_ form: TokenForm, on db: any Database) async throws -> TokenResponse {
        guard let clientID = form.client_id.flatMap(UUID.init(uuidString:)), try await OAuthClient.find(clientID, on: db) != nil else {
            throw OAuthError("invalid_client", "Unknown client_id.")
        }
        if let value = form.resource, value != resource { throw OAuthError("invalid_target", "resource must be the MCP resource.") }
        let outcome: Outcome
        switch form.grant_type {
        case "authorization_code": outcome = try await exchangeCode(form, clientID: clientID, on: db)
        case "refresh_token": outcome = try await refresh(form, clientID: clientID, on: db)
        default: throw OAuthError("unsupported_grant_type", "grant_type must be authorization_code or refresh_token.")
        }
        switch outcome {
        case .issued(let response): return response
        case .failed(let error): throw error
        }
    }

    private func exchangeCode(_ form: TokenForm, clientID: UUID, on db: any Database) async throws -> Outcome {
        guard let code = form.code, let redirectURI = form.redirect_uri, let verifier = form.code_verifier else {
            throw OAuthError("invalid_request", "code, redirect_uri and code_verifier are required.")
        }
        guard OAuthText.isVerifier(verifier) else { throw OAuthError("invalid_grant", "Invalid code_verifier.") }
        let hash = Secrets.hash(code), invalid = OAuthError("invalid_grant", "The authorization code is invalid, expired or already used.")
        guard OAuthText.isBase64URL(code, count: 43...43),
              try await OAuthCode.query(on: db).filter(\.$codeHash == hash).first() != nil else { throw invalid }
        return try await auth.transaction(on: db) { tx in
            let now = Date()
            guard let record = try await OAuthCode.query(on: tx).filter(\.$codeHash == hash).first() else { return .failed(invalid) }
            guard record.expiresAt > now, record.clientId == clientID, record.redirectURI == redirectURI,
                  record.resource == resource else { return .failed(invalid) }
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
            guard Secrets.equal(challenge, record.codeChallenge) else { return .failed(invalid) }
            guard let active = try await OAuthGrant.find(record.grantId, on: tx),
                  try await auth.modules.enabled(.mcp, account: active.accountId, on: tx) else { return .failed(invalid) }
            if record.consumedAt != nil { try await revokeGrant(record.grantId, on: tx); return .failed(invalid) }
            let consumed = try await conditionalWrite(on: tx) {
                try await OAuthCode.query(on: $0).filter(\.$id == record.requireID()).filter(\.$consumedAt == nil).filter(\.$expiresAt > now)
                    .set(\.$consumedAt, to: now).update()
            }
            guard consumed else { try await revokeGrant(record.grantId, on: tx); return .failed(invalid) }
            guard let grant = try await activeGrant(record.grantId, on: tx), grant.clientId == clientID else { return .failed(invalid) }
            try await OAuthClient.query(on: tx).filter(\.$id == clientID).set(\.$lastUsedAt, to: now).update()
            return .issued(try await issue(grant: grant, scopes: record.scopes, parent: nil, now: now, on: tx))
        }
    }

    private func refresh(_ form: TokenForm, clientID: UUID, on db: any Database) async throws -> Outcome {
        guard let presented = form.refresh_token else { throw OAuthError("invalid_request", "refresh_token is required.") }
        let hash = Secrets.hash(presented), invalid = OAuthError("invalid_grant", "The refresh token is invalid, expired or revoked.")
        guard presented.count == OAuthTokenFormat.length, presented.hasPrefix(OAuthTokenFormat.refreshPrefix),
              try await OAuthToken.query(on: db).filter(\.$tokenHash == hash).first() != nil else { throw invalid }
        let narrowed = form.scope.map { OAuthText.parseScopes($0) }
        return try await auth.transaction(on: db) { tx in
            let now = Date()
            guard presented.hasPrefix(OAuthTokenFormat.refreshPrefix), let record = try await OAuthToken.query(on: tx).filter(\.$tokenHash == hash).first(),
                  record.kind == "refresh", let grant = try await OAuthGrant.find(record.grantId, on: tx), grant.clientId == clientID else { return .failed(invalid) }
            guard try await auth.modules.enabled(.mcp, account: grant.accountId, on: tx) else { return .failed(invalid) }
            if record.usedAt != nil { try await revokeGrant(record.grantId, on: tx); return .failed(invalid) }
            guard record.revokedAt == nil, record.expiresAt > now, try await activeGrant(record.grantId, on: tx) != nil else { return .failed(invalid) }
            var scopes = Array(Set(record.scopes).intersection(grant.scopes)).sorted()
            if let narrowed, !narrowed.isEmpty {
                guard narrowed.allSatisfy(scopes.contains) else { return .failed(OAuthError("invalid_scope", "scope exceeds the original grant.")) }
                scopes = narrowed
            }
            let consumed = try await conditionalWrite(on: tx) {
                try await OAuthToken.query(on: $0).filter(\.$id == record.requireID()).filter(\.$usedAt == nil).filter(\.$revokedAt == nil)
                    .filter(\.$expiresAt > now).set(\.$usedAt, to: now).update()
            }
            guard consumed else { try await revokeGrant(record.grantId, on: tx); return .failed(invalid) }
            return .issued(try await issue(grant: grant, scopes: scopes, parent: record.requireID(), now: now, on: tx))
        }
    }

    private func activeGrant(_ id: UUID, on db: any Database) async throws -> OAuthGrant? {
        guard let grant = try await OAuthGrant.find(id, on: db), grant.revokedAt == nil,
              let account = try await Account.find(grant.accountId, on: db), account.disabledAt == nil else { return nil }
        guard try await auth.modules.enabled(.mcp, account: grant.accountId, on: db) else { return nil }
        return grant
    }

    private func issue(grant: OAuthGrant, scopes: [String], parent: UUID?, now: Date, on db: any Database) async throws -> TokenResponse {
        let grantID = try grant.requireID()
        let access = OAuthTokenFormat.make(OAuthTokenFormat.accessPrefix), refresh = OAuthTokenFormat.make(OAuthTokenFormat.refreshPrefix)
        for (value, kind, lifetime) in [(access, "access", Self.accessLifetime), (refresh, "refresh", Self.refreshLifetime)] {
            let record = OAuthToken()
            record.tokenHash = Secrets.hash(value); record.kind = kind; record.grantId = grantID; record.scopes = scopes
            record.createdAt = now; record.expiresAt = now.addingTimeInterval(lifetime); record.parentId = kind == "refresh" ? parent : nil
            try await record.create(on: db)
        }
        try await OAuthGrant.query(on: db).filter(\.$id == grantID).set(\.$lastUsedAt, to: now).update()
        return TokenResponse(access_token: access, token_type: "Bearer", expires_in: Int(Self.accessLifetime), refresh_token: refresh, scope: scopes.joined(separator: " "))
    }

    /// Revokes the grant and every token issued under it, immediately.
    func revokeGrant(_ id: UUID, on db: any Database) async throws {
        let now = Date()
        try await OAuthGrant.query(on: db).filter(\.$id == id).filter(\.$revokedAt == nil).set(\.$revokedAt, to: now).update()
        try await OAuthToken.query(on: db).filter(\.$grantId == id).filter(\.$revokedAt == nil).set(\.$revokedAt, to: now).update()
    }

    // MARK: Revocation (RFC 7009)

    /// Revoking a refresh token ends the whole grant; revoking an access token only that token. Unknown tokens are ignored.
    func revoke(token: String, clientID: String?, on db: any Database) async throws {
        guard token.count == OAuthTokenFormat.length, let record = try await OAuthToken.query(on: db).filter(\.$tokenHash == Secrets.hash(token)).first() else { return }
        if let clientID {
            guard let id = UUID(uuidString: clientID), let grant = try await OAuthGrant.find(record.grantId, on: db), grant.clientId == id else { return }
        }
        if record.kind == "refresh" { try await revokeGrant(record.grantId, on: db) }
        else { try await OAuthToken.query(on: db).filter(\.$id == record.requireID()).filter(\.$revokedAt == nil).set(\.$revokedAt, to: Date()).update() }
    }
}
