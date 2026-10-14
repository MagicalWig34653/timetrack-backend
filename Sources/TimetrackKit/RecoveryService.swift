import Vapor
import Fluent
import Argon2Swift

/// Implementations must never log recipients, verification codes or message bodies.
public protocol MailSender: Sendable {
    func sendCode(_ code: String, to address: String) async throws
}

struct RecoveryStatusDTO: Content {
    struct Codes: Content { let active: Bool; let remaining: Int }
    struct Password: Content { let active: Bool }
    struct Email: Content { let available: Bool; let active: Bool; let verified: Bool }
    let recoveryCodes: Codes; let fallbackPassword: Password; let email: Email
}

extension AuthService {
    var mailAvailable: Bool { configuration.smtpHost != nil && mailSender != nil }
    static func validEmail(_ email: String) -> Bool {
        email.utf8.count <= 254 && email.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil
    }
    func recoveryStatus(_ context: AuthContext, on db: any Database) async throws -> RecoveryStatusDTO {
        try context.normal()
        let id = try context.account.requireID()
        let remaining = try await RecoveryCode.query(on: db).filter(\.$accountId == id).filter(\.$usedAt == nil).count()
        let password = try await FallbackPassword.query(on: db).filter(\.$accountId == id).first()
        let email = try await EmailRecovery.query(on: db).filter(\.$accountId == id).first()
        return .init(recoveryCodes: .init(active: remaining > 0, remaining: remaining), fallbackPassword: .init(active: password != nil),
            email: .init(available: mailAvailable, active: mailAvailable && email?.active == true && email?.verifiedAt != nil, verified: email?.verifiedAt != nil))
    }
    func recoveryCodes(_ context: AuthContext, generate: Bool, on db: any Database) async throws -> [String] {
        try await transaction(on: db) { tx in
            let current = try await authenticate(context.token, on: tx); try current.fresh()
            let id = try current.account.requireID()
            try await RecoveryCode.query(on: tx).filter(\.$accountId == id).delete()
            let codes = generate ? (0..<10).map { _ in Secrets.token(bytes: 24) } : []
            for code in codes { try await RecoveryCode(accountId: id, codeHash: Secrets.hash(code)).create(on: tx) }
            return codes
        }
    }
    func fallbackPassword(_ password: String?, context: AuthContext, on db: any Database) async throws {
        try context.fresh()
        guard password.map({ (12...256).contains($0.count) }) ?? true else { throw APIError.invalid }
        // Run expensive hashing away from the event loop. Strip the library's trailing C NUL.
        let hash: String?
        if let password {
            hash = try await Task.detached {
                try Argon2Swift.hashPasswordString(password: password, salt: Salt.newSalt(length: 16), iterations: 3,
                    memory: 65536, parallelism: 1, length: 32, type: .id).encodedString().trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            }.value
        } else { hash = nil }
        try await transaction(on: db) { tx in
            let current = try await authenticate(context.token, on: tx); try current.fresh()
            let id = try current.account.requireID()
            try await FallbackPassword.query(on: tx).filter(\.$accountId == id).delete()
            if let hash { try await FallbackPassword(accountId: id, hash: hash, algorithm: "argon2id", updatedAt: Date()).create(on: tx) }
        }
    }
    func enableEmail(_ address: String, context: AuthContext, on db: any Database) async throws {
        try context.fresh()
        guard mailAvailable, let mailSender else { throw APIError(.notImplemented, "not_implemented") }
        guard Self.validEmail(address) else { throw APIError.invalid }
        let code = Secrets.token(bytes: 12)
        try await transaction(on: db) { tx in
            let current = try await authenticate(context.token, on: tx); try current.fresh()
            let id = try current.account.requireID()
            try await EmailRecovery.query(on: tx).filter(\.$accountId == id).delete()
            try await EmailRecovery(accountId: id, email: address, active: false).create(on: tx)
            try await RecoveryAttempt.query(on: tx).filter(\.$accountId == id).filter(\.$kind == .emailVerification).set(\.$consumedAt, to: Date()).update()
            try await RecoveryAttempt(kind: .emailVerification, accountId: id, codeHash: Secrets.hash(code), proofHash: Secrets.hash(address),
                expiresAt: Date().addingTimeInterval(600), attemptCount: 0, createdAt: Date()).create(on: tx)
        }
        try await mailSender.sendCode(code, to: address)
    }
    func disableEmail(_ context: AuthContext, on db: any Database) async throws {
        try await transaction(on: db) { tx in
            let current = try await authenticate(context.token, on: tx); try current.fresh()
            let id = try current.account.requireID()
            try await EmailRecovery.query(on: tx).filter(\.$accountId == id).delete()
            try await RecoveryAttempt.query(on: tx).filter(\.$accountId == id).group(.or) { $0.filter(\.$kind == .email).filter(\.$kind == .emailVerification) }
                .set(\.$consumedAt, to: Date()).update()
        }
    }
    func verifyEmail(_ code: String, context: AuthContext, on db: any Database) async throws {
        let valid = try await transaction(on: db) { tx in
            let current = try await authenticate(context.token, on: tx); try current.fresh()
            guard mailAvailable else { throw APIError(.notImplemented, "not_implemented") }
            let id = try current.account.requireID()
            guard let email = try await EmailRecovery.query(on: tx).filter(\.$accountId == id).first(),
                  let attempt = try await RecoveryAttempt.query(on: tx).filter(\.$accountId == id).filter(\.$kind == .emailVerification)
                    .filter(\.$consumedAt == nil).sort(\.$createdAt, .descending).first(),
                  attempt.expiresAt > Date(), attempt.attemptCount < 5 else { return false }
            attempt.attemptCount += 1; try await attempt.update(on: tx)
            guard Secrets.equal(attempt.codeHash ?? "", Secrets.hash(code)), Secrets.equal(attempt.proofHash ?? "", Secrets.hash(email.email)),
                  try await SingleUse.consume(.recoveryAttempt, id: attempt.requireID(), on: tx) else { return false }
            email.active = true; email.verifiedAt = Date(); try await email.update(on: tx)
            return true
        }
        guard valid else { throw APIError(.badRequest, "invalid_code") }
    }
    func recoveryStart(_ input: RecoveryStart, on db: any Database) async throws -> RecoveryStarted {
        guard input.method != .emailVerification, input.identifier.count <= 32 else { throw APIError.invalid }
        let code = Secrets.token(bytes: 12)
        let result: (UUID, String?) = try await transaction(on: db) { tx in
            let account = try await Account.query(on: tx).filter(\.$handle == input.identifier).filter(\.$disabledAt == nil).first()
            var accountID = account?.id
            var emailAddress: String?
            var proofHash: String?
            if let id = accountID {
                switch input.method {
                case .email:
                    if mailAvailable, let email = try await EmailRecovery.query(on: tx).filter(\.$accountId == id).filter(\.$active == true).first(), email.verifiedAt != nil {
                        emailAddress = email.email; proofHash = Secrets.hash(email.email)
                    } else { accountID = nil }
                case .fallbackPassword:
                    if let password = try await FallbackPassword.query(on: tx).filter(\.$accountId == id).first() { proofHash = Secrets.hash(password.hash) }
                    else { accountID = nil }
                case .recoveryCode:
                    if try await RecoveryCode.query(on: tx).filter(\.$accountId == id).filter(\.$usedAt == nil).count() == 0 { accountID = nil }
                case .emailVerification: throw APIError.invalid
                }
            }
            let attempt = RecoveryAttempt(kind: input.method, accountId: accountID, codeHash: input.method == .email ? Secrets.hash(code) : nil,
                proofHash: proofHash, expiresAt: Date().addingTimeInterval(600), attemptCount: 0, createdAt: Date())
            try await attempt.create(on: tx)
            return (try attempt.requireID(), emailAddress)
        }
        // Delivery failure must not turn this anti-enumeration response into a different status.
        if let address = result.1, let mailSender { try? await mailSender.sendCode(code, to: address) }
        return .init(recoveryId: result.0)
    }
    func recoveryComplete(_ input: RecoveryProof, on db: any Database) async throws -> AuthContext {
        guard input.proof.count <= 256 else { throw APIError.unauthorized }
        let context: AuthContext? = try await transaction(on: db) { tx in
            guard let attempt = try await RecoveryAttempt.find(input.recoveryId, on: tx), attempt.kind != .emailVerification,
                  attempt.consumedAt == nil, attempt.expiresAt > Date(), attempt.attemptCount < 5 else { return nil }
            attempt.attemptCount += 1; try await attempt.update(on: tx)
            var passwordVerified = false
            if attempt.kind == .fallbackPassword {
                let password: FallbackPassword?
                if let id = attempt.accountId { password = try await FallbackPassword.query(on: tx).filter(\.$accountId == id).first() }
                else { password = nil }
                let encoded = password.flatMap { Secrets.equal(Secrets.hash($0.hash), attempt.proofHash ?? "") ? $0.hash : nil }
                // Unknown accounts and unavailable passwords perform the same expensive KDF.
                passwordVerified = try await Task.detached {
                    if let encoded { return try Argon2Swift.verifyHashString(password: input.proof, hash: encoded, type: .id) }
                    _ = try Argon2Swift.hashPasswordString(password: input.proof, salt: Salt.newSalt(length: 16), iterations: 3,
                        memory: 65536, parallelism: 1, length: 32, type: .id)
                    return false
                }.value
            }
            guard let id = attempt.accountId, let account = try await Account.find(id, on: tx), account.disabledAt == nil else { return nil }
            switch attempt.kind {
            case .recoveryCode:
                guard let code = try await RecoveryCode.query(on: tx).filter(\.$accountId == id).filter(\.$codeHash == Secrets.hash(input.proof)).first(),
                      try await SingleUse.consume(.recoveryCode, id: code.requireID(), on: tx) else { return nil }
            case .fallbackPassword:
                guard passwordVerified else { return nil }
            case .email:
                guard mailAvailable, let email = try await EmailRecovery.query(on: tx).filter(\.$accountId == id).first(), email.active, email.verifiedAt != nil,
                      Secrets.equal(attempt.proofHash ?? "", Secrets.hash(email.email)), Secrets.equal(attempt.codeHash ?? "", Secrets.hash(input.proof)) else { return nil }
            case .emailVerification: return nil
            }
            guard try await SingleUse.consume(.recoveryAttempt, id: input.recoveryId, on: tx) else { throw APIError.unauthorized }
            return try await issueSession(for: account, recovery: true, on: tx)
        }
        guard let context else { throw APIError.unauthorized }; return context
    }
}
