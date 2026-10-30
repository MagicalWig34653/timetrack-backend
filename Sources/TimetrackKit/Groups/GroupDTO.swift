import Foundation

// Wire shapes of the groups module. Public shapes never contain account data (no owner name, handle or id).

struct PollOptionInput: Decodable {
    var label: String?
    var date: String?
    var startTime: String?
    var endTime: String?
}

struct PollInput: Decodable {
    var title: String
    var description: String?
    var kind: String
    var choiceMode: String
    var timeZone: String?
    var options: [PollOptionInput]
    var deadline: Date?
    var hideResults: Bool?
}

/// Merge patch: absent keys stay, `null` clears `description` and `deadline`.
struct PollPatch: Decodable {
    var title: String?
    var description: String??
    var deadline: Date??
    var hideResults: Bool?
    enum CodingKeys: String, CodingKey { case title, description, deadline, hideResults }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        hideResults = try container.decodeIfPresent(Bool.self, forKey: .hideResults)
        description = container.contains(.description) ? .some(try container.decodeIfPresent(String.self, forKey: .description)) : nil
        deadline = container.contains(.deadline) ? .some(try container.decodeIfPresent(Date.self, forKey: .deadline)) : nil
    }
}

struct PollFinalInput: Decodable { var optionId: UUID? }

struct PollAnswerInput: Decodable {
    var optionId: UUID
    var answer: String
}

struct VoteInput: Decodable {
    var name: String
    var answers: [PollAnswerInput]
}

struct PollOptionDTO: Encodable {
    var id: UUID
    var label: String?
    var date: String?
    var startTime: String?
    var endTime: String?
}

struct PollAnswerDTO: Encodable {
    var optionId: UUID
    var answer: String
}

struct PollVoteDTO: Encodable {
    var id: UUID
    var name: String
    var answers: [PollAnswerDTO]
    var createdAt: Date
    var updatedAt: Date
}

struct PollTallyDTO: Encodable {
    var optionId: UUID
    var yes: Int
    var maybe: Int
    var no: Int
}

/// Owner view (`id`, link data) and public view share this shape; `votes` and `tally` are absent while results are hidden.
struct PollDTO: Encodable {
    var id: UUID?
    var title: String
    var description: String?
    var kind: String
    var choiceMode: String
    var timeZone: String?
    var options: [PollOptionDTO]
    var deadline: Date?
    var hideResults: Bool
    var closed: Bool
    var closedAt: Date?
    var finalOptionId: UUID?
    var resultsVisible: Bool
    var voteCount: Int
    var votes: [PollVoteDTO]?
    var tally: [PollTallyDTO]?
    var createdAt: Date?
    var updatedAt: Date?
    /// Only in the response that creates or rotates the link.
    var token: String?
    var path: String?
}

struct PollSummaryDTO: Encodable {
    var id: UUID
    var title: String
    var kind: String
    var choiceMode: String
    var deadline: Date?
    var closed: Bool
    var closedAt: Date?
    var voteCount: Int
    var createdAt: Date
}

struct VoteCreatedDTO: Encodable {
    var vote: PollVoteDTO
    /// Shown once; the client keeps it to edit or delete the vote later (header `X-Edit-Secret`).
    var editSecret: String
}

// MARK: Orders

struct OrderInput: Decodable {
    var title: String
    var note: String?
    var deadline: Date?
    var catalogId: UUID?
}

struct OrderPatch: Decodable {
    var title: String?
    var note: String??
    var deadline: Date??
    var catalogId: UUID??
    enum CodingKeys: String, CodingKey { case title, note, deadline, catalogId }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        note = container.contains(.note) ? .some(try container.decodeIfPresent(String.self, forKey: .note)) : nil
        deadline = container.contains(.deadline) ? .some(try container.decodeIfPresent(Date.self, forKey: .deadline)) : nil
        catalogId = container.contains(.catalogId) ? .some(try container.decodeIfPresent(UUID.self, forKey: .catalogId)) : nil
    }
}

struct EntryInput: Decodable {
    var name: String
    var item: String
    var note: String?
    var quantity: Int?
    var priceCents: Int?
}

struct EntryTakeInput: Decodable {
    var name: String
    var quantity: Int?
    var note: String?
}

struct EntryDTO: Encodable {
    var id: UUID
    var name: String
    var item: String
    var note: String?
    var quantity: Int
    var priceCents: Int?
    var createdAt: Date
    var updatedAt: Date
}

struct EntryCreatedDTO: Encodable {
    var entry: EntryDTO
    var editSecret: String
}

struct AggregatedItemDTO: Encodable {
    var item: String
    var note: String?
    var priceCents: Int?
    var quantity: Int
    var names: [String]
}

struct CatalogItemDTO: Codable {
    var name: String
    var priceCents: Int?
}

struct OrderDTO: Encodable {
    var id: UUID?
    var title: String
    var note: String?
    var deadline: Date?
    var closed: Bool
    var closedAt: Date?
    var catalogId: UUID?
    var entryCount: Int
    var entries: [EntryDTO]
    var aggregated: [AggregatedItemDTO]
    /// Sum of quantity times price over priced entries, in cents.
    var totalCents: Int
    var unpricedQuantity: Int
    /// Items of the selected catalog, offered as suggestions in the entry form.
    var suggestions: [CatalogItemDTO]
    var createdAt: Date?
    var token: String?
    var path: String?
}

struct OrderSummaryDTO: Encodable {
    var id: UUID
    var title: String
    var deadline: Date?
    var closed: Bool
    var closedAt: Date?
    var entryCount: Int
    var createdAt: Date
}

struct ItemSuggestionDTO: Encodable {
    var item: String
    var priceCents: Int?
    var count: Int
}

/// What a link token resolves to.
struct PublicGroupDTO: Encodable {
    var type: String
    var poll: PollDTO?
    var order: OrderDTO?
}

// MARK: Catalogs

struct CatalogInput: Decodable {
    var name: String
    var items: [CatalogItemDTO]
}

struct CatalogDTO: Encodable {
    var id: UUID
    var name: String
    var items: [CatalogItemDTO]
    var itemCount: Int
    var createdAt: Date
    var updatedAt: Date
}
