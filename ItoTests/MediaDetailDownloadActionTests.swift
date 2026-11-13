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
            (.downloaded, [.readOnlineThisTime, .delete]),
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
        XCTAssertEqual(viewModel.downloadActions(for: chapter("chapter-1")), [.readOnlineThisTime, .delete])
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

    func testADownloadedChapterOffersReadOnlineThisTimeOnlyWhereASourceExistsAndTheChapterIsUnlocked() {
        let downloads = MediaDetailDownloadsFake()
        downloads.set(.downloaded, chapterKey: "chapter-1")
        downloads.set(.downloaded, chapterKey: "locked")
        downloads.set(.damaged, chapterKey: "damaged")
        let withSource = makeViewModel(media: Self.series, saved: true, downloads: downloads)
        let savedOnly = makeViewModel(media: Self.series, saved: true, downloads: downloads, savedOnly: true)
        savedOnly.start()

        XCTAssertEqual(withSource.downloadActions(for: chapter("chapter-1")), [.readOnlineThisTime, .delete])
        XCTAssertEqual(withSource.downloadActions(for: chapter("locked")), [.delete])
        XCTAssertEqual(withSource.downloadActions(for: chapter("damaged")), [.delete])
        XCTAssertEqual(savedOnly.detailLoadState, .savedOnly)
        XCTAssertEqual(savedOnly.downloadActions(for: chapter("chapter-1")), [.delete])
    }

    func testReadOnlineThisTimeOpensTheReaderForThatChapterOnlyAndChangesNothingStored() {
        let downloads = MediaDetailDownloadsFake()
        downloads.set(.downloaded, chapterKey: "chapter-1")
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads)

        viewModel.performDownloadAction(.readOnlineThisTime, for: chapter("chapter-1"))

        guard case .pages(_, let content, _, _, let opened)? = viewModel.readerDestination else {
            return XCTFail("The page reader opens")
        }
        XCTAssertEqual(content.preference, .remoteThisTime(chapterKey: "chapter-1"))
        XCTAssertEqual(opened.key, "chapter-1")
        XCTAssertTrue(downloads.downloadRequests.isEmpty)
        XCTAssertTrue(downloads.editionCalls.isEmpty)
        XCTAssertEqual(viewModel.downloadState(for: chapter("chapter-1")), .downloaded)

        // Opening the chapter afterwards reads the downloaded copy again.
        viewModel.dismissReader()
        viewModel.selectChapter(chapter("chapter-1"))
        guard case .pages(_, let reopened, _, _, _)? = viewModel.readerDestination else {
            return XCTFail("The page reader opens")
        }
        XCTAssertEqual(reopened.preference, .localFirst)
    }

    func testReadOnlineThisTimeDoesNothingWhereItIsNotOffered() {
        let downloads = MediaDetailDownloadsFake()
        downloads.set(.downloaded, chapterKey: "chapter-1")
        downloads.set(.downloaded, chapterKey: "locked")
        let withSource = makeViewModel(media: Self.series, saved: true, downloads: downloads)
        let savedOnly = makeViewModel(media: Self.series, saved: true, downloads: downloads, savedOnly: true)
        savedOnly.start()

        withSource.performDownloadAction(.readOnlineThisTime, for: chapter("locked"))
        savedOnly.performDownloadAction(.readOnlineThisTime, for: chapter("chapter-1"))

        XCTAssertNil(withSource.readerDestination)
        XCTAssertNil(savedOnly.readerDestination)
    }

    /// A chapter another edition's read mark covers by number is still an edition of its own: the explicit
    /// Download is offered and queues exactly that edition. Presets skip it; this action never reads progress.
    func testASingleDownloadIsStillOfferedForAnEditionWhoseNumberAnotherEditionMarkedRead() async {
        let series = Manga(
            key: "series-1",
            title: "Series One",
            chapters: [
                Chapter(key: "a16", chapter: 16, scanlator: "A"),
                Chapter(key: "b16", chapter: 16, scanlator: "B")
            ]
        )
        let progress = MediaDetailProgressFake()
        progress.readChapterIDs[MediaDetailDownloadsFake.series] = ["b16"]
        progress.readChapterNumbers[MediaDetailDownloadsFake.series] = [16]
        let downloads = MediaDetailDownloadsFake()
        let viewModel = makeViewModel(media: series, saved: true, downloads: downloads, progress: progress)
        let aSixteen = Chapter(key: "a16", chapter: 16, scanlator: "A")

        XCTAssertTrue(viewModel.isRead(aSixteen), "The list shows a16 read, by number")
        XCTAssertEqual(viewModel.downloadActions(for: aSixteen), [.download])

        await viewModel.performDownloadAction(.download, for: aSixteen).value

        XCTAssertEqual(downloads.downloadRequests.map(\.chapterKey), ["a16"])
    }

    // MARK: - Metered prompt

    func testASingleChapterInAskModeWaitsForTheForegroundPrompt() async {
        let downloads = MediaDetailDownloadsFake()
        downloads.meteredConfirmationNeeded = true
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads)

        await viewModel.performDownloadAction(.download, for: chapter("chapter-1")).value

        XCTAssertNotNil(viewModel.downloadBatch.meteredPrompt)
        XCTAssertTrue(downloads.downloadRequests.isEmpty)
        XCTAssertTrue(downloads.batchRequests.isEmpty)
    }

    func testUseMeteredDataQueuesTheSingleChapterWithConsent() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.meteredConfirmationNeeded = true
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads)
        await viewModel.performDownloadAction(.download, for: chapter("chapter-1")).value
        let prompt = try XCTUnwrap(viewModel.downloadBatch.meteredPrompt)

        await viewModel.downloadBatch.resolveMeteredPrompt(prompt.id, useMeteredData: true).value

        XCTAssertNil(viewModel.downloadBatch.meteredPrompt)
        XCTAssertEqual(downloads.batchRequests.map { $0.chapters.map(\.key) }, [["chapter-1"]])
        XCTAssertEqual(downloads.batchRequests.first?.preset, .single)
        XCTAssertEqual(downloads.confirmedMeteredUses, [true])
    }

    func testQueueAndWaitQueuesTheSingleChapterWithoutConsent() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.meteredConfirmationNeeded = true
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads)
        await viewModel.performDownloadAction(.download, for: chapter("chapter-1")).value
        let prompt = try XCTUnwrap(viewModel.downloadBatch.meteredPrompt)

        await viewModel.downloadBatch.resolveMeteredPrompt(prompt.id, useMeteredData: false).value

        XCTAssertEqual(downloads.batchRequests.count, 1)
        XCTAssertEqual(downloads.confirmedMeteredUses, [false])
    }

    func testDismissingThePromptQueuesNothing() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.meteredConfirmationNeeded = true
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads)
        await viewModel.performDownloadAction(.download, for: chapter("chapter-1")).value
        let prompt = try XCTUnwrap(viewModel.downloadBatch.meteredPrompt)

        viewModel.downloadBatch.dismissMeteredPrompt()
        await viewModel.downloadBatch.resolveMeteredPrompt(prompt.id, useMeteredData: true).value

        XCTAssertNil(viewModel.downloadBatch.meteredPrompt)
        XCTAssertTrue(downloads.batchRequests.isEmpty)
    }

    func testAStalePromptAnswerAfterResetQueuesNothing() async throws {
        let downloads = MediaDetailDownloadsFake()
        downloads.meteredConfirmationNeeded = true
        let viewModel = makeViewModel(media: Self.series, saved: true, downloads: downloads)
        await viewModel.performDownloadAction(.download, for: chapter("chapter-1")).value
        let prompt = try XCTUnwrap(viewModel.downloadBatch.meteredPrompt)

        viewModel.downloadBatch.reset()
        XCTAssertNil(viewModel.downloadBatch.meteredPrompt)
        await viewModel.downloadBatch.resolveMeteredPrompt(prompt.id, useMeteredData: true).value

        XCTAssertTrue(downloads.batchRequests.isEmpty)
    }

    func testAPreviewConfirmedInAskModeShowsThePromptOnlyAfterItsSheetDismisses() async throws {
        let chapters = (1...12).map { Chapter(key: "c\($0)", chapter: Double($0)) }
        let series = Manga(key: "series-1", title: "Series One", chapters: chapters)
        let downloads = MediaDetailDownloadsFake()
        downloads.meteredConfirmationNeeded = true
        let viewModel = makeViewModel(media: series, saved: true, downloads: downloads)

        await viewModel.downloadBatch.startDownload(.all).value
        guard case .preview(let preview)? = viewModel.downloadBatch.sheet else {
            return XCTFail("All of twelve chapters is previewed before it is queued")
        }
        await viewModel.downloadBatch.confirmDownloadPreview(previewID: preview.id).value

        // The sheet is still dismissing: a dialog presented now would not be shown.
        XCTAssertNil(viewModel.downloadBatch.meteredPrompt)
        viewModel.downloadBatch.downloadSheetDidDismiss()
        let prompt = try XCTUnwrap(viewModel.downloadBatch.meteredPrompt)
        await viewModel.downloadBatch.resolveMeteredPrompt(prompt.id, useMeteredData: false).value

        XCTAssertEqual(downloads.confirmedMeteredUses, [false])
        XCTAssertEqual(downloads.batchRequests.first?.chapters.count, 12)
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
        savedOnly: Bool = false,
        progress: MediaDetailProgressFake = MediaDetailProgressFake()
    ) -> MediaDetailViewModel<M> {
        let state = MediaDetailLibraryState(
            records: saved
                ? [MediaDetailLibraryRecord(itemID: media.key, pluginID: Self.pluginID, mediaKind: media.mediaKind)]
                : [],
            hasCustomCategories: false
        )
        let context = MediaDetailRouteContext<M>(
            loadDetails: savedOnly ? nil : { media, _ in media },
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
            progress: progress,
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
    /// What `enqueueBatch` answers; nil queues every requested chapter.
    var batchOutcome: DownloadBatchOutcome?
    var preferenceWriteFailure: Error?
    var preferenceReadFailure: Error?
    var capacity: Int64?
    var storedBytes: Int64?
    /// While set, the call waits until the test releases it, so a test can act in between.
    var holdsPreferenceReads = false
    var holdsPreferenceWrites = false
    var holdsBatches = false
    private(set) var batchRequests: [DownloadBatchRequest] = []
    /// Whether queueing would use an expensive path the user must confirm first.
    var meteredConfirmationNeeded = false
    private(set) var confirmedMeteredUses: [Bool] = []
    private(set) var storedPreferences: [MediaIdentity: EditionSelection] = [:]
    private(set) var preferenceReadCount = 0
    private(set) var preferenceWriteCount = 0
    private var pendingPreferenceReads: [CheckedContinuation<Void, Never>] = []
    private var pendingPreferenceWrites: [CheckedContinuation<Void, Never>] = []
    private var pendingBatches: [CheckedContinuation<Void, Never>] = []
    private var pendingBatchObservers: [UUID: (count: Int, continuation: CheckedContinuation<Void, any Error>)] = [:]
    private var pendingPreferenceWriteObservers: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var pendingPreferenceReadCount: Int { pendingPreferenceReads.count }
    var pendingPreferenceWriteCount: Int { pendingPreferenceWrites.count }
    var pendingBatchCount: Int { pendingBatches.count }
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
    func seedPreference(_ selection: EditionSelection, for media: MediaIdentity) {
        storedPreferences[media] = selection
    }
    /// What the store does when a series leaves the library: its remembered choice is forgotten.
    func forgetPreference(for media: MediaIdentity) {
        storedPreferences[media] = nil
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

    func meteredUseNeedsConfirmation() -> Bool { meteredConfirmationNeeded }

    func enqueueBatch(_ request: DownloadBatchRequest, confirmedMeteredUse: Bool = false) async -> DownloadBatchOutcome {
        batchRequests.append(request)
        confirmedMeteredUses.append(confirmedMeteredUse)
        if holdsBatches {
            await withCheckedContinuation { continuation in
                pendingBatches.append(continuation)
                let arrived = pendingBatches.count
                let ready = pendingBatchObservers.filter { $0.value.count <= arrived }
                ready.keys.forEach { pendingBatchObservers.removeValue(forKey: $0) }
                ready.values.forEach { $0.continuation.resume() }
            }
        }
        return batchOutcome ?? DownloadBatchOutcome(queued: request.chapters.count)
    }

    func editionPreference(for media: MediaIdentity) async throws -> EditionSelection? {
        preferenceReadCount += 1
        if holdsPreferenceReads { await withCheckedContinuation { pendingPreferenceReads.append($0) } }
        if let preferenceReadFailure { throw preferenceReadFailure }
        return storedPreferences[media]
    }

    func setEditionPreference(_ selection: EditionSelection, for media: MediaIdentity) async throws {
        preferenceWriteCount += 1
        if holdsPreferenceWrites {
            await withCheckedContinuation { continuation in
                pendingPreferenceWrites.append(continuation)
                let observers = Array(pendingPreferenceWriteObservers.values)
                pendingPreferenceWriteObservers.removeAll()
                observers.forEach { $0.resume() }
            }
        }
        if let preferenceWriteFailure { throw preferenceWriteFailure }
        storedPreferences[media] = selection
    }

    func availableCapacity() async -> Int64? {
        capacity
    }

    func storedByteCount(for media: MediaIdentity) async -> Int64? {
        storedBytes
    }

    func releasePreferenceReads() {
        let pending = pendingPreferenceReads
        pendingPreferenceReads = []
        pending.forEach { $0.resume() }
    }

    func releasePreferenceWrites() {
        let pending = pendingPreferenceWrites
        pendingPreferenceWrites = []
        pending.forEach { $0.resume() }
        let observers = Array(pendingPreferenceWriteObservers.values)
        pendingPreferenceWriteObservers.removeAll()
        observers.forEach { $0.resume(throwing: CancellationError()) }
    }
    func waitForPendingPreferenceWrite() async throws {
        guard pendingPreferenceWrites.isEmpty else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if !pendingPreferenceWrites.isEmpty {
                    continuation.resume()
                } else {
                    pendingPreferenceWriteObservers[waiterID] = continuation
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancelPreferenceWriteObserver(waiterID) }
        }
    }

    private func cancelPreferenceWriteObserver(_ id: UUID) {
        pendingPreferenceWriteObservers.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Releases every held batch, and fails any waiter that has not seen one arrive.
    func releaseBatches() {
        let pending = pendingBatches
        pendingBatches = []
        pending.forEach { $0.resume() }
        let observers = Array(pendingBatchObservers.values)
        pendingBatchObservers.removeAll()
        observers.forEach { $0.continuation.resume(throwing: CancellationError()) }
    }

    /// Releases only the earliest held batch, so a test can finish one submission while another is still held.
    func releaseOldestBatch() {
        guard !pendingBatches.isEmpty else { return }
        pendingBatches.removeFirst().resume()
    }

    /// Returns once `count` batches are held; cancellation of the waiting task removes its observer.
    func waitForPendingBatch(count: Int = 1) async throws {
        guard pendingBatches.count < count else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if pendingBatches.count >= count {
                    continuation.resume()
                } else {
                    pendingBatchObservers[waiterID] = (count, continuation)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancelBatchObserver(waiterID) }
        }
    }

    private func cancelBatchObserver(_ id: UUID) {
        pendingBatchObservers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}
