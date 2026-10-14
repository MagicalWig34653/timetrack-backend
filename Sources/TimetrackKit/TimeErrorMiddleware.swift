import Vapor

struct TimeErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let path = request.url.path
        let applies = ["/api/v1/time/", "/api/v1/work-models", "/api/v1/places", "/api/v1/me/device-tokens", "/api/v1/automation/",
                       "/api/v1/vacation/", "/api/v1/absences", "/api/v1/calendar/", "/api/v1/plan/", "/api/v1/shares"].contains { path.hasPrefix($0) }
        guard applies else { return try await next.respond(to: request) }
        do { return try await next.respond(to: request) }
        catch {
            let failure: APIError
            if let known = error as? APIError { failure = known }
            else if error is TimeEngineError || error is VacationEngineError || error is DecodingError { failure = .invalid }
            else if let abort = error as? any AbortError { failure = .init(abort.status, abort.status == .notFound ? "not_found" : "bad_request") }
            else { throw error }
            struct Envelope: Encodable { struct Detail: Encodable { var code: String; var message: String }; var error: Detail }
            return try timeResponse(Envelope(error: .init(code: failure.code, message: TimeMessages.german[failure.code] ?? "Die Anfrage konnte nicht verarbeitet werden.")), status: failure.status)
        }
    }
}
