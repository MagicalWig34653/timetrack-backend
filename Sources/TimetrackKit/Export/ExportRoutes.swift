import Vapor

/// Entry point owned by package C11 (export). Registered from `registerRoutes`.
func registerExportRoutes(_ app: Application, auth: AuthService) {
    let api = app.grouped("api", "v1").grouped(SessionMiddleware(service: auth))
    api.get("export", "time") { req async throws -> Response in
        guard let fromText: String = req.query["from"], let toText: String = req.query["to"],
              let formatText: String = req.query["format"], let format = ExportFileFormat(rawValue: formatText),
              let from = try? LocalDate(fromText), let to = try? LocalDate(toText) else { throw APIError.invalid }
        try LocalDate.checkedRange(from: from, to: to, maxDays: ExportLimits.maxDays)
        let data: Data
        do {
            data = try await TimeServices.session(req.authContext, auth: auth, db: req.db) { scope in
                let document = try await ExportService(scope: scope).document(from: from, to: to)
                return try ExportService.render(document, as: format)
            }
        } catch is TimeEngineError { throw APIError.invalid }
        let name = ExportService.fileName(from: from, to: to, format: format)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: format.contentType)
        headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=\"\(name)\"; filename*=UTF-8''\(name)")
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }
}
