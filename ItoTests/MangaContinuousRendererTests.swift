import Nuke
import UIKit
import XCTest
import ito_runner
@testable import Ito

/// Drives the production continuous renderer in a window, with image responses released by the
/// test, and checks that the page on screen stays at the same pixel through every change.
@MainActor
final class MangaContinuousRendererTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    func testImagesResizingAboveAndAtTheAnchorKeepTheVisiblePageInPlace() async throws {
        let reader = try await openReader(chapters: [chapter("a", 1)], initial: "a", pageCount: 6)
        // Prefetch keeps these requests alive whether or not their cells are on screen.
        reader.subject.viewModel.imageSession.setPrefetch(try ["a#0", "a#1", "a#3"].map(reader.descriptor))

        let offset = try reader.scroll(toPage: "a#3", pixelOffset: -120)
        try await reader.respond("a#0", width: 400, height: 1_200)
        try reader.assertAnchor("a#3", offset)
        XCTAssertEqual(reader.controller.pageFrame("a#0")?.height, 1_170)

        try await reader.respond("a#1", width: 400, height: 200)
        try reader.assertAnchor("a#3", offset)
        XCTAssertEqual(reader.controller.pageFrame("a#1")?.height, 195)

        // The page being read grows too; its top stays where it was.
        try await reader.respond("a#3", width: 400, height: 900)
        try reader.assertAnchor("a#3", offset)
    }

    func testATallImageArrivingInASliverAtTheTopDoesNotMoveThePageBeingRead() async throws {
        let reader = try await openReader(chapters: [chapter("a", 1)], initial: "a", pageCount: 4)
        reader.subject.viewModel.imageSession.setPrefetch([try reader.descriptor("a#0")])
        // Only the bottom 300 points of the first page show; the reader looks at the second.
        let offset = try reader.scroll(toPage: "a#1", pixelOffset: 308)

        try await reader.respond("a#0", width: 400, height: 4_000)
        try reader.assertAnchor("a#1", offset)
    }

    func testThePreviousChaptersLastPageArrivingAboveTheDividerDoesNotMoveTheCurrentChapter() async throws {
        // A 667-point screen puts the middle of the viewport in the gap above the divider.
        let reader = try await openReader(
            chapters: [chapter("c1", 1), chapter("c2", 2)],
            initial: "c2",
            pageCount: 2,
            windowSize: CGSize(width: 375, height: 667)
        )
        reader.subject.loader.enqueue(.pages(pages("c1", count: 2)), for: "c1")
        reader.subject.viewModel.prependPreviousChapter()
        await waitUntil { reader.subject.viewModel.segments.count == 2 }
        let anchor = try XCTUnwrap(reader.controller.visibleAnchor())
        XCTAssertEqual(anchor.pageID, "c2#0")

        reader.subject.viewModel.imageSession.setPrefetch([try reader.descriptor("c1#1")])
        try await reader.respond("c1#1", width: 400, height: 4_000)
        try reader.assertAnchor("c2#0", anchor.pixelOffset)
    }

    func testDeepOffsetSurvivesPrependAppendAndEviction() async throws {
        let chapters = (1...5).map { chapter("c\($0)", Float32($0)) }
        let reader = try await openReader(chapters: chapters, initial: "c3", pageCount: 2)
        reader.subject.viewModel.imageSession.setPrefetch([try reader.descriptor("c3#1")])
        try await reader.respond("c3#1", width: 400, height: 8_000)
        let offset = try reader.scroll(toPage: "c3#1", pixelOffset: -4_558.5)
        await waitUntil { reader.subject.viewModel.continuousPageIndex == 1 }

        for key in ["c2", "c1"] {
            reader.subject.loader.enqueue(.pages(pages(key, count: 2)), for: key)
            let count = reader.subject.viewModel.segments.count
            reader.subject.viewModel.prependPreviousChapter()
            await waitUntil { reader.subject.viewModel.segments.count == count + 1 }
            try reader.assertAnchor("c3#1", offset)
        }
        for key in ["c4", "c5"] {
            reader.subject.loader.enqueue(.pages(pages(key, count: 2)), for: key)
            reader.subject.viewModel.appendNextChapter()
            await waitUntil { reader.subject.viewModel.segments.last?.chapter.key == key }
            try reader.assertAnchor("c3#1", offset)
        }
        // Five chapters exceed the window: the one farthest above the reader was dropped.
        XCTAssertEqual(reader.subject.viewModel.segments.map(\.chapter.key), ["c2", "c3", "c4", "c5"])
    }

    func testRotationAndWebtoonSpacingKeepTheVisiblePageInPlace() async throws {
        let reader = try await openReader(chapters: [chapter("a", 1)], initial: "a", pageCount: 4)
        let offset = try reader.scroll(toPage: "a#2", pixelOffset: -100)

        let window = try XCTUnwrap(window)
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 844)
        window.layoutIfNeeded()
        reader.controller.view.layoutIfNeeded()
        XCTAssertEqual(reader.controller.pageFrame("a#2")?.width, 600)
        try reader.assertAnchor("a#2", offset)

        reader.subject.viewModel.setViewerOverride(.Webtoon)
        try reader.assertAnchor("a#2", offset)
        let first = try XCTUnwrap(reader.controller.pageFrame("a#1"))
        let second = try XCTUnwrap(reader.controller.pageFrame("a#2"))
        XCTAssertEqual(second.minY, first.maxY)
    }

    func testSavedPageIsRestoredWithoutRecordingTheFirstPage() async throws {
        let reader = try await openReader(
            chapters: [chapter("a", 1)],
            initial: "a",
            pageCount: 5,
            savedPage: 3
        )
        await waitUntil { reader.subject.viewModel.scrollTarget == nil }
        await waitUntil { reader.subject.progress.savedPages["a"] == 3 }

        let target = try XCTUnwrap(reader.controller.pageFrame("a#3"))
        XCTAssertEqual(reader.controller.collectionView.contentOffset.y, target.minY)
        XCTAssertEqual(reader.subject.viewModel.continuousPageIndex, 3)
        XCTAssertFalse(reader.subject.progress.savedPageWrites.contains { $0.page == 0 })
    }

    func testReachingTheEndWithoutTheUserScrollingDoesNotLoadTheNextChapter() async throws {
        let reader = try await openReader(
            chapters: [chapter("a", 1), chapter("b", 2)],
            initial: "a",
            pageCount: 2
        )
        reader.subject.loader.enqueue(.pages(pages("b", count: 2)), for: "b")
        let collectionView = reader.controller.collectionView
        collectionView.contentOffset.y = collectionView.contentSize.height - collectionView.bounds.height
        collectionView.layoutIfNeeded()
        // The renderer delivers to the view model on the main queue: once a block queued now
        // runs, everything the scroll queued has run before it.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        await reader.subject.viewModel.waitForTestingOperations()

        XCTAssertEqual(reader.subject.viewModel.continuousPageIndex, 1)
        XCTAssertEqual(reader.subject.loader.callCount(for: "b"), 0)
    }

    func testALayoutChangeDuringAnAnimatedJumpLandsOnTheRequestedPage() async throws {
        let reader = try await openReader(chapters: [chapter("a", 1)], initial: "a", pageCount: 6)

        // The footer's next-page button animates; switching to Webtoon spacing lands mid-flight.
        reader.subject.viewModel.nextPage()
        reader.subject.viewModel.setViewerOverride(.Webtoon)
        await waitUntil { reader.subject.viewModel.scrollTarget == nil }

        let target = try XCTUnwrap(reader.controller.pageFrame("a#1"))
        XCTAssertEqual(reader.controller.collectionView.contentOffset.y, target.minY)
        XCTAssertEqual(reader.subject.viewModel.continuousPageIndex, 1)
    }

    // MARK: - Fixtures

    private func openReader(
        chapters: [Manga.Chapter],
        initial: String,
        pageCount: Int,
        savedPage: Int? = nil,
        windowSize: CGSize = CGSize(width: 390, height: 844)
    ) async throws -> RendererFixture {
        let images = GatedImageLoader()
        let pipeline = ImagePipeline {
            $0.dataLoader = images
            $0.imageCache = nil
            $0.dataCache = nil
        }
        let start = try XCTUnwrap(chapters.first { $0.key == initial })
        let subject = makeMangaReaderSubject(
            manga: Manga(key: "manga", title: "Manga", viewer: .Vertical, chapters: chapters),
            initialChapter: start,
            imageSession: ReaderPageImageSession(pipeline: pipeline)
        )
        subject.progress.savedPages[initial] = savedPage
        subject.loader.enqueue(.pages(pages(initial, count: pageCount)), for: initial)
        subject.viewModel.start()
        await waitUntil { subject.viewModel.loadPhase == .content }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: windowSize)
        let controller = MangaContinuousCollectionViewController(viewModel: subject.viewModel, onToggleUI: {})
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        self.window = window
        return RendererFixture(test: self, subject: subject, controller: controller, images: images)
    }

    private func chapter(_ key: String, _ number: Float32) -> Manga.Chapter {
        Manga.Chapter(key: key, title: nil, chapter: number, scanlator: nil, paywalled: nil)
    }

    private func pages(_ chapterKey: String, count: Int) -> [Page] {
        (0..<count).map { Page(index: Int32($0), content: .url(GatedImageLoader.url(chapterKey, $0))) }
    }

    fileprivate func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the reader")
    }
}

