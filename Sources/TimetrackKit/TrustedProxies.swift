import Foundation
import Vapor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A parsed IPv4 (4 bytes) or IPv6 (16 bytes) address. IPv4-mapped IPv6 addresses are normalised to IPv4.
struct IPAddressValue: Equatable, Sendable {
    let bytes: [UInt8]

    init(bytes: [UInt8]) {
        if bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            self.bytes = Array(bytes[12...])
        } else {
            self.bytes = bytes
        }
    }

    /// Parses a textual address only (no port, no brackets, no zone id).
    init?(_ text: String) {
        guard !text.isEmpty, text.utf8.count <= 45, !text.contains("%") else { return nil }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            self.init(bytes: withUnsafeBytes(of: &v4) { Array($0) })
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            self.init(bytes: withUnsafeBytes(of: &v6) { Array($0) })
            return
        }
        return nil
    }

    var isIPv6: Bool { bytes.count == 16 }

    /// Canonical text form (`inet_ntop`).
    var text: String {
        var buffer = [CChar](repeating: 0, count: 64)
        let family = isIPv6 ? AF_INET6 : AF_INET
        guard inet_ntop(family, bytes, &buffer, 64) != nil else { return "unknown" }
        return String(cString: buffer)
    }

    /// Rate-limit bucket: IPv4 as is, IPv6 reduced to its /64 network (a single subscriber normally owns a whole /64,
    /// so otherwise one client could rotate through 2^64 addresses and never hit a per-address limit).
    var rateLimitKey: String {
        guard isIPv6 else { return text }
        return IPAddressValue(bytes: Array(bytes[0..<8]) + [UInt8](repeating: 0, count: 8)).text + "/64"
    }
}

/// An IP network. A single address is a network with the full prefix length.
struct CIDR: Equatable, Sendable {
    let network: [UInt8]
    let prefix: Int

    /// Accepts `a.b.c.d`, `a.b.c.d/n`, `v6`, `v6/n`. Throws a reason string for anything else.
    init(parsing raw: String) throws {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, let address = IPAddressValue(parts[0]) else { throw CIDRError(entry: raw) }
        // An IPv4-mapped IPv6 network (::ffff:a.b.c.d/n) is the IPv4 network with prefix n - 96.
        let mapped = parts[0].contains(":") && !address.isIPv6
        let maxBits = mapped ? 128 : address.bytes.count * 8
        var written = maxBits
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].count <= 3, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(parts[1]), value <= maxBits else { throw CIDRError(entry: raw) }
            written = value
        }
        let length = mapped ? written - 96 : written
        // A /0 network would trust every peer and defeat the spoofing protection, so it is rejected.
        guard length > 0 else { throw CIDRError(entry: raw) }
        network = Self.masked(address.bytes, prefix: length)
        prefix = length
    }

    private static func masked(_ bytes: [UInt8], prefix: Int) -> [UInt8] {
        var result = bytes
        for index in result.indices {
            let covered = max(0, min(8, prefix - index * 8))
            result[index] &= covered == 0 ? 0 : UInt8(truncatingIfNeeded: 0xff << (8 - covered))
        }
        return result
    }

    func contains(_ address: IPAddressValue) -> Bool {
        address.bytes.count == network.count && Self.masked(address.bytes, prefix: prefix) == network
    }
}

struct CIDRError: Error { let entry: String }

/// Trusted reverse proxies and the header they use to report the client address (ADR-0018).
/// Empty list: nobody is trusted, forwarded headers are ignored.
public struct TrustedProxies: Sendable, Equatable {
    public enum Header: String, Sendable { case forwardedFor = "X-Forwarded-For", realIP = "X-Real-IP" }

    let cidrs: [CIDR]
    public let header: Header

    public static let none = TrustedProxies(cidrs: [], header: .forwardedFor)

    init(cidrs: [CIDR], header: Header) { self.cidrs = cidrs; self.header = header }

    public var isEmpty: Bool { cidrs.isEmpty }

