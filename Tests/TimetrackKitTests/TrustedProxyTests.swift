import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

final class TrustedProxyTests: XCTestCase, @unchecked Sendable {
    private func proxies(_ cidrs: String, header: String? = nil) throws -> TrustedProxies {
        try TrustedProxies(cidrs: cidrs, header: header)
    }
    private func resolve(_ trusted: TrustedProxies, peer: String?, _ forwarded: String...) -> String? {
        trusted.resolve(peer: peer, forwarded: forwarded)?.text
    }

    // MARK: CIDR parsing

    func testCIDRParsingAcceptsAndRejects() throws {
        for good in ["10.0.0.0/8", "10.1.2.3", "0.0.0.0/0", "192.168.1.7/32", "fd00::/8", "::1", "::1/128", "2001:db8::/32", "::ffff:10.0.0.0/104", "::/0"] {
            XCTAssertNoThrow(try CIDR(parsing: good), good)
        }
        for bad in ["", "/8", "10.0.0.0/", "10.0.0.0/33", "10.0.0.0/-1", "10.0.0.0/8/8", "10.0.0/8", "300.1.1.1", "10.0.0.1/ 8",
                    "fd00::/129", "::ffff:10.0.0.0/64", "example.com", "10.0.0.1:80", "[::1]", "fe80::1%eth0", "10.0.0.0/abc", "10.0.0.0/0008"] {
            XCTAssertThrowsError(try CIDR(parsing: bad), bad)
        }
    }

    func testCIDRMatching() throws {
        let net = try CIDR(parsing: "10.1.2.3/8")   // host bits are masked
        XCTAssertTrue(net.contains(IPAddressValue("10.255.255.255")!))
        XCTAssertFalse(net.contains(IPAddressValue("11.0.0.0")!))
        XCTAssertFalse(net.contains(IPAddressValue("::1")!), "families never match each other")
        let v6 = try CIDR(parsing: "fd00::/8")
        XCTAssertTrue(v6.contains(IPAddressValue("fdff::1")!))
        XCTAssertFalse(v6.contains(IPAddressValue("fe00::1")!))
        let single = try CIDR(parsing: "172.18.0.5")
        XCTAssertTrue(single.contains(IPAddressValue("172.18.0.5")!))
        XCTAssertFalse(single.contains(IPAddressValue("172.18.0.6")!))
        let any = try CIDR(parsing: "0.0.0.0/0")
        XCTAssertTrue(any.contains(IPAddressValue("8.8.8.8")!))
        // Non-byte-aligned prefix.
        let odd = try CIDR(parsing: "192.168.4.0/22")
        XCTAssertTrue(odd.contains(IPAddressValue("192.168.7.255")!)); XCTAssertFalse(odd.contains(IPAddressValue("192.168.8.0")!))
        // A mapped IPv4 network is the IPv4 network.
        let mapped = try CIDR(parsing: "::ffff:10.0.0.0/104")
        XCTAssertTrue(mapped.contains(IPAddressValue("10.9.9.9")!)); XCTAssertFalse(mapped.contains(IPAddressValue("11.0.0.1")!))
    }

    func testAddressNormalisationAndBucketing() {
        XCTAssertEqual(IPAddressValue("::ffff:192.0.2.1")?.text, "192.0.2.1")
        XCTAssertEqual(IPAddressValue("2001:0DB8:0:0:0:0:0:1")?.text, "2001:db8::1")
        XCTAssertEqual(IPAddressValue("192.0.2.1")?.rateLimitKey, "192.0.2.1")
        XCTAssertEqual(IPAddressValue("2001:db8:1:2:aaaa:bbbb:cccc:dddd")?.rateLimitKey, "2001:db8:1:2::/64")
        XCTAssertEqual(IPAddressValue("2001:db8:1:2:1::9")?.rateLimitKey, IPAddressValue("2001:db8:1:2:ffff::1")?.rateLimitKey)
        XCTAssertNotEqual(IPAddressValue("2001:db8:1:2::1")?.rateLimitKey, IPAddressValue("2001:db8:1:3::1")?.rateLimitKey)
        for bad in ["", "unknown", "1.2.3", "1.2.3.4.5", "1.2.3.4/8", "::g", "fe80::1%en0", String(repeating: "1", count: 60)] {
            XCTAssertNil(IPAddressValue(bad), bad)
        }
    }

    // MARK: resolution

    func testUntrustedPeerIgnoresHeaders() throws {
        let trusted = try proxies("10.0.0.0/8")
        XCTAssertEqual(resolve(trusted, peer: "198.51.100.9", "203.0.113.5"), "198.51.100.9")
        XCTAssertEqual(resolve(trusted, peer: "198.51.100.9", "10.0.0.1, 203.0.113.5"), "198.51.100.9")
        // Nothing configured: nobody is trusted, even loopback.
        XCTAssertEqual(resolve(.none, peer: "127.0.0.1", "203.0.113.5"), "127.0.0.1")
        XCTAssertEqual(resolve(try proxies(""), peer: "10.0.0.1", "203.0.113.5"), "10.0.0.1")
        XCTAssertEqual(resolve(try proxies(" , ,"), peer: "10.0.0.1", "203.0.113.5"), "10.0.0.1")
    }

