import Foundation
import Fluent
import Vapor

/// Adds the no-store/noindex headers to every response of the public groups API (success and error alike). Registered as the
/// outermost middleware so it also covers responses that the error middlewares produce.
struct GroupPublicMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        if request.url.path.hasPrefix("/api/v1/public/") || request.url.path == "/g" || request.url.path.hasPrefix("/g/") {
            response.headers.replaceOrAdd(name: "X-Robots-Tag", value: "noindex, nofollow")
            response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
            if request.url.path.hasPrefix("/api/") { response.headers.replaceOrAdd(name: .cacheControl, value: "no-store") }
        }
        return response
    }
}

enum GroupTarget: Sendable {
    case poll(GroupPollRecord)
    case order(GroupOrderRecord)
}

/// Public side: the link token is the only credential. Lookups go through the SHA-256 hash (the database never compares the
/// secret itself), and unknown, rotated, deleted, wrong-type and disabled-owner links are indistinguishable (404).
struct PublicGroups: Sendable {
    let auth: AuthService

    private func ownerActive(_ accountId: UUID, on db: any Database) async throws -> Bool {
        guard let account = try await Account.find(accountId, on: db), account.disabledAt == nil else { return false }
        return try await auth.modules.enabled(.groups, account: accountId, on: db)
    }

    func resolve(_ token: String, on db: any Database) async throws -> GroupTarget? {
        guard GroupTokens.plausible(token) else { return nil }
        let hash = Secrets.hash(token)
        if let poll = try await GroupPollRecord.query(on: db).filter(\.$tokenHash == hash).first(), Secrets.equal(poll.tokenHash, hash),
           try await ownerActive(poll.accountId, on: db) { return .poll(poll) }
        if let order = try await GroupOrderRecord.query(on: db).filter(\.$tokenHash == hash).first(), Secrets.equal(order.tokenHash, hash),
           try await ownerActive(order.accountId, on: db) { return .order(order) }
        return nil
    }

    static func tooMany() -> Response {
        let response = Response(status: .tooManyRequests, headers: ["Content-Type": "application/json"],
                                body: .init(string: "{\"error\":{\"code\":\"too_many_requests\",\"message\":\"\(GroupMessages.german["too_many_requests"]!)\"}}"))
        response.headers.replaceOrAdd(name: .retryAfter, value: String(Int(GroupRateLimit.window)))
        return response
    }

    /// Reads: per-IP counters only (no serialization).
    func read(_ req: Request, token: String, _ operation: @escaping @Sendable (GroupTarget, any Database, Date) async throws -> Response) async throws -> Response {
        let now = Date(), client = req.clientRateLimitKey, db = req.db
        let missKey = "grp-miss:" + client
        guard try await !GroupRateLimit.exceeded(missKey, limit: GroupRateLimit.miss, now: now, on: db),
              try await GroupRateLimit.hit("grp-ip:" + client, limit: GroupRateLimit.ipRead, now: now, on: db) else { return Self.tooMany() }
        guard let target = try await resolve(token, on: db) else {
            try await GroupRateLimit.record(missKey, now: now, on: db)
            throw APIError.missing
        }
        return try await operation(target, db, now)
    }

