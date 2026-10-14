import Vapor
import Fluent

func registerOIDCRoutes(_ app: Application, auth: AuthService) {
    let config = auth.configuration.oidc
    let client = config.map { OIDCClient(configuration: $0, group: app.eventLoopGroup) }
    let service = OIDCService(auth: auth, config: config, client: client)
    if let client { app.lifecycle.use(OIDCShutdown(client: client)) }
    let open = app.grouped("api", "v1")
    let api = open.grouped(SessionMiddleware(service: auth))
    let secure = auth.configuration.publicBaseURL.scheme == "https"

    @Sendable func bindingCookie(_ value: String?) -> HTTPCookies.Value {
        .init(string: value ?? "", expires: value == nil ? .distantPast : Date().addingTimeInterval(OIDCService.lifetime), maxAge: value == nil ? 0 : Int(OIDCService.lifetime),
              path: "/api/v1/auth/oidc", isSecure: secure, isHTTPOnly: true, sameSite: .lax)
    }
    @Sendable func ip(_ req: Request) -> String { req.remoteAddress?.ipAddress ?? "unknown" }

    open.get("auth", "oidc", "config") { req async throws -> Response in
        struct Body: Content { let enabled: Bool; let name: String? }
        return try await Body(enabled: config != nil, name: config?.name).encodeResponse(for: req)
    }
    api.post("auth", "oidc", "start") { req async throws -> Response in
        struct Input: Content { let purpose: OIDCPurpose; let inviteToken: String? }
        struct Output: Content { let authorizationUrl: String }
        _ = try service.requireEnabled()
        try await auth.limited(ip: ip(req), on: req.db)
        let input = try req.content.decode(Input.self)
        let started = try await service.start(purpose: input.purpose, inviteToken: input.inviteToken, context: try? req.authContext, on: req.db)
        let response = try await Output(authorizationUrl: started.authorizationURL).encodeResponse(for: req)
        response.cookies[OIDCService.bindingCookie] = bindingCookie(started.binding)
        return response
    }
    // No SessionMiddleware: the callback must always answer with a 302, even for a stale or restricted session.
    open.get("auth", "oidc", "callback") { req async throws -> Response in
        func redirect(_ location: String) -> Response {
            let response = Response(status: .found)
            response.headers.replaceOrAdd(name: .location, value: location)
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
            return response
        }
        do { try await auth.limited(ip: ip(req), on: req.db) } catch { return redirect("/login?oidc_error=oidc_failed") }
        struct Query: Decodable { let code: String?; let state: String?; let error: String? }
        let query = (try? req.query.decode(Query.self)) ?? Query(code: nil, state: nil, error: nil)
        let outcome = await service.callback(code: query.code, state: query.state, providerError: query.error,
                                             binding: req.cookies[OIDCService.bindingCookie]?.string, sessionToken: req.cookies["tt_session"]?.string, on: req.db)
        let response = redirect(outcome.location)
        if let context = outcome.session { response.cookies["tt_session"] = auth.cookie(context) }
        if outcome.clearBinding { response.cookies[OIDCService.bindingCookie] = bindingCookie(nil) }
        return response
    }
    api.post("auth", "oidc", "register") { req async throws -> Response in
        struct Input: Content { let pendingId: String; let handle: String; let displayName: String }
        _ = try service.requireEnabled()
        try await auth.limited(ip: ip(req), on: req.db)
        let input = try req.content.decode(Input.self)
        guard let pendingID = UUID(uuidString: input.pendingId) else { throw APIError.missing }
        let context = try await service.register(pendingID: pendingID, handle: input.handle, displayName: input.displayName,
                                                 binding: req.cookies[OIDCService.bindingCookie]?.string, on: req.db)
        let response = try await context.response.encodeResponse(status: .created, for: req)
        response.cookies["tt_session"] = auth.cookie(context)
        response.cookies[OIDCService.bindingCookie] = bindingCookie(nil)
        return response
    }
    api.get("me", "identities") { req async throws -> [ExternalIdentityDTO] in try await service.identities(req.authContext, on: req.db) }
    api.delete("me", "identities", ":id") { req async throws -> HTTPStatus in
        guard let id = req.parameters.get("id", as: UUID.self) else { throw APIError.missing }
        try await service.unlink(id, context: req.authContext, on: req.db)
        return .noContent
    }
}

private struct OIDCShutdown: LifecycleHandler {
    let client: OIDCClient
    func shutdownAsync(_ application: Application) async { await client.shutdown() }
}