    func testTrustedProxySingleAndMultipleHops() throws {
        let trusted = try proxies("10.0.0.0/8, 172.16.0.0/12")
        XCTAssertEqual(resolve(trusted, peer: "10.0.0.2", "203.0.113.5"), "203.0.113.5")
        XCTAssertEqual(resolve(trusted, peer: "10.0.0.2", "203.0.113.5, 10.0.0.3"), "203.0.113.5")
        XCTAssertEqual(resolve(trusted, peer: "10.0.0.2", "203.0.113.5,172.16.4.4,10.0.0.3"), "203.0.113.5")
        // Several header lines behave like one list.
        XCTAssertEqual(trusted.resolve(peer: "10.0.0.2", forwarded: ["203.0.113.5", "10.0.0.3"])?.text, "203.0.113.5")
        // Port suffixes and brackets some proxies add.
        XCTAssertEqual(resolve(trusted, peer: "10.0.0.2", "203.0.113.5:51234"), "203.0.113.5")
        XCTAssertEqual(resolve(trusted, peer: "10.0.0.2", "[2001:db8::7]:443"), "2001:db8::7")
        XCTAssertEqual(resolve(trusted, peer: "10.0.0.2", "[2001:db8::7]"), "2001:db8::7")
        // No header or only trusted hops: the direct peer.
        XCTAssertEqual(trusted.resolve(peer: "10.0.0.2", forwarded: [])?.text, "10.0.0.2")
        XCTAssertEqual(resolve(trusted, peer: "10.0.0.2", "10.0.0.9, 172.16.0.1"), "10.0.0.2")
    }

    func testPrependedEntriesFromAttackerAreIgnored() throws {
        let trusted = try proxies("10.0.0.0/8")
        // The attacker sends "X-Forwarded-For: 1.1.1.1"; our proxy appends the attacker's real address.
        XCTAssertEqual(resolve(trusted, peer: "10.0.0.2", "1.1.1.1, 203.0.113.50"), "203.0.113.50")
        XCTAssertEqual(resolve(trusted, peer: "10.0.0.2", "1.1.1.1, 10.0.0.77, 203.0.113.50"), "203.0.113.50")
        // Attacker pretends to be a trusted proxy in front of itself: still the right-most untrusted entry.
        XCTAssertEqual(resolve(trusted, peer: "10.0.0.2", "10.0.0.8, 9.9.9.9, 203.0.113.50, 10.0.0.3"), "203.0.113.50")
    }

    func testMalformedForwardedValuesFallBackToPeer() throws {
        let trusted = try proxies("10.0.0.0/8")
        for bad in ["", " ", "unknown", "not-an-ip", "203.0.113", "203.0.113.5.6", "999.1.1.1", "203.0.113.5;for=x", "<script>", "203.0.113.5:", "203.0.113.5:abc",
                    "[2001:db8::7", "[2001:db8::7]x", "2001:db8::7]:1", "fe80::1%en0", ",", "203.0.113.5,,10.0.0.3", "203.0.113.5, garbage", "\"203.0.113.5\""] {
            XCTAssertEqual(resolve(trusted, peer: "10.0.0.2", bad), "10.0.0.2", bad)
        }
        XCTAssertNil(trusted.resolve(peer: nil, forwarded: ["203.0.113.5"]))
        XCTAssertNil(trusted.resolve(peer: "unix", forwarded: ["203.0.113.5"]))
    }

    func testIPv6AndMappedIPv4() throws {
        let trusted = try proxies("fd00::/8, 10.0.0.0/8")
        XCTAssertEqual(resolve(trusted, peer: "fd00::2", "2001:db8:0:0:0:0:0:9"), "2001:db8::9")
        XCTAssertEqual(trusted.resolve(peer: "fd00::2", forwarded: ["2001:db8:1:2:3:4:5:6"])?.rateLimitKey, "2001:db8:1:2::/64")
        // Mapped peer and mapped forwarded values are IPv4.
        XCTAssertEqual(resolve(trusted, peer: "::ffff:10.0.0.2", "::ffff:203.0.113.5"), "203.0.113.5")
        XCTAssertEqual(resolve(trusted, peer: "::ffff:10.0.0.2", "203.0.113.5, ::ffff:10.0.0.9"), "203.0.113.5")
        XCTAssertEqual(resolve(trusted, peer: "::ffff:198.51.100.1", "203.0.113.5"), "198.51.100.1")
        // IPv4 client behind IPv6 proxy.
        XCTAssertEqual(resolve(trusted, peer: "fd00::2", "203.0.113.5"), "203.0.113.5")
    }

