import Combine
import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// The Library's `rawPayload` blobs, as the app's own writers saved them before and after chapters carried a
/// content kind, decode through the paths the app reads them with and keep every stored value.
@MainActor
struct PersistedLibraryPayloadTests {
    @Test(arguments: PersistedLibraryFixture.allCases)
    func theDeferredDecoderReadsEveryStoredPayloadWithItsValues(fixture: PersistedLibraryFixture) async throws {
        let media = try await JSONDeferredPluginPayloadDecoder().decode(try fixture.libraryItem())

        PersistedExpectations.check(media, fixture)
    }

    @Test(arguments: [PersistedLibraryFixture.mangaABI1, .mangaABI2, .animeABI1, .animeABI2])
    func aRowSavedBeforeKindsWereStoredIsClassifiedByItsAnimeFlag(fixture: PersistedLibraryFixture) async throws {
        let item = try fixture.libraryItem(withTypeColumn: false)
        #expect(item.pluginType == nil)

        let media = try await JSONDeferredPluginPayloadDecoder().decode(item)

        PersistedExpectations.check(media, fixture)
    }

    @Test(arguments: PersistedLibraryFixture.allCases)
    func aDecodedPayloadSavedAgainByTheLibraryStaysReadableWithTheSameValues(fixture: PersistedLibraryFixture) async throws {
        let decoder = JSONDeferredPluginPayloadDecoder()
        let media = try await decoder.decode(try fixture.libraryItem())
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = LibraryManager(dbPool: database.dbPool)
        let pluginId = PersistedLibraryFixture.pluginId

        switch media {
        case .manga(let manga): _ = try await manager.saveMangaDurably(manga: manga, pluginId: pluginId)
        case .novel(let novel): _ = try await manager.saveNovelDurably(novel: novel, pluginId: pluginId)
        case .anime(let anime): _ = try await manager.saveAnimeDurably(anime: anime, pluginId: pluginId)
        }

        let saved = try #require(try await database.dbPool.read { db in
            try Ito.LibraryItem.fetchOne(db, key: fixture.id)
        })
        #expect(saved.pluginType == fixture.kind)
        PersistedExpectations.check(try await decoder.decode(saved), fixture)
    }

    /// A payload an older Foundation may have written, with each `Float` number widened to a `Double` literal.
    /// This is a tripwire for the move to `Double` numbers. Through the `Float` boundary the readers see the
    /// stored `Float`, so read marks and history keyed by that number keep matching; the model-typed checks
    /// below hold for a `Float` model and fail for a `Double` one, which would hold `1.100000023841858`. The
    /// change must then either normalise widened legacy numbers on decode or change those expectations
    /// deliberately.
    @Test func widenedFloatLiteralsStillReadAsTheSameLegacyNumbers() async throws {
        let item = Ito.LibraryItem(
            id: "manga-abi2", title: "Tower of Dusk", coverUrl: nil, pluginId: PersistedLibraryFixture.pluginId,
            isAnime: false, pluginType: .manga,
            rawPayload: try PersistedDataFixtures.data("persisted-library-manga-widened-literals.json"),
            anilistId: nil
        )
        let text = try #require(String(data: item.rawPayload, encoding: .utf8))
        #expect(text.contains("1.100000023841858"), "The fixture must hold the widened literal")
        #expect(text.contains("10.300000190734863"))
        #expect(text.contains("0.10000000149011612"))

        guard case .manga(let manga) = try await JSONDeferredPluginPayloadDecoder().decode(item) else {
            Issue.record("Decoded the wrong kind")
            return
        }

        let decimal = try #require(manga.chapters?.first { $0.key == "ch-004-decimal" })
        let other = try #require(manga.chapters?.first { $0.key == "ch-005-decimal" })
        #expect(legacyFloat(decimal.chapter) == 1.1)
        #expect(legacyFloat(decimal.volume) == 0.1)
        #expect(legacyFloat(other.chapter) == 10.3)
        #expect(sameNumber(decimal.chapter, 1.1))
        #expect(sameNumber(decimal.volume, 0.1))
        #expect(sameNumber(other.chapter, 10.3))
        // Everything else is as in the narrow payload.
        #expect(manga.chapters?.map(\.key) == PersistedExpectations.chapters(of: .mangaABI2).map(\.key))
        #expect(manga.title == "Tower of Dusk")
    }

    @Test func aPayloadIsReadAsTheKindTheRowSaysAndNeverAsAnother() async throws {
        let decoder = JSONDeferredPluginPayloadDecoder()
        let manga = try PersistedLibraryFixture.mangaABI2.payload()
        let novel = try PersistedLibraryFixture.novelABI2.payload()
        let anime = try PersistedLibraryFixture.animeABI2.payload()

        func row(_ payload: Data, kind: MediaKind, isAnime: Bool) -> Ito.LibraryItem {
            Ito.LibraryItem(
                id: "row", title: "Row", coverUrl: nil, pluginId: PersistedLibraryFixture.pluginId,
                isAnime: isAnime, pluginType: kind, rawPayload: payload, anilistId: nil
            )
        }

        // The viewer layout is what tells a manga payload from a novel one.
        await #expect(throws: (any Error).self) { try await decoder.decode(row(manga, kind: .novel, isAnime: false)) }
        await #expect(throws: (any Error).self) { try await decoder.decode(row(novel, kind: .manga, isAnime: false)) }
        await #expect(throws: (any Error).self) { try await decoder.decode(row(manga, kind: .anime, isAnime: true)) }
        // The anime flag and the stored kind must agree.
        await #expect(throws: (any Error).self) { try await decoder.decode(row(anime, kind: .anime, isAnime: false)) }
        await #expect(throws: (any Error).self) { try await decoder.decode(row(manga, kind: .manga, isAnime: true)) }
    }

    @Test(arguments: [PersistedLibraryFixture.mangaABI1, .mangaABI2, .novelABI1, .novelABI2])
    func theSavedCatalogOfAStoredPayloadIsItsChaptersAsFacts(fixture: PersistedLibraryFixture) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = LibraryManager(dbPool: database.dbPool)
        let payload = try fixture.payload()
        try await database.dbPool.write { db in
            try fixture.libraryItem().insert(db)
            try LibrarySnapshotStateRecord(
                pluginId: PersistedLibraryFixture.pluginId, mediaKind: fixture.kind, canonicalMediaId: fixture.id,
                payloadSHA256: OfflineDigest.sha256Hex(payload), refreshedAt: Date(timeIntervalSince1970: 1_000),
                catalogScope: .allEligible, catalogCompleteness: .complete,
                chapterRowCount: PersistedExpectations.chapters(of: fixture).count
            ).save(db)
        }
        try await manager.reload()

        let basis = try #require(try await manager.snapshotBasis(for: MediaIdentity(
            pluginId: PersistedLibraryFixture.pluginId, canonicalMediaId: fixture.id, mediaKind: fixture.kind
        )))

        let expected = PersistedExpectations.chapters(of: fixture)
        #expect(basis.catalog.map(\.key) == expected.map(\.key))
        for (facts, row) in zip(basis.catalog, expected) {
            #expect(sameNumber(facts.number, row.chapter), "number of \(row.key): \(String(describing: facts.number))")
            #expect(sameNumber(facts.volume, row.volume), "volume of \(row.key): \(String(describing: facts.volume))")
            // Stored data predates group identifiers and source-declared reading order.
            #expect(facts.scanlatorID == nil)
            #expect(facts.readingOrder == nil)
        }
        #expect(basis.catalog.map(\.scanlator) == expected.map(\.scanlator))
        #expect(basis.catalog.map(\.isLocked) == expected.map { $0.paywalled ?? false })
        #expect(basis.currentPayloadSHA256 == OfflineDigest.sha256Hex(payload))
    }
}