    /// Writes: stricter per-IP and per-link counters, executed in the serialized authentication transaction so the size limits
    /// and the name check cannot be raced.
    func write(_ req: Request, token: String, _ operation: @escaping @Sendable (GroupTarget, any Database, Date) async throws -> Response) async throws -> Response {
        let now = Date(), client = req.clientRateLimitKey, db = req.db, auth = auth
        let missKey = "grp-miss:" + client
        do {
            return try await auth.transaction(on: db) { tx in
                guard try await !GroupRateLimit.exceeded(missKey, limit: GroupRateLimit.miss, now: now, on: tx),
                      try await GroupRateLimit.hit("grp-ip:" + client, limit: GroupRateLimit.ipRead, now: now, on: tx),
                      try await GroupRateLimit.hit("grp-write-ip:" + client, limit: GroupRateLimit.ipWrite, now: now, on: tx) else { return Self.tooMany() }
                guard let target = try await resolve(token, on: tx) else {
                    try await GroupRateLimit.record(missKey, now: now, on: tx)
                    return Response(status: .notFound, headers: ["X-Group-Miss": "1"])
                }
                let id: UUID
                switch target { case .poll(let poll): id = try poll.requireID(); case .order(let order): id = try order.requireID() }
                guard try await GroupRateLimit.hit("grp-write-tok:" + id.uuidString, limit: GroupRateLimit.tokenWrite, now: now, on: tx) else { return Self.tooMany() }
                return try await operation(target, tx, now)
            }.unmissed()
        } catch let error as APIError where error.code == "edit_secret_invalid" {
            // The failed transaction rolled back; guessing edit secrets still counts against the client.
            try? await GroupRateLimit.record(missKey, now: now, on: db)
            throw error
        }
    }
}

private extension Response {
    /// The marker is only used to turn a recorded miss (committed) into the regular 404 envelope outside the transaction.
    func unmissed() throws -> Response {
        if headers.first(name: "X-Group-Miss") != nil { throw APIError.missing }
        return self
    }
}

func registerGroupRoutes(_ app: Application, auth: AuthService) {
    registerGroupOwnerRoutes(app, auth: auth)
    registerGroupPublicRoutes(app, auth: auth)
}

