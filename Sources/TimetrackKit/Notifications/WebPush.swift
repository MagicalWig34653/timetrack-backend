import Foundation
import Crypto

/// Web Push primitives: RFC 8291 (aes128gcm message encryption) and RFC 8292 (VAPID). No logging, no state.
enum WebPushCrypto {
    enum Failure: Error { case invalidKey, invalidRecord, payloadTooLarge }

    /// Encrypts `plaintext` for one user agent. Output is the complete aes128gcm body (header + single record).
    /// `padding` zero bytes are appended after the delimiter; the record size bounds the payload (4096 per RFC 8291, max 3993 bytes of data).
    static func encrypt(_ plaintext: Data, userAgentPublicKey: Data, authSecret: Data,
                        senderKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
                        salt: Data = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }),
                        recordSize: Int = 4096, paddedLength: Int = 0) throws -> Data {
        guard salt.count == 16, authSecret.count == 16, let uaKey = try? P256.KeyAgreement.PublicKey(x963Representation: userAgentPublicKey) else { throw Failure.invalidKey }
        let senderPublic = senderKey.publicKey.x963Representation
        let (key, nonce) = try derive(secret: senderKey.sharedSecretFromKeyAgreement(with: uaKey), authSecret: authSecret, salt: salt,
                                      uaPublic: userAgentPublicKey, asPublic: senderPublic)
        var record = plaintext + Data([0x02])
        if paddedLength > plaintext.count { record += Data(repeating: 0, count: paddedLength - plaintext.count) }
        guard record.count + 16 <= recordSize else { throw Failure.payloadTooLarge }
        let sealed = try AES.GCM.seal(record, using: key, nonce: AES.GCM.Nonce(data: nonce))
        var header = salt
        header += withUnsafeBytes(of: UInt32(recordSize).bigEndian) { Data($0) }
        header += Data([UInt8(senderPublic.count)]) + senderPublic
        return header + sealed.ciphertext + sealed.tag
    }

    /// Decrypts a body produced by `encrypt` (used by tests acting as the user agent, and for the RFC vector).
    static func decrypt(_ body: Data, userAgentKey: P256.KeyAgreement.PrivateKey, authSecret: Data) throws -> Data {
        let bytes = [UInt8](body)
        guard bytes.count > 86 else { throw Failure.invalidRecord }
        let salt = Data(bytes[0..<16])
        let size = Int(bytes[16]) << 24 | Int(bytes[17]) << 16 | Int(bytes[18]) << 8 | Int(bytes[19])
        let idLength = Int(bytes[20])
        guard idLength == 65, bytes.count >= 21 + idLength + 17, size >= 18, bytes.count - 21 - idLength <= size else { throw Failure.invalidRecord }
        let senderPublic = Data(bytes[21..<(21 + idLength)])
        guard let senderKey = try? P256.KeyAgreement.PublicKey(x963Representation: senderPublic) else { throw Failure.invalidKey }
        let (key, nonce) = try derive(secret: userAgentKey.sharedSecretFromKeyAgreement(with: senderKey), authSecret: authSecret, salt: salt,
                                      uaPublic: userAgentKey.publicKey.x963Representation, asPublic: senderPublic)
        let encrypted = Data(bytes[(21 + idLength)...])
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16))
        var plain = [UInt8](try AES.GCM.open(box, using: key))
        while plain.last == 0 { plain.removeLast() }
        guard plain.last == 0x02 else { throw Failure.invalidRecord }
        plain.removeLast()
        return Data(plain)
    }

    private static func derive(secret: SharedSecret, authSecret: Data, salt: Data, uaPublic: Data, asPublic: Data) throws -> (SymmetricKey, Data) {
        let keyInfo = Data("WebPush: info".utf8) + Data([0]) + uaPublic + asPublic
        let ikm = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: authSecret, sharedInfo: keyInfo, outputByteCount: 32)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm".utf8) + Data([0]), outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce".utf8) + Data([0]), outputByteCount: 12)
        return (key, nonce.withUnsafeBytes { Data($0) })
    }
}

/// VAPID key pair and subject from the environment (ADR-0010). Absent or invalid values mean "push unavailable".
struct VapidConfiguration: Sendable {
    let privateKey: P256.Signing.PrivateKey
    let subject: String
    var publicKey: Data { privateKey.publicKey.x963Representation }
    var publicKeyBase64URL: String { publicKey.base64URL }

    init?(environment: [String: String]) {
        guard let raw = environment["VAPID_PRIVATE_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let data = Data(base64URL: raw.replacingOccurrences(of: "=", with: "")), data.count == 32,
              let key = try? P256.Signing.PrivateKey(rawRepresentation: data),
              let subject = environment["VAPID_SUBJECT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.validSubject(subject) else { return nil }
        privateKey = key; self.subject = subject
    }
    init(privateKey: P256.Signing.PrivateKey, subject: String) { self.privateKey = privateKey; self.subject = subject }

    static func validSubject(_ value: String) -> Bool {
        if value.hasPrefix("mailto:") { let address = value.dropFirst(7); return address.count > 3 && address.contains("@") && !address.contains(" ") }
        if value.hasPrefix("https://") { return URL(string: value)?.host?.isEmpty == false }
        return false
    }

    /// RFC 8292 JWT: ES256, `aud` = push service origin, `exp` at most 12 h ahead.
    func authorization(audience: String, now: Date, lifetime: TimeInterval = 12 * 3600 - 60) throws -> String {
        let header = Data(#"{"typ":"JWT","alg":"ES256"}"#.utf8).base64URL
        let claims: [String: Any] = ["aud": audience, "exp": Int(now.timeIntervalSince1970 + min(lifetime, 12 * 3600)), "sub": subject]
        let body = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]).base64URL
        let signature = try privateKey.signature(for: Data((header + "." + body).utf8)).rawRepresentation.base64URL
        return "vapid t=\(header).\(body).\(signature), k=\(publicKeyBase64URL)"
    }

    static func origin(of endpoint: String) -> String? {
        guard let url = URL(string: endpoint), let scheme = url.scheme, let host = url.host else { return nil }
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return scheme + "://" + hostPart + (url.port.map { ":\($0)" } ?? "")
    }
}
