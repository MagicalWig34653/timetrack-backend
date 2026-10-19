import Foundation
import XCTVapor
import AsyncKit
import MySQLNIO
import SQLiteNIO
import NIOCore
import NIOPosix
@testable import TimetrackKit

final class InfrastructureErrorTests: XCTestCase, @unchecked Sendable {
    private struct Bug: Error {}

    func testClassifiesConnectionAndPoolFailures() {
        XCTAssertEqual(InfrastructureError.classify(ConnectionPoolTimeoutError.connectionRequestTimeout), .poolTimeout)
        XCTAssertEqual(InfrastructureError.classify(ConnectionPoolError.shutdown), .connectionClosed)
        XCTAssertEqual(InfrastructureError.classify(IOError(errnoCode: ECONNREFUSED, reason: "connect")), .connectionFailed)
        XCTAssertEqual(InfrastructureError.classify(IOError(errnoCode: ECONNRESET, reason: "read")), .connectionFailed)
        XCTAssertEqual(InfrastructureError.classify(ChannelError.ioOnClosedChannel), .connectionClosed)
        XCTAssertEqual(InfrastructureError.classify(MySQLError.closed), .connectionClosed)
        XCTAssertEqual(InfrastructureError.classify(sqlite: .busy), .sqliteBusy)
        XCTAssertEqual(InfrastructureError.classify(NSError(domain: "x", code: 1, userInfo: [NSUnderlyingErrorKey: IOError(errnoCode: ECONNREFUSED, reason: "connect")])), .connectionFailed)
    }

    func testDoesNotClassifyApplicationErrors() {
        XCTAssertNil(InfrastructureError.classify(Bug()))
        XCTAssertNil(InfrastructureError.classify(MySQLError.duplicateEntry("dup")))
        XCTAssertNil(InfrastructureError.classify(MySQLError.invalidSyntax("syntax")))
        XCTAssertNil(InfrastructureError.classify(sqlite: .constraintUniqueFailed))
        XCTAssertNil(InfrastructureError.classify(APIError.invalid))
    }

    /// Q1 finding 4 / S1b: an unreachable OIDC provider (an outbound HTTP call, not the database) surfaces as a typed OIDC
    /// error, never as a raw NIO error that the middleware would report as "database unavailable".
    func testOutboundOIDCFailureIsNotClassifiedAsDatabaseOutage() async throws {
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(listener.localAddress?.port)
        try await listener.close()   // nothing listens on this port any more: connection refused
        let configuration = try XCTUnwrap(OIDCConfiguration(environment: ["OIDC_ISSUER": "http://127.0.0.1:\(port)", "OIDC_CLIENT_ID": "client"]))
        let client = OIDCClient(configuration: configuration, group: MultiThreadedEventLoopGroup.singleton)
        do {
            _ = try await client.discover()
            XCTFail("discovery against a closed port must fail")
        } catch {
            guard case OIDCClientError.network = error else { return XCTFail("expected OIDCClientError.network, got \(error)") }
            XCTAssertNil(InfrastructureError.classify(error))
        }
        await client.shutdown()
    }

    func testRetryAfterDiffersForPoolTimeout() {
        XCTAssertEqual(InfrastructureError.Kind.poolTimeout.retryAfterSeconds, 5)
        XCTAssertEqual(InfrastructureError.Kind.connectionFailed.retryAfterSeconds, 2)
    }

    func testMiddlewareAnswers503WithRetryAfter() async throws {
        let app = try await Application.make(.testing)
        app.middleware.use(APIErrorMiddleware())
        app.get("api", "refused") { _ async throws -> String in throw IOError(errnoCode: ECONNREFUSED, reason: "connect") }
        app.get("api", "pool") { _ async throws -> String in throw ConnectionPoolTimeoutError.connectionRequestTimeout }
        app.get("api", "bug") { _ async throws -> String in throw Bug() }
        do {
            try await app.test(.GET, "api/refused") { response async throws in
                XCTAssertEqual(response.status, .serviceUnavailable)
                XCTAssertEqual(response.headers.first(name: .retryAfter), "2")
                let body = try response.content.decode([String: [String: String]].self)
                XCTAssertEqual(body["error"]?["code"], "database_unavailable")
                XCTAssertEqual(body["error"]?["message"], "Der Server kann die Datenbank gerade nicht erreichen. Bitte gleich noch einmal versuchen.")
                XCTAssertFalse(response.body.string.contains("errno"))
            }
            try await app.test(.GET, "api/pool") { response async throws in
                XCTAssertEqual(response.status, .serviceUnavailable)
                XCTAssertEqual(response.headers.first(name: .retryAfter), "5")
            }
            try await app.test(.GET, "api/bug") { response async throws in
                XCTAssertEqual(response.status, .internalServerError)
                XCTAssertNil(response.headers.first(name: .retryAfter))
                XCTAssertEqual(try response.content.decode([String: [String: String]].self)["error"]?["code"], "not_ready")
            }
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