/// A Library row whose payload cannot be decoded still names its series, and stays in the Library.
@MainActor
struct LibraryPayloadFallbackTests {
    enum Corruption: CaseIterable, CustomTestStringConvertible {
        case truncated
        case empty
        case notAnObject
        case missingRequiredField
        case payloadOfAnotherKind

        var testDescription: String { String(describing: self) }

        var payload: Data {
            switch self {
            case .truncated: return Data(#"{"key":"saved-series","title":"#.utf8)
            case .empty: return Data()
            case .notAnObject: return Data("[1,2,3]".utf8)
            case .missingRequiredField: return Data(#"{"key":"saved-series","viewer":1}"#.utf8)
            case .payloadOfAnotherKind: return (try? PersistedLibraryFixture.novelABI2.payload()) ?? Data()
            }
        }
    }

    private static func savedItem(_ payload: Data) -> Ito.LibraryItem {
        Ito.LibraryItem(
            id: "saved-series", title: "Saved Title ✨", coverUrl: "https://cdn.example.test/covers/saved.jpg",
            pluginId: "com.example.saved", isAnime: false, pluginType: .manga, rawPayload: payload,
            anilistId: 77, status: "Ongoing", lastCheckedAt: Date(timeIntervalSince1970: 500),
            lastUpdatedAt: Date(timeIntervalSince1970: 400), knownChapterCount: 12
        )
    }

    @Test(arguments: Corruption.allCases)
    func aCorruptPayloadShowsTheSavedFieldsAndTheRowStaysInTheLibrary(corruption: Corruption) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let original = Self.savedItem(corruption.payload)
        try await database.dbPool.write { db in
            try original.insert(db)
            try LibraryCategory(id: "cat-keep", name: "Keep", sortOrder: 5).insert(db)
            try ItemCategoryLink(itemId: original.id, categoryId: "cat-keep").insert(db)
        }
        let manager = LibraryManager(dbPool: database.dbPool)
        try await manager.reload()
        let item = try #require(manager.items.first)
        let dependencies = PreparedLibraryDependencies.unavailable()
        let viewModel = DeferredPluginViewModel(
            item: item,
            plugins: dependencies.plugins,
            installer: dependencies.installer,
            payloadDecoder: JSONDeferredPluginPayloadDecoder(),
            presentationLogger: PresentationEventCaptureSpy()
        )

        viewModel.appear()
        await Self.untilDecodeSettles(viewModel)

        guard case .failure(.payloadDecode) = viewModel.phase else {
            Issue.record("A corrupt payload must end in the payload failure, got \(viewModel.phase)")
            return
        }
        #expect(viewModel.savedFieldsFallback == DeferredSavedFields(
            title: "Saved Title ✨",
            coverURL: URL(string: "https://cdn.example.test/covers/saved.jpg")
        ))
        #expect(viewModel.route == nil)

