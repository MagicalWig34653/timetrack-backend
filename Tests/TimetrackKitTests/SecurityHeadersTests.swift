import Crypto
import Foundation
import XCTVapor
@testable import TimetrackKit

/// SEC-05 (security headers) and SEC-01 (startup warnings for proxy networks).
// Lives in an AuthTests extension: XCTestCase cannot be instantiated directly on Linux.
extension AuthTests {
    private var shell: String { """
    <!doctype html><html><head><script>var a = 1;</script><script src="/_app/x.js"></script></head>
    <body><button onclick="location.assign('/')">x</button><script>document.title = "t";</script></body></html>
    """ }

    private func shellDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pwa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try shell.write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "console.log(1)".write(to: directory.appendingPathComponent("app.js"), atomically: true, encoding: .utf8)
        return directory
    }

    func testSec05_PolicyHashesInlineScriptsAndHandlersButNotExternalScripts() {
        let policy = PWAContentSecurityPolicy.policy(forHTML: shell)
        XCTAssertTrue(policy.contains(PWAContentSecurityPolicy.hashSource("var a = 1;")))
        XCTAssertTrue(policy.contains(PWAContentSecurityPolicy.hashSource(#"document.title = "t";"#)))
        XCTAssertTrue(policy.contains(PWAContentSecurityPolicy.hashSource("location.assign('/')")))
        XCTAssertTrue(policy.contains("'unsafe-hashes'"))
        XCTAssertFalse(policy.contains("script-src 'self' 'unsafe-inline'"))
        for required in ["default-src 'self'", "frame-ancestors 'none'", "base-uri 'none'", "object-src", "form-action 'self'", "connect-src 'self'", "worker-src 'self'", "manifest-src 'self'"] {
            XCTAssertTrue(policy.contains(required), required)
        }
        XCTAssertFalse(PWAContentSecurityPolicy.policy(forHTML: "<html><script src=\"/a.js\"></script></html>").contains("unsafe-hashes"))
    }

    func testSec05_PWAShellAndAssetsCarryHeaders() async throws {
        let directory = try shellDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withApp(environment: ["PWA_STATIC_DIR": directory.path, "PUBLIC_BASE_URL": "https://timetrack.example.org", "WEBAUTHN_RP_ID": "timetrack.example.org", "WEBAUTHN_ORIGIN": "https://timetrack.example.org"]) { app, _ in
            try await app.test(.GET, "/some/route") { r async throws in
                XCTAssertEqual(r.status, .ok)
                let csp = try XCTUnwrap(r.headers.first(name: "Content-Security-Policy"))
                XCTAssertTrue(csp.contains(PWAContentSecurityPolicy.hashSource("var a = 1;")))
                XCTAssertTrue(csp.contains("frame-ancestors 'none'"))
                XCTAssertEqual(r.headers.first(name: "Referrer-Policy"), "no-referrer")
                XCTAssertEqual(r.headers.first(name: "X-Content-Type-Options"), "nosniff")
                XCTAssertEqual(r.headers.first(name: "X-Frame-Options"), "DENY")
                XCTAssertNotNil(r.headers.first(name: "Permissions-Policy"))
                XCTAssertEqual(r.headers.first(name: "Strict-Transport-Security"), "max-age=15552000")
            }
            try await app.test(.GET, "/app.js") { r async throws in
                // A service worker inherits the CSP of its script response: it must allow same-origin fetches.
                XCTAssertEqual(r.headers.first(name: "Content-Security-Policy"), PWAContentSecurityPolicy.assetPolicy)
                XCTAssertEqual(r.headers.first(name: "X-Content-Type-Options"), "nosniff")
                XCTAssertEqual(r.headers.first(name: "Referrer-Policy"), "no-referrer")
            }
        }
    }

    func testSec05_APIResponsesAndErrorsCarryHeaders() async throws {
        try await withApp { app, _ in
            for path in ["/health", "/api/v1/me", "/api/v1/nonexistent"] {
                try await app.test(.GET, path) { r async throws in
                    XCTAssertEqual(r.headers.first(name: "Content-Security-Policy"), "default-src 'none'; frame-ancestors 'none'", path)
                    XCTAssertEqual(r.headers.first(name: "Referrer-Policy"), "no-referrer", path)
                    XCTAssertEqual(r.headers.first(name: "X-Content-Type-Options"), "nosniff", path)
                    XCTAssertEqual(r.headers.first(name: "X-Frame-Options"), "DENY", path)
                    XCTAssertNil(r.headers.first(name: "Strict-Transport-Security"), "plain-HTTP base URL: no HSTS")
                }
            }
        }
    }

    func testSec05_HSTSIsConfigurableAndExistingHeadersAreKept() throws {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: "Content-Security-Policy", value: "sandbox; default-src 'none'")
        headers.replaceOrAdd(name: "Referrer-Policy", value: "same-origin")
        headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
        SecurityHeadersMiddleware(hstsMaxAgeSeconds: 100).apply(to: &headers)
        XCTAssertEqual(headers.first(name: "Content-Security-Policy"), "sandbox; default-src 'none'")
        XCTAssertEqual(headers.first(name: "Referrer-Policy"), "same-origin")
        XCTAssertEqual(headers.first(name: "Cache-Control"), "no-store")
        XCTAssertEqual(headers.first(name: "Strict-Transport-Security"), "max-age=100")
        var html = HTTPHeaders(); html.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
        SecurityHeadersMiddleware(hstsMaxAgeSeconds: 0).apply(to: &html)
        XCTAssertEqual(html.first(name: "Content-Security-Policy"), "frame-ancestors 'none'; base-uri 'none'")
        XCTAssertNil(html.first(name: "Strict-Transport-Security"))
        XCTAssertEqual(try Configuration(environment: ["HSTS_MAX_AGE_SECONDS": "0"]).hstsMaxAgeSeconds, 0)
        XCTAssertEqual(try Configuration(environment: [:]).hstsMaxAgeSeconds, 15552000)
        XCTAssertThrowsError(try Configuration(environment: ["HSTS_MAX_AGE_SECONDS": "-1"]))
    }

    func testSec01_StartupWarningsForProxyNetworks() throws {
        func warnings(_ cidrs: String, tls: Bool = true) throws -> [String] {
            try TrustedProxies(cidrs: cidrs, header: nil).startupWarnings(behindTLSProxy: tls)
        }
        XCTAssertEqual(try warnings("10.0.0.5/32"), [])
        XCTAssertEqual(try warnings("10.0.0.0/24, fd00::/64"), [])
        XCTAssertEqual(try warnings("172.18.0.0/16"), [])
        XCTAssertEqual(try warnings("", tls: false), [])
        XCTAssertEqual(try warnings("").count, 1, "empty list behind https: shared rate-limit bucket")
        XCTAssertTrue(try warnings("").joined().contains("share one address-based rate limit"))
        let wide = try warnings("10.0.0.0/8")
        XCTAssertEqual(wide.count, 1)
        XCTAssertTrue(wide[0].contains("routing mesh"))
        XCTAssertEqual(try warnings("172.16.0.0/12").count, 1)
        XCTAssertEqual(try warnings("fd00::/16").count, 1)
        XCTAssertTrue(try warnings("8.8.0.0/16")[0].contains("public addresses"))
        XCTAssertTrue(try warnings("0.0.0.0/1")[0].contains("public addresses"))
        XCTAssertTrue(try warnings("::/1")[0].contains("public addresses"))
        XCTAssertEqual(try warnings("192.0.2.1/32, 10.0.0.0/8").count, 2)
    }
}
