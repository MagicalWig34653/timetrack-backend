import Foundation
import Fluent
import Vapor

/// Poll rules shared by the owner API and the public link API (ADR-0033).
enum PollCore {
    static let kinds: Set<String> = ["text", "date"]
    static let modes: Set<String> = ["single", "multi"]

    static func options(_ pollId: UUID, on db: any Database) async throws -> [GroupPollOptionRecord] {
        try await GroupPollOptionRecord.query(on: db).filter(\.$pollId == pollId).sort(\.$position).all()
    }

    static func optionDTO(_ row: GroupPollOptionRecord) throws -> PollOptionDTO {
        try .init(id: row.requireID(), label: row.label, date: row.slotDate, startTime: row.startTime, endTime: row.endTime)
    }

    static func clockMinutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard text.utf8.count == 5, parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    /// Validates the option list of a new poll and returns unsaved rows in order.
    static func buildOptions(_ inputs: [PollOptionInput], kind: String) throws -> [GroupPollOptionRecord] {
        guard (1...GroupLimits.maxOptions).contains(inputs.count) else { throw APIError.invalid }
        var seen = Set<String>()
        var rows: [GroupPollOptionRecord] = []
        for (index, input) in inputs.enumerated() {
            let row = GroupPollOptionRecord()
            row.position = index
            let label = try GroupText.line(input.label, max: GroupLimits.textMax, required: kind == "text")
            let key: String
            if kind == "text" {
                guard input.date == nil, input.startTime == nil, input.endTime == nil else { throw APIError.invalid }
                row.label = label; key = "t|" + GroupText.key(label ?? "")
            } else {
                guard let date = input.date, (try? LocalDate(date)) != nil, date.utf8.count == 10 else { throw APIError.invalid }
                if let start = input.startTime {
                    guard let from = clockMinutes(start) else { throw APIError.invalid }
                    if let end = input.endTime { guard let to = clockMinutes(end), to > from else { throw APIError.invalid } }
                } else if input.endTime != nil { throw APIError.invalid }
                row.label = label; row.slotDate = date; row.startTime = input.startTime; row.endTime = input.endTime
                key = "d|\(date)|\(input.startTime ?? "")|\(input.endTime ?? "")"
            }
            guard seen.insert(key).inserted else { throw APIError.invalid }
            rows.append(row)
        }
        return rows
    }

    static func validTimeZone(_ identifier: String?) throws -> String? {
        guard let value = try GroupText.line(identifier, max: 64, required: false) else { return nil }
        guard TimeZone(identifier: value) != nil else { throw APIError.invalid }
        return value
    }

    /// Reduces the answers to the stored yes/maybe rows after checking them against the poll rules.
    static func validateAnswers(_ answers: [PollAnswerInput], poll: GroupPollRecord, options: [GroupPollOptionRecord]) throws -> [(UUID, String)] {
        let valid = Set(options.compactMap(\.id))
        var seen = Set<UUID>()
        var kept: [(UUID, String)] = []
        for answer in answers {
            guard valid.contains(answer.optionId), seen.insert(answer.optionId).inserted else { throw GroupError.answersInvalid }
            switch answer.answer {
            case "yes": kept.append((answer.optionId, "yes"))
            case "maybe":
                guard poll.kind == "date" else { throw GroupError.answersInvalid }
                kept.append((answer.optionId, "maybe"))
            case "no": break
            default: throw GroupError.answersInvalid
            }
        }
        let yes = kept.filter { $0.1 == "yes" }.count
        if poll.choiceMode == "single" {
            guard yes == 1, kept.count == 1 else { throw GroupError.answersInvalid }
        } else if poll.kind == "text" {
            guard yes >= 1 else { throw GroupError.answersInvalid }
        }
        return kept
    }

