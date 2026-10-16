import Vapor
import Fluent

func registerRoutes(_ app: Application, service: AuthService) {
    registerModuleRoutes(app, auth: service)
    registerTimeRoutes(app, auth: service)
    registerPlanningRoutes(app, auth: service)
    registerExportRoutes(app, auth: service)
    registerImportRoutes(app, auth: service)
    registerStorageRoutes(app, auth: service)
    registerReportRoutes(app, auth: service)
    registerOIDCRoutes(app, auth: service)
    registerAccountRoutes(app, auth: service)
    app.mcpAuthenticator = OAuthMcpAuthenticator(disabledModules: service.configuration.disabledModules)
    registerMCPRoutes(app, auth: service)
    registerOAuthRoutes(app, auth: service)
    app.get("health") { _ in StatusResponse(status: "ok") }
    // Associated Domains for native passkeys: public, no redirect, no auth. Apple's CDN fetches it without cookies.
    let appIDs = service.configuration.appleAppIDs
    app.get(".well-known", "apple-app-site-association") { _ -> Response in
        guard !appIDs.isEmpty else { throw Abort(.notFound) }
        let body = try JSONSerialization.data(withJSONObject: ["webcredentials": ["apps": appIDs]], options: [.sortedKeys])
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=3600")
        return Response(status: .ok, headers: headers, body: .init(data: body))
    }
    app.get("ready") { request async -> Response in
        do {
            try await requireSQL(request.db).raw("SELECT 1").run()
            guard try await app.migrator.previewPrepareBatch().get().isEmpty else {
                return try await NotReadyResponse().encodeResponse(status: .serviceUnavailable, for: request)
            }
            return try await StatusResponse(status: "ok").encodeResponse(for: request)
        } catch {
            return (try? await NotReadyResponse().encodeResponse(status: .serviceUnavailable, for: request)) ?? Response(status: .serviceUnavailable)
        }
    }
    let api = app.grouped("api", "v1").grouped(SessionMiddleware(service: service)).grouped(AuthRateLimitMiddleware(service: service))
    @Sendable func id(_ req: Request) throws -> UUID { guard let id = req.parameters.get("id", as: UUID.self) else { throw APIError.missing }; return id }
    @Sendable func limit(_ req: Request, subject: AuthService.RateLimitSubject = .anonymous) async throws {
        try await service.limitRequest(subject: subject, on: req.db)
    }
    @Sendable func sessionResponse(_ context: AuthContext, request: Request, status: HTTPResponseStatus = .ok) async throws -> Response {
        let response = try await context.response.encodeResponse(status: status, for: request)
        response.cookies["tt_session"] = service.cookie(context)
        return response
    }
    api.get("invitations", ":token") { req async throws -> Response in
        struct Inspection: Content { let valid: Bool; let expiresAt: Date }
        let invite = try await service.invitation(req.parameters.get("token") ?? "", on: req.db)
        return try await Inspection(valid: true, expiresAt: invite.expiresAt).encodeResponse(for: req)
    }
    api.post("auth", "register", "options") { req async throws -> OptionsDTO in
        let input = try req.content.decode(RegisterInput.self); try await limit(req, subject: .handle(input.handle))
        return try await service.registrationOptions(input, on: req.db)
    }
    api.post("auth", "register", "verify") { req async throws -> Response in
        let proof = try req.content.decode(RegisterProof.self)
        try await limit(req, subject: .registration(proof.challengeId))
        return try await sessionResponse(service.register(proof, on: req.db), request: req, status: .created)
    }
    api.post("auth", "login", "options") { req async throws -> OptionsDTO in
        try await limit(req); return try await service.loginOptions(on: req.db)
    }
    api.post("auth", "login", "verify") { req async throws -> Response in
        let proof = try req.content.decode(LoginProof.self)
        try await limit(req, subject: .credential(Data(proof.credential.rawID)))
        return try await sessionResponse(service.login(proof, on: req.db), request: req)
    }
    api.get("auth", "session") { req throws -> SessionDTO in try req.authContext.response }
    api.delete("auth", "session") { req async throws -> Response in
        try await service.revokeSessions(req.authContext, others: false, on: req.db)
        let response = Response(status: .noContent)
        response.cookies["tt_session"] = .init(string: "", expires: .distantPast, maxAge: 0, path: "/", isSecure: service.configuration.publicBaseURL.scheme == "https", isHTTPOnly: true, sameSite: .lax)
        return response
    }
    api.get("me", "passkeys") { req async throws -> [PasskeyDTO] in try await service.passkeys(req.authContext, on: req.db) }
    api.post("me", "passkeys", "options") { req async throws -> OptionsDTO in try await service.addOptions(req.authContext, on: req.db) }
    api.post("me", "passkeys", "verify") { req async throws -> Response in
        let key = try await service.addPasskey(req.content.decode(RegisterProof.self), context: req.authContext, on: req.db)
        let response = try await key.encodeResponse(status: .created, for: req)
        let current = try await service.authenticate(req.authContext.token, on: req.db)
        response.cookies["tt_session"] = service.cookie(current)
        return response
    }
    api.patch("me", "passkeys", ":id") { req async throws -> PasskeyDTO in
        struct Input: Content { let name: String }
        return try await service.changePasskey(id(req), name: req.content.decode(Input.self).name, context: req.authContext, on: req.db)
    }
    api.delete("me", "passkeys", ":id") { req async throws -> HTTPStatus in
        _ = try await service.changePasskey(id(req), name: nil, context: req.authContext, on: req.db); return .noContent
    }
    api.delete("me", "sessions") { req async throws -> HTTPStatus in
        try await service.revokeSessions(req.authContext, others: true, on: req.db); return .noContent
    }
    api.get("me", "recovery") { req async throws -> RecoveryStatusDTO in try await service.recoveryStatus(req.authContext, on: req.db) }
    api.post("me", "recovery", "recovery-codes") { req async throws -> Response in
        struct Codes: Content { let codes: [String] }
        return try await Codes(codes: service.recoveryCodes(req.authContext, generate: true, on: req.db)).encodeResponse(status: .created, for: req)
    }
    api.delete("me", "recovery", "recovery-codes") { req async throws -> HTTPStatus in
        _ = try await service.recoveryCodes(req.authContext, generate: false, on: req.db); return .noContent
    }
    api.put("me", "recovery", "fallback-password") { req async throws -> HTTPStatus in
        struct Input: Content { let password: String }
        try await service.fallbackPassword(req.content.decode(Input.self).password, context: req.authContext, on: req.db); return .noContent
    }
    api.delete("me", "recovery", "fallback-password") { req async throws -> HTTPStatus in
        try await service.fallbackPassword(nil, context: req.authContext, on: req.db); return .noContent
    }
    api.put("me", "recovery", "email") { req async throws -> HTTPStatus in
        struct Input: Content { let email: String }
        try await limit(req)
        try await service.enableEmail(req.content.decode(Input.self).email, context: req.authContext, on: req.db); return .accepted
    }
    api.delete("me", "recovery", "email") { req async throws -> HTTPStatus in
        try await service.disableEmail(req.authContext, on: req.db); return .noContent
    }
    api.post("me", "recovery", "email", "verify") { req async throws -> HTTPStatus in
        struct Input: Content { let code: String }
        try await limit(req)
        try await service.verifyEmail(req.content.decode(Input.self).code, context: req.authContext, on: req.db); return .noContent
    }
    api.post("auth", "recovery", "start") { req async throws -> Response in
        let input = try req.content.decode(RecoveryStart.self); try await limit(req, subject: .handle(input.identifier))
        return try await service.recoveryStart(input, on: req.db).encodeResponse(status: .accepted, for: req)
    }
    api.post("auth", "recovery", "complete") { req async throws -> Response in
        let proof = try req.content.decode(RecoveryProof.self)
        try await limit(req, subject: .recovery(proof.recoveryId))
        return try await sessionResponse(service.recoveryComplete(proof, on: req.db), request: req)
    }
    api.get("admin", "invitations") { req async throws -> [InvitationDTO] in try await service.invitations(req.authContext, on: req.db) }
    api.post("admin", "invitations") { req async throws -> Response in
        let input = (req.body.data?.readableBytes ?? 0) == 0 ? InvitationInput() : try req.content.decode(InvitationInput.self)
        return try await service.createInvitation(input, context: req.authContext, on: req.db).encodeResponse(status: .created, for: req)
    }
    api.delete("admin", "invitations", ":id") { req async throws -> HTTPStatus in
        try await service.revokeInvitation(id(req), context: req.authContext, on: req.db); return .noContent
    }
}
