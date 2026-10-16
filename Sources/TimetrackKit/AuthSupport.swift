import Vapor
import Fluent
import FluentSQL
import Crypto
import WebAuthn

struct APIError: Error, Sendable {
    let status: HTTPResponseStatus
    let code: String
    init(_ status: HTTPResponseStatus, _ code: String) { self.status = status; self.code = code }
    static let invalid = APIError(.badRequest, "bad_request")
    static let unauthorized = APIError(.unauthorized, "unauthorized")
    static let missing = APIError(.notFound, "not_found")
}

struct APIErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            let response = try await next.respond(to: request)
            if request.url.path.hasPrefix("/api/") { response.headers.replaceOrAdd(name: .cacheControl, value: "no-store") }
            return response
        } catch {
            let failure: APIError
            if let known = error as? APIError { failure = known }
            else if error is DecodingError { failure = .invalid }
            else if let abort = error as? any AbortError {
                failure = APIError(abort.status, abort.status == .notFound ? "not_found" : "bad_request")
            } else { failure = APIError(.internalServerError, "not_ready") }
            struct Envelope: Content { struct Detail: Content { let code: String; let message: String }; let error: Detail }
            let response = try await Envelope(error: .init(code: failure.code, message: ModuleMessages.message(failure.code) ?? (failure.code.replacingOccurrences(of: "_", with: " ") + ".")))
                .encodeResponse(status: failure.status, for: request)
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return response
        }
    }
}

enum Secrets {
    static func token(bytes: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64URL
    }
    static func hash(_ value: String) -> String { Data(SHA256.hash(data: Data(value.utf8))).base64URL }
    // Domain separation prevents the public CSRF value from being usable as a cookie.
    static func csrf(_ token: String) -> String { hash("timetrack.csrf.v1:" + token) }
    static func equal(_ lhs: String, _ rhs: String) -> Bool {
        SHA256.hash(data: Data(lhs.utf8)) == SHA256.hash(data: Data(rhs.utf8))
    }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL: String) {
        let base = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
}

// A database lock serializes stage-one security decisions across processes, including SQLite.
// Acquire before any reads to avoid deferred SQLite transaction upgrade races.
struct CreateAuthLock: AsyncMigration {
    let name = "stage1.create_auth_lock"
    func prepare(on database: any Database) async throws {
        try await database.schema("auth_lock").field("id", .int, .identifier(auto: false)).field("value", .int, .required).create()
        try await requireSQL(database).raw("INSERT INTO auth_lock (id, value) VALUES (1, 0)").run()
    }
    func revert(on database: any Database) async throws { try await database.schema("auth_lock").delete() }
}

