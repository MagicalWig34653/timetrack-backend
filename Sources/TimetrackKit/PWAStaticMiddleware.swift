import Vapor

struct PWAStaticMiddleware: AsyncMiddleware {
    let directory: String
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let path = request.url.path
        guard request.method == .GET, !["/api", "/health", "/ready", "/.well-known", "/oauth/authorize", "/mcp"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
              FileManager.default.fileExists(atPath: directory) else { return try await next.respond(to: request) }
        guard let decoded = path.removingPercentEncoding, !decoded.contains("\\"), !decoded.contains("\0"),
              !decoded.split(separator: "/").contains("..") else { throw APIError.missing }
        if ["/api", "/health", "/ready", "/.well-known", "/oauth/authorize", "/mcp"].contains(where: { decoded == $0 || decoded.hasPrefix($0 + "/") }) { throw APIError.missing }
        let root = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
        var file = root.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") || file == root else { throw APIError.missing }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) || isDirectory.boolValue {
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
