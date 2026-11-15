import Foundation
import Nuke
import Testing
import ito_runner
@testable import Ito

/// Opening one chosen saved copy: the reader is picked from the copy's own saved form, the chosen descriptor is
/// pinned in the entry the reader starts from, and the selected chapter reads only its leased bytes.
@MainActor
struct DownloadedAlternativeReaderRouteTests {
    private static let pluginID = "plugin.test"

    private struct NotAChapterReader: Error {}

    private struct Opened {
        let isText: Bool
        let content: ReaderContentSource
        let entry: MediaEntry
        let chapter: Chapter
    }

    private static func opened(_ destination: MediaDetailReaderDestination) throws -> Opened {
        switch destination {
        case .pages(_, let content, _, let entry, let chapter):
            return Opened(isText: false, content: content, entry: entry, chapter: chapter)
        case .text(_, let content, _, let entry, let chapter):
            return Opened(isText: true, content: content, entry: entry, chapter: chapter)
        case .anime:
            throw NotAChapterReader()
        }
    }

    private static func manga(chapters: [Chapter]? = nil, cover: String? = nil) -> Manga {
        Manga(key: "series-1", title: "Series One", cover: cover, chapters: chapters)
    }

    private static func novel(chapters: [Chapter]? = nil) -> Novel {
        Novel(key: "series-1", title: "Series One", chapters: chapters)
    }

    private static func open(
        _ real: RealAlternativeFixture,
        entry: MediaEntry,
        remote: ItoRunner? = nil
    ) async throws -> (opened: Opened, lease: OfflineChapterLease) {
        let lease = try await real.openLease()
        let destination = try MediaDetailReaderDestination.downloadedAlternative(
            real.candidate,
            lease: lease,
            of: entry,
            remote: remote,
            pluginID: pluginID
        )
        return (try opened(destination), lease)
    }

    private static func text(_ value: String) -> OfflinePageInput {
        OfflineStoreFixture.textPage(0, value)
    }

    // MARK: - 30

    @Test func aMangaCopySavedAsTextOpensTheTextReaderButKeepsTheMangaKind() async throws {
        // The descriptor claims images, as the live catalog's format would; the saved form decides.
        let real = try await RealAlternativeFixture.make(upload: .upload("b", kind: .images), pages: [Self.text("Words.")])

        let (opened, lease) = try await Self.open(real, entry: .manga(Self.manga()))

        #expect(opened.isText)
        #expect(opened.entry.kind == .manga)
        #expect(opened.chapter.kind == .text)
        #expect(opened.chapter.key == "b")
        #expect(opened.content.preference == .localOnly(chapterKey: "b", lease: lease))
    }

    @Test func aNovelCopySavedAsImagesOpensPagesButKeepsTheNovelKind() async throws {
        let real = try await RealAlternativeFixture.make(mediaKind: .novel, upload: .upload("b", kind: .text))

        let (opened, _) = try await Self.open(real, entry: .novel(Self.novel()))

        #expect(!opened.isText)
        #expect(opened.entry.kind == .novel)
        #expect(opened.chapter.kind == .images)
    }

    // MARK: - 31, 32

    @Test func theEntryTheReaderStartsFromListsTheSavedDescriptorInPlaceOfAConflictingLiveOne() async throws {
        let real = try await RealAlternativeFixture.make()
        let live = Self.manga(chapters: [
            .upload("a", unit: "unit-1"),
            Chapter(key: "b", title: "Live B", scanlator: "Live group", kind: .text, logicalUnitID: "unit-1"),
            .upload("c", unit: "unit-2")
        ])

        let (opened, _) = try await Self.open(real, entry: .manga(live))

        let chapters = try #require(opened.entry.chapters)
        #expect(chapters.map(\.key) == ["a", "b", "c"])
        let saved = chapters[1]
        #expect(saved.title == "Title b")
        #expect(saved.scanlator == "Other")
        #expect(saved.scanlatorID == "g-b")
        #expect(saved.kind == .images)
        #expect(!opened.isText)
        // The detail screen's own series is untouched: the reader's entry is a copy.
        #expect(live.chapters?[1].title == "Live B")
        #expect(live.chapters?[1].kind == .text)
    }

