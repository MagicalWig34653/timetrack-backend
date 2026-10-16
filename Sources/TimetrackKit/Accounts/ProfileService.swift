import Vapor
import Fluent

/// Profile editing and the onboarding flag (ADR-0019). Every operation acts on the caller's own account only; there is no
/// account id in any path or body, so one account cannot address another one.
extension AuthService {
    static let emailChangeLifetime: TimeInterval = 600
    static let emailChangeAttempts = 5

    static func normalizedEmail(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return validEmail(value) ? value : nil
    }

    func profile(_ context: AuthContext, on db: any Database) async throws -> ProfileDTO {
        try context.normal()
        let id = try context.account.requireID()
        guard let account = try await Account.find(id, on: db) else { throw APIError.unauthorized }
        let pending = try await EmailChangeRequest.query(on: db).filter(\.$accountId == id).first()
        return Self.profileDTO(account, pending: pending.flatMap { $0.expiresAt > Date() ? $0.email : nil }, mailAvailable: mailAvailable)
    }

    static func profileDTO(_ account: Account, pending: String?, mailAvailable: Bool) -> ProfileDTO {
        ProfileDTO(handle: account.handle, displayName: account.displayName, email: account.email, emailVerified: account.email != nil && account.emailVerifiedAt != nil,
            pendingEmail: pending, mailAvailable: mailAvailable,
            onboarding: .init(state: account.onboardingState ?? "pending", updatedAt: account.onboardingUpdatedAt))
    }

    func updateProfile(_ patch: ProfilePatch, context: AuthContext, on db: any Database) async throws -> ProfileDTO {
        try context.normal()
        let name = patch.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, (1...80).contains(name.count) else { throw APIError.invalid }
        try await transaction(on: db) { tx in
            let current = try await authenticate(context.token, on: tx); try current.normal()
            let account = current.account
            account.displayName = name
            try await account.update(on: tx)
            try await AccountAuditRecord(action: "profile.name_changed", actor: account.requireID(), target: account.requireID()).create(on: tx)
        }
        return try await profile(context, on: db)
    }

    /// Mails a code to the new address. The address only becomes the account's address once the code is confirmed.
    func requestEmailChange(_ address: String, context: AuthContext, on db: any Database) async throws {
        try context.fresh()
        guard mailAvailable, let mailSender else { throw APIError(.notImplemented, "not_implemented") }
        guard let address = Self.normalizedEmail(address) else { throw APIError.invalid }
        let code = Secrets.token(bytes: 12)
        try await transaction(on: db) { tx in
            let current = try await authenticate(context.token, on: tx); try current.fresh()
            let id = try current.account.requireID()
            if current.account.email == address, current.account.emailVerifiedAt != nil { throw APIError.invalid }
            try await EmailChangeRequest.query(on: tx).filter(\.$accountId == id).delete()
            try await EmailChangeRequest(accountId: id, email: address, codeHash: Secrets.hash(code),
                expiresAt: Date().addingTimeInterval(Self.emailChangeLifetime)).create(on: tx)
        }
        try await mailSender.sendCode(code, to: address)
    }

    func confirmEmailChange(_ code: String, context: AuthContext, on db: any Database) async throws -> ProfileDTO {
        enum Outcome { case done, invalid, taken }
        let outcome: Outcome = try await transaction(on: db) { tx in
            let current = try await authenticate(context.token, on: tx); try current.fresh()
            guard mailAvailable else { throw APIError(.notImplemented, "not_implemented") }
            let id = try current.account.requireID()
            guard let request = try await EmailChangeRequest.query(on: tx).filter(\.$accountId == id).first(),
                  request.expiresAt > Date(), request.attemptCount < Self.emailChangeAttempts else { return .invalid }
            request.attemptCount += 1; try await request.update(on: tx)
            guard Secrets.equal(request.codeHash, Secrets.hash(code)) else { return .invalid }
            // The auth lock serializes this check with every other confirmation, so two accounts can never both win the same address.
            let holder = try await Account.query(on: tx).filter(\.$email == request.email).filter(\.$emailVerifiedAt != nil).filter(\.$id != id).first()
            try await request.delete(on: tx)
            if holder != nil { return .taken }
            let account = current.account
            account.email = request.email; account.emailVerifiedAt = Date()
            try await account.update(on: tx)
            try await AccountAuditRecord(action: "profile.email_changed", actor: id, target: id).create(on: tx)
            return .done
        }
        switch outcome {
        case .invalid: throw APIError(.badRequest, "invalid_code")
        case .taken: throw APIError(.conflict, "email_taken")
        case .done: return try await profile(context, on: db)
        }
    }

    func removeEmail(_ context: AuthContext, on db: any Database) async throws {
        try await transaction(on: db) { tx in
            let current = try await authenticate(context.token, on: tx); try current.fresh()
            let id = try current.account.requireID()
            try await EmailChangeRequest.query(on: tx).filter(\.$accountId == id).delete()
            let account = current.account
            guard account.email != nil else { return }
            account.email = nil; account.emailVerifiedAt = nil
            try await account.update(on: tx)
            try await AccountAuditRecord(action: "profile.email_removed", actor: id, target: id).create(on: tx)
        }
    }

    func setOnboarding(_ state: String, context: AuthContext, on db: any Database) async throws -> ProfileDTO {
        try context.normal()
        guard ["pending", "completed", "skipped"].contains(state) else { throw APIError.invalid }
        try await transaction(on: db) { tx in
            let current = try await authenticate(context.token, on: tx); try current.normal()
            let account = current.account
            account.onboardingState = state == "pending" ? nil : state
            account.onboardingUpdatedAt = Date()
            try await account.update(on: tx)
            try await AccountAuditRecord(action: "onboarding." + state, actor: account.requireID(), target: account.requireID()).create(on: tx)
        }
        return try await profile(context, on: db)
    }
}