    static func voteDTOs(pollId: UUID, on db: any Database) async throws -> [PollVoteDTO] {
        let votes = try await GroupPollVoteRecord.query(on: db).filter(\.$pollId == pollId).sort(\.$createdAt).sort(\.$id).all()
        let answers = try await GroupPollAnswerRecord.query(on: db).filter(\.$pollId == pollId).all()
        let grouped = Dictionary(grouping: answers, by: \.voteId)
        return try votes.map { vote in
            let id = try vote.requireID()
            let mine = (grouped[id] ?? []).sorted { $0.optionId.uuidString < $1.optionId.uuidString }
            return .init(id: id, name: vote.name, answers: mine.map { .init(optionId: $0.optionId, answer: $0.answer) },
                         createdAt: vote.createdAt, updatedAt: vote.updatedAt)
        }
    }

    static func dto(_ poll: GroupPollRecord, on db: any Database, now: Date, owner: Bool, token: String? = nil) async throws -> PollDTO {
        let id = try poll.requireID()
        let options = try await options(id, on: db)
        let closed = poll.isClosed(now)
        let visible = owner || !poll.hideResults || closed
        let shown = owner ? (token ?? poll.linkToken) : nil
        let voteCount = try await GroupPollVoteRecord.query(on: db).filter(\.$pollId == id).count()
        var votes: [PollVoteDTO]?, tally: [PollTallyDTO]?
        if visible {
            let all = try await voteDTOs(pollId: id, on: db)
            votes = all
            tally = try options.map { option in
                let optionId = try option.requireID()
                let yes = all.filter { $0.answers.contains { $0.optionId == optionId && $0.answer == "yes" } }.count
                let maybe = all.filter { $0.answers.contains { $0.optionId == optionId && $0.answer == "maybe" } }.count
                return .init(optionId: optionId, yes: yes, maybe: maybe, no: all.count - yes - maybe)
            }
        }
        return .init(id: owner ? id : nil, title: poll.title, description: poll.details, kind: poll.kind, choiceMode: poll.choiceMode,
                     timeZone: poll.timeZone, options: try options.map(optionDTO), deadline: poll.deadline, hideResults: poll.hideResults,
                     closed: closed, closedAt: poll.closedAt, finalOptionId: poll.finalOptionId, resultsVisible: visible,
                     voteCount: voteCount, votes: votes, tally: tally, createdAt: owner ? poll.createdAt : nil,
                     updatedAt: owner ? poll.updatedAt : nil, token: shown, path: shown.map { "/g/" + $0 })
    }

    /// Replaces the answers of a vote (delete and insert; the pair is inside the caller's transaction).
    static func storeAnswers(_ kept: [(UUID, String)], pollId: UUID, voteId: UUID, on db: any Database) async throws {
        try await GroupPollAnswerRecord.query(on: db).filter(\.$voteId == voteId).delete()
        for (optionId, answer) in kept {
            let row = GroupPollAnswerRecord()
            row.pollId = pollId; row.voteId = voteId; row.optionId = optionId; row.answer = answer
            try await row.create(on: db)
        }
    }

    static func nameTaken(_ key: String, pollId: UUID, excluding voteId: UUID?, on db: any Database) async throws -> Bool {
        let rows = try await GroupPollVoteRecord.query(on: db).filter(\.$pollId == pollId).filter(\.$nameKey == key).all()
        return rows.contains { GroupText.key($0.name) == key && $0.id != voteId }
    }

    /// Public voting, always inside the caller's serialized transaction (counts and the name check stay exact).
    static func castVote(_ input: VoteInput, poll: GroupPollRecord, now: Date, on db: any Database) async throws -> VoteCreatedDTO {
        guard !poll.isClosed(now) else { throw GroupError.closed }
        let pollId = try poll.requireID()
        let name = try GroupText.requiredLine(input.name, max: GroupLimits.nameMax)
        let kept = try validateAnswers(input.answers, poll: poll, options: try await options(pollId, on: db))
        guard try await GroupPollVoteRecord.query(on: db).filter(\.$pollId == pollId).count() < GroupLimits.maxVotes else { throw GroupError.full }
        guard !(try await nameTaken(GroupText.key(name), pollId: pollId, excluding: nil, on: db)) else { throw GroupError.nameTaken }
        let secret = Secrets.token(bytes: 32)
        let vote = GroupPollVoteRecord()
        vote.pollId = pollId; vote.name = name; vote.nameKey = GroupText.key(name); vote.secretHash = Secrets.hash(secret)
        vote.createdAt = now; vote.updatedAt = now
        try await vote.create(on: db)
        let voteId = try vote.requireID()
        try await storeAnswers(kept, pollId: pollId, voteId: voteId, on: db)
        let dto = try await voteDTOs(pollId: pollId, on: db).first { $0.id == voteId }!
        return .init(vote: dto, editSecret: secret)
    }