        // Trying again changes nothing about the row either.
        viewModel.retry()
        await Self.untilDecodeSettles(viewModel)
        #expect(viewModel.savedFieldsFallback?.title == "Saved Title ✨")

        let kept = try #require(try await database.dbPool.read { db in
            try Ito.LibraryItem.fetchOne(db, key: original.id)
        })
        #expect(kept.id == original.id)
        #expect(kept.title == original.title)
        #expect(kept.coverUrl == original.coverUrl)
        #expect(kept.pluginId == original.pluginId)
        #expect(kept.isAnime == original.isAnime)
        #expect(kept.pluginType == original.pluginType)
        #expect(kept.rawPayload == corruption.payload)
        #expect(kept.anilistId == 77)
        #expect(kept.status == "Ongoing")
        #expect(kept.knownChapterCount == 12)
        let links = try await database.dbPool.read { db in
            try ItemCategoryLink.filter(Column("itemId") == original.id).fetchCount(db)
        }
        #expect(links == 1)
        try await manager.reload()
        #expect(manager.items.map(\.id) == [original.id])
    }

    @Test func aReadablePayloadHasNoFallback() async throws {
        let item = Ito.LibraryItem(
            id: PersistedLibraryFixture.mangaABI2.id, title: PersistedLibraryFixture.mangaABI2.title,
            coverUrl: PersistedLibraryFixture.mangaABI2.coverURL, pluginId: PersistedLibraryFixture.pluginId,
            isAnime: false, pluginType: .manga, rawPayload: try PersistedLibraryFixture.mangaABI2.payload(),
            anilistId: nil
        )
        let dependencies = PreparedLibraryDependencies.unavailable()
        let viewModel = DeferredPluginViewModel(
            item: item,
            plugins: dependencies.plugins,
            installer: dependencies.installer,
            payloadDecoder: JSONDeferredPluginPayloadDecoder(),
            presentationLogger: PresentationEventCaptureSpy()
        )

        viewModel.appear()
        await Self.untilDecodeSettles(viewModel)

        guard case .pluginMissing = viewModel.phase else {
            Issue.record("A readable payload with no installed source waits for the source, got \(viewModel.phase)")
            return
        }
        #expect(viewModel.savedFieldsFallback == nil)
    }

    /// Returns once the payload decode has produced its outcome. It is event-driven: the view model's phase
    /// publishes each change, and the decode is the only work started.
    private static func untilDecodeSettles(_ viewModel: DeferredPluginViewModel) async {
        var subscription: AnyCancellable?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            subscription = viewModel.$phase.sink { phase in
                guard !resumed else { return }
                switch phase {
                case .idle, .decoding, .loadingRunner, .loadingSavedDetails: return
                default:
                    resumed = true
                    continuation.resume()
                }
            }
        }
        subscription?.cancel()
    }
}
