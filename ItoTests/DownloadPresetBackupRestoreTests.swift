import Foundation
import GRDB
import Testing
@testable import Ito

struct DownloadPresetBackupRestoreTests {
    private static let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(_ id: UUID, name: String?, sortIndex: Int, count: Int = 3) -> DownloadPresetDefinitionRecord {
        DownloadPresetDefinitionRecord(
            id: id.uuidString, name: name, windowKind: "next", positionCount: count, sortIndex: sortIndex
        )
    }

    /// A backup that represents only the presets component. `representedPresets: false` is a backup from before
    /// the component existed: it has no capability row at all.
    private func backup(_ presets: [DownloadPresetDefinitionRecord], representedPresets: Bool = true) -> ImportedBackup {
        ImportedBackup(
            metadata: BackupMetadataRecord(formatVersion: 1, createdAt: Self.date),
            capabilities: representedPresets
                ? [BackupCapabilityRecord(component: .downloadPresets, representation: .representedNonempty)]
                : [],
            downloadPresets: presets
        )
    }

    private func operation(_ database: TestDatabase) -> ComponentAwareBackupRestoreOperation {
        ComponentAwareBackupRestoreOperation(
            dbPool: database.dbPool,
            standardApplicationDomain: "test.app",
            operationIdProvider: { "generated" },
            now: { Self.date }
        )
    }

    private func seed(_ database: TestDatabase, _ rows: [DownloadPresetDefinitionRecord]) throws {
        try database.dbPool.write { db in
            _ = try DownloadPresetDefinitionRecord.deleteAll(db)
            for row in rows { try row.insert(db) }
        }
    }

    private func stored(_ database: TestDatabase) throws -> [DownloadPresetDefinitionRecord] {
        try database.dbPool.read { db in
            try DownloadPresetDefinitionRecord.order(Column("sortIndex")).fetchAll(db)
        }
    }

    @Test func aBackupFromBeforeTheComponentLeavesLocalPresetsUntouchedInBothModes() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let local = [record(UUID(), name: "Local", sortIndex: 0)]
        try seed(database, local)

        let older = backup([], representedPresets: false)
        _ = try await operation(database).restore(older, mode: .merge)
        #expect(try stored(database) == local)

        _ = try await operation(database).restore(older, mode: .wipe)
        #expect(try stored(database) == local)
    }

    @Test func mergeKeepsTheLocalCopyForAKnownIdAndAppendsNewIdsInBackupOrder() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let idD = UUID()
        try seed(database, [record(idA, name: "Local A", sortIndex: 0), record(idB, name: nil, sortIndex: 1)])

        let incoming = backup([
            record(idA, name: "Backup A", sortIndex: 0),
            record(idB, name: nil, sortIndex: 1),
            record(idC, name: "C", sortIndex: 2),
            record(idD, name: "D", sortIndex: 3)
        ])
        _ = try await operation(database).restore(incoming, mode: .merge)

        let rows = try stored(database)
        #expect(rows.map(\.id) == [idA, idB, idC, idD].map(\.uuidString))
        #expect(rows.map(\.sortIndex) == [0, 1, 2, 3])
        #expect(rows[0].name == "Local A")
    }

    @Test func mergeRefusesNewIdsBeyondTheLimitAndKeepsTheRest() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let existing = (0..<19).map { record(UUID(), name: nil, sortIndex: $0) }
        try seed(database, existing)
        let first = UUID()
        let second = UUID()

        let incoming = backup([record(first, name: "First", sortIndex: 0), record(second, name: "Second", sortIndex: 1)])
        _ = try await operation(database).restore(incoming, mode: .merge)

        let rows = try stored(database)
        #expect(rows.count == DownloadPresetDefinitionRecord.maximumCount)
        #expect(rows.last?.id == first.uuidString)
        #expect(!rows.contains { $0.id == second.uuidString })
    }

    @Test func wipeReplacesEveryPresetAndRenumbersTheBackupOrder() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try seed(database, [record(UUID(), name: "Gone", sortIndex: 0), record(UUID(), name: "Also gone", sortIndex: 1)])
        let idD = UUID()
        let idE = UUID()

        let incoming = backup([record(idE, name: "E", sortIndex: 9), record(idD, name: "D", sortIndex: 5)])
        _ = try await operation(database).restore(incoming, mode: .wipe)

        let rows = try stored(database)
        #expect(rows.map(\.id) == [idD.uuidString, idE.uuidString])
        #expect(rows.map(\.sortIndex) == [0, 1])
    }
}
