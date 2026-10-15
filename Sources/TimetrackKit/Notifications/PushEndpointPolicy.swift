import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct PushEndpointPolicy: Sendable {
    var allowedHosts = ["fcm.googleapis.com", "*.push.services.mozilla.com", "*.notify.windows.com", "web.push.apple.com", "*.push.apple.com"]
    var pushAllowInsecureLoopback = false

    func endpoint(_ raw: String) -> (url: String, host: String)? {
        guard raw.count <= 2048, raw.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              let parts = URLComponents(string: raw), let host = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil, parts.fragment == nil else { return nil }
        if pushAllowInsecureLoopback, parts.scheme == "http", ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host),
           parts.port.map({ (1...65535).contains($0) }) ?? true { return (raw, host) }
        var literal = in_addr()
        guard inet_aton(host, &literal) == 0 else { return nil }
        guard parts.scheme == "https", parts.port == nil || parts.port == 443,
              host.contains("."), !host.hasSuffix("."),
              host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              !host.split(separator: ".").allSatisfy({ UInt8($0) != nil }),
              !["localhost", "local", "internal", "home", "lan", "localdomain", "test", "invalid", "example", "onion"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              allowedHosts.contains(where: { pattern in
                  let pattern = pattern.lowercased()
                  return pattern.hasPrefix("*.") ? host.hasSuffix(String(pattern.dropFirst())) && host != String(pattern.dropFirst(2)) : host == pattern
              }) else { return nil }
        return (raw, host)
    }

    static func isPublicAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            let n = UInt32(bigEndian: v4.s_addr)
            let a = n >> 24, b = (n >> 16) & 255
            return a != 0 && a != 10 && a != 127 && a < 224 &&
                !(a == 100 && (64...127).contains(b)) && !(a == 169 && b == 254) &&
                !(a == 172 && (16...31).contains(b)) && !(a == 192 && (b == 0 || b == 168 || b == 2)) &&
                !(a == 192 && b == 88 && ((n >> 8) & 255) == 99) &&
                !(a == 198 && (b == 18 || b == 19 || b == 51)) && !(a == 203 && b == 0)
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, text, &v6) == 1 else { return false }
        return withUnsafeBytes(of: v6) { bytes in
            // Only global unicast; excludes mapped IPv4, loopback, ULA, link-local and multicast.
            guard bytes[0] & 0xe0 == 0x20 else { return false }
            if bytes[0] == 0x20 && bytes[1] == 0x02 { return false } // Deprecated 6to4.
            if bytes[0] == 0x20 && bytes[1] == 0x01 {
                if bytes[2] < 2 { return false } // Special-purpose 2001::/23.
                if bytes[2] == 0x0d && bytes[3] == 0xb8 { return false }
            }
            return !(bytes[0] == 0x3f && bytes[1] == 0xff) // Documentation prefix.
        }
    }

    /// Resolve once, validate every A/AAAA answer and return a numeric address for the connection.
    func resolve(_ host: String) async throws -> String {
        if pushAllowInsecureLoopback, ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host) { return "127.0.0.1" }
        return try await Task.detached {
            var hints = addrinfo(); hints.ai_family = AF_UNSPEC
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else { throw APIError.invalid }
            defer { freeaddrinfo(first) }
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            var addresses: [String] = []
            while let node = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(node.pointee.ai_addr, node.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { throw APIError.invalid }
                let address = String(cString: buffer)
                guard Self.isPublicAddress(address) else { throw APIError.invalid }
                addresses.append(address); cursor = node.pointee.ai_next
            }
            guard let address = addresses.first else { throw APIError.invalid }
            return address
        }.value
    }
}
