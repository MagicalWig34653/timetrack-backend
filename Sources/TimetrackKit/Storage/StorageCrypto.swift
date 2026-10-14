import Foundation
import Crypto

/// AES-256-GCM box for the stored S3 secret. The key comes from `STORAGE_SECRET_KEY` (base64, 32 bytes).
struct SecretBox: Sendable {
    private let key: SymmetricKey
    private static let context = Data("timetrack.storage.s3secret.v1".utf8)

    /// Returns nil for a missing or malformed key (callers answer 501 not_implemented).
    init?(base64Key: String?) {
        guard let text = base64Key?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let data = Data(base64Encoded: text), data.count == 32 else { return nil }
        key = SymmetricKey(data: data)
    }

    /// `ciphertext` contains the GCM tag; the nonce is stored separately.
    func seal(_ secret: String) throws -> (ciphertext: Data, nonce: Data) {
        let sealed = try AES.GCM.seal(Data(secret.utf8), using: key, nonce: AES.GCM.Nonce(), authenticating: Self.context)
        var combined = Data(); combined.append(contentsOf: sealed.ciphertext); combined.append(contentsOf: sealed.tag)
        return (combined, Data(sealed.nonce))
    }

    func open(ciphertext: Data, nonce: Data) throws -> String {
        guard ciphertext.count >= 16 else { throw CryptoKitError.incorrectParameterSize }
        let tag = Data(ciphertext.suffix(16)), body = Data(ciphertext.dropLast(16))
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: body, tag: tag)
        let plain = try AES.GCM.open(box, using: key, authenticating: Self.context)
        guard let text = String(data: plain, encoding: .utf8) else { throw CryptoKitError.incorrectParameterSize }
        return text
    }
}
