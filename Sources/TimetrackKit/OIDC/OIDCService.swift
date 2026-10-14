import Vapor
import Fluent
import FluentSQL
import FluentMySQLDriver
import Crypto

struct ExternalIdentityDTO: Content {
    let id: UUID
    let providerName: String
    let emailHint: String?
    let linkedAt: Date
    let lastUsedAt: Date?
}

/// Result of the callback. Always becomes a 302 to the PWA; `session` additionally sets tt_session.
struct OIDCCallbackOutcome: Sendable {
    var location: String
    var session: AuthContext?
    var clearBinding = false
}

private struct OIDCFailure: Error { let code: String }

struct OIDCService: Sendable {
    static let bindingCookie = "tt_oidc"
    static let lifetime: TimeInterval = 600

    let auth: AuthService
    let config: OIDCConfiguration?
    let client: OIDCClient?

    var redirectURI: String { auth.configuration.publicBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1/auth/oidc/callback" }

    func requireEnabled() throws -> (OIDCConfiguration, OIDCClient) {
        guard let config, let client else { throw APIError(.notImplemented, "not_implemented") }
        return (config, client)
    }

    static func bindingHash(_ cookie: String) -> String { Secrets.hash("timetrack.oidc.binding.v1:" + cookie) }

    // MARK: Start

    struct Started: Sendable { let authorizationURL: String; let binding: String }

    func start(purpose: OIDCPurpose, inviteToken: String?, context: AuthContext?, on db: any Database) async throws -> Started {
        let (config, client) = try requireEnabled()
        var inviteID: UUID?, accountID: UUID?, token: String?
        switch purpose {
        case .login: break
        case .link:
            guard let context else { throw APIError.unauthorized }
            try context.fresh()
            accountID = try context.account.requireID()
        case .register:
            guard let inviteToken else { throw APIError.invalid }
            inviteID = try await auth.invitation(inviteToken, on: db).requireID()  // 404 not_found when unusable
            token = inviteToken
        }
        let discovery: OIDCDiscovery
        do { discovery = try await client.discover() } catch { throw APIError(.badGateway, "oidc_unavailable") }
        let state = Secrets.token(), nonce = Secrets.token(), verifier = Secrets.token(), binding = Secrets.token()
        let now = Date()
        // Opportunistic cleanup of long-expired rows.
        try? await OIDCState.query(on: db).filter(\.$expiresAt < now.addingTimeInterval(-3600)).delete()
        try? await OIDCPendingRegistration.query(on: db).filter(\.$expiresAt < now.addingTimeInterval(-3600)).delete()
        try await OIDCState(stateHash: Secrets.hash(state), nonce: nonce, codeVerifier: verifier, purpose: purpose, inviteId: inviteID, inviteToken: token,
                            accountId: accountID, bindingHash: Self.bindingHash(binding), createdAt: now, expiresAt: now.addingTimeInterval(Self.lifetime)).create(on: db)
        guard var parts = URLComponents(string: discovery.authorizationEndpoint) else { throw APIError(.badGateway, "oidc_unavailable") }
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        parts.queryItems = (parts.queryItems ?? []) + [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: redirectURI), .init(name: "scope", value: config.scopes.joined(separator: " ")),
            .init(name: "state", value: state), .init(name: "nonce", value: nonce),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256")
        ]
        // URLComponents leaves "+" and "&" unescaped inside values only if they occur; our values are base64url or fixed.
        guard let url = parts.url?.absoluteString else { throw APIError(.badGateway, "oidc_unavailable") }
        return Started(authorizationURL: url, binding: binding)
    }

    // MARK: Callback

