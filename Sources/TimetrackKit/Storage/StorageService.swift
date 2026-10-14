import Foundation
import Fluent
import FluentSQL
import Crypto
import NIOCore
import Vapor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum StorageErrors {
    static let tooLarge = APIError(.payloadTooLarge, "file_too_large")
    static let unsupported = APIError(.unsupportedMediaType, "unsupported_type")
    static let unavailable = APIError(.serviceUnavailable, "storage_unavailable")
    static let notImplemented = APIError(.notImplemented, "not_implemented")
    static let corrupt = APIError(.internalServerError, "storage_corrupt")
}

/// Per-application knobs. Production uses the defaults; tests replace single members.
struct StorageEnvironment: Sendable {
    /// Base64 key for the S3 secret box; defaults to the process environment variable `STORAGE_SECRET_KEY`.
    var secretKey: @Sendable () -> String? = { ProcessInfo.processInfo.environment["STORAGE_SECRET_KEY"] }
    /// Wraps every resolved adapter (failure injection in tests).
    var decorate: @Sendable (any StorageBackend) -> any StorageBackend = { $0 }
    /// Runs between the object write and the database commit that marks the file `stored`.
    var beforeFinalize: (@Sendable () async throws -> Void)?
    var s3Timeout: TimeAmount = .seconds(30)
}

struct StorageEnvironmentKey: StorageKey { typealias Value = StorageEnvironment }
extension Application {
    var storageEnvironment: StorageEnvironment {
        get { storage[StorageEnvironmentKey.self] ?? StorageEnvironment() }
        set { storage[StorageEnvironmentKey.self] = newValue }
    }
}

enum StorageRules {
    /// First matching rule wins (`maxBytes` inclusive); the last rule has no limit.
    static func select(_ rules: [StorageRule], size: Int) -> StorageBackendKind {
        for rule in rules where rule.maxBytes.map({ size <= $0 }) ?? true { return rule.backend }
        return rules.last?.backend ?? .db
    }
    static func validate(_ rules: [StorageRule]) throws {
        guard (1...StorageLimits.maxRules).contains(rules.count), rules.last?.maxBytes == nil else { throw APIError.invalid }
        var previous = 0
        for rule in rules.dropLast() {
            guard let limit = rule.maxBytes, limit > previous, limit <= StorageLimits.hardMaxUploadBytes else { throw APIError.invalid }
            previous = limit
        }
    }
}

struct StorageService: Sendable {
    let auth: AuthService
    let db: any Database
    let client: any Client
    let env: StorageEnvironment

    // MARK: Sessions and settings

    private func session<T: Sendable>(_ context: AuthContext, admin: Bool = false,
                                      _ operation: @escaping @Sendable (any Database, UUID) async throws -> T) async throws -> T {
        try await auth.transaction(on: db) { tx in
            let current = try await auth.authenticate(context.token, on: tx)
            if admin { try current.admin() } else { try current.normal() }
            return try await operation(tx, current.account.requireID())
        }
    }

    private func settingsRow(_ db: any Database) async throws -> StorageSettingsRecord? {
        try await StorageSettingsRecord.find(StorageSettingsRecord.rowId, on: db)
    }

    func settings(_ context: AuthContext) async throws -> StorageSettingsDTO {
        try await session(context, admin: true) { tx, _ in try await settingsRow(tx).map(StorageSettingsDTO.init) ?? .defaults }
    }

