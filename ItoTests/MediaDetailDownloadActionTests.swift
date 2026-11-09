import Combine
import XCTest
import ito_runner
@testable import Ito

/// The series details' download controls: which chapters offer which action, what reaches the download
/// service, and what is reported back.
@MainActor
final class MediaDetailDownloadActionTests: XCTestCase {
    private static let pluginID = "plugin.test"
    private static let series = Manga(
        key: "series-1",
        title: "Series One",
        chapters: [
            Chapter(key: "chapter-1", chapter: 1),
            Chapter(key: "locked", chapter: 2, paywalled: true)
        ]
    )

    func testUnavailableDownloadsShowNoStateAndNoActions() {
        let downloads = MediaDetailDownloadsFake(isAvailable: false)
        downloads.set(.downloaded, chapterKey: "chapter-1")
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads)

        XCTAssertFalse(viewModel.showsDownloadControls)
        XCTAssertNil(viewModel.downloadState(for: chapter("chapter-1")))
        XCTAssertEqual(viewModel.downloadActions(for: chapter("chapter-1")), [])
    }

    func testDownloadIsOfferedOnlyForAnUnlockedChapterOfASavedSeries() {
        let saved = makeViewModel(media: Self.series, saved: true, downloads: MediaDetailDownloadsFake())
        let unsaved = makeViewModel(media: Self.series, saved: false, downloads: MediaDetailDownloadsFake())

        XCTAssertEqual(saved.downloadActions(for: chapter("chapter-1")), [.download])
        XCTAssertEqual(saved.downloadActions(for: chapter("locked")), [])
        XCTAssertEqual(unsaved.downloadActions(for: chapter("chapter-1")), [])
    }

    func testASavedOnlySeriesOffersNoDownloadButStillManagesItsCopies() {
        let downloads = MediaDetailDownloadsFake()
        downloads.set(.downloaded, chapterKey: "chapter-1")
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads, savedOnly: true)
        viewModel.start()

        XCTAssertEqual(viewModel.detailLoadState, .savedOnly)
        XCTAssertEqual(viewModel.downloadActions(for: chapter("chapter-1")), [.delete])
        XCTAssertEqual(viewModel.downloadActions(for: chapter("chapter-2")), [])
    }

    func testEachStateOffersItsActionsAndRetryOnlyWhereAnEventCannotClearTheWait() {
        let cases: [(ChapterDownloadState, [ChapterDownloadAction])] = [
            (.queued, [.cancel]),
            (.downloading(completed: 1, total: 3), [.cancel]),
            (.waiting(.meteredNetwork), [.cancel]),
            (.waiting(.appInBackground), [.cancel]),
            (.waiting(.sourceConfigurationChanged), [.retry, .cancel]),
            (.waiting(.sourceUnavailable), [.retry, .cancel]),
            (.waiting(.restoredPendingReview), [.retry, .cancel]),
            (.failed(.network), [.retry, .cancel]),
            (.downloaded, [.delete]),
            (.damaged, [.delete])
        ]
        for (state, expected) in cases {
            let downloads = MediaDetailDownloadsFake()
            downloads.set(state, chapterKey: "chapter-1")
            let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads)

            XCTAssertEqual(viewModel.downloadState(for: chapter("chapter-1")), state)
            XCTAssertEqual(viewModel.downloadActions(for: chapter("chapter-1")), expected, "\(state)")
        }
    }

    func testAnAnimeSeriesNeverShowsDownloadControls() {
        let anime = Anime(key: "anime", title: "Anime", episodes: [Anime.Episode(key: "e1", title: "e1", episode: 1)])
        let viewModel = makeViewModel(media: anime, saved: true, downloads: MediaDetailDownloadsFake())

        XCTAssertFalse(viewModel.showsDownloadControls)
        XCTAssertEqual(viewModel.downloadActions(for: anime.episodes![0]), [])
    }

    func testDownloadQueuesTheExactChapterOfTheSeriesWithoutAMessage() async {
        let downloads = MediaDetailDownloadsFake()
        let messages = MediaDetailMessageSpy()
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads, messages: messages)

        await viewModel.performDownloadAction(.download, for: chapter("chapter-1")).value

        XCTAssertEqual(downloads.downloadRequests.count, 1)
        let request = downloads.downloadRequests.first
        XCTAssertEqual(
            request?.media,
            MediaIdentity(pluginId: Self.pluginID, canonicalMediaId: "series-1", mediaKind: .manga)
        )
        XCTAssertEqual(request?.chapterKey, "chapter-1")
        XCTAssertEqual(request?.entryKey, "series-1")
        XCTAssertEqual(request?.seriesTitle, "Series One")
        XCTAssertTrue(messages.messages.isEmpty)
    }

    func testANovelChapterIsQueuedAsANovelEntry() async {
        let novel = Novel(key: "novel-1", title: "Novel", chapters: [Chapter(key: "n1", chapter: 1)])
        let downloads = MediaDetailDownloadsFake()
        let viewModel = makeViewModel(media: novel, saved: true, downloads: downloads)

        await viewModel.performDownloadAction(.download, for: novel.chapters![0]).value

        XCTAssertEqual(downloads.downloadRequests.first?.entryKind, .novel)
        XCTAssertEqual(downloads.downloadRequests.first?.media.mediaKind, .novel)
    }

    func testARefusedDownloadSaysTheChapterCannotBeDownloaded() async {
        let downloads = MediaDetailDownloadsFake()
        downloads.downloadOutcome = .refused(.paywalled)
        let messages = MediaDetailMessageSpy()
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads, messages: messages)

        await viewModel.performDownloadAction(.download, for: chapter("chapter-1")).value

        XCTAssertEqual(messages.messages, [.downloadRefused])
    }

    func testADownloadTheStoreCouldNotQueueIsReportedAsAFailedAction() async {
        let downloads = MediaDetailDownloadsFake()
        downloads.downloadOutcome = .refused(.unavailable)
        let messages = MediaDetailMessageSpy()
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads, messages: messages)

        await viewModel.performDownloadAction(.download, for: chapter("chapter-1")).value

        XCTAssertEqual(messages.messages, [.downloadActionFailed])
    }

    func testCancelRetryAndDeleteReachTheStoreForTheExactEdition() async {
        let downloads = MediaDetailDownloadsFake()
        let messages = MediaDetailMessageSpy()
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads, messages: messages)
        let edition = OfflineChapterEdition(
            pluginId: Self.pluginID,
            mediaKind: .manga,
            canonicalMediaId: "series-1",
            chapterKey: "chapter-1"
        )

        await viewModel.performDownloadAction(.cancel, for: chapter("chapter-1")).value
        await viewModel.performDownloadAction(.retry, for: chapter("chapter-1")).value
        await viewModel.performDownloadAction(.delete, for: chapter("chapter-1")).value

        XCTAssertEqual(downloads.editionCalls, [.cancel(edition), .retry(edition), .delete(edition)])
        XCTAssertTrue(messages.messages.isEmpty)
    }

    func testAFailedDeleteIsReportedWhileTheScreenIsShownAndSilentAfterItCloses() async {
        let downloads = MediaDetailDownloadsFake()
        downloads.failure = OfflineStoreError.versionUnavailable
        let messages = MediaDetailMessageSpy()
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads, messages: messages)
        viewModel.start()
        viewModel.appear()

        await viewModel.performDownloadAction(.delete, for: chapter("chapter-1")).value
        XCTAssertEqual(messages.messages, [.downloadActionFailed])

        viewModel.disappear()
        await viewModel.performDownloadAction(.delete, for: chapter("chapter-1")).value
        XCTAssertEqual(messages.messages, [.downloadActionFailed])
    }

    func testAStateRecordedForAnotherSeriesIsNotShown() {
        let downloads = MediaDetailDownloadsFake()
        let otherSource = MediaIdentity(pluginId: "plugin.other", canonicalMediaId: "series-1", mediaKind: .manga)
        downloads.set(.downloaded, chapterKey: "chapter-1", media: otherSource)
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads)

        XCTAssertNil(viewModel.downloadState(for: chapter("chapter-1")))
        XCTAssertEqual(viewModel.downloadActions(for: chapter("chapter-1")), [.download])
    }

    func testAStoreChangeReachesTheOpenScreen() {
        let downloads = MediaDetailDownloadsFake()
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads)
        XCTAssertNil(viewModel.downloadState(for: chapter("chapter-1")))

        downloads.set(.downloading(completed: 1, total: 3), chapterKey: "chapter-1")
        XCTAssertEqual(viewModel.downloadState(for: chapter("chapter-1")), .downloading(completed: 1, total: 3))

        downloads.set(.downloaded, chapterKey: "chapter-1")
        XCTAssertEqual(viewModel.downloadActions(for: chapter("chapter-1")), [.delete])
    }

    func testDownloadDecidesOnTheCurrentChapterAndRefusesOneNoLongerListedOrNowLocked() async {
        let downloads = MediaDetailDownloadsFake()
        let messages = MediaDetailMessageSpy()
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads, messages: messages)

        // The row still holds an unlocked value of a chapter the source now marks locked.
        await viewModel.performDownloadAction(.download, for: Chapter(key: "locked", chapter: 2)).value
        await viewModel.performDownloadAction(.download, for: Chapter(key: "gone", chapter: 9)).value

        XCTAssertTrue(downloads.downloadRequests.isEmpty)
        XCTAssertEqual(messages.messages, [.downloadRefused, .downloadRefused])
    }

    func testADownloadTappedAfterTheChapterWasQueuedElsewhereDoesNothing() async {
        let downloads = MediaDetailDownloadsFake()
        let messages = MediaDetailMessageSpy()
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads, messages: messages)
        XCTAssertEqual(viewModel.downloadActions(for: chapter("chapter-1")), [.download])

        // Another screen queues it while this row's menu is still open.
        downloads.set(.queued, chapterKey: "chapter-1")
        await viewModel.performDownloadAction(.download, for: chapter("chapter-1")).value

        XCTAssertTrue(downloads.downloadRequests.isEmpty)
        XCTAssertTrue(messages.messages.isEmpty)
    }

    func testALockedChapterWithASavedCopyCanStillDeleteIt() {
        let downloads = MediaDetailDownloadsFake()
        downloads.set(.downloaded, chapterKey: "locked")
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads)

        XCTAssertEqual(viewModel.downloadActions(for: chapter("locked")), [.delete])
    }

    // MARK: - Subjects

    private func chapter(_ key: String) -> Chapter {
        Self.series.chapters?.first { $0.key == key } ?? Chapter(key: key, chapter: 2)
    }

    private func makeViewModel<M: MediaDisplayable>(
        media: M,
        saved: Bool,
        downloads: MediaDetailDownloadsFake,
        messages: MediaDetailMessageSpy = MediaDetailMessageSpy(),
        savedOnly: Bool = false
    ) -> MediaDetailViewModel<M> {
        let state = MediaDetailLibraryState(
            records: saved
                ? [MediaDetailLibraryRecord(itemID: media.key, pluginID: Self.pluginID, mediaKind: media.mediaKind)]
                : [],
            hasCustomCategories: false
        )
        let context = MediaDetailRouteContext<M>(
            loadDetails: savedOnly ? nil : { $0 },
            searchForRelink: nil,
            makeReaderDestination: { _, _ in
                .pages(
                    id: UUID(),
                    content: ReaderContentSource(remote: nil),
                    pluginID: Self.pluginID,
                    entry: .manga(Self.series),
                    chapter: Chapter(key: "chapter-1", chapter: 1)
                )
            }
        )
        var dependencies = PreparedMediaDetailDependencies(
            library: MediaDetailLibraryFake(state: state),
            progress: MediaDetailProgressFake(),
            tracker: MediaDetailTrackerFake(),
            theme: MediaDetailThemeFake(),
            relink: MediaDetailRelinkFake(),
            baseline: MediaDetailBaselineFake(),
            settings: MediaDetailSettingsFake(alwaysShowCategoryPicker: false, autoSyncTrackersToLocal: true),
            pluginMetadata: MediaDetailPluginMetadataFake(),
            discord: MediaDetailDiscordFake()
        )
        dependencies.downloads = downloads
        return MediaDetailViewModel(
            media: media,
            pluginID: Self.pluginID,
            routeContext: context,
            dependencies: dependencies,
            messagePresenter: messages,
            presentationLogger: PresentationEventCaptureSpy()
        )
    }
}

