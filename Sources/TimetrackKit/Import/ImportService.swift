import Foundation
import Fluent
import Crypto
import Vapor

private extension Array {
    func chunks(of size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

struct ImportEvaluation: Sendable {
    var preview: ImportPreviewDTO
    var accepted: [ImportCandidate]
    var duplicates: Int
    var errorRows: Int
    var absences: [WorktimeAbsence] = []
    var customDays: [WorktimeHoliday] = []
}

private struct SegmentKey: Hashable { let start: Date; let end: Date; let kind: String }

/// Sorted half-open intervals with a running maximum of ends: answers "does [s, e) overlap anything?".
private struct IntervalIndex {
    private var starts: [Date] = [], prefixMaxEnd: [Date] = []
    init(_ intervals: [(start: Date, end: Date)]) {
        let sorted = intervals.sorted { $0.start < $1.start }
        starts = sorted.map(\.start)
        var running = Date.distantPast
        prefixMaxEnd = sorted.map { running = Swift.max(running, $0.end); return running }
    }
    func overlaps(_ start: Date, _ end: Date) -> Bool {
        var low = 0, high = starts.count
        while low < high { let mid = (low + high) / 2; if starts[mid] < end { low = mid + 1 } else { high = mid } }
        return low > 0 && prefixMaxEnd[low - 1] > start
    }
}

/// Mutually disjoint accepted intervals; insertion keeps them sorted.
private struct DisjointIndex {
    private var starts: [Date] = [], ends: [Date] = []
    func overlaps(_ start: Date, _ end: Date) -> Bool {
        var low = 0, high = starts.count
        while low < high { let mid = (low + high) / 2; if starts[mid] <= start { low = mid + 1 } else { high = mid } }
        if low > 0, ends[low - 1] > start { return true }
        return low < starts.count && starts[low] < end
    }
    mutating func insert(_ start: Date, _ end: Date) {
        var low = 0, high = starts.count
        while low < high { let mid = (low + high) / 2; if starts[mid] <= start { low = mid + 1 } else { high = mid } }
        starts.insert(start, at: low); ends.insert(end, at: low)
    }
}

struct ImportService: Sendable {
    let scope: TimeServices
    var now: @Sendable () -> Date = { Date() }
    private var db: any Database { scope.db }
    private var accountId: UUID { scope.accountId }
    static let notReady = APIError(.conflict, "import_not_ready")

    // MARK: Jobs

    func job(_ id: UUID) async throws -> ImportJobRecord {
        guard let row = try await ImportJobRecord.query(on: db).filter(\.$accountId == accountId).filter(\.$id == id).first() else { throw APIError.missing }
        return row
    }

    func upload(filename rawName: String, data: Data, workbook: ImportWorkbook) async throws -> ImportJobDTO {
        let open = try await ImportJobRecord.query(on: db).filter(\.$accountId == accountId)
            .group(.or) { $0.filter(\.$status == "uploaded").filter(\.$status == "mapped") }.count()
        guard open < ImportLimits.maxOpenJobs else { throw APIError(.conflict, "conflict") }
        let job = ImportJobRecord()
        job.id = UUID(); job.accountId = accountId; job.filename = Self.sanitize(filename: rawName); job.kind = workbook.kind
        job.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        job.detectedProfile = try WorktimeWorkbook.detects(workbook) ? "worktime_workbook" : "generic"
        job.status = "uploaded"; job.sheets = workbook.sheetNames; job.createdAt = Date()
        try await job.create(on: db)
        let file = ImportFileRecord()
        file.id = UUID(); file.accountId = accountId; file.jobId = job.id!; file.size = data.count; file.bytes = data
        try await file.create(on: db)
        return try .init(job)
    }

    static func sanitize(filename: String) -> String {
        let last = filename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = String(String.UnicodeScalarView(last.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        let limited = String(String.UnicodeScalarView(cleaned.unicodeScalars.prefix(120)))
        return limited.isEmpty ? "import" : limited
    }

    func discard(_ id: UUID) async throws {
        let row = try await job(id)
        guard ["uploaded", "mapped"].contains(row.status) else { throw Self.notReady }
        try await ImportFileRecord.query(on: db).filter(\.$jobId == id).delete()
        try await ImportMappingRecord.query(on: db).filter(\.$jobId == id).delete()
        try await row.delete(on: db)
    }

    private func file(_ row: ImportJobRecord) async throws -> Data {
        guard ["uploaded", "mapped"].contains(row.status),
              let file = try await ImportFileRecord.query(on: db).filter(\.$accountId == accountId).filter(\.$jobId == row.requireID()).first() else { throw Self.notReady }
        return file.bytes
    }

    func rawPreview(_ id: UUID, sheet: String?) async throws -> [String: JSONValueBox] {
        let row = try await job(id)
        let workbook = try ImportWorkbook.open(data: try await file(row), filename: row.filename)
        let name = sheet ?? workbook.sheetNames[0]
        guard workbook.sheetNames.contains(name) else { throw APIError.invalid }
        let sheet = try workbook.sheet(name)
        let rows = sheet.rows.prefix(50).map { $0.map { ImportInterpreter.display($0, date1904: sheet.date1904) } }
        return ["sheet": .string(name), "rows": .rows(Array(rows))]
    }

    // MARK: Mapping and evaluation

    func putMapping(_ id: UUID, _ mapping: ImportMapping) async throws -> ImportPreviewDTO {
        try mapping.validate()
        let row = try await job(id)
        guard ["uploaded", "mapped"].contains(row.status) else { throw Self.notReady }
        let evaluation = try await evaluate(data: try await file(row), filename: row.filename, mapping: mapping)
        if let stored = try await ImportMappingRecord.query(on: db).filter(\.$jobId == id).first() {
            stored.mapping = mapping; try await stored.update(on: db)
        } else {
            let stored = ImportMappingRecord(); stored.id = UUID(); stored.accountId = accountId; stored.jobId = id; stored.mapping = mapping
            try await stored.create(on: db)
        }
        row.status = "mapped"; try await row.update(on: db)
        return evaluation.preview
    }

    func evaluate(data: Data, filename: String, mapping: ImportMapping) async throws -> ImportEvaluation {
        let workbook = try ImportWorkbook.open(data: data, filename: filename)
        if mapping.profile == "worktime_workbook" { return try await evaluateWorktime(workbook, mapping: mapping) }
        let sheet = try workbook.sheet(mapping.sheet)
        var places: [String: UUID] = [:]
        for place in try await PlaceRecord.query(on: db).filter(\.$accountId == accountId).all()
            .sorted(by: { ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "") }) where place.payload.archived != true {
            let key = place.payload.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if places[key] == nil, let id = place.id { places[key] = id }
        }
        let outcomes = ImportInterpreter(mapping: mapping, date1904: sheet.date1904, places: places).interpret(sheet.rows)

        let existing = try await SegmentRecord.query(on: db).filter(\.$accountId == accountId).filter(\.$voidedAt == nil).all()
        var keys = Set(existing.compactMap { row in row.endedAt.map { SegmentKey(start: row.startedAt, end: $0, kind: row.kind) } })
        let stored = IntervalIndex(existing.map { ($0.startedAt, $0.endedAt ?? .distantFuture) })
        var accepted = DisjointIndex()

        var errors: [ImportRowError] = [], errorRows = 0, duplicates = 0, summary = 0, total = 0
        var candidates: [ImportCandidate] = []
        for (number, outcome) in outcomes {
            switch outcome {
            case .blank: continue
            case .summary: summary += 1
            case .failed(let code):
                total += 1; errorRows += 1
                if errors.count < ImportLimits.maxErrorsListed { errors.append(.init(row: number, code: code)) }
            case .candidate(var candidate):
                total += 1; candidate.row = number
                let key = SegmentKey(start: candidate.start, end: candidate.end, kind: candidate.kind.rawValue)
                if keys.contains(key) { duplicates += 1; continue }
                if stored.overlaps(candidate.start, candidate.end) || accepted.overlaps(candidate.start, candidate.end) {
                    errorRows += 1
                    if errors.count < ImportLimits.maxErrorsListed { errors.append(.init(row: number, code: "overlap")) }
                    continue
                }
                keys.insert(key); accepted.insert(candidate.start, candidate.end); candidates.append(candidate)
            }
        }
        let sample = candidates.prefix(10).map { ImportSample(date: $0.date.description, startedAt: $0.start, endedAt: $0.end, kind: $0.kind) }
        let preview = ImportPreviewDTO(rows: total, valid: candidates.count, duplicates: duplicates, errors: errors, sample: sample,
                                       skippedSummaryRows: summary, errorCount: errorRows)
        return .init(preview: preview, accepted: candidates, duplicates: duplicates, errorRows: errorRows)
    }

    // MARK: Commit and rollback

    func commit(_ id: UUID, ignoreErrors: Bool) async throws -> ImportResultDTO {
        let row = try await job(id)
        guard row.status == "mapped", let stored = try await ImportMappingRecord.query(on: db).filter(\.$jobId == id).first() else { throw Self.notReady }
        let evaluation = try await evaluate(data: try await file(row), filename: row.filename, mapping: stored.mapping)
        guard evaluation.errorRows == 0 || ignoreErrors else { throw APIError(.conflict, "import_has_errors") }

        let batch = ImportBatchRecord()
        batch.id = UUID(); batch.accountId = accountId; batch.jobId = id; batch.createdAt = Date()
        batch.createdCount = evaluation.accepted.count; batch.skippedCount = evaluation.duplicates + evaluation.errorRows
        try await batch.create(on: db)

        let segments = evaluation.accepted.map { candidate -> SegmentRecord in
            let segment = SegmentRecord()
            segment.id = UUID(); segment.accountId = accountId
            segment.rawStartedAt = candidate.start; segment.rawEndedAt = candidate.end
            segment.startedAt = candidate.start; segment.endedAt = candidate.end
            segment.kind = candidate.kind.rawValue; segment.placeId = candidate.placeId
            segment.source = EngineSegmentSource.imported.rawValue; segment.note = candidate.note
            segment.version = 1; segment.needsReview = false; segment.clientEventId = nil; segment.running = nil; segment.revisions = 0
            return segment
        }
        for chunk in segments.chunks(of: 50) { try await chunk.create(on: db) }
        let links = segments.map { segment -> ImportBatchSegmentRecord in
            let link = ImportBatchSegmentRecord()
            link.id = UUID(); link.accountId = accountId; link.batchId = batch.id!; link.segmentId = segment.id!; link.createdVersion = 1
            return link
        }
        for chunk in links.chunks(of: 50) { try await chunk.create(on: db) }

        try await createWorktimeItems(evaluation, batch: batch.id!)
        row.status = "committed"; row.committedAt = Date(); try await row.update(on: db)
        // The uploaded bytes are no longer needed: the batch and the job keep the hash and the counts.
        try await ImportFileRecord.query(on: db).filter(\.$jobId == id).delete()
        return .init(warnings: evaluation.preview.warnings, absencesCreated: evaluation.absences.count, customDaysCreated: evaluation.customDays.count, batchId: batch.id!, created: batch.createdCount, skipped: batch.skippedCount, conflicts: nil, rolledBack: nil)
    }

    func rollback(_ id: UUID) async throws -> ImportResultDTO {
        let row = try await job(id)
        guard row.status == "committed",
              let batch = try await ImportBatchRecord.query(on: db).filter(\.$accountId == accountId).filter(\.$jobId == id).first(),
              batch.rolledBackAt == nil else { throw Self.notReady }
        let links = try await ImportBatchSegmentRecord.query(on: db).filter(\.$accountId == accountId).filter(\.$batchId == batch.requireID()).all()
        var segments: [SegmentRecord] = []
        for chunk in links.map(\.segmentId).chunks(of: 200) {
            segments += try await SegmentRecord.query(on: db).filter(\.$accountId == accountId).filter(\.$id ~~ chunk).all()
        }
        let versions = Dictionary(links.map { ($0.segmentId, $0.createdVersion) }, uniquingKeysWith: { first, _ in first })
        // Only segments that are still exactly as imported may be withdrawn; anything else blocks the rollback.
        let conflicts = segments.filter { $0.version != versions[$0.id ?? UUID()] || $0.voidedAt != nil }.compactMap(\.id)
            + links.map(\.segmentId).filter { id in !segments.contains { $0.id == id } }
        let typed = try await rollbackWorktimeItems(batch: batch.id!, remove: false) + conflicts.map { ImportTypedConflict(type: "segment", id: $0) }
        guard typed.isEmpty else { throw ImportConflictError(code: "rollback_conflict", conflicts: typed.map(\.id).sorted { $0.uuidString < $1.uuidString }, items: typed) }
        _ = try await rollbackWorktimeItems(batch: batch.id!, remove: true)

        let now = Date()
        var revisions: [RevisionRecord] = []
        for segment in segments {
            let before = try segment.dto()
            segment.voidedAt = now; segment.voidReason = "Import rollback"; segment.running = nil
            segment.version += 1; segment.revisions += 1
            try await segment.update(on: db)
            let revision = RevisionRecord()
            revision.accountId = accountId; revision.segmentId = try segment.requireID()
            revision.before = before; revision.after = try segment.dto(); revision.reason = "Import rollback"; revision.createdAt = now
            revisions.append(revision)
        }
        for chunk in revisions.chunks(of: 50) { try await chunk.create(on: db) }
        batch.rolledBackAt = now; try await batch.update(on: db)
        row.status = "rolled_back"; try await row.update(on: db)
        return .init(batchId: batch.id!, created: 0, skipped: 0, conflicts: [], rolledBack: segments.count)
    }

    // MARK: Templates

    func templates() async throws -> [ImportTemplateDTO] {
        try await ImportTemplateRecord.query(on: db).filter(\.$accountId == accountId).sort(\.$createdAt).all()
            .map { try ImportTemplateDTO(id: $0.requireID(), name: $0.name, mapping: $0.mapping) }
    }

    func createTemplate(name rawName: String, mapping: ImportMapping) async throws -> ImportTemplateDTO {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.unicodeScalars.count <= 80 else { throw APIError.invalid }
        try mapping.validate()
        guard try await ImportTemplateRecord.query(on: db).filter(\.$accountId == accountId).count() < ImportLimits.maxTemplates else { throw APIError(.conflict, "conflict") }
        let row = ImportTemplateRecord()
        row.id = UUID(); row.accountId = accountId; row.name = name; row.mapping = mapping; row.createdAt = Date()
        try await row.create(on: db)
        return .init(id: row.id!, name: name, mapping: mapping)
    }

    func deleteTemplate(_ id: UUID) async throws {
        guard let row = try await ImportTemplateRecord.query(on: db).filter(\.$accountId == accountId).filter(\.$id == id).first() else { throw APIError.missing }
        try await row.delete(on: db)
    }
}

/// Small encodable box for the raw preview response.
enum JSONValueBox: Encodable, Sendable {
    case string(String)
    case rows([[String?]])
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .rows(let value): try container.encode(value)
        }
    }
}