private func registerGroupOwnerRoutes(_ app: Application, auth: AuthService) {
    let api = app.grouped("api", "v1", "groups").grouped(SessionMiddleware(service: auth))
    @Sendable func id(_ req: Request, _ name: String = "id") throws -> UUID {
        guard let id = req.parameters.get(name, as: UUID.self) else { throw APIError.missing }; return id
    }
    @Sendable func run(_ req: Request, _ operation: @escaping @Sendable (TimeServices) async throws -> Response) async throws -> Response {
        do { return try await TimeServices.session(req.authContext, auth: auth, db: req.db, operation: operation) }
        catch is TimeEngineError { throw APIError.invalid }
    }
    @Sendable func runRead(_ req: Request, _ operation: @escaping @Sendable (TimeServices) async throws -> Response) async throws -> Response {
        do { return try await TimeServices.read(req.authContext, auth: auth, db: req.db, operation: operation) }
        catch is TimeEngineError { throw APIError.invalid }
    }
    let bigBody: HTTPBodyStreamStrategy = .collect(maxSize: "128kb")

    // Polls
    api.get("polls") { req async throws -> Response in try await runRead(req) { try timeResponse(await $0.polls.list()) } }
    api.on(.POST, "polls", body: bigBody) { req async throws -> Response in
        let input = try timeDecode(PollInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.polls.create(input), status: .created) }
    }
    api.get("polls", ":id") { req async throws -> Response in
        let key = try id(req); return try await runRead(req) { try timeResponse(await $0.polls.get(key)) }
    }
    api.patch("polls", ":id") { req async throws -> Response in
        let key = try id(req), patch = try timeDecode(PollPatch.self, request: req)
        return try await run(req) { try timeResponse(await $0.polls.patch(key, patch)) }
    }
    api.delete("polls", ":id") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try await $0.polls.delete(key); return Response(status: .noContent) }
    }
    api.post("polls", ":id", "close") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try timeResponse(await $0.polls.close(key)) }
    }
    api.post("polls", ":id", "reopen") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try timeResponse(await $0.polls.reopen(key)) }
    }
    api.post("polls", ":id", "final") { req async throws -> Response in
        let key = try id(req), input = try timeDecode(PollFinalInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.polls.setFinal(key, optionId: input.optionId)) }
    }
    api.post("polls", ":id", "rotate-token") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try timeResponse(await $0.polls.rotate(key)) }
    }
    api.delete("polls", ":id", "votes", ":voteId") { req async throws -> Response in
        let key = try id(req), vote = try id(req, "voteId")
        return try await run(req) { try await $0.polls.removeVote(key, voteId: vote); return Response(status: .noContent) }
    }

    // Order rounds
    api.get("orders") { req async throws -> Response in try await runRead(req) { try timeResponse(await $0.orders.list()) } }
    api.post("orders") { req async throws -> Response in
        let input = try timeDecode(OrderInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.orders.create(input), status: .created) }
    }
    api.get("orders", "suggestions") { req async throws -> Response in try await runRead(req) { try timeResponse(await $0.orders.itemSuggestions()) } }
    api.get("orders", ":id") { req async throws -> Response in
        let key = try id(req); return try await runRead(req) { try timeResponse(await $0.orders.get(key)) }
    }
    api.patch("orders", ":id") { req async throws -> Response in
        let key = try id(req), patch = try timeDecode(OrderPatch.self, request: req)
        return try await run(req) { try timeResponse(await $0.orders.patch(key, patch)) }
    }
    api.delete("orders", ":id") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try await $0.orders.delete(key); return Response(status: .noContent) }
    }
    api.post("orders", ":id", "close") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try timeResponse(await $0.orders.close(key)) }
    }
    api.post("orders", ":id", "reopen") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try timeResponse(await $0.orders.reopen(key)) }
    }
    api.post("orders", ":id", "rotate-token") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try timeResponse(await $0.orders.rotate(key)) }
    }
    api.delete("orders", ":id", "entries", ":entryId") { req async throws -> Response in
        let key = try id(req), entry = try id(req, "entryId")
        return try await run(req) { try await $0.orders.removeEntry(key, entryId: entry); return Response(status: .noContent) }
    }
    api.get("orders", ":id", "export") { req async throws -> Response in
        let key = try id(req), format: String = (try? req.query.get(String.self, at: "format")) ?? "csv"
        return try await runRead(req) { try await $0.orders.export(key, format: format) }
    }

    // Catalogs
    api.get("catalogs") { req async throws -> Response in try await runRead(req) { try timeResponse(await $0.catalogs.list()) } }
    api.on(.POST, "catalogs", body: bigBody) { req async throws -> Response in
        let input = try timeDecode(CatalogInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.catalogs.create(input), status: .created) }
    }
    api.get("catalogs", ":id") { req async throws -> Response in
        let key = try id(req); return try await runRead(req) { try timeResponse(await $0.catalogs.get(key)) }
    }
    api.on(.PUT, "catalogs", ":id", body: bigBody) { req async throws -> Response in
        let key = try id(req), input = try timeDecode(CatalogInput.self, request: req)
        return try await run(req) { try timeResponse(await $0.catalogs.replace(key, input)) }
    }
    api.delete("catalogs", ":id") { req async throws -> Response in
        let key = try id(req); return try await run(req) { try await $0.catalogs.delete(key); return Response(status: .noContent) }
    }
}

