import Foundation
import Vapor
import XCTVapor
@testable import TimetrackKit

/// Compares the routes registered by `configure` with the operations documented in contracts/openapi.yaml.
final class ContractRoutesTests: XCTestCase, @unchecked Sendable {
    /// Implemented routes that the contract intentionally does not describe (key: "METHOD /normalised/path").
    static let undocumentedAllowList: [String: String] = {
        var list: [String: String] = [
            "GET /.well-known/oauth-protected-resource/mcp": "RFC 9728 path-suffixed alias of the documented protected-resource metadata (same document)",
        ]
        for method in ["PUT", "PATCH", "DELETE"] { list["\(method) /mcp"] = "answers 405 method_not_allowed; only POST (and GET -> 405) are part of the contract" }
        for path in ["/.well-known/oauth-authorization-server", "/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp",
                     "/oauth/register", "/oauth/revoke", "/oauth/token"] {
            list["OPTIONS " + path] = "CORS preflight for browser-based MCP clients; no contract-level behaviour"
        }
        return list
    }()
    /// Documented operations that the router intentionally does not register.
    static let unimplementedAllowList: [String: String] = [:]

    func registeredRoutes() async throws -> Set<String> {
        let app = try await Application.make(.testing)
        app.logger.logLevel = .critical
        defer { Task { try? await app.asyncShutdown() } }
        let config = try Configuration(environment: ["SQLITE_PATH": ":memory:"])
        try await configure(app, configuration: config, mailSender: nil)
        var result: Set<String> = []
        for route in app.routes.all {
            let path = route.path.map { component -> String in
                switch component {
                case .constant(let value): return value
                case .parameter: return "{}"
                case .anything: return "*"
                case .catchall: return "**"
                }
            }.joined(separator: "/")
            result.insert("\(route.method.rawValue) /\(path)")
        }
        return result
    }

    func testRoutesMatchContract() async throws {
        let documented = Set(Contract.operations(try Contract.load()).keys)
        let implemented = try await registeredRoutes()
        let undocumented = implemented.subtracting(documented).subtracting(Self.undocumentedAllowList.keys).sorted()
        let missing = documented.subtracting(implemented).subtracting(Self.unimplementedAllowList.keys).sorted()
        XCTAssertEqual(undocumented, [], "Routes without contract entry (document them or add to the allow-list with a reason)")
        XCTAssertEqual(missing, [], "Documented operations without route")
        // Stale allow-list entries hide nothing and must be removed.
        XCTAssertEqual(Self.undocumentedAllowList.keys.filter { !implemented.contains($0) || documented.contains($0) }, [])
        XCTAssertEqual(Self.unimplementedAllowList.keys.filter { implemented.contains($0) || !documented.contains($0) }, [])
        XCTAssertGreaterThan(documented.count, 100)
    }
}
