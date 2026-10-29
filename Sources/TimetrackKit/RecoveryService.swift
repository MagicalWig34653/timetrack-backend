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
    /// C3: recovery codes go to the account e-mail (`accountEmail`); there is no separate recovery address any more.
    /// `verified` states whether the account e-mail is verified. `usesAccountEmail` is always true (marker for clients).
    struct Email: Content {
        let available: Bool; let active: Bool; let verified: Bool
        let accountEmail: String?; let usesAccountEmail: Bool
    }
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
        // Re-read: the context's account object can predate a confirmation made in this session.
        let account = try await Account.find(id, on: db) ?? context.account
        let verified = account.email != nil && account.emailVerifiedAt != nil
        return .init(recoveryCodes: .init(active: remaining > 0, remaining: remaining), fallbackPassword: .init(active: password != nil),
            email: .init(available: mailAvailable, active: mailAvailable && email?.active == true && verified, verified: verified,
                         accountEmail: account.email, usesAccountEmail: true))
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
    /// Switches on recovery by e-mail. The code always goes to the account e-mail (C3, ADR-0032 addendum / ARCHITEKTUR):
    /// - no `address` and a verified account e-mail: active at once, returns true (no code needed);
    /// - no `address` and an unverified account e-mail: a code is mailed to it, `verifyEmail` confirms both;
    /// - `address` equal to a verified account e-mail: legacy two-step flow (code mailed, `verifyEmail` activates);
    /// - `address` and no or an unverified account e-mail: the address is verified by code and then becomes the account e-mail;
    /// - `address` different from a verified account e-mail: 409 `recovery_email_must_be_account_email`.
    /// Returns whether recovery is active already.
    @discardableResult
    func enableEmail(_ address: String?, context: AuthContext, on db: any Database) async throws -> Bool {
        try context.fresh()
        guard mailAvailable, let mailSender else { throw APIError(.notImplemented, "not_implemented") }
        let requested: String?
        if let address { guard let normalised = Self.normalizedEmail(address) else { throw APIError.invalid }; requested = normalised } else { requested = nil }
        let code = Secrets.token(bytes: 12)
        let target: String? = try await transaction(on: db) { tx in
            let current = try await authenticate(context.token, on: tx); try current.fresh()
            let account = current.account, id = try account.requireID()
            let accountVerified = account.email != nil && account.emailVerifiedAt != nil
            if accountVerified, let mail = account.email {
                if let requested, requested != mail { throw APIError(.conflict, "recovery_email_must_be_account_email") }
                if requested == nil {
                    try await EmailRecovery.query(on: tx).filter(\.$accountId == id).delete()
                    try await EmailRecovery(accountId: id, email: mail, verifiedAt: account.emailVerifiedAt, active: true).create(on: tx)
                    return nil
                }
            }
            guard let target = requested ?? account.email else { throw APIError(.conflict, "account_email_missing") }
            if try await Account.query(on: tx).filter(\.$email == target).filter(\.$emailVerifiedAt != nil).filter(\.$id != id).first() != nil {
                throw APIError(.conflict, "email_taken")
            }
            try await EmailRecovery.query(on: tx).filter(\.$accountId == id).delete()
            try await EmailRecovery(accountId: id, email: target, active: false).create(on: tx)
            try await RecoveryAttempt.query(on: tx).filter(\.$accountId == id).filter(\.$kind == .emailVerification).set(\.$consumedAt, to: Date()).update()
            try await RecoveryAttempt(kind: .emailVerification, accountId: id, codeHash: Secrets.hash(code), proofHash: Secrets.hash(target),
                expiresAt: Date().addingTimeInterval(600), attemptCount: 0, createdAt: Date()).create(on: tx)
            return target
        }
        guard let target else { return true }
        try await mailSender.sendCode(code, to: target)
        return false
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
            // Proving the mailbox also verifies the account e-mail (the single address for codes). The auth lock serializes
            // this check, so two accounts cannot both win the same address.
            let account = current.account
            if account.email != email.email || account.emailVerifiedAt == nil {
                guard try await Account.query(on: tx).filter(\.$email == email.email).filter(\.$emailVerifiedAt != nil).filter(\.$id != id).first() == nil
                else { throw APIError(.conflict, "email_taken") }
                account.email = email.email; account.emailVerifiedAt = Date(); try await account.update(on: tx)
                try await AccountAuditRecord(action: "profile.email_changed", actor: id, target: id).create(on: tx)
            }
            email.active = true; email.verifiedAt = account.emailVerifiedAt ?? Date(); try await email.update(on: tx)
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
                    // C3: the code goes to the verified account e-mail; the recovery row only records that the user switched it on.
                    if mailAvailable, try await EmailRecovery.query(on: tx).filter(\.$accountId == id).filter(\.$active == true).first() != nil,
                       let mail = account?.email, account?.emailVerifiedAt != nil {
                        emailAddress = mail; proofHash = Secrets.hash(mail)
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
                guard mailAvailable, let email = try await EmailRecovery.query(on: tx).filter(\.$accountId == id).first(), email.active,
                      let mail = account.email, account.emailVerifiedAt != nil,
                      Secrets.equal(attempt.proofHash ?? "", Secrets.hash(mail)), Secrets.equal(attempt.codeHash ?? "", Secrets.hash(input.proof)) else { return nil }
            case .emailVerification: return nil
            }
            guard try await SingleUse.consume(.recoveryAttempt, id: input.recoveryId, on: tx) else { throw APIError.unauthorized }
            return try await issueSession(for: account, recovery: true, on: tx)
        }
        guard let context else { throw APIError.unauthorized }; return context
    }
}
