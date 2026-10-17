import Foundation
import Fluent
import FluentSQL
import XCTVapor
import ZIPFoundation
@testable import TimetrackKit

extension AuthTests {
    func scenarioC19IntegerAndDateBoundaries(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db)
        for value in [Int.min, Int.max] {
            try await api(app, owner, .POST, "vacation/adjustments", ["date": "2026-10-15", "halfDays": value, "reason": "Boundary"], .badRequest)
            try await api(app, owner, .POST, "time/account/adjustments", ["date": "2026-10-15", "kind": "correction", "seconds": value, "reason": "Boundary"], .badRequest)
        }
        let recipient = try await second(app, auth, owner)
        let share = try object(await api(app, owner, .POST, "shares", ["recipientHandle": recipient.account.handle, "scopes": ["plan": true, "actual": true, "vacation": true]], .created))
        let shareID = try XCTUnwrap(share["id"] as? String)
        try await api(app, owner, .POST, "work-models", modelBody("0001-01-01"), .created)
        for date in ["0001-01-01", "9999-12-31"] {
            for path in ["plan/days", "absences", "time/days"] {
                try await api(app, owner, .GET, path + "?from=\(date)&to=\(date)")
            }
            try await api(app, recipient, .GET, "shares/incoming/\(shareID)/view?from=\(date)&to=\(date)")
            try await api(app, owner, .GET, "export/time?from=\(date)&to=\(date)&format=csv")
            let year = String(date.prefix(4))
            try await api(app, owner, .GET, "reports/weeks/\(year)/1", nil, .badRequest)
            try await api(app, owner, .GET, "calendar/holidays?year=\(year)", nil, .badRequest)
        }
        try await api(app, owner, .POST, "time/segments", ["kind": "work", "startedAt": "999999999-01-01T00:00:00Z", "endedAt": "999999999-01-01T01:00:00Z"], .badRequest)
    }

    func scenarioC19OAuthBindingAndAdmission(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db)
        let client = try await oaRegister(app)
        let foreign = try await oaRegister(app, name: "Foreign")
        let flow = try await oaFlow(app, owner, client: client)
        for form in [oaCodeForm(flow, client: foreign), oaCodeForm(flow, verifier: Secrets.token(bytes: 32))] {
            try await eq((try await oaToken(app, form)).status, .badRequest)
            let record = try await OAuthCode.query(on: app.db).filter(\.$codeHash == Secrets.hash(flow.code)).first()
            XCTAssertNil(record?.consumedAt)
            let grant = try await OAuthGrant.find(record?.grantId, on: app.db)
            XCTAssertNil(grant?.revokedAt)
        }
        _ = try await oaExchange(app, flow)
        try await eq((try await oaToken(app, oaCodeForm(flow, client: foreign))).status, .badRequest)
        let code = try await need(try await OAuthCode.query(on: app.db).filter(\.$codeHash == Secrets.hash(flow.code)).first())
        let grant = try await OAuthGrant.find(code.grantId, on: app.db)
        XCTAssertNil(grant?.revokedAt)
        // Unknown credentials must leave the global lock's toggle unchanged.
        var unknownCode = oaCodeForm(flow); unknownCode["code"] = Secrets.token(bytes: 32)
        for form in [unknownCode, ["grant_type": "refresh_token", "client_id": client, "refresh_token": OAuthTokenFormat.make(OAuthTokenFormat.refreshPrefix)]] {
            let before = try await requireSQL(app.db).raw("SELECT value FROM auth_lock WHERE id = 1").first()?.decode(column: "value", as: Int.self)
            try await eq((try await oaToken(app, form)).status, .badRequest)
            let after = try await requireSQL(app.db).raw("SELECT value FROM auth_lock WHERE id = 1").first()?.decode(column: "value", as: Int.self)
            XCTAssertEqual(before, after)
        }
        // Unknown credentials exhaust only the process-local limiter, never entering auth_lock.
        for _ in 0..<120 {
            _ = try await oaToken(app, ["grant_type": "refresh_token", "client_id": foreign, "refresh_token": "malformed"])
        }
        try await eq((try await oaToken(app, ["client_id": foreign, "grant_type": "refresh_token", "refresh_token": "malformed"])).status, .tooManyRequests)
    }

    func scenarioC19StorageLocations(_ app: Application, _ auth: AuthService) async throws {
        let (owner, _) = try await registered(auth, db: app.db)
        let a = try tempDirectory(), b = try tempDirectory()
        defer { try? FileManager.default.removeItem(atPath: a); try? FileManager.default.removeItem(atPath: b) }
        try await api(app, owner, .PUT, "admin/storage", ["rules": [rule(nil, "local")], "localPath": a])
        let id = try fileID(await fileUpload(app, owner, "location.txt", Self.txt))
        try await api(app, owner, .PUT, "admin/storage", ["rules": [rule(nil, "local")], "localPath": b])
        _ = try await download(app, owner, id)
        try await api(app, owner, .DELETE, "files/" + id, nil, .noContent)
        XCTAssertTrue(diskFiles(a).isEmpty); XCTAssertTrue(diskFiles(b).isEmpty)
        // An S3 location change cannot borrow the new bucket's successful DELETE response.
        let objects = C19ObjectStore()
        app.storageEnvironment.secretKey = { Self.testKey }
        app.storageEnvironment.decorate = { backend in
            guard let s3 = backend as? S3Backend else { return backend }
            return C19ObjectBackend(bucket: s3.client.configuration.bucket, objects: objects)
        }
        var s3: [String: Any] = ["endpoint": "https://s3.example.test", "region": "eu-1", "bucket": "bucket-a", "accessKeyId": "test", "secretAccessKey": "test-secret"]
        try await api(app, owner, .PUT, "admin/storage", ["rules": [rule(nil, "s3")], "s3": s3])
        let s3ID = try fileID(await fileUpload(app, owner, "s3.txt", Self.txt))
        // Re-run the migration on ONE connection: the in-memory SQLite pool has one connection per event loop, and
        // with fewer cores (CI) consecutive `app.db` calls land on different connections that do not see each other's DDL.
        try await app.db.withConnection { db in
            try await BindStorageLocations().revert(on: db)
            try await BindStorageLocations().prepare(on: db)
        }
        s3["bucket"] = "bucket-b"
        try await api(app, owner, .PUT, "admin/storage", ["rules": [rule(nil, "s3")], "s3": s3])
        _ = try await download(app, owner, s3ID, .serviceUnavailable)
        try await api(app, owner, .DELETE, "files/" + s3ID, nil, .serviceUnavailable)
        let retained = try await StoredFileRecord.find(UUID(uuidString: s3ID), on: app.db)
        XCTAssertEqual(retained?.state, "deleting"); XCTAssertEqual(retained?.cleanupAttempts, 1)
        try await eq(await objects.count, 1)
        s3["bucket"] = "bucket-a"
        try await api(app, owner, .PUT, "admin/storage", ["rules": [rule(nil, "s3")], "s3": s3])
        try await eq(try await storageService(app, auth).cleanup(), 1)
        try await eq(await objects.count, 0)

    }

    func testC19HTTPBoundariesSQLite() async throws { try await withApp(scenarioC19IntegerAndDateBoundaries) }
    func testC19OAuthSQLite() async throws { try await withApp(scenarioC19OAuthBindingAndAdmission) }
    func testC19StorageSQLite() async throws { try await withApp(scenarioC19StorageLocations) }
    func testC19RegressionsMariaDB() async throws {
        for scenario in [scenarioC19IntegerAndDateBoundaries, scenarioC19OAuthBindingAndAdmission, scenarioC19StorageLocations] {
            try await withApp(environment: mariaDBEnvironment(), scenario)
        }
    }
}