    func putSettings(_ context: AuthContext, _ input: StorageSettingsInput) async throws -> StorageSettingsDTO {
        try StorageRules.validate(input.rules)
        let limit = input.maxUploadBytes ?? StorageLimits.defaultMaxUploadBytes
        guard (1...StorageLimits.hardMaxUploadBytes).contains(limit) else { throw APIError.invalid }
        let usesS3 = input.rules.contains { $0.backend == .s3 }, usesLocal = input.rules.contains { $0.backend == .local }
        let box = SecretBox(base64Key: env.secretKey())
        // S3 credentials can only be stored encrypted; without the server key they are refused.
        if (usesS3 || input.s3 != nil) && box == nil { throw StorageErrors.notImplemented }
        let localPath = input.localPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if usesLocal && localPath == nil { throw APIError.invalid }
        if let localPath { try LocalFSBackend.validateRoot(localPath) }
        if usesS3 && input.s3 == nil { throw APIError.invalid }
        let s3: (endpoint: String, region: String, bucket: String, pathStyle: Bool, keyId: String)?
        if let value = input.s3 {
            guard let endpoint = value.endpoint?.trimmingCharacters(in: .whitespaces).nilIfEmpty, Self.validEndpoint(endpoint),
                  let region = value.region?.trimmingCharacters(in: .whitespaces).nilIfEmpty, region.count <= 64,
                  let bucket = value.bucket?.trimmingCharacters(in: .whitespaces).nilIfEmpty, bucket.count <= 255, !bucket.contains("/"),
                  let keyId = value.accessKeyId?.trimmingCharacters(in: .whitespaces).nilIfEmpty, keyId.count <= 128,
                  (value.secretAccessKey?.count ?? 0) <= 256 else { throw APIError.invalid }
            s3 = (endpoint, region, bucket, value.pathStyle ?? true, keyId)
        } else { s3 = nil }
        let newSecret = input.s3?.secretAccessKey?.nilIfEmpty
        let sealed = try newSecret.map { try box!.seal($0) }
        return try await session(context, admin: true) { tx, _ in
            let row = try await settingsRow(tx) ?? {
                let created = StorageSettingsRecord(); created.id = StorageSettingsRecord.rowId; return created
            }()
            let existed = row.$id.exists
            row.rules = input.rules; row.maxUploadBytes = limit; row.localPath = localPath
            if let s3 {
                row.s3Endpoint = s3.endpoint; row.s3Region = s3.region; row.s3Bucket = s3.bucket; row.s3PathStyle = s3.pathStyle; row.s3AccessKeyId = s3.keyId
                if let sealed { row.s3SecretCiphertext = sealed.ciphertext; row.s3SecretNonce = sealed.nonce }
            } else {
                row.s3Endpoint = nil; row.s3Region = nil; row.s3Bucket = nil; row.s3PathStyle = true; row.s3AccessKeyId = nil
                row.s3SecretCiphertext = nil; row.s3SecretNonce = nil
            }
            if usesS3 && row.s3SecretCiphertext == nil { throw APIError.invalid }
            row.updatedAt = Date()
            if existed { try await row.update(on: tx) } else { try await row.create(on: tx) }
            return StorageSettingsDTO(row)
        }
    }

