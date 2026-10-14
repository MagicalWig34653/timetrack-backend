import Foundation
import Fluent
import Vapor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Raised by adapters when the object store cannot serve the request. Mapped to 503 storage_unavailable.
struct StorageBackendError: Error, Sendable { var detail: String }

/// Object store behind a `stored_files` row. `db` is only used by the database adapter so that blob and
/// state change commit together; the other adapters ignore it.
protocol StorageBackend: Sendable {
    var kind: StorageBackendKind { get }
    func put(key: String, data: Data, db: any Database) async throws
    func get(key: String, db: any Database) async throws -> Data
    func delete(key: String, db: any Database) async throws
}

enum StorageKeys {
    /// Random key with two shard levels: `ab/cd/<uuid>`. The database adapter uses the plain file id.
    static func make(for id: UUID, kind: StorageBackendKind) -> String {
        guard kind != .db else { return id.uuidString.lowercased() }
        let text = id.uuidString.lowercased()
        let shard = text.replacingOccurrences(of: "-", with: "")
        return "\(shard.prefix(2))/\(shard.dropFirst(2).prefix(2))/\(text)"
    }
    private static let hex = Set("0123456789abcdef")
    /// Strict shape check; guarantees there is no traversal, no empty or dotted component.
    static func isValidShardedKey(_ key: String) -> Bool {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 2, parts[1].count == 2, parts[2].count == 36,
              parts[0].allSatisfy(hex.contains), parts[1].allSatisfy(hex.contains),
              UUID(uuidString: String(parts[2])) != nil, parts[2] == parts[2].lowercased() else { return false }
        return true
    }
}

// MARK: Database

struct DBBackend: StorageBackend {
    let kind = StorageBackendKind.db
    func put(key: String, data: Data, db: any Database) async throws {
        guard let id = UUID(uuidString: key), data.count <= StorageLimits.hardMaxUploadBytes else { throw StorageBackendError(detail: "invalid key or size") }
        let row = FileBlobRecord(); row.id = id; row.bytes = data
        try await row.create(on: db)
    }
    func get(key: String, db: any Database) async throws -> Data {
        guard let id = UUID(uuidString: key), let row = try await FileBlobRecord.find(id, on: db) else { throw StorageBackendError(detail: "blob missing") }
        return row.bytes
    }
    func delete(key: String, db: any Database) async throws {
        guard let id = UUID(uuidString: key) else { throw StorageBackendError(detail: "invalid key") }
        try await FileBlobRecord.query(on: db).filter(\.$id == id).delete()
    }
}

// MARK: Local filesystem

/// Files below a configured root. Keys are generated (`ab/cd/<uuid>`) and shape-checked; additionally every
/// path is resolved with `realpath` and must stay below the resolved root, and symlinks are never followed.
struct LocalFSBackend: StorageBackend {
    let kind = StorageBackendKind.local
    let root: String

    init(root: String) { self.root = root }

    func put(key: String, data: Data, db: any Database) async throws { try await run { try self.writeSync(key: key, data: data) } }
    func get(key: String, db: any Database) async throws -> Data { try await run { try self.readSync(key: key) } }
    func delete(key: String, db: any Database) async throws { try await run { try self.deleteSync(key: key) } }

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .utility) { try work() }.value
    }

    private func resolvedRoot() throws -> String {
        guard root.hasPrefix("/"), let real = Self.realpath(root) else { throw StorageBackendError(detail: "root missing") }
        var info = stat()
        guard stat(real, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw StorageBackendError(detail: "root is not a directory") }
        return real
    }
    static func realpath(_ path: String) -> String? {
        guard let pointer = Darwin_or_Glibc_realpath(path) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
    private static func contained(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
    private static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// Creates (or validates) one shard directory component with mode 0700, never through a symlink.
    private func ensureDirectory(_ path: String, root: String) throws {
        if Self.isSymlink(path) { throw StorageBackendError(detail: "symlink in storage tree") }
        if mkdir(path, 0o700) != 0 && errno != EEXIST { throw StorageBackendError(detail: "mkdir failed") }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw StorageBackendError(detail: "not a directory") }
        guard let real = Self.realpath(path), Self.contained(real, in: root) else { throw StorageBackendError(detail: "path escapes root") }
        _ = chmod(path, 0o700)
    }

    private func paths(for key: String) throws -> (root: String, first: String, second: String, file: String, name: String) {
        guard StorageKeys.isValidShardedKey(key) else { throw StorageBackendError(detail: "invalid key") }
        let parts = key.split(separator: "/").map(String.init)
        let root = try resolvedRoot()
        let first = root + "/" + parts[0], second = first + "/" + parts[1]
        return (root, first, second, second + "/" + parts[2], parts[2])
    }

    func writeSync(key: String, data: Data) throws {
        let p = try paths(for: key)
        try ensureDirectory(p.first, root: p.root)
        try ensureDirectory(p.second, root: p.root)
        let temp = p.second + "/.tmp-" + UUID().uuidString.lowercased()
        let descriptor = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw StorageBackendError(detail: "open failed") }
        var finished = false
        defer { if !finished { close(descriptor); unlink(temp) } }
        _ = fchmod(descriptor, 0o600)
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 { if errno == EINTR { continue }; throw StorageBackendError(detail: "write failed") }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw StorageBackendError(detail: "fsync failed") }
        close(descriptor)
        finished = true
        // A pre-planted symlink at the destination is replaced by rename, never followed.
        guard rename(temp, p.file) == 0 else { unlink(temp); throw StorageBackendError(detail: "rename failed") }
        let directory = open(p.second, O_RDONLY)
        if directory >= 0 { _ = fsync(directory); close(directory) }
    }

    func readSync(key: String) throws -> Data {
        let p = try paths(for: key)
        var info = stat()
        guard lstat(p.file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw StorageBackendError(detail: "object missing") }
        guard let real = Self.realpath(p.file), Self.contained(real, in: p.root), Self.realpath(p.second).map({ Self.contained($0, in: p.root) }) == true
        else { throw StorageBackendError(detail: "path escapes root") }
        let descriptor = open(p.file, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StorageBackendError(detail: "open failed") }
        defer { close(descriptor) }
        var result = Data(); result.reserveCapacity(Int(info.st_size))
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0 { if errno == EINTR { continue }; throw StorageBackendError(detail: "read failed") }
            if count == 0 { break }
            result.append(chunk, count: count)
            if result.count > StorageLimits.hardMaxUploadBytes { throw StorageBackendError(detail: "object too large") }
        }
        return result
    }

    func deleteSync(key: String) throws {
        let p = try paths(for: key)
        guard let parent = Self.realpath(p.second), Self.contained(parent, in: p.root) else { return }  // nothing there
        if unlink(p.file) != 0 && errno != ENOENT { throw StorageBackendError(detail: "unlink failed") }
    }
}

#if canImport(Glibc)
private func Darwin_or_Glibc_realpath(_ path: String) -> UnsafeMutablePointer<CChar>? { Glibc.realpath(path, nil) }
#else
private func Darwin_or_Glibc_realpath(_ path: String) -> UnsafeMutablePointer<CChar>? { Darwin.realpath(path, nil) }
#endif
