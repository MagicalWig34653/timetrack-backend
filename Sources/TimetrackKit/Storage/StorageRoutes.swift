import Vapor
import Fluent

/// Entry point owned by package C13 (file storage and attachments). Registered from `registerRoutes`.
func registerStorageRoutes(_ app: Application, auth: AuthService) {
    // The error middleware is outermost so that CSRF and session errors use the same envelope.
    let api = app.grouped("api", "v1").grouped(StorageErrorMiddleware()).grouped(SessionMiddleware(service: auth))
    @Sendable func service(_ req: Request) -> StorageService {
        StorageService(auth: auth, db: req.db, client: req.client, env: req.application.storageEnvironment)
    }
    @Sendable func id(_ req: Request, _ name: String = "id") throws -> UUID {
        guard let id = req.parameters.get(name, as: UUID.self) else { throw APIError.missing }; return id
    }

    api.get("admin", "storage") { req async throws -> Response in
        try timeResponse(await service(req).settings(req.authContext))
    }
    api.put("admin", "storage") { req async throws -> Response in
        let input = try timeDecode(StorageSettingsInput.self, request: req)
        return try timeResponse(await service(req).putSettings(req.authContext, input))
    }

    // The body is streamed and collected here so that oversize uploads map to file_too_large instead of a generic 413.
    api.on(.POST, "files", body: .stream) { req async throws -> Response in
        let context = try req.authContext
        guard req.headers.contentType?.type == "multipart", req.headers.contentType?.subType == "form-data" else { throw APIError.invalid }
        let storage = service(req)
        let limit = try await storage.uploadLimit(context)
        let frame = limit + StorageLimits.multipartOverhead
        if let length = req.headers.first(name: .contentLength).flatMap(Int.init), length > frame { throw StorageErrors.tooLarge }
        // `collect(max:)` aborts while chunks arrive; nothing beyond the limit is buffered.
        do { _ = try await req.body.collect(max: frame).get() } catch { throw StorageErrors.tooLarge }
        struct Upload: Content { var file: File }
        let upload: Upload
        do { upload = try req.content.decode(Upload.self) } catch { throw APIError.invalid }
        var buffer = upload.file.data
        guard let data = buffer.readData(length: buffer.readableBytes) else { throw APIError.invalid }
        guard data.count <= limit else { throw StorageErrors.tooLarge }
        let declared = upload.file.contentType.map { "\($0.type)/\($0.subType)" }
        return try timeResponse(await storage.upload(context, filename: upload.file.filename, declaredType: declared, data: data), status: .created)
    }
    api.get("files", ":id") { req async throws -> Response in
        let (file, data) = try await service(req).download(req.authContext, id: id(req))
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: file.contentType)
        // `?disposition=inline` only for the safe previewable whitelist; any other value or type falls back to attachment.
        let inline = req.query[String.self, at: "disposition"] == "inline" && FilenameSanitizer.isInlineSafe(file.contentType)
        headers.replaceOrAdd(name: .contentDisposition, value: FilenameSanitizer.contentDisposition(file.name, inline: inline))
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        if inline { headers.replaceOrAdd(name: "Content-Security-Policy", value: FilenameSanitizer.inlineCSP) }
        headers.replaceOrAdd(name: .cacheControl, value: "private, no-store")
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }
    api.delete("files", ":id") { req async throws -> Response in
        try await service(req).delete(req.authContext, id: id(req)); return Response(status: .noContent)
    }

    api.get("absences", ":id", "attachments") { req async throws -> Response in
        try timeResponse(await service(req).attachments(req.authContext, absence: id(req)))
    }
    api.post("absences", ":id", "attachments") { req async throws -> Response in
        struct Input: Decodable { var fileId: UUID }
        let input = try timeDecode(Input.self, request: req)
        return try timeResponse(await service(req).attach(req.authContext, absence: id(req), file: input.fileId), status: .created)
    }
    api.delete("absences", ":id", "attachments", ":fileId") { req async throws -> Response in
        try await service(req).detach(req.authContext, absence: id(req), file: id(req, "fileId")); return Response(status: .noContent)
    }
}

/// Renders every error of the storage routes as `{ "error": { code, message } }` with German messages.
struct StorageErrorMiddleware: AsyncMiddleware {
    static let messages: [String: String] = [
        "file_too_large": "Die Datei ist zu groß.",
        "unsupported_type": "Dieser Dateityp wird nicht unterstützt. Erlaubt sind PDF, PNG, JPG, HEIC und TXT.",
        "storage_unavailable": "Der Dateispeicher ist derzeit nicht erreichbar oder nicht eingerichtet.",
        "not_implemented": "Diese Funktion ist auf diesem Server nicht eingerichtet.",
        "storage_corrupt": "Die gespeicherte Datei ist beschädigt.",
    ]
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do { return try await next.respond(to: request) }
        catch {
            struct Envelope: Encodable { struct Detail: Encodable { var code: String; var message: String }; var error: Detail }
            let failure: APIError
            if let known = error as? APIError { failure = known }
            else if error is DecodingError || error is TimeEngineError { failure = .invalid }
            else if let abort = error as? any AbortError {
                switch abort.status {
                case .payloadTooLarge: failure = StorageErrors.tooLarge
                case .unsupportedMediaType: failure = StorageErrors.unsupported
                case .notFound: failure = .missing
                default: failure = APIError(abort.status, "bad_request")
                }
            } else { throw error }
            let message = Self.messages[failure.code] ?? TimeMessages.german[failure.code] ?? "Die Anfrage konnte nicht verarbeitet werden."
            let response = try timeResponse(Envelope(error: .init(code: failure.code, message: message)), status: failure.status)
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return response
        }
    }
}
