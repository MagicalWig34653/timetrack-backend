import Foundation
import Fluent
import Vapor

/// Order-round rules shared by the owner API and the public link API (ADR-0033).
enum OrderCore {
    static func entryDTO(_ row: GroupOrderEntryRecord) throws -> EntryDTO {
        try .init(id: row.requireID(), name: row.name, item: row.item, note: row.note, quantity: row.quantity,
                  priceCents: row.priceCents, createdAt: row.createdAt, updatedAt: row.updatedAt)
    }

    static func entries(_ orderId: UUID, on db: any Database) async throws -> [GroupOrderEntryRecord] {
        try await GroupOrderEntryRecord.query(on: db).filter(\.$orderId == orderId).sort(\.$createdAt).sort(\.$id).all()
    }

    /// Identical items (same text, note and price, ignoring case and spacing) are summed; names keep the entry order.
    static func aggregate(_ entries: [EntryDTO]) -> [AggregatedItemDTO] {
        var order: [String] = []
        var groups: [String: AggregatedItemDTO] = [:]
        for entry in entries {
            let key = [GroupText.key(entry.item), GroupText.key(entry.note ?? ""), entry.priceCents.map(String.init) ?? "-"].joined(separator: "\u{1F}")
            if groups[key] == nil {
                order.append(key)
                groups[key] = .init(item: entry.item, note: entry.note, priceCents: entry.priceCents, quantity: 0, names: [])
            }
            groups[key]!.quantity += entry.quantity
            if !groups[key]!.names.contains(entry.name) { groups[key]!.names.append(entry.name) }
        }
        return order.compactMap { groups[$0] }.sorted { ($0.quantity, $1.item.lowercased()) > ($1.quantity, $0.item.lowercased()) }
    }

    static func dto(_ order: GroupOrderRecord, on db: any Database, now: Date, owner: Bool, token: String? = nil) async throws -> OrderDTO {
        let id = try order.requireID()
        let shown = owner ? (token ?? order.linkToken) : nil
        let entries = try await entries(id, on: db).map(entryDTO)
        var suggestions: [CatalogItemDTO] = []
        if let catalogId = order.catalogId {
            suggestions = try await GroupCatalogItemRecord.query(on: db).filter(\.$catalogId == catalogId).sort(\.$position).all()
                .map { .init(name: $0.name, priceCents: $0.priceCents) }
        }
        var total = 0, unpriced = 0
        for entry in entries {
            if let price = entry.priceCents { total += price * entry.quantity } else { unpriced += entry.quantity }
        }
        return OrderDTO(id: owner ? id : nil, title: order.title, note: order.note, deadline: order.deadline, closed: order.isClosed(now),
                        closedAt: order.closedAt, catalogId: owner ? order.catalogId : nil, entryCount: entries.count, entries: entries,
                        aggregated: aggregate(entries), totalCents: total, unpricedQuantity: unpriced, suggestions: suggestions,
                        createdAt: owner ? order.createdAt : nil, token: shown, path: shown.map { "/g/" + $0 })
    }

    static func price(_ value: Int?) throws -> Int? {
        guard let value else { return nil }
        guard (0...GroupLimits.maxPriceCents).contains(value) else { throw APIError.invalid }
        return value
    }
    static func quantity(_ value: Int?) throws -> Int {
        let quantity = value ?? 1
        guard (1...GroupLimits.maxQuantity).contains(quantity) else { throw APIError.invalid }
        return quantity
    }

    private static func ensureRoom(_ orderId: UUID, now: Date, order: GroupOrderRecord, on db: any Database) async throws {
        guard !order.isClosed(now) else { throw GroupError.closed }
        guard try await GroupOrderEntryRecord.query(on: db).filter(\.$orderId == orderId).count() < GroupLimits.maxEntries else { throw GroupError.full }
    }

    static func addEntry(_ input: EntryInput, order: GroupOrderRecord, now: Date, on db: any Database) async throws -> EntryCreatedDTO {
        let orderId = try order.requireID()
        let name = try GroupText.requiredLine(input.name, max: GroupLimits.nameMax)
        let item = try GroupText.requiredLine(input.item, max: GroupLimits.textMax)
        let note = try GroupText.line(input.note, max: GroupLimits.textMax, required: false)
        let quantity = try quantity(input.quantity), price = try price(input.priceCents)
        try await ensureRoom(orderId, now: now, order: order, on: db)
        return try await insert(orderId: orderId, name: name, item: item, note: note, quantity: quantity, price: price, source: nil, now: now, on: db)
    }

