import Vapor
import Fluent

struct OAuthGrantDTO: Content { let id: UUID; let clientName: String; let scopes: [String]; let createdAt: Date; let lastUsedAt: Date? }
struct ApiTokenDTO: Content {
    let id: UUID; let name: String; let scopes: [String]; let createdAt: Date; let expiresAt: Date; let lastUsedAt: Date?; var token: String?
    init(_ record: ApiTokenRecord, token: String? = nil) throws {
        id = try record.requireID(); name = record.name; scopes = record.scopes; createdAt = record.createdAt
        expiresAt = record.expiresAt; lastUsedAt = record.lastUsedAt; self.token = token
    }
}
struct ApiTokenInput: Content { let name: String; let scopes: [String]; let expiresInDays: Int }

/// Account-scoped management of OAuth grants and personal tokens. Foreign ids are always 404.
struct OAuthCredentialService: Sendable {
    let auth: AuthService
    let oauth: OAuthService
    static let maxActiveTokens = 25

    func grants(_ context: AuthContext, on db: any Database) async throws -> [OAuthGrantDTO] {
        try context.normal()
        let grants = try await OAuthGrant.query(on: db).filter(\.$accountId == context.account.requireID()).filter(\.$revokedAt == nil).sort(\.$createdAt, .descending).all()
        var result: [OAuthGrantDTO] = []
        for grant in grants {
            let name = try await OAuthClient.find(grant.clientId, on: db)?.name ?? ""
            result.append(OAuthGrantDTO(id: try grant.requireID(), clientName: name, scopes: grant.scopes, createdAt: grant.createdAt, lastUsedAt: grant.lastUsedAt))
        }
        return result
    }

    func revokeGrant(_ id: UUID, _ context: AuthContext, on db: any Database) async throws {
        try context.normal()
        let accountID = try context.account.requireID()
        try await auth.transaction(on: db) { tx in
            guard let grant = try await OAuthGrant.find(id, on: tx), grant.accountId == accountID, grant.revokedAt == nil else { throw APIError.missing }
            try await oauth.revokeGrant(id, on: tx)
        }
    }

    func tokens(_ context: AuthContext, on db: any Database) async throws -> [ApiTokenDTO] {
        try context.normal()
        return try await ApiTokenRecord.query(on: db).filter(\.$accountId == context.account.requireID()).filter(\.$revokedAt == nil)
            .sort(\.$createdAt, .descending).all().map { try ApiTokenDTO($0) }
    }

    func createToken(_ input: ApiTokenInput, _ context: AuthContext, on db: any Database) async throws -> ApiTokenDTO {
        try context.fresh()
        let name = OAuthText.sanitizedName(input.name)
        var seen = Set<String>()
        let scopes = input.scopes.filter { seen.insert($0).inserted }
        guard (1...80).contains(name.count), !scopes.isEmpty, scopes.allSatisfy(McpScopes.known.contains), (1...365).contains(input.expiresInDays) else { throw APIError.invalid }
        let accountID = try context.account.requireID()
        return try await auth.transaction(on: db) { tx in
            let now = Date()
            guard try await ApiTokenRecord.query(on: tx).filter(\.$accountId == accountID).filter(\.$revokedAt == nil).filter(\.$expiresAt > now).count() < Self.maxActiveTokens else {
                throw APIError(.conflict, "too_many_tokens")
            }
            let plain = OAuthTokenFormat.make(OAuthTokenFormat.personalPrefix)
            let record = ApiTokenRecord()
            record.accountId = accountID; record.name = name; record.scopes = scopes; record.tokenHash = Secrets.hash(plain)
            record.createdAt = now; record.expiresAt = now.addingTimeInterval(Double(input.expiresInDays) * 86400)
            try await record.create(on: tx)
            return try ApiTokenDTO(record, token: plain)
        }
    }

    func revokeToken(_ id: UUID, _ context: AuthContext, on db: any Database) async throws {
        try context.normal()
        let accountID = try context.account.requireID()
        let revoked = try await conditionalWrite(on: db) {
            try await ApiTokenRecord.query(on: $0).filter(\.$id == id).filter(\.$accountId == accountID).filter(\.$revokedAt == nil).set(\.$revokedAt, to: Date()).update()
        }
        guard revoked else { throw APIError.missing }
    }
}
