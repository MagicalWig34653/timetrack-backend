import Foundation
import Fluent
import XCTVapor
@testable import TimetrackKit

// C13: storage REST scenarios. Each runs on SQLite and (gated on MARIADB_TEST_HOST) on MariaDB.

final class FlakyFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool] = [:]
    subscript(name: String) -> Bool { get { lock.withLock { values[name] ?? false } } set { lock.withLock { values[name] = newValue } } }
}
struct FlakyBackend: StorageBackend {
    let inner: any StorageBackend
    let flags: FlakyFlags
    var kind: StorageBackendKind { inner.kind }
    func put(key: String, data: Data, db: any Database) async throws {
        if flags["put"] { throw StorageBackendError(detail: "injected put failure") }
        try await inner.put(key: key, data: data, db: db)
    }
    func get(key: String, db: any Database) async throws -> Data {
        if flags["get"] { throw StorageBackendError(detail: "injected get failure") }
        return try await inner.get(key: key, db: db)
    }
    func delete(key: String, db: any Database) async throws {
        if flags["delete"] { throw StorageBackendError(detail: "injected delete failure") }
        try await inner.delete(key: key, db: db)
    }
}

extension AuthTests {
    static let testKey = Data((0..<32).map { UInt8($0 &+ 3) }).base64EncodedString()
    static let txt = Data("Krankmeldung vom 12.10.2026\n".utf8)
    static let pdf = Data("%PDF-1.4\n".utf8) + Data(repeating: 0x41, count: 300)
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 64)

    @discardableResult
    func fileUpload(_ app: Application, _ context: AuthContext?, _ name: String, _ data: Data, type: String? = nil,
                    _ status: HTTPStatus = .created, csrf: Bool = true, file: StaticString = #filePath, line: UInt = #line) async throws -> XCTHTTPResponse {
        let boundary = "TTBOUNDARY"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n".utf8)
        if let type { body.append(Data("Content-Type: \(type)\r\n".utf8)) }
        body.append(Data("\r\n".utf8)); body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var head = context.map { headers($0, csrf: csrf) } ?? [:]
        head.replaceOrAdd(name: .contentType, value: "multipart/form-data; boundary=\(boundary)")
        let response = try await app.testable().sendRequest(.POST, "/api/v1/files", headers: head, body: ByteBuffer(data: body))
        XCTAssertEqual(response.status, status, response.body.string, file: file, line: line)
        return response
    }
    func fileID(_ response: XCTHTTPResponse) throws -> String { try XCTUnwrap(object(response)["id"] as? String) }
    func download(_ app: Application, _ context: AuthContext?, _ id: String, _ status: HTTPStatus = .ok,
                  file: StaticString = #filePath, line: UInt = #line) async throws -> XCTHTTPResponse {
        let response = try await app.testable().sendRequest(.GET, "/api/v1/files/" + id, headers: context.map { headers($0) } ?? [:])
        XCTAssertEqual(response.status, status, response.body.string, file: file, line: line)
        return response
    }
    func diskFiles(_ root: String) -> [String] {
        let manager = FileManager.default
        return (manager.enumerator(atPath: root)?.allObjects as? [String] ?? []).filter {
            var directory: ObjCBool = false
            return manager.fileExists(atPath: root + "/" + $0, isDirectory: &directory) && !directory.boolValue
        }.sorted()
    }
    func tempDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "tt-c13-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
    func storageService(_ app: Application, _ auth: AuthService) -> StorageService {
        StorageService(auth: auth, db: app.db, client: app.client, env: app.storageEnvironment)
    }
    func rule(_ maxBytes: Int?, _ backend: String) -> [String: Any] { maxBytes.map { ["maxBytes": $0, "backend": backend] } ?? ["backend": backend] }

    // MARK: Scenarios

    func scenarioStorageSettings(_ app: Application, _ auth: AuthService) async throws {
        let (admin, _) = try await registered(auth, db: app.db)
        let member = try await second(app, auth, admin)
        app.storageEnvironment.secretKey = { nil }

        try await api(app, member, .GET, "admin/storage", nil, .forbidden)
        try await api(app, member, .PUT, "admin/storage", ["rules": [rule(nil, "db")]], .forbidden)
        let anonymous = try await app.testable().sendRequest(.GET, "/api/v1/admin/storage")
        XCTAssertEqual(anonymous.status, .unauthorized)
        let noCSRF = try await app.testable().sendRequest(.PUT, "/api/v1/admin/storage", headers: headers(admin, csrf: false).merging(contentType: .json),
                                                          body: ByteBuffer(string: #"{"rules":[{"backend":"db"}]}"#))
        XCTAssertEqual(noCSRF.status, .forbidden)

        let defaults = try object(await api(app, admin, .GET, "admin/storage"))
        try await eq(defaults["maxUploadBytes"] as? Int, 10 * 1024 * 1024); try await eq(defaults["hasSecret"] as? Bool, false)
        try await eq((defaults["rules"] as? [[String: Any]])?.count, 1)

        // Without STORAGE_SECRET_KEY any S3 configuration or S3 rule is answered with 501 not_implemented.
        let s3: [String: Any] = ["endpoint": "https://s3.example.com", "region": "eu-1", "bucket": "b", "accessKeyId": "AK", "secretAccessKey": "TOP-SECRET-VALUE"]
        let refused = try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "s3")], "s3": s3], .notImplemented)
        try await eq(errorCode(refused), "not_implemented")
        try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "db")], "s3": s3], .notImplemented)
        let stillDefault = try object(await api(app, admin, .GET, "admin/storage"))
        try await eq(stillDefault["hasSecret"] as? Bool, false)
        let plain = try object(await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "db")], "maxUploadBytes": 2048]))
        try await eq(plain["maxUploadBytes"] as? Int, 2048)

        // Key present: secret stored encrypted, never returned.
        app.storageEnvironment.secretKey = { AuthTests.testKey }
        let saved = try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(100, "db"), rule(nil, "s3")], "s3": s3])
        XCTAssertFalse(saved.body.string.contains("TOP-SECRET-VALUE")); XCTAssertFalse(saved.body.string.lowercased().contains("secretaccesskey"))
        let body = try object(saved)
        try await eq(body["hasSecret"] as? Bool, true)
        try await eq((body["s3"] as? [String: Any])?["pathStyle"] as? Bool, true)
        try await eq((body["s3"] as? [String: Any])?["accessKeyId"] as? String, "AK")
        let read = try await api(app, admin, .GET, "admin/storage")
        XCTAssertFalse(read.body.string.contains("TOP-SECRET-VALUE"))
        let row = try await StorageSettingsRecord.find(StorageSettingsRecord.rowId, on: app.db).map { $0 }
        let stored = try XCTUnwrap(row)
        XCTAssertNil(stored.s3SecretCiphertext.flatMap { $0.range(of: Data("TOP-SECRET-VALUE".utf8)) })
        XCTAssertEqual(stored.s3SecretNonce?.count, 12)
        // Omitting the secret keeps it; clearing s3 removes it.
        var withoutSecret = s3; withoutSecret["secretAccessKey"] = nil; withoutSecret["region"] = "eu-2"
        let kept = try object(await api(app, admin, .PUT, "admin/storage", ["rules": [rule(100, "db"), rule(nil, "s3")], "s3": withoutSecret]))
        try await eq(kept["hasSecret"] as? Bool, true); try await eq((kept["s3"] as? [String: Any])?["region"] as? String, "eu-2")
        let cleared = try object(await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "db")], "s3": NSNull()]))
        try await eq(cleared["hasSecret"] as? Bool, false); XCTAssertTrue(cleared["s3"] is NSNull || cleared["s3"] == nil)
        // S3 rule without any secret is refused.
        try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "s3")], "s3": withoutSecret], .badRequest)
        try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "s3")]], .badRequest)

        // Rule, limit, endpoint and path validation.
        let invalid: [[String: Any]] = [
            ["rules": []], ["rules": [rule(10, "db")]], ["rules": [rule(20, "db"), rule(20, "db"), rule(nil, "db")]],
            ["rules": [rule(nil, "db")], "maxUploadBytes": 0], ["rules": [rule(nil, "db")], "maxUploadBytes": 64 * 1024 * 1024 + 1],
            ["rules": [rule(nil, "local")]], ["rules": [rule(nil, "local")], "localPath": "/definitely/not/there"],
            ["rules": [rule(nil, "db")], "localPath": "relative"], ["rules": [rule(nil, "bogus")]],
            ["rules": [rule(nil, "db")], "s3": ["endpoint": "ftp://x", "region": "r", "bucket": "b", "accessKeyId": "a", "secretAccessKey": "s"]],
            ["rules": [rule(nil, "db")], "s3": ["endpoint": "https://u:p@x", "region": "r", "bucket": "b", "accessKeyId": "a", "secretAccessKey": "s"]],
        ]
        for body in invalid { try await api(app, admin, .PUT, "admin/storage", body, .badRequest) }
        let directory = try tempDirectory(); defer { try? FileManager.default.removeItem(atPath: directory) }
        let local = try object(await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "local")], "localPath": directory]))
        try await eq(local["localPath"] as? String, directory)
        try await eq(diskFiles(directory), [])   // probe removed
    }

    func scenarioFilesCore(_ app: Application, _ auth: AuthService) async throws {
        let (admin, _) = try await registered(auth, db: app.db)
        let member = try await second(app, auth, admin)
        try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "db")], "maxUploadBytes": 600])

        let created = try object(await fileUpload(app, admin, "../../etc/Attest: Ärztin?.txt", AuthTests.txt, type: "text/plain"))
        let id = try XCTUnwrap(created["id"] as? String)
        try await eq(created["name"] as? String, "Attest_ Ärztin_.txt"); try await eq(created["backend"] as? String, "db")
        try await eq(created["size"] as? Int, AuthTests.txt.count); try await eq(created["contentType"] as? String, "text/plain; charset=utf-8")
        try await eq(created["sha256"] as? String, SigV4.sha256Hex(AuthTests.txt)); XCTAssertNotNil(created["createdAt"])
        let blobs = try await FileBlobRecord.query(on: app.db).count(); try await eq(blobs, 1)

        let got = try await download(app, admin, id)
        XCTAssertEqual(Data(got.body.readableBytesView), AuthTests.txt)
        try await eq(got.headers.first(name: "X-Content-Type-Options"), "nosniff")
        try await eq(got.headers.first(name: .contentType), "text/plain; charset=utf-8")
        let disposition = try XCTUnwrap(got.headers.first(name: .contentDisposition))
        XCTAssertTrue(disposition.hasPrefix("attachment;")); XCTAssertTrue(disposition.contains("filename*=UTF-8''Attest_%20%C3%84rztin_.txt"))
        // Other accounts and anonymous callers cannot see the file.
        let foreign = try await download(app, member, id, .notFound); try await eq(errorCode(foreign), "not_found")
        _ = try await download(app, nil, id, .unauthorized)
        _ = try await download(app, admin, UUID().uuidString, .notFound)
        try await api(app, member, .DELETE, "files/" + id, nil, .notFound)
        try await fileUpload(app, nil, "a.txt", AuthTests.txt, .unauthorized)
        try await fileUpload(app, admin, "a.txt", AuthTests.txt, .forbidden, csrf: false)

        // Type sniffing against extension, declared type and content.
        let wrongExt = try await fileUpload(app, admin, "scan.pdf", AuthTests.png, type: "application/pdf", .unsupportedMediaType)
        try await eq(errorCode(wrongExt), "unsupported_type")
        try await fileUpload(app, admin, "scan.png", AuthTests.pdf, type: "image/png", .unsupportedMediaType)
        try await fileUpload(app, admin, "scan.png", AuthTests.pdf, .unsupportedMediaType)
        try await fileUpload(app, admin, "run.exe", Data([0x4D, 0x5A, 0, 0, 0, 0]), .unsupportedMediaType)
        try await fileUpload(app, admin, "binary.txt", Data([0, 1, 2, 3, 4]), .unsupportedMediaType)
        try await fileUpload(app, admin, "empty.txt", Data(), .unsupportedMediaType)
        let pdf = try object(await fileUpload(app, admin, "ok", AuthTests.pdf, type: "application/octet-stream"))
        try await eq(pdf["name"] as? String, "ok.pdf"); try await eq(pdf["contentType"] as? String, "application/pdf")

        // The size limit is inclusive and enforced for the whole upload.
        let exact = try await fileUpload(app, admin, "exact.txt", Data(repeating: 0x61, count: 600))
        try await eq(exact.status, .created)
        let over = try await fileUpload(app, admin, "over.txt", Data(repeating: 0x61, count: 601), .payloadTooLarge)
        try await eq(errorCode(over), "file_too_large")

        // Delete removes metadata, blob and download.
        try await api(app, admin, .DELETE, "files/" + id, nil, .noContent)
        _ = try await download(app, admin, id, .notFound)
        try await api(app, admin, .DELETE, "files/" + id, nil, .notFound)
        let rows = try await StoredFileRecord.query(on: app.db).filter(\.$id == UUID(uuidString: id)!).count(); try await eq(rows, 0)
        let remaining = try await FileBlobRecord.query(on: app.db).count(); try await eq(remaining, 2)
        // A larger blob roundtrips (1.5 MB, default limit restored).
        try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "db")]])
        let bigId = try fileID(await fileUpload(app, admin, "big.txt", Data(repeating: 0x62, count: 1_500_000)))
        let bigBack = try await download(app, admin, bigId)
        try await eq(bigBack.body.readableBytes, 1_500_000)
    }

    func scenarioRulesApplyToNewUploadsOnly(_ app: Application, _ auth: AuthService) async throws {
        let (admin, _) = try await registered(auth, db: app.db)
        let directory = try tempDirectory(); defer { try? FileManager.default.removeItem(atPath: directory) }
        try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(50, "db"), rule(nil, "local")], "localPath": directory])
        let small = Data("kurz\n".utf8), large = Data(repeating: 0x63, count: 51), exact = Data(repeating: 0x64, count: 50)
        let smallId = try fileID(await fileUpload(app, admin, "small.txt", small))
        let exactMeta = try object(await fileUpload(app, admin, "exact.txt", exact))
        let largeMeta = try object(await fileUpload(app, admin, "large.txt", large))
        try await eq(exactMeta["backend"] as? String, "db"); try await eq(largeMeta["backend"] as? String, "local")
        let largeId = try XCTUnwrap(largeMeta["id"] as? String)
        let onDisk = diskFiles(directory)
        try await eq(onDisk.count, 1)
        try await yes(onDisk[0].hasSuffix(largeId.lowercased()))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory + "/" + onDisk[0])
        XCTAssertEqual((attributes[.posixPermissions] as? Int ?? 0) & 0o777, 0o600)

        // New rules: everything to the database. Existing files keep their location; new ones follow the new rule.
        try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "db")], "localPath": directory])
        let afterChange = try object(await fileUpload(app, admin, "large2.txt", large))
        try await eq(afterChange["backend"] as? String, "db")
        let oldLarge = try await download(app, admin, largeId); XCTAssertEqual(Data(oldLarge.body.readableBytesView), large)
        let oldSmall = try await download(app, admin, smallId); XCTAssertEqual(Data(oldSmall.body.readableBytesView), small)

        // The local backend becomes unconfigured: existing local file -> 503, no silent fallback, no silent loss.
        try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "db")], "localPath": NSNull()])
        let unavailable = try await download(app, admin, largeId, .serviceUnavailable)
        try await eq(errorCode(unavailable), "storage_unavailable")
        let stillThere = try await download(app, admin, smallId); XCTAssertEqual(Data(stillThere.body.readableBytesView), small)
        try await eq(diskFiles(directory).count, 1)
        // Deleting while unavailable hides the file but keeps the retry marker; cleanup finishes after repair.
        try await api(app, admin, .DELETE, "files/" + largeId, nil, .noContent)
        _ = try await download(app, admin, largeId, .notFound)
        let pendingRow = try await StoredFileRecord.find(UUID(uuidString: largeId), on: app.db)
        let pending = try XCTUnwrap(pendingRow)
        try await eq(pending.state, "deleting"); try await yes(pending.cleanupAttempts >= 1)
        try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "db")], "localPath": directory])
        let purged = try await storageService(app, auth).cleanup(); try await eq(purged, 1)
        try await eq(diskFiles(directory), [])
        let gone = try await StoredFileRecord.find(UUID(uuidString: largeId), on: app.db); XCTAssertNil(gone)
    }

    func scenarioS3EndToEnd(_ app: Application, _ auth: AuthService) async throws {
        let fake = try await FakeS3.start()
        do {
            let (admin, _) = try await registered(auth, db: app.db)
            app.storageEnvironment.secretKey = { AuthTests.testKey }
            app.storageEnvironment.s3Timeout = .seconds(5)
            let s3: [String: Any] = ["endpoint": fake.endpoint, "region": FakeS3.region, "bucket": FakeS3.bucket, "pathStyle": true,
                                     "accessKeyId": FakeS3.accessKey, "secretAccessKey": FakeS3.secret]
            try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(100, "db"), rule(nil, "s3")], "s3": s3])
            let content = Data(repeating: 0x65, count: 300)
            let meta = try object(await fileUpload(app, admin, "remote.txt", content))
            try await eq(meta["backend"] as? String, "s3")
            let id = try XCTUnwrap(meta["id"] as? String)
            let rowRow = try await StoredFileRecord.find(UUID(uuidString: id), on: app.db)
        let row = try XCTUnwrap(rowRow)
            XCTAssertEqual(fake.object("/\(FakeS3.bucket)/\(row.storageKey)"), content)
            XCTAssertEqual(fake.rejected, 0)
            let back = try await download(app, admin, id); XCTAssertEqual(Data(back.body.readableBytesView), content)
            // Small files stay in the database; nothing was sent to S3 for them.
            let small = try object(await fileUpload(app, admin, "small.txt", AuthTests.txt)); try await eq(small["backend"] as? String, "db")
            try await eq(fake.storedKeys.count, 1)
            try await api(app, admin, .DELETE, "files/" + id, nil, .noContent)
            try await eq(fake.storedKeys, [])
            try await eq(await StoredFileRecord.query(on: app.db).filter(\.$id == UUID(uuidString: id)!).count(), 0)

            // Server failure: 503, the row is `failed`, the secret does not leak into the response.
            fake.failWrites = true
            let failed = try await fileUpload(app, admin, "again.txt", content, .serviceUnavailable)
            try await eq(errorCode(failed), "storage_unavailable")
            XCTAssertFalse(failed.body.string.contains(FakeS3.secret)); XCTAssertFalse(failed.body.string.contains(FakeS3.accessKey))
            try await eq(await StoredFileRecord.query(on: app.db).filter(\.$state == "failed").count(), 1)
            fake.failWrites = false
            try await eq(await storageService(app, auth).cleanup(), 1)
            // Wrong secret: signature rejected -> 503; same after the key vanished from the environment (no fallback).
            var wrong = s3; wrong["secretAccessKey"] = "wrong-secret"
            try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "s3")], "s3": wrong])
            try await fileUpload(app, admin, "again.txt", content, .serviceUnavailable)
            try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "s3")], "s3": s3])
            let ok = try fileID(await fileUpload(app, admin, "again.txt", content))
            app.storageEnvironment.secretKey = { nil }
            _ = try await download(app, admin, ok, .serviceUnavailable)
            try await fileUpload(app, admin, "third.txt", content, .serviceUnavailable)
        } catch { try await fake.stop(); throw error }
        try await fake.stop()
    }

    func scenarioCompensation(_ app: Application, _ auth: AuthService) async throws {
        let (admin, _) = try await registered(auth, db: app.db)
        let directory = try tempDirectory(); defer { try? FileManager.default.removeItem(atPath: directory) }
        let flags = FlakyFlags()
        app.storageEnvironment.decorate = { FlakyBackend(inner: $0, flags: flags) }
        let service = storageService(app, auth)
        try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "local")], "localPath": directory])

        // a) object write fails: 503, row failed, nothing on disk; cleanup removes the row.
        flags["put"] = true
        let failedPut = try await fileUpload(app, admin, "a.txt", AuthTests.txt, .serviceUnavailable)
        try await eq(errorCode(failedPut), "storage_unavailable")
        let failedRows = try await StoredFileRecord.query(on: app.db).all()
        try await eq(failedRows.map(\.state), ["failed"]); try await eq(diskFiles(directory), [])
        flags["put"] = false
        try await eq(await StorageService(auth: auth, db: app.db, client: app.client, env: app.storageEnvironment).cleanup(), 1)
        try await eq(await StoredFileRecord.query(on: app.db).count(), 0)

        // b) database commit fails after the object was written: the object is removed again.
        struct Injected: Error {}
        app.storageEnvironment.beforeFinalize = { throw Injected() }
        try await fileUpload(app, admin, "b.txt", AuthTests.txt, .serviceUnavailable)
        try await eq(diskFiles(directory), [])
        try await eq(await StoredFileRecord.query(on: app.db).filter(\.$state == "failed").count(), 1)
        // b2) same for the database backend: no blob is left behind.
        try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "db")], "localPath": directory])
        try await fileUpload(app, admin, "b2.txt", AuthTests.txt, .serviceUnavailable)
        try await eq(await FileBlobRecord.query(on: app.db).count(), 0)
        app.storageEnvironment.beforeFinalize = nil
        _ = service
        try await eq(await storageService(app, auth).cleanup(), 2)
        try await eq(await StoredFileRecord.query(on: app.db).count(), 0)

        // c) object removal fails: DELETE succeeds for the user, the row stays `deleting` with a retry marker.
        try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "local")], "localPath": directory])
        let id = try fileID(await fileUpload(app, admin, "c.txt", AuthTests.txt))
        try await eq(diskFiles(directory).count, 1)
        flags["delete"] = true
        try await api(app, admin, .DELETE, "files/" + id, nil, .noContent)
        _ = try await download(app, admin, id, .notFound)
        let markerRow = try await StoredFileRecord.find(UUID(uuidString: id), on: app.db)
        let marker = try XCTUnwrap(markerRow)
        try await eq(marker.state, "deleting"); try await yes(marker.cleanupAttempts >= 1); XCTAssertNotNil(marker.cleanupAttemptedAt)
        try await eq(diskFiles(directory).count, 1)
        try await eq(await storageService(app, auth).cleanup(), 0)   // still failing
        flags["delete"] = false
        try await eq(await storageService(app, auth).cleanup(), 1)
        try await eq(diskFiles(directory), []); try await eq(await StoredFileRecord.query(on: app.db).count(), 0)

        // d) a read failure is a 503, not a 404 or 500.
        let readable = try fileID(await fileUpload(app, admin, "d.txt", AuthTests.txt))
        flags["get"] = true
        let unavailable = try await download(app, admin, readable, .serviceUnavailable); try await eq(errorCode(unavailable), "storage_unavailable")
        flags["get"] = false
        _ = try await download(app, admin, readable)
        // e) tampered object content is detected.
        let keyRow = try await StoredFileRecord.find(UUID(uuidString: readable), on: app.db)
        let key = try XCTUnwrap(keyRow).storageKey
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: directory + "/" + key))
        let corrupt = try await download(app, admin, readable, .internalServerError); try await eq(errorCode(corrupt), "storage_corrupt")
    }

    func scenarioAttachments(_ app: Application, _ auth: AuthService) async throws {
        let (admin, _) = try await registered(auth, db: app.db)
        let member = try await second(app, auth, admin)
        let first = try await createAbsence(app, admin, absenceBody("2026-10-12", "2026-10-13", kind: "sick", status: "taken"))
        let secondAbsence = try await createAbsence(app, admin, absenceBody("2026-10-20", kind: "sick", status: "taken"))
        let foreign = try await createAbsence(app, member, absenceBody("2026-10-12", kind: "sick", status: "taken"))
        let a1 = try XCTUnwrap(first["id"] as? String), a2 = try XCTUnwrap(secondAbsence["id"] as? String), m1 = try XCTUnwrap(foreign["id"] as? String)

        let fileId = try fileID(await fileUpload(app, admin, "Krankmeldung.txt", AuthTests.txt))
        let memberFile = try fileID(await fileUpload(app, member, "Mein.txt", AuthTests.txt))
        let attached = try object(await api(app, admin, .POST, "absences/\(a1)/attachments", ["fileId": fileId], .created))
        try await eq(attached["id"] as? String, fileId); try await eq(attached["name"] as? String, "Krankmeldung.txt")
        try await api(app, admin, .POST, "absences/\(a1)/attachments", ["fileId": fileId], .created)   // idempotent
        try await api(app, admin, .POST, "absences/\(a2)/attachments", ["fileId": fileId], .created)   // same file on several absences
        try await eq(list(await api(app, admin, .GET, "absences/\(a1)/attachments")).count, 1)
        try await eq(list(await api(app, admin, .GET, "absences/\(a2)/attachments")).count, 1)
        try await eq(list(await api(app, admin, .GET, "absences/\(a1)/attachments")).first?["sha256"] as? String, SigV4.sha256Hex(AuthTests.txt))

        // Owner isolation: absence and file must both belong to the caller; everything else is 404.
        try await api(app, member, .GET, "absences/\(a1)/attachments", nil, .notFound)
        try await api(app, member, .POST, "absences/\(a1)/attachments", ["fileId": memberFile], .notFound)
        try await api(app, member, .POST, "absences/\(m1)/attachments", ["fileId": fileId], .notFound)
        try await api(app, admin, .POST, "absences/\(m1)/attachments", ["fileId": memberFile], .notFound)
        try await api(app, admin, .POST, "absences/\(a1)/attachments", ["fileId": memberFile], .notFound)
        try await api(app, admin, .POST, "absences/\(a1)/attachments", ["fileId": UUID().uuidString], .notFound)
        try await api(app, admin, .POST, "absences/\(UUID().uuidString)/attachments", ["fileId": fileId], .notFound)
        try await api(app, admin, .POST, "absences/\(a1)/attachments", ["fileId": "nope"], .badRequest)
        try await api(app, member, .DELETE, "absences/\(a1)/attachments/\(fileId)", nil, .notFound)
        try await eq(list(await api(app, member, .GET, "absences/\(m1)/attachments")).count, 0)

        // Shared views never contain files or file names.
        try await api(app, admin, .POST, "shares", ["recipientHandle": "member", "scopes": ["plan": true, "actual": true, "vacation": true]], .created)
        let incoming = try list(await api(app, member, .GET, "shares/incoming"))
        let shareId = try XCTUnwrap(incoming.first?["id"] as? String)
        let view = try await api(app, member, .GET, "shares/incoming/\(shareId)/view?from=2026-10-01&to=2026-10-31")
        for needle in [fileId, "Krankmeldung", "attachment", "sha256", "storage"] { XCTAssertFalse(view.body.string.contains(needle), needle) }
        XCTAssertFalse(incoming.description.contains(fileId))
        // The absence resource itself does not embed files either.
        let absenceJSON = try await api(app, admin, .GET, "absences/\(a1)").body.string
        XCTAssertFalse(absenceJSON.contains(fileId))

        // Detach removes only the link.
        try await api(app, admin, .DELETE, "absences/\(a1)/attachments/\(fileId)", nil, .noContent)
        try await api(app, admin, .DELETE, "absences/\(a1)/attachments/\(fileId)", nil, .notFound)
        try await eq(list(await api(app, admin, .GET, "absences/\(a1)/attachments")).count, 0)
        _ = try await download(app, admin, fileId)
        try await eq(list(await api(app, admin, .GET, "absences/\(a2)/attachments")).count, 1)
        // Deleting the file removes every link; a deleted file cannot be attached.
        try await api(app, admin, .DELETE, "files/" + fileId, nil, .noContent)
        try await eq(list(await api(app, admin, .GET, "absences/\(a2)/attachments")).count, 0)
        try await api(app, admin, .POST, "absences/\(a1)/attachments", ["fileId": fileId], .notFound)
        try await eq(await AbsenceAttachmentRecord.query(on: app.db).count(), 0)
        // Cap per absence.
        for index in 0..<StorageLimits.maxAttachmentsPerAbsence {
            let id = try fileID(await fileUpload(app, admin, "f\(index).txt", Data("x\(index)\n".utf8)))
            try await api(app, admin, .POST, "absences/\(a1)/attachments", ["fileId": id], .created)
        }
        let extra = try fileID(await fileUpload(app, admin, "extra.txt", AuthTests.txt))
        try await api(app, admin, .POST, "absences/\(a1)/attachments", ["fileId": extra], .conflict)
    }

    var storageScenarios: [Scenario] {
        [scenarioStorageSettings, scenarioFilesCore, scenarioRulesApplyToNewUploadsOnly, scenarioS3EndToEnd, scenarioCompensation, scenarioAttachments]
    }

    func testStorageRESTSQLite() async throws {
        for scenario in storageScenarios { try await withApp(scenario) }
    }

    func testStorageRESTMariaDB() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MARIADB_TEST_HOST"] else { throw XCTSkip("MARIADB_TEST_HOST not set") }
        let environment = ["DATABASE_DRIVER": "mariadb", "DB_HOST": host, "DB_PORT": env["MARIADB_TEST_PORT"] ?? "13306",
            "DB_USER": env["MARIADB_TEST_USER"] ?? "timetrack", "DB_PASSWORD": env["MARIADB_TEST_PASSWORD"] ?? "",
            "DB_NAME": env["MARIADB_TEST_DB"] ?? "timetrack_test", "DB_TLS": "off"]
        for scenario in storageScenarios { try await withApp(environment: environment, scenario) }
    }

    /// Real streaming path: an oversize body must map to file_too_large (checked against the stored limit).
    func testStorageOversizeOverRealServer() async throws {
        try await withApp { app, auth in
            let (admin, _) = try await registered(auth, db: app.db)
            try await api(app, admin, .PUT, "admin/storage", ["rules": [rule(nil, "db")], "maxUploadBytes": 1024])
            try await app.testable(method: .running(port: 0)).test(.POST, "/api/v1/files", beforeRequest: { request async throws in
                let boundary = "TTBOUNDARY"
                var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"big.txt\"\r\n\r\n".utf8)
                body.append(Data(repeating: 0x61, count: 4 * 1024 * 1024)); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
                request.headers = headers(admin)
                request.headers.replaceOrAdd(name: .contentType, value: "multipart/form-data; boundary=\(boundary)")
                request.body = ByteBuffer(data: body)
            }, afterResponse: { response async throws in
                XCTAssertEqual(response.status, .payloadTooLarge)
                XCTAssertTrue(response.body.string.contains("file_too_large"))
            })
            try await eq(await StoredFileRecord.query(on: app.db).count(), 0)
        }
    }
}

private extension HTTPHeaders {
    func merging(contentType: HTTPMediaType) -> HTTPHeaders { var copy = self; copy.contentType = contentType; return copy }
}
