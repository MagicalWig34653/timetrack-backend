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

    // MARK: - CSP hotfix: hashes against the bytes that are actually served, operator emergency brake

    /// Production build of the PWA shell (`npm run build`, no mock): three inline scripts, one of them the SvelteKit start with `import()`.
    private var productionShellURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pwa-production-index.html")
    }

    /// Independent of the production code: script bodies by plain byte search, hashed with CryptoKit-compatible SHA-256.
    private func inlineScriptHashes(inServed bytes: [UInt8]) -> [String] {
        let open = Array("<script".utf8), close = Array("</script>".utf8)
        var hashes: [String] = [], index = 0
        func find(_ needle: [UInt8], from: Int) -> Int? {
            guard bytes.count >= needle.count, from <= bytes.count - needle.count else { return nil }
            return (from...(bytes.count - needle.count)).first { bytes[$0..<($0 + needle.count)].elementsEqual(needle) }
        }
        while let start = find(open, from: index), let tagEnd = bytes[start...].firstIndex(of: UInt8(ascii: ">")), let end = find(close, from: tagEnd) {
            let tag = String(decoding: bytes[start...tagEnd], as: UTF8.self)
            if !tag.contains("src=") { hashes.append("'sha256-" + Data(SHA256.hash(data: Data(bytes[(tagEnd + 1)..<end]))).base64EncodedString() + "'") }
            index = end + close.count
        }
        return hashes
    }

    func testCspHotfix_HashesMatchTheBytesServedForTheProductionBuildShell() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pwa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: productionShellURL)
        XCTAssertFalse(original.contains(UInt8(ascii: "\r")), "fixture must keep LF line endings like the build output")
        try original.write(to: directory.appendingPathComponent("index.html"))
        for path in ["/", "/index.html", "/week", "/settings/profile"] {
            // A client (or proxy) announcing gzip/br must still get the identity bytes that the hashes were computed from.
            try await withApp(environment: ["PWA_STATIC_DIR": directory.path]) { app, _ in
                var headers = HTTPHeaders(); headers.add(name: .acceptEncoding, value: "gzip, deflate, br")
                try await app.test(.GET, path, headers: headers) { r async throws in
                    XCTAssertEqual(r.status, .ok, path)
                    XCTAssertNil(r.headers.first(name: .contentEncoding), path)
                    let served = Array(r.body.readableBytesView)
                    XCTAssertEqual(served, Array(original), "served bytes differ from the file for \(path)")
                    let csp = try XCTUnwrap(r.headers.first(name: "Content-Security-Policy"))
                    let hashes = inlineScriptHashes(inServed: served)
                    XCTAssertEqual(hashes.count, 3, "recovery, theme and SvelteKit start script")
                    for hash in hashes { XCTAssertTrue(csp.contains(hash), "\(hash) missing from the CSP for \(path)") }
                    XCTAssertTrue(csp.contains("script-src 'self' "))
                    XCTAssertFalse(csp.contains("unsafe-inline'; style") || csp.contains("script-src 'self' 'unsafe-inline'"))
                    XCTAssertEqual(csp, PWAContentSecurityPolicy.policy(forHTML: String(decoding: served, as: UTF8.self)))
                }
            }
        }
    }

    func testCspHotfix_ShellWithCRLFAndMultipleScriptsHashesTheRawBytes() throws {
        let html = "<html><body>\r\n<script>\r\n  var a = 1;\r\n</script>\r\n<script id=\"x\">b()</script><script type=\"module\" src=\"/s.js\"></script><script>\n\timport('/e.js');\n</script></body></html>"
        let policy = PWAContentSecurityPolicy.policy(forHTML: html)
        for body in ["\r\n  var a = 1;\r\n", "b()", "\n\timport('/e.js');\n"] { XCTAssertTrue(policy.contains(PWAContentSecurityPolicy.hashSource(body)), body) }
        XCTAssertEqual(policy.components(separatedBy: "'sha256-").count - 1, 3)
    }

    func testCspHotfix_ModeParsingAndDefault() throws {
        XCTAssertEqual(try Configuration(environment: [:]).pwaCSPMode, .enforce)
        XCTAssertEqual(try Configuration(environment: ["PWA_CSP_MODE": ""]).pwaCSPMode, .enforce)
        XCTAssertEqual(try Configuration(environment: ["PWA_CSP_MODE": "Report-Only"]).pwaCSPMode, .reportOnly)
        XCTAssertEqual(try Configuration(environment: ["PWA_CSP_MODE": "off"]).pwaCSPMode, .off)
        XCTAssertThrowsError(try Configuration(environment: ["PWA_CSP_MODE": "none"]))
    }

    func testCspHotfix_EmergencyBrakeRelaxesOnlyThePWAResponses() async throws {
        let directory = try shellDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for mode in ["report-only", "off"] {
            try await withApp(environment: ["PWA_STATIC_DIR": directory.path, "PWA_CSP_MODE": mode]) { app, _ in
                try await app.test(.GET, "/some/route") { r async throws in
                    XCTAssertEqual(r.headers.first(name: "Content-Security-Policy"), "frame-ancestors 'none'; base-uri 'none'", mode)
                    let reportOnly = r.headers.first(name: "Content-Security-Policy-Report-Only")
                    if mode == "report-only" { XCTAssertTrue(try XCTUnwrap(reportOnly).contains(PWAContentSecurityPolicy.hashSource("var a = 1;"))) } else { XCTAssertNil(reportOnly) }
                    XCTAssertEqual(r.headers.first(name: "X-Frame-Options"), "DENY")
                }
                try await app.test(.GET, "/app.js") { r async throws in
                    XCTAssertEqual(r.headers.first(name: "Content-Security-Policy"), "frame-ancestors 'none'", mode)
                    XCTAssertNil(r.headers.first(name: "Content-Security-Policy-Report-Only"))
                }
                // The API keeps its strict default whatever the PWA mode is.
                try await app.test(.GET, "/api/v1/me") { r async throws in
                    XCTAssertEqual(r.headers.first(name: "Content-Security-Policy"), "default-src 'none'; frame-ancestors 'none'", mode)
                }
            }
        }
        // Default stays strict and sends no report-only header.
        try await withApp(environment: ["PWA_STATIC_DIR": directory.path]) { app, _ in
            try await app.test(.GET, "/some/route") { r async throws in
                XCTAssertTrue(try XCTUnwrap(r.headers.first(name: "Content-Security-Policy")).hasPrefix("default-src 'self'; script-src 'self' "))
                XCTAssertNil(r.headers.first(name: "Content-Security-Policy-Report-Only"))
            }
        }
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
