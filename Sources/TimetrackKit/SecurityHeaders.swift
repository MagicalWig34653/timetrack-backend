import Crypto
import Foundation
import NIOConcurrencyHelpers
import Vapor

/// Content-Security-Policy for the static PWA shell (SEC-05).
///
/// The SvelteKit static build inlines a few bootstrap scripts whose bodies change with every build, so the policy cannot be a
/// constant: `script-src` lists the SHA-256 hash of every inline `<script>` (and inline event handler attribute) found in
/// the HTML file that is being served, plus `'self'` for the hashed `_app/` bundles and the service worker.
/// Styles keep `'unsafe-inline'` because Svelte/shadcn components set `style=` attributes; scripts never do.
enum PWAContentSecurityPolicy {
    /// Operator switch `PWA_CSP_MODE` (emergency brake): how the PWA static responses are protected.
    /// `enforce` (default) sends the strict policy; `reportOnly` sends the same policy as `Content-Security-Policy-Report-Only`
    /// (the browser enforces nothing but logs violations to its console); `off` sends no script/resource policy at all.
    /// In both relaxed modes only `frame-ancestors 'none'` (and `base-uri 'none'` for the shell) stays enforced.
    enum Mode: String, Sendable {
        case enforce
        case reportOnly = "report-only"
        case off
    }

    /// Enforced in the relaxed modes: no framing, no `<base>` injection; neither can break script or module loading.
    static let relaxedShellPolicy = "frame-ancestors 'none'; base-uri 'none'"
    static let relaxedAssetPolicy = "frame-ancestors 'none'"

    private static let cache = NIOLockedValueBox<[String: (modified: Date, policy: String)]>([:])

    /// Policy for the HTML file at `path`; cached per path and modification date.
    static func policy(forHTMLFileAt path: String) -> String? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        if let hit = cache.withLockedValue({ $0[path] }), hit.modified == modified { return hit.policy }
        guard let data = FileManager.default.contents(atPath: path), let html = String(data: data, encoding: .utf8) else { return nil }
        let value = policy(forHTML: html)
        cache.withLockedValue { $0[path] = (modified, value) }
        return value
    }

    static func policy(forHTML html: String) -> String {
        let scripts = inlineScriptBodies(in: html).map(hashSource)
        let handlers = eventHandlerValues(in: html).map(hashSource)
        var script = ["'self'"] + scripts + handlers
        if !handlers.isEmpty { script.insert("'unsafe-hashes'", at: 1) }
        return [
            "default-src 'self'",
            "script-src " + script.joined(separator: " "),
            "style-src 'self' 'unsafe-inline'",
            // blob: and data: for downloads, attachment previews (images, PDF in an iframe) and generated documents.
            "img-src 'self' data: blob:",
            "font-src 'self' data:",
            "connect-src 'self'",
            "media-src 'self' blob:",
            "frame-src 'self' blob:",
            "object-src 'self' blob:",
            "worker-src 'self'",
            "manifest-src 'self'",
            "base-uri 'none'",
            "form-action 'self'",
            "frame-ancestors 'none'"
        ].joined(separator: "; ")
    }

    /// Policy for non-HTML static files. The CSP of `service-worker.js` applies to the worker, which fetches only same-origin resources.
    static let assetPolicy = "default-src 'self'; base-uri 'none'; frame-ancestors 'none'"

    static func hashSource(_ body: String) -> String {
        "'sha256-" + Data(SHA256.hash(data: Data(body.utf8))).base64EncodedString() + "'"
    }

    /// Bodies of `<script>` elements without a `src` attribute, byte for byte as the browser hashes them.
    static func inlineScriptBodies(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<script(\\s[^>]*)?>(.*?)</script>", options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let body = Range(match.range(at: 2), in: html), !html[body].isEmpty else { return nil }
            if let attributes = Range(match.range(at: 1), in: html), html[attributes].lowercased().contains("src=") { return nil }
            return String(html[body])
        }
    }

    /// Values of inline event handler attributes (`onclick="..."`); they need `'unsafe-hashes'` to be allowed by hash.
    static func eventHandlerValues(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<[a-zA-Z][^>]*?\\son[a-z]+=\"([^\"]*)\"", options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            Range(match.range(at: 1), in: html).map { decodeEntities(String(html[$0])) }
        }
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Adds the baseline security headers to every response unless a route already chose its own value (SEC-05).
/// Routes that set stricter or more specific values (file preview CSP sandbox, token URLs, OAuth pages) are never weakened:
/// existing headers are kept as they are.
struct SecurityHeadersMiddleware: AsyncMiddleware {
    /// `Strict-Transport-Security` max-age; 0 omits the header (HTTP base URL, or the reverse proxy sets it).
    let hstsMaxAgeSeconds: Int

    static let permissionsPolicy = "camera=(), microphone=(), payment=(), usb=(), geolocation=(self), interest-cohort=()"

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        apply(to: &response.headers)
        return response
    }

    func apply(to headers: inout HTTPHeaders) {
        func setIfAbsent(_ name: String, _ value: String) { if !headers.contains(name: name) { headers.replaceOrAdd(name: name, value: value) } }
        setIfAbsent("X-Content-Type-Options", "nosniff")
        setIfAbsent("Referrer-Policy", "no-referrer")
        setIfAbsent("X-Frame-Options", "DENY")
        setIfAbsent("Permissions-Policy", Self.permissionsPolicy)
        // The PWA sets its own full policy; API and server-rendered pages (OAuth consent, token URLs) get the minimum that
        // cannot break them: no framing and no <base> injection. API responses carry no active content at all.
        if !headers.contains(name: "Content-Security-Policy") {
            let isHTML = headers.first(name: .contentType)?.lowercased().hasPrefix("text/html") ?? false
            setIfAbsent("Content-Security-Policy", isHTML ? "frame-ancestors 'none'; base-uri 'none'" : "default-src 'none'; frame-ancestors 'none'")
        }
        if hstsMaxAgeSeconds > 0 { setIfAbsent("Strict-Transport-Security", "max-age=\(hstsMaxAgeSeconds)") }
    }
}
