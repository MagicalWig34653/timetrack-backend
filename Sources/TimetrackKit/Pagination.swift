import Foundation

/// Central, overflow-safe offset/limit handling for every paged list (F01). Values come straight from clients (REST query
/// strings and MCP arguments), so `Int.max` is a legal decoded value: it is rejected here instead of reaching `offset + limit`.
enum Pagination {
    /// Largest accepted offset; no list holds more rows than this per account, and deeper paging is not a use case.
    static let maxOffset = 100_000

    /// Validates `limit` (1...`maxLimit`) and `offset` (0...`maxOffset`) and returns the row range `offset..<offset + limit`.
    /// Throws `APIError.invalid` (400) for anything outside; the addition cannot overflow because both operands are bounded.
    static func range(limit: Int, offset: Int, maxLimit: Int) throws -> Range<Int> {
        guard (1...maxLimit).contains(limit), (0...maxOffset).contains(offset) else { throw APIError.invalid }
        let (end, overflow) = offset.addingReportingOverflow(limit)
        guard !overflow else { throw APIError.invalid }
        return offset..<end
    }
}
