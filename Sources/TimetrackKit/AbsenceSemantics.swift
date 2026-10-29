import Foundation

/// Which absence statuses are meaningful per kind (C3, ADR-0032). Only vacation is requested and approved; sick days,
/// exemptions (Freistellung) and other absences are recorded facts or notes. Older clients that still send the vacation
/// workflow for those kinds are accepted and normalised instead of rejected.
enum AbsenceSemantics {
    /// The statuses that are stored for a kind.
    static func allowedStatuses(for kind: AbsenceKind) -> [AbsenceStatus] {
        switch kind {
        case .vacation: [.planned, .requested, .approved, .rejected, .cancelled, .taken]
        case .sick, .excused: [.recorded, .cancelled]
        case .other: [.planned, .recorded, .cancelled]
        }
    }

    /// Default when a client sends no status.
    static func defaultStatus(for kind: AbsenceKind) -> AbsenceStatus { kind == .vacation ? .planned : .recorded }

    /// Maps the submitted status to the stored one. `recorded` on vacation and `rejected` on kinds without an approval
    /// are 400 `absence_status_invalid_for_kind`; the other legacy workflow values are normalised:
    /// sick/excused: planned, requested, approved, taken -> recorded; other: requested -> planned, approved, taken -> recorded.
    static func normalise(kind: AbsenceKind, status: AbsenceStatus) throws -> AbsenceStatus {
        if allowedStatuses(for: kind).contains(status) { return status }
        switch (kind, status) {
        case (.sick, .planned), (.sick, .requested), (.sick, .approved), (.sick, .taken),
             (.excused, .planned), (.excused, .requested), (.excused, .approved), (.excused, .taken),
             (.other, .approved), (.other, .taken): return .recorded
        case (.other, .requested): return .planned
        default: throw APIError(.badRequest, "absence_status_invalid_for_kind")
        }
    }
}
