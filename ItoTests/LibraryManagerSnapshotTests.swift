import Combine
import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

/// Saved Library details are replaced by a refreshed copy only while they are still the ones the refresh
/// started from; nothing else about the Library changes.
@MainActor
struct LibraryManagerSnapshotTests {
    private nonisolated static let pluginId = "plugin.test"
    private nonisolated static let media = MediaIdentity(pluginId: pluginId, canonicalMediaId: "series-1", mediaKind: .manga)
    private nonisolated static let refreshedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private nonisolated static let originalPayload = Data("original".utf8)
    private nonisolated static let refreshedPayload = Data("refreshed".utf8)

    private struct Fixture {
        let database: TestDatabase
        let manager: LibraryManager

        func payload(id: String = "series-1") async throws -> Data? {
            try await database.dbPool.read { db in try LibraryItem.fetchOne(db, key: id)?.rawPayload }
        }

        func state() async throws -> LibrarySnapshotStateRecord? {
            try await database.dbPool.read { db in try LibrarySnapshotStateRecord.fetchOne(db) }
        }
    }

    private func makeFixture(
        coverUrl: String? = "https://example.com/original.jpg",
        rawPayload: Data = LibraryManagerSnapshotTests.originalPayload
    ) async throws -> Fixture {
        let database = try TestDatabase()
        let manager = LibraryManager(dbPool: database.dbPool)
        try await database.dbPool.write { db in
            try LibraryItem(
                id: "series-1",
                title: "My Label",
                coverUrl: coverUrl,
                pluginId: Self.pluginId,
                isAnime: false,
                pluginType: .manga,
                rawPayload: rawPayload,
                anilistId: nil
            ).insert(db)
        }
        try await manager.reload()
        return Fixture(database: database, manager: manager)
    }

    private func token(_ fixture: Fixture) async throws -> LibrarySnapshotToken {
        try #require(try await fixture.manager.snapshotToken(for: Self.media))
    }

    private func replace(
        _ fixture: Fixture,
        _ token: LibrarySnapshotToken,
        payload: Data = LibraryManagerSnapshotTests.refreshedPayload,
        coverUrl: String? = "https://example.com/refreshed.jpg",
        chapterRowCount: Int = 12,
        catalog: LibraryCatalogDescription = .unknown
    ) async throws -> LibrarySnapshotReplaceOutcome {
        try await fixture.manager.replaceSnapshotDurably(
            token,
            payload: payload,
            coverUrl: coverUrl,
            chapterRowCount: chapterRowCount,
            catalog: catalog,
            refreshedAt: Self.refreshedAt
        )
    }

