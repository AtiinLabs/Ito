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

    /// Two groups release chapters 1 to 3.
    private let groupChapters = [
        Manga.Chapter(key: "a1", chapter: 1, scanlator: "Group A"),
        Manga.Chapter(key: "b1", chapter: 1, scanlator: "Group B"),
        Manga.Chapter(key: "a2", chapter: 2, scanlator: "Group A"),
        Manga.Chapter(key: "b2", chapter: 2, scanlator: "Group B"),
        Manga.Chapter(key: "a3", chapter: 3, scanlator: "Group A"),
        Manga.Chapter(key: "b3", chapter: 3, scanlator: "Group B")
    ]

    func testResumeIntentOpensTheResumeChapterOnceDetailsLoad() async {
        let subject = makeSubject(openIntent: .resume(preferredScanlator: nil))
        subject.progress.readChapterIDs[subject.viewModel.mediaIdentity] = ["one"]
        subject.route.loadResponses = [.value(manga(chapters: chapters)), .value(manga(chapters: chapters))]

        await subject.viewModel.refresh()
        XCTAssertEqual(openedChapter(subject.viewModel), "two")

        // The intent applies once: coming back and refreshing stays on the series.
        subject.viewModel.dismissReader()
        await subject.viewModel.refresh()
        XCTAssertNil(subject.viewModel.readerDestination)
    }

    func testResumeContinuesWithTheGroupOfTheChapterReadLast() async {
        let subject = makeSubject(openIntent: nil)
        let media = subject.viewModel.mediaIdentity
        subject.progress.readChapterIDs[media] = ["b1"]
        subject.progress.readChapterNumbers[media] = [1]
        subject.progress.lastRead[media] = "b1"
        subject.route.loadResponses = [.value(manga(chapters: groupChapters))]

        await subject.viewModel.refresh()

        XCTAssertEqual(subject.viewModel.resumeChapter?.key, "b2")
    }

    func testHistoryNamesTheGroupWhenTheLastChapterIsNoLongerListed() async {
        // Read on another source: the saved chapter key is not in this list.
        let subject = makeSubject(openIntent: .resume(preferredScanlator: "Group B"))
        let media = subject.viewModel.mediaIdentity
        subject.progress.readChapterNumbers[media] = [1]
        subject.progress.lastRead[media] = "elsewhere"
        subject.route.loadResponses = [.value(manga(chapters: groupChapters))]

        await subject.viewModel.refresh()

        XCTAssertEqual(openedChapter(subject.viewModel), "b2")
        XCTAssertEqual(subject.viewModel.resumeChapter?.key, "b2")
    }

    func testAGroupWithoutTheNextChapterFallsBackToAnotherGroup() async {
        let subject = makeSubject(openIntent: .resume(preferredScanlator: "Group C"))
        subject.progress.readChapterNumbers[subject.viewModel.mediaIdentity] = [1]
        subject.route.loadResponses = [.value(manga(chapters: groupChapters))]

        await subject.viewModel.refresh()

        XCTAssertEqual(openedChapter(subject.viewModel), "a2")
    }

    func testChapterIntentOpensThatChapterByKey() async {
        let subject = makeSubject(openIntent: .chapter(reference(key: "b2", number: 2, scanlator: "Group B")))
        subject.route.loadResponses = [.value(manga(chapters: groupChapters))]

        await subject.viewModel.refresh()

        XCTAssertEqual(openedChapter(subject.viewModel), "b2")
    }

    func testARelistedChapterIsFoundByNumberAndGroup() async {
        let sameGroup = makeSubject(openIntent: .chapter(reference(key: "old-key", number: 2, scanlator: "Group B")))
        sameGroup.route.loadResponses = [.value(manga(chapters: groupChapters))]
        await sameGroup.viewModel.refresh()
        XCTAssertEqual(openedChapter(sameGroup.viewModel), "b2")

        let goneGroup = makeSubject(openIntent: .chapter(reference(key: "old-key", number: 2, scanlator: "Group C")))
        goneGroup.route.loadResponses = [.value(manga(chapters: groupChapters))]
        await goneGroup.viewModel.refresh()
        XCTAssertEqual(openedChapter(goneGroup.viewModel), "a2")
        XCTAssertTrue(goneGroup.messages.messages.isEmpty)
    }

    func testAVolumeTellsApartChaptersThatRestartEachVolume() async {
        let volumes = [
            Manga.Chapter(key: "v1c1", volume: 1, chapter: 1),
            Manga.Chapter(key: "v2c1", volume: 2, chapter: 1)
        ]
        let subject = makeSubject(
            openIntent: .chapter(MediaDetailChapterReference(key: "old", number: 1, volume: 2, scanlator: nil))
        )
        subject.route.loadResponses = [.value(manga(chapters: volumes))]

        await subject.viewModel.refresh()

        XCTAssertEqual(openedChapter(subject.viewModel), "v2c1")
    }

    func testReplacementDoesNotGuessBetweenVolumes() {
        let repeated = [
            Manga.Chapter(key: "unknown", chapter: 1),
            Manga.Chapter(key: "v1", volume: 1, chapter: 1),
            Manga.Chapter(key: "v2", volume: 2, chapter: 1)
        ]
        let legacy = MediaDetailChapterReference(key: "gone", number: 1, volume: nil, scanlator: nil)
        XCTAssertNil(repeated.chapter(matching: legacy))
        let specific = MediaDetailChapterReference(key: "gone", number: 1, volume: 2, scanlator: nil)
        XCTAssertEqual(repeated.chapter(matching: specific)?.key, "v2")
        let absent = MediaDetailChapterReference(key: "gone", number: 1, volume: 3, scanlator: nil)
        XCTAssertNil(repeated.chapter(matching: absent))
        // Sources that omit all volumes can still replace a re-uploaded chapter.
        XCTAssertEqual([repeated[0]].chapter(matching: specific)?.key, "unknown")
    }

    func testHistoryContinueDoesNotRestartACompletedSeriesDuringRereading() async {
        let subject = makeSubject(openIntent: .resume(preferredScanlator: nil))
        let identity = subject.viewModel.mediaIdentity
        subject.progress.readChapterNumbers[identity] = [1, 2]
        subject.progress.lastRead[identity] = "two"
        subject.route.loadResponses = [.value(manga(chapters: chapters, status: .Completed))]

        await subject.viewModel.refresh()

        XCTAssertEqual(openedChapter(subject.viewModel), "two")
        XCTAssertEqual(subject.viewModel.resumeChapter?.key, "one")
        XCTAssertTrue(subject.viewModel.isResumeRereading)
        let target = MediaDetailResumeTarget(
            chapters: chapters, lastReadKey: "two", fallbackGroup: nil, isCompleted: true, isRead: { _ in true }
        )
        XCTAssertEqual(target?.continuationChapter.key, "two")
    }

    func testAChapterTheSourceNoLongerListsSaysSoAndStaysOnTheSeries() async {
        let subject = makeSubject(openIntent: .chapter(reference(key: "removed", number: 9, scanlator: nil)))
        subject.route.loadResponses = [.value(manga(chapters: chapters))]

        await subject.viewModel.refresh()

        XCTAssertNil(subject.viewModel.readerDestination)
        XCTAssertEqual(subject.messages.messages, [.chapterUnavailable(isEpisode: false)])
    }

    func testALockedChapterSaysSoInsteadOfOpening() async {
        let locked = [Manga.Chapter(key: "one", chapter: 1, paywalled: true)]
        let chapter = makeSubject(openIntent: .chapter(reference(key: "one", number: 1, scanlator: nil)))
        chapter.route.loadResponses = [.value(manga(chapters: locked))]
        await chapter.viewModel.refresh()
        XCTAssertNil(chapter.viewModel.readerDestination)
        XCTAssertEqual(chapter.messages.messages, [.chapterLocked(isEpisode: false)])

        let resume = makeSubject(openIntent: .resume(preferredScanlator: nil))
        resume.route.loadResponses = [.value(manga(chapters: locked))]
        await resume.viewModel.refresh()
        XCTAssertNil(resume.viewModel.readerDestination)
        XCTAssertEqual(resume.messages.messages, [.chapterLocked(isEpisode: false)])
    }

    func testAFinishedCompletedSeriesStartsOverAndAnOngoingOneReopensTheLatest() async {
        let completed = makeSubject(openIntent: nil)
        completed.progress.readChapterNumbers[completed.viewModel.mediaIdentity] = [1, 2]
        completed.route.loadResponses = [.value(manga(chapters: chapters, status: .Completed))]
        await completed.viewModel.refresh()
        XCTAssertEqual(completed.viewModel.resumeChapter?.key, "one")
        XCTAssertTrue(completed.viewModel.isResumeRereading)

        let ongoing = makeSubject(openIntent: nil)
        ongoing.progress.readChapterNumbers[ongoing.viewModel.mediaIdentity] = [1, 2]
        ongoing.route.loadResponses = [.value(manga(chapters: chapters, status: .Ongoing))]
        await ongoing.viewModel.refresh()
        XCTAssertEqual(ongoing.viewModel.resumeChapter?.key, "two")
        XCTAssertFalse(ongoing.viewModel.isResumeRereading)
    }

    func testAFailedLoadDropsTheIntentSoARetryStaysOnTheSeries() async {
        let subject = makeSubject(openIntent: .chapter(reference(key: "one", number: 1, scanlator: nil)))
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
        let messages: MediaDetailMessageSpy
    }

    private func makeSubject(openIntent: MediaDetailOpenIntent?) -> Subject {
        let route = MediaRouteHarness<Manga>()
        let progress = MediaDetailProgressFake()
        let messages = MediaDetailMessageSpy()
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
            messagePresenter: messages,
            presentationLogger: PresentationEventCaptureSpy(),
            openIntent: openIntent
        )
        return Subject(viewModel: viewModel, route: route, progress: progress, messages: messages)
    }

    private func manga(chapters: [Manga.Chapter], status: Manga.Status = .Unknown) -> Manga {
        Manga(key: "m1", title: "Manga", status: status, chapters: chapters)
    }

    private func reference(key: String, number: Float, scanlator: String?) -> MediaDetailChapterReference {
        MediaDetailChapterReference(key: key, number: number, volume: nil, scanlator: scanlator)
    }

    private func openedChapter(_ viewModel: MediaDetailViewModel<Manga>) -> String? {
        guard case .pages(_, _, _, _, let chapter) = viewModel.readerDestination else { return nil }
        return chapter.key
    }
}