@MainActor
private struct RendererFixture {
    let test: MangaContinuousRendererTests
    let subject: MangaReaderTestSubject
    let controller: MangaContinuousCollectionViewController
    let images: GatedImageLoader

    func descriptor(_ pageID: String) throws -> ReaderPageImageDescriptor {
        let page = try XCTUnwrap(subject.viewModel.flatPages.first { $0.id == pageID })
        guard case .url(let value) = page.page.content else { throw XCTSkip("not an image page") }
        let url = try XCTUnwrap(URL(string: value))
        return ReaderPageImageDescriptor(
            pageID: pageID,
            request: NukeMangaReaderImagePrefetcher.urlRequest(url: url, headers: page.page.headers)
        )
    }

    /// Scrolls so `pageID` starts `pixelOffset` below the viewport's top, and returns the offset
    /// the scroll view actually used: it rounds to whole screen pixels.
    func scroll(toPage pageID: String, pixelOffset: CGFloat) throws -> CGFloat {
        let frame = try XCTUnwrap(controller.pageFrame(pageID))
        controller.collectionView.contentOffset = CGPoint(x: 0, y: frame.minY - pixelOffset)
        controller.collectionView.layoutIfNeeded()
        let anchor = try XCTUnwrap(controller.visibleAnchor())
        XCTAssertEqual(anchor.pageID, pageID)
        XCTAssertEqual(anchor.pixelOffset, pixelOffset, accuracy: 1)
        return anchor.pixelOffset
    }