    private static func insert(orderId: UUID, name: String, item: String, note: String?, quantity: Int, price: Int?, source: UUID?, now: Date,
                               on db: any Database) async throws -> EntryCreatedDTO {
        let secret = Secrets.token(bytes: 32)
        let row = GroupOrderEntryRecord()
        row.orderId = orderId; row.name = name; row.item = item; row.note = note; row.quantity = quantity; row.priceCents = price
        row.secretHash = Secrets.hash(secret); row.sourceEntryId = source; row.createdAt = now; row.updatedAt = now
        try await row.create(on: db)
        return .init(entry: try entryDTO(row), editSecret: secret)
    }

    /// Copies the item of an existing entry as a new entry of the caller (own name, own edit secret).
    static func takeEntry(_ id: UUID, input: EntryTakeInput, order: GroupOrderRecord, now: Date, on db: any Database) async throws -> EntryCreatedDTO {
        let orderId = try order.requireID()
        guard let source = try await GroupOrderEntryRecord.query(on: db).filter(\.$orderId == orderId).filter(\._$id == id).first() else { throw APIError.missing }
        let name = try GroupText.requiredLine(input.name, max: GroupLimits.nameMax)
        let note = input.note == nil ? source.note : try GroupText.line(input.note, max: GroupLimits.textMax, required: false)
        let quantity = try quantity(input.quantity)
        try await ensureRoom(orderId, now: now, order: order, on: db)
        return try await insert(orderId: orderId, name: name, item: source.item, note: note, quantity: quantity, price: source.priceCents,
                                source: id, now: now, on: db)
    }

    static func ownEntry(_ id: UUID, order: GroupOrderRecord, secret: String?, on db: any Database) async throws -> GroupOrderEntryRecord {
        guard let entry = try await GroupOrderEntryRecord.query(on: db).filter(\.$orderId == order.requireID()).filter(\._$id == id).first() else { throw APIError.missing }
        guard let secret, GroupTokens.matches(secret, hash: entry.secretHash) else { throw GroupError.editSecretInvalid }
        return entry
    }

    static func updateEntry(_ entry: GroupOrderEntryRecord, input: EntryInput, order: GroupOrderRecord, now: Date, on db: any Database) async throws -> EntryDTO {
        guard !order.isClosed(now) else { throw GroupError.closed }
        entry.name = try GroupText.requiredLine(input.name, max: GroupLimits.nameMax)
        entry.item = try GroupText.requiredLine(input.item, max: GroupLimits.textMax)
        entry.note = try GroupText.line(input.note, max: GroupLimits.textMax, required: false)
        entry.quantity = try quantity(input.quantity); entry.priceCents = try price(input.priceCents); entry.updatedAt = now
        try await entry.update(on: db)
        return try entryDTO(entry)
    }

    // MARK: Export

    private static func euros(_ cents: Int, comma: Bool) -> String {
        let text = String(format: "%d.%02d", cents / 100, cents % 100)
        return comma ? text.replacingOccurrences(of: ".", with: ",") : text
    }

    /// RFC 4180 CSV through the shared writer, which neutralises formula-looking text (`=`, `+`, `-`, `@`, tab, CR).
    static func csv(_ order: OrderDTO) -> Data {
        var out = CSVWriter.line(["Name", "Gericht", "Notiz", "Menge", "Einzelpreis (EUR)", "Summe (EUR)"].map { .text($0) })
        for entry in order.entries {
            out += CSVWriter.line([.text(entry.name), .text(entry.item), entry.note.map { .text($0) } ?? .empty, .text(String(entry.quantity)),
                                   entry.priceCents.map { .text(euros($0, comma: false)) } ?? .empty,
                                   entry.priceCents.map { .text(euros($0 * entry.quantity, comma: false)) } ?? .empty])
        }
        return Data(out.utf8)
    }

    static func text(_ order: OrderDTO) -> Data {
        var lines = [order.title, String(repeating: "=", count: min(40, max(3, order.title.count))), ""]
        lines.append("Zusammenfassung")
        for item in order.aggregated {
            var line = "\(item.quantity)x \(item.item)"
            if let note = item.note { line += " (\(note))" }
            if let price = item.priceCents { line += " - \(euros(price, comma: true)) EUR je Stück" }
            line += " [\(item.names.joined(separator: ", "))]"
            lines.append(line)
        }
        lines += ["", "Einzelne Einträge"]
        for entry in order.entries {
            var line = "\(entry.name): \(entry.quantity)x \(entry.item)"
            if let note = entry.note { line += " (\(note))" }
            if let price = entry.priceCents { line += " - \(euros(price * entry.quantity, comma: true)) EUR" }
            lines.append(line)
        }
        lines += ["", "Gesamt: \(euros(order.totalCents, comma: true)) EUR" + (order.unpricedQuantity > 0 ? " (ohne \(order.unpricedQuantity) Stück ohne Preis)" : "")]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func exportResponse(_ order: OrderDTO, format: String) throws -> Response {
        let isCSV: Bool
        switch format { case "csv": isCSV = true; case "txt": isCSV = false; default: throw APIError.invalid }
        let response = Response(status: .ok, body: .init(data: isCSV ? csv(order) : text(order)))
        response.headers.replaceOrAdd(name: .contentType, value: isCSV ? "text/csv; charset=utf-8" : "text/plain; charset=utf-8")
        response.headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=\"bestellung.\(isCSV ? "csv" : "txt")\"")
        return response.markGroupPublic()
    }
}

