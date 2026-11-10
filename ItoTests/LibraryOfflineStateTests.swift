import UIKit
import XCTest
import ito_runner
@testable import Ito

/// The Library says when the device is offline and keeps the covers its cards displayed.
@MainActor
final class LibraryOfflineStateTests: XCTestCase {
    private final class Messages: LibraryMessagePresenting {
        func present(_ message: LibraryMessage) { _ = message }
    }

    private struct Subject {
        let viewModel: LibraryViewModel
        let connectivity: ConnectivityFake
        let thumbnails: LibraryCoverThumbnailsFake
    }

    private func makeSubject(isOffline: Bool = false) -> Subject {
        let connectivity = ConnectivityFake(isOffline: isOffline)
        let thumbnails = LibraryCoverThumbnailsFake()
        var dependencies = PreparedLibraryDependencies.unavailable()
        dependencies.connectivity = connectivity
        dependencies.coverThumbnails = thumbnails
        let viewModel = LibraryViewModel(
            dependencies: dependencies,
            tabRouter: AppRouter(),
            messagePresenter: Messages(),
            presentationLogger: PresentationEventCaptureSpy()
        )
        return Subject(viewModel: viewModel, connectivity: connectivity, thumbnails: thumbnails)
    }

    private func item(id: String = "series-1", coverUrl: String? = "https://example.com/cover.jpg") -> Ito.LibraryItem {
        Ito.LibraryItem(
            id: id,
            title: "Series",
            coverUrl: coverUrl,
            pluginId: "plugin.test",
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data(),
            anilistId: nil
        )
    }

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 6)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 6))
        }
    }

    func testTheBannerStateStartsFromConnectivityAndFollowsIt() {
        let online = makeSubject(isOffline: false)
        let offline = makeSubject(isOffline: true)
        XCTAssertFalse(online.viewModel.isOffline)
        XCTAssertTrue(offline.viewModel.isOffline)

        online.connectivity.set(isOffline: true)
        offline.connectivity.set(isOffline: false)

        XCTAssertTrue(online.viewModel.isOffline)
        XCTAssertFalse(offline.viewModel.isOffline)
    }

    func testTheUnavailableSeamNeverShowsTheBanner() {
        let viewModel = LibraryViewModel(
            dependencies: .unavailable(),
            tabRouter: AppRouter(),
            messagePresenter: Messages(),
            presentationLogger: PresentationEventCaptureSpy()
        )

        XCTAssertFalse(viewModel.isOffline)
    }

    func testADisplayedCoverIsHandedToTheDurableStoreWithItsAddress() {
        let subject = makeSubject()
        let cover = image()

        subject.viewModel.coverLoaded(for: item(), image: cover)

        XCTAssertEqual(subject.thumbnails.captures.map(\.itemID), ["series-1"])
        XCTAssertEqual(subject.thumbnails.captures.map(\.coverUrl), ["https://example.com/cover.jpg"])
        XCTAssertTrue(subject.thumbnails.captures.first?.image === cover)
    }

    func testAnItemWithoutACoverAddressKeepsNothing() {
        let subject = makeSubject()

        subject.viewModel.coverLoaded(for: item(coverUrl: nil), image: image())

        XCTAssertTrue(subject.thumbnails.captures.isEmpty)
    }

    func testTheDurableCoverComesFromTheStoreByItemIDWhenItMatchesTheCardsCoverAddress() async {
        let subject = makeSubject()
        let stored = image()
        subject.thumbnails.thumbnails["series-1"] = LibraryDurableCover(
            image: stored,
            coverURLSHA256: LibraryCoverThumbnailStore.coverHash("https://example.com/cover.jpg")
        )

        let found = await subject.viewModel.durableCover(for: item())
        let missing = await subject.viewModel.durableCover(for: item(id: "series-2"))

        XCTAssertTrue(found === stored)
        XCTAssertNil(missing)
        XCTAssertEqual(subject.thumbnails.thumbnailRequests, ["series-1", "series-2"])
    }

    func testADurableCoverCapturedForAnotherCoverAddressIsNotShown() async {
        let subject = makeSubject()
        subject.thumbnails.thumbnails["series-1"] = LibraryDurableCover(
            image: image(),
            coverURLSHA256: LibraryCoverThumbnailStore.coverHash("https://example.com/old-cover.jpg")
        )

        let shown = await subject.viewModel.durableCover(for: item())

        XCTAssertNil(shown)
    }
}
