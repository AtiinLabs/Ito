import XCTest
@testable import Ito

@MainActor
final class TrackerProviderSelectionViewModelTests: XCTestCase {
    private func configuration(anilistRemoteID: String?, isAnime: Bool = true) -> TrackerSheetConfiguration {
        TrackerSheetConfiguration(
            mediaIdentity: MediaIdentity(pluginId: "plugin.test", canonicalMediaId: "media.test"),
            title: "Title",
            isAnime: isAnime,
            providers: [
                TrackerSheetProviderPresentation(
                    provider: presentation(id: "anilist", name: "AniList"),
                    linkedRemoteMediaID: anilistRemoteID
                ),
                TrackerSheetProviderPresentation(
                    provider: presentation(id: "myanimelist", name: "MyAnimeList"),
                    linkedRemoteMediaID: nil
                )
            ]
        )
    }

    private func presentation(id: String, name: String) -> TrackerProviderPresentation {
        TrackerProviderPresentation(identifier: id, name: name, isAuthenticated: true, username: nil)
    }

    func testLinkedTrackerShowsItsEntryAndUnlinkedTrackerIsNotTracked() async {
        let service = TrackerDetailsServiceFake()
        service.queuedLoadResults = [.success(TrackerMediaEntry(status: "CURRENT", progress: 3, score: nil, startDate: nil, finishDate: nil))]
        let viewModel = TrackerProviderSelectionViewModel(
            configuration: configuration(anilistRemoteID: "1"),
            detailsService: service
        )

        XCTAssertEqual(viewModel.label(for: "anilist"), "Checking…")
        XCTAssertEqual(viewModel.label(for: "myanimelist"), "Not tracked")
        viewModel.start()
        viewModel.start()
        await trackingWaitUntil { viewModel.label(for: "anilist") == "Watching · 3" }

        XCTAssertEqual(service.loadInvocations.count, 1)
        XCTAssertEqual(service.loadInvocations[0].providerID, "anilist")
        XCTAssertEqual(service.loadInvocations[0].mediaID, "1")
        XCTAssertEqual(viewModel.label(for: "myanimelist"), "Not tracked")
    }

    func testReadingSeriesUsesReadingLabelAndMissingEntryIsNotOnList() async {
        let service = TrackerDetailsServiceFake()
        service.queuedLoadResults = [.success(nil)]
        let viewModel = TrackerProviderSelectionViewModel(
            configuration: configuration(anilistRemoteID: "2", isAnime: false),
            detailsService: service
        )

        viewModel.start()
        await trackingWaitUntil { viewModel.label(for: "anilist") == "Not on list" }
    }

    func testFailedLoadStillShowsTracked() async {
        let service = TrackerDetailsServiceFake()
        service.queuedLoadResults = [.failure(TrackingTestError.failure)]
        let viewModel = TrackerProviderSelectionViewModel(
            configuration: configuration(anilistRemoteID: "3"),
            detailsService: service
        )

        viewModel.start()
        await trackingWaitUntil { viewModel.label(for: "anilist") == "Tracked" }
    }
}