    func assertAnchor(
        _ pageID: String,
        _ pixelOffset: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let anchor = try XCTUnwrap(controller.visibleAnchor(), file: file, line: line)
        XCTAssertEqual(anchor.pageID, pageID, file: file, line: line)
        XCTAssertEqual(anchor.pixelOffset, pixelOffset, accuracy: 0.001, file: file, line: line)
    }

    /// Answers the page's image request once the session has made it, and checks the renderer
    /// applied the size: the session notifies the renderer in the same pass as this test.
    func respond(_ pageID: String, width: Int, height: Int) async throws {
        let descriptor = try descriptor(pageID)
        let url = try XCTUnwrap(descriptor.request.url)
        let decoded = test.expectation(description: "\(pageID) decoded")
        let observation = subject.viewModel.imageSession.observe(descriptor.key) { state in
            if state.pixelSize != nil { decoded.fulfill() }
        }
        await images.waitForRequest(url)
        images.respond(url, width: width, height: height)
        await test.fulfillment(of: [decoded], timeout: 5)
        observation.cancel()
        let expected = (controller.collectionView.bounds.width * CGFloat(height) / CGFloat(width)).rounded(.up)
        XCTAssertEqual(controller.pageFrame(pageID)?.height, expected)
    }
}

/// Holds image requests until the test answers them with a PNG of a chosen size.
final class GatedImageLoader: DataLoading, @unchecked Sendable {
    private struct Pending {
        let didReceiveData: @Sendable (Data, URLResponse) -> Void
        let completion: @Sendable (Error?) -> Void
    }

    private let lock = NSLock()
    private var pending: [URL: [Pending]] = [:]
    private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private var requests = 0

    /// Every request the pipeline has made so far.
    var requestCount: Int { lock.withLock { requests } }

    static func url(_ chapterKey: String, _ index: Int) -> String {
        "https://renderer.test/\(chapterKey)/\(index).png"
    }

    /// Returns once a request for `url` is waiting for an answer.
    func waitForRequest(_ url: URL) async {
        await withCheckedContinuation { continuation in
            let isPending = lock.withLock {
                if !(pending[url]?.isEmpty ?? true) { return true }
                waiters[url, default: []].append(continuation)
                return false
            }
            if isPending { continuation.resume() }
        }
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        guard let url = request.url else {
            completion(URLError(.badURL))
            return GatedImageCancellation()
        }
        let resumed = lock.withLock {
            requests += 1
            pending[url, default: []].append(Pending(didReceiveData: didReceiveData, completion: completion))
            return waiters.removeValue(forKey: url) ?? []
        }
        resumed.forEach { $0.resume() }
        return GatedImageCancellation()
    }

    func respond(_ url: URL, width: Int, height: Int) {
        let waiting = lock.withLock { pending.removeValue(forKey: url) ?? [] }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .pngData { context in
                UIColor.gray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
        let response = URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil)
        for request in waiting {
            request.didReceiveData(data, response)
            request.completion(nil)
        }
    }
}

private final class GatedImageCancellation: Cancellable, Sendable {
    func cancel() {}
}