    /// Parses `TRUSTED_PROXY_CIDRS` / `TRUSTED_PROXY_HEADER`. Blank entries are ignored; any invalid entry is an error.
    public init(cidrs raw: String, header rawHeader: String?) throws {
        var list: [CIDR] = []
        for part in raw.split(separator: ",", omittingEmptySubsequences: true) {
            let entry = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if entry.isEmpty { continue }
            do { list.append(try CIDR(parsing: entry)) } catch {
                throw ConfigurationError(key: "TRUSTED_PROXY_CIDRS", reason: "entries must be IPv4/IPv6 addresses or CIDR networks (e.g. 10.0.0.0/8, fd00::/8)")
            }
        }
        let name = (rawHeader ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let header: Header
        if name.isEmpty { header = .forwardedFor }
        else if let match = [Header.forwardedFor, .realIP].first(where: { $0.rawValue.lowercased() == name.lowercased() }) { header = match }
        else { throw ConfigurationError(key: "TRUSTED_PROXY_HEADER", reason: "expected X-Forwarded-For or X-Real-IP") }
        self.init(cidrs: list, header: header)
    }

    /// One-time startup hint (Q1 finding 1): `X-Real-IP` is taken at face value from a trusted peer, so the proxy must overwrite it
    /// on every request. Nil for the default header or when no proxy is trusted.
    var startupWarning: String? {
        guard header == .realIP, !cidrs.isEmpty else { return nil }
        return "TRUSTED_PROXY_HEADER=X-Real-IP: the header is trusted as sent by the proxy; the proxy must overwrite X-Real-IP with the client address on every request (nginx: proxy_set_header X-Real-IP $remote_addr). If it passes a client-supplied value through, clients can spoof their address and bypass per-address rate limits. X-Forwarded-For is safer because it is read from the right."
    }

    /// Startup warnings for configurations that make the forwarded address spoofable or useless (SEC-01).
    /// `behindTLSProxy` is true when the public base URL is https (a proxy is then expected in front of the backend).
    func startupWarnings(behindTLSProxy: Bool) -> [String] {
        var warnings: [String] = []
        if let warning = startupWarning { warnings.append(warning) }
        if cidrs.isEmpty {
            if behindTLSProxy {
                warnings.append("TRUSTED_PROXY_CIDRS is empty although PUBLIC_BASE_URL is https: every client is seen with the proxy's address and all clients share one address-based rate limit and lockout (one attacker can lock out everybody). Set TRUSTED_PROXY_CIDRS to the proxy address or network (docs/BETRIEB.md).")
            }
            return warnings
        }
        for cidr in cidrs {
            let text = "\(IPAddressValue(bytes: cidr.network).text)/\(cidr.prefix)"
            if !Self.isPrivateOrLoopback(cidr) {
                warnings.append("TRUSTED_PROXY_CIDRS entry \(text) contains public addresses: any host in that range can forge X-Forwarded-For / X-Real-IP and bypass the address-based rate limits. Trust only your proxy.")
            } else if (cidr.network.count == 4 && cidr.prefix < 16) || (cidr.network.count == 16 && cidr.prefix < 48) {
                warnings.append("TRUSTED_PROXY_CIDRS entry \(text) is a very wide network. With Docker Swarm's routing mesh every connection to a published port arrives with an address of the ingress network, so the whole internet is trusted unless the port is reachable only from the proxy (node firewall). Prefer the proxy address as /32 or the narrowest network (docs/DEPLOYMENT.md).")
            }
        }
        return warnings
    }

    /// True when the whole network lies inside loopback, RFC 1918, CGNAT, link-local or unique-local space.
    private static func isPrivateOrLoopback(_ cidr: CIDR) -> Bool {
        let b = cidr.network, p = cidr.prefix
        if b.count == 4 {
            if b[0] == 10 || b[0] == 127 { return p >= 8 }
            if b[0] == 172, (16...31).contains(b[1]) { return p >= 12 }
            if b[0] == 192, b[1] == 168 { return p >= 16 }
            if b[0] == 169, b[1] == 254 { return p >= 16 }
            if b[0] == 100, (64...127).contains(b[1]) { return p >= 10 }
            return false
        }
        if b == [UInt8](repeating: 0, count: 15) + [1] { return true }
        if b[0] & 0xfe == 0xfc { return p >= 7 }
        if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return p >= 10 }
        return false
    }

    func isTrusted(_ address: IPAddressValue) -> Bool { cidrs.contains { $0.contains(address) } }

    /// Resolves the client address. `peer` is the socket peer; forwarded values are only read when the peer is trusted.
    /// Returns nil when no address is known at all.
    func resolve(peer: String?, forwarded: [String]) -> IPAddressValue? {
        guard let peer, let direct = IPAddressValue(peer) else { return nil }
        guard !cidrs.isEmpty, isTrusted(direct) else { return direct }
        switch header {
        case .realIP:
            guard forwarded.count == 1, let value = Self.parseForwarded(forwarded[0]) else { return direct }
            return value
        case .forwardedFor:
            // Several header lines are equivalent to one comma-joined list. Walk from the right (the hop closest to us,
            // appended by our own proxy) and stop at the first address that is not a trusted proxy. Entries to the left
            // of it are attacker-controlled and never read.
            let entries = forwarded.joined(separator: ",").split(separator: ",", omittingEmptySubsequences: false)
            guard !entries.isEmpty else { return direct }
            for entry in entries.reversed() {
                guard let value = Self.parseForwarded(String(entry)) else { return direct }
                if !isTrusted(value) { return value }
            }
            return direct
        }
    }

    /// Accepts `ip`, `ip:port`, `[v6]`, `[v6]:port`; everything else is malformed.
    static func parseForwarded(_ raw: String) -> IPAddressValue? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let rest = text[text.index(after: close)...]
            guard rest.isEmpty || (rest.hasPrefix(":") && rest.dropFirst().allSatisfy(\.isNumber) && rest.count > 1) else { return nil }
            text = String(text[text.index(after: text.startIndex)..<close])
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            let port = text[text.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return nil }
            text = String(text[..<colon])
        }
        return IPAddressValue(text)
    }
}

private struct TrustedProxiesKey: StorageKey { typealias Value = TrustedProxies }

extension Application {
    var trustedProxies: TrustedProxies {
        get { storage[TrustedProxiesKey.self] ?? .none }
        set { storage[TrustedProxiesKey.self] = newValue }
    }
}

extension Request {
    /// The client address after trusted-proxy handling (normalised text), or `"unknown"` without a socket peer.
    /// Use this, never `remoteAddress` or raw forwarded headers.
    var clientAddress: String {
        resolvedClientAddress?.text ?? "unknown"
    }

    /// Key for IP-based rate limits: like `clientAddress`, but IPv6 clients are bucketed by /64.
    var clientRateLimitKey: String {
        resolvedClientAddress?.rateLimitKey ?? "unknown"
    }

    private var resolvedClientAddress: IPAddressValue? {
        let proxies = application.trustedProxies
        let forwarded = proxies.isEmpty ? [] : headers[proxies.header.rawValue]
        return proxies.resolve(peer: remoteAddress?.ipAddress, forwarded: forwarded)
    }
}
