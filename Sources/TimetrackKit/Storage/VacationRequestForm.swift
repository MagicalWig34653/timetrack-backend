import Foundation
import Fluent
import Vapor

// B7: one vacation request form template (employer PDF) and its field mapping per account (ADR-0026).
// The PDF is an ordinary stored file (storage rules DB/S3/local); this table only binds it to the account and keeps the mapping.

enum VacationRequestFormLimits {
    static let maxFileBytes = 5 * 1024 * 1024
    static let maxMappingBytes = 64 * 1024
    static let defaultFileName = "Urlaubsantrag.pdf"
}

enum VacationRequestFormErrors {
    static let noTemplate = APIError(.conflict, "no_template")
    static let mappingTooLarge = APIError(.payloadTooLarge, "mapping_too_large")
}

final class VacationRequestFormRecord: Model, @unchecked Sendable {
    static let schema = "vacation_request_forms"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountId: UUID
    /// `stored_files.id` of the template PDF. No foreign key: the file may be removed (and retried) independently.
    @Field(key: "file_id") var fileId: UUID
    /// Mapping as JSON text (opaque to the server, at most 64 KB).
    @Field(key: "mapping") var mappingText: String
    var mapping: JSONValue {
        get { (try? JSONDecoder().decode(JSONValue.self, from: Data(mappingText.utf8))) ?? .object([:]) }
        set { mappingText = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "{}" }
    }
    @Field(key: "updated_at") var updatedAt: Date
    init() {}
}

struct CreateVacationRequestForms: AsyncMigration {
    let name = "b7.create_vacation_request_forms"
    func prepare(on db: any Database) async throws {
        try await db.schema("vacation_request_forms").id()
            .field("account_id", .uuid, .required, .references("accounts", "id", onDelete: .restrict))
            .field("file_id", .uuid, .required)
            .field("mapping", .sql(unsafeRaw: "LONGTEXT"), .required)
            .field("updated_at", .datetime, .required)
            .unique(on: "account_id")
            .create()
    }
    func revert(on db: any Database) async throws { try await db.schema("vacation_request_forms").delete() }
}

/// Response of `GET/PUT /vacation/request-form...`. Absent values are explicit `null`s.
struct VacationRequestFormDTO: Content, Equatable {
    var exists: Bool
    var fileName: String?
    var sizeBytes: Int?
    var mapping: JSONValue?
    var updatedAt: Date?

    static let none = VacationRequestFormDTO(exists: false, fileName: nil, sizeBytes: nil, mapping: nil, updatedAt: nil)

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(exists, forKey: .exists); try c.encode(fileName, forKey: .fileName); try c.encode(sizeBytes, forKey: .sizeBytes)
        try c.encode(mapping, forKey: .mapping); try c.encode(updatedAt, forKey: .updatedAt)
    }
    enum CodingKeys: String, CodingKey { case exists, fileName, sizeBytes, mapping, updatedAt }
}

extension StorageService {
    private func formDTO(_ tx: any Database, account: UUID) async throws -> VacationRequestFormDTO {
        guard let record = try await VacationRequestFormRecord.query(on: tx).filter(\.$accountId == account).first(),
              let file = try await StoredFileRecord.query(on: tx).filter(\.$id == record.fileId).filter(\.$accountId == account)
                  .filter(\.$state == FileState.stored.rawValue).first() else { return .none }
        return VacationRequestFormDTO(exists: true, fileName: file.name, sizeBytes: file.size, mapping: record.mapping, updatedAt: record.updatedAt)
    }

    func requestForm(_ context: AuthContext) async throws -> VacationRequestFormDTO {
        try await readSession(context) { tx, account in try await formDTO(tx, account: account) }
    }

    /// Stores (or replaces) the template PDF. The previous file is removed afterwards; the mapping is kept.
    func putRequestFormFile(_ context: AuthContext, filename: String, data: Data) async throws -> VacationRequestFormDTO {
        guard !data.isEmpty else { throw APIError.invalid }
        guard data.count <= VacationRequestFormLimits.maxFileBytes else { throw StorageErrors.tooLarge }
        guard data.starts(with: Array("%PDF-".utf8)) else { throw APIError.invalid }
        var name = FilenameSanitizer.sanitize(filename, fallbackExtension: "pdf")
        if (name as NSString).pathExtension.lowercased() != "pdf" { name += ".pdf" }
        let meta = try await upload(context, filename: name, declaredType: "application/pdf", data: data)
        let previous: UUID?
        do {
            previous = try await session(context) { tx, account -> UUID? in
                let now = Date()
                if let record = try await VacationRequestFormRecord.query(on: tx).filter(\.$accountId == account).first() {
                    let old = record.fileId
                    record.fileId = meta.id; record.updatedAt = now
                    try await record.update(on: tx)
                    return old
                }
                let record = VacationRequestFormRecord()
                record.accountId = account; record.fileId = meta.id; record.mapping = .object([:]); record.updatedAt = now
                try await record.create(on: tx)
                return nil
            }
        } catch {
            try? await delete(context, id: meta.id)
            throw error
        }
        if let previous { try? await delete(context, id: previous) }
        return try await requestForm(context)
    }

