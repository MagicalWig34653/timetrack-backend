import Foundation
import Fluent
import Vapor
import ZIPFoundation

/// `GET /me/export`: a ZIP with the caller's own data as JSON, CSV for the tabular parts, and the attachment files (ADR-0016).
/// Never contains credentials, token hashes, push keys, other accounts' data or incoming shares.
struct AccountExportService: Sendable {
    let auth: AuthService
    let db: any Database
    let storage: StorageService

    /// Attachment bytes beyond this budget are listed in the manifest as not included instead of exhausting memory.
    static let attachmentBudgetBytes = 256 * 1024 * 1024

    typealias Row = [String: JSONValue]

    func archive(_ context: AuthContext, now: Date = Date()) async throws -> (data: Data, fileName: String) {
        // Read-only: the session middleware verified the credentials in this request (S1b).
        try context.normal()
        let account = context.account, id = try account.requireID()
        let zip = try Archive(accessMode: .create)
        func add(_ path: String, _ data: Data) throws {
            try zip.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), modificationDate: now, compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        var counts: [String: JSONValue] = [:]
        func table(_ name: String, _ rows: [Row], csv columns: [String]? = nil) throws {
            counts[name] = .number(Double(rows.count))
            try add("\(name).json", try Self.json(.array(rows.map(JSONValue.object))))
            if let columns { try add("\(name).csv", Self.csv(rows, columns)) }
        }

        try add("account.json", try Self.json(.object([
            "id": .string(id.uuidString), "handle": .string(account.handle), "displayName": .string(account.displayName),
            "email": account.email.map(JSONValue.string) ?? .null, "role": .string(account.role.rawValue), "createdAt": Self.iso(account.createdAt),
        ])))

        try add("preferences.json", try Self.json(try Self.value(account.preferences ?? .defaults)))

        let segments = try await SegmentRecord.query(on: db).filter(\.$accountId == id).sort(\.$startedAt).all()
        try table("time-entries", segments.map { s in
            ["id": .string(s.id?.uuidString ?? ""), "kind": .string(s.kind), "rawStartedAt": Self.iso(s.rawStartedAt), "rawEndedAt": Self.iso(s.rawEndedAt),
             "startedAt": Self.iso(s.startedAt), "endedAt": Self.iso(s.endedAt), "placeId": Self.uuid(s.placeId), "source": .string(s.source),
             "note": Self.opt(s.note), "voidedAt": Self.iso(s.voidedAt), "voidReason": Self.opt(s.voidReason),
             "needsReview": .bool(s.needsReview), "version": .number(Double(s.version))]
        }, csv: ["id", "kind", "rawStartedAt", "rawEndedAt", "startedAt", "endedAt", "placeId", "source", "note", "voidedAt", "voidReason", "needsReview", "version"])
        let revisions = try await RevisionRecord.query(on: db).filter(\.$accountId == id).sort(\.$createdAt).all()
        try table("time-entry-revisions", try revisions.map { r in
            ["id": .string(r.id?.uuidString ?? ""), "segmentId": .string(r.segmentId.uuidString), "reason": .string(r.reason),
             "createdAt": Self.iso(r.createdAt), "before": try Self.value(r.before), "after": try Self.value(r.after)]
        })
        let absences = try await AbsenceRecord.query(on: db).filter(\.$accountId == id).sort(\.$startDate).all()
        try table("absences", absences.map { a in
            ["id": .string(a.id?.uuidString ?? ""), "kind": .string(a.kind), "startDate": .string(a.startDate), "endDate": .string(a.endDate),
             "halfDayStart": .bool(a.halfDayStart), "halfDayEnd": .bool(a.halfDayEnd), "status": .string(a.status), "note": Self.opt(a.note),
             "documentStatus": .string(a.documentStatus), "documentSubmittedOn": Self.opt(a.documentSubmittedOn),
             "documentReferenceStart": Self.opt(a.documentReferenceStart), "documentReferenceEnd": Self.opt(a.documentReferenceEnd),
             "createdAt": Self.iso(a.createdAt), "updatedAt": Self.iso(a.updatedAt)]
        }, csv: ["id", "kind", "startDate", "endDate", "halfDayStart", "halfDayEnd", "status", "note", "documentStatus", "documentSubmittedOn", "documentReferenceStart", "documentReferenceEnd"])
        let attachments = try await AbsenceAttachmentRecord.query(on: db).filter(\.$accountId == id).all()
        try table("absence-attachments", attachments.map { ["id": .string($0.id?.uuidString ?? ""), "absenceId": .string($0.absenceId.uuidString), "fileId": .string($0.fileId.uuidString)] })
        let entries = try await ReportEntryRecord.query(on: db).filter(\.$accountId == id).sort(\.$date).all()
        try table("report-entries", entries.map { e in
            ["id": .string(e.id?.uuidString ?? ""), "date": .string(e.date), "learningField": .string(e.learningFieldName),
             "durationSeconds": .number(Double(e.durationSeconds)), "notes": .string(e.notes), "draft": .bool(e.draft),
             "createdAt": Self.iso(e.createdAt), "updatedAt": Self.iso(e.updatedAt)]
        }, csv: ["id", "date", "learningField", "durationSeconds", "notes", "draft", "createdAt", "updatedAt"])
        let fields = try await LearningFieldRecord.query(on: db).filter(\.$accountId == id).sort(\.$sortOrder).all()
        try table("report-learning-fields", fields.map { ["id": .string($0.id?.uuidString ?? ""), "number": $0.number.map { .number(Double($0)) } ?? .null, "name": .string($0.name), "sortOrder": .number(Double($0.sortOrder))] })
        let weeks = try await ReportWeekStatusRecord.query(on: db).filter(\.$accountId == id).all()
        try table("report-week-status", weeks.map { ["isoYear": .number(Double($0.isoYear)), "isoWeek": .number(Double($0.isoWeek)), "status": .string($0.status)] })
        let sources = try await ReportSourceRecord.query(on: db).filter(\.$accountId == id).all()
        try table("report-sources", sources.map { ["isoYear": .number(Double($0.isoYear)), "isoWeek": .number(Double($0.isoWeek)), "date": Self.opt($0.date), "note": Self.opt($0.note), "fileId": Self.uuid($0.fileId)] })
        let models = try await WorkModelRecord.query(on: db).filter(\.$accountId == id).sort(\.$validFrom).all()
        try table("work-models", try models.map { ["id": .string($0.id?.uuidString ?? ""), "validFrom": .string($0.validFrom), "validTo": Self.opt($0.validTo), "model": try Self.value($0.payload)] })
        let places = try await PlaceRecord.query(on: db).filter(\.$accountId == id).all()
        try table("places", try places.map { ["id": .string($0.id?.uuidString ?? ""), "place": try Self.value($0.payload)] })
        let days = try await DayPreferenceRecord.query(on: db).filter(\.$accountId == id).sort(\.$date).all()
        try table("day-preferences", days.map { ["date": .string($0.date), "mark": .string($0.mark), "creditSeconds": $0.creditSeconds.map { .number(Double($0)) } ?? .null,
                                                  "skipFixedBreaks": .bool($0.skipFixedBreaks), "note": Self.opt($0.note)] })
        let adjustments = try await AdjustmentRecord.query(on: db).filter(\.$accountId == id).sort(\.$date).all()
        try table("balance-adjustments", adjustments.map { ["kind": .string($0.kind), "date": .string($0.date), "seconds": .number(Double($0.seconds)), "reason": .string($0.reason), "opening": $0.opening.map { .number(Double($0)) } ?? .null] })
        let vacation = try await VacationSettingsRecord.query(on: db).filter(\.$accountId == id).all()
        try table("vacation-settings", vacation.map { ["region": .string($0.region), "annualEntitlementHalfDays": .number(Double($0.annualEntitlementHalfDays)),
                                                         "carryOver": .object($0.carryOver.mapValues { .number(Double($0)) }), "carryOverExpiry": Self.opt($0.carryOverExpiry)] })
        let vacationAdjustments = try await VacationAdjustmentRecord.query(on: db).filter(\.$accountId == id).sort(\.$date).all()
        try table("vacation-adjustments", vacationAdjustments.map { ["date": .string($0.date), "halfDays": .number(Double($0.halfDays)), "reason": .string($0.reason), "createdAt": Self.iso($0.createdAt)] })
        let calendar = try await CustomCalendarDayRecord.query(on: db).filter(\.$accountId == id).sort(\.$startDate).all()
        try table("calendar-days", calendar.map { ["kind": .string($0.kind), "startDate": .string($0.startDate), "endDate": .string($0.endDate), "name": .string($0.name)] })
        let plan = try await PlanDayRecord.query(on: db).filter(\.$accountId == id).sort(\.$date).all()
        try table("plan-days", plan.map { ["date": .string($0.date), "mode": .string($0.mode), "placeId": Self.uuid($0.placeId), "note": Self.opt($0.note),
                                          "plannedStart": Self.opt($0.plannedStart), "plannedEnd": Self.opt($0.plannedEnd),
                                          "plannedBreakMinutes": $0.plannedBreakMinutes.map { JSONValue.number(Double($0)) } ?? .null] })
        // Only the caller's own outgoing shares; the plans of others that are shared with the caller are not part of this account's data.
        let shares = try await ShareRecord.query(on: db).filter(\.$ownerId == id).sort(\.$createdAt).all()
        var shareRows: [Row] = []
        for share in shares {
            let handle = try await Account.find(share.recipientId, on: db)?.handle
            shareRows.append(["recipientHandle": Self.opt(handle), "scopes": .object(["plan": .bool(share.scopePlan), "actual": .bool(share.scopeActual), "vacation": .bool(share.scopeVacation)]),
                              "createdAt": Self.iso(share.createdAt), "revokedAt": Self.iso(share.revokedAt)])
        }
        try table("shares-outgoing", shareRows)
        if let settings = try await NotificationSettingsRecord.query(on: db).filter(\.$accountId == id).first() {
            try add("notification-settings.json", try Self.json(try Self.value(settings.settings)))
        }

        // Attachment files. Anything that cannot be included is listed, never silently dropped.
        let files = try await StoredFileRecord.query(on: db).filter(\.$accountId == id).filter(\.$state == FileState.stored.rawValue).sort(\.$createdAt).all()
        var fileRows: [Row] = [], budget = Self.attachmentBudgetBytes
        for file in files {
            let fileId = try file.requireID()
            var row: Row = ["id": .string(fileId.uuidString), "name": .string(file.name), "contentType": .string(file.contentType), "size": .number(Double(file.size)),
                            "sha256": .string(file.sha256), "createdAt": Self.iso(file.createdAt)]
            if file.size > budget { row["included"] = .bool(false); row["reason"] = .string("export_size_limit") }
            else if let data = try? await storage.download(context, id: fileId).data {
                let path = "files/\(fileId.uuidString.lowercased())-\(file.name.replacingOccurrences(of: "/", with: "_"))"
                try add(path, data); budget -= data.count
                row["included"] = .bool(true); row["path"] = .string(path)
            } else { row["included"] = .bool(false); row["reason"] = .string("storage_unavailable") }
            fileRows.append(row)
        }
        try table("files", fileRows)

        try add("manifest.json", try Self.json(.object([
            "format": .string("timetrack-account-export"), "version": .number(1), "generatedAt": Self.iso(now),
            "counts": .object(counts),
            "notIncluded": .array(["credentials, sessions and tokens", "push subscriptions", "import job files", "plans shared by other accounts"].map(JSONValue.string)),
        ])))
        guard let data = zip.data else { throw APIError(.internalServerError, "not_ready") }
        let stamp = ISO8601DateFormatter().string(from: now).prefix(10)
        return (data, "timetrack-export-\(account.handle)-\(stamp).zip")
    }

    // MARK: Encoding helpers

    static func iso(_ date: Date?) -> JSONValue {
        guard let date else { return .null }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .string(formatter.string(from: date))
    }
    static func opt(_ text: String?) -> JSONValue { text.map(JSONValue.string) ?? .null }
    static func uuid(_ id: UUID?) -> JSONValue { id.map { .string($0.uuidString) } ?? .null }
    static func value<T: Encodable>(_ item: T) throws -> JSONValue {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        return try decoder.decode(JSONValue.self, from: encoder.encode(item))
    }
    static func json(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    static func csv(_ rows: [Row], _ columns: [String]) -> Data {
        var out = CSVWriter.line(columns.map { .text($0) })
        for row in rows {
            out += CSVWriter.line(columns.map { column in
                switch row[column] ?? .null {
                case .null: return .empty
                case .string(let text): return .text(text)
                case .bool(let flag): return .text(flag ? "true" : "false")
                case .number(let number): return .text(number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number))
                default: return .empty
                }
            })
        }
        return Data(out.utf8)
    }
}
