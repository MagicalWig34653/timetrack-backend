import Foundation
import Fluent
import XCTVapor
import Crypto
@testable import TimetrackKit

// C16 helpers: a minimal OAuth client driving the real HTTP endpoints.
struct OAuthFlow {
    let client: String
    let redirect: String
    let verifier: String
    let challenge: String
    let requestId: String
    var code: String
    let state: String
    let location: String
}

extension AuthTests {
    static let oaRedirect = "https://client.example/callback"
    static let oaResource = "http://localhost:18080/mcp"

    func oaForm(_ values: [String: String]) -> ByteBuffer {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return ByteBuffer(string: values.map { $0.key + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.sorted().joined(separator: "&"))
    }
    func oaSend(_ app: Application, _ method: HTTPMethod, _ path: String, headers: HTTPHeaders = [:], body: ByteBuffer? = nil) async throws -> XCTHTTPResponse {
        try await app.testable().sendRequest(method, path, headers: headers, body: body)
    }
    func oaJSON(_ response: XCTHTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]) ?? [:]
    }
    func oaQuery(_ location: String?) -> [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(string: location ?? "")?.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }
    @discardableResult
    func oaRegister(_ app: Application, name: String = "Test Client", redirects: [String] = [AuthTests.oaRedirect], status: HTTPStatus = .created,
                    extra: [String: Any] = [:]) async throws -> String {
        var body: [String: Any] = ["client_name": name, "redirect_uris": redirects, "token_endpoint_auth_method": "none"]
        body.merge(extra) { _, new in new }
        let response = try await oaSend(app, .POST, "/oauth/register", headers: ["Content-Type": "application/json"], body: ByteBuffer(data: JSONSerialization.data(withJSONObject: body)))
        XCTAssertEqual(response.status, status, response.body.string)
        return oaJSON(response)["client_id"] as? String ?? ""
    }
    func oaPKCE() -> (verifier: String, challenge: String) {
        let verifier = Secrets.token(bytes: 32)
        return (verifier, Data(SHA256.hash(data: Data(verifier.utf8))).base64URL)
    }
    func oaAuthorize(_ app: Application, client: String, redirect: String = AuthTests.oaRedirect, challenge: String?, method: String? = "S256", scope: String? = nil,
                     state: String? = "state-1", resource: String? = AuthTests.oaResource, responseType: String? = "code") async throws -> XCTHTTPResponse {
        var items: [String: String] = ["client_id": client, "redirect_uri": redirect]
        if let challenge { items["code_challenge"] = challenge }
        if let method { items["code_challenge_method"] = method }
        if let scope { items["scope"] = scope }
        if let state { items["state"] = state }
        if let resource { items["resource"] = resource }
        if let responseType { items["response_type"] = responseType }
        let query = oaForm(items).string
        return try await oaSend(app, .GET, "/oauth/authorize?" + query)
    }
    /// authorize + open consent request with the account session.
    func oaStart(_ app: Application, _ context: AuthContext, client: String, scope: String? = nil, state: String = "state-1") async throws -> (id: String, challenge: String, verifier: String, location: String) {
        let pkce = oaPKCE()
        let response = try await oaAuthorize(app, client: client, challenge: pkce.challenge, scope: scope, state: state)
        XCTAssertEqual(response.status, .found, response.body.string)
        let location = response.headers.first(name: .location) ?? ""
        let id = oaQuery(location)["request"] ?? ""
        return (id, pkce.challenge, pkce.verifier, location)
    }
    func oaDecision(_ app: Application, _ context: AuthContext, _ id: String, approve: Bool, scopes: [String]? = nil, csrf: Bool = true) async throws -> XCTHTTPResponse {
        var body: [String: Any] = ["approve": approve]
        if let scopes { body["scopes"] = scopes }
        var head = headers(context, csrf: csrf); head.contentType = .json
        return try await oaSend(app, .POST, "/api/v1/oauth/requests/\(id)/decision", headers: head, body: ByteBuffer(data: JSONSerialization.data(withJSONObject: body)))
    }
    /// Full authorization up to the code in the redirect.
    func oaFlow(_ app: Application, _ context: AuthContext, client: String, scope: String? = nil, approve scopes: [String]? = nil, state: String = "state-1") async throws -> OAuthFlow {
        let started = try await oaStart(app, context, client: client, scope: scope, state: state)
        let consent = try await oaSend(app, .GET, "/api/v1/oauth/requests/\(started.id)", headers: headers(context))
        XCTAssertEqual(consent.status, .ok, consent.body.string)
        let decision = try await oaDecision(app, context, started.id, approve: true, scopes: scopes)
        XCTAssertEqual(decision.status, .ok, decision.body.string)
        let url = oaJSON(decision)["redirectUrl"] as? String ?? ""
        let query = oaQuery(url)
        return OAuthFlow(client: client, redirect: AuthTests.oaRedirect, verifier: started.verifier, challenge: started.challenge, requestId: started.id,
                         code: query["code"] ?? "", state: query["state"] ?? "", location: url)
    }
    func oaToken(_ app: Application, _ values: [String: String]) async throws -> (status: HTTPStatus, json: [String: Any], response: XCTHTTPResponse) {
        let response = try await oaSend(app, .POST, "/oauth/token", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: oaForm(values))
        return (response.status, oaJSON(response), response)
    }
    func oaCodeForm(_ flow: OAuthFlow, verifier: String? = nil, redirect: String? = nil, resource: String? = nil, client: String? = nil) -> [String: String] {
        var form = ["grant_type": "authorization_code", "code": flow.code, "redirect_uri": redirect ?? flow.redirect, "client_id": client ?? flow.client,
                    "code_verifier": verifier ?? flow.verifier]
        if let resource { form["resource"] = resource }
        return form
    }
    func oaExchange(_ app: Application, _ flow: OAuthFlow) async throws -> (access: String, refresh: String, json: [String: Any]) {
        let result = try await oaToken(app, oaCodeForm(flow))
        XCTAssertEqual(result.status, .ok, result.response.body.string)
        return (result.json["access_token"] as? String ?? "", result.json["refresh_token"] as? String ?? "", result.json)
    }
    func oaOAuthError(_ result: (status: HTTPStatus, json: [String: Any], response: XCTHTTPResponse)) -> String? { result.json["error"] as? String }
}

extension AuthTests {
    func notNil<T>(_ value: @autoclosure () async throws -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await value(); XCTAssertNotNil(result, message, file: file, line: line)
    }
    func isNil<T>(_ value: @autoclosure () async throws -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await value(); XCTAssertNil(result, message, file: file, line: line)
    }
}

func oaUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { try XCTUnwrap(value, file: file, line: line) }
