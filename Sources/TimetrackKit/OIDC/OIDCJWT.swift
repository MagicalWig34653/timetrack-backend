import Foundation
import Crypto
import _CryptoExtras

enum OIDCTokenError: Error, Sendable, Equatable {
    case malformed, unsupportedAlgorithm, unknownKey, badSignature, claim(String)
}

/// A provider signing key from a JWKS document.
struct OIDCJWK: Sendable {
    enum Material: Sendable { case rsa(n: Data, e: Data), ec(x: Data, y: Data) }
    let kid: String?
    let alg: String?
    let material: Material

    /// Parses the supported subset (RSA, P-256 EC, signing use). Unsupported keys are skipped by the caller.
    init?(json: [String: Any]) {
        if let use = json["use"] as? String, use != "sig" { return nil }
        kid = json["kid"] as? String
        alg = json["alg"] as? String
        func part(_ key: String) -> Data? { (json[key] as? String).flatMap { Data(base64URL: $0) } }
        switch json["kty"] as? String {
        case "RSA":
            guard let n = part("n"), let e = part("e"), n.count >= 256 else { return nil }  // at least 2048 bit
            material = .rsa(n: n, e: e)
        case "EC":
            guard json["crv"] as? String == "P-256", let x = part("x"), let y = part("y"), x.count == 32, y.count == 32 else { return nil }
            material = .ec(x: x, y: y)
        default: return nil
        }
    }

    var algorithm: String { switch material { case .rsa: "RS256"; case .ec: "ES256" } }

    func verify(signature: Data, signingInput: Data) -> Bool {
        switch material {
        case .rsa(let n, let e):
            guard let key = try? _RSA.Signing.PublicKey(n: n, e: e), key.keySizeInBits >= 2048 else { return false }
            return key.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: signature), for: signingInput, padding: .insecurePKCS1v1_5)
        case .ec(let x, let y):
            guard signature.count == 64, let key = try? P256.Signing.PublicKey(x963Representation: Data([4]) + x + y),
                  let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
            return key.isValidSignature(sig, for: signingInput)
        }
    }
}

struct OIDCParsedToken {
    let header: [String: Any]
    let claims: [String: Any]
    let signingInput: Data
    let signature: Data
    var kid: String? { header["kid"] as? String }
    var algorithm: String { header["alg"] as? String ?? "" }

    /// Splits and decodes a compact JWS. Only RS256 and ES256 are accepted; `none` and HMAC algorithms are rejected here.
    init(_ token: String) throws {
        guard token.utf8.count <= 16 * 1024 else { throw OIDCTokenError.malformed }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let head = Data(base64URL: String(parts[0])), let body = Data(base64URL: String(parts[1])),
              let sig = Data(base64URL: String(parts[2])), !sig.isEmpty,
              let headerObject = (try? JSONSerialization.jsonObject(with: head)) as? [String: Any],
              let claimObject = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { throw OIDCTokenError.malformed }
        guard let alg = headerObject["alg"] as? String, alg == "RS256" || alg == "ES256" else { throw OIDCTokenError.unsupportedAlgorithm }
        // Reject embedded-key tricks: keys must come from the provider's JWKS, never from the token.
        guard headerObject["jwk"] == nil, headerObject["jku"] == nil, headerObject["x5u"] == nil, headerObject["crit"] == nil else { throw OIDCTokenError.malformed }
        header = headerObject; claims = claimObject
        signingInput = Data((String(parts[0]) + "." + String(parts[1])).utf8)
        signature = sig
    }
}

struct OIDCIdentityClaims: Sendable {
    let subject: String
    let emailHint: String?
}

enum OIDCClaimValidator {
    static let leeway: TimeInterval = 60

    /// Validates iss, aud, azp, exp, iat, nbf and nonce. Signature must have been verified before.
    static func validate(_ claims: [String: Any], issuer: String, clientID: String, nonce: String, now: Date = Date()) throws -> OIDCIdentityClaims {
        guard claims["iss"] as? String == issuer else { throw OIDCTokenError.claim("iss") }
        let audiences: [String]
        if let single = claims["aud"] as? String { audiences = [single] }
        else if let many = claims["aud"] as? [String] { audiences = many }
        else { throw OIDCTokenError.claim("aud") }
        guard audiences.contains(clientID) else { throw OIDCTokenError.claim("aud") }
        if let azp = claims["azp"] { guard azp as? String == clientID else { throw OIDCTokenError.claim("azp") } }
        else if audiences.count > 1 { throw OIDCTokenError.claim("azp") }
        func date(_ key: String) -> Double? {
            guard let value = claims[key] else { return nil }
            if value is Bool { return nil }
            return (value as? NSNumber)?.doubleValue
        }
        let t = now.timeIntervalSince1970
        guard let exp = date("exp"), exp > t - leeway else { throw OIDCTokenError.claim("exp") }
        guard let iat = date("iat"), iat <= t + leeway else { throw OIDCTokenError.claim("iat") }
        if claims["nbf"] != nil { guard let nbf = date("nbf"), nbf <= t + leeway else { throw OIDCTokenError.claim("nbf") } }
        guard let tokenNonce = claims["nonce"] as? String, Secrets.equal(tokenNonce, nonce) else { throw OIDCTokenError.claim("nonce") }
        guard let sub = claims["sub"] as? String, !sub.isEmpty, sub.utf8.count <= 255 else { throw OIDCTokenError.claim("sub") }
        var hint = claims["email"] as? String
        if let value = hint, value.count > 254 || value.contains(where: { $0.isNewline }) { hint = nil }
        return OIDCIdentityClaims(subject: sub, emailHint: hint)
    }
}