final class C19ParserAndPolicyTests: XCTestCase, @unchecked Sendable {
    func testTokenLimiterIPClientBudgetsAndExpiry() async throws {
        let limiter = OAuthTokenLimiter(), now = Date()
        for _ in 0..<1200 { try await limiter.admit(ip: "shared", now: now) }
        do { try await limiter.admit(ip: "shared", now: now); XCTFail("Expected IP limit") }
        catch let error as OAuthError { XCTAssertEqual(error.status, .tooManyRequests) }
        try await limiter.admit(ip: "other", now: now)
        for index in 0..<120 { try await limiter.admit(ip: "ip-\(index)", client: "client-a", now: now) }
        do { try await limiter.admit(ip: "new-ip", client: "client-a", now: now); XCTFail("Expected client limit") }
        catch let error as OAuthError { XCTAssertEqual(error.status, .tooManyRequests) }
        try await limiter.admit(ip: "new-ip", client: "client-b", now: now)
        try await limiter.admit(ip: "shared", now: now.addingTimeInterval(301))
        try await limiter.admit(ip: "new-ip", client: "client-a", now: now.addingTimeInterval(301))
    }
    func testDelimiterSampleStopsAfterFortyCompleteRecords() throws {
        for delimiter in [";", "\t"] {
            let text = "Date\(delimiter)Hours\(delimiter)Note\n" + String(repeating: "2026-10-15\(delimiter)7,5\(delimiter)\"two\nlines\"\n", count: 45)
            let rows = try CSVReader.read(Data(text.utf8))
            XCTAssertEqual(rows.count, 46); XCTAssertEqual(rows[1], ["2026-10-15", "7,5", "two\nlines"])
        }
    }
    func testXLSXRejectsInvalidRowBeforeCellsOrArithmetic() throws {
        for row in [String(Int.max), "20001", "-1", "not-a-number"] {
            for cells in ["", "<c r=\"A1\"><v>1</v></c>"] {
                let archive = try Archive(data: Data(), accessMode: .create)
                try TestXLSX.add(archive, "xl/workbook.xml", Data("<workbook><sheets><sheet name=\"Sheet\" r:id=\"r1\" xmlns:r=\"r\"/></sheets></workbook>".utf8))
                try TestXLSX.add(archive, "xl/_rels/workbook.xml.rels", Data("<Relationships><Relationship Id=\"r1\" Target=\"worksheets/sheet1.xml\"/></Relationships>".utf8))
                try TestXLSX.add(archive, "xl/worksheets/sheet1.xml", Data("<worksheet><sheetData><row r=\"\(row)\">\(cells)</row></sheetData></worksheet>".utf8))
                let data = try XCTUnwrap(archive.data)
                XCTAssertThrowsError(try ImportWorkbook.open(data: data, filename: "bad.xlsx").sheet("Sheet"))
            }
        }
    }
    func testZIP64SizeCannotOverflowArchiveBudget() throws {
        var data = try TestXLSX.build(sheets: [(name: "S", rows: [[.inline("x")]])])
        let signature = Data([0x50, 0x4b, 0x01, 0x02])
        var positions: [Int] = [], offset = 0
        while let range = data.range(of: signature, in: offset..<data.count) { positions.append(range.lowerBound); offset = range.upperBound }
        let central = try XCTUnwrap(positions.last)
        func read16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        let nameLength = read16(central + 28), extraLength = read16(central + 30)
        let insertion = central + 46 + nameLength + extraLength
        data.replaceSubrange((central + 24)..<(central + 28), with: [UInt8](repeating: 255, count: 4))
        let length = extraLength + 12
        data[central + 30] = UInt8(length & 255); data[central + 31] = UInt8(length >> 8)
        data.insert(contentsOf: [1, 0, 8, 0] + [UInt8](repeating: 255, count: 8), at: insertion)
        let end = try XCTUnwrap(data.range(of: Data([0x50, 0x4b, 0x05, 0x06]))).lowerBound
        let size = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[end + 12 + $1]) << (8 * $1) } + 12
        for index in 0..<4 { data[end + 12 + index] = UInt8((size >> (8 * index)) & 255) }
        XCTAssertThrowsError(try ImportWorkbook.open(data: data, filename: "huge.xlsx")) {
            XCTAssertEqual(($0 as? APIError)?.code, "file_too_large")
        }
    }
    func testExtremeDurationFormatting() {
        XCTAssertEqual(ExportFormat.duration(Int.min), "-2562047788015215:30")
        XCTAssertEqual(ExportFormat.signed(Int.min), "-2562047788015215:30")
        XCTAssertEqual(McpJSON.hm(Int.min), "-2562047788015215:30")
    }
    func testCivilDateRangeBoundariesAndHugeInstants() throws {
        for text in ["0001-01-01", "9999-12-31"] {
            let date = try LocalDate(text)
            XCTAssertNoThrow(try LocalDate.checkedRange(from: date, to: date, maxDays: 366))
        }
        let date = try LocalDate("9999-12-31")
        XCTAssertEqual(date.addingDays(1).year, 10000)
        let model = EngineWorkModel(validFrom: try LocalDate("2026-01-01"), weeklyTargetSeconds: 0, workdays: [])
        XCTAssertThrowsError(try TimeEngine.assignedDate(for: Date(timeIntervalSince1970: 1e100), model: model))
        XCTAssertNil(timeInstant("999999999-01-01T00:00:00Z"))
    }
    func testPushEndpointPolicyRejectsUnsafeClasses() {
        let policy = PushEndpointPolicy()
        for url in ["http://127.0.0.1/x", "http://localhost/x", "https://127.0.0.1/x", "https://[::1]/x", "https://10.1.2.3/x", "https://169.254.169.254/x", "https://100.64.0.1/x", "https://[fd00::1]/x", "https://localhost/x", "https://x.local/x", "https://example.com/x", "https://fcm.googleapis.com:8443/x", "https://fcm.googleapis.com.evil.test/x"] {
            XCTAssertNil(policy.endpoint(url), url)
        }
        for host in ["fcm.googleapis.com", "updates.push.services.mozilla.com", "wns.notify.windows.com", "web.push.apple.com", "x.push.apple.com"] {
            XCTAssertNotNil(policy.endpoint("https://" + host + "/x"))
        }
        for ip in ["0.0.0.0", "10.1.2.3", "127.0.0.1", "169.254.1.2", "172.16.0.1", "192.168.1.1", "100.64.1.1", "192.0.2.1", "198.18.0.1", "224.0.0.1", "::1", "::ffff:127.0.0.1", "fc00::1", "fe80::1", "2001:db8::1"] {
            XCTAssertFalse(PushEndpointPolicy.isPublicAddress(ip), ip)
        }
        XCTAssertTrue(PushEndpointPolicy.isPublicAddress("8.8.8.8"))
        XCTAssertTrue(PushEndpointPolicy.isPublicAddress("2606:4700:4700::1111"))
        var test = policy; test.pushAllowInsecureLoopback = true
        XCTAssertNotNil(test.endpoint("http://127.0.0.1:1234/x"))
    }
}

actor C19ObjectStore {
    var values: [String: Data] = [:]
    func put(_ key: String, _ data: Data) { values[key] = data }
    func get(_ key: String) -> Data? { values[key] }
    func delete(_ key: String) { values[key] = nil }
    var count: Int { values.count }
}
struct C19ObjectBackend: StorageBackend {
    let kind = StorageBackendKind.s3
    let bucket: String
    let objects: C19ObjectStore
    func put(key: String, data: Data, db: any Database) async throws { await objects.put(bucket + "/" + key, data) }
    func get(key: String, db: any Database) async throws -> Data {
        guard let value = await objects.get(bucket + "/" + key) else { throw StorageErrors.unavailable }
        return value
    }
    func delete(key: String, db: any Database) async throws { await objects.delete(bucket + "/" + key) }
}
