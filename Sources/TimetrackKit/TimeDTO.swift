import Foundation
import Vapor

struct WorkModelDTO: Content {
    var id: UUID?
    var createdAt: Date?
    var validFrom: LocalDate
    var validTo: LocalDate?
    var timezone: String?
    var weeklyTargetSeconds: Int
    var workdays: [Int]
    var dailyTargetSeconds: [String: Int]?
    var travelCountsAsWork: Bool?
    var roundingEnabled: Bool?
    var roundingMinutes: Int?
    var schoolFullDayThresholdSeconds: Int?
    var schoolCreditSeconds: Int?
    var dayBoundaryMinutes: Int?
    var fixedBreaks: [BreakInput]?
    /// Correction counter (M1); absent on versions created before it, which count as 1. Ignored on input.
    var version: Int?
    struct BreakInput: Content { var start: String; var end: String }
    func engine() throws -> EngineWorkModel {
        func time(_ text: String) throws -> LocalTime {
            let parts = text.split(separator: ":")
            guard text.count == 5, parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { throw APIError.invalid }
            return try LocalTime(hour: hour, minute: minute)
        }
        var targets: [Int: Int] = [:]
        for (key, value) in dailyTargetSeconds ?? [:] {
            guard let day = Int(key), String(day) == key else { throw APIError.invalid }
            targets[day] = value
        }
        let value = try EngineWorkModel(id: id ?? UUID(), validFrom: validFrom, validTo: validTo,
            timezone: timezone ?? "Europe/Berlin", weeklyTargetSeconds: weeklyTargetSeconds, workdays: Set(workdays),
            dailyTargetSeconds: targets, travelCountsAsWork: travelCountsAsWork ?? true, roundingEnabled: roundingEnabled ?? true,
            roundingMinutes: roundingMinutes ?? 15, schoolFullDayThresholdSeconds: schoolFullDayThresholdSeconds ?? 10800,
            schoolCreditSeconds: schoolCreditSeconds, dayBoundaryMinutes: dayBoundaryMinutes ?? 0,
            fixedBreaks: (fixedBreaks ?? []).map { try FixedBreak(start: time($0.start), end: time($0.end)) })
        try value.validate()
        return value
    }
}
struct PlaceDTO: Content {
    var id: UUID?
    var archived: Bool?
    var name: String
    var kind: String
    var automationMode: String
    var latitude: Double?
    var longitude: Double?
    var radiusMeters: Int?
    var confirmAfterSeconds: Int?
    var defaultSegmentKind: EngineSegmentKind?
    func validate() throws {
        guard name.count <= 80, ["office", "home", "customer", "school", "other"].contains(kind),
              ["direct", "suggest", "off"].contains(automationMode), radiusMeters.map({ $0 >= 20 }) ?? true,
              (confirmAfterSeconds ?? 300) >= 0 else { throw APIError.invalid }
    }
}
struct SegmentInput: Content {
    var kind: EngineSegmentKind
    var startedAt: Date
    var endedAt: Date?
    var placeId: UUID?
    var note: String?
}
// Preserve the distinction between an omitted nullable field and an explicit null.
struct SegmentCorrection: Decodable, Sendable {
    var startedAt: Date?
    var endedAt: Date?
    var kind: EngineSegmentKind?
    var placeId: UUID?
    var note: String?
    var reason: String
    var needsReview: Bool?
    var hasEnd: Bool
    var hasPlace: Bool
    var hasNote: Bool
    enum CodingKeys: String, CodingKey { case startedAt, endedAt, kind, placeId, note, reason, needsReview }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        kind = try c.decodeIfPresent(EngineSegmentKind.self, forKey: .kind)
        placeId = try c.decodeIfPresent(UUID.self, forKey: .placeId)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        reason = try c.decode(String.self, forKey: .reason)
        needsReview = try c.decodeIfPresent(Bool.self, forKey: .needsReview)
        hasEnd = c.contains(.endedAt); hasPlace = c.contains(.placeId); hasNote = c.contains(.note)
    }
}
struct TimerInput: Content { var clientEventId: UUID; var kind: EngineSegmentKind?; var placeId: UUID? }
struct DayInput: Decodable, Sendable {
    var mark: DayMarkKind?; var creditSeconds: Int?; var skipFixedBreaks: Bool?; var note: String?
    var hasCredit: Bool; var hasNote: Bool
    enum CodingKeys: String, CodingKey { case mark, creditSeconds, skipFixedBreaks, note }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mark = try c.decodeIfPresent(DayMarkKind.self, forKey: .mark)
        creditSeconds = try c.decodeIfPresent(Int.self, forKey: .creditSeconds)
        skipFixedBreaks = try c.decodeIfPresent(Bool.self, forKey: .skipFixedBreaks)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        hasCredit = c.contains(.creditSeconds); hasNote = c.contains(.note)
    }
}
struct AdjustmentInput: Content { var kind: String; var date: LocalDate; var seconds: Int; var reason: String }
struct AdjustmentDTO: Content {
    var id: UUID; var kind: String; var date: String; var seconds: Int; var reason: String; var createdAt: Date
}
struct AdjustmentPage: Content {
    var items: [AdjustmentDTO]; var total: Int; var limit: Int; var offset: Int
}
struct SuggestionDTO: Content {
    var id: UUID
    var type: String
    var placeId: UUID?
    var proposedStartedAt: Date?
    var proposedEndedAt: Date?
    var segmentId: UUID?
    var createdAt: Date
}
struct SuggestionAccept: Content { var startedAt: Date?; var endedAt: Date? }
struct DeviceTokenInput: Content { var name: String; var expiresInDays: Int? }
struct DeviceTokenDTO: Content {
    var id: UUID; var name: String; var scope: String; var createdAt: Date
    var expiresAt: Date?; var lastUsedAt: Date?; var token: String?
}
struct AutomationInput: Content {
    var eventId: UUID; var deviceId: String; var type: String; var placeId: UUID; var occurredAt: Date
    var latitude: Double?; var longitude: Double?
}
struct AutomationResult: Content { var result: String; var segmentId: UUID?; var suggestionId: UUID? }

func timeResponse<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) throws -> Response {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        let formatter = ISO8601DateFormatter()
        if date.timeIntervalSince1970.rounded() != date.timeIntervalSince1970 { formatter.formatOptions.insert(.withFractionalSeconds) }
        try container.encode(formatter.string(from: date))
    }
    return Response(status: status, headers: ["Content-Type": "application/json"], body: .init(data: try encoder.encode(value)))
}
func timeDecode<T: Decodable>(_ type: T.Type, request: Request) throws -> T {
    guard let body = request.body.data else { throw APIError.invalid }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let date = timeInstant(value) else { throw APIError.invalid }
        return date
    }
    return try decoder.decode(type, from: Data(body.readableBytesView))
}
extension String {
    /// Length limits count unicode scalars: MariaDB VARCHAR/utf8mb4 counts code points, not grapheme clusters,
    /// so a Swift `count` could admit values the column rejects (which would surface as a 500).
    func fitsColumn(_ limit: Int) -> Bool { unicodeScalars.count <= limit }
}
func validateReason(_ reason: String) throws {
    guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.fitsColumn(200) else { throw APIError.invalid }
}

func timeInstant(_ value: String) -> Date? {
    guard value.count >= 20, (try? LocalDate(String(value.prefix(10)))) != nil else { return nil }
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter.date(from: value)
}