/// Owner side of order rounds.
struct OrderService: Sendable {
    let scope: TimeServices

    func record(_ id: UUID) async throws -> GroupOrderRecord {
        guard let row = try await GroupOrderRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$id == id).first() else { throw APIError.missing }
        return row
    }

    func list(now: Date = Date()) async throws -> [OrderSummaryDTO] {
        let rows = try await GroupOrderRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).sort(\.$createdAt, .descending).all()
        var result: [OrderSummaryDTO] = []
        for row in rows {
            let id = try row.requireID()
            let count = try await GroupOrderEntryRecord.query(on: scope.db).filter(\.$orderId == id).count()
            result.append(.init(id: id, title: row.title, deadline: row.deadline, closed: row.isClosed(now), closedAt: row.closedAt, entryCount: count, createdAt: row.createdAt))
        }
        return result
    }

    private func checkCatalog(_ id: UUID?) async throws {
        guard let id else { return }
        guard try await GroupCatalogRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\._$id == id).count() == 1 else { throw APIError.invalid }
    }

    func create(_ input: OrderInput, now: Date = Date()) async throws -> OrderDTO {
        let title = try GroupText.requiredLine(input.title, max: GroupLimits.titleMax)
        if let deadline = input.deadline { guard deadline > now else { throw APIError(.badRequest, "deadline_in_past") } }
        try await checkCatalog(input.catalogId)
        guard try await GroupOrderRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).count() < GroupLimits.maxOrdersPerAccount else {
            throw APIError(.conflict, "too_many_orders")
        }
        let (token, hash) = GroupTokens.create()
        let order = GroupOrderRecord()
        order.accountId = scope.accountId; order.tokenHash = hash; order.linkToken = token; order.title = title
        order.note = try GroupText.block(input.note, max: GroupLimits.descriptionMax)
        order.deadline = input.deadline; order.catalogId = input.catalogId; order.createdAt = now; order.updatedAt = now
        try await order.create(on: scope.db)
        return try await OrderCore.dto(order, on: scope.db, now: now, owner: true, token: token)
    }

    func get(_ id: UUID, now: Date = Date()) async throws -> OrderDTO {
        try await OrderCore.dto(try await record(id), on: scope.db, now: now, owner: true)
    }

    func patch(_ id: UUID, _ patch: OrderPatch, now: Date = Date()) async throws -> OrderDTO {
        let order = try await record(id)
        if let title = patch.title { order.title = try GroupText.requiredLine(title, max: GroupLimits.titleMax) }
        if let note = patch.note { order.note = try GroupText.block(note, max: GroupLimits.descriptionMax) }
        if let deadline = patch.deadline {
            if let value = deadline { guard value > now else { throw APIError(.badRequest, "deadline_in_past") } }
            order.deadline = deadline
        }
        if let catalog = patch.catalogId { try await checkCatalog(catalog); order.catalogId = catalog }
        order.updatedAt = now
        try await order.update(on: scope.db)
        return try await OrderCore.dto(order, on: scope.db, now: now, owner: true)
    }

    func close(_ id: UUID, now: Date = Date()) async throws -> OrderDTO {
        let order = try await record(id)
        if order.closedAt == nil { order.closedAt = now; order.updatedAt = now; try await order.update(on: scope.db) }
        return try await OrderCore.dto(order, on: scope.db, now: now, owner: true)
    }

    func reopen(_ id: UUID, now: Date = Date()) async throws -> OrderDTO {
        let order = try await record(id)
        order.closedAt = nil
        if let deadline = order.deadline, deadline <= now { order.deadline = nil }
        order.updatedAt = now
        try await order.update(on: scope.db)
        return try await OrderCore.dto(order, on: scope.db, now: now, owner: true)
    }

    func rotate(_ id: UUID, now: Date = Date()) async throws -> OrderDTO {
        let order = try await record(id)
        let (token, hash) = GroupTokens.create()
        order.tokenHash = hash; order.linkToken = token; order.updatedAt = now
        try await order.update(on: scope.db)
        return try await OrderCore.dto(order, on: scope.db, now: now, owner: true, token: token)
    }

    func removeEntry(_ id: UUID, entryId: UUID) async throws {
        _ = try await record(id)
        guard try await GroupOrderEntryRecord.query(on: scope.db).filter(\.$orderId == id).filter(\._$id == entryId).count() == 1 else { throw APIError.missing }
        try await GroupOrderEntryRecord.query(on: scope.db).filter(\._$id == entryId).delete()
    }

    func delete(_ id: UUID) async throws {
        _ = try await record(id)
        try await GroupPurge.orders([id], on: scope.db)
    }

    func export(_ id: UUID, format: String, now: Date = Date()) async throws -> Response {
        try OrderCore.exportResponse(try await get(id, now: now), format: format)
    }

    /// "Remember my previous items": the most frequent items in the owner's earlier rounds.
    func itemSuggestions() async throws -> [ItemSuggestionDTO] {
        let orderIds = try await GroupOrderRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).sort(\.$createdAt, .descending).limit(50).all().compactMap(\.id)
        var counts: [String: ItemSuggestionDTO] = [:]
        for chunk in orderIds.chunked(100) {
            for entry in try await GroupOrderEntryRecord.query(on: scope.db).filter(\.$orderId ~~ chunk).limit(2000).all() {
                let key = GroupText.key(entry.item)
                var current = counts[key] ?? .init(item: entry.item, priceCents: entry.priceCents, count: 0)
                current.count += entry.quantity
                if current.priceCents == nil { current.priceCents = entry.priceCents }
                counts[key] = current
            }
        }
        return Array(counts.values.sorted { ($0.count, $1.item.lowercased()) > ($1.count, $0.item.lowercased()) }.prefix(20))
    }
}

