import Foundation
import Crypto
import WebAuthn
@testable import TimetrackKit

/// Minimal CTAP/WebAuthn wire fixture. All signatures use swift-crypto P-256.
struct SoftwareAuthenticator: Sendable {
    let privateKey = P256.Signing.PrivateKey()
    let credentialID = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    func clientData(challenge: String, type: String, origin: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "challenge": challenge, "origin": origin, "crossOrigin": false], options: [.sortedKeys])
    }
    func registration(_ options: OptionsDTO, origin: String = "http://localhost:18080", flags: UInt8 = 0x45) throws -> RegisterProof {
        guard case .object(let object) = options.publicKey, let challenge = object["challenge"]?.string else { throw APIError.invalid }
        let coordinates = Array(privateKey.publicKey.x963Representation.dropFirst())
        let cose: [UInt8] = [0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21] + bytes(Array(coordinates.prefix(32))) + [0x22] + bytes(Array(coordinates.suffix(32)))
        let auth = Array(SHA256.hash(data: Data("localhost".utf8))) + [flags, 0, 0, 0, 0] + Array(repeating: UInt8(0), count: 16) + [0, 32] + Array(credentialID) + cose
        let attestation = [UInt8(0xa3)] + text("fmt") + text("none") + text("attStmt") + [0xa0] + text("authData") + bytes(auth)
        let data = try clientData(challenge: challenge, type: "webauthn.create", origin: origin)
        let json: [String: Any] = ["id": credentialID.base64URL, "rawId": credentialID.base64URL, "type": "public-key", "response": ["clientDataJSON": data.base64URL, "attestationObject": Data(attestation).base64URL, "transports": ["internal"]]]
        let credential = try JSONDecoder().decode(RegistrationCredential.self, from: JSONSerialization.data(withJSONObject: json))
        return RegisterProof(challengeId: options.challengeId, credential: credential, passkeyName: "Software key")
    }
    func assertion(_ options: OptionsDTO, accountID: UUID, count: UInt32 = 1, origin: String = "http://localhost:18080", flags: UInt8 = 5) throws -> LoginProof {
        guard case .object(let object) = options.publicKey, let challenge = object["challenge"]?.string else { throw APIError.invalid }
        let client = try clientData(challenge: challenge, type: "webauthn.get", origin: origin)
        let counter = [UInt8(count >> 24), UInt8(truncatingIfNeeded: count >> 16), UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)]
        let auth = Data(Array(SHA256.hash(data: Data("localhost".utf8))) + [flags] + counter)
        let signature = try privateKey.signature(for: auth + Data(SHA256.hash(data: client))).derRepresentation
        let json: [String: Any] = ["id": credentialID.base64URL, "rawId": credentialID.base64URL, "type": "public-key", "response": ["clientDataJSON": client.base64URL, "authenticatorData": auth.base64URL, "signature": signature.base64URL, "userHandle": Data(accountID.uuidString.utf8).base64URL]]
        return try LoginProof(challengeId: options.challengeId, credential: JSONDecoder().decode(AuthenticationCredential.self, from: JSONSerialization.data(withJSONObject: json)))
    }
    private func text(_ value: String) -> [UInt8] { [0x60 + UInt8(value.utf8.count)] + Array(value.utf8) }
    private func bytes(_ value: [UInt8]) -> [UInt8] {
        (value.count < 24 ? [0x40 + UInt8(value.count)] : value.count < 256 ? [0x58, UInt8(value.count)] : [0x59, UInt8(value.count >> 8), UInt8(truncatingIfNeeded: value.count)]) + value
    }
}

actor RecordingMailSender: MailSender {
    private var messages: [(String, String)] = []
    func sendCode(_ code: String, to address: String) { messages.append((address, code)) }
    func lastCode() -> String { messages.last!.1 }
}