/// Download service double: states keyed by series and chapter, recorded requests, and scripted outcomes.
@MainActor
final class MediaDetailDownloadsFake: MediaDetailDownloadServing {
    struct DownloadRequest: Equatable {
        let media: MediaIdentity
        let entryKey: String
        let entryKind: MediaKind
        let chapterKey: String
        let seriesTitle: String
    }

    enum EditionCall: Equatable {
        case cancel(OfflineChapterEdition)
        case retry(OfflineChapterEdition)
        case delete(OfflineChapterEdition)
    }

    static let series = MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "series-1", mediaKind: .manga)

    let isAvailable: Bool
    var downloadOutcome: DownloadEnqueueOutcome = .queued
    var failure: Error?
    private(set) var downloadRequests: [DownloadRequest] = []
    private(set) var editionCalls: [EditionCall] = []
    private let states = CurrentValueSubject<[MediaIdentity: [String: ChapterDownloadState]], Never>([:])

    init(isAvailable: Bool = true) {
        self.isAvailable = isAvailable
    }

    /// Records a chapter's state as the store would publish it. Nil removes it.
    func set(_ state: ChapterDownloadState?, chapterKey: String, media: MediaIdentity = MediaDetailDownloadsFake.series) {
        var all = states.value
        all[media, default: [:]][chapterKey] = state
        states.send(all)
    }

    func chapterStates(for media: MediaIdentity) -> AnyPublisher<[String: ChapterDownloadState], Never> {
        states.map { $0[media] ?? [:] }.removeDuplicates().eraseToAnyPublisher()
    }

    func download(
        media: MediaIdentity,
        entry: MediaEntry,
        chapter: Chapter,
        seriesTitle: String
    ) async -> DownloadEnqueueOutcome {
        let (entryKey, entryKind): (String, MediaKind) = switch entry {
        case .manga(let manga): (manga.key, .manga)
        case .novel(let novel): (novel.key, .novel)
        case .anime(let anime): (anime.key, .anime)
        }
        downloadRequests.append(DownloadRequest(
            media: media,
            entryKey: entryKey,
            entryKind: entryKind,
            chapterKey: chapter.key,
            seriesTitle: seriesTitle
        ))
        return downloadOutcome
    }

    func cancel(_ edition: OfflineChapterEdition) async throws {
        editionCalls.append(.cancel(edition))
        if let failure { throw failure }
    }

    func retry(_ edition: OfflineChapterEdition) async throws {
        editionCalls.append(.retry(edition))
        if let failure { throw failure }
    }

    func delete(_ edition: OfflineChapterEdition) async throws {
        editionCalls.append(.delete(edition))
        if let failure { throw failure }
    }
}
