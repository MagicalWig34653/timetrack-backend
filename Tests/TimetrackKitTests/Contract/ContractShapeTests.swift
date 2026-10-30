import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

/// Validates real responses against the response schemas of contracts/openapi.yaml.
/// Mismatches are collected and reported together so one run shows every deviation.
extension AuthTests {
    /// Calls `method path` (as an API-relative path), then validates the JSON body against the contract entry for `template`.
    @discardableResult
    func contractCheck(_ app: Application, _ context: AuthContext?, _ document: [String: Any], _ method: HTTPMethod, template: String,
                       path: String, body: [String: Any]? = nil, status: HTTPStatus = .ok, problems: inout [String]) async throws -> XCTHTTPResponse {
        var head = context.map { headers($0) } ?? [:]
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        if data != nil { head.contentType = .json }
        let response = try await app.testable().sendRequest(method, "/api/v1/" + path, headers: head, body: data.map(ByteBuffer.init(data:)))
        let label = "\(method.rawValue) \(template) -> \(status.code)"
        guard response.status == status else {
            problems.append("\(label): unexpected status \(response.status.code) \(response.body.string.prefix(120))"); return response
        }
        let (documented, schema) = Contract.responseSchema(document, method: method.rawValue, template: "/api/v1/" + template, status: Int(status.code))
        // Error statuses are often covered only implicitly; they must still match the shared Error schema.
        let errorSchema: [String: Any]? = status.code >= 400 ? ["$ref": "#/components/schemas/Error"] : nil
        guard documented || errorSchema != nil else { problems.append("\(label): status not documented in contract"); return response }
        guard let schema = schema ?? errorSchema else { return response }
        let bytes = Data(response.body.readableBytesView)
        guard let json = try? JSONSchemaValidator.parse(bytes) else {
            problems.append("\(label): body is not JSON"); return response
        }
        for issue in JSONSchemaValidator(document: document, reportUndeclaredProperties: true).validate(json, against: schema) { problems.append("\(label): \(issue)") }
        return response
    }

