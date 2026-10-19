import Vapor
import Fluent

/// Entry point owned by package C15 (Berichtsheft). Registered from `registerRoutes`. Report data is never shared.
func registerReportRoutes(_ app: Application, auth: AuthService) {
    let api = app.grouped("api", "v1").grouped(ReportErrorMiddleware()).grouped(SessionMiddleware(service: auth)).grouped("reports")
    @Sendable func run(_ req: Request, _ operation: @escaping @Sendable (ReportService) async throws -> Response) async throws -> Response {
        try await ReportService.session(req.authContext, auth: auth, db: req.db, operation: operation)
    }
    /// GET routes: no second authentication and no global lock (S1b).
    @Sendable func runRead(_ req: Request, _ operation: @escaping @Sendable (ReportService) async throws -> Response) async throws -> Response {
        try await ReportService.read(req.authContext, auth: auth, db: req.db, operation: operation)
    }
    @Sendable func id(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw APIError.missing }; return id
    }
    @Sendable func week(_ req: Request) throws -> (year: Int, week: Int) {
        guard let year = req.parameters.get("year", as: Int.self), let week = req.parameters.get("week", as: Int.self) else { throw APIError.invalid }
        return (year, week)
    }

    api.get("learning-fields") { req async throws -> Response in try await runRead(req) { try timeResponse(await $0.learningFields()) } }
    api.post("learning-fields") { req async throws -> Response in
        let input = try timeDecode(LearningFieldInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.createLearningField(input), status: .created) }
    }
    api.put("learning-fields", ":id") { req async throws -> Response in
        let key = try id(req); let input = try timeDecode(LearningFieldInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.updateLearningField(key, input)) }
    }
    api.delete("learning-fields", ":id") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try await $0.deleteLearningField(key); return Response(status: .noContent) }
    }

    api.post("entries") { req async throws -> Response in
        let input = try timeDecode(ReportEntryInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.createEntry(input), status: .created) }
    }
    api.put("entries", ":id") { req async throws -> Response in
        let key = try id(req); let input = try timeDecode(ReportEntryInput.self, request: req)
        let version = req.headers.first(name: .ifMatch).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }
        return try await run(req) { try timeResponse(await $0.updateEntry(key, input, version: version)) }
    }
    api.delete("entries", ":id") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try await $0.deleteEntry(key); return Response(status: .noContent) }
    }

    api.get("weeks", ":year", ":week") { req async throws -> Response in
        let (year, number) = try week(req)
        return try await runRead(req) { try timeResponse(await $0.week(year: year, week: number)) }
    }
    api.put("weeks", ":year", ":week") { req async throws -> Response in
        struct Input: Decodable { var status: String }
        let (year, number) = try week(req); let input = try timeDecode(Input.self, request: req)
        return try await run(req) { try timeResponse(await $0.putStatus(year: year, week: number, status: input.status)) }
    }
    api.get("weeks", ":year", ":week", "text") { req async throws -> Response in
        let (year, number) = try week(req)
        return try await runRead(req) { service in
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .contentType, value: "text/plain; charset=utf-8")
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return Response(status: .ok, headers: headers, body: .init(string: try await service.text(year: year, week: number)))
        }
    }

    api.get("sources") { req async throws -> Response in
        guard let year: Int = req.query["year"], let number: Int = req.query["week"] else { throw APIError.invalid }
        return try await runRead(req) { try timeResponse(await $0.sources(year: year, week: number)) }
    }
    api.post("sources") { req async throws -> Response in
        let input = try timeDecode(ReportSourceInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.createSource(input), status: .created) }
    }
    api.delete("sources", ":id") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try await $0.deleteSource(key); return Response(status: .noContent) }
    }
}

/// Renders every error of the report routes as `{ "error": { code, message } }` with German messages.
struct ReportErrorMiddleware: AsyncMiddleware {
    static let messages: [String: String] = [
        "learning_field_exists": "Ein Lernfeld mit diesem Namen existiert bereits.",
        "stale_version": "Der Eintrag wurde inzwischen geändert. Bitte lade ihn neu.",
    ]
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do { return try await next.respond(to: request) }
        catch {
            struct Envelope: Encodable { struct Detail: Encodable { var code: String; var message: String }; var error: Detail }
            let failure: APIError
            if let known = error as? APIError { failure = known }
            else if error is DecodingError || error is TimeEngineError { failure = .invalid }
            else if let abort = error as? any AbortError { failure = APIError(abort.status, abort.status == .notFound ? "not_found" : "bad_request") }
            else { throw error }
            let message = Self.messages[failure.code] ?? TimeMessages.german[failure.code] ?? "Die Anfrage konnte nicht verarbeitet werden."
            let response = try timeResponse(Envelope(error: .init(code: failure.code, message: message)), status: failure.status)
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return response
        }
    }
}
