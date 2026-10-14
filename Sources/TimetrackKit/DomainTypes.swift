import Foundation

public enum AccountRole: String, Codable, Sendable { case admin, member }
public enum ChallengePurpose: String, Codable, Sendable {
    case registration, authentication
    case addPasskey = "add_passkey"
}
public enum RecoveryKind: String, Codable, Sendable {
    case email
    case recoveryCode = "recovery-code"
    case fallbackPassword = "fallback-password"
    case emailVerification = "email-verification"
}
