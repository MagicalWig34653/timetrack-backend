import Vapor
import Fluent

struct AuthContext: Sendable {
    let session: Session
    let account: Account
    let token: String
    func normal() throws { if session.recovery { throw APIError(.forbidden, "recovery_session_restricted") } }
    func fresh(allowRecovery: Bool = false) throws {
        if !allowRecovery { try normal() }
        guard session.recovery || session.createdAt > Date().addingTimeInterval(-600) else { throw APIError(.forbidden, "reauth_required") }
    }
    func admin() throws { try normal(); guard account.role == .admin else { throw APIError(.forbidden, "forbidden") } }
    var response: SessionDTO { get throws { try .init(account: AccountDTO(account), csrfToken: Secrets.csrf(token), recovery: session.recovery, expiresAt: session.expiresAt) } }
}

extension AuthService {
    static let lastSeenGranularity: TimeInterval = 60
    func authenticate(_ token: String?, on db: any Database) async throws -> AuthContext {
        guard let token, token.count == 43,
              let session = try await Session.query(on: db).filter(\.$tokenHash == Secrets.hash(token)).first(),
              session.revokedAt == nil, session.expiresAt > Date(),
              let account = try await Account.find(session.accountId, on: db), account.disabledAt == nil else { throw APIError.unauthorized }
        // The timestamp is informational; writing it on every request (up to three authentications per request)
        // cost a committed write each. Refresh it at most once a minute.
        if session.lastSeenAt.map({ Date().timeIntervalSince($0) >= Self.lastSeenGranularity }) ?? true {
            try await Session.query(on: db).filter(\.$id == session.requireID()).set(\.$lastSeenAt, to: Date()).update()
        }
        return AuthContext(session: session, account: account, token: token)
    }
    func issueSession(for account: Account, recovery: Bool = false, on db: any Database) async throws -> AuthContext {
        let token = Secrets.token()
        let now = Date()
        let session = Session(accountId: try account.requireID(), tokenHash: Secrets.hash(token), csrfTokenHash: Secrets.hash(Secrets.csrf(token)),
                              recovery: recovery, createdAt: now, expiresAt: now.addingTimeInterval(recovery ? 1800 : Double(configuration.sessionTTLHours * 3600)), lastSeenAt: now)
        try await session.create(on: db)
        return AuthContext(session: session, account: account, token: token)
    }
    func revokeSessions(_ context: AuthContext, others: Bool, on db: any Database) async throws {
        try await transaction(on: db) { tx in
            let current = try await authenticate(context.token, on: tx)
            if others { try current.normal() }
            let query = try Session.query(on: tx).filter(\.$accountId == current.account.requireID())
            if others { try query.filter(\.$id != current.session.requireID()) } else { try query.filter(\.$id == current.session.requireID()) }
            try await query.set(\.$revokedAt, to: Date()).update()
        }
    }
    func cookie(_ context: AuthContext) -> HTTPCookies.Value {
        .init(string: context.token, expires: context.session.expiresAt, path: "/", isSecure: configuration.publicBaseURL.scheme == "https", isHTTPOnly: true, sameSite: .lax)
    }
}

struct ContextKey: StorageKey { typealias Value = AuthContext }
extension Request {
    var authContext: AuthContext { get throws { guard let value = storage[ContextKey.self] else { throw APIError.unauthorized }; return value } }
}
struct SessionMiddleware: AsyncMiddleware {
    let service: AuthService
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if let token = request.cookies["tt_session"]?.string {
            let context: AuthContext?
            do { context = try await service.authenticate(token, on: request.db) }
            catch let error as APIError where error.code == "unauthorized" { context = nil }
            if let context {
                if ![.GET, .HEAD, .OPTIONS].contains(request.method) {
                    guard let csrf = request.headers.first(name: "X-CSRF-Token"),
                          Secrets.equal(Secrets.hash(csrf), context.session.csrfTokenHash) else { throw APIError(.forbidden, "csrf_invalid") }
                }
                if context.session.recovery {
                    let path = request.url.path
                    let allowed = (path == "/api/v1/auth/session" && [.GET, .DELETE].contains(request.method)) ||
                        (["/api/v1/me/passkeys/options", "/api/v1/me/passkeys/verify"].contains(path) && request.method == .POST)
                    guard allowed else { throw APIError(.forbidden, "recovery_session_restricted") }
                }
                request.storage[ContextKey.self] = context
            }
        }
        return try await next.respond(to: request)
    }
}

struct AuthRateLimitMiddleware: AsyncMiddleware {
    let service: AuthService
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let path = request.url.path
        let limited = path.hasPrefix("/api/v1/auth/register/") || path.hasPrefix("/api/v1/auth/login/") ||
            path.hasPrefix("/api/v1/auth/recovery/") || path.hasPrefix("/api/v1/me/recovery/email") ||
            path.hasPrefix("/api/v1/me/profile/email")
        if limited && [.POST, .PUT].contains(request.method) {
            // Forwarded headers count only from configured trusted proxies (ADR-0018). Charge before decoding request bodies.
            do { try await service.limited(ip: request.clientRateLimitKey, on: request.db) }
            catch let error as APIError where error.code == "too_many_requests" {
                // Diagnostics for operators (no personal data): behind a reverse proxy without TRUSTED_PROXY_CIDRS every
                // client shares the proxy's address and therefore one bucket (docs: Reverse Proxy, ADR-0018).
                let proxies = request.application.trustedProxies
                let peer = request.remoteAddress?.ipAddress ?? "unknown"
                let hasForwarded = request.headers.contains(name: proxies.header.rawValue) || request.headers.contains(name: "X-Forwarded-For")
                request.logger.warning("rate limit (per client address) exceeded on \(request.method) \(path): peer=\(peer) trustedProxies=\(proxies.isEmpty ? "none" : "set") forwardedHeaderPresent=\(hasForwarded)\(proxies.isEmpty && hasForwarded ? " - the request came through a proxy but TRUSTED_PROXY_CIDRS is empty: all clients share one bucket; set TRUSTED_PROXY_CIDRS to the subnet of the connecting proxy (Swarm routing mesh: the ingress network)" : "")")
                throw error
            }
        }
        return try await next.respond(to: request)
    }
}
