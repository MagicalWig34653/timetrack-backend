import Vapor
import Fluent

func registerPlanningRoutes(_ app: Application, auth: AuthService) {
    let api = app.grouped("api", "v1").grouped(SessionMiddleware(service: auth))
    @Sendable func id(_ req: Request, _ name: String = "id") throws -> UUID {
        guard let id = req.parameters.get(name, as: UUID.self) else { throw APIError.missing }; return id
    }
    @Sendable func date(_ req: Request) throws -> LocalDate { try LocalDate(req.parameters.get("date") ?? "") }
    @Sendable func query(_ req: Request, _ name: String) throws -> LocalDate { try LocalDate(req.query[String.self, at: name] ?? "") }
    @Sendable func year(_ req: Request) throws -> Int {
        guard let year = try? req.query.get(Int.self, at: "year") else { throw APIError.invalid }; return year
    }
    @Sendable func run(_ req: Request, _ operation: @escaping @Sendable (TimeServices) async throws -> Response) async throws -> Response {
        try await TimeServices.session(req.authContext, auth: auth, db: req.db, operation: operation)
    }
    @Sendable func empty(_ work: @escaping @Sendable () async throws -> Void) async throws -> Response {
        try await work(); return Response(status: .noContent)
    }

    api.get("vacation", "settings") { req async throws -> Response in try await run(req) { try timeResponse(await $0.vacation.settings()) } }
    api.put("vacation", "settings") { req async throws -> Response in
        let input = try timeDecode(VacationSettingsDTO.self, request: req)
        return try await run(req) { try timeResponse(await $0.vacation.save(input)) }
    }
    api.post("vacation", "snapshots") { req async throws -> Response in
        let input = try timeDecode(SnapshotInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.vacation.createSnapshot(input), status: .created) }
    }
    api.post("vacation", "adjustments") { req async throws -> Response in
        let input = try timeDecode(VacationAdjustmentInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.vacation.createAdjustment(input), status: .created) }
    }
    api.get("vacation", "balance") { req async throws -> Response in
        let value = try year(req); return try await run(req) { try timeResponse(await $0.vacation.balance(year: value)) }
    }
    api.get("vacation", "entries") { req async throws -> Response in
        let value = try year(req); return try await run(req) { try timeResponse(await $0.vacation.entries(year: value)) }
    }
    api.delete("vacation", "entries", ":id") { req async throws -> Response in
        let key = try id(req); return try await run(req) { scope in try await empty { try await scope.vacation.deleteEntry(key) } }
    }

    api.get("absences") { req async throws -> Response in
        let from = try query(req, "from"), to = try query(req, "to")
        return try await run(req) { try timeResponse(await $0.absences.list(from: from, to: to)) }
    }
    api.post("absences") { req async throws -> Response in
        let input = try timeDecode(AbsenceInputDTO.self, request: req)
        return try await run(req) { try timeResponse(await $0.absences.create(input), status: .created) }
    }
    api.get("absences", ":id") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try timeResponse(await $0.absences.get(key)) }
    }
    api.put("absences", ":id") { req async throws -> Response in
        let key = try id(req); let input = try timeDecode(AbsenceInputDTO.self, request: req)
        guard let header = req.headers.first(name: .ifMatch) else { throw APIError.invalid }   // required by the contract
        var token = header.trimmingCharacters(in: .whitespaces)
        if token.hasPrefix("W/") { token.removeFirst(2) }
        let version = Int(token.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        return try await run(req) { try timeResponse(await $0.absences.update(key, input, version: version)) }
    }
    api.delete("absences", ":id") { req async throws -> Response in
        let key = try id(req); return try await run(req) { scope in try await empty { try await scope.absences.delete(key) } }
    }

    api.get("calendar", "holidays") { req async throws -> Response in
        let value = try year(req); let region: String? = req.query["region"]
        return try await run(req) { try timeResponse(await $0.calendar.holidays(year: value, region: region)) }
    }
    api.post("calendar", "custom-days") { req async throws -> Response in
        let input = try timeDecode(CustomDayInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.calendar.createCustom(input), status: .created) }
    }
    api.delete("calendar", "custom-days", ":id") { req async throws -> Response in
        let key = try id(req); return try await run(req) { scope in try await empty { try await scope.calendar.deleteCustom(key) } }
    }

    api.get("plan", "days") { req async throws -> Response in
        let from = try query(req, "from"), to = try query(req, "to")
        return try await run(req) { try timeResponse(await $0.plans.list(from: from, to: to)) }
    }
    api.put("plan", "days", ":date") { req async throws -> Response in
        let day = try date(req); let input = try timeDecode(PlanDayInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.plans.put(day, input)) }
    }
    api.delete("plan", "days", ":date") { req async throws -> Response in
        let day = try date(req); return try await run(req) { scope in try await empty { try await scope.plans.delete(day) } }
    }

    // "incoming" is a constant path segment and takes precedence over the :id routes below.
    api.get("shares", "incoming") { req async throws -> Response in try await run(req) { try timeResponse(await $0.shares.incoming()) } }
    api.get("shares", "incoming", ":shareId", "view") { req async throws -> Response in
        let key = try id(req, "shareId"); let from = try query(req, "from"), to = try query(req, "to")
        return try await run(req) { try timeResponse(await $0.shares.view(key, from: from, to: to)) }
    }
    api.get("shares") { req async throws -> Response in try await run(req) { try timeResponse(await $0.shares.list()) } }
    api.post("shares") { req async throws -> Response in
        let input = try timeDecode(ShareCreateInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.shares.create(input), status: .created) }
    }
    api.patch("shares", ":id") { req async throws -> Response in
        let key = try id(req); let input = try timeDecode(ShareUpdateInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.shares.update(key, scopes: input.scopes)) }
    }
    api.delete("shares", ":id") { req async throws -> Response in
        let key = try id(req); return try await run(req) { scope in try await empty { try await scope.shares.revoke(key) } }
    }
}
