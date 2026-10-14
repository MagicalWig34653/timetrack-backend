import Foundation
import Fluent
import XCTVapor
import FluentSQLiteDriver
@testable import TimetrackKit

// C13: pure units (SigV4, rules, secret box, sniffing, sanitizing, local adapter, S3 client against a fake S3).

/// In-process S3 stand-in: verifies the SigV4 signature of every request and keeps objects in memory.
final class FakeS3: @unchecked Sendable {
    static let accessKey = "AKIATESTFAKE", secret = "fake-secret-value/with+chars", region = "eu-test-1", bucket = "tt-bucket"
    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private(set) var requests: [String] = []
    private(set) var rejected = 0
    var failWrites = false
    let app: Application
    var endpoint: String { "http://127.0.0.1:\(app.http.server.shared.localAddress?.port ?? 0)" }

    static func start() async throws -> FakeS3 {
        let app = try await Application.make(.testing)
        app.logger.logLevel = .critical
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        let fake = FakeS3(app: app)
        app.middleware = Middlewares()
        app.middleware.use(FakeS3Middleware(fake: fake))
        try await app.startup()
        return fake
    }
    private init(app: Application) { self.app = app }
    func stop() async throws { try await app.asyncShutdown() }
    var storedKeys: [String] { lock.withLock { objects.keys.sorted() } }
    func object(_ path: String) -> Data? { lock.withLock { objects[path] } }
    fileprivate func record(_ line: String) { lock.withLock { requests.append(line) } }
    fileprivate func reject() { lock.withLock { rejected += 1 } }
    fileprivate func put(_ path: String, _ data: Data) { lock.withLock { objects[path] = data } }
    fileprivate func remove(_ path: String) { lock.withLock { objects[path] = nil } }
}

struct FakeS3Middleware: AsyncMiddleware {
    let fake: FakeS3
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let body = try await request.body.collect(max: 70 * 1024 * 1024).get()
        let data = body.map { Data($0.readableBytesView) } ?? Data()
        let path = request.url.path
        fake.record("\(request.method.rawValue) \(path)")
        guard verify(request, path: path, body: data) else { fake.reject(); return Response(status: .forbidden) }
        guard path.hasPrefix("/\(FakeS3.bucket)/") else { return Response(status: .notFound) }
        switch request.method {
        case .PUT:
            if fake.failWrites { return Response(status: .internalServerError) }
            fake.put(path, data); return Response(status: .ok)
        case .GET:
            guard let stored = fake.object(path) else { return Response(status: .notFound) }
            return Response(status: .ok, body: .init(data: stored))
        case .HEAD:
            guard let stored = fake.object(path) else { return Response(status: .notFound) }
            return Response(status: .ok, headers: ["Content-Length": String(stored.count)])
        case .DELETE: fake.remove(path); return Response(status: .noContent)
        default: return Response(status: .methodNotAllowed)
        }
    }

    private func verify(_ request: Request, path: String, body: Data) -> Bool {
        guard let authorization = request.headers.first(name: .authorization), authorization.hasPrefix("AWS4-HMAC-SHA256 "),
              let date = request.headers.first(name: "x-amz-date"), let payloadHash = request.headers.first(name: "x-amz-content-sha256"),
              payloadHash == SigV4.sha256Hex(body) else { return false }
        var fields: [String: String] = [:]
        for part in authorization.dropFirst("AWS4-HMAC-SHA256 ".count).split(separator: ",") {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        guard let signedList = fields["SignedHeaders"], let given = fields["Signature"], fields["Credential"]?.hasPrefix(FakeS3.accessKey + "/") == true else { return false }
        let headers: [(String, String)] = signedList.split(separator: ";").map { name in
            (String(name), request.headers.first(name: String(name)) ?? "")
        }
        let expected = SigV4.sign(method: request.method.rawValue, path: path, query: [], headers: headers, payloadHash: payloadHash, amzDate: date,
                                  region: FakeS3.region, service: "s3", accessKeyId: FakeS3.accessKey, secret: FakeS3.secret)
        return expected.signature == given
    }
}

final class StorageUnitTests: XCTestCase, @unchecked Sendable {
    // MARK: SigV4

