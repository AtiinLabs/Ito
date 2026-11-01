import XCTest
import ito_runner
@testable import Ito

/// A detail screen opened from History opens the reader once its chapter list has loaded.
@MainActor
final class MediaDetailOpenIntentTests: XCTestCase {
    private let chapters = [
        Manga.Chapter(key: "one", title: "One", chapter: 1),
        Manga.Chapter(key: "two", title: "Two", chapter: 2)
    ]

    func testResumeIntentOpensTheResumeChapterOnceDetailsLoad() async {
        let subject = makeSubject(openIntent: .resume)
        subject.progress.readChapterIDs[subject.viewModel.mediaIdentity] = ["one"]
        subject.route.loadResponses = [.value(manga(chapters: chapters)), .value(manga(chapters: chapters))]

        await subject.viewModel.refresh()
        XCTAssertEqual(openedChapter(subject.viewModel), "two")

        // The intent applies once: coming back and refreshing stays on the series.
        subject.viewModel.dismissReader()
        await subject.viewModel.refresh()
        XCTAssertNil(subject.viewModel.readerDestination)
    }

    func testChapterIntentOpensThatChapterOrNothingIfItIsGone() async {
        let present = makeSubject(openIntent: .chapter(key: "one"))
        present.route.loadResponses = [.value(manga(chapters: chapters))]
        await present.viewModel.refresh()
        XCTAssertEqual(openedChapter(present.viewModel), "one")

        let missing = makeSubject(openIntent: .chapter(key: "removed"))
        missing.route.loadResponses = [.value(manga(chapters: chapters))]
        await missing.viewModel.refresh()
        XCTAssertNil(missing.viewModel.readerDestination)
    }

    func testAFailedLoadDropsTheIntentSoARetryStaysOnTheSeries() async {
        let subject = makeSubject(openIntent: .chapter(key: "one"))
        subject.route.loadResponses = [.failure, .value(manga(chapters: chapters))]

        await subject.viewModel.refresh()
        XCTAssertNotEqual(subject.viewModel.detailLoadState, .content)
        await subject.viewModel.refresh()
        XCTAssertEqual(subject.viewModel.detailLoadState, .content)

        XCTAssertNil(subject.viewModel.readerDestination)
    }

    func testNoIntentOpensNothing() async {
        let subject = makeSubject(openIntent: nil)
        subject.route.loadResponses = [.value(manga(chapters: chapters))]

        await subject.viewModel.refresh()

        XCTAssertNil(subject.viewModel.readerDestination)
    }

    // MARK: - Fixture

    private struct Subject {
        let viewModel: MediaDetailViewModel<Manga>
        let route: MediaRouteHarness<Manga>
        let progress: MediaDetailProgressFake
    }

    private func makeSubject(openIntent: MediaDetailOpenIntent?) -> Subject {
        let route = MediaRouteHarness<Manga>()
        let progress = MediaDetailProgressFake()
        let runner = ItoRunner()
        let viewModel = MediaDetailViewModel(
            media: manga(chapters: []),
            pluginID: "plugin.test",
            routeContext: MediaDetailRouteContext<Manga>(
                loadDetails: { try await route.load($0) },
                searchForRelink: { _ in [] },
                makeReaderDestination: { parent, selected in
                    .pages(id: UUID(), runner: runner, pluginID: "plugin.test", entry: .manga(parent), chapter: selected)
                }
            ),
            dependencies: PreparedMediaDetailDependencies(
                library: MediaDetailLibraryFake(),
                progress: progress,
                tracker: MediaDetailTrackerFake(),
                theme: MediaDetailThemeFake(),
                relink: MediaDetailRelinkFake(),
                baseline: MediaDetailBaselineFake(),
                settings: MediaDetailSettingsFake(),
                pluginMetadata: MediaDetailPluginMetadataFake(),
                discord: MediaDetailDiscordFake()
            ),
            messagePresenter: MediaDetailMessageSpy(),
            presentationLogger: PresentationEventCaptureSpy(),
            openIntent: openIntent
        )
        return Subject(viewModel: viewModel, route: route, progress: progress)
    }

    private func manga(chapters: [Manga.Chapter]) -> Manga {
        Manga(key: "m1", title: "Manga", chapters: chapters)
    }

    private func openedChapter(_ viewModel: MediaDetailViewModel<Manga>) -> String? {
        guard case .pages(_, _, _, _, let chapter) = viewModel.readerDestination else { return nil }
        return chapter.key
    }
}
