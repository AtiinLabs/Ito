import XCTest
import ito_runner
@testable import Ito

/// The saved-only series route: no installed source, so nothing is refreshed, the baseline never advances,
/// and only chapters with a verified offline copy open.
@MainActor
final class MediaDetailSavedOnlyTests: XCTestCase {
    private static let pluginID = "plugin.test"

    private struct Subject {
        let viewModel: MediaDetailViewModel<Manga>
        let baseline: MediaDetailBaselineFake
        let messages: MediaDetailMessageSpy
    }

    func testSavedOnlyRouteShowsTheSeriesWithoutAdvancingTheBaselineOrRefreshing() {
        let subject = makeSubject(saved: true, offlineChapterKeys: [])

        subject.viewModel.start()

        XCTAssertEqual(subject.viewModel.detailLoadState, .savedOnly)
        XCTAssertTrue(subject.baseline.requests.isEmpty)
        XCTAssertEqual(subject.baseline.refreshCount, 0)
        XCTAssertFalse(subject.viewModel.canRelink)
        XCTAssertTrue(subject.messages.messages.isEmpty)
    }

    func testATappedChapterWithAnOfflineCopyOpensTheReaderWithoutARemoteSource() async {
        let subject = makeSubject(saved: true, offlineChapterKeys: ["chapter-1"])
        subject.viewModel.start()
        subject.viewModel.appear()

        subject.viewModel.selectChapter(Chapter(key: "chapter-1", chapter: 1))

        await waitUntil { subject.viewModel.readerDestination != nil }
        guard case .pages(_, let content, _, _, let chapter)? = subject.viewModel.readerDestination else {
            return XCTFail("A downloaded page chapter opens the page reader")
        }
        XCTAssertNil(content.remote)
        XCTAssertEqual(chapter.key, "chapter-1")
        XCTAssertTrue(subject.messages.messages.isEmpty)
    }

    func testATappedChapterWithoutAnOfflineCopyPresentsNotDownloadedInsteadOfReading() async {
        let subject = makeSubject(saved: true, offlineChapterKeys: ["chapter-1"])
        subject.viewModel.start()
        subject.viewModel.appear()

        subject.viewModel.selectChapter(Chapter(key: "chapter-2", chapter: 2))

        await waitUntil { !subject.messages.messages.isEmpty }
        XCTAssertEqual(subject.messages.messages, [.chapterNotDownloaded])
        XCTAssertNil(subject.viewModel.readerDestination)
    }

    func testASecondTapWhileACopyCheckIsRunningDoesNothing() async {
        let gate = AvailabilityGate()
        let subject = makeSubject(saved: true, availability: { _ in await gate.check() })
        subject.viewModel.start()
        subject.viewModel.appear()

        subject.viewModel.selectChapter(Chapter(key: "chapter-1", chapter: 1))
        await waitUntil { gate.isWaiting }
        subject.viewModel.selectChapter(Chapter(key: "chapter-1", chapter: 1))
        gate.answer(true)
        await waitUntil { subject.viewModel.readerDestination != nil }

        XCTAssertEqual(gate.checkCount, 1)
        XCTAssertTrue(subject.messages.messages.isEmpty)
    }

    func testDismissingTheScreenCancelsAPendingCopyCheck() async {
        let gate = AvailabilityGate()
        let subject = makeSubject(saved: true, availability: { _ in await gate.check() })
        subject.viewModel.start()
        subject.viewModel.appear()

        subject.viewModel.selectChapter(Chapter(key: "chapter-1", chapter: 1))
        await waitUntil { gate.isWaiting }
        subject.viewModel.cancelScreenOperations()
        gate.answer(true)
        await Task.yield()

        XCTAssertNil(subject.viewModel.readerDestination)
        XCTAssertTrue(subject.messages.messages.isEmpty)

        // A new tap starts a fresh check after the cancelled one.
        subject.viewModel.selectChapter(Chapter(key: "chapter-1", chapter: 1))
        await waitUntil { gate.isWaiting }
        XCTAssertEqual(gate.checkCount, 2)
        gate.answer(true)
        await waitUntil { subject.viewModel.readerDestination != nil }
    }

    private func makeSubject(saved: Bool, offlineChapterKeys: Set<String>) -> Subject {
        makeSubject(saved: saved, availability: { chapter in offlineChapterKeys.contains(chapter.key) })
    }

    private func makeSubject(saved: Bool, availability: @escaping (Chapter) async -> Bool) -> Subject {
        let media = Manga(
            key: "series-1",
            title: "Series",
            chapters: [Chapter(key: "chapter-1", chapter: 1), Chapter(key: "chapter-2", chapter: 2)]
        )
        let state = MediaDetailLibraryState(
            records: saved
                ? [MediaDetailLibraryRecord(itemID: media.key, pluginID: Self.pluginID, mediaKind: .manga)]
                : [],
            hasCustomCategories: false
        )
        let baseline = MediaDetailBaselineFake()
        let messages = MediaDetailMessageSpy()
        let context = MediaDetailRouteContext<Manga>(
            loadDetails: nil,
            searchForRelink: nil,
            makeReaderDestination: { parent, selected in
                .pages(
                    id: UUID(),
                    content: ReaderContentSource(remote: nil),
                    pluginID: Self.pluginID,
                    entry: .manga(parent),
                    chapter: selected
                )
            },
            isChapterAvailableOffline: availability
        )
        let viewModel = MediaDetailViewModel(
            media: media,
            pluginID: Self.pluginID,
            routeContext: context,
            dependencies: PreparedMediaDetailDependencies(
                library: MediaDetailLibraryFake(state: state),
                progress: MediaDetailProgressFake(),
                tracker: MediaDetailTrackerFake(),
                theme: MediaDetailThemeFake(),
                relink: MediaDetailRelinkFake(),
                baseline: baseline,
                settings: MediaDetailSettingsFake(
                    alwaysShowCategoryPicker: false,
                    autoSyncTrackersToLocal: true
                ),
                pluginMetadata: MediaDetailPluginMetadataFake(),
                discord: MediaDetailDiscordFake()
            ),
            messagePresenter: messages,
            presentationLogger: PresentationEventCaptureSpy()
        )
        return Subject(viewModel: viewModel, baseline: baseline, messages: messages)
    }
}

/// Holds each copy check until the test answers it, so overlapping taps are deterministic.
@MainActor
private final class AvailabilityGate {
    private(set) var checkCount = 0
    private var continuation: CheckedContinuation<Bool, Never>?

    var isWaiting: Bool { continuation != nil }

    func check() async -> Bool {
        checkCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func answer(_ available: Bool) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: available)
    }
}
