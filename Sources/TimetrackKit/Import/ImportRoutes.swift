import Vapor
import Fluent

struct WorktimeClockKey: StorageKey { typealias Value = @Sendable () -> Date }

/// Entry point owned by package C12 (import). Registered from `registerRoutes`.
func registerImportRoutes(_ app: Application, auth: AuthService) {
    // The error middleware is outermost so that CSRF and session errors use the same envelope.
    let api = app.grouped("api", "v1").grouped(ImportErrorMiddleware()).grouped(SessionMiddleware(service: auth))
    @Sendable func id(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw APIError.missing }; return id
    }
    @Sendable func run(_ req: Request, _ operation: @escaping @Sendable (ImportService) async throws -> Response) async throws -> Response {
        let clock = req.application.storage[WorktimeClockKey.self] ?? { Date() }
        return try await TimeServices.session(req.authContext, auth: auth, db: req.db) { try await operation(ImportService(scope: $0, now: clock)) }
    }

    // The body is streamed and collected here so that oversize uploads map to file_too_large instead of a generic 413.
    api.on(.POST, "imports", body: .stream) { req async throws -> Response in
        _ = try req.authContext
        guard req.headers.contentType?.type == "multipart", req.headers.contentType?.subType == "form-data" else { throw APIError.invalid }
        if let length = req.headers.first(name: .contentLength).flatMap(Int.init), length > ImportLimits.maxFileBytes + 64 * 1024 { throw ImportErrors.tooLarge }
        do { _ = try await req.body.collect(max: ImportLimits.maxFileBytes + 64 * 1024).get() }
        catch { throw ImportErrors.tooLarge }
        struct Upload: Content { var file: File }
        let upload: Upload
        do { upload = try req.content.decode(Upload.self) } catch { throw APIError.invalid }
        var buffer = upload.file.data
        guard let data = buffer.readData(length: buffer.readableBytes) else { throw APIError.invalid }
        guard data.count <= ImportLimits.maxFileBytes else { throw ImportErrors.tooLarge }
        let filename = upload.file.filename
        // Content sniffing and parsing happen before the serialized transaction starts.
        let workbook = try ImportWorkbook.open(data: data, filename: filename)
        return try await run(req) { try timeResponse(await $0.upload(filename: filename, data: data, workbook: workbook), status: .created) }
    }
    api.get("imports", ":id") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try timeResponse(ImportJobDTO(await $0.job(key))) }
    }
    api.delete("imports", ":id") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try await $0.discard(key); return Response(status: .noContent) }
    }
    api.get("imports", ":id", "preview") { req async throws -> Response in
        let key = try id(req); let sheet: String? = req.query["sheet"]
        return try await run(req) { try timeResponse(await $0.rawPreview(key, sheet: sheet)) }
    }
    api.put("imports", ":id", "mapping") { req async throws -> Response in
        let key = try id(req); let mapping = try timeDecode(ImportMapping.self, request: req)
        return try await run(req) { try timeResponse(await $0.putMapping(key, mapping)) }
    }
    api.post("imports", ":id", "commit") { req async throws -> Response in
        struct Input: Decodable { var ignoreErrors: Bool? }
        let key = try id(req)
        let input = (req.body.data?.readableBytesView.isEmpty ?? true) ? Input() : try timeDecode(Input.self, request: req)
        return try await run(req) { try timeResponse(await $0.commit(key, ignoreErrors: input.ignoreErrors ?? false)) }
    }
    api.post("imports", ":id", "rollback") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try timeResponse(await $0.rollback(key)) }
    }
    api.get("import-profiles", "worktime", "default-rules") { req async throws -> Response in
        try await run(req) { _ in try timeResponse(WorktimeRemarkRule.defaults) }
    }
    api.get("import-templates") { req async throws -> Response in try await run(req) { try timeResponse(await $0.templates()) } }
    api.post("import-templates") { req async throws -> Response in
        struct Input: Decodable { var name: String; var mapping: ImportMapping }
        let input = try timeDecode(Input.self, request: req)
        return try await run(req) { try timeResponse(await $0.createTemplate(name: input.name, mapping: input.mapping), status: .created) }
    }
    api.delete("import-templates", ":id") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try await $0.deleteTemplate(key); return Response(status: .noContent) }
    }
}

/// Renders every error of the import routes as `{ "error": { code, message } }` with German messages.
struct ImportErrorMiddleware: AsyncMiddleware {
    static let messages: [String: String] = [
        "file_too_large": "Die Datei ist zu groß (höchstens 5 MiB).",
        "unsupported_type": "Dieser Dateityp wird nicht unterstützt. Erlaubt sind CSV und XLSX.",
        "too_many_rows": "Die Datei enthält zu viele Zeilen (höchstens 20 000).",
        "import_not_ready": "Der Import befindet sich nicht im passenden Zustand für diese Aktion.",
        "import_has_errors": "Die Datei enthält fehlerhafte Zeilen. Bitte korrigiere sie oder ignoriere die Fehler ausdrücklich.",
        "rollback_conflict": "Einige importierte Einträge wurden inzwischen geändert und blockieren die Rücknahme.",
    ]
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do { return try await next.respond(to: request) }
        catch {
            struct Envelope: Encodable {
                struct Detail: Encodable { var code: String; var message: String; var conflicts: [UUID]?; var conflictItems: [ImportTypedConflict]? }
                var error: Detail
                var conflicts: [UUID]?
                var conflictItems: [ImportTypedConflict]?
            }
            let failure: APIError
            var conflicts: [UUID]?
            var conflictItems: [ImportTypedConflict]?
            if let known = error as? APIError { failure = known }
            else if let conflict = error as? ImportConflictError { failure = APIError(.conflict, conflict.code); conflicts = conflict.conflicts; conflictItems = conflict.items }
            else if error is TimeEngineError || error is DecodingError { failure = .invalid }
            else if let abort = error as? any AbortError {
                switch abort.status {
                case .payloadTooLarge: failure = ImportErrors.tooLarge
                case .unsupportedMediaType: failure = ImportErrors.unsupported
                case .notFound: failure = .missing
                default: failure = APIError(abort.status, "bad_request")
                }
            } else { throw error }
            let message = Self.messages[failure.code] ?? TimeMessages.german[failure.code] ?? "Die Anfrage konnte nicht verarbeitet werden."
            let response = try timeResponse(Envelope(error: .init(code: failure.code, message: message, conflicts: conflicts, conflictItems: conflictItems), conflicts: conflicts, conflictItems: conflictItems), status: failure.status)
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return response
        }
    }
}
