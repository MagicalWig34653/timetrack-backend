import Vapor

/// Mirrors DefaultResponder: empty path segments do not participate in routing.
/// Do not percent-decode here; the router splits the URL path as supplied.
extension Request {
    var routePathComponents: [Substring] { url.path.split(separator: "/", omittingEmptySubsequences: true) }
    var normalizedRoutePath: String { "/" + routePathComponents.joined(separator: "/") }
}
