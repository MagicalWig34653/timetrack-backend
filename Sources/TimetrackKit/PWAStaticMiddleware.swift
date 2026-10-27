import Vapor

struct PWAStaticMiddleware: AsyncMiddleware {
    let directory: String
    /// File extensions that identify a static asset request. A missing asset must never be answered with the SPA shell:
    /// a browser would receive text/html for a module script (white page when replicas or caches hold different builds).
    static let assetExtensions: Set<String> = [
        "js", "mjs", "css", "map", "json", "webmanifest", "txt", "xml", "png", "jpg", "jpeg", "gif", "webp", "avif", "svg", "ico",
        "woff", "woff2", "ttf", "otf", "eot", "wasm", "mp3", "mp4", "webm", "pdf"
    ]
    /// True when `decodedPath` is a request for a file rather than a client-side navigation route.
    static func isAssetRequest(_ decodedPath: String) -> Bool {
        if decodedPath == "/_app" || decodedPath.hasPrefix("/_app/") { return true }
        guard let last = decodedPath.split(separator: "/").last, let dot = last.lastIndex(of: "."), dot != last.startIndex else { return false }
        return assetExtensions.contains(last[last.index(after: dot)...].lowercased())
    }
    private static func notFound() -> Response {
        let response = Response(status: .notFound, body: .init(string: "Not found\n"))
        response.headers.replaceOrAdd(name: .contentType, value: "text/plain; charset=utf-8")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        return response
    }
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let path = request.url.path
        if request.method == .GET, path == "/.well-known" || path.hasPrefix("/.well-known/") {
            // Discovery documents are real routes; anything unknown stays a real 404 (never the SPA shell) and is not cached.
            let response = try await next.respond(to: request)
            if response.status == .notFound { response.headers.replaceOrAdd(name: .cacheControl, value: "no-store") }
            return response
        }
        guard request.method == .GET, !["/api", "/health", "/ready", "/.well-known", "/oauth/authorize", "/mcp", "/t", "/ics"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
              FileManager.default.fileExists(atPath: directory) else { return try await next.respond(to: request) }
        guard let decoded = path.removingPercentEncoding, !decoded.contains("\\"), !decoded.contains("\0"),
              !decoded.split(separator: "/").contains("..") else { throw APIError.missing }
        if ["/api", "/health", "/ready", "/.well-known", "/oauth/authorize", "/mcp", "/t", "/ics"].contains(where: { decoded == $0 || decoded.hasPrefix($0 + "/") }) { throw APIError.missing }
        let root = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
        var file = root.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") || file == root else { throw APIError.missing }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) || isDirectory.boolValue {
            if Self.isAssetRequest(decoded) { return Self.notFound() }
            file = root.appendingPathComponent("index.html").resolvingSymlinksInPath()
        }
        guard file.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: file.path) else { return try await next.respond(to: request) }
        let response = try await request.fileio.asyncStreamFile(at: file.path)
        // Only SvelteKit's content-hashed output is immutable; other static files (icons, manifest, service worker) are revalidated.
        let hashed = decoded.hasPrefix("/_app/immutable/")
        response.headers.replaceOrAdd(name: .cacheControl, value: file.lastPathComponent == "index.html" ? "no-cache" : hashed ? "public, max-age=31536000, immutable" : "no-cache")
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        // Vapor has no mapping for .webmanifest; browsers expect the manifest media type.
        if file.pathExtension == "webmanifest" { response.headers.replaceOrAdd(name: .contentType, value: "application/manifest+json") }
        // Same for favicons: with nosniff a missing or wrong type would make browsers drop the icon.
        if file.pathExtension == "ico" { response.headers.replaceOrAdd(name: .contentType, value: "image/x-icon") }
        if file.pathExtension == "svg" { response.headers.replaceOrAdd(name: .contentType, value: "image/svg+xml") }
        return response
    }
}