    @Test func aCopyTheLiveCatalogDoesNotListOpensAloneWithoutInventingNeighborsOrNeedingASource() async throws {
        let real = try await RealAlternativeFixture.make()
        let live = Self.manga(chapters: [.upload("a", unit: "unit-1"), .upload("c", unit: "unit-2")], cover: "https://cover.test/c.jpg")

        let (opened, _) = try await Self.open(real, entry: .manga(live), remote: nil)

        #expect(opened.entry.chapters?.map(\.key) == ["b"])
        #expect(opened.entry.key == "series-1")
        #expect(opened.entry.title == "Series One")
        #expect(opened.entry.cover == "https://cover.test/c.jpg")
        #expect(opened.entry.kind == .manga)
        #expect(opened.content.remote == nil)
    }

    @Test func anEntryThatIsNotTheCopysSeriesOrAnAnimeEntryNeverRoutes() async throws {
        let real = try await RealAlternativeFixture.make()
        let lease = try await real.openLease()

        #expect(throws: DownloadedAlternativeError.selectionChanged) {
            try MediaDetailReaderDestination.downloadedAlternative(
                real.candidate,
                lease: lease,
                of: .manga(Manga(key: "series-2", title: "Other")),
                remote: nil,
                pluginID: Self.pluginID
            )
        }
        #expect(throws: DownloadedAlternativeError.selectionChanged) {
            try MediaDetailReaderDestination.downloadedAlternative(
                real.candidate,
                lease: lease,
                of: .manga(Self.manga()),
                remote: nil,
                pluginID: "plugin.other"
            )
        }
        #expect(throws: DownloadedAlternativeError.unsupportedMediaKind) {
            try MediaDetailReaderDestination.downloadedAlternative(
                real.candidate,
                lease: lease,
                of: .anime(Anime(key: "series-1", title: "Series One")),
                remote: nil,
                pluginID: Self.pluginID
            )
        }
    }

    // MARK: - 33

    @Test func aMixedCopyKeepsEveryPageInOrderAndTheSavedLayoutPicksTheReader() async throws {
        let pages = [
            OfflineStoreFixture.imagePage(0),
            OfflineStoreFixture.textPage(1, "Between."),
            OfflineStoreFixture.imagePage(2)
        ]
        let defaulted = try await RealAlternativeFixture.make(upload: .upload("b", kind: nil), pages: pages)
        let texty = try await RealAlternativeFixture.make(upload: .upload("b", kind: .text), pages: pages)

        let (imagesFirst, lease) = try await Self.open(defaulted, entry: .manga(Self.manga()))
        let (textFirst, _) = try await Self.open(texty, entry: .manga(Self.manga()))

        #expect(lease.manifest.contentKind == .mixed)
        #expect(!imagesFirst.isText)
        #expect(textFirst.isText)

        let remote = RecordingAlternativeMangaLoader()
        let loader = ResolvingMangaPageLoader(
            pluginID: Self.pluginID,
            local: defaulted.store,
            remote: remote,
            preference: imagesFirst.content.preference
        )
        let loaded = try await loader.pages(for: imagesFirst.entry, chapter: imagesFirst.chapter, operation: makeTestNetworkOperation())

        #expect(loaded.map(\.index) == [0, 1, 2])
        guard case .url(let first) = loaded[0].content, case .text(let between) = loaded[1].content,
              case .url(let last) = loaded[2].content else {
            Issue.record("Image, text and image pages keep their form")
            return
        }
        #expect(first.hasPrefix("ito-offline://") && last.hasPrefix("ito-offline://"))
        #expect(between == "Between.")
        #expect(remote.callCount == 0)
    }

    // MARK: - 34

    @Test func aSeedThatDoesNotMatchItsScopeFailsLocallyWithoutDiscoveryOrASource() async throws {
        let real = try await RealAlternativeFixture.make()
        let lease = try await real.openLease()
        let foreignFixture = try OfflineStoreFixture()
        let foreign = foreignFixture.makeStore()
        struct Case {
            let name: String
            let plugin: String
            let local: any OfflineChapterReading
            let entry: MediaEntry
            let seedKey: String
            let chapterKey: String
        }
        let cases = [
            Case(name: "plugin", plugin: "plugin.other", local: real.store, entry: .manga(Self.manga()), seedKey: "b", chapterKey: "b"),
            Case(name: "kind", plugin: Self.pluginID, local: real.store, entry: .novel(Self.novel()), seedKey: "b", chapterKey: "b"),
            Case(
                name: "series", plugin: Self.pluginID, local: real.store,
                entry: .manga(Manga(key: "series-2", title: "Other")), seedKey: "b", chapterKey: "b"
            ),
            Case(name: "chapter", plugin: Self.pluginID, local: real.store, entry: .manga(Self.manga()), seedKey: "x", chapterKey: "x"),
            Case(name: "directory", plugin: Self.pluginID, local: foreign, entry: .manga(Self.manga()), seedKey: "b", chapterKey: "b")
        ]
        for scenario in cases {
            let remote = RecordingAlternativeMangaLoader()
            let loader = ResolvingMangaPageLoader(
                pluginID: scenario.plugin,
                local: scenario.local,
                remote: remote,
                preference: .localOnly(chapterKey: scenario.seedKey, lease: lease)
            )

            await #expect(throws: OfflineReadError.localCopyUnavailable, "\(scenario.name)") {
                try await loader.pages(
                    for: scenario.entry,
                    chapter: Chapter(key: scenario.chapterKey, title: "x"),
                    operation: makeTestNetworkOperation()
                )
            }
            #expect(remote.callCount == 0, "\(scenario.name)")
        }
    }

    // MARK: - 35

    @Test func aSelectedTextCopyThatTurnsUnreadableFailsLocallyOnEveryAttemptAndNeverAsksASource() async throws {
        enum Damage: CaseIterable { case tampered, missing, notUTF8 }
        for damage in Damage.allCases {
            let pages = damage == .notUTF8
                ? [OfflinePageInput(content: .text(Data([0xFF, 0xFE, 0xFD])), sourceIndex: 0)]
                : [Self.text("Original.")]
            let real = try await RealAlternativeFixture.make(pages: pages)
            let (opened, lease) = try await Self.open(real, entry: .manga(Self.manga()))
            let leased = try #require(lease.page(fileName: OfflinePageFileName.make(index: 0, fileExtension: "txt")))
            switch damage {
            case .tampered: real.fixture.fileSystem.replaceFile(at: leased.fileURL, with: Data("tampered".utf8))
            case .missing: try real.fixture.fileSystem.removeItem(at: leased.fileURL)
            case .notUTF8: break
            }
            let remote = RecordingAlternativeNovelLoader()
            let loader = ResolvingNovelChapterLoader(
                pluginID: Self.pluginID,
                local: real.store,
                remote: remote,
                preference: opened.content.preference
            )

            for _ in 0..<2 {
                await #expect(throws: OfflineReadError.localCopyDamaged, "\(damage)") {
                    try await loader.content(for: opened.entry, chapter: opened.chapter, operation: makeTestNetworkOperation())
                }
            }
            #expect(remote.callCount == 0, "\(damage)")
        }
    }

    @Test func aLockedDeviceKeepsTheTypedProtectedDataFailureForTheSelectedCopy() async throws {
        let real = try await RealAlternativeFixture.make(pages: [Self.text("Original.")])
        let (opened, _) = try await Self.open(real, entry: .manga(Self.manga()))
        let remote = RecordingAlternativeNovelLoader()
        let loader = ResolvingNovelChapterLoader(
            pluginID: Self.pluginID,
            local: real.store,
            remote: remote,
            preference: opened.content.preference
        )
        real.fixture.fileSystem.setLocked(true)

        await #expect(throws: OfflineReadError.protectedDataUnavailable) {
            try await loader.content(for: opened.entry, chapter: opened.chapter, operation: makeTestNetworkOperation())
        }
        real.fixture.fileSystem.setLocked(false)
        let pages = try await loader.content(for: opened.entry, chapter: opened.chapter, operation: makeTestNetworkOperation())
        #expect(pages.count == 1)
        #expect(remote.callCount == 0)
    }

    // MARK: - 36

    @Test func aSelectedImageThatIsTamperedWithFailsThroughTheOfflinePipelineAndNeverReachesARemoteOne() async throws {
        let real = try await RealAlternativeFixture.make()
        let (opened, lease) = try await Self.open(real, entry: .manga(Self.manga()))
        let remote = RecordingAlternativeMangaLoader()
        let loader = ResolvingMangaPageLoader(
            pluginID: Self.pluginID,
            local: real.store,
            remote: remote,
            preference: opened.content.preference
        )
        let leased = try #require(lease.page(fileName: OfflinePageFileName.make(index: 0, fileExtension: "jpg")))
        real.fixture.fileSystem.replaceFile(at: leased.fileURL, with: Data("tampered".utf8))
        let remoteLoader = CountingDataLoader()
        let remotePipeline = ImagePipeline {
            $0.dataLoader = remoteLoader
            $0.dataCache = nil
            $0.imageCache = nil
        }

        for attempt in 0..<2 {
            let pages = try await loader.pages(for: opened.entry, chapter: opened.chapter, operation: makeTestNetworkOperation())
            guard case .url(let locator) = pages[0].content else {
                Issue.record("An image page is addressed by its offline locator")
                return
            }
            #expect(locator.hasPrefix("ito-offline://"))
            let session = ReaderPageImageSession(
                pipeline: remotePipeline,
                offlinePipeline: OfflineImagePipeline.make(reader: real.store)
            )
            let descriptor = ReaderPageImageDescriptor(
                pageID: "attempt-\(attempt)",
                request: URLRequest(url: try #require(URL(string: locator)))
            )

            let decoded = await OfflineReadingTestSupport.awaitSettled(session, descriptor)

            #expect(!decoded)
        }
        #expect(remoteLoader.count == 0)
        #expect(remote.callCount == 0)
    }

    // MARK: - 37

    @Test func theSelectedCopyStaysVersionPinnedWhileAnOrdinaryReaderStartsLocalFirst() async throws {
        let real = try await RealAlternativeFixture.make()
        let (opened, lease) = try await Self.open(real, entry: .manga(Self.manga()))
        let remote = RecordingAlternativeMangaLoader()
        let selected = ResolvingMangaPageLoader(
            pluginID: Self.pluginID,
            local: real.store,
            remote: remote,
            preference: opened.content.preference
        )
        let before = try await selected.pages(for: opened.entry, chapter: opened.chapter, operation: makeTestNetworkOperation())

        try await real.store.delete(real.fixture.edition("b"))
        let replacement = try await real.fixture.publishUpload(
            real.store,
            .upload("b", group: "Other", groupID: "g-b"),
            pages: [OfflineStoreFixture.imagePage(7)]
        )
        let after = try await selected.pages(for: opened.entry, chapter: opened.chapter, operation: makeTestNetworkOperation())

        func token(_ pages: [Page]) -> String {
            guard case .url(let locator)? = pages.first?.content else { return "" }
            return locator
        }
        #expect(token(before) == token(after))
        #expect(token(after).contains(lease.token.uuidString))
        #expect(after.count == 2)

        // Another reader of the same chapter is ordinary: it reads whatever copy is current.
        let ordinary = ResolvingMangaPageLoader(pluginID: Self.pluginID, local: real.store, remote: remote)
        let current = try await ordinary.pages(for: opened.entry, chapter: opened.chapter, operation: makeTestNetworkOperation())
        #expect(!token(current).contains(lease.token.uuidString))
        #expect(current.count == 1)
        #expect(real.store.leases.isLeased(versionId: replacement))
        #expect(remote.callCount == 0)
    }

    // MARK: - 38

    @Test func ordinaryLocalFirstStillFallsBackToTheSourceWhenACopyIsDamaged() async throws {
        let real = try await RealAlternativeFixture.make(pages: [Self.text("Original.")])
        let lease = try await real.openLease()
        let leased = try #require(lease.page(fileName: OfflinePageFileName.make(index: 0, fileExtension: "txt")))
        real.fixture.fileSystem.replaceFile(at: leased.fileURL, with: Data("tampered".utf8))
        let remote = RecordingAlternativeMangaLoader()
        let loader = ResolvingMangaPageLoader(pluginID: Self.pluginID, local: real.store, remote: remote)
        let entry = MediaEntry.manga(Self.manga())
        let chapter = Chapter(key: "b", title: "b")

        _ = try await loader.pages(for: entry, chapter: chapter, operation: makeTestNetworkOperation())
        _ = try await loader.pages(for: entry, chapter: chapter, operation: makeTestNetworkOperation())

        #expect(remote.callCount == 2)
    }

    @Test func readingOnlineThisTimeAndReadingTheCopyAgainKeepTheirOrdinarySemantics() async throws {
        let real = try await RealAlternativeFixture.make()
        let remote = RecordingAlternativeMangaLoader()
        let loader = ResolvingMangaPageLoader(
            pluginID: Self.pluginID,
            local: real.store,
            remote: remote,
            preference: .remoteThisTime(chapterKey: "b")
        )
        let entry = MediaEntry.manga(Self.manga())
        let chapter = Chapter(key: "b", title: "b")

        _ = try await loader.pages(for: entry, chapter: chapter, operation: makeTestNetworkOperation())
        #expect(remote.callCount == 1)
        #expect(loader.isReadingRemoteThisTime(chapterKey: "b"))

        loader.readDownloadedCopy(chapterKey: "b")
        let local = try await loader.pages(for: entry, chapter: chapter, operation: makeTestNetworkOperation())
        #expect(remote.callCount == 1)
        #expect(local.count == 2)
    }

    // MARK: - 42

    @Test func theCentersLeaseTheSourceResolverAndTheOfflinePipelineShareOneLeaseDirectory() async throws {
        let fixture = try DownloadWorkerFixture()
        try await fixture.offline.publishUpload(fixture.store, .upload("a"))
        try await fixture.offline.publishUpload(fixture.store, .upload("b", group: "Other", groupID: "g-b"))
        let anchor = OfflineChapterAlternativeAnchor.catalog(edition: fixture.edition(chapterKey: "a"), logicalUnitID: "unit-1")
        let listed = try await fixture.center.downloadedAlternatives(for: anchor)
        let candidate = try #require(listed.candidates.first)
        let lease = try await fixture.center.openDownloadedAlternative(candidate, sourceEpoch: listed.sourceEpoch)
        let loader = ResolvingMangaPageLoader(
            pluginID: Self.pluginID,
            local: fixture.store,
            remote: nil,
            preference: .localOnly(chapterKey: "b", lease: lease)
        )

        let pages = try await loader.pages(
            for: .manga(Self.manga()),
            chapter: candidate.chapter,
            operation: makeTestNetworkOperation()
        )
        guard case .url(let locator) = pages[0].content else {
            Issue.record("An image page is addressed by its offline locator")
            return
        }
        let url = try #require(URL(string: locator))
        let bytes = try await OfflineReadingTestSupport.load(OfflineAssetDataLoader(reader: fixture.store), URLRequest(url: url))

        #expect(bytes == OfflineStoreFixture.jpeg("image-0"))
        #expect(fixture.store.leases.resolvePage(token: lease.token, fileName: "p0000.jpg") != nil)
    }
}

@MainActor
private final class RecordingAlternativeMangaLoader: MangaPageLoading {
    private(set) var callCount = 0

    func pages(for entry: MediaEntry, chapter: Chapter, operation: PluginNetworkOperation) async throws -> [Page] {
        _ = (entry, chapter, operation)
        callCount += 1
        return [Page(index: 0, content: .url("https://remote.example.test/p0000.jpg"))]
    }
}

@MainActor
private final class RecordingAlternativeNovelLoader: NovelChapterLoading {
    private(set) var callCount = 0

    func content(for entry: MediaEntry, chapter: Chapter, operation: PluginNetworkOperation) async throws -> [Page] {
        _ = (entry, chapter, operation)
        callCount += 1
        return [Page(index: 0, content: .text("Remote page."))]
    }
}