    static func ownVote(_ id: UUID, poll: GroupPollRecord, secret: String?, on db: any Database) async throws -> GroupPollVoteRecord {
        guard let vote = try await GroupPollVoteRecord.query(on: db).filter(\.$pollId == poll.requireID()).filter(\.$id == id).first() else { throw APIError.missing }
        guard let secret, GroupTokens.matches(secret, hash: vote.secretHash) else { throw GroupError.editSecretInvalid }
        return vote
    }

    static func updateVote(_ vote: GroupPollVoteRecord, input: VoteInput, poll: GroupPollRecord, now: Date, on db: any Database) async throws -> PollVoteDTO {
        guard !poll.isClosed(now) else { throw GroupError.closed }
        let pollId = try poll.requireID(), voteId = try vote.requireID()
        let name = try GroupText.requiredLine(input.name, max: GroupLimits.nameMax)
        let kept = try validateAnswers(input.answers, poll: poll, options: try await options(pollId, on: db))
        guard !(try await nameTaken(GroupText.key(name), pollId: pollId, excluding: voteId, on: db)) else { throw GroupError.nameTaken }
        vote.name = name; vote.nameKey = GroupText.key(name); vote.updatedAt = now
        try await vote.update(on: db)
        try await storeAnswers(kept, pollId: pollId, voteId: voteId, on: db)
        return try await voteDTOs(pollId: pollId, on: db).first { $0.id == voteId }!
    }

    static func removeVote(_ voteId: UUID, on db: any Database) async throws {
        try await GroupPollAnswerRecord.query(on: db).filter(\.$voteId == voteId).delete()
        try await GroupPollVoteRecord.query(on: db).filter(\._$id == voteId).delete()
    }
}

/// Errors with stable codes and German messages (`GroupMessages`).
enum GroupError {
    static let closed = APIError(.conflict, "group_closed")
    static let full = APIError(.conflict, "group_full")
    static let nameTaken = APIError(.conflict, "name_taken")
    static let answersInvalid = APIError(.badRequest, "answers_invalid")
    static let editSecretInvalid = APIError(.forbidden, "edit_secret_invalid")
}

/// Owner side (session + CSRF): everything is scoped to the signed-in account.
struct PollService: Sendable {
    let scope: TimeServices