    func testRealIPHeader() throws {
        let trusted = try proxies("10.0.0.0/8", header: "x-real-ip")
        XCTAssertEqual(trusted.header, .realIP)
        XCTAssertEqual(trusted.resolve(peer: "10.0.0.2", forwarded: ["203.0.113.5"])?.text, "203.0.113.5")
        XCTAssertEqual(trusted.resolve(peer: "10.0.0.2", forwarded: ["1.1.1.1, 203.0.113.5"])?.text, "10.0.0.2", "a list is malformed for X-Real-IP")
        XCTAssertEqual(trusted.resolve(peer: "10.0.0.2", forwarded: ["1.1.1.1", "2.2.2.2"])?.text, "10.0.0.2")
        XCTAssertEqual(trusted.resolve(peer: "198.51.100.1", forwarded: ["203.0.113.5"])?.text, "198.51.100.1")
    }

    // MARK: configuration

    func testConfiguration() throws {
        XCTAssertTrue(try Configuration(environment: [:]).trustedProxies.isEmpty)
        XCTAssertEqual(try Configuration(environment: [:]).trustedProxies.header, .forwardedFor)
        let config = try Configuration(environment: ["TRUSTED_PROXY_CIDRS": " 10.0.0.0/8 , fd00::/8,172.18.0.5 ", "TRUSTED_PROXY_HEADER": "X-Real-IP"])
        XCTAssertEqual(config.trustedProxies.cidrs.count, 3)
        XCTAssertEqual(config.trustedProxies.header, .realIP)
        for bad in ["10.0.0.0/33", "proxy.example", "10.0.0.0/8;fd00::/8", "10.0.0.0/8,oops"] {
            XCTAssertThrowsError(try Configuration(environment: ["TRUSTED_PROXY_CIDRS": bad]), bad) { error in
                XCTAssertEqual((error as? ConfigurationError)?.key, "TRUSTED_PROXY_CIDRS")
            }
        }
        XCTAssertThrowsError(try Configuration(environment: ["TRUSTED_PROXY_HEADER": "Forwarded"])) { error in
            XCTAssertEqual((error as? ConfigurationError)?.key, "TRUSTED_PROXY_HEADER")
        }
    }

    // MARK: HTTP level (real socket peer 127.0.0.1)

    private func withServer(environment: [String: String], _ run: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        app.logger.logLevel = .critical
        let config = try Configuration(environment: ["SQLITE_PATH": ":memory:"].merging(environment) { _, new in new })
        do {
            try await configure(app, configuration: config)
            try await app.autoMigrate()
            try await run(app)
            try await app.autoRevert()
        } catch { try await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }

    private func post(_ app: Application, port: Int, forwarded: String) async throws -> HTTPStatus {
        var status = HTTPStatus.ok
        try await app.testable(method: .running(hostname: "127.0.0.1", port: port)).test(
            .POST, "/api/v1/auth/login/options", headers: ["X-Forwarded-For": forwarded]) { response async throws in status = response.status }
        return status
    }

    func testTwoClientsBehindProxyHaveSeparateBuckets() async throws {
        let port = 18171
        try await withServer(environment: ["TRUSTED_PROXY_CIDRS": "127.0.0.0/8"]) { app in
            func statuses(_ forwarded: String, _ count: Int) async throws -> [HTTPStatus] {
                var result: [HTTPStatus] = []
                for _ in 0..<count { result.append(try await post(app, port: port, forwarded: forwarded)) }
                return result
            }
            // Attacker (client A) exhausts its own bucket.
            let a = try await statuses("203.0.113.10", 62)
            XCTAssertNotEqual(a.first, .tooManyRequests)
            XCTAssertEqual(a.last, .tooManyRequests)
            // Client B behind the same proxy is not affected.
            let b = try await statuses("203.0.113.11", 3)
            XCTAssertFalse(b.contains(.tooManyRequests), "client B was locked out by client A: \(b)")
            // A prepended spoofed entry does not move A into a fresh bucket (the proxy-appended address wins).
            let spoof = try await statuses("198.51.100.99, 203.0.113.10", 1)
            XCTAssertEqual(spoof.last, .tooManyRequests)
            // Same IPv6 /64 shares one bucket.
            let v6a = try await statuses("2001:db8:5:5::1", 61)
            XCTAssertEqual(v6a.last, .tooManyRequests)
            let v6b = try await statuses("2001:db8:5:5:ffff::2", 1)
            XCTAssertEqual(v6b.last, .tooManyRequests)
        }
    }

    func testSpoofedHeaderFromUntrustedPeerSharesOneBucket() async throws {
        let port = 18172
        try await withServer(environment: [:]) { app in
            var last = HTTPStatus.ok
            for index in 0..<62 {
                last = try await post(app, port: port, forwarded: "203.0.113.\(index)")
            }
            XCTAssertEqual(last, .tooManyRequests, "rotating X-Forwarded-For must not create new buckets without a trusted proxy")
        }
    }
}