struct AuthService: Sendable {
    let configuration: Configuration
    let mailSender: (any MailSender)?
    var webAuthn: WebAuthnManager { webAuthn(origin: configuration.webAuthnOrigin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
    func webAuthn(origin: String) -> WebAuthnManager {
        .init(configuration: .init(relyingPartyID: configuration.webAuthnRPID, relyingPartyName: configuration.webAuthnRPName, relyingPartyOrigin: origin))
    }
    /// Picks the manager whose expected origin equals the client-reported origin, but only from the exact-match allow-list.
    /// Any other origin falls back to the web manager, whose verification rejects it.
    func webAuthn(clientDataJSON bytes: [UInt8]) -> WebAuthnManager {
        struct Origin: Decodable { let origin: String? }
        if let origin = (try? JSONDecoder().decode(Origin.self, from: Data(bytes)))?.origin, configuration.webAuthnAllowedOrigins.contains(origin) {
            return webAuthn(origin: origin)
        }
        return webAuthn
    }
    func transaction<T: Sendable>(on db: any Database, _ operation: @escaping @Sendable (any Database) async throws -> T) async throws -> T {
        try await db.transaction { tx in
            try await requireSQL(tx).raw("UPDATE auth_lock SET value = 1 - value WHERE id = 1").run()
            return try await operation(tx)
        }
    }
    enum RateLimitSubject: Sendable {
        case anonymous, handle(String), registration(UUID), credential(Data), recovery(UUID)
    }
    func limitRequest(ip: String? = nil, subject: RateLimitSubject = .anonymous, on db: any Database) async throws {
        // Charge the IP before lookups so arbitrary identifiers cannot bypass the limiter.
        try await limited(ip: ip, on: db)
        let handle: String?
        switch subject {
        case .anonymous: handle = nil
        case .handle(let value): handle = value
        case .registration(let id): handle = try await WebAuthnChallenge.find(id, on: db)?.payload["handle"]?.string
        case .credential(let id):
            if let key = try await Passkey.query(on: db).filter(\.$credentialId == id).first() {
                handle = try await Account.find(key.accountId, on: db)?.handle
            } else { handle = nil }
        case .recovery(let id):
            if let accountID = try await RecoveryAttempt.find(id, on: db)?.accountId {
                handle = try await Account.find(accountID, on: db)?.handle
            } else { handle = nil }
        }
        if let handle { try await limited(handle: handle, on: db) }
    }
    func limited(ip: String? = nil, handle: String? = nil, on db: any Database) async throws {
        let allowed = try await transaction(on: db) { tx in
            let now = Date()
            let keys = (ip.map { [("ip:" + Secrets.hash($0), 60)] } ?? []) + (handle.map { [("handle:" + Secrets.hash($0.lowercased()), 15)] } ?? [])
            for (key, limit) in keys {
                if try await RateLimitEvent.query(on: tx).filter(\.$key == key).filter(\.$occurredAt > now.addingTimeInterval(-300)).count() >= limit { return false }
            }
            for (key, _) in keys { try await RateLimitEvent(key: key, occurredAt: now).create(on: tx) }
            try await RateLimitEvent.query(on: tx).filter(\.$occurredAt < now.addingTimeInterval(-600)).delete()
            return true
        }
        guard allowed else { throw APIError(.tooManyRequests, "too_many_requests") }
    }
}

struct AccountDTO: Content { let id: UUID; let handle: String; let displayName: String; let role: AccountRole
    init(_ account: Account) throws { id = try account.requireID(); handle = account.handle; displayName = account.displayName; role = account.role }
}
struct SessionDTO: Content { let account: AccountDTO; let csrfToken: String; let recovery: Bool; let expiresAt: Date }
struct PasskeyDTO: Content { let id: UUID; let name: String; let createdAt: Date; let lastUsedAt: Date?
    init(_ key: Passkey) throws { id = try key.requireID(); name = key.name; createdAt = key.createdAt; lastUsedAt = key.lastUsedAt }
}
struct InvitationDTO: Content {
    let id: UUID; let note: String?; let createdAt: Date; let expiresAt: Date; let status: String; var token: String?
    init(_ invite: Invitation, token: String? = nil) throws {
        id = try invite.requireID(); note = invite.note; createdAt = invite.createdAt; expiresAt = invite.expiresAt; self.token = token
        status = invite.revokedAt != nil ? "revoked" : invite.usedAt != nil ? "used" : invite.expiresAt <= Date() ? "expired" : "open"
    }
}
struct OptionsDTO: Content { let challengeId: UUID; let publicKey: JSONValue }
struct RegisterInput: Content { let inviteToken: String; let handle: String; let displayName: String; let email: String? }
struct RegisterProof: Content { let challengeId: UUID; let credential: RegistrationCredential; let passkeyName: String? }
struct LoginProof: Content { let challengeId: UUID; let credential: AuthenticationCredential }
struct InvitationInput: Content { var expiresInHours: Int?; var note: String? }
struct RecoveryStart: Content { let method: RecoveryKind; let identifier: String }
struct RecoveryProof: Content { let recoveryId: UUID; let proof: String }
struct RecoveryStarted: Content { let recoveryId: UUID }

extension JSONValue {
    static func encoding<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
    var string: String? { if case .string(let s) = self { return s }; return nil }
}