    func record(_ id: UUID) async throws -> GroupPollRecord {
        guard let row = try await GroupPollRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).filter(\.$id == id).first() else { throw APIError.missing }
        return row
    }

    func list(now: Date = Date()) async throws -> [PollSummaryDTO] {
        let rows = try await GroupPollRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).sort(\.$createdAt, .descending).all()
        var result: [PollSummaryDTO] = []
        for row in rows {
            let id = try row.requireID()
            let count = try await GroupPollVoteRecord.query(on: scope.db).filter(\.$pollId == id).count()
            result.append(.init(id: id, title: row.title, kind: row.kind, choiceMode: row.choiceMode, deadline: row.deadline,
                                closed: row.isClosed(now), closedAt: row.closedAt, voteCount: count, createdAt: row.createdAt))
        }
        return result
    }

    func create(_ input: PollInput, now: Date = Date()) async throws -> PollDTO {
        let title = try GroupText.requiredLine(input.title, max: GroupLimits.titleMax)
        guard PollCore.kinds.contains(input.kind), PollCore.modes.contains(input.choiceMode) else { throw APIError.invalid }
        if let deadline = input.deadline { guard deadline > now else { throw APIError(.badRequest, "deadline_in_past") } }
        let options = try PollCore.buildOptions(input.options, kind: input.kind)
        guard try await GroupPollRecord.query(on: scope.db).filter(\.$accountId == scope.accountId).count() < GroupLimits.maxPollsPerAccount else {
            throw APIError(.conflict, "too_many_polls")
        }
        let (token, hash) = GroupTokens.create()
        let poll = GroupPollRecord()
        poll.accountId = scope.accountId; poll.tokenHash = hash; poll.linkToken = token; poll.title = title
        poll.details = try GroupText.block(input.description, max: GroupLimits.descriptionMax)
        poll.kind = input.kind; poll.choiceMode = input.choiceMode; poll.timeZone = try PollCore.validTimeZone(input.timeZone)
        poll.deadline = input.deadline; poll.hideResults = input.hideResults ?? false; poll.createdAt = now; poll.updatedAt = now
        try await poll.create(on: scope.db)
        let pollId = try poll.requireID()
        for option in options { option.pollId = pollId; try await option.create(on: scope.db) }
        return try await PollCore.dto(poll, on: scope.db, now: now, owner: true, token: token)
    }

    func get(_ id: UUID, now: Date = Date()) async throws -> PollDTO {
        try await PollCore.dto(try await record(id), on: scope.db, now: now, owner: true)
    }

    func patch(_ id: UUID, _ patch: PollPatch, now: Date = Date()) async throws -> PollDTO {
        let poll = try await record(id)
        if let title = patch.title { poll.title = try GroupText.requiredLine(title, max: GroupLimits.titleMax) }
        if let description = patch.description { poll.details = try GroupText.block(description, max: GroupLimits.descriptionMax) }
        if let deadline = patch.deadline {
            if let value = deadline { guard value > now else { throw APIError(.badRequest, "deadline_in_past") } }
            poll.deadline = deadline
        }
        if let hide = patch.hideResults { poll.hideResults = hide }
        poll.updatedAt = now
        try await poll.update(on: scope.db)
        return try await PollCore.dto(poll, on: scope.db, now: now, owner: true)
    }

    func close(_ id: UUID, now: Date = Date()) async throws -> PollDTO {
        let poll = try await record(id)
        if poll.closedAt == nil { poll.closedAt = now; poll.updatedAt = now; try await poll.update(on: scope.db) }
        return try await PollCore.dto(poll, on: scope.db, now: now, owner: true)
    }

    /// Reopening also drops a deadline that has already passed (otherwise the poll would stay closed).
    func reopen(_ id: UUID, now: Date = Date()) async throws -> PollDTO {
        let poll = try await record(id)
        poll.closedAt = nil
        if let deadline = poll.deadline, deadline <= now { poll.deadline = nil }
        poll.updatedAt = now
        try await poll.update(on: scope.db)
        return try await PollCore.dto(poll, on: scope.db, now: now, owner: true)
    }

    /// Picks (or clears) the final option; picking closes the poll.
    func setFinal(_ id: UUID, optionId: UUID?, now: Date = Date()) async throws -> PollDTO {
        let poll = try await record(id)
        if let optionId {
            guard try await GroupPollOptionRecord.query(on: scope.db).filter(\.$pollId == id).filter(\._$id == optionId).count() == 1 else { throw APIError.invalid }
            if poll.closedAt == nil { poll.closedAt = now }
        }
        poll.finalOptionId = optionId; poll.updatedAt = now
        try await poll.update(on: scope.db)
        return try await PollCore.dto(poll, on: scope.db, now: now, owner: true)
    }

    func rotate(_ id: UUID, now: Date = Date()) async throws -> PollDTO {
        let poll = try await record(id)
        let (token, hash) = GroupTokens.create()
        poll.tokenHash = hash; poll.linkToken = token; poll.updatedAt = now
        try await poll.update(on: scope.db)
        return try await PollCore.dto(poll, on: scope.db, now: now, owner: true, token: token)
    }

    func removeVote(_ id: UUID, voteId: UUID) async throws {
        _ = try await record(id)
        guard let vote = try await GroupPollVoteRecord.query(on: scope.db).filter(\.$pollId == id).filter(\._$id == voteId).first() else { throw APIError.missing }
        try await PollCore.removeVote(vote.requireID(), on: scope.db)
    }

    func delete(_ id: UUID) async throws {
        _ = try await record(id)
        try await GroupPurge.polls([id], on: scope.db)
    }
}

extension TimeServices {
    var polls: PollService { .init(scope: self) }
}
