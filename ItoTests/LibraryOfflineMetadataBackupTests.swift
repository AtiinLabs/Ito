import UIKit

import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

/// Snapshot freshness stays installation-local; saved details and bounded cover thumbnails are portable.
@MainActor
struct LibraryOfflineMetadataBackupTests {
    private nonisolated static let pluginId = "plugin.test"
    private nonisolated static let media = MediaIdentity(pluginId: pluginId, canonicalMediaId: "series-1", mediaKind: .manga)
    private nonisolated static let originalPayload = Data("original".utf8)
    private nonisolated static let refreshedPayload = Data("refreshed".utf8)
    private nonisolated static let refreshedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private nonisolated static let originalCover = "https://example.com/original.jpg"
    private nonisolated static let refreshedCover = "https://example.com/refreshed.jpg"

    private struct Fixture {
        let database: TestDatabase
        let manager: LibraryManager
        let thumbnails: LibraryCoverThumbnailStore
    }

    @Test func capabilityMigrationKeepsEveryOlderRowAndStillRejectsUnrepresentedComponents() throws {
        let database = try DatabaseQueue()
        let migrator = AppDatabase.makeMigrator()
        try migrator.migrate(database, upTo: "v21")
        let olderComponents = BackupComponent.allCases.filter { $0 != .savedLibraryThumbnails }
        #expect(olderComponents.count == 13)
        var before: [String: String] = [:]
        try database.write { db in
            for (index, component) in olderComponents.enumerated() {
                let representation: BackupRepresentation = index.isMultiple(of: 2)
                    ? .representedNonempty
                    : .representedEmpty
                try BackupCapabilityRecord(component: component, representation: representation).insert(db)
                before[component.rawValue] = representation.rawValue
            }
        }

        try migrator.migrate(database)

        try database.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT component, representation FROM backupCapability")
            let after = Dictionary(uniqueKeysWithValues: rows.map { ($0["component"] as String, $0["representation"] as String) })
            #expect(after == before)

            try BackupCapabilityRecord(component: .savedLibraryThumbnails, representation: .representedEmpty).insert(db)
            #expect(try BackupCapabilityRecord.fetchOne(db, key: "savedLibraryThumbnails")?.representation == .representedEmpty)

            for (component, representation) in [
                (nil, "representedEmpty"),
                ("futureComponent", "representedEmpty"),
                ("pluginSettings", "unrepresented")
            ] as [(String?, String)] {
                #expect(throws: DatabaseError.self) {
                    try db.execute(
                        sql: "INSERT INTO backupCapability (component, representation) VALUES (?, ?)",
                        arguments: [component, representation]
                    )
                }
            }
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM backupCapability") == 14)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let database = try TestDatabase()
        try await database.dbPool.write { db in
            for entry in AppPreferenceCatalogEntry.allCases {
                try AppPreference(key: entry.rawValue, value: entry.canonicalDefaultJSON).insert(db)
            }
            try LibraryItem(
                id: "series-1",
                title: "Series",
                coverUrl: Self.originalCover,
                pluginId: Self.pluginId,
                isAnime: false,
                pluginType: .manga,
                rawPayload: Self.originalPayload,
                anilistId: nil
            ).insert(db)
        }
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.reload()
        return Fixture(
            database: database,
            manager: manager,
            thumbnails: LibraryCoverThumbnailStore(database: database.dbPool)
        )
    }

    /// Refreshes the series' details and keeps a thumbnail for the refreshed cover.
    private func refresh(_ fixture: Fixture) async throws {
        let token = try #require(try await fixture.manager.snapshotToken(for: Self.media))
        let outcome = try await fixture.manager.replaceSnapshotDurably(
            token,
            payload: Self.refreshedPayload,
            coverUrl: Self.refreshedCover,
            chapterRowCount: 3,
            refreshedAt: Self.refreshedAt
        )
        #expect(outcome == .replaced)
        let encodedImage = try Self.jpeg(.white)
        let stored = try await fixture.thumbnails.store(
            EncodedCoverThumbnail(data: encodedImage, pixelWidth: 20, pixelHeight: 30),
            itemID: "series-1",
            coverUrl: Self.refreshedCover
        )
        #expect(stored == .stored)
    }

    private static func jpeg(_ color: UIColor) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 30), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        }
        return try #require(image.jpegData(compressionQuality: 0.8))
    }

    private func export(_ fixture: Fixture, to name: String) async throws -> URL {
        let url = fixture.database.databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent(name)
        try await BackupExportOperation(
            dbPool: fixture.database.dbPool,
            sourceDatabaseURL: fixture.database.databaseURL,
            readinessGate: {}
        ).export(to: url)
        return url
    }

    @Test func anExportCarriesSavedDetailsAndBoundedThumbnailsButNotFreshness() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        try await refresh(fixture)

        let url = try await export(fixture, to: "metadata.itobackup")
        let exported = try DatabaseQueue(path: url.path)
        defer { try? exported.close() }
        let counts = try await exported.read { db in
            try ["librarySnapshotState", "libraryCoverThumbnail"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? 0
            }
        }
        #expect(counts == [0, 1])
        let exportedPayload = try await exported.read { db in
            try LibraryItem.fetchOne(db, key: "series-1")?.rawPayload
        }
        #expect(exportedPayload == Self.refreshedPayload)
        let capability = try await exported.read { db in
            try BackupCapabilityRecord.fetchOne(db, key: BackupComponent.savedLibraryThumbnails.rawValue)
        }
        #expect(capability?.representation == .representedNonempty)
        let localCounts = try await fixture.database.dbPool.read { db in
            try ["librarySnapshotState", "libraryCoverThumbnail"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? 0
            }
        }
        #expect(localCounts == [1, 1])
    }

    @Test func anExportLeavesOutAThumbnailMadeForAnOlderCoverInsteadOfFailing() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        try await refresh(fixture)
        try await fixture.database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE libraryItem SET coverUrl = ? WHERE id = ?",
                arguments: ["https://example.com/newer.jpg", "series-1"]
            )
        }

        let url = try await export(fixture, to: "stale-thumbnail.itobackup")
        let exported = try DatabaseQueue(path: url.path)
        defer { try? exported.close() }
        let (count, capability) = try await exported.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM libraryCoverThumbnail"),
                try BackupCapabilityRecord.fetchOne(db, key: BackupComponent.savedLibraryThumbnails.rawValue)
            )
        }
        #expect(count == 0)
        #expect(capability?.representation == .representedEmpty)
        #expect(try await fixture.thumbnails.storedThumbnail(for: "series-1") != nil)
    }

    @Test(arguments: [true, false])
    func aMergeKeepsAKeptSeriesLocalThumbnailAndOnlyFillsAMissingOne(_ localHasThumbnail: Bool) async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        try await refresh(fixture)
        let exportedThumbnail = try #require(await fixture.thumbnails.storedThumbnail(for: "series-1"))
        let url = try await export(fixture, to: "merge-thumbnail.itobackup")
        let backup = try await ItoNativeImporter().parse(url: url)
        try await fixture.database.dbPool.write { db in
            _ = try LibraryCoverThumbnailRecord.deleteAll(db)
        }
        if localHasThumbnail {
            let stored = try await fixture.thumbnails.store(
                EncodedCoverThumbnail(data: try Self.jpeg(.black), pixelWidth: 20, pixelHeight: 30),
                itemID: "series-1",
                coverUrl: Self.refreshedCover
            )
            #expect(stored == .stored)
        }
        let local = try await fixture.thumbnails.storedThumbnail(for: "series-1")

        _ = try await ComponentAwareBackupRestoreOperation(dbPool: fixture.database.dbPool)
            .restore(backup, mode: .merge, operationId: "thumbnail-merge")

        let restored = try await fixture.thumbnails.storedThumbnail(for: "series-1")
        #expect(restored == (localHasThumbnail ? local : exportedThumbnail))
    }

    @Test func restoringBackupRoundTripsThumbnailWithoutRestoringFreshness() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        try await refresh(fixture)
        let expected = try #require(await fixture.thumbnails.storedThumbnail(for: "series-1"))
        let url = try await export(fixture, to: "roundtrip.itobackup")
        let backup = try await ItoNativeImporter().parse(url: url)

        let destination = try TestDatabase()
        defer { destination.cleanup() }
        _ = try await ComponentAwareBackupRestoreOperation(dbPool: destination.dbPool)
            .restore(backup, mode: .wipe, operationId: "thumbnail-roundtrip")

        let thumbnails = LibraryCoverThumbnailStore(database: destination.dbPool)
        let manager = LibraryManager(dbPool: destination.dbPool)
        #expect(try await thumbnails.storedThumbnail(for: "series-1") == expected)
        #expect(try await manager.snapshotRefreshDate(for: Self.media) == nil)
    }

    @Test func aLargeLibraryExportsTheNewestThumbnailsWithinTheBudgetWithoutChangingLocalCopies() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        try await refresh(fixture)
        var jpeg = try Self.jpeg(.white)
        jpeg.append(Data(count: LibraryCoverThumbnailRecord.maximumByteCount - jpeg.count))
        let paddedJPEG = jpeg
        let oldest = Date(timeIntervalSince1970: 1_600_000_000)
        try await fixture.database.dbPool.write { db in
            let original = try #require(try LibraryItem.fetchOne(db, key: "series-1"))
            let originalThumbnail = try #require(try LibraryCoverThumbnailRecord.fetchOne(db, key: "series-1"))
            // The original series' thumbnail is the oldest of all 66, budget-0 the next oldest.
            try db.execute(
                sql: "UPDATE libraryCoverThumbnail SET storedAt = ? WHERE libraryItemId = 'series-1'",
                arguments: [oldest]
            )
            for index in 0..<65 {
                let item = LibraryItem(
                    id: "budget-\(index)",
                    title: original.title,
                    coverUrl: original.coverUrl,
                    pluginId: original.pluginId,
                    isAnime: false,
                    pluginType: .manga,
                    rawPayload: original.rawPayload,
                    anilistId: nil
                )
                try item.insert(db)
                var thumbnail = originalThumbnail
                thumbnail.libraryItemId = item.id
                thumbnail.imageData = paddedJPEG
                thumbnail.storedAt = oldest.addingTimeInterval(Double(index + 1) * 60)
                try thumbnail.insert(db)
            }
        }

        let url = try await export(fixture, to: "bounded-thumbnails.itobackup")
        let backup = try await ItoNativeImporter().parse(url: url)
        #expect(backup.items.count == 66)
        #expect(backup.savedLibraryThumbnails.count == 64)
        #expect(
            Set(backup.savedLibraryThumbnails.map(\.libraryItemId))
                == Set((1..<65).map { "budget-\($0)" })
        )
        let bytes = backup.savedLibraryThumbnails.reduce(0) { $0 + $1.imageData.count }
        #expect(bytes <= LibraryCoverThumbnailRecord.maximumPortableAggregateByteCount)
        let localCount = try await fixture.database.dbPool.read { db in
            try LibraryCoverThumbnailRecord.fetchCount(db)
        }
        #expect(localCount == 66)
    }

    @Test func anExportPrunesThumbnailsThatAreNotWellFormedInsteadOfFailing() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        try await refresh(fixture)
        let valid = try Self.jpeg(.white)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let pngData = try #require(
            UIGraphicsImageRenderer(size: CGSize(width: 20, height: 30), format: format)
                .image { _ in }
                .pngData()
        )
        try await fixture.database.dbPool.write { db in
            let original = try #require(try LibraryItem.fetchOne(db, key: "series-1"))
            let originalThumbnail = try #require(try LibraryCoverThumbnailRecord.fetchOne(db, key: "series-1"))
            let defects: [(String, Data, Int)] = [
                ("png", pngData, 20),
                ("misdescribed", valid, 21),
                ("truncated", Data(valid.prefix(valid.count / 2)), 20)
            ]
            for (id, data, width) in defects {
                try LibraryItem(
                    id: id,
                    title: original.title,
                    coverUrl: original.coverUrl,
                    pluginId: original.pluginId,
                    isAnime: false,
                    pluginType: .manga,
                    rawPayload: original.rawPayload,
                    anilistId: nil
                ).insert(db)
                var thumbnail = originalThumbnail
                thumbnail.libraryItemId = id
                thumbnail.imageData = data
                thumbnail.pixelWidth = width
                try thumbnail.insert(db)
            }
        }

        let url = try await export(fixture, to: "pruned-thumbnails.itobackup")

        let backup = try await ItoNativeImporter().parse(url: url)
        #expect(backup.items.count == 4)
        #expect(backup.savedLibraryThumbnails.map(\.libraryItemId) == ["series-1"])
        #expect(backup.representation(of: .savedLibraryThumbnails) == .representedNonempty)
        let localCount = try await fixture.database.dbPool.read { db in
            try LibraryCoverThumbnailRecord.fetchCount(db)
        }
        #expect(localCount == 4)
    }

    @Test(arguments: ["corrupt", "truncated", "wrong-cover-digest", "wrong-dimensions", "png", "orphan"])
    func invalidThumbnailPayloadsAreRejectedBeforeRestore(_ mutation: String) async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        try await refresh(fixture)
        let url = try await export(fixture, to: "\(mutation).itobackup")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let pngData = try #require(
            UIGraphicsImageRenderer(size: CGSize(width: 20, height: 30), format: format)
                .image { _ in }
                .pngData()
        )
        let backupDB = try DatabaseQueue(path: url.path)
        try await backupDB.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            switch mutation {
            case "corrupt":
                try db.execute(
                    sql: "UPDATE libraryCoverThumbnail SET imageData = ?",
                    arguments: [Data([0, 1, 2])]
                )
            case "truncated":
                let data = try #require(try Data.fetchOne(db, sql: "SELECT imageData FROM libraryCoverThumbnail"))
                try db.execute(
                    sql: "UPDATE libraryCoverThumbnail SET imageData = ?",
                    arguments: [Data(data.prefix(data.count / 2))]
                )
            case "wrong-cover-digest":
                try db.execute(
                    sql: "UPDATE libraryCoverThumbnail SET coverURLSHA256 = ?",
                    arguments: [String(repeating: "0", count: 64)]
                )
            case "wrong-dimensions":
                try db.execute(sql: "UPDATE libraryCoverThumbnail SET pixelWidth = 21")
            case "png":
                try db.execute(sql: "UPDATE libraryCoverThumbnail SET imageData = ?", arguments: [pngData])
            default:
                try db.execute(sql: "UPDATE libraryCoverThumbnail SET libraryItemId = 'not-an-item'")
            }
        }
        try backupDB.close()

        await #expect(
            throws: BackupPreflightError.rejected(
                .invalidCapabilityMetadata(component: .savedLibraryThumbnails, code: "invalidThumbnail")
            )
        ) {
            _ = try await ItoNativeImporter().parse(url: url)
        }
    }

    /// More than 16 MiB of thumbnail bytes is refused from a size query, before any thumbnail is loaded or
    /// decoded: the rows here are not images, so loading them would fail differently. Text values count their
    /// bytes, not their characters.
    @Test(arguments: ["blob", "text"])
    func aBackupCarryingMoreThanTheBudgetOfThumbnailBytesIsRefusedBeforeTheyAreLoaded(_ storage: String) async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        try await refresh(fixture)
        let url = try await export(fixture, to: "\(storage)-budget.itobackup")
        let rowCount = storage == "blob" ? 65 : 17
        let coverHash = LibraryCoverThumbnailStore.coverHash(Self.refreshedCover)
        let fourByteCharacters = String(repeating: "\u{1D11E}", count: LibraryCoverThumbnailRecord.maximumByteCount)
        let backupDB = try DatabaseQueue(path: url.path)
        try await backupDB.write { db in
            for index in 0..<rowCount {
                let id = "oversized-\(index)"
                try LibraryItem(
                    id: id,
                    title: "Oversized \(index)",
                    coverUrl: Self.refreshedCover,
                    pluginId: Self.pluginId,
                    isAnime: false,
                    pluginType: .manga,
                    rawPayload: Data(),
                    anilistId: nil
                ).insert(db)
                let image = storage == "blob" ? "zeroblob(\(LibraryCoverThumbnailRecord.maximumByteCount))" : "?"
                var values: [(any DatabaseValueConvertible)?] = [id, coverHash]
                if storage == "text" { values.append(fourByteCharacters) }
                values.append(Self.refreshedAt)
                try db.execute(
                    sql: """
                        INSERT INTO libraryCoverThumbnail
                          (libraryItemId, coverURLSHA256, imageData, pixelWidth, pixelHeight, storedAt)
                        VALUES (?, ?, \(image), 20, 30, ?)
                        """,
                    arguments: StatementArguments(values)
                )
            }
        }
        try backupDB.close()

        await #expect(
            throws: BackupPreflightError.rejected(
                .invalidCapabilityMetadata(component: .savedLibraryThumbnails, code: "thumbnailBudgetExceeded")
            )
        ) {
            _ = try await ItoNativeImporter().parse(url: url)
        }
    }

    @Test func anOlderBackupWithoutTheThumbnailComponentIgnoresStrayRowsAndLeavesLocalThumbnailsAlone() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        try await refresh(fixture)
        let url = try await export(fixture, to: "thirteen-components.itobackup")
        let backupDB = try DatabaseQueue(path: url.path)
        try await backupDB.write { db in
            try db.execute(
                sql: "DELETE FROM backupCapability WHERE component = ?",
                arguments: [BackupComponent.savedLibraryThumbnails.rawValue]
            )
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM libraryCoverThumbnail") == 1)
        }
        try backupDB.close()

        let backup = try await ItoNativeImporter().parse(url: url)

        #expect(backup.capabilities.count == 13)
        #expect(backup.representation(of: .savedLibraryThumbnails) == .unrepresented)
        #expect(backup.savedLibraryThumbnails.isEmpty)
        #expect(!backup.representedComponents.contains(.savedLibraryThumbnails))

        try await fixture.database.dbPool.write { db in
            _ = try LibraryCoverThumbnailRecord.deleteAll(db)
        }
        let stored = try await fixture.thumbnails.store(
            EncodedCoverThumbnail(data: try Self.jpeg(.black), pixelWidth: 20, pixelHeight: 30),
            itemID: "series-1",
            coverUrl: Self.refreshedCover
        )
        #expect(stored == .stored)
        let local = try await fixture.thumbnails.storedThumbnail(for: "series-1")

        let merged = try await ComponentAwareBackupRestoreOperation(dbPool: fixture.database.dbPool)
            .restore(backup, mode: .merge, operationId: "older-merge", resolvedConflicts: ["series-1": .keepBackup])

        #expect(try await fixture.thumbnails.storedThumbnail(for: "series-1") == local)
        #expect(!merged.representedComponents.contains(.savedLibraryThumbnails))
        #expect(!merged.outcomes.contains { $0.component == .savedLibraryThumbnails })

        let destination = try TestDatabase()
        defer { destination.cleanup() }
        let wiped = try await ComponentAwareBackupRestoreOperation(dbPool: destination.dbPool)
            .restore(backup, mode: .wipe, operationId: "older-wipe")
        #expect(!wiped.outcomes.contains { $0.component == .savedLibraryThumbnails })
        let restoredCount = try await destination.dbPool.read { db in
            try LibraryCoverThumbnailRecord.fetchCount(db)
        }
        #expect(restoredCount == 0)
    }

    @Test func restoringOlderDetailsLeavesTheLocalStateAloneAndHidesTheAgeOfThePayload() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        // The backup holds the details as they were before the refresh.
        let url = try await export(fixture, to: "before-refresh.itobackup")
        try await refresh(fixture)
        let thumbnailBeforeRestore = try await fixture.thumbnails.storedThumbnail(for: "series-1")
        let tokenBeforeRestore = try #require(try await fixture.manager.snapshotToken(for: Self.media))
        #expect(try await fixture.manager.snapshotRefreshDate(for: Self.media) == Self.refreshedAt)
        let backup = try await ItoNativeImporter().parse(url: url)

        _ = try await ComponentAwareBackupRestoreOperation(
            dbPool: fixture.database.dbPool,
            operationIdProvider: { "metadata-restore" },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        ).restore(
            backup,
            mode: .merge,
            operationId: "metadata-restore",
            resolvedConflicts: ["series-1": .keepBackup]
        )

        let restored = try await fixture.database.dbPool.read { db in
            try LibraryItem.fetchOne(db, key: "series-1")?.rawPayload
        }
        #expect(restored == Self.originalPayload)
        // The restore does not touch the installation's own tables.
        let state = try await fixture.database.dbPool.read { db in try LibrarySnapshotStateRecord.fetchAll(db) }
        #expect(state.count == 1)
        #expect(try await fixture.thumbnails.storedThumbnail(for: "series-1") == thumbnailBeforeRestore)
        // The restored payload is not the one the freshness describes: its age is unknown, not stale.
        #expect(try await fixture.manager.snapshotRefreshDate(for: Self.media) == nil)
        // A refresh that began before the restore cannot write over it.
        let outcome = try await fixture.manager.replaceSnapshotDurably(
            tokenBeforeRestore,
            payload: Data("late".utf8),
            coverUrl: nil,
            chapterRowCount: 1,
            refreshedAt: Self.refreshedAt
        )
        #expect(outcome == .stale)
    }
}
