import Foundation
import GRDB
import Testing
@testable import Ito

struct SourceMappingBackupTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func fullColumnExportImportRoundTripPreservesPersistedRejection() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let expected = mapping(
            canonicalMediaId: "42",
            decision: .discard,
            matchMethod: .none,
            confidence: 0.125,
            title: "Persisted rejection",
            includeOptionalColumns: true
        )
        try await database.dbPool.write { db in
            for entry in AppPreferenceCatalogEntry.allCases {
                try AppPreference(
                    key: entry.rawValue,
                    value: entry.canonicalDefaultJSON
                ).insert(db)
            }
            try expected.insert(db)
        }
        let backupURL = database.databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("source-mapping.itobackup")

        try await BackupExportOperation(
            dbPool: database.dbPool,
            sourceDatabaseURL: database.databaseURL,
            readinessGate: {}
        ).export(to: backupURL)
        let imported = try await ItoNativeImporter().parse(url: backupURL)

        #expect(imported.representation(of: .sourceMappings) == .representedNonempty)
        #expect(imported.sourceMappings == [expected])
        #expect(imported.sourceMappings[0].decision == .discard)
        #expect(imported.sourceMappings[0].matchMethod == .none)
    }

    @Test func mergeUsesCompositePrimaryKeyAndPreservesLocalConflicts() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let exact = mapping(canonicalMediaId: "exact")
        let localConflict = mapping(canonicalMediaId: "conflict", title: "Local")
        let backupConflict = mapping(
            canonicalMediaId: "conflict",
            decision: .discard,
            matchMethod: .none,
            title: "Backup"
        )
        let insertedRejection = mapping(
            canonicalMediaId: "new",
            decision: .discard,
            matchMethod: .none,
            title: "Rejected"
        )
        try await database.dbPool.write { db in
            try exact.insert(db)
            try localConflict.insert(db)
        }

        let report = try await operation(database).restore(
            backup(sourceMappings: [backupConflict, insertedRejection, exact]),
            mode: .merge,
            operationId: "source-mapping-merge"
        )

        let outcome = try #require(
            report.outcomes.first { $0.component == .sourceMappings }
        )
        #expect(outcome.inserted == 1)
        #expect(outcome.preservedLocal == 1)
        #expect(outcome.skipped == 1)
        #expect(
            try await fetchMappings(database)
                == sorted([exact, localConflict, insertedRejection])
        )
    }

    @Test func wipeReplacesAllLocalSourceMappings() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let localConflict = mapping(canonicalMediaId: "same", title: "Local")
        let unrelated = mapping(canonicalMediaId: "unrelated")
        let restored = mapping(
            canonicalMediaId: "same",
            decision: .discard,
            matchMethod: .none,
            title: "Backup"
        )
        try await database.dbPool.write { db in
            try localConflict.insert(db)
            try unrelated.insert(db)
        }

        let report = try await operation(database).restore(
            backup(sourceMappings: [restored]),
            mode: .wipe,
            operationId: "source-mapping-wipe"
        )

        let outcome = try #require(
            report.outcomes.first { $0.component == .sourceMappings }
        )
        #expect(outcome.replaced == 2)
        #expect(outcome.inserted == 1)
        #expect(try await fetchMappings(database) == [restored])
    }

    @Test func representedEmptyMergePreservesAndWipeClearsSourceMappings() async throws {
        let mergeDatabase = try TestDatabase()
        defer { mergeDatabase.cleanup() }
        let wipeDatabase = try TestDatabase()
        defer { wipeDatabase.cleanup() }
        let local = mapping(canonicalMediaId: "local")
        try await mergeDatabase.dbPool.write { db in
            try local.insert(db)
        }
        try await wipeDatabase.dbPool.write { db in
            try local.insert(db)
        }
        let representedEmpty = backup(
            sourceMappings: [],
            representation: .representedEmpty
        )

        let mergeReport = try await operation(mergeDatabase).restore(
            representedEmpty,
            mode: .merge,
            operationId: "source-mapping-empty-merge"
        )
        let wipeReport = try await operation(wipeDatabase).restore(
            representedEmpty,
            mode: .wipe,
            operationId: "source-mapping-empty-wipe"
        )

        #expect(try await fetchMappings(mergeDatabase) == [local])
        #expect(try await fetchMappings(wipeDatabase).isEmpty)
        #expect(
            mergeReport.outcomes.first { $0.component == .sourceMappings }?.total == 0
        )
        #expect(
            wipeReport.outcomes.first { $0.component == .sourceMappings }?.replaced == 1
        )
    }

    @Test func absentSourceMappingComponentPreservesLocalRowsDuringWipe() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let local = mapping(canonicalMediaId: "local")
        try await database.dbPool.write { db in
            try local.insert(db)
        }
        let unrelatedBackup = ImportedBackup(
            metadata: BackupMetadataRecord(formatVersion: 1, createdAt: date),
            capabilities: [
                BackupCapabilityRecord(
                    component: .repositories,
                    representation: .representedEmpty
                )
            ]
        )

        let report = try await operation(database).restore(
            unrelatedBackup,
            mode: .wipe,
            operationId: "source-mapping-absent"
        )

        #expect(try await fetchMappings(database) == [local])
        #expect(!report.outcomes.contains { $0.component == .sourceMappings })
    }

    @Test func nativeParserIgnoresPhysicalRowsWhenCapabilityIsAbsent() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let physicalRow = mapping(canonicalMediaId: "legacy-physical")
        try await database.dbPool.write { db in
            // The backup holds only the rows seeded here, not the migrated system list.
            try db.execute(sql: "DELETE FROM libraryCategory")
            try physicalRow.insert(db)
            try BackupMetadataRecord(formatVersion: 1, createdAt: date).insert(db)
            try BackupCapabilityRecord(
                component: .repositories,
                representation: .representedEmpty
            ).insert(db)
        }

        let imported = try await ItoNativeImporter().parse(url: database.databaseURL)

        #expect(imported.representation(of: .sourceMappings) == .unrepresented)
        #expect(imported.sourceMappings.isEmpty)
    }

    @Test func duplicateAndConflictingLogicalIdentitiesAreRejectedBeforeMutation() async throws {
        let row = mapping(canonicalMediaId: "duplicate")
        try await assertRejected(
            sourceMappings: [row, row],
            code: "duplicateLogicalIdentity"
        )
        try await assertRejected(
            sourceMappings: [
                row,
                mapping(
                    canonicalMediaId: "duplicate",
                    decision: .discard,
                    matchMethod: .none,
                    title: "Conflict"
                )
            ],
            code: "conflictingLogicalIdentity"
        )
    }

    private func operation(
        _ database: TestDatabase
    ) -> ComponentAwareBackupRestoreOperation {
        ComponentAwareBackupRestoreOperation(
            dbPool: database.dbPool,
            operationIdProvider: { "generated" },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    private func backup(
        sourceMappings: [SourceMappingRecord],
        representation: BackupRepresentation = .representedNonempty
    ) -> ImportedBackup {
        ImportedBackup(
            metadata: BackupMetadataRecord(formatVersion: 1, createdAt: date),
            capabilities: [
                BackupCapabilityRecord(
                    component: .sourceMappings,
                    representation: representation
                )
            ],
            sourceMappings: sourceMappings
        )
    }

    private func mapping(
        canonicalMediaId: String,
        decision: MatchDecision = .autoConfirm,
        matchMethod: MatchMethod = .exactPreferred,
        confidence: Double = 1,
        title: String = "Title",
        includeOptionalColumns: Bool = false
    ) -> SourceMappingRecord {
        SourceMappingRecord(
            canonicalProvider: "anilist",
            canonicalMediaId: canonicalMediaId,
            mediaType: .manga,
            pluginId: "plugin",
            pluginMediaKey: "media-\(canonicalMediaId)",
            decision: decision,
            matchMethod: matchMethod,
            confidence: confidence,
            titleSnapshot: title,
            createdAt: date,
            updatedAt: date.addingTimeInterval(1),
            coverURLSnapshot: includeOptionalColumns
                ? "https://example.com/\(canonicalMediaId).jpg"
                : nil,
            encodedPayload: includeOptionalColumns ? Data([0, 1, 2, 255]) : nil,
            payloadVersion: includeOptionalColumns ? 7 : nil,
            pluginVersion: includeOptionalColumns ? "9.8.7" : nil,
            lastVerifiedAt: includeOptionalColumns
                ? date.addingTimeInterval(2)
                : nil
        )
    }

    private func fetchMappings(
        _ database: TestDatabase
    ) async throws -> [SourceMappingRecord] {
        try await database.dbPool.read { db in
            try SourceMappingRecord.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM sourceMapping
                    ORDER BY canonicalProvider, canonicalMediaId, mediaType,
                             pluginId, pluginMediaKey
                    """
            )
        }
    }

    private func sorted(
        _ mappings: [SourceMappingRecord]
    ) -> [SourceMappingRecord] {
        mappings.sorted {
            (
                $0.canonicalProvider,
                $0.canonicalMediaId,
                mediaType($0.mediaType),
                $0.pluginId,
                $0.pluginMediaKey
            ) < (
                $1.canonicalProvider,
                $1.canonicalMediaId,
                mediaType($1.mediaType),
                $1.pluginId,
                $1.pluginMediaKey
            )
        }
    }

    private func mediaType(_ type: PluginMediaType) -> String {
        switch type {
        case .manga: "manga"
        case .anime: "anime"
        }
    }

    private func assertRejected(
        sourceMappings: [SourceMappingRecord],
        code: String
    ) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let sentinel = mapping(canonicalMediaId: "sentinel")
        try await database.dbPool.write { db in
            try sentinel.insert(db)
        }

        do {
            _ = try await operation(database).restore(
                backup(sourceMappings: sourceMappings),
                mode: .wipe,
                operationId: "source-mapping-rejected-\(code)"
            )
            Issue.record("Expected source-mapping preflight rejection")
        } catch let BackupPreflightError.rejected(reason) {
            #expect(
                reason == .invalidComponentData(
                    component: .sourceMappings,
                    code: code
                )
            )
        }

        #expect(try await fetchMappings(database) == [sentinel])
        #expect(try await database.dbPool.read { db in
            try BackupRestoreJournalRecord.fetchCount(db)
        } == 0)
    }
}