    func testContractResponseShapes() async throws {
        let document = try Contract.load()
        var problems: [String] = []
        try await withApp(environment: singleScenarioEnvironment()) { app, auth in
            let (admin, _) = try await registered(auth, db: app.db)
            let member = try await second(app, auth, admin)
            let memberId = try member.account.requireID().uuidString
            func check(_ method: HTTPMethod, _ template: String, _ path: String? = nil, _ body: [String: Any]? = nil, _ status: HTTPStatus = .ok,
                       as context: AuthContext? = nil) async throws {
                try await self.contractCheck(app, context ?? admin, document, method, template: template, path: path ?? template, body: body, status: status, problems: &problems)
            }
            try await check(.GET, "auth/session")
            try await check(.GET, "me/passkeys")
            try await check(.GET, "modules")
            try await check(.GET, "system/info")
            try await check(.GET, "me/preferences")
            try await check(.PATCH, "me/preferences", nil, ["accent": "custom", "accentCustomHex": "#12ab9f", "colorScheme": "dark", "glow": "medium"])
            try await check(.GET, "auth/session")
            try await check(.PATCH, "me/preferences", nil, ["accent": "teal"])
            try await check(.PUT, "me/modules", nil, ["modules": ["reports": true]])
            // Work models and time.
            let model = try await self.contractCheck(app, admin, document, .POST, template: "work-models", path: "work-models", body: modelBody("2026-01-01"), status: .created, problems: &problems)
            let modelId = (try? resourceID(model)) ?? "missing"
            try await check(.GET, "work-models")
            try await check(.GET, "work-models/{id}", "work-models/" + modelId)
            try await check(.GET, "places")
            let segment = try await self.contractCheck(app, admin, document, .POST, template: "time/segments", path: "time/segments",
                                                       body: segmentBody("2026-10-12T06:07:00Z", "2026-10-12T10:00:00Z"), status: .created, problems: &problems)
            let segmentId = (try? resourceID(segment)) ?? "missing"
            try await check(.GET, "time/segments/{id}", "time/segments/" + segmentId)
            try await check(.GET, "time/days", "time/days?from=2026-10-12&to=2026-10-13")
            try await check(.GET, "time/days/{date}", "time/days/2026-10-12")
            try await check(.GET, "time/timer")
            try await check(.GET, "time/account")
            try await check(.GET, "time/suggestions")
            // Absences, vacation, plan, calendar.
            let absence = try await self.contractCheck(app, admin, document, .POST, template: "absences", path: "absences", body: absenceBody("2026-10-19", "2026-10-20"), status: .created, problems: &problems)
            let absenceId = (try? resourceID(absence)) ?? "missing"
            try await check(.GET, "absences", "absences?from=2026-10-01&to=2026-10-31")
            try await check(.GET, "absences/{id}", "absences/" + absenceId)
            try await check(.GET, "vacation/settings")
            try await check(.PUT, "vacation/settings", nil, ["region": "DE-ST", "annualEntitlementHalfDays": 60, "carryOverByYear": ["2026": 8], "carryOverExpiry": "03-31"])
            try await check(.GET, "vacation/balance", "vacation/balance?year=2026")
            try await check(.POST, "vacation/adjustments", nil, ["date": "2026-10-01", "halfDays": 2, "reason": "Adjustment"], .created)
            try await check(.GET, "vacation/entries", "vacation/entries?year=2026")
            try await check(.GET, "plan/days", "plan/days?from=2026-10-12&to=2026-10-18")
            try await check(.GET, "calendar/holidays", "calendar/holidays?year=2026&region=DE-ST")
            try await check(.GET, "shares")
            try await check(.GET, "shares/incoming")
            // Reports.
            let field = try await self.contractCheck(app, admin, document, .POST, template: "reports/learning-fields", path: "reports/learning-fields", body: ["number": 3, "name": "Netzwerke"], status: .created, problems: &problems)
            let fieldId = (try? resourceID(field)) ?? "missing"
            try await check(.GET, "reports/learning-fields")
            let entry = try await self.contractCheck(app, admin, document, .POST, template: "reports/entries", path: "reports/entries",
                                                     body: ["date": "2026-10-12", "learningField": "Netzwerke", "learningFieldId": fieldId, "durationSeconds": 3600, "notes": "Subnetting"], status: .created, problems: &problems)
            let entryId = (try? resourceID(entry)) ?? "missing"
            try await check(.GET, "reports/weeks/{year}/{week}", "reports/weeks/2026/42")
            try await check(.GET, "reports/sources", "reports/sources?year=2026&week=42")
            // Transfer, notifications, tokens, storage.
            try await check(.GET, "import-templates")
            try await check(.GET, "notifications")
            try await check(.GET, "notifications/settings")
            try await check(.GET, "me/api-tokens")
            try await check(.GET, "me/device-tokens")
            try await check(.GET, "me/oauth-grants")
            try await check(.GET, "me/identities")
            try await check(.GET, "me/recovery")
            try await check(.GET, "me/push-subscriptions")
            try await check(.GET, "me/push-devices")
            // Account administration.
            try await check(.GET, "admin/accounts")
            try await check(.GET, "admin/accounts", nil, nil, .forbidden, as: member)
            try await check(.PATCH, "admin/accounts/{id}", "admin/accounts/" + memberId, ["state": "disabled"])
            try await check(.PATCH, "admin/accounts/{id}", "admin/accounts/" + memberId, ["state": "active"])
            try await check(.GET, "admin/invitations")
            try await check(.GET, "admin/modules")
            try await check(.GET, "admin/storage")
            // File downloads use the documented media types.
            for (template, path, expected) in [("export/time", "export/time?from=2026-10-12&to=2026-10-13&format=csv", "text/csv"),
                                               ("export/time", "export/time?from=2026-10-12&to=2026-10-13&format=pdf", "application/pdf"),
                                               ("me/export", "me/export", "application/zip")] {
                var head = self.headers(admin)
                head.replaceOrAdd(name: .accept, value: "*/*")
                let response = try await app.testable().sendRequest(.GET, "/api/v1/" + path, headers: head)
                let documented = (((document["paths"] as? [String: Any])?["/api/v1/" + template] as? [String: Any])?["get"] as? [String: Any])
                    .flatMap { ($0["responses"] as? [String: Any])?["200"] as? [String: Any] }.flatMap { $0["content"] as? [String: Any] }?.keys.sorted() ?? []
                let type = response.headers.first(name: .contentType)?.split(separator: ";").first.map(String.init) ?? ""
                if response.status != .ok { problems.append("GET \(path): status \(response.status.code)") }
                else if type != expected || !documented.contains(type) { problems.append("GET \(path): content type \(type), expected \(expected) of \(documented)") }
                if response.headers.first(name: .contentDisposition)?.hasPrefix("attachment") != true { problems.append("GET \(path): missing attachment Content-Disposition") }
            }
            // Public probes: /health follows the Health schema.
            let health = try await app.testable().sendRequest(.GET, "/health")
            if let json = try? JSONSchemaValidator.parse(Data(health.body.readableBytesView)) {
                for issue in JSONSchemaValidator(document: document, reportUndeclaredProperties: true).validate(json, against: ["$ref": "#/components/schemas/Health"]) { problems.append("GET /health: \(issue)") }
            } else { problems.append("GET /health: body is not JSON") }
            // Error bodies share the documented Error schema.
            // G1 groups module: owner and public shapes (ADR-0033).
            let groupPoll = try self.object(await self.api(app, admin, .POST, "groups/polls", ["title": "T", "kind": "date", "choiceMode": "multi", "timeZone": "Europe/Berlin",
                "options": [["date": "2027-03-01", "startTime": "18:00", "endTime": "19:00"], ["date": "2027-03-02"]]], .created))
            let pollId = try XCTUnwrap(groupPoll["id"] as? String), pollToken = try XCTUnwrap(groupPoll["token"] as? String)
            let optionIds = self.gArray(groupPoll["options"]).compactMap { $0["id"] as? String }
            try await self.contractCheck(app, admin, document, .GET, template: "groups/polls", path: "groups/polls", problems: &problems)
            try await self.contractCheck(app, admin, document, .GET, template: "groups/polls/{id}", path: "groups/polls/" + pollId, problems: &problems)
            try await self.contractCheck(app, nil, document, .GET, template: "public/groups/{token}", path: "public/groups/" + pollToken, problems: &problems)
            let voted = try await self.contractCheck(app, nil, document, .POST, template: "public/groups/{token}/votes", path: "public/groups/\(pollToken)/votes",
                body: ["name": "Anna", "answers": [["optionId": optionIds[0], "answer": "yes"], ["optionId": optionIds[1], "answer": "maybe"]]], status: .created, problems: &problems)
            _ = voted
            try await self.contractCheck(app, nil, document, .GET, template: "public/groups/{token}", path: "public/groups/" + pollToken, problems: &problems)
            try await self.contractCheck(app, admin, document, .POST, template: "groups/polls/{id}/rotate-token", path: "groups/polls/\(pollId)/rotate-token", problems: &problems)
            try await self.contractCheck(app, admin, document, .POST, template: "groups/polls/{id}/close", path: "groups/polls/\(pollId)/close", problems: &problems)
            let groupCatalog = try self.object(await self.api(app, admin, .POST, "groups/catalogs", ["name": "K", "items": [["name": "Döner", "priceCents": 650]]], .created))
            let catalogId = try XCTUnwrap(groupCatalog["id"] as? String)
            try await self.contractCheck(app, admin, document, .GET, template: "groups/catalogs", path: "groups/catalogs", problems: &problems)
            try await self.contractCheck(app, admin, document, .GET, template: "groups/catalogs/{id}", path: "groups/catalogs/" + catalogId, problems: &problems)
            let groupOrder = try self.object(await self.api(app, admin, .POST, "groups/orders", ["title": "Dönerstag", "catalogId": catalogId], .created))
            let orderId = try XCTUnwrap(groupOrder["id"] as? String), orderToken = try XCTUnwrap(groupOrder["token"] as? String)
            let groupEntry = try await self.contractCheck(app, nil, document, .POST, template: "public/groups/{token}/entries", path: "public/groups/\(orderToken)/entries",
                body: ["name": "Bob", "item": "Döner", "priceCents": 650, "quantity": 2], status: .created, problems: &problems)
            let groupEntryId = try XCTUnwrap(((try self.object(groupEntry))["entry"] as? [String: Any])?["id"] as? String)
            try await self.contractCheck(app, nil, document, .POST, template: "public/groups/{token}/entries/{entryId}/take", path: "public/groups/\(orderToken)/entries/\(groupEntryId)/take",
                body: ["name": "Cleo"], status: .created, problems: &problems)
            try await self.contractCheck(app, nil, document, .GET, template: "public/groups/{token}", path: "public/groups/" + orderToken, problems: &problems)
            try await self.contractCheck(app, admin, document, .GET, template: "groups/orders", path: "groups/orders", problems: &problems)
            try await self.contractCheck(app, admin, document, .GET, template: "groups/orders/{id}", path: "groups/orders/" + orderId, problems: &problems)
            try await self.contractCheck(app, admin, document, .GET, template: "groups/orders/suggestions", path: "groups/orders/suggestions", problems: &problems)
            try await self.contractCheck(app, nil, document, .GET, template: "public/groups/{token}", path: "public/groups/" + String(repeating: "Z", count: 43), status: .notFound, problems: &problems)
            try await self.contractCheck(app, nil, document, .GET, template: "work-models", path: "work-models", status: .unauthorized, problems: &problems)
            try await check(.GET, "work-models/{id}", "work-models/" + UUID().uuidString, nil, .notFound)
        }
        XCTAssertEqual(problems, [], "Responses deviating from contracts/openapi.yaml")
    }
}