    func callback(code: String?, state: String?, providerError: String?, binding: String?, sessionToken: String?, on db: any Database) async -> OIDCCallbackOutcome {
        func fail(_ code: String, link: Bool = false) -> OIDCCallbackOutcome {
            OIDCCallbackOutcome(location: (link ? "/settings/identities" : "/login") + "?oidc_error=" + code)
        }
        guard config != nil, let client else { return fail("oidc_failed") }
        guard let state, !state.isEmpty, state.count <= 128 else { return fail("oidc_state_invalid") }
        // Consume first: a state can be used exactly once, whatever happens afterwards.
        let row: OIDCState
        do {
            guard let found = try await OIDCState.query(on: db).filter(\.$stateHash == Secrets.hash(state)).first(),
                  try await consume(OIDCState.self, id: found.requireID(), on: db) else { return fail("oidc_state_invalid") }
            row = found
        } catch { return fail("oidc_failed") }
        guard let purpose = OIDCPurpose(rawValue: row.purpose) else { return fail("oidc_state_invalid") }
        let link = purpose == .link
        let verifier = row.codeVerifier, nonce = row.nonce, inviteToken = row.inviteToken
        // Secrets are only needed in memory from here on.
        if let rowID = row.id { try? await OIDCState.query(on: db).filter(\.$id == rowID).set(\.$codeVerifier, to: "").set(\.$inviteToken, to: nil).update() }
        guard let binding, row.bindingHash == Self.bindingHash(binding) else { return fail("oidc_state_invalid", link: link) }
        guard providerError == nil else { return fail("oidc_failed", link: link) }
        guard let code, !code.isEmpty, code.count <= 2048 else { return fail("oidc_failed", link: link) }
        do {
            // Link flow: the initiating session must still be the current, fresh one.
            var linking: AuthContext?
            if purpose == .link {
                guard let sessionToken, let accountID = row.accountId,
                      let context = try? await auth.authenticate(sessionToken, on: db), context.account.id == accountID else { throw OIDCFailure(code: "oidc_reauth_required") }
                do { try context.fresh() } catch { throw OIDCFailure(code: "oidc_reauth_required") }
                linking = context
            }
            let identity: OIDCIdentityClaims
            do {
                let idToken = try await client.exchange(code: code, verifier: verifier, redirectURI: redirectURI)
                identity = try await client.verify(idToken: idToken, nonce: nonce)
            } catch let error as OIDCTokenError { _ = error; throw OIDCFailure(code: "oidc_token_invalid") }
            catch { throw OIDCFailure(code: "oidc_failed") }
            let issuer = config!.issuer
            switch purpose {
            case .login:
                let context = try await auth.transaction(on: db) { tx -> AuthContext in
                    guard let link = try await ExternalIdentity.query(on: tx).filter(\.$issuer == issuer).filter(\.$subject == identity.subject).first() else {
                        throw OIDCFailure(code: "oidc_not_linked")
                    }
                    guard let account = try await Account.find(link.accountId, on: tx), account.disabledAt == nil else { throw OIDCFailure(code: "oidc_failed") }
                    link.lastUsedAt = Date()
                    if let hint = identity.emailHint { link.emailHint = hint }
                    try await link.update(on: tx)
                    return try await auth.issueSession(for: account, on: tx)
                }
                return OIDCCallbackOutcome(location: "/", session: context, clearBinding: true)
            case .link:
                guard let linking else { throw OIDCFailure(code: "oidc_reauth_required") }
                let accountID = try linking.account.requireID()
                try await auth.transaction(on: db) { tx in
                    // Re-check inside the transaction: the session may have been revoked meanwhile.
                    let current = try await auth.authenticate(linking.token, on: tx)
                    do { try current.fresh() } catch { throw OIDCFailure(code: "oidc_reauth_required") }
                    if let existing = try await ExternalIdentity.query(on: tx).filter(\.$issuer == issuer).filter(\.$subject == identity.subject).first() {
                        guard existing.accountId == accountID else { throw OIDCFailure(code: "oidc_identity_taken") }
                        existing.lastUsedAt = Date(); try await existing.update(on: tx)
                        return
                    }
                    try await ExternalIdentity(accountId: accountID, issuer: issuer, subject: identity.subject, emailHint: identity.emailHint, linkedAt: Date()).create(on: tx)
                }
                return OIDCCallbackOutcome(location: "/settings/identities?linked=1", clearBinding: true)
            case .register:
                guard let inviteID = row.inviteId, let inviteToken else { throw OIDCFailure(code: "oidc_invite_invalid") }
                let pendingID = try await auth.transaction(on: db) { tx -> UUID in
                    guard let invite = try await Invitation.find(inviteID, on: tx), invite.usedAt == nil, invite.revokedAt == nil, invite.expiresAt > Date() else {
                        throw OIDCFailure(code: "oidc_invite_invalid")
                    }
                    guard try await ExternalIdentity.query(on: tx).filter(\.$issuer == issuer).filter(\.$subject == identity.subject).first() == nil else {
                        throw OIDCFailure(code: "oidc_identity_taken")
                    }
                    let now = Date()
                    let pending = OIDCPendingRegistration(issuer: issuer, subject: identity.subject, emailHint: identity.emailHint, invitationId: inviteID,
                                                          bindingHash: row.bindingHash, createdAt: now, expiresAt: now.addingTimeInterval(Self.lifetime))
                    try await pending.create(on: tx)
                    return try pending.requireID()
                }
                return OIDCCallbackOutcome(location: "/invite/\(inviteToken)?oidc=\(pendingID.uuidString)")
            }
        } catch let failure as OIDCFailure {
            return fail(failure.code, link: link)
        } catch {
            return fail("oidc_failed", link: link)
        }
    }