    func putRequestFormMapping(_ context: AuthContext, mapping: JSONValue) async throws -> VacationRequestFormDTO {
        guard case .object = mapping else { throw APIError.invalid }
        try await session(context) { tx, account in
            guard let record = try await VacationRequestFormRecord.query(on: tx).filter(\.$accountId == account).first(),
                  try await StoredFileRecord.query(on: tx).filter(\.$id == record.fileId).filter(\.$state == FileState.stored.rawValue).count() == 1
            else { throw VacationRequestFormErrors.noTemplate }
            record.mapping = mapping; record.updatedAt = Date()
            try await record.update(on: tx)
        }
        return try await requestForm(context)
    }

    func requestFormFile(_ context: AuthContext) async throws -> (file: StoredFileRecord, data: Data) {
        let id = try await readSession(context) { tx, account -> UUID in
            guard let record = try await VacationRequestFormRecord.query(on: tx).filter(\.$accountId == account).first() else { throw APIError.missing }
            return record.fileId
        }
        return try await download(context, id: id)
    }

    /// Idempotent: nothing stored is not an error.
    func deleteRequestForm(_ context: AuthContext) async throws {
        let fileId = try await session(context) { tx, account -> UUID? in
            guard let record = try await VacationRequestFormRecord.query(on: tx).filter(\.$accountId == account).first() else { return nil }
            let id = record.fileId
            try await record.delete(on: tx)
            return id
        }
        if let fileId { try? await delete(context, id: fileId) }
    }
}

func registerVacationRequestFormRoutes(_ api: any RoutesBuilder, service: @escaping @Sendable (Request) -> StorageService) {
    /// Streams the body and aborts as soon as the limit is exceeded; nothing beyond it is buffered.
    @Sendable func collect(_ req: Request, limit: Int, error: APIError) async throws -> Data {
        if let length = req.headers.first(name: .contentLength).flatMap(Int.init), length > limit { throw error }
        do { _ = try await req.body.collect(max: limit).get() } catch { throw error }
        guard var buffer = req.body.data, let data = buffer.readData(length: buffer.readableBytes) else { return Data() }
        return data
    }
    api.get("vacation", "request-form") { req async throws -> Response in
        try timeResponse(await service(req).requestForm(req.authContext))
    }
    api.on(.PUT, "vacation", "request-form", "file", body: .stream) { req async throws -> Response in
        let context = try req.authContext
        guard req.headers.contentType?.type == "application", req.headers.contentType?.subType == "pdf" else { throw StorageErrors.unsupported }
        var name = VacationRequestFormLimits.defaultFileName
        if let raw = req.headers.first(name: "X-File-Name") {
            guard let decoded = raw.removingPercentEncoding, !decoded.isEmpty else { throw APIError.invalid }
            name = decoded
        }
        let data = try await collect(req, limit: VacationRequestFormLimits.maxFileBytes, error: StorageErrors.tooLarge)
        return try timeResponse(await service(req).putRequestFormFile(context, filename: name, data: data))
    }
    api.on(.PUT, "vacation", "request-form", "mapping", body: .stream) { req async throws -> Response in
        let context = try req.authContext
        let data = try await collect(req, limit: VacationRequestFormLimits.maxMappingBytes, error: VacationRequestFormErrors.mappingTooLarge)
        guard let mapping = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw APIError.invalid }
        return try timeResponse(await service(req).putRequestFormMapping(context, mapping: mapping))
    }
    api.get("vacation", "request-form", "file") { req async throws -> Response in
        let (file, data) = try await service(req).requestFormFile(req.authContext)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/pdf")
        headers.replaceOrAdd(name: .contentDisposition, value: FilenameSanitizer.contentDisposition(file.name))
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        headers.replaceOrAdd(name: .cacheControl, value: "private, no-store")
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }
    api.delete("vacation", "request-form") { req async throws -> Response in
        try await service(req).deleteRequestForm(req.authContext); return Response(status: .noContent)
    }
}
