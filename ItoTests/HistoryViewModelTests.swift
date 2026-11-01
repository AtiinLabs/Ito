import XCTest
import ito_runner
@testable import Ito

@MainActor
final class HistoryViewModelTests: XCTestCase {
    /// Noon on 2025-06-18 (a Wednesday), UTC.
    private let now = Date(timeIntervalSince1970: 1_750_248_000)
    private let day: TimeInterval = 86_400

    // MARK: - Grouping

    func testSeriesAreGroupedNewestFirstWithOneRowPerChapter() {
        let harness = makeViewModel(history: [
            pr11bHistoryEntry(id: "a3", readAt: 30, media: "a", chapterKey: "c3"),
            pr11bHistoryEntry(id: "b1", readAt: 20, media: "b", chapterKey: "c1"),
            pr11bHistoryEntry(id: "a2", readAt: 10, media: "a", chapterKey: "c2"),
            // An older visit to a chapter already listed adds nothing.
            pr11bHistoryEntry(id: "a3-old", readAt: 5, media: "a", chapterKey: "c3")
        ])

        let series = harness.viewModel.sections.flatMap(\.series)
        XCTAssertEqual(series.map(\.key.mediaKey), ["a", "b"])
        XCTAssertEqual(series[0].chapters.map(\.id), ["a3", "a2"])
        XCTAssertEqual(series[0].earlierChapters.map(\.id), ["a2"])
        XCTAssertEqual(series[1].chapters.map(\.id), ["b1"])
    }

    func testTheSameKeyOfAnotherKindIsAnotherSeries() {
        let harness = makeViewModel(history: [
            pr11bHistoryEntry(id: "manga", readAt: 2, media: "42", kind: .manga),
            pr11bHistoryEntry(id: "novel", readAt: 1, media: "42", kind: .novel)
        ])

        XCTAssertEqual(
            harness.viewModel.sections.flatMap(\.series).map(\.key.mediaKind),
            [.manga, .novel]
        )
    }

