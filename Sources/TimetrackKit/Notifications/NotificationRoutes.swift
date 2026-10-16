import Foundation
import Vapor
import Fluent

func registerNotificationRoutes(_ app: Application, auth: AuthService, service: NotificationService) {
    let api = app.grouped("api", "v1").grouped(NotificationErrorMiddleware()).grouped(SessionMiddleware(service: auth))
    @Sendable func account(_ req: Request) throws -> UUID {
        let context = try req.authContext
        try context.normal()
        return try context.account.requireID()
    }
    @Sendable func id(_ req: Request) throws -> UUID { guard let id = req.parameters.get("id", as: UUID.self) else { throw APIError.missing }; return id }

    api.get("notifications") { req async throws -> Response in
        let owner = try account(req)
        var limit = 50
        if let raw: String = req.query["limit"] { guard let parsed = Int(raw), (1...100).contains(parsed) else { throw APIError.invalid }; limit = parsed }
        var before: Date?
        if let raw: String = req.query["before"] { guard let parsed = timeInstant(raw) else { throw APIError.invalid }; before = parsed }
        var unreadOnly = false
        if let raw: String = req.query["unreadOnly"] { guard ["true", "false"].contains(raw) else { throw APIError.invalid }; unreadOnly = raw == "true" }
        return try timeResponse(await service.list(owner, unreadOnly: unreadOnly, limit: limit, before: before, on: req.db))
    }
    api.post("notifications", "read") { req async throws -> Response in
        let owner = try account(req)
        let input = try timeDecode(MarkReadInput.self, request: req)
        return try timeResponse(UnreadCountDTO(unreadCount: await service.markRead(owner, input, on: req.db)))
    }
    api.get("notifications", "settings") { req async throws -> Response in
        try timeResponse(await service.settings(account(req), on: req.db))
    }
    api.put("notifications", "settings") { req async throws -> Response in
        let owner = try account(req)
        return try timeResponse(await service.putSettings(owner, timeDecode(NotificationSettingsDTO.self, request: req), on: req.db))
    }
    api.delete("notifications", ":id") { req async throws -> Response in
        try await service.delete(account(req), id: id(req), on: req.db); return Response(status: .noContent)
    }
    api.get("push", "config") { req async throws -> Response in _ = try account(req); return try timeResponse(service.config) }
    api.get("me", "push-subscriptions") { req async throws -> Response in
        try timeResponse(await service.subscriptions(account(req), on: req.db))
    }
    api.post("me", "push-subscriptions") { req async throws -> Response in
        let owner = try account(req)
        return try timeResponse(await service.subscribe(owner, timeDecode(PushSubscriptionInput.self, request: req), on: req.db), status: .created)
    }
    registerPushSubscriptionReplaceRoute(api, service: service, account: account)
    api.delete("me", "push-subscriptions", ":id") { req async throws -> Response in
        try await service.unsubscribe(account(req), id: id(req), on: req.db); return Response(status: .noContent)
    }
    api.post("me", "push-subscriptions", ":id", "test") { req async throws -> Response in
        try await service.sendTest(account(req), id: id(req), on: req.db); return Response(status: .accepted)
    }
}

/// Renders every error of the notification routes as `{ "error": { code, message } }` with German messages.
struct NotificationErrorMiddleware: AsyncMiddleware {
    static let messages: [String: String] = [
        "push_unavailable": "Push-Benachrichtigungen sind auf diesem Server nicht eingerichtet.",
        "too_many_subscriptions": "Es sind höchstens 10 Geräte für Push-Benachrichtigungen möglich.",
        "push_failed": "Die Testnachricht konnte nicht zugestellt werden.",
        "too_many_requests": "Zu viele Anfragen. Bitte versuche es später erneut.",
        "recovery_session_restricted": "Diese Aktion ist in einer Wiederherstellungssitzung nicht erlaubt.",
    ]
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do { return try await next.respond(to: request) }
        catch {
            struct Envelope: Encodable { struct Detail: Encodable { var code: String; var message: String }; var error: Detail }
            let failure: APIError
            if let known = error as? APIError { failure = known }
            else if error is DecodingError { failure = .invalid }
            else if let abort = error as? any AbortError { failure = APIError(abort.status, abort.status == .notFound ? "not_found" : "bad_request") }
            else { throw error }
            let message = Self.messages[failure.code] ?? TimeMessages.german[failure.code] ?? "Die Anfrage konnte nicht verarbeitet werden."
            let response = try timeResponse(Envelope(error: .init(code: failure.code, message: message)), status: failure.status)
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return response
        }
    }
}