    static func validEndpoint(_ value: String) -> Bool {
        guard value.count <= 255, let parts = URLComponents(string: value), let scheme = parts.scheme, ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return false }
        return true
    }

    // MARK: Adapters

    /// Resolves an adapter from the current settings. Missing or broken configuration is `storage_unavailable`.
    func backend(_ kind: StorageBackendKind, settings: StorageSettingsRecord?) throws -> any StorageBackend {
        let adapter: any StorageBackend
        switch kind {
        case .db: adapter = DBBackend()
        case .local:
            guard let path = settings?.localPath, !path.isEmpty else { throw StorageErrors.unavailable }
            adapter = LocalFSBackend(root: path)
        case .s3:
            guard let row = settings, let endpoint = row.s3Endpoint, let region = row.s3Region, let bucket = row.s3Bucket, let keyId = row.s3AccessKeyId,
                  let ciphertext = row.s3SecretCiphertext, let nonce = row.s3SecretNonce, let box = SecretBox(base64Key: env.secretKey()),
                  let secret = try? box.open(ciphertext: ciphertext, nonce: nonce) else { throw StorageErrors.unavailable }
            let configuration = S3Configuration(endpoint: endpoint, region: region, bucket: bucket, pathStyle: row.s3PathStyle, accessKeyId: keyId, secretAccessKey: secret)
            adapter = S3Backend(client: S3Client(configuration: configuration, client: client, timeout: env.s3Timeout))
        }
        return env.decorate(adapter)
    }

    // MARK: Upload

    func uploadLimit(_ context: AuthContext) async throws -> Int {
        try await session(context) { tx, _ in try await settingsRow(tx)?.maxUploadBytes ?? StorageLimits.defaultMaxUploadBytes }
    }

    func upload(_ context: AuthContext, filename: String, declaredType: String?, data: Data) async throws -> FileMetaDTO {
        guard !data.isEmpty, let kind = FileTypeSniffer.verify(data: data, filename: filename, declaredMime: declaredType) else { throw StorageErrors.unsupported }
        let name = FilenameSanitizer.sanitize(filename, fallbackExtension: kind.ext)
        let size = data.count
        let sha = SigV4.sha256Hex(data)
        let id = UUID()

        // Step 1: choose the backend by the rules valid now and record the file as pending.
        let (backend, key, owner) = try await session(context) { tx, account -> (any StorageBackend, String, UUID) in
            let settings = try await settingsRow(tx)
            guard size <= (settings?.maxUploadBytes ?? StorageLimits.defaultMaxUploadBytes), size <= StorageLimits.hardMaxUploadBytes else { throw StorageErrors.tooLarge }
            let chosen = StorageRules.select(settings?.rules ?? StorageSettingsDTO.defaults.rules, size: size)
            let adapter = try backend(chosen, settings: settings)
            let row = StoredFileRecord()
            row.id = id; row.accountId = account; row.name = name; row.contentType = kind.mime; row.size = size; row.sha256 = sha
            row.backend = chosen.rawValue; row.storageKey = StorageKeys.make(for: id, kind: chosen); row.state = FileState.pending.rawValue
            row.createdAt = Date(); row.cleanupAttempts = 0
            try await row.create(on: tx)
            return (adapter, row.storageKey, account)
        }

        // Step 2: object write. The database adapter writes inside the finalizing transaction instead.
        if backend.kind != .db {
            do { try await backend.put(key: key, data: data, db: db) }
            catch { await abandon(id, backend: backend, key: key); throw StorageErrors.unavailable }
        }

        // Step 3: commit "stored". Any failure removes the object again.
        do {
            try await env.beforeFinalize?()
            return try await session(context) { tx, account in
                guard account == owner, let row = try await StoredFileRecord.query(on: tx).filter(\.$id == id)
                    .filter(\.$state == FileState.pending.rawValue).first() else { throw StorageErrors.unavailable }
                if backend.kind == .db { try await backend.put(key: key, data: data, db: tx) }
                row.state = FileState.stored.rawValue
                try await row.update(on: tx)
                return try FileMetaDTO(row)
            }
        } catch {
            await abandon(id, backend: backend, key: key)
            throw (error as? APIError) ?? StorageErrors.unavailable
        }
    }

    /// Marks the file `failed` and removes the object on a best-effort basis; leftovers are retried by `cleanup`.
    private func abandon(_ id: UUID, backend: any StorageBackend, key: String) async {
        _ = try? await auth.transaction(on: db) { tx in
            try await StoredFileRecord.query(on: tx).filter(\.$id == id).set(\.$state, to: FileState.failed.rawValue).update()
        }
        if backend.kind != .db { _ = try? await backend.delete(key: key, db: db) }
        else { _ = try? await auth.transaction(on: db) { tx in try await backend.delete(key: key, db: tx) } }
    }

    // MARK: Read

    private func ownedFile(_ tx: any Database, _ account: UUID, _ id: UUID) async throws -> StoredFileRecord {
        guard let row = try await StoredFileRecord.query(on: tx).filter(\.$id == id).filter(\.$accountId == account)
            .filter(\.$state == FileState.stored.rawValue).first() else { throw APIError.missing }
        return row
    }

    func meta(_ context: AuthContext, id: UUID) async throws -> FileMetaDTO {
        try await session(context) { tx, account in try FileMetaDTO(await ownedFile(tx, account, id)) }
    }

    func download(_ context: AuthContext, id: UUID) async throws -> (file: StoredFileRecord, data: Data) {
        let (row, backend) = try await session(context) { tx, account -> (StoredFileRecord, any StorageBackend) in
            let row = try await ownedFile(tx, account, id)
            guard let kind = StorageBackendKind(rawValue: row.backend) else { throw StorageErrors.corrupt }
            // The file is always read through the backend it was written to, never through a fallback.
            return (row, try backend(kind, settings: try await settingsRow(tx)))
        }
        let data: Data
        do { data = try await backend.get(key: row.storageKey, db: db) } catch { throw StorageErrors.unavailable }
        guard data.count == row.size, SigV4.sha256Hex(data) == row.sha256 else { throw StorageErrors.corrupt }
        return (row, data)
    }

    // MARK: Delete and cleanup

    func delete(_ context: AuthContext, id: UUID) async throws {
        let row = try await session(context) { tx, account -> StoredFileRecord in
            let row = try await ownedFile(tx, account, id)
            row.state = FileState.deleting.rawValue
            try await row.update(on: tx)
            try await AbsenceAttachmentRecord.query(on: tx).filter(\.$fileId == id).delete()
            return row
        }
        _ = await purge(row)
        _ = try? await cleanup(limit: 5)
    }

    /// Removes the object, then the row. On failure the retry marker is bumped and the row stays `deleting`/`failed`.
    @discardableResult
    func purge(_ row: StoredFileRecord) async -> Bool {
        guard let id = row.id, let kind = StorageBackendKind(rawValue: row.backend) else { return false }
        do {
            let settings = try await settingsRow(db)
            let adapter = try backend(kind, settings: settings)
            let key = row.storageKey
            try await auth.transaction(on: db) { tx in
                try await adapter.delete(key: key, db: kind == .db ? tx : db)
                try await StoredFileRecord.query(on: tx).filter(\.$id == id).delete()
            }
            return true
        } catch {
            _ = try? await auth.transaction(on: db) { tx in
                guard let current = try await StoredFileRecord.find(id, on: tx) else { return }
                current.cleanupAttempts += 1; current.cleanupAttemptedAt = Date()
                try await current.update(on: tx)
            }
            return false
        }
    }

    /// Retries removals of `deleting` and `failed` files and of `pending` files abandoned for an hour.
    /// Also drops attachment links whose absence no longer exists. Returns the number of purged files.
    @discardableResult
    func cleanup(limit: Int = StorageLimits.cleanupBatch, pendingOlderThan: TimeInterval = 3600) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-pendingOlderThan)
        let rows = try await StoredFileRecord.query(on: db)
            .group(.or) { group in
                group.filter(\.$state == FileState.deleting.rawValue).filter(\.$state == FileState.failed.rawValue)
                group.group(.and) { $0.filter(\.$state == FileState.pending.rawValue).filter(\.$createdAt < cutoff) }
            }
            .sort(\.$createdAt).limit(limit).all()
        var purged = 0
        for row in rows where await purge(row) { purged += 1 }
        try await requireSQL(db).raw("DELETE FROM absence_attachments WHERE absence_id NOT IN (SELECT id FROM absences)").run()
        return purged
    }

    // MARK: Attachments

    private func absence(_ tx: any Database, _ account: UUID, _ id: UUID) async throws {
        guard try await AbsenceRecord.query(on: tx).filter(\.$accountId == account).filter(\.$id == id).count() == 1 else { throw APIError.missing }
    }

    func attachments(_ context: AuthContext, absence id: UUID) async throws -> [FileMetaDTO] {
        try await session(context) { tx, account in
            try await absence(tx, account, id)
            let links = try await AbsenceAttachmentRecord.query(on: tx).filter(\.$absenceId == id).filter(\.$accountId == account).sort(\.$createdAt).all()
            guard !links.isEmpty else { return [] }
            let files = try await StoredFileRecord.query(on: tx).filter(\.$id ~~ links.map(\.fileId)).filter(\.$accountId == account)
                .filter(\.$state == FileState.stored.rawValue).all()
            let byId = Dictionary(uniqueKeysWithValues: files.compactMap { row in row.id.map { ($0, row) } })
            return try links.compactMap { byId[$0.fileId] }.map(FileMetaDTO.init)
        }
    }

    func attach(_ context: AuthContext, absence id: UUID, file fileId: UUID) async throws -> FileMetaDTO {
        try await session(context) { tx, account in
            try await absence(tx, account, id)
            let file = try await ownedFile(tx, account, fileId)
            let existing = try await AbsenceAttachmentRecord.query(on: tx).filter(\.$absenceId == id).all()
            if !existing.contains(where: { $0.fileId == fileId }) {
                guard existing.count < StorageLimits.maxAttachmentsPerAbsence else { throw APIError(.conflict, "conflict") }
                let link = AbsenceAttachmentRecord(); link.id = UUID(); link.accountId = account; link.absenceId = id; link.fileId = fileId; link.createdAt = Date()
                try await link.create(on: tx)
            }
            return try FileMetaDTO(file)
        }
    }

    func detach(_ context: AuthContext, absence id: UUID, file fileId: UUID) async throws {
        try await session(context) { tx, account in
            try await absence(tx, account, id)
            let links = try await AbsenceAttachmentRecord.query(on: tx).filter(\.$absenceId == id).filter(\.$fileId == fileId).filter(\.$accountId == account).all()
            guard !links.isEmpty else { throw APIError.missing }
            for link in links { try await link.delete(on: tx) }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension LocalFSBackend {
    /// Save-time validation: absolute, no `..`, not `/`, an existing directory that accepts a probe file.
    static func validateRoot(_ path: String) throws {
        guard path.hasPrefix("/"), path.utf8.count <= 1024, !path.contains("\0"),
              !path.split(separator: "/").contains(".."), let real = realpath(path), real != "/" else { throw APIError.invalid }
        var info = stat()
        guard stat(real, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw APIError.invalid }
        let probe = real + "/.tt-probe-" + UUID().uuidString.lowercased()
        let descriptor = open(probe, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw APIError.invalid }
        close(descriptor); unlink(probe)
    }
}
