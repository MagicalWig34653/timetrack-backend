import Vapor

/// Entry point owned by package C11 (export). Registered from `registerRoutes`.
func registerExportRoutes(_ app: Application, auth: AuthService) {
    let api = app.grouped("api", "v1").grouped(SessionMiddleware(service: auth))
    api.get("export", "time") { req async throws -> Response in
        guard let fromText: String = req.query["from"], let toText: String = req.query["to"],
              let formatText: String = req.query["format"],
              formatText == "worktime-xlsx" || ExportFileFormat(rawValue: formatText) != nil,
              let from = try? LocalDate(fromText), let to = try? LocalDate(toText) else { throw APIError.invalid }
        try LocalDate.checkedRange(from: from, to: to, maxDays: ExportLimits.maxDays)
        let worktime = formatText == "worktime-xlsx"
        let format = ExportFileFormat(rawValue: formatText) ?? .xlsx
        let options = try WorktimeExportOptions(times: worktime ? req.query["times"] : nil,
            pauseMinutes: worktime ? req.query["pauseMinutes"] : nil,
            standardStart: worktime ? req.query["standardStart"] : nil, dateSystem: worktime ? req.query["dateSystem"] : nil)
        let data: Data
        do {
            data = try await TimeServices.session(req.authContext, auth: auth, db: req.db) { scope in
                if worktime {
                    let document = try await WorktimeExportService(scope: scope).document(from: from, to: to, options: options)
                    return try FormulaXLSXWriter.write(document)
                }
                let document = try await ExportService(scope: scope).document(from: from, to: to)
                return try ExportService.render(document, as: format)
            }
        } catch is TimeEngineError { throw APIError.invalid }
        let name = worktime ? "zeitnachweis_\(from)_\(to)_tabelle.xlsx" : ExportService.fileName(from: from, to: to, format: format)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: format.contentType)
        headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=\"\(name)\"; filename*=UTF-8''\(name)")
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }
}
