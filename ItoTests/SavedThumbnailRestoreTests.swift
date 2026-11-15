import UIKit

import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

/// A saved thumbnail follows the established Library identity mapping on restore, never a coinciding row id:
/// the backup item and the local item it matches by identity carry different ids.
@MainActor
struct SavedThumbnailRestoreTests {
    private static let pluginId = "test.plugin"
    private static let coverA = "https://example.com/a.jpg"
    private static let coverB = "https://example.com/b.jpg"
    private static let outdatedCover = "https://example.com/outdated.jpg"

    private struct Snapshot: Equatable {
        let items: [Ito.LibraryItem]
        let categories: [LibraryCategory]
        let thumbnails: [LibraryCoverThumbnailRecord]
    }

    private static func item(
        _ id: String,
        title: String,
        cover: String?,
        kind: MediaKind = .manga
    ) -> Ito.LibraryItem {
        Ito.LibraryItem(
            id: id,
            title: title,
            coverUrl: cover,
            pluginId: pluginId,
            isAnime: false,
            pluginType: kind,
            rawPayload: Data(title.utf8),
            anilistId: nil
        )
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

    private static func png() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 30), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        }
        return try #require(image.pngData())
    }

    private static func thumbnail(
        _ itemID: String,
        cover: String,
        data: Data
    ) -> LibraryCoverThumbnailRecord {
        LibraryCoverThumbnailRecord(
            libraryItemId: itemID,
            coverURLSHA256: LibraryCoverThumbnailStore.coverHash(cover),
            imageData: data,
            pixelWidth: 20,
            pixelHeight: 30,
            storedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func seed(
        _ database: TestDatabase,
        items: [Ito.LibraryItem],
        thumbnails: [LibraryCoverThumbnailRecord] = []
    ) async throws {
        try await database.dbPool.write { db in
            for item in items { try item.insert(db) }
            for thumbnail in thumbnails { try thumbnail.insert(db) }
        }
    }

    private func restore(
        _ backup: ImportedBackup,
        into database: TestDatabase,
        resolvedConflicts: [String: ConflictResolution] = [:]
    ) async throws -> BackupRestoreReport {
        try await ComponentAwareBackupRestoreOperation(dbPool: database.dbPool).restore(
            backup,
            mode: .merge,
            operationId: "saved-thumbnail-restore",
            resolvedConflicts: resolvedConflicts
        )
    }

    private func snapshot(_ database: TestDatabase) async throws -> Snapshot {
        try await database.dbPool.read { db in
            Snapshot(
                items: try Ito.LibraryItem.order(Column("id")).fetchAll(db),
                categories: try LibraryCategory.order(Column("id")).fetchAll(db),
                thumbnails: try LibraryCoverThumbnailRecord.order(Column("libraryItemId")).fetchAll(db)
            )
        }
    }

    private func outcome(_ report: BackupRestoreReport) throws -> ComponentOutcome {
        try #require(report.outcomes.first { $0.component == .savedLibraryThumbnails })
    }

    // MARK: Identity mapping

    @Test func aMergeFillsTheThumbnailOfTheLocalItemABackupItemMatchesByIdentity() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let local = Self.item("test.plugin_media-1", title: "Local", cover: Self.coverA)
        let imported = Self.item("media-1", title: "Backup", cover: Self.coverA)
        let white = try Self.jpeg(.white)
        try await seed(database, items: [local])

        let report = try await restore(
            ImportedBackup(
                items: [imported],
                savedLibraryThumbnails: [Self.thumbnail(imported.id, cover: Self.coverA, data: white)]
            ),
            into: database
        )

        let state = try await snapshot(database)
        #expect(state.items.map(\.id) == [local.id])
        #expect(state.thumbnails.map(\.libraryItemId) == [local.id])
        #expect(state.thumbnails.first?.imageData == white)
        #expect(try outcome(report).inserted == 1)
    }

    @Test func aNewItemThatCollidesWithADifferentLocalSeriesTakesItsThumbnailToTheNewID() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        // A manga holds the raw id "42"; the backup's novel of the same key can only land on the kind-scoped id.
        let manga = Self.item("42", title: "Manga", cover: Self.coverA, kind: .manga)
        let novel = Self.item("42", title: "Novel", cover: Self.coverB, kind: .novel)
        let mangaThumbnail = Self.thumbnail(manga.id, cover: Self.coverA, data: try Self.jpeg(.black))
        let novelData = try Self.jpeg(.white)
        try await seed(database, items: [manga], thumbnails: [mangaThumbnail])

        let report = try await restore(
            ImportedBackup(
                items: [novel],
                savedLibraryThumbnails: [Self.thumbnail(novel.id, cover: Self.coverB, data: novelData)]
            ),
            into: database
        )

        let novelTargetID = "\(Self.pluginId)\u{1F}novel\u{1F}42"
        let state = try await snapshot(database)
        #expect(state.items.map(\.id).sorted() == ["42", novelTargetID].sorted())
        let byID = Dictionary(uniqueKeysWithValues: state.thumbnails.map { ($0.libraryItemId, $0) })
        #expect(Set(byID.keys) == ["42", novelTargetID])
        #expect(byID["42"] == mangaThumbnail)
        #expect(byID[novelTargetID]?.imageData == novelData)
        #expect(try outcome(report).inserted == 1)
    }

    // MARK: Merge dispositions

    @Test func keepingTheBackupSeriesReplacesADifferingLocalThumbnail() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let local = Self.item("test.plugin_media-1", title: "Local", cover: Self.coverA)
        let imported = Self.item("media-1", title: "Backup", cover: Self.coverA)
        let white = try Self.jpeg(.white)
        try await seed(
            database,
            items: [local],
            thumbnails: [Self.thumbnail(local.id, cover: Self.coverA, data: try Self.jpeg(.black))]
        )

        let report = try await restore(
            ImportedBackup(
                items: [imported],
                savedLibraryThumbnails: [Self.thumbnail(imported.id, cover: Self.coverA, data: white)]
            ),
            into: database,
            resolvedConflicts: [local.id: .keepBackup]
        )

        let state = try await snapshot(database)
        #expect(state.items.map(\.title) == ["Backup"])
        #expect(state.thumbnails.map(\.libraryItemId) == [local.id])
        #expect(state.thumbnails.first?.imageData == white)
        #expect(try outcome(report).replaced == 1)
    }

    @Test(arguments: ["valid", "outdated"])
    func keepingTheLocalSeriesKeepsAValidLocalThumbnailAndReplacesAnOutdatedOne(_ localThumbnail: String) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let local = Self.item("test.plugin_media-1", title: "Local", cover: Self.coverA)
        let imported = Self.item("media-1", title: "Backup", cover: Self.coverA)
        let black = try Self.jpeg(.black)
        let white = try Self.jpeg(.white)
        let localRow = Self.thumbnail(
            local.id,
            cover: localThumbnail == "valid" ? Self.coverA : Self.outdatedCover,
            data: black
        )
        try await seed(database, items: [local], thumbnails: [localRow])

        let report = try await restore(
            ImportedBackup(
                items: [imported],
                savedLibraryThumbnails: [Self.thumbnail(imported.id, cover: Self.coverA, data: white)]
            ),
            into: database,
            resolvedConflicts: [local.id: .keepLocal]
        )

        let state = try await snapshot(database)
        #expect(state.items.map(\.title) == ["Local"])
        #expect(state.thumbnails.map(\.libraryItemId) == [local.id])
        if localThumbnail == "valid" {
            #expect(state.thumbnails == [localRow])
            #expect(try outcome(report).preservedLocal == 1)
        } else {
            let replaced = try #require(state.thumbnails.first)
            #expect(replaced.imageData == white)
            #expect(replaced.coverURLSHA256 == LibraryCoverThumbnailStore.coverHash(Self.coverA))
            #expect(try outcome(report).replaced == 1)
        }
    }

    @Test(arguments: [false, true])
    func aThumbnailMadeForAnotherCoverThanTheKeptSeriesHasIsSkipped(_ localHasThumbnail: Bool) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        // The kept local series shows cover B; the backup's thumbnail was made for the cover A it had.
        let local = Self.item("test.plugin_media-1", title: "Local", cover: Self.coverB)
        let imported = Self.item("media-1", title: "Backup", cover: Self.coverA)
        let localRows = localHasThumbnail
            ? [Self.thumbnail(local.id, cover: Self.coverB, data: try Self.jpeg(.black))]
            : []
        try await seed(database, items: [local], thumbnails: localRows)

        let report = try await restore(
            ImportedBackup(
                items: [imported],
                savedLibraryThumbnails: [Self.thumbnail(imported.id, cover: Self.coverA, data: try Self.jpeg(.white))]
            ),
            into: database
        )

        let state = try await snapshot(database)
        #expect(state.items == [local])
        #expect(state.thumbnails == localRows)
        let result = try outcome(report)
        #expect(result.skipped == 1)
        #expect(result.inserted == 0)
        #expect(result.replaced == 0)
    }

    // MARK: Preflight rejection

    @Test(arguments: ["duplicate", "orphan", "wrong-dimensions", "png"])
    func aBackupWithAnInvalidThumbnailIsRejectedBeforeAnythingIsWritten(_ defect: String) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let local = Self.item("test.plugin_media-1", title: "Local", cover: Self.coverA)
        let imported = Self.item("media-1", title: "Backup", cover: Self.coverA)
        let fresh = Self.item("media-2", title: "Fresh", cover: Self.coverA)
        let good = Self.thumbnail(imported.id, cover: Self.coverA, data: try Self.jpeg(.white))
        try await seed(
            database,
            items: [local],
            thumbnails: [Self.thumbnail(local.id, cover: Self.coverA, data: try Self.jpeg(.black))]
        )
        let thumbnails: [LibraryCoverThumbnailRecord]
        switch defect {
        case "duplicate":
            thumbnails = [good, good]
        case "orphan":
            thumbnails = [good, Self.thumbnail("not-in-the-backup", cover: Self.coverA, data: good.imageData)]
        case "wrong-dimensions":
            var misdescribed = Self.thumbnail(fresh.id, cover: Self.coverA, data: good.imageData)
            misdescribed.pixelWidth = 21
            thumbnails = [good, misdescribed]
        default:
            thumbnails = [good, Self.thumbnail(fresh.id, cover: Self.coverA, data: try Self.png())]
        }
        let before = try await snapshot(database)

        await #expect(
            throws: BackupPreflightError.rejected(
                .invalidComponentData(component: .savedLibraryThumbnails, code: "invalidThumbnail")
            )
        ) {
            _ = try await restore(
                ImportedBackup(
                    categories: [LibraryCategory(id: "backup-category", name: "Backup", sortOrder: 7)],
                    items: [imported, fresh],
                    savedLibraryThumbnails: thumbnails
                ),
                into: database
            )
        }

        #expect(try await snapshot(database) == before)
    }

    /// 64 thumbnails of the largest encoded size are exactly the aggregate budget.
    @Test(arguments: [64, 65])
    func aBackupWithinTheAggregateBudgetRestoresAndOnePastItIsRejectedAtomically(_ count: Int) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        var padded = try Self.jpeg(.white)
        padded.append(Data(count: LibraryCoverThumbnailRecord.maximumByteCount - padded.count))
        let items = (0..<count).map { Self.item("budget-\($0)", title: "Item \($0)", cover: Self.coverA) }
        let thumbnails = items.map { Self.thumbnail($0.id, cover: Self.coverA, data: padded) }
        let before = try await snapshot(database)

        let backup = ImportedBackup(items: items, savedLibraryThumbnails: thumbnails)
        if count == 64 {
            let report = try await restore(backup, into: database)
            #expect(try outcome(report).inserted == 64)
            #expect(try await snapshot(database).thumbnails.count == 64)
        } else {
            await #expect(
                throws: BackupPreflightError.rejected(
                    .invalidComponentData(component: .savedLibraryThumbnails, code: "invalidThumbnail")
                )
            ) {
                _ = try await restore(backup, into: database)
            }
            #expect(try await snapshot(database) == before)
        }
    }
}