    // MARK: Register

    func register(pendingID: UUID, handle: String, displayName: String, binding: String?, on db: any Database) async throws -> AuthContext {
        _ = try requireEnabled()
        guard handle.range(of: "^[a-z0-9][a-z0-9._-]{2,31}$", options: .regularExpression) == handle.startIndex..<handle.endIndex,
              (1...80).contains(displayName.count) else { throw APIError.invalid }
        return try await auth.transaction(on: db) { tx in
            guard let pending = try await OIDCPendingRegistration.find(pendingID, on: tx), pending.consumedAt == nil, pending.expiresAt > Date(),
                  let binding, pending.bindingHash == Self.bindingHash(binding),
                  try await consume(OIDCPendingRegistration.self, id: pendingID, on: tx),
                  let invite = try await Invitation.find(pending.invitationId, on: tx),
                  try await SingleUse.consume(.invitation, id: pending.invitationId, on: tx) else { throw APIError.missing }
            guard try await ExternalIdentity.query(on: tx).filter(\.$issuer == pending.issuer).filter(\.$subject == pending.subject).first() == nil else {
                throw APIError(.conflict, "oidc_identity_taken")
            }
            guard try await Account.query(on: tx).filter(\.$handle == handle).first() == nil else { throw APIError(.conflict, "handle_taken") }
            let account = Account(handle: handle, displayName: displayName, role: invite.role, createdAt: Date())
            try await account.create(on: tx)
            let accountID = try account.requireID()
            try await ExternalIdentity(accountId: accountID, issuer: pending.issuer, subject: pending.subject, emailHint: pending.emailHint,
                                       linkedAt: Date(), lastUsedAt: Date()).create(on: tx)
            try await Invitation.query(on: tx).filter(\.$id == pending.invitationId).set(\.$usedBy, to: accountID).update()
            return try await auth.issueSession(for: account, on: tx)
        }
    }

    // MARK: Identities

    func identities(_ context: AuthContext, on db: any Database) async throws -> [ExternalIdentityDTO] {
        try context.normal()
        let name = config?.name ?? "OpenID Connect"
        return try await ExternalIdentity.query(on: db).filter(\.$accountId == context.account.requireID()).sort(\.$linkedAt).all().map {
            ExternalIdentityDTO(id: try $0.requireID(), providerName: name, emailHint: $0.emailHint, linkedAt: $0.linkedAt, lastUsedAt: $0.lastUsedAt)
        }
    }

    func unlink(_ id: UUID, context: AuthContext, on db: any Database) async throws {
        try await auth.transaction(on: db) { tx in
            let current = try await auth.authenticate(context.token, on: tx)
            try current.fresh()
            let accountID = try current.account.requireID()
            guard let identity = try await ExternalIdentity.query(on: tx).filter(\.$id == id).filter(\.$accountId == accountID).first() else { throw APIError.missing }
            let passkeys = try await Passkey.query(on: tx).filter(\.$accountId == accountID).filter(\.$revokedAt == nil).count()
            let others = try await ExternalIdentity.query(on: tx).filter(\.$accountId == accountID).filter(\.$id != id).count()
            guard passkeys + others > 0 else { throw APIError(.conflict, "last_login_method") }
            try await identity.delete(on: tx)
        }
    }

    // MARK: Single use

    /// Conditional write plus affected-row count on one connection (same technique as `SingleUse`).
    private func consume<M: Model>(_ type: M.Type, id: UUID, on database: any Database) async throws -> Bool where M.IDValue == UUID {
        let now = Date()
        return try await database.withConnection { connection in
            if M.self == OIDCState.self {
                try await OIDCState.query(on: connection).filter(\.$id == id).filter(\.$consumedAt == nil).filter(\.$expiresAt > now).set(\.$consumedAt, to: now).update()
            } else {
                try await OIDCPendingRegistration.query(on: connection).filter(\.$id == id).filter(\.$consumedAt == nil).filter(\.$expiresAt > now).set(\.$consumedAt, to: now).update()
            }
            let sql = try requireSQL(connection)
            let row = try await sql.raw(connection is any MySQLDatabase ? "SELECT ROW_COUNT() AS affected" : "SELECT changes() AS affected").first()
            guard let row else { throw DatabaseSupportError.missingAffectedRowCount }
            return try row.decode(column: "affected", as: Int.self) == 1
        }
    }
}
