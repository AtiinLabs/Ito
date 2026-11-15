import Foundation
import GRDB
import Testing
@testable import Ito

@MainActor
struct DownloadPresetEditorTests {
    @Test func draftRejectsInvalidCountsAndNamesWithoutWriting() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = DownloadPresetStore(dbPool: database.dbPool, scheduling: ImmediateValueObservationScheduler())
        var draft = DownloadPresetDraft(newPreset: ())
        draft.countText = "1001"
        #expect(draft.rule == nil)
        await #expect(throws: DownloadPresetDraft.PersistenceError.invalidCount) { try await draft.persist(in: store) }
        draft.countText = "3"
        draft.name = "two\nlines"
        #expect(draft.nameProblem == .lineBreak)
        await #expect(throws: DownloadPresetDraft.NameProblem.lineBreak) { try await draft.persist(in: store) }
        draft.name = String(repeating: "a", count: 41)
        #expect(draft.nameProblem == .tooLong)
        draft.name = "short\tname"
        #expect(draft.nameProblem == .unsupportedCharacters)
        await #expect(throws: DownloadPresetDraft.NameProblem.unsupportedCharacters) {
            try await draft.persist(in: store)
        }
        #expect(try await database.dbPool.read { db in try DownloadPresetDefinitionRecord.fetchCount(db) } == 0)
    }

    @Test func failedPersistenceKeepsTheDraftAndDoesNotPublishASuccessfulList() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let store = DownloadPresetStore(dbPool: database.dbPool, scheduling: ImmediateValueObservationScheduler())
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refusePreset BEFORE INSERT ON downloadPresetDefinition
                BEGIN SELECT RAISE(ABORT, 'injected failure'); END
                """)
        }
        var draft = DownloadPresetDraft(newPreset: ())
        draft.name = "Keep this draft"
        draft.countText = "7"
        let original = draft
        await #expect(throws: DatabaseError.self) { try await draft.persist(in: store) }
        #expect(draft == original)
        #expect(store.state == .loaded([]))
        #expect(try await database.dbPool.read { db in try DownloadPresetDefinitionRecord.fetchCount(db) } == 0)
    }
    @Test func failedUnreadableRecoveryReportsFailureAndPreservesStoredRows() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let row = DownloadPresetDefinitionRecord(
            id: UUID().uuidString, name: "Invalid\tname", windowKind: "next", positionCount: 3, sortIndex: 0
        )
        try await database.dbPool.write { db in
            try row.insert(db)
            try db.execute(sql: """
                CREATE TRIGGER refusePresetDelete BEFORE DELETE ON downloadPresetDefinition
                BEGIN SELECT RAISE(ABORT, 'injected failure'); END
                """)
        }
        let store = DownloadPresetStore(dbPool: database.dbPool, scheduling: ImmediateValueObservationScheduler())
        let model = DownloadPresetsSettingsModel(store: store)
        #expect(model.state == .unreadable)
        await model.deleteAll().value
        #expect(model.state == .unreadable)
        #expect(model.failure == DownloadPresetsSettingsModel.saveFailure)
        let stored = try await database.dbPool.read { db in try DownloadPresetDefinitionRecord.fetchAll(db) }
        #expect(stored == [row])
    }
}