/// Stored catalogs of one account.
struct CatalogService: Sendable {
    let scope: TimeServices

    func record(_ id: UUID) async throws -> GroupCatalogRecord {
        guard let row = try await GroupCatalogRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$id == id).first() else { throw APIError.missing }
        return row
    }

    private func dto(_ row: GroupCatalogRecord) async throws -> CatalogDTO {
        let id = try row.requireID()
        let items = try await GroupCatalogItemRecord.query(on: scope.db).filter(\.$catalogId == id).sort(\.$position).all()
        return .init(id: id, name: row.name, items: items.map { .init(name: $0.name, priceCents: $0.priceCents) }, itemCount: items.count,
                     createdAt: row.createdAt, updatedAt: row.updatedAt)
    }

    func list() async throws -> [CatalogDTO] {
        var result: [CatalogDTO] = []
        for row in try await GroupCatalogRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).sort(\.$name).all() { result.append(try await dto(row)) }
        return result
    }
    func get(_ id: UUID) async throws -> CatalogDTO { try await dto(try await record(id)) }

    private func checked(_ input: CatalogInput) throws -> (String, [CatalogItemDTO]) {
        let name = try GroupText.requiredLine(input.name, max: GroupLimits.catalogNameMax)
        guard input.items.count <= GroupLimits.maxCatalogItems else { throw APIError.invalid }
        let items = try input.items.map { CatalogItemDTO(name: try GroupText.requiredLine($0.name, max: GroupLimits.textMax), priceCents: try OrderCore.price($0.priceCents)) }
        return (name, items)
    }

    private func storeItems(_ items: [CatalogItemDTO], catalogId: UUID) async throws {
        try await GroupCatalogItemRecord.query(on: scope.db).filter(\.$catalogId == catalogId).delete()
        for (index, item) in items.enumerated() {
            let row = GroupCatalogItemRecord()
            row.catalogId = catalogId; row.position = index; row.name = item.name; row.priceCents = item.priceCents
            try await row.create(on: scope.db)
        }
    }

    func create(_ input: CatalogInput, now: Date = Date()) async throws -> CatalogDTO {
        let (name, items) = try checked(input)
        guard try await GroupCatalogRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).count() < GroupLimits.maxCatalogsPerAccount else {
            throw APIError(.conflict, "too_many_catalogs")
        }
        let row = GroupCatalogRecord()
        row.accountId = scope.accountId; row.name = name; row.createdAt = now; row.updatedAt = now
        try await row.create(on: scope.db)
        try await storeItems(items, catalogId: row.requireID())
        return try await dto(row)
    }

    func replace(_ id: UUID, _ input: CatalogInput, now: Date = Date()) async throws -> CatalogDTO {
        let row = try await record(id)
        let (name, items) = try checked(input)
        row.name = name; row.updatedAt = now
        try await row.update(on: scope.db)
        try await storeItems(items, catalogId: id)
        return try await dto(row)
    }

    func delete(_ id: UUID) async throws {
        _ = try await record(id)
        try await GroupPurge.catalogs([id], on: scope.db)
    }
}

extension TimeServices {
    var orders: OrderService { .init(scope: self) }
    var catalogs: CatalogService { .init(scope: self) }
}
