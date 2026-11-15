import Combine
import Foundation
import GRDB

/// Why a preset write was refused.
nonisolated enum DownloadPresetStoreError: Error, Equatable, Sendable {
    /// Twenty presets already exist.
    case limitReached
    /// The preset no longer exists (it was deleted or replaced meanwhile).
    case notFound
    /// The order handed to `reorder` is not the stored set of presets.
    case stale
}

/// The single owner of custom download presets. Settings and the series screen never write SQL for them.
///
/// Publication comes only from `ValueObservation` on the table, so a write, a restore or any other writer is
/// observed the same way. A row that fails strict validation makes the whole list `unreadable`: the store fails
/// closed and never publishes a partial list.
@MainActor
final class DownloadPresetStore: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded([CustomDownloadPreset])
        case unreadable
    }

    @Published private(set) var state: State = .loading

    private let dbPool: DatabasePool
    private var observation: AnyDatabaseCancellable?

    init<Scheduler: ValueObservationMainActorScheduler>(
        dbPool: DatabasePool,
        scheduling scheduler: Scheduler
    ) {
        self.dbPool = dbPool
        let observation = ValueObservation.tracking { db -> State in
            Self.fetchState(db)
        }
        self.observation = observation.start(
            in: dbPool,
            scheduling: scheduler,
            onError: { [weak self] _ in self?.state = .unreadable },
            onChange: { [weak self] state in self?.state = state }
        )
    }

    // MARK: - Writes

    /// Appends a preset after the existing ones, inside the write transaction that checks the limit.
    func create(name: CustomPresetName?, rule: CustomDownloadRule) async throws -> UUID {
        let id = UUID()
        try await dbPool.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloadPresetDefinition") ?? 0
            guard count < DownloadPresetDefinitionRecord.maximumCount else {
                throw DownloadPresetStoreError.limitReached
            }
            let sortIndex = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sortIndex), -1) + 1 FROM downloadPresetDefinition"
            ) ?? 0
            try DownloadPresetDefinitionRecord(
                CustomDownloadPreset(id: id, name: name, rule: rule),
                sortIndex: sortIndex
            ).insert(db)
        }
        return id
    }

    /// Replaces the name and rule of one preset in place. Its position does not change.
    func update(id: UUID, name: CustomPresetName?, rule: CustomDownloadRule) async throws {
        try await dbPool.write { db in
            guard let current = try DownloadPresetDefinitionRecord.fetchOne(db, key: id.uuidString) else {
                throw DownloadPresetStoreError.notFound
            }
            let replacement = DownloadPresetDefinitionRecord(
                CustomDownloadPreset(id: id, name: name, rule: rule),
                sortIndex: current.sortIndex
            )
            try replacement.update(db)
        }
    }

    /// Deletes one preset and renumbers the rest densely from 0.
    func delete(id: UUID) async throws {
        try await dbPool.write { db in
            guard try DownloadPresetDefinitionRecord.deleteOne(db, key: id.uuidString) else {
                throw DownloadPresetStoreError.notFound
            }
            try Self.rewrite(try Self.orderedRecords(db), in: db)
        }
    }

    /// Stores the order the ids are given in. The ids must be exactly the stored set, or nothing changes.
    func reorder(_ ids: [UUID]) async throws {
        try await dbPool.write { db in
            let current = try Self.orderedRecords(db)
            let stored = Set(current.map(\.id))
            let requested = Set(ids.map(\.uuidString))
            guard ids.count == current.count, requested == stored, requested.count == ids.count else {
                throw DownloadPresetStoreError.stale
            }
            let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
            let reordered = ids.compactMap { byID[$0.uuidString] }
            try Self.rewrite(reordered, in: db)
        }
    }

    /// Recovery for `unreadable`: removes every stored definition. The list then loads as empty.
    func deleteAll() async throws {
        try await dbPool.write { db in
            _ = try DownloadPresetDefinitionRecord.deleteAll(db)
        }
    }

    // MARK: - Reads

    /// Every stored row, validated. Any row that fails validation makes the whole list unreadable, as does an order
    /// that is not dense from 0 or a duplicate id. Errors while reading are unreadable too: the list fails closed.
    nonisolated static func fetchState(_ db: Database) -> State {
        do {
            let records = try orderedRecords(db)
            let presets = try records.map { try $0.validated() }
            guard records.count <= DownloadPresetDefinitionRecord.maximumCount,
                  records.map(\.sortIndex) == Array(records.indices),
                  Set(presets.map(\.id)).count == presets.count else {
                return .unreadable
            }
            return .loaded(presets)
        } catch {
            return .unreadable
        }
    }

    nonisolated private static func orderedRecords(_ db: Database) throws -> [DownloadPresetDefinitionRecord] {
        try DownloadPresetDefinitionRecord
            .order(Column("sortIndex"))
            .fetchAll(db)
    }

    /// Replaces the table with `records` in this order, renumbered from 0. Delete then insert keeps the UNIQUE
    /// sortIndex from ever conflicting mid-update.
    nonisolated private static func rewrite(_ records: [DownloadPresetDefinitionRecord], in db: Database) throws {
        _ = try DownloadPresetDefinitionRecord.deleteAll(db)
        for (index, var record) in records.enumerated() {
            record.sortIndex = index
            try record.insert(db)
        }
    }
}

extension DownloadPresetStore: DownloadPresetProviding {
    /// The loaded presets, in order; empty while loading and when unreadable.
    var presetsPublisher: AnyPublisher<[CustomDownloadPreset], Never> {
        $state
            .map { state -> [CustomDownloadPreset] in
                if case .loaded(let presets) = state { return presets }
                return []
            }
            .eraseToAnyPublisher()
    }
}
