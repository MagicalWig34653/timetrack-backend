import Vapor
import Fluent
import WebAuthn
@preconcurrency import SwiftCBOR

extension AuthService {
    func requireSameOriginClient(_ bytes: [UInt8]) throws {
        struct ClientContext: Decodable { let crossOrigin: Bool?; let topOrigin: String? }
        guard let context = try? JSONDecoder().decode(ClientContext.self, from: Data(bytes)),
              context.crossOrigin != true, context.topOrigin == nil else { throw APIError.invalid }
    }
    func registrationOptions(_ input: RegisterInput, on db: any Database) async throws -> OptionsDTO {
        guard input.handle.range(of: "^[a-z0-9][a-z0-9._-]{2,31}$", options: .regularExpression) == input.handle.startIndex..<input.handle.endIndex,
              (1...80).contains(input.displayName.count), input.email.map(Self.validEmail) ?? true else { throw APIError.invalid }
        return try await transaction(on: db) { tx in
            let invite = try await invitation(input.inviteToken, on: tx)
            guard try await Account.query(on: tx).filter(\.$handle == input.handle).first() == nil else { throw APIError(.conflict, "handle_taken") }
            let accountID = UUID()
            let options = webAuthn.beginRegistration(user: .init(id: Array(accountID.uuidString.utf8), name: input.handle, displayName: input.displayName))
            let challenge = WebAuthnChallenge(purpose: .registration, challenge: Data(options.challenge),
                payload: ["accountID": .string(accountID.uuidString), "handle": .string(input.handle), "displayName": .string(input.displayName), "email": input.email.map(JSONValue.string) ?? .null],
                invitationId: try invite.requireID(), expiresAt: Date().addingTimeInterval(300))
            try await challenge.create(on: tx)
            return try creationOptions(options, challenge: challenge, excluding: [])
        }
    }
    func creationOptions(_ options: PublicKeyCredentialCreationOptions, challenge: WebAuthnChallenge, excluding keys: [Passkey]) throws -> OptionsDTO {
        guard case .object(var object) = try JSONValue.encoding(options) else { throw APIError.invalid }
        object["authenticatorSelection"] = .object(["residentKey": .string("required"), "requireResidentKey": .bool(true), "userVerification": .string("required")])
        object["excludeCredentials"] = .array(keys.map { .object(["type": .string("public-key"), "id": .string($0.credentialId.base64URL)]) })
        return try OptionsDTO(challengeId: challenge.requireID(), publicKey: .object(object))
    }
    func challenge(_ id: UUID, purpose: ChallengePurpose, on db: any Database) async throws -> WebAuthnChallenge {
        guard let challenge = try await WebAuthnChallenge.find(id, on: db), challenge.purpose == purpose,
              challenge.consumedAt == nil, challenge.expiresAt > Date() else { throw APIError.invalid }
        return challenge
    }
    func verifyRegistration(_ proof: RegisterProof, challenge: WebAuthnChallenge, accountID: UUID, on db: any Database) async throws -> Passkey {
        guard (proof.passkeyName?.count ?? 0) <= 80, !proof.credential.rawID.isEmpty,
              proof.credential.id.decodedBytes == proof.credential.rawID else { throw APIError.invalid }
        try requireSameOriginClient(proof.credential.attestationResponse.clientDataJSON)
        let credential: Credential
        do {
            credential = try await webAuthn.finishRegistration(challenge: Array(challenge.challenge), credentialCreationData: proof.credential, requireUserVerification: true) { _ in
                try await Passkey.query(on: db).filter(\.$credentialId == Data(proof.credential.rawID)).first() == nil
            }
        } catch { throw APIError.invalid }
        // The library verifies the attestation; additionally bind its credential ID to the envelope.
        // Upstream beta exposes only the envelope ID in Credential, not the attested ID.
        guard let attestation = try? CBOR.decode(proof.credential.attestationResponse.attestationObject, options: CBOROptions(maximumDepth: 16)),
              case .byteString(let data) = attestation["authData"], data.count >= 55 else { throw APIError.invalid }
        let length = Int(data[53]) * 256 + Int(data[54])
        guard data.count >= 55 + length, Array(data[55..<(55 + length)]) == proof.credential.rawID else { throw APIError.invalid }
        return Passkey(accountId: accountID, credentialId: Data(proof.credential.rawID), publicKey: Data(credential.publicKey), signCount: Int64(credential.signCount),
                       name: proof.passkeyName ?? "Passkey", transports: [], backedUp: credential.isBackedUp, createdAt: Date())
    }
    func register(_ proof: RegisterProof, on db: any Database) async throws -> AuthContext {
        try await transaction(on: db) { tx in
            let challenge = try await challenge(proof.challengeId, purpose: .registration, on: tx)
            guard let inviteID = challenge.invitationId, let invite = try await Invitation.find(inviteID, on: tx),
                  try await SingleUse.consume(.invitation, id: inviteID, on: tx) else { throw APIError.missing }
            guard let accountID = challenge.payload["accountID"]?.string.flatMap(UUID.init(uuidString:)),
                  let handle = challenge.payload["handle"]?.string, let name = challenge.payload["displayName"]?.string else { throw APIError.invalid }
            guard try await Account.query(on: tx).filter(\.$handle == handle).first() == nil else { throw APIError(.conflict, "handle_taken") }
            let key = try await verifyRegistration(proof, challenge: challenge, accountID: accountID, on: tx)
            guard try await SingleUse.consume(.challenge, id: proof.challengeId, on: tx) else { throw APIError.invalid }
            let account = Account(id: accountID, handle: handle, displayName: name, email: challenge.payload["email"]?.string, role: invite.role, createdAt: Date())
            try await account.create(on: tx)
            try await key.create(on: tx)
            try await Invitation.query(on: tx).filter(\.$id == inviteID).set(\.$usedBy, to: accountID).update()
            return try await issueSession(for: account, on: tx)
        }
    }
    func loginOptions(on db: any Database) async throws -> OptionsDTO {
        let options = webAuthn.beginAuthentication(userVerification: .required)
        let challenge = WebAuthnChallenge(purpose: .authentication, challenge: Data(options.challenge), payload: [:], expiresAt: Date().addingTimeInterval(300))
        try await challenge.create(on: db)
        return try OptionsDTO(challengeId: challenge.requireID(), publicKey: .encoding(options))
    }
    func login(_ proof: LoginProof, on db: any Database) async throws -> AuthContext {
        try await transaction(on: db) { tx in
            guard let challenge = try? await challenge(proof.challengeId, purpose: .authentication, on: tx),
                  proof.credential.id.decodedBytes == proof.credential.rawID,
                  let key = try await Passkey.query(on: tx).filter(\.$credentialId == Data(proof.credential.rawID)).filter(\.$revokedAt == nil).first(),
                  let account = try await Account.find(key.accountId, on: tx), account.disabledAt == nil,
                  proof.credential.response.userHandle == Array(try account.requireID().uuidString.utf8) else { throw APIError.unauthorized }
            let verified: VerifiedAuthentication
            do {
                try requireSameOriginClient(proof.credential.response.clientDataJSON)
                verified = try webAuthn.finishAuthentication(credential: proof.credential, expectedChallenge: Array(challenge.challenge),
                    credentialPublicKey: Array(key.publicKey), credentialCurrentSignCount: UInt32(key.signCount), requireUserVerification: true)
            } catch { throw APIError.unauthorized }
            guard try await SingleUse.consume(.challenge, id: proof.challengeId, on: tx) else { throw APIError.unauthorized }
            key.signCount = Int64(verified.newSignCount); key.backedUp = verified.credentialBackedUp; key.lastUsedAt = Date()
            try await key.update(on: tx)
            return try await issueSession(for: account, on: tx)
        }
    }
    func addOptions(_ context: AuthContext, on db: any Database) async throws -> OptionsDTO {
        try await transaction(on: db) { tx in
            let current = try await authenticate(context.token, on: tx); try current.fresh(allowRecovery: true)
            let account = current.account
            let options = webAuthn.beginRegistration(user: .init(id: Array(try account.requireID().uuidString.utf8), name: account.handle, displayName: account.displayName))
            let challenge = WebAuthnChallenge(purpose: .addPasskey, challenge: Data(options.challenge), payload: ["sessionID": .string(try current.session.requireID().uuidString)],
                accountId: try account.requireID(), expiresAt: Date().addingTimeInterval(300))
            try await challenge.create(on: tx)
            return try await creationOptions(options, challenge: challenge, excluding: Passkey.query(on: tx).filter(\.$accountId == account.requireID()).filter(\.$revokedAt == nil).all())
        }
    }
    func addPasskey(_ proof: RegisterProof, context: AuthContext, on db: any Database) async throws -> PasskeyDTO {
        try await transaction(on: db) { tx in
            let current = try await authenticate(context.token, on: tx); try current.fresh(allowRecovery: true)
            let challenge = try await challenge(proof.challengeId, purpose: .addPasskey, on: tx)
            guard challenge.accountId == current.account.id, challenge.payload["sessionID"]?.string == current.session.id?.uuidString else { throw APIError.missing }
            let key = try await verifyRegistration(proof, challenge: challenge, accountID: current.account.requireID(), on: tx)
            guard try await SingleUse.consume(.challenge, id: proof.challengeId, on: tx) else { throw APIError.invalid }
            try await key.create(on: tx)
            if current.session.recovery {
                try await Session.query(on: tx).filter(\.$id == current.session.requireID()).set(\.$recovery, to: false)
                    .set(\.$createdAt, to: Date()).set(\.$expiresAt, to: Date().addingTimeInterval(Double(configuration.sessionTTLHours * 3600))).update()
            }
            return try PasskeyDTO(key)
        }
    }
    func passkeys(_ context: AuthContext, on db: any Database) async throws -> [PasskeyDTO] {
        try context.normal()
        return try await Passkey.query(on: db).filter(\.$accountId == context.account.requireID()).filter(\.$revokedAt == nil).sort(\.$createdAt).all().map(PasskeyDTO.init)
    }
    func changePasskey(_ id: UUID, name: String?, context: AuthContext, on db: any Database) async throws -> PasskeyDTO {
        try await transaction(on: db) { tx in
            let current = try await authenticate(context.token, on: tx); try current.normal()
            guard let key = try await Passkey.query(on: tx).filter(\.$id == id).filter(\.$accountId == current.account.requireID()).filter(\.$revokedAt == nil).first() else { throw APIError.missing }
            if let name {
                guard name.count <= 80 else { throw APIError.invalid }; key.name = name
            } else {
                try current.fresh()
                let count = try await Passkey.query(on: tx).filter(\.$accountId == key.accountId).filter(\.$revokedAt == nil).count()
                let recovery = try await recoveryStatus(current, on: tx)
                guard count > 1 || recovery.recoveryCodes.active || recovery.fallbackPassword.active || recovery.email.active else { throw APIError(.conflict, "last_passkey") }
                key.revokedAt = Date()
            }
            try await key.update(on: tx); return try PasskeyDTO(key)
        }
    }
}