    func testSigV4AWSPublishedVectorGetVanilla() {
        // AWS Signature V4 test suite, "get-vanilla".
        let signed = SigV4.sign(method: "GET", path: "/", query: [], headers: [("Host", "example.amazonaws.com"), ("X-Amz-Date", "20150830T123600Z")],
                                payloadHash: SigV4.sha256Hex(Data()), amzDate: "20150830T123600Z", region: "us-east-1", service: "service",
                                accessKeyId: "AKIDEXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
        XCTAssertEqual(signed.canonicalRequest, "GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(signed.stringToSign, "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\nbb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63")
        XCTAssertEqual(signed.signature, "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
        XCTAssertEqual(signed.authorization, "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    func testSigV4AWSS3DocumentationExample() {
        // "GET Object" example of the S3 documentation (Range header, examplebucket).
        let empty = SigV4.sha256Hex(Data())
        let signed = SigV4.sign(method: "GET", path: "/test.txt", query: [],
                                headers: [("host", "examplebucket.s3.amazonaws.com"), ("range", "bytes=0-9"), ("x-amz-content-sha256", empty), ("x-amz-date", "20130524T000000Z")],
                                payloadHash: empty, amzDate: "20130524T000000Z", region: "us-east-1", service: "s3",
                                accessKeyId: "AKIAIOSFODNN7EXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        XCTAssertEqual(signed.signature, "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    func testSigV4QueryIsSortedAndEncoded() {
        let signed = SigV4.sign(method: "GET", path: "/", query: [("b", "2 3"), ("a", "x/y")], headers: [("host", "h")], payloadHash: "p",
                                amzDate: "20150830T123600Z", region: "r", service: "s", accessKeyId: "k", secret: "s")
        XCTAssertTrue(signed.canonicalRequest.hasPrefix("GET\n/\na=x%2Fy&b=2%203\n"))
    }

    func testS3RequestPreparationPathAndVirtualHosted() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        func client(pathStyle: Bool, endpoint: String) -> S3Client {
            S3Client(configuration: .init(endpoint: endpoint, region: "eu-1", bucket: "my-bucket", pathStyle: pathStyle, accessKeyId: "AK", secretAccessKey: "SK"),
                     client: app.client, now: { fixed })
        }
        let key = "ab/cd/abcd0000-0000-0000-0000-000000000000"
        let path = try client(pathStyle: true, endpoint: "http://127.0.0.1:9090").prepare(method: "PUT", key: key, payload: Data("x".utf8))
        XCTAssertEqual(path.url, "http://127.0.0.1:9090/my-bucket/\(key)")
        let virtual = try client(pathStyle: false, endpoint: "https://s3.eu-1.example.com").prepare(method: "GET", key: key, payload: Data())
        XCTAssertEqual(virtual.url, "https://my-bucket.s3.eu-1.example.com/\(key)")
        XCTAssertEqual(virtual.headers.first { $0.0 == "x-amz-date" }?.1, "20231114T221320Z")
        let auth = try XCTUnwrap(virtual.headers.first { $0.0 == "authorization" }?.1)
        XCTAssertTrue(auth.contains("Credential=AK/20231114/eu-1/s3/aws4_request"))
        XCTAssertTrue(auth.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date"))
        XCTAssertFalse(auth.contains("SK"))
        XCTAssertThrowsError(try client(pathStyle: true, endpoint: "ftp://x").prepare(method: "GET", key: key, payload: Data()))
    }

    func testS3ClientAgainstFakeServer() async throws {
        let fake = try await FakeS3.start()
        let app = try await Application.make(.testing)
        do {
            func s3(secret: String = FakeS3.secret) -> S3Client {
                S3Client(configuration: .init(endpoint: fake.endpoint, region: FakeS3.region, bucket: FakeS3.bucket, pathStyle: true,
                                              accessKeyId: FakeS3.accessKey, secretAccessKey: secret), client: app.client)
            }
            let key = "ab/cd/abcd0000-0000-0000-0000-000000000001"
            let payload = Data((0..<5000).map { UInt8($0 % 251) })
            try await s3().put(key: key, data: payload)
            XCTAssertEqual(fake.object("/\(FakeS3.bucket)/\(key)"), payload)
            let loaded = try await s3().get(key: key)
            XCTAssertEqual(loaded, payload)
            let size = try await s3().head(key: key)
            XCTAssertNotNil(size)   // existence; the fake's HEAD framing does not carry the length
            try await s3().delete(key: key)
            XCTAssertNil(fake.object("/\(FakeS3.bucket)/\(key)"))
            let missing = try await s3().head(key: key)
            XCTAssertNil(missing)
            try await s3().delete(key: key)   // idempotent
            // A wrong secret is rejected by signature verification, and the error does not echo credentials.
            do { try await s3(secret: "wrong").put(key: key, data: payload); XCTFail("expected failure") }
            catch { let text = "\(error)"; XCTAssertFalse(text.contains("wrong")); XCTAssertFalse(text.contains(FakeS3.secret)); XCTAssertFalse(text.contains(FakeS3.accessKey)) }
            XCTAssertGreaterThanOrEqual(fake.rejected, 1)
            // Unreachable endpoint: bounded by a timeout, plain error.
            var broken = s3(); broken.timeout = .seconds(2)
            broken = S3Client(configuration: .init(endpoint: "http://127.0.0.1:1", region: "r", bucket: "b", pathStyle: true, accessKeyId: "a", secretAccessKey: "s"),
                              client: app.client, timeout: .seconds(2))
            do { _ = try await broken.get(key: key); XCTFail("expected failure") } catch is StorageBackendError {}
        } catch { try await app.asyncShutdown(); try await fake.stop(); throw error }
        try await app.asyncShutdown(); try await fake.stop()
    }

    // MARK: Rules

    func testRuleSelectionAtBoundaries() {
        let rules = [StorageRule(maxBytes: 100, backend: .db), StorageRule(maxBytes: 1000, backend: .local), StorageRule(maxBytes: nil, backend: .s3)]
        XCTAssertEqual(StorageRules.select(rules, size: 1), .db)
        XCTAssertEqual(StorageRules.select(rules, size: 100), .db)
        XCTAssertEqual(StorageRules.select(rules, size: 101), .local)
        XCTAssertEqual(StorageRules.select(rules, size: 1000), .local)
        XCTAssertEqual(StorageRules.select(rules, size: 1001), .s3)
        XCTAssertEqual(StorageRules.select([StorageRule(maxBytes: nil, backend: .local)], size: 5), .local)
    }

    func testRuleValidation() throws {
        try StorageRules.validate([.init(maxBytes: nil, backend: .db)])
        try StorageRules.validate([.init(maxBytes: 10, backend: .db), .init(maxBytes: 20, backend: .local), .init(maxBytes: nil, backend: .db)])
        let bad: [[StorageRule]] = [
            [], [.init(maxBytes: 10, backend: .db)],                                            // last must be unlimited
            [.init(maxBytes: nil, backend: .db), .init(maxBytes: nil, backend: .local)],        // unlimited only last
            [.init(maxBytes: 20, backend: .db), .init(maxBytes: 20, backend: .local), .init(maxBytes: nil, backend: .db)],  // not increasing
            [.init(maxBytes: 30, backend: .db), .init(maxBytes: 20, backend: .local), .init(maxBytes: nil, backend: .db)],
            [.init(maxBytes: 0, backend: .db), .init(maxBytes: nil, backend: .db)],
            [.init(maxBytes: -1, backend: .db), .init(maxBytes: nil, backend: .db)],
        ]
        for rules in bad { XCTAssertThrowsError(try StorageRules.validate(rules), "\(rules)") }
    }

    // MARK: Secret box

    func testSecretBoxRoundtripAndKeyHandling() throws {
        let key = Data((0..<32).map { UInt8($0) }).base64EncodedString()
        let box = try XCTUnwrap(SecretBox(base64Key: key))
        let sealed = try box.seal("super-secret")
        XCTAssertFalse(String(decoding: sealed.ciphertext, as: UTF8.self).contains("super-secret"))
        XCTAssertEqual(try box.open(ciphertext: sealed.ciphertext, nonce: sealed.nonce), "super-secret")
        XCTAssertNotEqual(try box.seal("super-secret").nonce, sealed.nonce)
        let other = try XCTUnwrap(SecretBox(base64Key: Data(repeating: 7, count: 32).base64EncodedString()))
        XCTAssertThrowsError(try other.open(ciphertext: sealed.ciphertext, nonce: sealed.nonce))
        var tampered = sealed.ciphertext; tampered[0] ^= 1
        XCTAssertThrowsError(try box.open(ciphertext: tampered, nonce: sealed.nonce))
        for invalid in [nil, "", "not base64!!", Data(repeating: 1, count: 16).base64EncodedString(), Data(repeating: 1, count: 33).base64EncodedString()] {
            XCTAssertNil(SecretBox(base64Key: invalid), invalid ?? "nil")
        }
    }

    // MARK: Sniffing and names

    func testTypeSniffingAndConsistency() {
        let pdf = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x20, count: 20)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0, count: 20)
        let jpg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: 20)
        let heic = Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8) + Data(repeating: 0, count: 12)
        let text = Data("Krankmeldung vom Arzt\nÄÖÜ\n".utf8)
        XCTAssertEqual(FileTypeSniffer.verify(data: pdf, filename: "a.pdf", declaredMime: "application/pdf"), FileTypeSniffer.pdf)
        XCTAssertEqual(FileTypeSniffer.verify(data: png, filename: "a.PNG", declaredMime: "application/octet-stream"), FileTypeSniffer.png)
        XCTAssertEqual(FileTypeSniffer.verify(data: jpg, filename: "a.jpeg", declaredMime: "image/jpeg"), FileTypeSniffer.jpg)
        XCTAssertEqual(FileTypeSniffer.verify(data: heic, filename: "a.heic", declaredMime: nil), FileTypeSniffer.heic)
        XCTAssertEqual(FileTypeSniffer.verify(data: text, filename: "a.txt", declaredMime: "text/plain"), FileTypeSniffer.txt)
        XCTAssertEqual(FileTypeSniffer.verify(data: png, filename: "noext", declaredMime: nil), FileTypeSniffer.png)
        // PNG content named .pdf, PDF content declared as PNG, executables, NUL bytes, unknown extension.
        XCTAssertNil(FileTypeSniffer.verify(data: png, filename: "a.pdf", declaredMime: "application/pdf"))
        XCTAssertNil(FileTypeSniffer.verify(data: pdf, filename: "a.pdf", declaredMime: "image/png"))
        XCTAssertNil(FileTypeSniffer.verify(data: Data([0x7F, 0x45, 0x4C, 0x46, 0, 0, 0, 0]), filename: "a.txt", declaredMime: nil))
        XCTAssertNil(FileTypeSniffer.verify(data: Data([0x4D, 0x5A, 0x90, 0x00, 0x03]), filename: "a.pdf", declaredMime: nil))
        XCTAssertNil(FileTypeSniffer.verify(data: pdf, filename: "a.exe", declaredMime: nil))
        XCTAssertNil(FileTypeSniffer.verify(data: text, filename: "a.pdf", declaredMime: nil))
        XCTAssertNil(FileTypeSniffer.verify(data: Data(), filename: "a.txt", declaredMime: nil))
        XCTAssertNil(FileTypeSniffer.verify(data: Data("abc\0def".utf8), filename: "a.txt", declaredMime: nil))
    }

    func testFilenameSanitization() {
        XCTAssertEqual(FilenameSanitizer.sanitize("../../etc/passwd"), "passwd")
        XCTAssertEqual(FilenameSanitizer.sanitize("C:\\Users\\x\\bad:name?.pdf"), "bad_name_.pdf")
        XCTAssertEqual(FilenameSanitizer.sanitize("  ..hidden.txt. "), "hidden.txt")
        XCTAssertEqual(FilenameSanitizer.sanitize("a\u{0}b\u{7}c\nd.pdf"), "a_b_c_d.pdf")
        XCTAssertEqual(FilenameSanitizer.sanitize("..."), "file")
        XCTAssertEqual(FilenameSanitizer.sanitize(""), "file")
        XCTAssertEqual(FilenameSanitizer.sanitize("Attest Ärztin.pdf"), "Attest Ärztin.pdf")
        XCTAssertEqual(FilenameSanitizer.sanitize("scan", fallbackExtension: "png"), "scan.png")
        let long = FilenameSanitizer.sanitize(String(repeating: "x", count: 500) + ".pdf")
        XCTAssertEqual(long.unicodeScalars.count, 120); XCTAssertTrue(long.hasSuffix(".pdf"))
        let header = FilenameSanitizer.contentDisposition("Attest \"Ärztin\".pdf")
        XCTAssertTrue(header.hasPrefix("attachment; filename=\"Attest _"))
        XCTAssertTrue(header.contains("filename*=UTF-8''Attest%20%22%C3%84rztin%22.pdf"))
    }

    // MARK: Local adapter

    private func tempRoot() throws -> String {
        let path = NSTemporaryDirectory() + "tt-storage-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
    private func mode(_ path: String) throws -> Int { try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) & 0o777 }

    func testLocalAdapterRoundtripPermissionsAndAtomicWrite() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let backend = LocalFSBackend(root: root)
        let id = UUID(), key = StorageKeys.make(for: id, kind: .local)
        XCTAssertTrue(StorageKeys.isValidShardedKey(key))
        let data = Data((0..<100_000).map { UInt8($0 % 256) })
        let sqlDB = try await Application.make(.testing)
        sqlDB.databases.use(.sqlite(.memory), as: .sqlite)
        defer { Task { try? await sqlDB.asyncShutdown() } }
        try await backend.put(key: key, data: data, db: sqlDB.db)
        let file = root + "/" + key
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(root + "/" + key.split(separator: "/")[0]), 0o700)
        XCTAssertEqual(try mode(root + "/" + key.split(separator: "/")[0...1].joined(separator: "/")), 0o700)
        let loaded = try await backend.get(key: key, db: sqlDB.db)
        XCTAssertEqual(loaded, data)
        // No temp files remain; overwriting replaces atomically.
        try await backend.put(key: key, data: Data("new".utf8), db: sqlDB.db)
        let replaced = try await backend.get(key: key, db: sqlDB.db)
        XCTAssertEqual(replaced, Data("new".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: (file as NSString).deletingLastPathComponent)
        XCTAssertEqual(leftovers, [id.uuidString.lowercased()])
        try await backend.delete(key: key, db: sqlDB.db)
        try await backend.delete(key: key, db: sqlDB.db)   // idempotent
        do { _ = try await backend.get(key: key, db: sqlDB.db); XCTFail("expected missing") } catch is StorageBackendError {}
    }

    func testLocalAdapterRejectsTraversalAndSymlinks() async throws {
        let root = try tempRoot(), outside = try tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: outside) }
        let app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        defer { Task { try? await app.asyncShutdown() } }
        let backend = LocalFSBackend(root: root)
        for key in ["../x", "ab/cd/../../x", "/etc/passwd", "ab/cd/" + UUID().uuidString, "zz/cd/" + UUID().uuidString.lowercased(), "ab/cd", "", "ab//" + UUID().uuidString.lowercased()] {
            do { try await backend.put(key: key, data: Data("x".utf8), db: app.db); XCTFail("accepted \(key)") } catch is StorageBackendError {}
            do { _ = try await backend.get(key: key, db: app.db); XCTFail("accepted \(key)") } catch is StorageBackendError {}
            do { try await backend.delete(key: key, db: app.db); XCTFail("accepted \(key)") } catch is StorageBackendError {}
        }
        // A shard directory replaced by a symlink to an outside directory must not be followed.
        let id = UUID(), key = StorageKeys.make(for: id, kind: .local)
        let first = String(key.split(separator: "/")[0])
        try FileManager.default.createSymbolicLink(atPath: root + "/" + first, withDestinationPath: outside)
        do { try await backend.put(key: key, data: Data("secret".utf8), db: app.db); XCTFail("followed symlink") } catch is StorageBackendError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside), [])
        try FileManager.default.removeItem(atPath: root + "/" + first)
        // A file that is itself a symlink is not readable and not followed on delete.
        try await backend.put(key: key, data: Data("real".utf8), db: app.db)
        let secret = outside + "/secret.txt"
        try Data("outside".utf8).write(to: URL(fileURLWithPath: secret))
        try FileManager.default.removeItem(atPath: root + "/" + key)
        try FileManager.default.createSymbolicLink(atPath: root + "/" + key, withDestinationPath: secret)
        do { _ = try await backend.get(key: key, db: app.db); XCTFail("read through symlink") } catch is StorageBackendError {}
        // Writing replaces the link itself and leaves the target untouched.
        try await backend.put(key: key, data: Data("replaced".utf8), db: app.db)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: secret)), Data("outside".utf8))
        let replaced = try await backend.get(key: key, db: app.db)
        XCTAssertEqual(replaced, Data("replaced".utf8))
        // Missing / relative root.
        do { try await LocalFSBackend(root: root + "/missing").put(key: key, data: Data("x".utf8), db: app.db); XCTFail() } catch is StorageBackendError {}
        do { try await LocalFSBackend(root: "relative").put(key: key, data: Data("x".utf8), db: app.db); XCTFail() } catch is StorageBackendError {}
    }

    func testLocalRootValidation() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try LocalFSBackend.validateRoot(root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), [])   // probe file removed
        for bad in ["", "relative/path", "/", root + "/missing", root + "/../etc", "/etc/hosts"] {
            XCTAssertThrowsError(try LocalFSBackend.validateRoot(bad), bad)
        }
        let locked = root + "/locked"
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o500])
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked) }
        if getuid() != 0 { XCTAssertThrowsError(try LocalFSBackend.validateRoot(locked)) }
    }
}
