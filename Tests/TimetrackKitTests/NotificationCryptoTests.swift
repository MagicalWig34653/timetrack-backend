import Foundation
import XCTest
import Crypto
@testable import TimetrackKit

final class NotificationCryptoTests: XCTestCase {
    // RFC 8291 Appendix A.
    let plaintext = "When I grow up, I want to be a watermelon"
    let asPrivate = "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
    let uaPrivate = "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"
    let uaPublic = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
    let authSecret = "BTBZMqHH6r4Tts7J_aSIgg"
    let salt = "DGv6ra1nlYgDCS1FRnbzlw"
    let body = "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

    func testRFC8291ExampleDecrypts() throws {
        let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: XCTUnwrap(Data(base64URL: uaPrivate)))
        XCTAssertEqual(key.publicKey.x963Representation.base64URL, uaPublic)
        let plain = try WebPushCrypto.decrypt(XCTUnwrap(Data(base64URL: body)), userAgentKey: key, authSecret: XCTUnwrap(Data(base64URL: authSecret)))
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), plaintext)
    }

    func testRFC8291ExampleEncryptsToKnownCiphertext() throws {
        let sender = try P256.KeyAgreement.PrivateKey(rawRepresentation: XCTUnwrap(Data(base64URL: asPrivate)))
        let out = try WebPushCrypto.encrypt(Data(plaintext.utf8), userAgentPublicKey: XCTUnwrap(Data(base64URL: uaPublic)),
                                            authSecret: XCTUnwrap(Data(base64URL: authSecret)), senderKey: sender, salt: XCTUnwrap(Data(base64URL: salt)))
        XCTAssertEqual(out.base64URL, body)
    }

    func testRoundtripWithPaddingAndTamperDetection() throws {
        let receiver = P256.KeyAgreement.PrivateKey()
        let secret = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let message = Data(#"{"title":"Timer läuft noch"}"#.utf8)
        for padding in [0, 100, 3000] {
            let encrypted = try WebPushCrypto.encrypt(message, userAgentPublicKey: receiver.publicKey.x963Representation, authSecret: secret, paddedLength: padding)
            XCTAssertEqual(try WebPushCrypto.decrypt(encrypted, userAgentKey: receiver, authSecret: secret), message)
            if padding > 0 { XCTAssertGreaterThanOrEqual(encrypted.count, 86 + padding + 17) }
        }
        var tampered = try WebPushCrypto.encrypt(message, userAgentPublicKey: receiver.publicKey.x963Representation, authSecret: secret)
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try WebPushCrypto.decrypt(tampered, userAgentKey: receiver, authSecret: secret))
        XCTAssertThrowsError(try WebPushCrypto.decrypt(try WebPushCrypto.encrypt(message, userAgentPublicKey: receiver.publicKey.x963Representation, authSecret: secret),
                                                       userAgentKey: receiver, authSecret: Data(repeating: 1, count: 16)))
        XCTAssertThrowsError(try WebPushCrypto.encrypt(Data(repeating: 1, count: 4090), userAgentPublicKey: receiver.publicKey.x963Representation, authSecret: secret))
        XCTAssertThrowsError(try WebPushCrypto.encrypt(message, userAgentPublicKey: Data(repeating: 4, count: 65), authSecret: secret))
    }

    func testVapidAuthorizationStructureAndSignature() throws {
        let key = P256.Signing.PrivateKey()
        let vapid = VapidConfiguration(privateKey: key, subject: "mailto:admin@example.test")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let header = try vapid.authorization(audience: "https://push.example.test", now: now)
        XCTAssertTrue(header.hasPrefix("vapid t="))
        let parts = header.dropFirst("vapid t=".count).components(separatedBy: ", k=")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1], key.publicKey.x963Representation.base64URL)
        XCTAssertEqual(Data(base64URL: parts[1])?.count, 65)
        let jwt = parts[0].split(separator: ".").map(String.init)
        XCTAssertEqual(jwt.count, 3)
        let head = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64URL: jwt[0]))) as? [String: String])
        XCTAssertEqual(head, ["typ": "JWT", "alg": "ES256"])
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64URL: jwt[1]))) as? [String: Any])
        XCTAssertEqual(claims["aud"] as? String, "https://push.example.test")
        XCTAssertEqual(claims["sub"] as? String, "mailto:admin@example.test")
        let exp = try XCTUnwrap(claims["exp"] as? Int)
        XCTAssertGreaterThan(exp, 1_800_000_000); XCTAssertLessThanOrEqual(exp, 1_800_000_000 + 12 * 3600)
        let signature = try XCTUnwrap(Data(base64URL: jwt[2]))
        XCTAssertEqual(signature.count, 64)
        XCTAssertTrue(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: Data((jwt[0] + "." + jwt[1]).utf8)))
        XCTAssertEqual(VapidConfiguration.origin(of: "https://push.example.test:8443/a/b?c"), "https://push.example.test:8443")
    }

    func testVapidConfigurationValidation() {
        let key = P256.Signing.PrivateKey().rawRepresentation.base64URL
        XCTAssertNotNil(VapidConfiguration(environment: ["VAPID_PRIVATE_KEY": key, "VAPID_SUBJECT": "mailto:a@example.test"]))
        XCTAssertNotNil(VapidConfiguration(environment: ["VAPID_PRIVATE_KEY": key, "VAPID_SUBJECT": "https://example.test/contact"]))
        for subject in ["", "admin@example.test", "mailto:", "http://example.test", "https://"] {
            XCTAssertNil(VapidConfiguration(environment: ["VAPID_PRIVATE_KEY": key, "VAPID_SUBJECT": subject]), subject)
        }
        XCTAssertNil(VapidConfiguration(environment: ["VAPID_SUBJECT": "mailto:a@example.test"]))
        XCTAssertNil(VapidConfiguration(environment: ["VAPID_PRIVATE_KEY": "short", "VAPID_SUBJECT": "mailto:a@example.test"]))
        XCTAssertNil(VapidConfiguration(environment: ["VAPID_PRIVATE_KEY": Data(repeating: 0, count: 32).base64URL, "VAPID_SUBJECT": "mailto:a@example.test"]))
    }
}
