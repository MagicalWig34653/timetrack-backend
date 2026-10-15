import Vapor
import Fluent

func registerOAuthRoutes(_ app: Application, auth: AuthService) {
    let oauth = OAuthService(auth: auth)
    let tokenLimiter = OAuthTokenLimiter()
    let credentials = OAuthCredentialService(auth: auth, oauth: oauth)
    let api = app.grouped("api", "v1").grouped(SessionMiddleware(service: auth))
    @Sendable func ip(_ req: Request) -> String { req.remoteAddress?.ipAddress ?? "unknown" }
    @Sendable func id(_ req: Request) throws -> UUID { guard let id = req.parameters.get("id", as: UUID.self) else { throw APIError.missing }; return id }

    @Sendable func machine(_ req: Request, _ body: () async throws -> Response) async throws -> Response { try await machineResponse(req, body) }
    @Sendable func json<T: Encodable & Sendable>(_ value: T, _ req: Request, status: HTTPResponseStatus = .ok) throws -> Response {
        let response = Response(status: status)
        response.headers.contentType = .json
        response.body = .init(data: try JSONEncoder().encode(value))
        return response
    }
    @Sendable func preflight(_ req: Request) -> Response {
        let response = Response(status: .noContent)
        response.headers.replaceOrAdd(name: .accessControlAllowOrigin, value: "*")
        response.headers.replaceOrAdd(name: .accessControlAllowMethods, value: "GET, POST, OPTIONS")
        response.headers.replaceOrAdd(name: .accessControlAllowHeaders, value: "Content-Type, Authorization, MCP-Protocol-Version")
        response.headers.replaceOrAdd(name: .accessControlMaxAge, value: "600")
        return response
    }

    // Metadata (RFC 9728 / RFC 8414). The resource has a path, so RFC 9728 path-insertion is served as well.
    for path in [["oauth-protected-resource"], ["oauth-protected-resource", "mcp"]] {
        app.get([".well-known"] + path.map { PathComponent(stringLiteral: $0) }) { req in
            try await machine(req) { try json(oauth.protectedResourceMetadata, req) }
        }
    }
    app.get(".well-known", "oauth-authorization-server") { req in
        try await machine(req) { try json(oauth.authorizationServerMetadata, req) }
    }
    for path: [PathComponent] in [[".well-known", "oauth-protected-resource"], [".well-known", "oauth-protected-resource", "mcp"], [".well-known", "oauth-authorization-server"],
                                  ["oauth", "register"], ["oauth", "token"], ["oauth", "revoke"]] {
        app.on(.OPTIONS, path) { preflight($0) }
    }

    app.post("oauth", "register") { req in
        try await machine(req) {
            let input = try req.content.decode(RegistrationInput.self)
            return try json(await oauth.register(input, ip: ip(req), on: req.db), req, status: .created)
        }
    }

    // Errors that must not redirect (unknown client, redirect mismatch) are answered as JSON; all others redirect.
    app.get("oauth", "authorize") { req async throws -> Response in
        do {
            let query = try req.query.decode(AuthorizeQuery.self)
            let location = try await oauth.authorize(query, ip: ip(req), on: req.db)
            let response = Response(status: .found)
            response.headers.replaceOrAdd(name: .location, value: location)
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
            return response
        } catch let error as OAuthError {
            let response = try await error.body.encodeResponse(status: error.status, for: req)
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return response
        } catch is DecodingError {
            return try await OAuthError("invalid_request", "Malformed request.").body.encodeResponse(status: .badRequest, for: req)
        } catch let abort as any AbortError where abort.status.code < 500 {
            return try await OAuthError("invalid_request", "Malformed request.").body.encodeResponse(status: .badRequest, for: req)
        }
    }

    app.post("oauth", "token") { req in
        try await machine(req) {
            try await tokenLimiter.admit(ip: ip(req))
            let form = try req.content.decode(TokenForm.self)
            try await tokenLimiter.admit(ip: ip(req), client: String((form.client_id ?? "unknown").prefix(128)))
            return try json(await oauth.token(form, on: req.db), req)
        }
    }
    app.post("oauth", "revoke") { req in
        try await machine(req) {
            struct Form: Decodable { let token: String?; let client_id: String? }
            let form = try req.content.decode(Form.self)
            if let token = form.token { try await oauth.revoke(token: token, clientID: form.client_id, on: req.db) }
            return try json([String: String](), req)
        }
    }

    api.get("oauth", "requests", ":id") { req async throws -> OAuthRequestDTO in
        try await oauth.consent(id(req), req.authContext, on: req.db)
    }
    api.post("oauth", "requests", ":id", "decision") { req async throws -> Response in
        struct Input: Content { let approve: Bool; let scopes: [String]? }
        struct Output: Content { let redirectUrl: String }
        let input = try req.content.decode(Input.self)
        let location = try await oauth.decide(id(req), approve: input.approve, scopes: input.scopes, req.authContext, on: req.db)
        return try await Output(redirectUrl: location).encodeResponse(for: req)
    }

    api.get("me", "oauth-grants") { req async throws -> [OAuthGrantDTO] in try await credentials.grants(req.authContext, on: req.db) }
    api.delete("me", "oauth-grants", ":id") { req async throws -> HTTPStatus in
        try await credentials.revokeGrant(id(req), req.authContext, on: req.db); return .noContent
    }
    api.get("me", "api-tokens") { req async throws -> [ApiTokenDTO] in try await credentials.tokens(req.authContext, on: req.db) }
    api.post("me", "api-tokens") { req async throws -> Response in
        let input = try req.content.decode(ApiTokenInput.self)
        return try await credentials.createToken(input, req.authContext, on: req.db).encodeResponse(status: .created, for: req)
    }
    api.delete("me", "api-tokens", ":id") { req async throws -> HTTPStatus in
        try await credentials.revokeToken(id(req), req.authContext, on: req.db); return .noContent
    }
}

    /// Public machine endpoints: RFC 6749 JSON errors, CORS for browser-based clients, never cached.
private func machineResponse(_ req: Request, _ body: () async throws -> Response) async throws -> Response {
    let response: Response
    do { response = try await body() }
    catch {
        if let failure = error as? OAuthError { response = try await failure.body.encodeResponse(status: failure.status, for: req) }
        else if error is DecodingError || (error as? any AbortError).map({ $0.status.code < 500 && $0.status != .tooManyRequests }) == true {
            response = try await OAuthError("invalid_request", "Malformed request.").body.encodeResponse(status: .badRequest, for: req)
        } else { throw error }
    }
    response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
    response.headers.replaceOrAdd(name: .pragma, value: "no-cache")
    response.headers.replaceOrAdd(name: .accessControlAllowOrigin, value: "*")
    return response
}
