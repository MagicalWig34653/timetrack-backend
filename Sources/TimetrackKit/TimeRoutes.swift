import Vapor
import Fluent

func registerTimeRoutes(_ app: Application, auth: AuthService) {
    let api = app.grouped("api", "v1").grouped(SessionMiddleware(service: auth))
    @Sendable func id(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw APIError.missing }; return id
    }
    @Sendable func date(_ req: Request) throws -> LocalDate { try LocalDate(req.parameters.get("date") ?? "") }
    @Sendable func run(_ req: Request, _ operation: @escaping @Sendable (TimeServices) async throws -> Response) async throws -> Response {
        do { return try await TimeServices.session(req.authContext, auth: auth, db: req.db, operation: operation) }
        catch is TimeEngineError { throw APIError.invalid }
    }
    @Sendable func runRead(_ req: Request, _ operation: @escaping @Sendable (TimeServices) async throws -> Response) async throws -> Response {
        do { return try await TimeServices.read(req.authContext, auth: auth, db: req.db, operation: operation) }
        catch is TimeEngineError { throw APIError.invalid }
    }
    api.get("work-models") { req async throws -> Response in try await runRead(req) { try timeResponse(await $0.models.list()) } }
    api.post("work-models") { req async throws -> Response in
        let input = try timeDecode(WorkModelDTO.self, request: req)
        return try await run(req) { try timeResponse(await $0.models.create(input), status: .created) }
    }
    api.get("work-models", ":id") { req async throws -> Response in
        let key = try id(req); return try await runRead(req) { try timeResponse(await $0.models.record(key).versioned) }
    }
    api.patch("work-models", ":id") { req async throws -> Response in
        struct Input: Decodable { var validTo: LocalDate }
        let key = try id(req); let input = try timeDecode(Input.self, request: req)
        return try await run(req) { try timeResponse(await $0.models.end(key, at: input.validTo)) }
    }
    api.put("work-models", ":id") { req async throws -> Response in
        let key = try id(req); let input = try timeDecode(WorkModelDTO.self, request: req)
        let version = req.headers.first(name: .ifMatch).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }
        return try await run(req) { try timeResponse(await $0.models.update(key, input: input, version: version)) }
    }
    api.post("work-models", ":id", "preview") { req async throws -> Response in
        let key = try id(req); let input = try timeDecode(WorkModelDTO.self, request: req)
        return try await runRead(req) { try timeResponse(await $0.models.preview(key, input: input)) }
    }
    api.get("places") { req async throws -> Response in try await runRead(req) { try timeResponse(await $0.places.list()) } }
    api.post("places") { req async throws -> Response in
        let input = try timeDecode(PlaceDTO.self, request: req)
        return try await run(req) { try timeResponse(await $0.places.save(input), status: .created) }
    }
    api.put("places", ":id") { req async throws -> Response in
        let key = try id(req); let input = try timeDecode(PlaceDTO.self, request: req)
        return try await run(req) { try timeResponse(await $0.places.save(input, id: key)) }
    }
    api.delete("places", ":id") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try await $0.places.archive(key); return Response(status: .noContent) }
    }
    api.get("time", "segments") { req async throws -> Response in
        guard let fromText: String = req.query["from"], let toText: String = req.query["to"],
              let from = timeInstant(fromText), let to = timeInstant(toText), from < to else { throw APIError.invalid }
        let voided = (try? req.query.get(Bool.self, at: "includeVoided")) ?? false
        return try await runRead(req) { scope in
            try timeResponse(await scope.segments.list(from: from, to: to, includeVoided: voided))
        }
    }
    api.post("time", "segments") { req async throws -> Response in
        let input = try timeDecode(SegmentInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.segments.create(input), status: .created) }
    }
    api.get("time", "segments", ":id") { req async throws -> Response in
        let key = try id(req); return try await runRead(req) { try timeResponse(await $0.segments.record(key).dto()) }
    }
    api.patch("time", "segments", ":id") { req async throws -> Response in
        let key = try id(req); let input = try timeDecode(SegmentCorrection.self, request: req)
        let version = req.headers.first(name: .ifMatch).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }
        return try await run(req) { try timeResponse(await $0.segments.correct(key, input: input, version: version)) }
    }
    api.delete("time", "segments", ":id") { req async throws -> Response in
        let key = try id(req); let reason: String = req.query["reason"] ?? ""
        return try await run(req) { try await $0.segments.void(key, reason: reason); return Response(status: .noContent) }
    }
    api.get("time", "timer") { req async throws -> Response in try await runRead(req) { try timeResponse(await $0.timer.current()?.dto()) } }
    for action in ["start", "stop"] {
        api.post("time", "timer", .constant(action)) { req async throws -> Response in
            let input = try timeDecode(TimerInput.self, request: req)
            return try await run(req) { try timeResponse(await $0.timer.act(input, action: action)) }
        }
    }
    api.get("time", "days") { req async throws -> Response in
        let from = try LocalDate(req.query[String.self, at: "from"] ?? ""); let to = try LocalDate(req.query[String.self, at: "to"] ?? "")
        return try await runRead(req) { try timeResponse(await $0.days.range(from: from, to: to)) }
    }
    api.get("time", "days", ":date") { req async throws -> Response in
        let day = try date(req); return try await runRead(req) { try timeResponse(await $0.days.evaluate(day)) }
    }
    api.put("time", "days", ":date") { req async throws -> Response in
        let day = try date(req); let input = try timeDecode(DayInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.days.set(day, input: input)) }
    }
    api.get("time", "account") { req async throws -> Response in
        let asOf = try req.query[String.self, at: "asOf"].map(LocalDate.init)
        return try await runRead(req) { try timeResponse(await $0.account.balance(asOf: asOf)) }
    }
    api.post("time", "account", "adjustments") { req async throws -> Response in
        let input = try timeDecode(AdjustmentInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.account.adjust(input), status: .created) }
    }
    api.get("time", "suggestions") { req async throws -> Response in try await run(req) { try timeResponse(await $0.suggestions.list()) } }
    api.post("time", "suggestions", ":id", "accept") { req async throws -> Response in
        let key = try id(req)
        let input = req.body.data.map { $0.readableBytes > 0 } == true ? try timeDecode(SuggestionAccept.self, request: req) : SuggestionAccept()
        return try await run(req) { try timeResponse(await $0.suggestions.accept(key, input: input)) }
    }
    api.post("time", "suggestions", ":id", "reject") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try await $0.suggestions.reject(key); return Response(status: .noContent) }
    }
    api.get("me", "device-tokens") { req async throws -> Response in try await runRead(req) { try timeResponse(await $0.devices.list()) } }
    api.post("me", "device-tokens") { req async throws -> Response in
        let input = try timeDecode(DeviceTokenInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.devices.create(input), status: .created) }
    }
    api.delete("me", "device-tokens", ":id") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try await $0.devices.revoke(key); return Response(status: .noContent) }
    }
    app.grouped("api", "v1").grouped(DeviceTokenMiddleware(auth: auth)).post("automation", "events") { req async throws -> Response in
        let input = try timeDecode(AutomationInput.self, request: req)
        guard let token = req.storage[DeviceContextKey.self] else { throw APIError.unauthorized }
        return try await auth.transaction(on: req.db) { tx in
            let device = try await DeviceTokenService.authenticate(token, db: tx, disabledModules: auth.configuration.disabledModules)
            return try timeResponse(await TimeServices(accountId: device.accountId, db: tx, disabledModules: auth.configuration.disabledModules).automation.process(input))
        }
    }
}
