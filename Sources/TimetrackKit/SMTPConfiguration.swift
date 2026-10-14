import Foundation

public struct SMTPConfiguration: Sendable {
    public enum TLS: String, Sendable { case starttls, implicit, off }
    public let host: String
    public let port: Int
    public let tls: TLS
    public let user: String?
    public let password: String?
    public let from: String
    public let fromName: String?

    init?(environment: [String: String]) throws {
        guard let host = environment["SMTP_HOST"], !host.isEmpty else { return nil }
        func invalid(_ key: String) -> ConfigurationError {
            ConfigurationError(key: key, reason: "invalid SMTP setting")
        }
        guard host.utf8.allSatisfy({ (33...126).contains($0) }),
              !host.contains("/"), !host.contains("@") else { throw invalid("SMTP_HOST") }
        guard let port = Int(environment["SMTP_PORT"] ?? "587"), (1...65535).contains(port) else { throw invalid("SMTP_PORT") }
        guard let tls = TLS(rawValue: environment["SMTP_TLS"] ?? "starttls") else { throw invalid("SMTP_TLS") }
        // Only literal loopback endpoints and the project's dedicated Mailpit service may use cleartext.
        if tls == .off && !["localhost", "127.0.0.1", "::1", "mailpit"].contains(host.lowercased()) {
            throw invalid("SMTP_TLS")
        }
        let user = environment["SMTP_USER"], password = environment["SMTP_PASSWORD"]
        guard (user == nil) == (password == nil),
              user.map({ !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 256 }) ?? true,
              password.map({ !$0.contains("\0") && $0.utf8.count <= 256 }) ?? true,
              tls != .off || user == nil else { throw invalid("SMTP_USER") }
        guard let from = environment["SMTP_FROM"], Self.validAddress(from) else { throw invalid("SMTP_FROM") }
        let name = environment["SMTP_FROM_NAME"]
        guard name.map({ !$0.utf8.contains(13) && !$0.utf8.contains(10) && $0.utf8.count <= 256 }) ?? true else {
            throw invalid("SMTP_FROM_NAME")
        }
        self.host = host; self.port = port; self.tls = tls; self.user = user
        self.password = password; self.from = from; self.fromName = name
    }

    static func validAddress(_ address: String) -> Bool {
        guard address.utf8.count <= 254, address.utf8.allSatisfy({ (33...126).contains($0) }) else { return false }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64,
              !parts[0].hasPrefix("."), !parts[0].hasSuffix("."), !parts[0].contains(".."),
              parts[0].allSatisfy({ $0.isLetter || $0.isNumber || "!#$%&'*+-/=?^_`{|}~.".contains($0) }) else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
            label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}
