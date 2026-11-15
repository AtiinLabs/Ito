import Combine
import Foundation
import GRDB
import Testing
@testable import Ito

@MainActor
struct DownloadPresetStoreTests {
    private func makeStore() throws -> (TestDatabase, DownloadPresetStore) {
        let database = try TestDatabase()
        let store = DownloadPresetStore(dbPool: database.dbPool, scheduling: ImmediateValueObservationScheduler())
        return (database, store)
    }

    private func count(_ count: Int) throws -> DownloadPositionCount {
        try #require(DownloadPositionCount(count))
    }

    @Test func createAppendsAndTheTwentyFirstIsRefusedWithoutWriting() async throws {
        let (database, store) = try makeStore()
        defer { database.cleanup() }

        var ids: [UUID] = []
        for index in 0..<DownloadPresetDefinitionRecord.maximumCount {
            ids.append(try await store.create(
                name: CustomPresetName(validating: "Preset \(index)"),
                rule: .next(try count(index + 1))
            ))
        }
        for await state in store.$state.values {
            if case .loaded(let current) = state, current.map(\.id) == ids { break }
        }
        guard case .loaded(let presets) = store.state else { Issue.record("Expected loaded presets"); return }
        #expect(presets.map(\.id) == ids)

        await #expect(throws: DownloadPresetStoreError.limitReached) {
            _ = try await store.create(name: nil, rule: .more(try self.count(5)))
        }
        let rows = try await database.dbPool.read { db in try DownloadPresetDefinitionRecord.fetchCount(db) }
        #expect(rows == DownloadPresetDefinitionRecord.maximumCount)
    }

    @Test func updateReplacesNameAndRuleInPlace() async throws {
        let (database, store) = try makeStore()
        defer { database.cleanup() }
        let first = try await store.create(name: nil, rule: .next(try count(2)))
        let second = try await store.create(name: nil, rule: .next(try count(3)))

        try await store.update(id: first, name: CustomPresetName(validating: "Renamed"), rule: .more(try count(9)))

        for await state in store.$state.values {
            if case .loaded(let current) = state, current.first?.name?.value == "Renamed" { break }
        }
        guard case .loaded(let presets) = store.state else { Issue.record("Expected loaded presets"); return }
        #expect(presets.map(\.id) == [first, second])
        #expect(presets[0].name?.value == "Renamed")
        #expect(presets[0].rule == .more(try count(9)))
    }

    @Test func deleteRenumbersTheRemainingPresetsFromZero() async throws {
        let (database, store) = try makeStore()
        defer { database.cleanup() }
        let first = try await store.create(name: nil, rule: .next(try count(1)))
        let second = try await store.create(name: nil, rule: .next(try count(2)))
        let third = try await store.create(name: nil, rule: .next(try count(3)))

        try await store.delete(id: first)

        let sortIndexes = try await database.dbPool.read { db in
            try DownloadPresetDefinitionRecord.order(Column("sortIndex")).fetchAll(db).map { ($0.id, $0.sortIndex) }
        }
        #expect(sortIndexes.map(\.0) == [second.uuidString, third.uuidString])
        #expect(sortIndexes.map(\.1) == [0, 1])
    }

    @Test func reorderWithAStaleIdSetThrowsAndChangesNothing() async throws {
        let (database, store) = try makeStore()
        defer { database.cleanup() }
        let first = try await store.create(name: nil, rule: .next(try count(1)))
        let second = try await store.create(name: nil, rule: .next(try count(2)))

        await #expect(throws: DownloadPresetStoreError.stale) {
            try await store.reorder([second])
        }
        try await store.reorder([second, first])

        for await state in store.$state.values {
            if case .loaded(let current) = state, current.map(\.id) == [second, first] { break }
        }
        guard case .loaded(let presets) = store.state else { Issue.record("Expected loaded presets"); return }
        #expect(presets.map(\.id) == [second, first])
    }

    @Test func aDirectWriteSuchAsARestoreIsObserved() async throws {
        let (database, store) = try makeStore()
        defer { database.cleanup() }
        let id = UUID()
        try await database.dbPool.write { db in
            try DownloadPresetDefinitionRecord(
                id: id.uuidString, name: "Restored", windowKind: "more", positionCount: 4, sortIndex: 0
            ).insert(db)
        }

        for await state in store.$state.values {
            if case .loaded(let current) = state, current.map(\.id) == [id] { break }
        }
        guard case .loaded(let presets) = store.state else { Issue.record("Expected loaded presets"); return }
        #expect(presets.map(\.id) == [id])
        #expect(presets.first?.name?.value == "Restored")
    }

    @Test func anInvalidStoredRowMakesTheListUnreadableUntilDeleteAllRecovers() async throws {
        let (database, store) = try makeStore()
        defer { database.cleanup() }
        _ = try await store.create(name: nil, rule: .next(try count(1)))
        // A name with a line break passes the database CHECKs but not the strict validator.
        try await database.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO downloadPresetDefinition (id, name, windowKind, positionCount, sortIndex)
                VALUES (?, 'bad' || char(10) || 'name', 'next', 2, 1)
                """, arguments: [UUID().uuidString])
        }
        for await state in store.$state.values {
            if state == .unreadable { break }
        }
        #expect(store.state == .unreadable)

        try await store.deleteAll()
        for await state in store.$state.values {
            if state == .loaded([]) { break }
        }
        #expect(store.state == .loaded([]))
    }
}