private func registerGroupPublicRoutes(_ app: Application, auth: AuthService) {
    let pub = app.grouped("api", "v1", "public", "groups")
    let gateway = PublicGroups(auth: auth)
    @Sendable func parameter(_ req: Request, _ name: String) throws -> UUID {
        guard let id = req.parameters.get(name, as: UUID.self) else { throw APIError.missing }; return id
    }
    @Sendable func secret(_ req: Request) -> String? { req.headers.first(name: "X-Edit-Secret") }
    @Sendable func poll(_ target: GroupTarget) throws -> GroupPollRecord {
        guard case .poll(let poll) = target else { throw APIError.missing }; return poll
    }
    @Sendable func order(_ target: GroupTarget) throws -> GroupOrderRecord {
        guard case .order(let order) = target else { throw APIError.missing }; return order
    }

    pub.get(":token") { req async throws -> Response in
        try await gateway.read(req, token: req.parameters.get("token") ?? "") { target, db, now in
            switch target {
            case .poll(let row): return try timeResponse(PublicGroupDTO(type: "poll", poll: try await PollCore.dto(row, on: db, now: now, owner: false), order: nil))
            case .order(let row): return try timeResponse(PublicGroupDTO(type: "order", poll: nil, order: try await OrderCore.dto(row, on: db, now: now, owner: false)))
            }
        }
    }
    pub.get(":token", "export") { req async throws -> Response in
        let format: String = (try? req.query.get(String.self, at: "format")) ?? "csv"
        return try await gateway.read(req, token: req.parameters.get("token") ?? "") { target, db, now in
            try OrderCore.exportResponse(try await OrderCore.dto(try order(target), on: db, now: now, owner: false), format: format)
        }
    }

    // Poll votes
    pub.post(":token", "votes") { req async throws -> Response in
        let input = try timeDecode(VoteInput.self, request: req)
        return try await gateway.write(req, token: req.parameters.get("token") ?? "") { target, db, now in
            try timeResponse(try await PollCore.castVote(input, poll: try poll(target), now: now, on: db), status: .created)
        }
    }
    pub.put(":token", "votes", ":voteId") { req async throws -> Response in
        let input = try timeDecode(VoteInput.self, request: req), voteId = try parameter(req, "voteId"), key = secret(req)
        return try await gateway.write(req, token: req.parameters.get("token") ?? "") { target, db, now in
            let row = try poll(target)
            let vote = try await PollCore.ownVote(voteId, poll: row, secret: key, on: db)
            return try timeResponse(try await PollCore.updateVote(vote, input: input, poll: row, now: now, on: db))
        }
    }
    pub.delete(":token", "votes", ":voteId") { req async throws -> Response in
        let voteId = try parameter(req, "voteId"), key = secret(req)
        return try await gateway.write(req, token: req.parameters.get("token") ?? "") { target, db, now in
            let row = try poll(target)
            let vote = try await PollCore.ownVote(voteId, poll: row, secret: key, on: db)
            guard !row.isClosed(now) else { throw GroupError.closed }
            try await PollCore.removeVote(vote.requireID(), on: db)
            return Response(status: .noContent)
        }
    }

    // Order entries
    pub.post(":token", "entries") { req async throws -> Response in
        let input = try timeDecode(EntryInput.self, request: req)
        return try await gateway.write(req, token: req.parameters.get("token") ?? "") { target, db, now in
            try timeResponse(try await OrderCore.addEntry(input, order: try order(target), now: now, on: db), status: .created)
        }
    }
    pub.put(":token", "entries", ":entryId") { req async throws -> Response in
        let input = try timeDecode(EntryInput.self, request: req), entryId = try parameter(req, "entryId"), key = secret(req)
        return try await gateway.write(req, token: req.parameters.get("token") ?? "") { target, db, now in
            let row = try order(target)
            let entry = try await OrderCore.ownEntry(entryId, order: row, secret: key, on: db)
            return try timeResponse(try await OrderCore.updateEntry(entry, input: input, order: row, now: now, on: db))
        }
    }
    pub.delete(":token", "entries", ":entryId") { req async throws -> Response in
        let entryId = try parameter(req, "entryId"), key = secret(req)
        return try await gateway.write(req, token: req.parameters.get("token") ?? "") { target, db, now in
            let row = try order(target)
            let entry = try await OrderCore.ownEntry(entryId, order: row, secret: key, on: db)
            guard !row.isClosed(now) else { throw GroupError.closed }
            try await GroupOrderEntryRecord.query(on: db).filter(\._$id == entry.requireID()).delete()
            return Response(status: .noContent)
        }
    }
    pub.post(":token", "entries", ":entryId", "take") { req async throws -> Response in
        let input = try timeDecode(EntryTakeInput.self, request: req), entryId = try parameter(req, "entryId")
        return try await gateway.write(req, token: req.parameters.get("token") ?? "") { target, db, now in
            try timeResponse(try await OrderCore.takeEntry(entryId, input: input, order: try order(target), now: now, on: db), status: .created)
        }
    }
}