    @Test func theTokenNamesTheSavedPayloadAndIsNilForAnUnsavedSeries() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }

        let token = try await token(fixture)

        #expect(token.itemID == "series-1")
        #expect(token.media == Self.media)
        #expect(token.payloadSHA256 == OfflineDigest.sha256Hex(Self.originalPayload))
        let unsaved = MediaIdentity(pluginId: Self.pluginId, canonicalMediaId: "other", mediaKind: .manga)
        #expect(try await fixture.manager.snapshotToken(for: unsaved) == nil)
    }

    @Test func aRefreshReplacesTheDetailsAndRecordsWhenAndForWhichPayload() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        let token = try await token(fixture)

        let outcome = try await replace(fixture, token)

        #expect(outcome == .replaced)
        #expect(try await fixture.payload() == Self.refreshedPayload)
        let item = try #require(try await fixture.database.dbPool.read { db in
            try LibraryItem.fetchOne(db, key: "series-1")
        })
        // The title is the user's own label; the cover follows the source.
        #expect(item.title == "My Label")
        #expect(item.coverUrl == "https://example.com/refreshed.jpg")
        let state = try #require(try await fixture.state())
        #expect(state.media == Self.media)
        #expect(state.payloadSHA256 == OfflineDigest.sha256Hex(Self.refreshedPayload))
        #expect(state.refreshedAt == Self.refreshedAt)
        #expect(state.chapterRowCount == 12)
        #expect(state.catalogScope == .unknown)
        #expect(state.catalogCompleteness == .unknown)
        #expect(fixture.manager.items.first?.rawPayload == Self.refreshedPayload)
        #expect(try await fixture.manager.snapshotRefreshDate(for: Self.media) == Self.refreshedAt)
    }

    @Test func aRefreshWithoutAChapterListChangesNothing() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        let token = try await token(fixture)

        let outcome = try await replace(fixture, token, chapterRowCount: 0)

        #expect(outcome == .rejectedIncomplete)
        #expect(try await fixture.payload() == Self.originalPayload)
        #expect(try await fixture.state() == nil)
    }

    @Test func aRefreshWithoutACoverKeepsTheSavedCover() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        let token = try await token(fixture)

        #expect(try await replace(fixture, token, coverUrl: nil) == .replaced)

        let cover = try await fixture.database.dbPool.read { db in
            try LibraryItem.fetchOne(db, key: "series-1")?.coverUrl
        }
        #expect(cover == "https://example.com/original.jpg")
    }

    @Test func aNarrowerCatalogReplacesTheSavedCompleteOneAndIsRecordedAsNarrower() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        let complete = LibraryCatalogDescription(scope: .allEligible, completeness: .complete)
        #expect(try await replace(fixture, try await token(fixture), catalog: complete) == .replaced)

        let filtered = LibraryCatalogDescription(scope: .visible, completeness: .complete)
        let partial = LibraryCatalogDescription(scope: .allEligible, completeness: .partial)
        let unknown = LibraryCatalogDescription.unknown
        let allEligibleUnknown = LibraryCatalogDescription(scope: .allEligible, completeness: .unknown)
        for narrower in [filtered, partial, unknown, allEligibleUnknown] {
            let payload = Data("narrower \(narrower.scope) \(narrower.completeness)".utf8)
            let outcome = try await replace(fixture, try await token(fixture), payload: payload, catalog: narrower)
            #expect(outcome == .replaced)
            #expect(try await fixture.payload() == payload)
            // What the source reports now is what is recorded, so the entire-series claim drops with it.
            let state = try #require(try await fixture.state())
            #expect(state.catalog == narrower)
            #expect(!state.coversEntireSeries)
        }

        // A complete catalog may be refreshed by another complete one, and then the claim comes back.
        let newer = try await replace(fixture, try await token(fixture), payload: Data("newer".utf8), catalog: complete)
        #expect(newer == .replaced)
        #expect(try await fixture.state()?.coversEntireSeries == true)
    }

    @Test func anUnchangedRefreshOnlyRecordsTheTimeAndWritesNoLibraryRow() async throws {
        let fixture = try await makeFixture(coverUrl: "https://example.com/original.jpg")
        defer { fixture.database.cleanup() }
        let counter = LibraryItemChangeCounter()
        try await fixture.database.dbPool.writeWithoutTransaction { db in
            db.add(transactionObserver: counter, extent: .observerLifetime)
        }
        let later = Self.refreshedAt.addingTimeInterval(3_600)

        // The refresh returns exactly the bytes and cover the item already has.
        let outcome = try await fixture.manager.replaceSnapshotDurably(
            try await token(fixture),
            payload: Self.originalPayload,
            coverUrl: "https://example.com/original.jpg",
            chapterRowCount: 4,
            refreshedAt: later
        )

        #expect(outcome == .replaced)
        #expect(counter.changeCount == 0)
        #expect(try await fixture.payload() == Self.originalPayload)
        let state = try #require(try await fixture.state())
        #expect(state.refreshedAt == later)
        #expect(state.chapterRowCount == 4)
        #expect(state.payloadSHA256 == OfflineDigest.sha256Hex(Self.originalPayload))
        #expect(try await fixture.manager.snapshotRefreshDate(for: Self.media) == later)

        // The same bytes with a different cover is a change.
        _ = try await replace(
            fixture,
            try await token(fixture),
            payload: Self.originalPayload,
            coverUrl: "https://example.com/new.jpg"
        )
        #expect(counter.changeCount == 1)
    }

    @Test func aCatalogIsStoredWithItsScopeAndCompletenessApart() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        let filteredButComplete = LibraryCatalogDescription(scope: .visible, completeness: .complete)

        #expect(try await replace(fixture, try await token(fixture), catalog: filteredButComplete) == .replaced)

        let state = try #require(try await fixture.state())
        #expect(state.catalogScope == .visible)
        #expect(state.catalogCompleteness == .complete)
        // A complete list of what is visible does not cover the series.
        #expect(!state.catalog.coversEntireSeries)
        #expect(LibraryCatalogDescription(scope: .allEligible, completeness: .complete).coversEntireSeries)
        #expect(!LibraryCatalogDescription(scope: .allEligible, completeness: .partial).coversEntireSeries)
        #expect(!LibraryCatalogDescription(scope: .allEligible, completeness: .unknown).coversEntireSeries)
        #expect(!LibraryCatalogDescription(scope: .unknown, completeness: .complete).coversEntireSeries)
    }

    @Test func anEmptyCatalogIsNeverComplete() {
        func state(rows: Int, scope: LibraryCatalogScope, completeness: LibraryCatalogCompleteness)
            -> LibrarySnapshotStateRecord {
            LibrarySnapshotStateRecord(
                pluginId: Self.pluginId,
                mediaKind: .manga,
                canonicalMediaId: "series-1",
                payloadSHA256: String(repeating: "a", count: 64),
                refreshedAt: Self.refreshedAt,
                catalogScope: scope,
                catalogCompleteness: completeness,
                chapterRowCount: rows
            )
        }

        #expect(state(rows: 12, scope: .allEligible, completeness: .complete).coversEntireSeries)
        #expect(!state(rows: 0, scope: .allEligible, completeness: .complete).coversEntireSeries)
        #expect(!state(rows: 12, scope: .visible, completeness: .complete).coversEntireSeries)
        #expect(!state(rows: 12, scope: .allEligible, completeness: .unknown).coversEntireSeries)
    }

    @Test func reportedValuesThatAreMissingOrUnrecognisedAreUnknown() {
        #expect(LibraryCatalogScope(reported: nil) == .unknown)
        #expect(LibraryCatalogScope(reported: "somethingNew") == .unknown)
        #expect(LibraryCatalogScope(reported: "visible") == .visible)
        #expect(LibraryCatalogScope(reported: "allEligible") == .allEligible)
        #expect(LibraryCatalogCompleteness(reported: nil) == .unknown)
        #expect(LibraryCatalogCompleteness(reported: "somethingNew") == .unknown)
        #expect(LibraryCatalogCompleteness(reported: "partial") == .partial)
        #expect(LibraryCatalogCompleteness(reported: "complete") == .complete)
    }

    @Test func onlyACompleteCatalogOfEveryEligibleUploadBacksTheEntireSeriesClaim() {
        let cells: [(CatalogScope, CatalogCompleteness, SeriesCatalogScope)] = [
            (.unknown, .unknown, .unknown),
            (.unknown, .partial, .partial),
            (.unknown, .complete, .unknown),
            (.visible, .unknown, .visible),
            (.visible, .partial, .partial),
            (.visible, .complete, .visible),
            (.allEligible, .unknown, .unknown),
            (.allEligible, .partial, .partial),
            (.allEligible, .complete, .complete)
        ]
        for (scope, completeness, offline) in cells {
            let description = LibraryCatalogDescription(ChapterCatalog(scope: scope, completeness: completeness))
            let state = LibrarySnapshotStateRecord(
                pluginId: Self.pluginId,
                mediaKind: .manga,
                canonicalMediaId: "series-1",
                payloadSHA256: String(repeating: "a", count: 64),
                refreshedAt: Self.refreshedAt,
                catalogScope: description.scope,
                catalogCompleteness: description.completeness,
                chapterRowCount: 3
            )
            let claim = scope == .allEligible && completeness == .complete
            #expect(description.coversEntireSeries == claim, "\(scope) \(completeness)")
            #expect(state.coversEntireSeries == claim, "\(scope) \(completeness)")
            #expect(state.offlineSnapshot.catalogScope == offline, "\(scope) \(completeness)")
        }
        #expect(LibraryCatalogDescription(nil) == .unknown)
    }

    // MARK: - Recording a refresh through the refresher

    private func makeRefresher(_ fixture: Fixture) -> MediaDetailSnapshotRefresher {
        MediaDetailSnapshotRefresher(library: fixture.manager)
    }

    private static func manga(chapters count: Int, catalog: ChapterCatalog?) -> Manga {
        Manga(
            key: "series-1",
            title: "Series",
            chapters: (0..<count).map { index in
                Chapter(key: "c\(index)", volume: nil, chapter: Double(index + 1), scanlator: "A", paywalled: nil)
            },
            catalog: catalog
        )
    }

    @Test func aRefreshRecordsTheCatalogTheSourceReportedForTheEntireSeriesClaim() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        let token = try await token(fixture)
        let complete = ChapterCatalog(scope: .allEligible, completeness: .complete)

        let saved = await makeRefresher(fixture).replace(
            token,
            with: Self.manga(chapters: 3, catalog: complete),
            refreshedAt: Self.refreshedAt
        )

        #expect(saved == Self.refreshedAt)
        let state = try #require(try await fixture.state())
        #expect(state.catalog == LibraryCatalogDescription(complete))
        #expect(state.offlineSnapshot.catalogScope == .complete)
        #expect(try await fixture.manager.snapshotBasis(for: Self.media)?.snapshot.catalogScope == .complete)
    }

    @Test func aLaterNarrowerVisibleCatalogReplacesTheCompleteOneAndTheClaimDrops() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        let refresher = makeRefresher(fixture)
        let firstToken = try await token(fixture)
        let first = await refresher.replace(
            firstToken,
            with: Self.manga(chapters: 3, catalog: ChapterCatalog(scope: .allEligible, completeness: .complete)),
            refreshedAt: Self.refreshedAt
        )
        #expect(first == Self.refreshedAt)

        let laterToken = try await token(fixture)
        let later = Self.refreshedAt.addingTimeInterval(60)
        let second = await refresher.replace(
            laterToken,
            with: Self.manga(chapters: 4, catalog: ChapterCatalog(scope: .visible, completeness: .complete)),
            refreshedAt: later
        )
        #expect(second == later)

        let state = try #require(try await fixture.state())
        #expect(state.catalog == LibraryCatalogDescription(scope: .visible, completeness: .complete))
        #expect(state.offlineSnapshot.catalogScope == .visible)
        let basis = try #require(try await fixture.manager.snapshotBasis(for: Self.media))
        #expect(basis.snapshot.catalogScope == .visible)
    }

    @Test func aSourceThatReportsNoCatalogRecordsUnknownAndDropsAnEarlierClaim() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        let refresher = makeRefresher(fixture)
        let firstToken = try await token(fixture)
        let first = await refresher.replace(
            firstToken,
            with: Self.manga(chapters: 3, catalog: ChapterCatalog(scope: .allEligible, completeness: .complete)),
            refreshedAt: Self.refreshedAt
        )
        #expect(first == Self.refreshedAt)

        let laterToken = try await token(fixture)
        let second = await refresher.replace(
            laterToken,
            with: Self.manga(chapters: 3, catalog: nil),
            refreshedAt: Self.refreshedAt
        )
        #expect(second == Self.refreshedAt)

        let state = try #require(try await fixture.state())
        #expect(state.catalog == .unknown)
        #expect(state.offlineSnapshot.catalogScope == .unknown)
    }

    @Test func anEmptyOrMissingChapterListIsNeverSaved() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        let refresher = makeRefresher(fixture)
        let complete = ChapterCatalog(scope: .allEligible, completeness: .complete)

        let emptyToken = try await token(fixture)
        let empty = await refresher.replace(
            emptyToken,
            with: Self.manga(chapters: 0, catalog: complete),
            refreshedAt: Self.refreshedAt
        )
        #expect(empty == nil)

        let missingToken = try await token(fixture)
        let missing = await refresher.replace(
            missingToken,
            with: Manga(key: "series-1", title: "Series", catalog: complete),
            refreshedAt: Self.refreshedAt
        )
        #expect(missing == nil)

        #expect(try await fixture.payload() == Self.originalPayload)
        #expect(try await fixture.state() == nil)
    }

    @Test func aRestoredPayloadWithACompleteCatalogInItsJSONMakesNoClaim() async throws {
        let restored = try JSONEncoder().encode(Self.manga(
            chapters: 3,
            catalog: ChapterCatalog(scope: .allEligible, completeness: .complete)
        ))

        // Saved without a refresh: no state row, so nothing backs the claim.
        let unrecorded = try await makeFixture(rawPayload: restored)
        defer { unrecorded.database.cleanup() }
        #expect(try await unrecorded.state() == nil)
        #expect(try await unrecorded.manager.snapshotBasis(for: Self.media) == nil)

        // A complete refresh of other bytes, then a restore of this payload: the state describes a payload that
        // is no longer saved, so it does not back the claim.
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        let complete = LibraryCatalogDescription(scope: .allEligible, completeness: .complete)
        #expect(try await replace(fixture, try await token(fixture), catalog: complete) == .replaced)
        try await fixture.database.dbPool.write { db in
            try db.execute(sql: "UPDATE libraryItem SET rawPayload = ? WHERE id = ?", arguments: [restored, "series-1"])
        }
        let basis = try #require(try await fixture.manager.snapshotBasis(for: Self.media))
        #expect(basis.snapshot.payloadSHA256 != basis.currentPayloadSHA256)
        #expect(basis.catalog.isEmpty)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func cancellingDuringEncodingLeavesTheSavedCompletePayloadAndClaimUnchanged() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        let original = try JSONEncoder().encode(Self.manga(
            chapters: 3,
            catalog: ChapterCatalog(scope: .allEligible, completeness: .complete)
        ))
        let initial = try await token(fixture)
        #expect(try await fixture.manager.replaceSnapshotDurably(
            initial,
            payload: original,
            coverUrl: nil,
            chapterRowCount: 3,
            catalog: LibraryCatalogDescription(scope: .allEligible, completeness: .complete),
            refreshedAt: Self.refreshedAt
        ) == .replaced)
        let completeState = try #require(try await fixture.state())
        let token = try await token(fixture)
        let encoder = SuspendedSnapshotEncoder()
        defer { Task { await encoder.releaseAll() } }
        let refresher = MediaDetailSnapshotRefresher(library: fixture.manager, encoder: encoder)
        let task = Task {
            await refresher.replace(
                token,
                with: Self.manga(
                    chapters: 4,
                    catalog: ChapterCatalog(scope: .visible, completeness: .complete)
                ),
                refreshedAt: Self.refreshedAt.addingTimeInterval(60)
            )
        }

        try await encoder.waitUntilStarted(1)
        task.cancel()
        await encoder.release(request: 1)
        #expect(await task.value == nil)
        #expect(await encoder.observedCancellationState(for: 1) == true)
        #expect(try await fixture.payload() == original)
        #expect(try await fixture.state() == completeState)
        let basis = try #require(try await fixture.manager.snapshotBasis(for: Self.media))
        #expect(basis.snapshot.catalogScope == .complete)
        #expect(basis.currentPayloadSHA256 == completeState.payloadSHA256)
    }

    // MARK: - Stale tokens

    @Test func aTokenReadBeforeARelinkRefusesTheRefreshAndWritesNothing() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        let token = try await token(fixture)
        let relinkedPayload = Data("relinked".utf8)
        _ = try await LibrarySourceRemapper(dbPool: fixture.database.dbPool).relink(
            pluginId: Self.pluginId,
            mediaKind: .manga,
            possibleSourceItemIds: ["series-1"],
            destinationItemId: "series-2",
            title: "Relinked",
            coverUrl: nil,
            rawPayload: relinkedPayload
        )

        let outcome = try await replace(fixture, token)

        #expect(outcome == .stale)
        #expect(try await fixture.payload(id: "series-1") == nil)
        #expect(try await fixture.payload(id: "series-2") == relinkedPayload)
        #expect(try await fixture.state() == nil)
    }

    @Test func aTokenReadBeforeARestoreOfAnOlderPayloadRefusesTheRefresh() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        let token = try await token(fixture)
        // A restore writes the backup's payload over the saved one.
        let restoredPayload = Data("restored".utf8)
        try await fixture.database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE libraryItem SET rawPayload = ? WHERE id = 'series-1'",
                arguments: [restoredPayload]
            )
        }

        let outcome = try await replace(fixture, token)

        #expect(outcome == .stale)
        #expect(try await fixture.payload() == restoredPayload)
        #expect(try await fixture.state() == nil)
    }

    @Test func aTokenReadBeforeTheSeriesWasRemovedAndSavedAgainRefusesTheRefresh() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        let token = try await token(fixture)
        try await fixture.manager.removeItemDurably(media: Self.media)
        _ = try await fixture.manager.saveMangaDurably(
            manga: Manga(key: "series-1", title: "Saved again", chapters: [Chapter(key: "c1", chapter: 1)]),
            pluginId: Self.pluginId
        )
        let savedAgain = try #require(try await fixture.payload())

        let outcome = try await replace(fixture, token)

        #expect(outcome == .stale)
        #expect(try await fixture.payload() == savedAgain)
        #expect(try await fixture.state() == nil)
    }

    @Test func aTokenReadBeforeAnotherRefreshRefusesTheSecondOne() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        let first = try await token(fixture)
        let second = try await token(fixture)
        #expect(try await replace(fixture, first) == .replaced)

        let outcome = try await replace(fixture, second, payload: Data("late".utf8))

        #expect(outcome == .stale)
        #expect(try await fixture.payload() == Self.refreshedPayload)
    }

    @Test func aRestoredPayloadHasNoRefreshDateEvenThoughTheStateRowRemains() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        #expect(try await replace(fixture, try await token(fixture)) == .replaced)
        #expect(try await fixture.manager.snapshotRefreshDate(for: Self.media) == Self.refreshedAt)

        try await fixture.database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE libraryItem SET rawPayload = ? WHERE id = 'series-1'",
                arguments: [Self.originalPayload]
            )
        }

        #expect(try await fixture.manager.snapshotRefreshDate(for: Self.media) == nil)
        #expect(try await fixture.state() != nil)
    }

    // MARK: - Removal and downloads

    @Test func removingTheSeriesDeletesItsSnapshotStateAndKeepsOthers() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        #expect(try await replace(fixture, try await token(fixture)) == .replaced)
        let other = MediaIdentity(pluginId: Self.pluginId, canonicalMediaId: "series-9", mediaKind: .manga)
        try await fixture.database.dbPool.write { db in
            try LibrarySnapshotStateRecord(
                pluginId: other.pluginId,
                mediaKind: other.mediaKind,
                canonicalMediaId: other.canonicalMediaId,
                payloadSHA256: OfflineDigest.sha256Hex(Data("x".utf8)),
                refreshedAt: Self.refreshedAt,
                catalogScope: .unknown,
                catalogCompleteness: .unknown,
                chapterRowCount: 1
            ).insert(db)
        }

        try await fixture.manager.removeItemDurably(media: Self.media)

        let remaining = try await fixture.database.dbPool.read { db in
            try LibrarySnapshotStateRecord.fetchAll(db).map(\.canonicalMediaId)
        }
        #expect(remaining == ["series-9"])
    }

    @Test func aRefreshNeverTouchesDownloadedChapters() async throws {
        let fixture = try await makeFixture()
        defer { fixture.database.cleanup() }
        try await fixture.database.dbPool.write { db in
            try DownloadedChapterRecord(
                pluginId: Self.pluginId,
                mediaKind: .manga,
                canonicalMediaId: "series-1",
                chapterKey: "gone-from-the-new-list",
                authorityScope: .publicUnscoped,
                versionId: UUID().uuidString,
                state: .verified,
                damageReason: nil,
                contentKind: .images,
                pageCount: 1,
                byteCount: 4,
                manifestFormatVersion: 1,
                manifestSHA256: String(repeating: "a", count: 64),
                chapterSnapshot: Data("{}".utf8),
                seriesTitle: "Series",
                sourceEpoch: nil,
                verifiedAt: Self.refreshedAt
            ).insert(db)
        }

        // The new list names no chapter the series had; the saved copy is still there.
        #expect(try await replace(fixture, try await token(fixture), chapterRowCount: 1) == .replaced)

        let count = try await fixture.database.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloadedChapter") ?? 0
        }
        #expect(count == 1)
    }

    /// The proof observation reads the two small proof tables, so a refresh that changes only its time reaches the
    /// entire-series filter while the Library's own rows stay exactly as they were.
    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aRefreshThatChangesOnlyItsTimeIsPublishedToTheProofsAndNotToTheLibrary() async throws {
        let fixture = try await makeObservedFixture()
        defer { fixture.database.cleanup() }
        #expect(try await replace(
            fixture,
            try await token(fixture),
            catalog: LibraryCatalogDescription(scope: .allEligible, completeness: .complete)
        ) == .replaced)
        for await proofs in fixture.manager.offlineProofSnapshotPublisher.values
        where proofs.states[Self.media] != nil {
            break
        }
        let libraryBefore = fixture.manager.items

        let laterRefresh = Self.refreshedAt.addingTimeInterval(3_600)
        let outcome = try await fixture.manager.replaceSnapshotDurably(
            try await token(fixture),
            payload: Self.refreshedPayload,
            coverUrl: nil,
            chapterRowCount: 12,
            catalog: LibraryCatalogDescription(scope: .allEligible, completeness: .complete),
            refreshedAt: laterRefresh
        )
        #expect(outcome == .replaced)
        for await proofs in fixture.manager.offlineProofSnapshotPublisher.values
        where proofs.states[Self.media]?.refreshedAt == laterRefresh {
            break
        }
        #expect(fixture.manager.items == libraryBefore)
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func removingTheSeriesDropsItsProofStateAndItsRememberedEditionTogether() async throws {
        let fixture = try await makeObservedFixture()
        defer { fixture.database.cleanup() }
        #expect(try await replace(
            fixture,
            try await token(fixture),
            catalog: LibraryCatalogDescription(scope: .allEligible, completeness: .complete)
        ) == .replaced)
        try await fixture.database.dbPool.write { db in
            try SeriesEditionPreferenceRecord.save(.allUploads, for: Self.media, at: Self.refreshedAt, in: db)
        }
        for await proofs in fixture.manager.offlineProofSnapshotPublisher.values
        where proofs.states[Self.media] != nil && proofs.preferences[Self.media] != nil {
            break
        }

        try await fixture.manager.removeItemDurably(media: Self.media)
        for await proofs in fixture.manager.offlineProofSnapshotPublisher.values
        where proofs.states[Self.media] == nil && proofs.preferences[Self.media] == nil {
            break
        }
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aRememberedEditionReachesTheProofsAsItsStoredBytes() async throws {
        let fixture = try await makeObservedFixture()
        defer { fixture.database.cleanup() }
        let stored = try EditionSelection.scanlators([ScanlatorRef(name: "A")]).storageData()
        try await fixture.database.dbPool.write { db in
            try SeriesEditionPreferenceRecord.save(.scanlators([ScanlatorRef(name: "A")]), for: Self.media, at: Self.refreshedAt, in: db)
        }
        for await proofs in fixture.manager.offlineProofSnapshotPublisher.values
        where proofs.preferences[Self.media] == stored {
            break
        }
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aRekeyedSeriesLosesItsProofStateAtOnce() async throws {
        let fixture = try await makeObservedFixture()
        defer { fixture.database.cleanup() }
        #expect(try await replace(
            fixture,
            try await token(fixture),
            catalog: LibraryCatalogDescription(scope: .allEligible, completeness: .complete)
        ) == .replaced)
        for await proofs in fixture.manager.offlineProofSnapshotPublisher.values
        where proofs.states[Self.media] != nil {
            break
        }

        // The statement the rekey runs against the state table.
        try await fixture.database.dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM librarySnapshotState WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ?",
                arguments: [Self.media.pluginId, Self.media.mediaKind.rawValue, Self.media.canonicalMediaId]
            )
        }
        for await proofs in fixture.manager.offlineProofSnapshotPublisher.values
        where proofs.states[Self.media] == nil {
            break
        }
    }

    private func makeObservedFixture() async throws -> Fixture {
        let database = try TestDatabase()
        let manager = LibraryManager(dbPool: database.dbPool, observationScheduler: ImmediateValueObservationScheduler())
        try await database.dbPool.write { db in
            try LibraryItem(
                id: "series-1",
                title: "My Label",
                coverUrl: "https://example.com/original.jpg",
                pluginId: Self.pluginId,
                isAnime: false,
                pluginType: .manga,
                rawPayload: Self.originalPayload,
                anilistId: nil
            ).insert(db)
        }
        try await manager.reload()
        return Fixture(database: database, manager: manager)
    }
}

/// Counts the row changes a write makes to `libraryItem`.
private nonisolated final class LibraryItemChangeCounter: TransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var changes = 0

    var changeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return changes
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        eventKind.tableName == "libraryItem"
    }

    func databaseDidChange(with event: DatabaseEvent) {
        lock.lock()
        changes += 1
        lock.unlock()
    }

    func databaseDidCommit(_ db: Database) {}

    func databaseDidRollback(_ db: Database) {}
}
