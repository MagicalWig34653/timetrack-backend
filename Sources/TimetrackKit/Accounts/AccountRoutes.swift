import Vapor
import Fluent

/// Account administration, data export and account deletion (package B1, ADR-0016). Not behind any module switch.
func registerAccountRoutes(_ app: Application, auth: AuthService) {
    let api = app.grouped("api", "v1").grouped(SessionMiddleware(service: auth))
    @Sendable func admin(_ req: Request) -> AccountAdminService {
        AccountAdminService(auth: auth, db: req.db, storage: StorageService(auth: auth, db: req.db, client: req.client, env: req.application.storageEnvironment))
    }
    @Sendable func id(_ req: Request) throws -> UUID { guard let id = req.parameters.get("id", as: UUID.self) else { throw APIError.missing }; return id }
    @Sendable func confirmation(_ req: Request) throws -> AccountDeletionConfirm {
        guard let confirm = try? req.content.decode(AccountDeletionConfirm.self) else { throw APIError.invalid }
        return confirm
    }

    api.get("admin", "accounts") { req async throws -> AdminAccountPage in
        try await admin(req).list(req.authContext, limit: req.query["limit"], offset: req.query["offset"])
    }
    api.patch("admin", "accounts", ":id") { req async throws -> AdminAccountDTO in
        try await admin(req).patch(id(req), req.content.decode(AdminAccountPatch.self), context: req.authContext)
    }
    api.delete("admin", "accounts", ":id", "sessions") { req async throws -> HTTPStatus in
        try await admin(req).revokeSessions(id(req), context: req.authContext); return .noContent
    }
    api.delete("admin", "accounts", ":id") { req async throws -> HTTPStatus in
        try await admin(req).delete(id(req), confirm: confirmation(req), context: req.authContext, selfService: false); return .noContent
    }

    api.get("me", "export") { req async throws -> Response in
        let service = admin(req)
        let result = try await AccountExportService(auth: auth, db: req.db, storage: service.storage).archive(req.authContext)
        _ = try? await AccountAuditRecord(action: "account.exported", actor: req.authContext.account.requireID(), target: req.authContext.account.requireID()).create(on: req.db)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/zip")
        headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=\"\(result.fileName)\"")
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        return Response(status: .ok, headers: headers, body: .init(data: result.data))
    }
    api.delete("me") { req async throws -> Response in
        let context = try req.authContext
        try await admin(req).delete(context.account.requireID(), confirm: confirmation(req), context: context, selfService: true)
        let response = Response(status: .noContent)
        response.cookies["tt_session"] = .init(string: "", expires: .distantPast, maxAge: 0, path: "/", isSecure: auth.configuration.publicBaseURL.scheme == "https", isHTTPOnly: true, sameSite: .lax)
        return response
    }
}