    func testSeriesAreSectionedByTheDayTheyWereLastRead() {
        let harness = makeViewModel(history: [
            pr11bHistoryEntry(id: "today", readAt: now.timeIntervalSince1970 - 60, media: "today"),
            pr11bHistoryEntry(id: "yesterday", readAt: now.timeIntervalSince1970 - day, media: "yesterday"),
            pr11bHistoryEntry(id: "yesterday-2", readAt: now.timeIntervalSince1970 - day - 60, media: "yesterday-2"),
            pr11bHistoryEntry(id: "last-week", readAt: now.timeIntervalSince1970 - 9 * day, media: "last-week")
        ])

        let sections = harness.viewModel.sections
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections[0].title, "Today")
        XCTAssertEqual(sections[0].series.map(\.key.mediaKey), ["today"])
        XCTAssertEqual(sections[1].title, "Yesterday")
        XCTAssertEqual(sections[1].series.map(\.key.mediaKey), ["yesterday", "yesterday-2"])
        XCTAssertEqual(sections[2].series.map(\.key.mediaKey), ["last-week"])
        XCTAssertNotEqual(sections[2].title, "Today")
    }

    // MARK: - Search and filter

    func testSearchMatchesTitlesWithoutRegardToCase() {
        let harness = makeViewModel(history: [
            pr11bHistoryEntry(id: "1", readAt: 2, media: "one", title: "Solo Leveling"),
            pr11bHistoryEntry(id: "2", readAt: 1, media: "two", title: "Omniscient Reader")
        ])

        harness.viewModel.searchText = "  solo "
        XCTAssertEqual(harness.viewModel.sections.flatMap(\.series).map(\.title), ["Solo Leveling"])

        harness.viewModel.searchText = "nothing"
        XCTAssertEqual(harness.viewModel.phase, .noResults)
        XCTAssertTrue(harness.viewModel.isClearVisible)

        harness.viewModel.searchText = ""
        XCTAssertEqual(harness.viewModel.phase, .content)
    }

    func testKindFilterIsOfferedOnlyForKindsInHistory() {
        let single = makeViewModel(history: [pr11bHistoryEntry(id: "1", readAt: 1)]).viewModel
        XCTAssertTrue(single.availableKindFilters.isEmpty)

        let mixed = makeViewModel(history: [
            pr11bHistoryEntry(id: "manga", readAt: 2, kind: .manga),
            pr11bHistoryEntry(id: "anime", readAt: 1, kind: .anime)
        ]).viewModel
        XCTAssertEqual(mixed.availableKindFilters, [.all, .manga, .anime])

        mixed.kindFilter = .anime
        XCTAssertEqual(mixed.sections.flatMap(\.series).map(\.key.mediaKind), [.anime])
        mixed.kindFilter = .all
        XCTAssertEqual(mixed.sections.flatMap(\.series).count, 2)
    }

    func testEmptyHistoryHasNoClearButton() {
        let empty = makeViewModel(history: []).viewModel
        XCTAssertEqual(empty.phase, .empty)
        XCTAssertFalse(empty.isClearVisible)
    }

    func testAFilterWhoseKindIsGoneFallsBackToAll() async {
        let novel = pr11bHistoryEntry(id: "novel", readAt: 2, media: "n", kind: .novel)
        let harness = makeViewModel(history: [
            novel,
            pr11bHistoryEntry(id: "manga", readAt: 1, media: "m", kind: .manga)
        ])
        harness.viewModel.kindFilter = .novel

        await harness.viewModel.removeChapter(novel)

        XCTAssertEqual(harness.viewModel.kindFilter, .all)
        XCTAssertEqual(harness.viewModel.phase, .content)
        XCTAssertEqual(harness.viewModel.sections.flatMap(\.series).map(\.key.mediaKey), ["m"])
    }

    // MARK: - Row content

    func testChapterLabelsNameChaptersByTitleOrNumberAndNeverByKey() {
        func label(_ kind: MediaKind, key: String, title: String?, number: Double?) -> String {
            HistoryViewModel.chapterLabel(
                for: pr11bHistoryEntry(
                    id: "x", readAt: 1, kind: kind, chapterKey: key, chapterTitle: .some(title), chapterNumber: number
                ).record
            )
        }

        XCTAssertEqual(label(.manga, key: "k", title: "The Beginning", number: 1), "The Beginning")
        XCTAssertEqual(label(.manga, key: "k", title: nil, number: 12), "Chapter 12")
        XCTAssertEqual(label(.novel, key: "k", title: nil, number: 12.5), "Chapter 12.5")
        // Older rows stored the key as the title when a chapter had none.
        XCTAssertEqual(label(.manga, key: "8f2c91", title: "8f2c91", number: nil), "Unknown Chapter")
        XCTAssertEqual(label(.manga, key: "Chapter 5", title: "Chapter 5", number: nil), "Chapter 5")
        XCTAssertEqual(label(.anime, key: "ep-7", title: nil, number: 7), "Episode 7")
        XCTAssertEqual(label(.anime, key: "ep-7", title: "ep-7", number: nil), "Unknown Episode")
    }

    func testSourceNameIsThePluginNameOrANoteWhenUninstalled() {
        let entry = pr11bHistoryEntry(id: "one", readAt: 1)
        let installed = makeViewModel(sourceNames: ["plugin": "Atsumaru"]).viewModel
        XCTAssertEqual(installed.sourceName(for: entry), "Atsumaru")

        let uninstalled = makeViewModel().viewModel
        XCTAssertEqual(uninstalled.sourceName(for: entry), "Source not installed")
    }

    func testOpeningASavedSeriesUsesItsLibraryItem() throws {
        let entry = pr11bHistoryEntry(id: "1", readAt: 1, media: "saved")
        let harness = makeViewModel(history: [entry])
        let saved = LibraryItem(
            id: "saved", title: "Saved", coverUrl: nil, pluginId: "plugin", isAnime: false,
            pluginType: .manga, rawPayload: Data("{}".utf8), anilistId: 7
        )
        harness.library.items[entry.seriesKey] = saved

        let series = try XCTUnwrap(harness.viewModel.sections.first?.series.first)
        XCTAssertEqual(harness.viewModel.libraryItem(for: series)?.anilistId, 7)
    }

    func testAnUnsavedSeriesOpensAsTheKindItWasReadAs() async throws {
        let harness = makeViewModel(history: [
            pr11bHistoryEntry(id: "manga", readAt: 3, media: "m", kind: .manga, title: "A Manga"),
            pr11bHistoryEntry(id: "novel", readAt: 2, media: "n", kind: .novel, title: "A Novel"),
            pr11bHistoryEntry(id: "anime", readAt: 1, media: "a", kind: .anime, title: "An Anime")
        ])
        let decoder = JSONDeferredPluginPayloadDecoder()
        var decoded: [String] = []
        for series in harness.viewModel.sections.flatMap(\.series) {
            let item = try XCTUnwrap(harness.viewModel.libraryItem(for: series))
            XCTAssertEqual(item.pluginId, "plugin")
            switch try await decoder.decode(item) {
            case .manga(let manga): decoded.append("manga:\(manga.key):\(manga.title)")
            case .novel(let novel): decoded.append("novel:\(novel.key):\(novel.title)")
            case .anime(let anime): decoded.append("anime:\(anime.key):\(anime.title)")
            }
        }
        XCTAssertEqual(decoded, ["manga:m:A Manga", "novel:n:A Novel", "anime:a:An Anime"])
    }

    // MARK: - Removal

    func testRemovingAChapterAwaitsPublicationAndKeepsTheSeriesOtherChapters() async throws {
        let latest = pr11bHistoryEntry(id: "a2", readAt: 2, media: "a", chapterKey: "c2")
        let earlier = pr11bHistoryEntry(id: "a1", readAt: 1, media: "a", chapterKey: "c1")
        let harness = makeViewModel(history: [latest, earlier])
        harness.service.deleteResponses = [.suspended]

        let task = Task { await harness.viewModel.removeChapter(earlier) }
        await waitUntil { harness.service.pendingDeleteCount == 1 }
        let removal = HistoryRemoval.chapter(earlier.seriesKey, chapterKey: "c1")
        XCTAssertTrue(harness.viewModel.isRemoving(removal))
        XCTAssertEqual(harness.viewModel.history.map(\.id), ["a2", "a1"])

        harness.service.resolveDelete(at: 0, result: .success(()))
        await task.value

        XCTAssertEqual(harness.service.deleteRequests, [removal])
        XCTAssertEqual(harness.viewModel.sections.flatMap(\.series).first?.chapters.map(\.id), ["a2"])
        XCTAssertFalse(harness.viewModel.isRemoving(removal))
        XCTAssertEqual(harness.logger.events.last?.outcome, .succeeded)
    }

    func testRemovingASeriesRemovesAllItsChaptersOnly() async {
        let harness = makeViewModel(history: [
            pr11bHistoryEntry(id: "a2", readAt: 3, media: "a", chapterKey: "c2"),
            pr11bHistoryEntry(id: "b1", readAt: 2, media: "b", chapterKey: "c1"),
            pr11bHistoryEntry(id: "a1", readAt: 1, media: "a", chapterKey: "c1")
        ])
        let series = harness.viewModel.sections.flatMap(\.series)[0]

        await harness.viewModel.removeSeries(series)

        XCTAssertEqual(harness.service.deleteRequests, [.series(series.key)])
        XCTAssertEqual(harness.viewModel.history.map(\.id), ["b1"])
    }

    func testRemovalFailureKeepsTheChapterAndCanBeRetried() async {
        let entry = pr11bHistoryEntry(id: "one", readAt: 1)
        let harness = makeViewModel(history: [entry])
        harness.service.deleteResponses = [
            .immediate(.failure(CategoryHistoryTestFailure.expected)),
            .immediate(.success(()))
        ]

        await harness.viewModel.removeChapter(entry)

        XCTAssertEqual(harness.viewModel.history.map(\.id), ["one"])
        XCTAssertEqual(harness.viewModel.failure, .historyDeleteFailed)
        XCTAssertEqual(harness.messages.messages, [.historyDeleteFailed])

        await harness.viewModel.removeChapter(entry)
        XCTAssertEqual(harness.viewModel.phase, .empty)
    }

    func testARepeatedRemovalWaitsForTheFirstWhileOthersProceed() async {
        let one = pr11bHistoryEntry(id: "one", readAt: 2)
        let two = pr11bHistoryEntry(id: "two", readAt: 1)
        let harness = makeViewModel(history: [one, two])
        harness.service.deleteResponses = [.suspended, .immediate(.success(()))]

        let first = Task { await harness.viewModel.removeChapter(one) }
        await waitUntil { harness.service.pendingDeleteCount == 1 }
        await harness.viewModel.removeChapter(one)
        await harness.viewModel.removeChapter(two)

        XCTAssertEqual(harness.service.deleteRequests.count, 2)
        XCTAssertEqual(harness.viewModel.history.map(\.id), ["one"])

        harness.service.resolveDelete(at: 0, result: .success(()))
        await first.value
        XCTAssertTrue(harness.viewModel.history.isEmpty)
    }

    func testRemovalOfSomethingNotInHistoryWritesNothing() async {
        let harness = makeViewModel()

        await harness.viewModel.removeChapter(pr11bHistoryEntry(id: "missing", readAt: 1))
        await harness.viewModel.clearHistory()

        XCTAssertTrue(harness.service.deleteRequests.isEmpty)
        XCTAssertEqual(harness.service.clearRequestCount, 0)
    }

    func testClearRequiresConfirmationBeforeWriting() async {
        let harness = makeViewModel(history: [pr11bHistoryEntry(id: "one", readAt: 1)])

        harness.viewModel.requestClear()
        XCTAssertTrue(harness.viewModel.isClearConfirmationPresented)
        harness.viewModel.cancelClear()
        XCTAssertEqual(harness.service.clearRequestCount, 0)
        XCTAssertEqual(harness.viewModel.phase, .content)

        harness.viewModel.requestClear()
        await harness.viewModel.confirmClear()

        XCTAssertFalse(harness.viewModel.isClearConfirmationPresented)
        XCTAssertEqual(harness.service.clearRequestCount, 1)
        XCTAssertEqual(harness.viewModel.phase, .empty)
    }

    func testClearFailureKeepsHistoryAndIgnoresADuplicateClear() async {
        let harness = makeViewModel(history: [pr11bHistoryEntry(id: "one", readAt: 1)])
        harness.service.clearResponses = [.suspended, .immediate(.success(()))]

        let first = Task { await harness.viewModel.clearHistory() }
        await waitUntil { harness.service.pendingClearCount == 1 }
        await harness.viewModel.clearHistory()
        XCTAssertEqual(harness.service.clearRequestCount, 1)

        harness.service.resolveClear(at: 0, result: .failure(CategoryHistoryTestFailure.expected))
        await first.value

        XCTAssertEqual(harness.viewModel.history.map(\.id), ["one"])
        XCTAssertEqual(harness.viewModel.failure, .historyClearFailed)
        XCTAssertFalse(harness.viewModel.isClearing)

        await harness.viewModel.clearHistory()
        XCTAssertTrue(harness.viewModel.history.isEmpty)
    }

    func testRemovalCleanupKeepsANewerPublication() async {
        let one = pr11bHistoryEntry(id: "one", readAt: 2)
        let two = pr11bHistoryEntry(id: "two", readAt: 1)
        let newer = pr11bHistoryEntry(id: "newer", readAt: 3)
        let harness = makeViewModel(history: [one, two])
        harness.service.deleteResponses = [.suspended]

        let task = Task { await harness.viewModel.removeChapter(one) }
        await waitUntil { harness.service.pendingDeleteCount == 1 }
        harness.service.publish([newer, one, two])
        harness.service.resolveDelete(at: 0, result: .success(()))
        await task.value

        XCTAssertEqual(harness.viewModel.history.map(\.id), ["newer", "two"])
    }

    // MARK: - Fixture

    private func makeViewModel(
        history: [HistoryEntry] = [],
        sourceNames: [String: String] = [:]
    ) -> (
        viewModel: HistoryViewModel,
        service: HistoryServiceFake,
        library: HistoryLibraryLookupFake,
        messages: CategoryHistoryMessageSpy,
        logger: CategoryHistoryPresentationLogSpy
    ) {
        let service = HistoryServiceFake(history: history)
        let library = HistoryLibraryLookupFake()
        let messages = CategoryHistoryMessageSpy()
        let logger = CategoryHistoryPresentationLogSpy()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = now
        return (
            HistoryViewModel(
                historyService: service,
                sourceNames: HistorySourceNamesFake(names: sourceNames),
                progress: HistoryProgressFake(),
                libraryLookup: library,
                messagePresenter: messages,
                presentationLogger: logger,
                calendar: calendar,
                now: { now }
            ),
            service,
            library,
            messages,
            logger
        )
    }
}
