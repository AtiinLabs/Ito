import XCTest
import ito_runner
@testable import Ito

/// The notice a relink shows when it cancelled queued downloads.
@MainActor
final class MediaDetailRelinkNoticeTests: XCTestCase {
    private static let pluginID = "plugin.test"

    private struct Subject {
        let viewModel: MediaDetailViewModel<Manga>
        let route: MediaRouteHarness<Manga>
        let relink: MediaDetailRelinkFake
    }

    private func makeSubject() -> Subject {
        let media = Manga(key: "m1", title: "Manga", cover: nil, chapters: nil)
        let route = MediaRouteHarness<Manga>()
        let relink = MediaDetailRelinkFake()
        let runner = ItoRunner()
        let viewModel = MediaDetailViewModel(
            media: media,
            pluginID: Self.pluginID,
            routeContext: MediaDetailRouteContext<Manga>(
                loadDetails: { try await route.load($0, operation: $1) },
                searchForRelink: { try await route.search($0, operationID: $1) },
                makeReaderDestination: { parent, selected in
                    .pages(
                        id: UUID(),
                        content: ReaderContentSource(remote: runner),
                        pluginID: Self.pluginID,
                        entry: .manga(parent),
                        chapter: selected
                    )
                }
            ),
            dependencies: PreparedMediaDetailDependencies(
                library: MediaDetailLibraryFake(
                    state: MediaDetailLibraryState(
                        records: [MediaDetailLibraryRecord(itemID: "m1", pluginID: Self.pluginID, mediaKind: .manga)],
                        hasCustomCategories: false
                    )
                ),
                progress: MediaDetailProgressFake(),
                tracker: MediaDetailTrackerFake(),
                theme: MediaDetailThemeFake(),
                relink: relink,
                baseline: MediaDetailBaselineFake(),
                settings: MediaDetailSettingsFake(),
                pluginMetadata: MediaDetailPluginMetadataFake(),
                discord: MediaDetailDiscordFake()
            ),
            messagePresenter: MediaDetailMessageSpy(),
            presentationLogger: PresentationEventCaptureSpy()
        )
        return Subject(viewModel: viewModel, route: route, relink: relink)
    }

    /// Opens the relink sheet and relinks to a second series.
    private func performRelink(_ subject: Subject) async {
        let selected = Manga(key: "m2", title: "Selected", cover: nil, chapters: nil)
        subject.route.loadResponses = [.value(selected)]
        subject.viewModel.openRelink()
        await subject.viewModel.performRelink(with: selected)
    }

    func testARelinkThatCancelledSeveralDownloadsSaysSoUntilDismissed() async {
        let subject = makeSubject()
        subject.relink.cancelledDownloadCount = 3

        await performRelink(subject)

        XCTAssertEqual(subject.viewModel.relinkCancelledDownloadCount, 3)
        XCTAssertEqual(
            subject.viewModel.relinkDownloadsNotice,
            "3 queued downloads were cancelled. Download them again from the new source."
        )

        subject.viewModel.dismissRelinkDownloadsNotice()
        XCTAssertNil(subject.viewModel.relinkDownloadsNotice)
    }

    func testARelinkThatCancelledNoDownloadsShowsNoNotice() async {
        let subject = makeSubject()
        subject.relink.cancelledDownloadCount = 0

        await performRelink(subject)

        XCTAssertEqual(subject.viewModel.relinkCancelledDownloadCount, 0)
        XCTAssertNil(subject.viewModel.relinkDownloadsNotice)
    }

    func testAFailedRelinkShowsNoDownloadsNotice() async {
        let subject = makeSubject()
        subject.relink.cancelledDownloadCount = 3
        subject.relink.error = MediaDetailTestFailure.expected

        await performRelink(subject)

        XCTAssertNil(subject.viewModel.relinkDownloadsNotice)
    }
}
