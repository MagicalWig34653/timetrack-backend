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

    /// S1b contract hygiene: every operation carries a short German `summary` (one line, no trailing period) and an operationId.
    func testEveryOperationHasShortGermanSummary() throws {
        let operations = Contract.operations(try Contract.load())
        var problems: [String] = []
        var ids: [String: String] = [:]
        for (key, operation) in operations.sorted(by: { $0.key < $1.key }) {
            guard let summary = operation["summary"] as? String, !summary.trimmingCharacters(in: .whitespaces).isEmpty else {
                problems.append("\(key): summary missing"); continue
            }
            if summary.count > 70 || summary.contains("\n") { problems.append("\(key): summary too long or multi-line") }
            if summary.hasSuffix(".") { problems.append("\(key): summary ends with a period") }
            guard let id = operation["operationId"] as? String else { problems.append("\(key): operationId missing"); continue }
            if let other = ids[id] { problems.append("\(key): operationId \(id) also used by \(other)") }
            ids[id] = key
        }
        XCTAssertEqual(problems, [])
        // Summaries are meant to differ per operation so generated clients and docs stay readable.
        let summaries = operations.values.compactMap { $0["summary"] as? String }
        XCTAssertEqual(Set(summaries).count, summaries.count, "summaries must be unique")
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
