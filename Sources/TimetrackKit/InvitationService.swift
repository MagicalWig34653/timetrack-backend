import Vapor
import Fluent

extension AuthService {
    func invitation(_ token: String, on db: any Database) async throws -> Invitation {
        guard token.count == 43, let invite = try await Invitation.query(on: db).filter(\.$tokenHash == Secrets.hash(token)).first(),
              invite.usedAt == nil, invite.revokedAt == nil, invite.expiresAt > Date() else { throw APIError.missing }
        return invite
    }
    func createInvitation(_ input: InvitationInput, context: AuthContext?, bootstrap: Bool = false, on db: any Database) async throws -> InvitationDTO {
        let hours = input.expiresInHours ?? 72
        guard (1...720).contains(hours), (input.note?.count ?? 0) <= 200 else { throw APIError.invalid }
        return try await transaction(on: db) { tx in
            var creator: UUID?
            if bootstrap {
                guard try await Account.query(on: tx).count() == 0 else { throw APIError(.conflict, "conflict") }
                // A second bootstrap invalidates any previously printed bootstrap links.
                try await Invitation.query(on: tx).filter(\.$createdBy == nil).filter(\.$usedAt == nil).set(\.$revokedAt, to: Date()).update()
            } else {
                guard let context else { throw APIError.unauthorized }
                let current = try await authenticate(context.token, on: tx)
                try current.admin(); creator = try current.account.requireID()
            }
            let token = Secrets.token()
            let invite = Invitation(tokenHash: Secrets.hash(token), createdBy: creator, note: input.note, role: bootstrap ? .admin : .member,
                                    createdAt: Date(), expiresAt: Date().addingTimeInterval(Double(hours * 3600)))
            try await invite.create(on: tx)
            return try InvitationDTO(invite, token: token)
        }
    }
    func invitations(_ context: AuthContext, on db: any Database) async throws -> [InvitationDTO] {
        try context.admin()
        return try await Invitation.query(on: db).filter(\.$createdBy == context.account.requireID()).sort(\.$createdAt, .descending).all().map { try InvitationDTO($0) }
    }
    func revokeInvitation(_ id: UUID, context: AuthContext, on db: any Database) async throws {
        try await transaction(on: db) { tx in
            let current = try await authenticate(context.token, on: tx)
            try current.normal()
            guard let invite = try await Invitation.query(on: tx).filter(\.$id == id).filter(\.$createdBy == current.account.requireID()).first() else { throw APIError.missing }
            try current.admin()
            invite.revokedAt = Date(); try await invite.update(on: tx)
        }
    }
}

struct BootstrapAdmin: AsyncCommand {
    struct Signature: CommandSignature { init() {} }
    let help = "Create the first administrator invitation."
    let service: AuthService
    func run(using context: CommandContext, signature: Signature) async throws {
        let invite = try await service.createInvitation(.init(), context: nil, bootstrap: true, on: context.application.db)
        guard let token = invite.token else { throw APIError.invalid }
        context.console.print(service.configuration.publicBaseURL.appendingPathComponent("invite").appendingPathComponent(token).absoluteString)
    }
}
