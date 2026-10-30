import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

/// G1: groups module (public polls, group orders, catalogs). ADR-0033.
extension AuthTests {
    // MARK: Helpers

    /// Runs on SQLite by default. With `G1_ON_MARIADB=1` and the usual `MARIADB_TEST_*` variables the same scenarios run on MariaDB.
    func gWithApp(environment: [String: String] = [:], _ run: (Application, AuthService) async throws -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        var merged = environment
        if env["G1_ON_MARIADB"] == "1" {
            guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
            for (key, value) in ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
                                 "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
                                 "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test_g1", "DB_TLS": "off", "STORAGE_SECRET_KEY": AuthTests.testKey] {
                merged[key] = merged[key] ?? value
            }
        }
        try await withApp(environment: merged, run)
    }

    @discardableResult
    func gPublic(_ app: Application, _ method: HTTPMethod, _ token: String, _ suffix: String = "", _ body: [String: Any]? = nil,
                 secret: String? = nil, _ status: HTTPStatus = .ok, file: StaticString = #filePath, line: UInt = #line) async throws -> XCTHTTPResponse {
        var head: HTTPHeaders = [:]
        if let secret { head.add(name: "X-Edit-Secret", value: secret) }
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        if data != nil { head.contentType = .json }
        let response = try await app.testable().sendRequest(method, "/api/v1/public/groups/" + token + suffix, headers: head, body: data.map(ByteBuffer.init(data:)))
        XCTAssertEqual(response.status, status, response.body.string, file: file, line: line)
        return response
    }

    func gView(_ app: Application, _ token: String, _ key: String) async throws -> [String: Any] {
        let wrapper = try object(await gPublic(app, .GET, token))
        return try XCTUnwrap(wrapper[key] as? [String: Any])
    }
    func gList(_ app: Application, _ context: AuthContext, _ path: String) async throws -> [[String: Any]] {
        try list(await api(app, context, .GET, path))
    }

    func gArray(_ value: Any?) -> [[String: Any]] { (value as? [[String: Any]]) ?? [] }

    func gTextPoll(_ app: Application, _ owner: AuthContext, mode: String = "single", extra: [String: Any] = [:]) async throws -> (id: String, token: String, options: [String]) {
        let body: [String: Any] = ["title": "Pizza oder Döner?", "kind": "text", "choiceMode": mode, "options": [["label": "Pizza"], ["label": "Döner"], ["label": "Sushi"]]]
            .merging(extra) { _, new in new }
        let created = try object(await api(app, owner, .POST, "groups/polls", body, .created))
        return (try XCTUnwrap(created["id"] as? String), try XCTUnwrap(created["token"] as? String), gArray(created["options"]).compactMap { $0["id"] as? String })
    }

    func gDatePoll(_ app: Application, _ owner: AuthContext, mode: String = "multi", extra: [String: Any] = [:]) async throws -> (id: String, token: String, options: [String]) {
        let body: [String: Any] = ["title": "Teamtreffen", "description": "Wann passt es?", "kind": "date", "choiceMode": mode, "timeZone": "Europe/Berlin",
                                   "options": [["date": "2027-03-01", "startTime": "18:00", "endTime": "20:00"], ["date": "2027-03-02"], ["date": "2027-03-03", "startTime": "09:30"]]]
            .merging(extra) { _, new in new }
        let created = try object(await api(app, owner, .POST, "groups/polls", body, .created))
        return (try XCTUnwrap(created["id"] as? String), try XCTUnwrap(created["token"] as? String), gArray(created["options"]).compactMap { $0["id"] as? String })
    }

    func gOrder(_ app: Application, _ owner: AuthContext, extra: [String: Any] = [:]) async throws -> (id: String, token: String) {
        let created = try object(await api(app, owner, .POST, "groups/orders", ["title": "Dönerstag"].merging(extra) { _, new in new }, .created))
        return (try XCTUnwrap(created["id"] as? String), try XCTUnwrap(created["token"] as? String))
    }

    func gVote(_ app: Application, _ token: String, _ name: String, _ answers: [[String: String]], _ status: HTTPStatus = .created) async throws -> [String: Any] {
        try object(await gPublic(app, .POST, token, "/votes", ["name": name, "answers": answers], status))
    }

    func gSetClosedAt(_ app: Application, poll id: String, daysAgo: Double, deadline: Bool = false) async throws {
        let row = try await XCTUnwrapAsync(try await GroupPollRecord.find(UUID(uuidString: id), on: app.db))
        let date = Date().addingTimeInterval(-daysAgo * 86_400)
        if deadline { row.deadline = date } else { row.closedAt = date }
        try await row.update(on: app.db)
    }

    // MARK: Poll lifecycle, tokens, edit secrets

    func testG1PollLifecycleAndPrivacy() async throws {
        try await gWithApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let created = try object(await api(app, owner, .POST, "groups/polls",
                ["title": "Pizza oder Döner?", "description": "Abstimmung", "kind": "text", "choiceMode": "single",
                 "options": [["label": "Pizza"], ["label": "Döner"]]], .created))
            let token = try XCTUnwrap(created["token"] as? String), id = try XCTUnwrap(created["id"] as? String)
            XCTAssertEqual(token.count, 43)
            XCTAssertEqual(created["path"] as? String, "/g/" + token)
            // The token is stored only as a hash and is never shown again.
            let row = try await XCTUnwrapAsync(try await GroupPollRecord.find(UUID(uuidString: id), on: app.db))
            XCTAssertEqual(row.tokenHash, Secrets.hash(token)); XCTAssertNotEqual(row.tokenHash, token)
            let again = try object(await api(app, owner, .GET, "groups/polls/" + id))
            XCTAssertNil(again["token"]); XCTAssertNil(again["path"])
            let listed = try await api(app, owner, .GET, "groups/polls")
            XCTAssertFalse(listed.body.string.contains(token))
            // Public view without any login.
            let view = try await gPublic(app, .GET, token)
            XCTAssertEqual(view.headers.first(name: "X-Robots-Tag"), "noindex, nofollow")
            XCTAssertEqual(view.headers.first(name: .cacheControl), "no-store")
            XCTAssertEqual(view.headers.first(name: "Referrer-Policy"), "no-referrer")
            let wrapper = try object(view), poll = try XCTUnwrap(wrapper["poll"] as? [String: Any])
            XCTAssertEqual(wrapper["type"] as? String, "poll"); XCTAssertEqual(poll["title"] as? String, "Pizza oder Döner?")
            // No account data and no owner-side identifiers leak.
            let text = view.body.string
            XCTAssertNil(poll["id"]); XCTAssertNil(poll["createdAt"])
            for forbidden in ["accountId", "handle", "admin", "email", "displayName", "tokenHash", "secretHash"] { XCTAssertFalse(text.contains(forbidden), forbidden) }
            let options = gArray(poll["options"]).compactMap { $0["id"] as? String }
            // Vote, view own name, edit with the secret.
            let vote = try await gVote(app, token, "Anna", [["optionId": options[0], "answer": "yes"]])
            let editSecret = try XCTUnwrap(vote["editSecret"] as? String)
            let voteId = try XCTUnwrap((vote["vote"] as? [String: Any])?["id"] as? String)
            let stored = try await XCTUnwrapAsync(try await GroupPollVoteRecord.find(UUID(uuidString: voteId), on: app.db))
            XCTAssertEqual(stored.secretHash, Secrets.hash(editSecret)); XCTAssertNotEqual(stored.secretHash, editSecret)
            var publicPoll = try await gView(app, token, "poll")
            XCTAssertEqual(gArray(publicPoll["votes"]).map { $0["name"] as? String }, ["Anna"])
            XCTAssertFalse(String(data: try JSONSerialization.data(withJSONObject: publicPoll["votes"] as Any), encoding: .utf8)!.contains("secret"))
            // Wrong, missing and foreign secrets cannot edit or delete.
            let change: [String: Any] = ["name": "Anna", "answers": [["optionId": options[1], "answer": "yes"]]]
            let wrong = try await gPublic(app, .PUT, token, "/votes/" + voteId, change, secret: "nope", .forbidden)
            XCTAssertEqual(try errorCode(wrong), "edit_secret_invalid")
            try await gPublic(app, .PUT, token, "/votes/" + voteId, change, secret: nil, .forbidden)
            try await gPublic(app, .DELETE, token, "/votes/" + voteId, nil, secret: Secrets.token(), .forbidden)
            try await gPublic(app, .PUT, token, "/votes/" + UUID().uuidString, change, secret: editSecret, .notFound)
            try await gPublic(app, .PUT, token, "/votes/" + voteId, change, secret: editSecret)
            publicPoll = try await gView(app, token, "poll")
            let tally = gArray(publicPoll["tally"])
            XCTAssertEqual(tally.first { $0["optionId"] as? String == options[1] }?["yes"] as? Int, 1)
            XCTAssertEqual(tally.first { $0["optionId"] as? String == options[0] }?["yes"] as? Int, 0)
            // Delete own vote.
            try await gPublic(app, .DELETE, token, "/votes/" + voteId, nil, secret: editSecret, .noContent)
            try await eq(try await GroupPollVoteRecord.query(on: app.db).count(), 0)
            try await eq(try await GroupPollAnswerRecord.query(on: app.db).count(), 0)
        }
    }

    func testG1UnknownMalformedAndWrongTypeTokens() async throws {
        try await gWithApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let order = try await gOrder(app, owner)
            let poll = try await gTextPoll(app, owner)
            for token in ["short", String(repeating: "A", count: 43), String(repeating: "A", count: 44), "../" + String(repeating: "B", count: 40), poll.token.lowercased()] {
                let response = try await gPublic(app, .GET, token, "", nil, secret: nil, .notFound)
                XCTAssertEqual(try errorCode(response), "not_found")
            }
            // An order token is not a poll and vice versa.
            try await gPublic(app, .POST, order.token, "/votes", ["name": "X", "answers": []], secret: nil, .notFound)
            try await gPublic(app, .POST, poll.token, "/entries", ["name": "X", "item": "Y"], secret: nil, .notFound)
            try await gPublic(app, .GET, poll.token, "/export?format=csv", nil, secret: nil, .notFound)
        }
    }

    func testG1VotingRules() async throws {
        try await gWithApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let single = try await gTextPoll(app, owner, mode: "single")
            let multi = try await gTextPoll(app, owner, mode: "multi")
            let dates = try await gDatePoll(app, owner)
            let dateSingle = try await gDatePoll(app, owner, mode: "single")
            func invalid(_ token: String, _ answers: [[String: String]], name: String = "Bob") async throws {
                let response = try await gPublic(app, .POST, token, "/votes", ["name": name, "answers": answers], secret: nil, .badRequest)
                XCTAssertEqual(try errorCode(response), "answers_invalid")
            }
            // Single choice: exactly one yes.
            try await invalid(single.token, [])
            try await invalid(single.token, [["optionId": single.options[0], "answer": "yes"], ["optionId": single.options[1], "answer": "yes"]])
            try await invalid(single.token, [["optionId": single.options[0], "answer": "maybe"]])
            try await invalid(single.token, [["optionId": single.options[0], "answer": "no"]])
            // Unknown option, duplicate option, unknown answer word.
            try await invalid(multi.token, [["optionId": UUID().uuidString, "answer": "yes"]])
            try await invalid(multi.token, [["optionId": multi.options[0], "answer": "yes"], ["optionId": multi.options[0], "answer": "yes"]])
            try await invalid(multi.token, [["optionId": multi.options[0], "answer": "perhaps"]])
            // An option of another poll is rejected.
            try await invalid(multi.token, [["optionId": single.options[0], "answer": "yes"]])
            // Text multi needs at least one yes, never maybe.
            try await invalid(multi.token, [])
            try await invalid(multi.token, [["optionId": multi.options[0], "answer": "maybe"]])
            _ = try await gVote(app, multi.token, "Cleo", [["optionId": multi.options[0], "answer": "yes"], ["optionId": multi.options[2], "answer": "yes"]])
            // Date polls: yes/maybe/no; multi may be empty, single needs one yes.
            let answers = [["optionId": dates.options[0], "answer": "yes"], ["optionId": dates.options[1], "answer": "maybe"], ["optionId": dates.options[2], "answer": "no"]]
            _ = try await gVote(app, dates.token, "Dora", answers)
            _ = try await gVote(app, dates.token, "Emil", [])
            try await invalid(dateSingle.token, [["optionId": dateSingle.options[0], "answer": "maybe"]])
            _ = try await gVote(app, dateSingle.token, "Fritz", [["optionId": dateSingle.options[1], "answer": "yes"]])
            let view = try await gView(app, dates.token, "poll")
            let tally = gArray(view["tally"])
            XCTAssertEqual(tally.map { [$0["yes"] as? Int, $0["maybe"] as? Int, $0["no"] as? Int] }, [[1, 0, 1], [0, 1, 1], [0, 0, 2]])
            XCTAssertEqual(view["voteCount"] as? Int, 2)
            // Names: unique per poll ignoring case and spacing, trimmed, limited.
            let a = [["optionId": single.options[0], "answer": "yes"]]
            _ = try await gVote(app, single.token, "  Anna  Maria ", a)
            let duplicate = try await gPublic(app, .POST, single.token, "/votes", ["name": "anna maria", "answers": a], secret: nil, .conflict)
            XCTAssertEqual(try errorCode(duplicate), "name_taken")
            _ = try await gVote(app, single.token, "anna maria 2", a)
            for bad in ["", "   ", String(repeating: "x", count: 61), "Line\nBreak", "bidi\u{202E}name", "nul\u{0}"] {
                try await gPublic(app, .POST, single.token, "/votes", ["name": bad, "answers": a], secret: nil, .badRequest)
            }
            _ = try await gVote(app, single.token, String(repeating: "ä", count: 60), a)
            // Renaming into an existing name is rejected, keeping the own name works.
            let mine = try await gVote(app, single.token, "Gustav", a)
            let secret = try XCTUnwrap(mine["editSecret"] as? String), voteId = try XCTUnwrap((mine["vote"] as? [String: Any])?["id"] as? String)
            try await gPublic(app, .PUT, single.token, "/votes/" + voteId, ["name": "ANNA MARIA", "answers": a], secret: secret, .conflict)
            try await gPublic(app, .PUT, single.token, "/votes/" + voteId, ["name": "gustav", "answers": a], secret: secret)
        }
    }

    func testG1PollInputLimitsAndOptionRules() async throws {
        try await gWithApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            func create(_ body: [String: Any], _ status: HTTPStatus = .badRequest) async throws {
                let merged = ["title": "T", "kind": "text", "choiceMode": "single", "options": [["label": "A"]]].merging(body) { _, new in new } as [String: Any]
                try await api(app, owner, .POST, "groups/polls", merged, status)
            }
            try await create([:], .created)
            try await create(["options": (0..<51).map { ["label": "Option \($0)"] }])
            try await create(["options": (0..<50).map { ["label": "Option \($0)"] }], .created)
            try await create(["options": []])
            try await create(["options": [["label": "A"], ["label": " a "]]])
            try await create(["options": [["label": String(repeating: "x", count: 201)]]])
            try await create(["options": [["label": "x", "date": "2027-01-01"]]])
            try await create(["title": ""]); try await create(["title": String(repeating: "t", count: 121)])
            try await create(["kind": "other"]); try await create(["choiceMode": "triple"])
            try await create(["description": String(repeating: "d", count: 2001)])
            try await create(["deadline": "2020-01-01T00:00:00Z"])
            try await create(["timeZone": "Mars/Base"])
            // Date options.
            let date: [String: Any] = ["kind": "date"]
            try await create(date.merging(["options": [["date": "2027-02-30"]]]) { _, n in n })
            try await create(date.merging(["options": [["date": "2027-02-01", "startTime": "25:00"]]]) { _, n in n })
            try await create(date.merging(["options": [["date": "2027-02-01", "endTime": "10:00"]]]) { _, n in n })
            try await create(date.merging(["options": [["date": "2027-02-01", "startTime": "10:00", "endTime": "09:00"]]]) { _, n in n })
            try await create(date.merging(["options": [["label": "no date"]]]) { _, n in n })
            try await create(date.merging(["options": [["date": "2027-02-01"], ["date": "2027-02-01"]]]) { _, n in n })
            try await create(date.merging(["options": [["date": "2027-02-01"], ["date": "2027-02-01", "startTime": "10:00"]]]) { _, n in n }, .created)
            // Too many polls per account.
            for _ in 0..<(GroupLimits.maxPollsPerAccount) {
                let count = try await GroupPollRecord.query(on: app.db).count()
                if count >= GroupLimits.maxPollsPerAccount { break }
                let row = GroupPollRecord()
                row.accountId = owner.account.id!; row.tokenHash = Secrets.hash(UUID().uuidString); row.title = "x"; row.kind = "text"; row.choiceMode = "single"
                row.hideResults = false; row.createdAt = Date(); row.updatedAt = Date(); try await row.create(on: app.db)
            }
            let full = try await api(app, owner, .POST, "groups/polls", ["title": "T", "kind": "text", "choiceMode": "single", "options": [["label": "A"]]], .conflict)
            XCTAssertEqual(try errorCode(full), "too_many_polls")
        }
    }

    func testG1VoteLimitPerPoll() async throws {
        try await gWithApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let poll = try await gTextPoll(app, owner, mode: "multi")
            let pollId = try XCTUnwrap(UUID(uuidString: poll.id))
            for index in 0..<GroupLimits.maxVotes {
                let vote = GroupPollVoteRecord()
                vote.pollId = pollId; vote.name = "v\(index)"; vote.nameKey = "v\(index)"; vote.secretHash = "x"; vote.createdAt = Date(); vote.updatedAt = Date()
                try await vote.create(on: app.db)
            }
            let response = try await gPublic(app, .POST, poll.token, "/votes", ["name": "late", "answers": [["optionId": poll.options[0], "answer": "yes"]]], secret: nil, .conflict)
            XCTAssertEqual(try errorCode(response), "group_full")
        }
    }

    // MARK: Closing, deadline, hidden results, final option

    func testG1CloseReopenDeadlineHiddenResultsAndFinal() async throws {
        try await gWithApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let poll = try await gTextPoll(app, owner, extra: ["hideResults": true])
            let answer = [["optionId": poll.options[0], "answer": "yes"]]
            let first = try await gVote(app, poll.token, "Anna", answer)
            // Results are hidden from the public while the poll is open, the owner sees everything.
            var view = try await gView(app, poll.token, "poll")
            XCTAssertEqual(view["resultsVisible"] as? Bool, false); XCTAssertNil(view["votes"]); XCTAssertNil(view["tally"])
            XCTAssertEqual(view["voteCount"] as? Int, 1)
            var ownerView = try object(await api(app, owner, .GET, "groups/polls/" + poll.id))
            XCTAssertEqual(gArray(ownerView["votes"]).count, 1); XCTAssertNotNil(ownerView["tally"])
            // Closing shows the results and rejects changes.
            try await api(app, owner, .POST, "groups/polls/\(poll.id)/close")
            view = try await gView(app, poll.token, "poll")
            XCTAssertEqual(view["closed"] as? Bool, true); XCTAssertEqual(view["resultsVisible"] as? Bool, true); XCTAssertEqual(gArray(view["votes"]).count, 1)
            let closed = try await gPublic(app, .POST, poll.token, "/votes", ["name": "Bob", "answers": answer], secret: nil, .conflict)
            XCTAssertEqual(try errorCode(closed), "group_closed")
            let voteId = try XCTUnwrap((first["vote"] as? [String: Any])?["id"] as? String), secret = try XCTUnwrap(first["editSecret"] as? String)
            try await gPublic(app, .PUT, poll.token, "/votes/" + voteId, ["name": "Anna", "answers": answer], secret: secret, .conflict)
            try await gPublic(app, .DELETE, poll.token, "/votes/" + voteId, nil, secret: secret, .conflict)
            // Reopen.
            ownerView = try object(await api(app, owner, .POST, "groups/polls/\(poll.id)/reopen"))
            XCTAssertEqual(ownerView["closed"] as? Bool, false)
            _ = try await gVote(app, poll.token, "Bob", answer)
            // A passed deadline closes without owner action; reopening clears it.
            try await gSetClosedAt(app, poll: poll.id, daysAgo: 1, deadline: true)
            let late = try await gPublic(app, .POST, poll.token, "/votes", ["name": "Cleo", "answers": answer], secret: nil, .conflict)
            XCTAssertEqual(try errorCode(late), "group_closed")
            ownerView = try object(await api(app, owner, .POST, "groups/polls/\(poll.id)/reopen"))
            XCTAssertNil(ownerView["deadline"] as? String)
            _ = try await gVote(app, poll.token, "Cleo", answer)
            // Deadline validation and merge patch.
            try await api(app, owner, .PATCH, "groups/polls/" + poll.id, ["deadline": "2020-01-01T00:00:00Z"], .badRequest)
            let patched = try object(await api(app, owner, .PATCH, "groups/polls/" + poll.id, ["title": "Neu", "deadline": "2099-01-01T00:00:00Z", "hideResults": false]))
            XCTAssertEqual(patched["title"] as? String, "Neu"); XCTAssertEqual(patched["deadline"] as? String, "2099-01-01T00:00:00Z")
            XCTAssertEqual(patched["description"] as? String, nil)
            let cleared = try object(await api(app, owner, .PATCH, "groups/polls/" + poll.id, ["deadline": NSNull()]))
            XCTAssertNil(cleared["deadline"] as? String); XCTAssertEqual(cleared["title"] as? String, "Neu")
            // Final option closes the poll; foreign options are rejected; null clears the pick only.
            try await api(app, owner, .POST, "groups/polls/\(poll.id)/final", ["optionId": UUID().uuidString], .badRequest)
            let picked = try object(await api(app, owner, .POST, "groups/polls/\(poll.id)/final", ["optionId": poll.options[1]]))
            XCTAssertEqual(picked["finalOptionId"] as? String, poll.options[1].uppercased()); XCTAssertEqual(picked["closed"] as? Bool, true)
            let publicFinal = try await gView(app, poll.token, "poll")
            XCTAssertEqual(publicFinal["finalOptionId"] as? String, poll.options[1].uppercased())
            let unpicked = try object(await api(app, owner, .POST, "groups/polls/\(poll.id)/final", ["optionId": NSNull()]))
            XCTAssertNil(unpicked["finalOptionId"] as? String); XCTAssertEqual(unpicked["closed"] as? Bool, true)
        }
    }

    func testG1OwnerRemovesVoteRotatesAndDeletes() async throws {
        try await gWithApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let poll = try await gTextPoll(app, owner, mode: "multi")
            let answer = [["optionId": poll.options[0], "answer": "yes"]]
            let spam = try await gVote(app, poll.token, "Spam", answer)
            _ = try await gVote(app, poll.token, "Anna", answer)
            let spamId = try XCTUnwrap((spam["vote"] as? [String: Any])?["id"] as? String)
            try await api(app, owner, .DELETE, "groups/polls/\(poll.id)/votes/\(UUID().uuidString)", nil, .notFound)
            try await api(app, owner, .DELETE, "groups/polls/\(poll.id)/votes/\(spamId)", nil, .noContent)
            try await eq(try await GroupPollVoteRecord.query(on: app.db).count(), 1)
            // Rotate: old link dies at once, the new one works and is shown once.
            let rotated = try object(await api(app, owner, .POST, "groups/polls/\(poll.id)/rotate-token"))
            let newToken = try XCTUnwrap(rotated["token"] as? String)
            XCTAssertNotEqual(newToken, poll.token); XCTAssertEqual(newToken.count, 43)
            try await gPublic(app, .GET, poll.token, "", nil, secret: nil, .notFound)
            try await gPublic(app, .GET, newToken)
            // Votes survive rotation, including their edit secrets.
            let view = try await gView(app, newToken, "poll")
            XCTAssertEqual(gArray(view["votes"]).count, 1)
            // Delete removes the whole tree.
            try await api(app, owner, .DELETE, "groups/polls/" + poll.id, nil, .noContent)
            try await gPublic(app, .GET, newToken, "", nil, secret: nil, .notFound)
            for count in [try await GroupPollRecord.query(on: app.db).count(), try await GroupPollOptionRecord.query(on: app.db).count(),
                          try await GroupPollVoteRecord.query(on: app.db).count(), try await GroupPollAnswerRecord.query(on: app.db).count()] { XCTAssertEqual(count, 0) }
            try await api(app, owner, .GET, "groups/polls/" + poll.id, nil, .notFound)
        }
    }

    // MARK: Owner authorization

    func testG1OwnerEndpointsAreOwnerOnlyAndNeedSessionAndCSRF() async throws {
        try await gWithApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let other = try await second(app, auth, owner)
            let poll = try await gTextPoll(app, owner)
            let order = try await gOrder(app, owner)
            let catalog = try object(await api(app, owner, .POST, "groups/catalogs", ["name": "Döner", "items": [["name": "Döner", "priceCents": 650]]], .created))
            let catalogId = try XCTUnwrap(catalog["id"] as? String)
            let probes: [(HTTPMethod, String, [String: Any]?)] = [
                (.GET, "groups/polls/" + poll.id, nil), (.PATCH, "groups/polls/" + poll.id, ["title": "x"]), (.DELETE, "groups/polls/" + poll.id, nil),
                (.POST, "groups/polls/\(poll.id)/close", nil), (.POST, "groups/polls/\(poll.id)/reopen", nil), (.POST, "groups/polls/\(poll.id)/rotate-token", nil),
                (.POST, "groups/polls/\(poll.id)/final", ["optionId": poll.options[0]]), (.DELETE, "groups/polls/\(poll.id)/votes/\(UUID().uuidString)", nil),
                (.GET, "groups/orders/" + order.id, nil), (.PATCH, "groups/orders/" + order.id, ["title": "x"]), (.DELETE, "groups/orders/" + order.id, nil),
                (.POST, "groups/orders/\(order.id)/close", nil), (.POST, "groups/orders/\(order.id)/rotate-token", nil), (.GET, "groups/orders/\(order.id)/export", nil),
                (.DELETE, "groups/orders/\(order.id)/entries/\(UUID().uuidString)", nil),
                (.GET, "groups/catalogs/" + catalogId, nil), (.PUT, "groups/catalogs/" + catalogId, ["name": "x", "items": []]), (.DELETE, "groups/catalogs/" + catalogId, nil),
            ]
            for (method, path, body) in probes { try await api(app, other, method, path, body, .notFound) }
            // Other accounts see nothing of the owner's items.
            for list in ["groups/polls", "groups/orders", "groups/catalogs"] { let rows = try await gList(app, other, list); XCTAssertEqual(rows.count, 0) }
            // Cannot select someone else's catalog for a round.
            try await api(app, other, .POST, "groups/orders", ["title": "x", "catalogId": catalogId], .badRequest)
            // Unauthenticated, missing CSRF, bearer token.
            try await timeRequest(app, nil, .GET, "groups/polls", nil, status: .unauthorized)
            let noCSRF = try await app.testable().sendRequest(.POST, "/api/v1/groups/polls/\(poll.id)/close", headers: headers(owner, csrf: false))
            XCTAssertEqual(noCSRF.status, .forbidden)
            let bearer = try object(await api(app, owner, .POST, "me/api-tokens", ["name": "t", "scopes": ["time:read"], "expiresInDays": 30], .created))
            if let value = bearer["token"] as? String {
                try await timeRequest(app, nil, .GET, "groups/polls", nil, status: .unauthorized, extra: ["Authorization": "Bearer " + value])
            }
            // The owner still sees everything.
            let mine = try await gList(app, owner, "groups/polls"); XCTAssertEqual(mine.count, 1)
        }
    }

    // MARK: Orders

    func testG1OrderEntriesAggregationAndTake() async throws {
        try await gWithApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let catalog = try object(await api(app, owner, .POST, "groups/catalogs",
                ["name": "Dönerladen", "items": [["name": "Döner", "priceCents": 650], ["name": "Dürüm"], ["name": "Pommes", "priceCents": 300]]], .created))
            let order = try await gOrder(app, owner, extra: ["note": "Bis 11:30 bestellen", "catalogId": catalog["id"] as Any])
            let view = try await gView(app, order.token, "order")
            XCTAssertEqual(view["title"] as? String, "Dönerstag"); XCTAssertNil(view["id"]); XCTAssertNil(view["catalogId"])
            XCTAssertEqual(gArray(view["suggestions"]).map { $0["name"] as? String }, ["Döner", "Dürüm", "Pommes"])
            let a = try object(await gPublic(app, .POST, order.token, "/entries", ["name": "Anna", "item": "Döner", "note": "ohne Zwiebeln", "quantity": 2, "priceCents": 650], secret: nil, .created))
            let aEntry = try XCTUnwrap(a["entry"] as? [String: Any]), aId = try XCTUnwrap(aEntry["id"] as? String), aSecret = try XCTUnwrap(a["editSecret"] as? String)
            XCTAssertNil(aEntry["editSecret"]); XCTAssertEqual(aEntry["quantity"] as? Int, 2)
            let stored = try await XCTUnwrapAsync(try await GroupOrderEntryRecord.find(UUID(uuidString: aId), on: app.db))
            XCTAssertEqual(stored.secretHash, Secrets.hash(aSecret))
            // Bob takes Anna's entry as his own: same item, note and price, own secret, quantity 1.
            let taken = try object(await gPublic(app, .POST, order.token, "/entries/\(aId)/take", ["name": "Bob"], secret: nil, .created))
            let bEntry = try XCTUnwrap(taken["entry"] as? [String: Any])
            XCTAssertEqual(bEntry["item"] as? String, "Döner"); XCTAssertEqual(bEntry["note"] as? String, "ohne Zwiebeln"); XCTAssertEqual(bEntry["priceCents"] as? Int, 650)
            XCTAssertEqual(bEntry["quantity"] as? Int, 1); XCTAssertEqual(bEntry["name"] as? String, "Bob")
            XCTAssertNotEqual(taken["editSecret"] as? String, aSecret)
            try await gPublic(app, .POST, order.token, "/entries/\(UUID().uuidString)/take", ["name": "Bob"], secret: nil, .notFound)
            try await gPublic(app, .POST, order.token, "/entries/\(aId)/take", ["name": ""], secret: nil, .badRequest)
            _ = try await gPublic(app, .POST, order.token, "/entries", ["name": "Cleo", "item": "döner", "note": "Ohne  Zwiebeln", "priceCents": 650], secret: nil, .created)
            _ = try await gPublic(app, .POST, order.token, "/entries", ["name": "Cleo", "item": "Pommes", "priceCents": 300], secret: nil, .created)
            _ = try await gPublic(app, .POST, order.token, "/entries", ["name": "Dora", "item": "Falafel"], secret: nil, .created)
            let full = try await gView(app, order.token, "order")
            XCTAssertEqual(full["entryCount"] as? Int, 5)
            let aggregated = gArray(full["aggregated"])
            XCTAssertEqual(aggregated.first?["quantity"] as? Int, 4)
            XCTAssertEqual((aggregated.first?["names"] as? [String]) ?? [], ["Anna", "Bob", "Cleo"])
            XCTAssertEqual(aggregated.count, 3)
            XCTAssertEqual(full["totalCents"] as? Int, 4 * 650 + 300); XCTAssertEqual(full["unpricedQuantity"] as? Int, 1)
            // Edit and delete need the secret of that entry.
            let update: [String: Any] = ["name": "Anna", "item": "Dürüm", "quantity": 1]
            try await gPublic(app, .PUT, order.token, "/entries/" + aId, update, secret: try XCTUnwrap(taken["editSecret"] as? String), .forbidden)
            try await gPublic(app, .DELETE, order.token, "/entries/" + aId, nil, secret: nil, .forbidden)
            let updated = try object(await gPublic(app, .PUT, order.token, "/entries/" + aId, update, secret: aSecret))
            XCTAssertEqual(updated["item"] as? String, "Dürüm"); XCTAssertNil(updated["priceCents"] as? Int)
            try await gPublic(app, .DELETE, order.token, "/entries/" + aId, nil, secret: aSecret, .noContent)
            try await gPublic(app, .DELETE, order.token, "/entries/" + aId, nil, secret: aSecret, .notFound)
            // Closing stops everything for participants; the owner can still remove entries.
            try await api(app, owner, .POST, "groups/orders/\(order.id)/close")
            let closed = try await gPublic(app, .POST, order.token, "/entries", ["name": "Eve", "item": "x"], secret: nil, .conflict)
            XCTAssertEqual(try errorCode(closed), "group_closed")
            let remaining = try await GroupOrderEntryRecord.query(on: app.db).first()
            try await gPublic(app, .POST, order.token, "/entries/\(try XCTUnwrap(remaining?.id))/take", ["name": "Eve"], secret: nil, .conflict)
            let ownerView = try object(await api(app, owner, .GET, "groups/orders/" + order.id))
            let entryId = try XCTUnwrap(gArray(ownerView["entries"]).first?["id"] as? String)
            try await api(app, owner, .DELETE, "groups/orders/\(order.id)/entries/\(entryId)", nil, .noContent)
            try await api(app, owner, .DELETE, "groups/orders/\(order.id)/entries/\(entryId)", nil, .notFound)
            try await api(app, owner, .POST, "groups/orders/\(order.id)/reopen")
            _ = try await gPublic(app, .POST, order.token, "/entries", ["name": "Eve", "item": "x"], secret: nil, .created)
            // Rotate and delete.
            let rotated = try object(await api(app, owner, .POST, "groups/orders/\(order.id)/rotate-token"))
            try await gPublic(app, .GET, order.token, "", nil, secret: nil, .notFound)
            try await gPublic(app, .GET, try XCTUnwrap(rotated["token"] as? String))
            try await api(app, owner, .DELETE, "groups/orders/" + order.id, nil, .noContent)
            try await eq(try await GroupOrderEntryRecord.query(on: app.db).count(), 0)
            try await eq(try await GroupOrderRecord.query(on: app.db).count(), 0)
            // Deleting a catalog detaches it from rounds.
            let second = try await gOrder(app, owner, extra: ["catalogId": catalog["id"] as Any])
            try await api(app, owner, .DELETE, "groups/catalogs/" + (catalog["id"] as! String), nil, .noContent)
            let detached = try object(await api(app, owner, .GET, "groups/orders/" + second.id))
            XCTAssertNil(detached["catalogId"] as? String); XCTAssertEqual(gArray(detached["suggestions"]).count, 0)
        }
    }

    func testG1EntryValidationAndLimits() async throws {
        try await gWithApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let order = try await gOrder(app, owner)
            func add(_ body: [String: Any], _ status: HTTPStatus = .badRequest) async throws {
                try await gPublic(app, .POST, order.token, "/entries", ["name": "Anna", "item": "Döner"].merging(body) { _, new in new }, secret: nil, status)
            }
            try await add([:], .created)
            try await add(["name": ""]); try await add(["name": String(repeating: "n", count: 61)])
            try await add(["item": ""]); try await add(["item": String(repeating: "i", count: 201)]); try await add(["item": "line\nbreak"])
            try await add(["note": String(repeating: "n", count: 201)])
            try await add(["quantity": 0]); try await add(["quantity": 100]); try await add(["quantity": -1])
            try await add(["priceCents": -1]); try await add(["priceCents": GroupLimits.maxPriceCents + 1])
            try await add(["quantity": 99, "priceCents": GroupLimits.maxPriceCents, "item": String(repeating: "i", count: 200)], .created)
            // Oversized text is refused (the transport additionally caps public bodies at Vapor's 16 kB default).
            try await gPublic(app, .POST, order.token, "/entries", ["name": "Anna", "item": String(repeating: "x", count: 40_000)], secret: nil, .badRequest)
            // Entry limit per round.
            let orderId = try XCTUnwrap(UUID(uuidString: order.id))
            let existing = try await GroupOrderEntryRecord.query(on: app.db).count()
            for index in existing..<GroupLimits.maxEntries {
                let row = GroupOrderEntryRecord()
                row.orderId = orderId; row.name = "n\(index)"; row.item = "i"; row.quantity = 1; row.secretHash = "x"; row.createdAt = Date(); row.updatedAt = Date()
                try await row.create(on: app.db)
            }
            let full = try await gPublic(app, .POST, order.token, "/entries", ["name": "Zed", "item": "x"], secret: nil, .conflict)
            XCTAssertEqual(try errorCode(full), "group_full")
            let firstEntry = try await XCTUnwrapAsync(try await GroupOrderEntryRecord.query(on: app.db).first())
            let takeFull = try await gPublic(app, .POST, order.token, "/entries/\(try firstEntry.requireID())/take", ["name": "Zed"], secret: nil, .conflict)
            XCTAssertEqual(try errorCode(takeFull), "group_full")
            // Round validation.
            try await api(app, owner, .POST, "groups/orders", ["title": ""], .badRequest)
            try await api(app, owner, .POST, "groups/orders", ["title": "x", "deadline": "2020-01-01T00:00:00Z"], .badRequest)
            try await api(app, owner, .POST, "groups/orders", ["title": "x", "catalogId": UUID().uuidString], .badRequest)
            let patched = try object(await api(app, owner, .PATCH, "groups/orders/" + order.id, ["title": "Neu", "note": "Hinweis"]))
            XCTAssertEqual(patched["title"] as? String, "Neu"); XCTAssertEqual(patched["note"] as? String, "Hinweis")
            let cleared = try object(await api(app, owner, .PATCH, "groups/orders/" + order.id, ["note": NSNull()]))
            XCTAssertNil(cleared["note"] as? String)
        }
    }

    func testG1ExportCSVAndTextWithFormulaInjection() async throws {
        try await gWithApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let order = try await gOrder(app, owner, extra: ["title": "=cmd|' /C calc'!A0"])
            for (name, item, note) in [("=HYPERLINK(\"http://evil\")", "+SUM(1,1)", "@import"), ("-2+3", "Döner, scharf", "mit \"Soße\""), ("Anna", "Tee", "")] {
                var body: [String: Any] = ["name": name, "item": item, "priceCents": 350, "quantity": 2]
                if !note.isEmpty { body["note"] = note }
                try await gPublic(app, .POST, order.token, "/entries", body, secret: nil, .created)
            }
            for response in [try await gPublic(app, .GET, order.token, "/export?format=csv"), try await api(app, owner, .GET, "groups/orders/\(order.id)/export?format=csv")] {
                XCTAssertEqual(response.headers.first(name: .contentType), "text/csv; charset=utf-8")
                XCTAssertTrue(response.headers.first(name: .contentDisposition)?.hasPrefix("attachment") == true)
                XCTAssertEqual(response.headers.first(name: "X-Content-Type-Options"), "nosniff")
                XCTAssertEqual(response.headers.first(name: "X-Robots-Tag"), "noindex, nofollow")
                let lines = response.body.string.components(separatedBy: "\r\n").filter { !$0.isEmpty }
                XCTAssertEqual(lines[0], "Name,Gericht,Notiz,Menge,Einzelpreis (EUR),Summe (EUR)")
                // Every cell that could start a formula is neutralised with an apostrophe.
                XCTAssertTrue(lines[1].hasPrefix("\"'=HYPERLINK(\"\"http://evil\"\")\",\"'+SUM(1,1)\","), lines[1])
                XCTAssertTrue(lines[1].contains(",'@import,2,3.50,7.00"), lines[1])
                XCTAssertTrue(lines[2].hasPrefix("'-2+3,\"Döner, scharf\",\"mit \"\"Soße\"\"\",2,3.50,7.00"), lines[2])
                XCTAssertEqual(lines[3], "Anna,Tee,,2,3.50,7.00")
                for line in lines.dropFirst() { for cell in line.split(separator: ",", omittingEmptySubsequences: false).prefix(1) { XCTAssertFalse(cell.hasPrefix("=")) } }
            }
            let text = try await gPublic(app, .GET, order.token, "/export?format=txt")
            XCTAssertEqual(text.headers.first(name: .contentType), "text/plain; charset=utf-8")
            XCTAssertTrue(text.body.string.contains("Zusammenfassung")); XCTAssertTrue(text.body.string.contains("Anna: 2x Tee - 7,00 EUR"))
            XCTAssertTrue(text.body.string.contains("Gesamt: 21,00 EUR"))
            try await gPublic(app, .GET, order.token, "/export?format=xlsx", nil, secret: nil, .badRequest)
            try await api(app, owner, .GET, "groups/orders/\(order.id)/export?format=pdf", nil, .badRequest)
        }
    }

    func testG1CatalogsAndSuggestions() async throws {
        try await gWithApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let created = try object(await api(app, owner, .POST, "groups/catalogs", ["name": " Dönerladen ", "items": [["name": "Döner", "priceCents": 650], ["name": "Dürüm"]]], .created))
            let id = try XCTUnwrap(created["id"] as? String)
            XCTAssertEqual(created["name"] as? String, "Dönerladen"); XCTAssertEqual(created["itemCount"] as? Int, 2)
            let replaced = try object(await api(app, owner, .PUT, "groups/catalogs/" + id, ["name": "Neu", "items": [["name": "Lahmacun", "priceCents": 500]]]))
            XCTAssertEqual(gArray(replaced["items"]).map { $0["name"] as? String }, ["Lahmacun"])
            try await eq(try await GroupCatalogItemRecord.query(on: app.db).count(), 1)
            let got = try object(await api(app, owner, .GET, "groups/catalogs/" + id)); XCTAssertEqual(got["name"] as? String, "Neu")
            for bad: [String: Any] in [["name": "", "items": []], ["name": "x", "items": [["name": ""]]], ["name": "x", "items": [["name": "a", "priceCents": -5]]],
                                       ["name": String(repeating: "n", count: 81), "items": []], ["name": "x", "items": (0...GroupLimits.maxCatalogItems).map { ["name": "i\($0)"] }]] {
                try await api(app, owner, .POST, "groups/catalogs", bad, .badRequest)
            }
            try await api(app, owner, .POST, "groups/catalogs", ["name": "x", "items": (0..<GroupLimits.maxCatalogItems).map { ["name": "i\($0)"] }], .created)
            for index in 0..<(GroupLimits.maxCatalogsPerAccount - 2) { try await api(app, owner, .POST, "groups/catalogs", ["name": "c\(index)", "items": []], .created) }
            let full = try await api(app, owner, .POST, "groups/catalogs", ["name": "late", "items": []], .conflict)
            XCTAssertEqual(try errorCode(full), "too_many_catalogs")
            // "Remember my items": most frequent items of earlier rounds.
            let order = try await gOrder(app, owner)
            for (name, item) in [("A", "Döner"), ("B", "döner"), ("C", "Pizza")] { try await gPublic(app, .POST, order.token, "/entries", ["name": name, "item": item, "priceCents": 600], secret: nil, .created) }
            let suggestions = try list(await api(app, owner, .GET, "groups/orders/suggestions"))
            XCTAssertEqual(suggestions.first?["count"] as? Int, 2); XCTAssertEqual(suggestions.count, 2)
            let other = try await second(app, auth, owner)
            let none = try await gList(app, other, "groups/orders/suggestions"); XCTAssertEqual(none.count, 0)
            try await api(app, owner, .DELETE, "groups/catalogs/" + id, nil, .noContent)
            try await api(app, owner, .GET, "groups/catalogs/" + id, nil, .notFound)
        }
    }

    // MARK: Rate limits

    func testG1RateLimits() async throws {
        try await gWithApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let poll = try await gTextPoll(app, owner, mode: "multi")
            let answer = [["optionId": poll.options[0], "answer": "yes"]]
            // Unknown links: 30 misses per client, then 429 before any lookup (also for the valid link).
            for _ in 0..<GroupRateLimit.miss { try await gPublic(app, .GET, String(repeating: "Z", count: 43), "", nil, secret: nil, .notFound) }
            let limited = try await gPublic(app, .GET, poll.token, "", nil, secret: nil, .tooManyRequests)
            XCTAssertNotNil(limited.headers.first(name: .retryAfter)); XCTAssertEqual(try errorCode(limited), "too_many_requests")
            try await RateLimitEvent.query(on: app.db).delete()
            _ = try await gVote(app, poll.token, "Anna", answer)
            // Per-IP write limit.
            for index in 0..<GroupRateLimit.ipWrite { try await RateLimitEvent(key: "grp-write-ip:unknown", occurredAt: Date().addingTimeInterval(Double(-index))).create(on: app.db) }
            try await gPublic(app, .POST, poll.token, "/votes", ["name": "Bob", "answers": answer], secret: nil, .tooManyRequests)
            try await gPublic(app, .GET, poll.token)
            try await RateLimitEvent.query(on: app.db).delete()
            // Per-link write limit (other clients share the link).
            let id = poll.id.uppercased()
            for _ in 0..<GroupRateLimit.tokenWrite { try await RateLimitEvent(key: "grp-write-tok:" + id, occurredAt: Date()).create(on: app.db) }
            try await gPublic(app, .POST, poll.token, "/votes", ["name": "Cleo", "answers": answer], secret: nil, .tooManyRequests)
            try await RateLimitEvent.query(on: app.db).delete()
            // Per-IP read limit.
            for _ in 0..<GroupRateLimit.ipRead { try await RateLimitEvent(key: "grp-ip:unknown", occurredAt: Date()).create(on: app.db) }
            try await gPublic(app, .GET, poll.token, "", nil, secret: nil, .tooManyRequests)
            // Old events do not count.
            try await RateLimitEvent.query(on: app.db).delete()
            for _ in 0..<GroupRateLimit.ipRead { try await RateLimitEvent(key: "grp-ip:unknown", occurredAt: Date().addingTimeInterval(-GroupRateLimit.window - 5)).create(on: app.db) }
            try await gPublic(app, .GET, poll.token)
        }
    }

    func testG1GuessingEditSecretsIsRateLimited() async throws {
        try await gWithApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let poll = try await gTextPoll(app, owner, mode: "multi")
            let vote = try await gVote(app, poll.token, "Anna", [["optionId": poll.options[0], "answer": "yes"]])
            let voteId = try XCTUnwrap((vote["vote"] as? [String: Any])?["id"] as? String)
            let body: [String: Any] = ["name": "Anna", "answers": [["optionId": poll.options[0], "answer": "yes"]]]
            for _ in 0..<GroupRateLimit.miss { try await gPublic(app, .PUT, poll.token, "/votes/" + voteId, body, secret: Secrets.token(), .forbidden) }
            try await gPublic(app, .PUT, poll.token, "/votes/" + voteId, body, secret: try XCTUnwrap(vote["editSecret"] as? String), .tooManyRequests)
        }
    }

    // MARK: Module switch

    func testG1ModuleSwitch() async throws {
        try await gWithApp { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let poll = try await gTextPoll(app, owner)
            let order = try await gOrder(app, owner)
            // Owner turns the module off: owner API and the owner's public links are gone.
            try await setModules(app, owner, ["groups": false])
            let disabled = try await api(app, owner, .GET, "groups/polls", nil, .notFound)
            XCTAssertEqual(try errorCode(disabled), "module_disabled")
            try await gPublic(app, .GET, poll.token, "", nil, secret: nil, .notFound)
            try await gPublic(app, .GET, order.token, "", nil, secret: nil, .notFound)
            try await setModules(app, owner, ["groups": true])
            try await gPublic(app, .GET, poll.token)
            // Operator switch removes the whole surface, even for a visitor with a stale session cookie.
            try await setModules(app, owner, ["groups": false], server: true)
            let server = try await gPublic(app, .GET, poll.token, "", nil, secret: nil, .notFound)
            XCTAssertEqual(try errorCode(server), "module_disabled")
            let stale = try await app.testable().sendRequest(.GET, "/api/v1/public/groups/" + poll.token, headers: ["Cookie": "tt_session=garbage"])
            XCTAssertEqual(stale.status, .notFound)
            try await setModules(app, owner, ["groups": true], server: true)
            // A stale cookie on the public route is simply ignored.
            let ok = try await app.testable().sendRequest(.GET, "/api/v1/public/groups/" + poll.token, headers: ["Cookie": "tt_session=garbage"])
            XCTAssertEqual(ok.status, .ok)
            // Disabled owners lose their public links.
            let row = try await XCTUnwrapAsync(try await Account.find(owner.account.id, on: app.db))
            row.disabledAt = Date(); try await row.update(on: app.db)
            try await gPublic(app, .GET, poll.token, "", nil, secret: nil, .notFound)
        }
        try await gWithApp(environment: ["MODULES_DISABLED": "groups"]) { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            try await api(app, owner, .GET, "groups/polls", nil, .notFound)
            try await gPublic(app, .GET, String(repeating: "A", count: 43), "", nil, secret: nil, .notFound)
        }
    }

    // MARK: Retention

    func testG1RetentionDeletesClosedAndExpiredItemsOnly() async throws {
        try await gWithApp(environment: ["GROUPS_RETENTION_DAYS": "30"]) { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let service = try maintenanceService(app, environment: ["GROUPS_RETENTION_DAYS": "30"])
            XCTAssertEqual(service.options.groupsRetentionDays, 30)
            XCTAssertEqual(try MaintenanceOptions(environment: [:]).groupsRetentionDays, 90)
            XCTAssertThrowsError(try MaintenanceOptions(environment: ["GROUPS_RETENTION_DAYS": "0"]))
            let answer: (String, [String]) -> [[String: String]] = { _, options in [["optionId": options[0], "answer": "yes"]] }
            let oldClosed = try await gTextPoll(app, owner), recentClosed = try await gTextPoll(app, owner)
            let oldDeadline = try await gTextPoll(app, owner), open = try await gTextPoll(app, owner), reopened = try await gTextPoll(app, owner)
            for poll in [oldClosed, recentClosed, oldDeadline, open, reopened] { _ = try await gVote(app, poll.token, "Anna", answer("", poll.options)) }
            try await gSetClosedAt(app, poll: oldClosed.id, daysAgo: 31)
            try await gSetClosedAt(app, poll: recentClosed.id, daysAgo: 29)
            try await gSetClosedAt(app, poll: oldDeadline.id, daysAgo: 40, deadline: true)
            try await gSetClosedAt(app, poll: reopened.id, daysAgo: 100, deadline: true)
            let reopenedRow = try await XCTUnwrapAsync(try await GroupPollRecord.find(UUID(uuidString: reopened.id), on: app.db))
            reopenedRow.deadline = Date().addingTimeInterval(86_400); try await reopenedRow.update(on: app.db)
            let oldOrder = try await gOrder(app, owner), openOrder = try await gOrder(app, owner), expiredOrder = try await gOrder(app, owner)
            for order in [oldOrder, openOrder, expiredOrder] { try await gPublic(app, .POST, order.token, "/entries", ["name": "A", "item": "x"], secret: nil, .created) }
            let old = try await XCTUnwrapAsync(try await GroupOrderRecord.find(UUID(uuidString: oldOrder.id), on: app.db))
            old.closedAt = Date().addingTimeInterval(-45 * 86_400); try await old.update(on: app.db)
            let expired = try await XCTUnwrapAsync(try await GroupOrderRecord.find(UUID(uuidString: expiredOrder.id), on: app.db))
            expired.deadline = Date().addingTimeInterval(-45 * 86_400); try await expired.update(on: app.db)
            let polls = try await service.groupPolls(Date()), orders = try await service.groupOrders(Date())
            XCTAssertEqual(polls, 2); XCTAssertEqual(orders, 2)
            let remaining = Set(try await GroupPollRecord.query(on: app.db).all().compactMap { $0.id?.uuidString })
            XCTAssertEqual(remaining, Set([recentClosed.id, open.id, reopened.id].map { $0.uppercased() }))
            try await eq(try await GroupPollVoteRecord.query(on: app.db).count(), 3)
            try await eq(try await GroupPollAnswerRecord.query(on: app.db).count(), 3)
            try await eq(try await GroupPollOptionRecord.query(on: app.db).count(), 9)
            try await eq(try await GroupOrderEntryRecord.query(on: app.db).count(), 1)
            try await gPublic(app, .GET, oldClosed.token, "", nil, secret: nil, .notFound)
            // Idempotent, and the full run reports the steps.
            let again = try await service.groupPolls(Date()); XCTAssertEqual(again, 0)
            let report = await service.run()
            XCTAssertEqual(report.counts["group_polls"], 0); XCTAssertEqual(report.counts["group_orders"], 0); XCTAssertEqual(report.failedSteps, [])
        }
    }

    // MARK: Account export and deletion

    func testG1ExportAndAccountDeletionIncludeGroupData() async throws {
        try await gWithApp(environment: singleScenarioEnvironment()) { app, auth in
            let (admin, _) = try await registered(auth, db: app.db)
            let (member, _) = try await registered(auth, db: app.db, handle: "member", admin: admin)
            let memberId = try member.account.requireID()
            let poll = try await gDatePoll(app, member), order = try await gOrder(app, member)
            let catalog = try object(await api(app, member, .POST, "groups/catalogs", ["name": "K", "items": [["name": "Döner", "priceCents": 650]]], .created))
            _ = try await gVote(app, poll.token, "Anna", [["optionId": poll.options[0], "answer": "yes"], ["optionId": poll.options[1], "answer": "maybe"]])
            try await gPublic(app, .POST, order.token, "/entries", ["name": "Bob", "item": "Döner"], secret: nil, .created)
            // Another account's data stays untouched by the member's deletion.
            let adminPoll = try await gTextPoll(app, admin)
            _ = try await gVote(app, adminPoll.token, "Keep", [["optionId": adminPoll.options[0], "answer": "yes"]])
            let export = try await api(app, member, .GET, "me/export")
            let files = try entries(Data(export.body.readableBytesView))
            let polls = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(files["polls.json"])) as? [[String: Any]])
            XCTAssertEqual(polls.count, 1); XCTAssertEqual(gArray(polls[0]["votes"]).first?["name"] as? String, "Anna"); XCTAssertEqual(gArray(polls[0]["options"]).count, 3)
            XCTAssertEqual((try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(files["orders.json"])) as? [[String: Any]])).count, 1)
            XCTAssertEqual((try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(files["catalogs.json"])) as? [[String: Any]])).count, 1)
            // Neither link tokens nor hashes nor edit secrets are exported.
            let all = files.values.compactMap { String(data: $0, encoding: .utf8) }.joined()
            for secret in [poll.token, order.token, Secrets.hash(poll.token), Secrets.hash(order.token)] { XCTAssertFalse(all.contains(secret)) }
            XCTAssertFalse(try XCTUnwrap(String(data: XCTUnwrap(files["polls.json"]), encoding: .utf8)).contains("secret"))
            _ = catalog
            // Delete the member: everything of the module is gone, the other account's items stay.
            let fresh = try await freshSession(app, auth, "admin")
            try await del(app, fresh, "admin/accounts/\(memberId)", confirm: "member")
            for count in [try await GroupPollRecord.query(on: app.db).filter(\.$accountId == memberId).count(), try await GroupOrderRecord.query(on: app.db).filter(\.$accountId == memberId).count(),
                          try await GroupCatalogRecord.query(on: app.db).filter(\.$accountId == memberId).count()] { XCTAssertEqual(count, 0) }
            try await eq(try await GroupPollRecord.query(on: app.db).count(), 1)
            try await eq(try await GroupPollVoteRecord.query(on: app.db).count(), 1)
            try await eq(try await GroupPollOptionRecord.query(on: app.db).count(), 3)
            try await eq(try await GroupPollAnswerRecord.query(on: app.db).count(), 1)
            try await eq(try await GroupOrderEntryRecord.query(on: app.db).count(), 0)
            try await eq(try await GroupCatalogItemRecord.query(on: app.db).count(), 0)
            try await gPublic(app, .GET, poll.token, "", nil, secret: nil, .notFound)
            try await gPublic(app, .GET, adminPoll.token)
        }
    }

    // MARK: Static shell and headers

    func testG1SPARouteIsNotIndexableAndAPIIsNotShadowed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pwa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "<html>PWA</html>".write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try await gWithApp(environment: ["PWA_STATIC_DIR": directory.path]) { app, auth in
            let (owner, _) = try await registered(auth, db: app.db)
            let poll = try await gTextPoll(app, owner)
            let page = try await app.testable().sendRequest(.GET, "/g/" + poll.token)
            XCTAssertEqual(page.status, .ok); XCTAssertTrue(page.body.string.contains("PWA"))
            XCTAssertEqual(page.headers.first(name: "X-Robots-Tag"), "noindex, nofollow")
            XCTAssertEqual(page.headers.first(name: "Referrer-Policy"), "no-referrer")
            let api = try await gPublic(app, .GET, poll.token)
            XCTAssertFalse(api.body.string.contains("PWA")); XCTAssertEqual(api.headers.first(name: .contentType)?.hasPrefix("application/json"), true)
            let missing = try await gPublic(app, .GET, String(repeating: "Q", count: 43), "", nil, secret: nil, .notFound)
            XCTAssertFalse(missing.body.string.contains("PWA")); XCTAssertEqual(missing.headers.first(name: "X-Robots-Tag"), "noindex, nofollow")
            XCTAssertEqual(missing.headers.first(name: .cacheControl), "no-store")
            // Other SPA pages stay indexable-neutral (no header added).
            let other = try await app.testable().sendRequest(.GET, "/some/spa/route")
            XCTAssertNil(other.headers.first(name: "X-Robots-Tag"))
        }
    }

    func testG1RequestsDoNotLeakTokensIntoLogs() {
        // The console log scrubber already redacts /t/ and /ics/ paths; the group link path /g/<token> is covered too.
        let token = Secrets.token()
        XCTAssertFalse(TriggerTokenScrubber.scrub("GET /g/\(token) 200").contains(token))
        XCTAssertFalse(TriggerTokenScrubber.scrub("GET /api/v1/public/groups/\(token)/votes 201").contains(token))
    }
}
