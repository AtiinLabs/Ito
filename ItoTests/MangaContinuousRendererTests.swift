import Combine
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

    func testWebtoonPagesMeetWithoutABackgroundLineBetweenThem() async throws {
        let reader = try await openReader(chapters: [chapter("a", 1)], initial: "a", pageCount: 3)
        reader.subject.viewModel.setViewerOverride(.Webtoon)
        reader.subject.viewModel.imageSession.setPrefetch(try ["a#0", "a#1"].map(reader.descriptor))
        // At 390 points wide these pages are 998.4 points tall: not a whole number of points.
        try await reader.respond("a#0", width: 400, height: 1_024)
        try await reader.respond("a#1", width: 400, height: 1_024)
        _ = try reader.scroll(toPage: "a#1", pixelOffset: 400)

        // Both pages show their images once the session holds them; the window then draws them.
        let session = reader.subject.viewModel.imageSession
        let keys = try ["a#0", "a#1"].map { try reader.descriptor($0).key }
        await waitUntil {
            keys.allSatisfy { if case .ready = session.state(for: $0).phase { true } else { false } }
        }
        let window = try XCTUnwrap(window)
        let seam = try XCTUnwrap(reader.controller.pageFrame("a#1")).minY
            - reader.controller.scrollView.contentOffset.y
        let rows = Self.pixelRows(in: window, around: seam)
        XCTAssertEqual(rows.count, 7)
        XCTAssertTrue(rows.allSatisfy { $0 > 0 }, "Brightness by pixel row around the seam: \(rows)")
    }

    func testFractionalViewportZoomDoesNotExposeABackgroundSeam() async throws {
        let reader = try await openReader(chapters: [chapter("a", 1)], initial: "a", pageCount: 3)
        reader.subject.viewModel.setViewerOverride(.Webtoon)
        let session = reader.subject.viewModel.imageSession
        let descriptors = try ["a#0", "a#1"].map(reader.descriptor)
        let ready = expectation(description: "Both seam images decoded")
        ready.expectedFulfillmentCount = descriptors.count
        var delivered: Set<ReaderPageImageKey> = []
        let observations = descriptors.map { descriptor in
            session.observe(descriptor.key) { state in
                if case .ready = state.phase, delivered.insert(descriptor.key).inserted { ready.fulfill() }
            }
        }
        defer { observations.forEach { $0.cancel() } }
        session.setPrefetch(descriptors)
        try await reader.respond("a#0", width: 400, height: 1_024)
        try await reader.respond("a#1", width: 400, height: 1_024)
        reader.controller.scrollView.setZoomScale(2.5, animated: false)
        _ = try reader.scroll(toPage: "a#1", pixelOffset: 400)
        await fulfillment(of: [ready], timeout: 5)
        let screenY = try XCTUnwrap(reader.controller.pageFrame("a#1")).minY * 2.5
            - reader.controller.scrollView.contentOffset.y
        let rows = Self.pixelRows(in: try XCTUnwrap(window), around: screenY)
        XCTAssertEqual(rows.count, 7)
        XCTAssertTrue(rows.allSatisfy { $0 > 0 }, "Brightness around the magnified seam: \(rows)")
    }

    /// The brightness of the screen pixels in the middle column from three pixels above `y` to
    /// three below it, as the window draws them.
    private static func pixelRows(in window: UIWindow, around y: CGFloat) -> [UInt8] {
        let scale = window.screen.scale
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return [] }
        let column = cgImage.width / 2
        let center = Int((y * scale).rounded())
        return (center - 3...center + 3).compactMap { row in
            guard (0..<cgImage.height).contains(row) else { return nil }
            let offset = row * cgImage.bytesPerRow + column * cgImage.bitsPerPixel / 8
            return max(bytes[offset], bytes[offset + 1], bytes[offset + 2])
        }
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
        XCTAssertEqual(reader.controller.scrollView.contentOffset.y, target.minY)
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
        let scrollView = reader.controller.scrollView
        scrollView.contentOffset.y = scrollView.contentSize.height - scrollView.bounds.height
        scrollView.layoutIfNeeded()
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
        XCTAssertEqual(reader.controller.scrollView.contentOffset.y, target.minY)
        XCTAssertEqual(reader.subject.viewModel.continuousPageIndex, 1)
    }

    func testQueuedViewportSurvivesLayoutInvalidation() async throws {
        let reader = try await openReader(chapters: [chapter("a", 1)], initial: "a", pageCount: 6)
        let delivered = expectation(description: "Current viewport is delivered after layout invalidation")
        let subscription = reader.subject.viewModel.$continuousPageIndex.filter { $0 == 2 }.first().sink { _ in delivered.fulfill() }
        defer { subscription.cancel() }
        _ = try reader.scroll(toPage: "a#2", pixelOffset: -100)

        // Queue progress, then synchronously change row geometry before the main-queue delivery.
        reader.controller.scrollViewDidScroll(reader.controller.scrollView)
        reader.subject.viewModel.setViewerOverride(.Webtoon)

        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(reader.subject.viewModel.continuousPageIndex, 2)
    }

    func testZoomedImageArrivalPreservesPhysicalAnchorAndViewportProgress() async throws {
        let reader = try await openReader(chapters: [chapter("a", 1)], initial: "a", pageCount: 20)
        let delivered = expectation(description: "Zoomed anchor page is published")
        let subscription = reader.subject.viewModel.$continuousPageIndex.filter { $0 == 10 }.first().sink { _ in delivered.fulfill() }
        defer { subscription.cancel() }
        reader.controller.scrollView.setZoomScale(2.5, animated: false)
        reader.subject.viewModel.imageSession.setPrefetch(try ["a#0", "a#10"].map(reader.descriptor))
        let offset = try reader.scroll(toPage: "a#10", pixelOffset: -120)
        try await reader.respond("a#0", width: 400, height: 4_000)
        try reader.assertAnchor("a#10", offset)
        try await reader.respond("a#10", width: 400, height: 2_000)
        try reader.assertAnchor("a#10", offset)
        XCTAssertEqual(reader.controller.visiblePageIDs(), ["a#10"])
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(reader.subject.viewModel.continuousPageIndex, 10)
        XCTAssertEqual(reader.controller.scrollView.zoomScale, 2.5)
    }

    func testZoomedPrependAndRotationPreservePhysicalAnchorAndBaseWidth() async throws {
        let reader = try await openReader(
            chapters: [chapter("a", 1), chapter("b", 2)], initial: "b", pageCount: 8
        )
        reader.controller.scrollView.setZoomScale(2.5, animated: false)
        let offset = try reader.scroll(toPage: "b#4", pixelOffset: -90)
        reader.subject.loader.enqueue(.pages(pages("a", count: 8)), for: "a")
        reader.subject.viewModel.prependPreviousChapter()
        await reader.subject.viewModel.waitForTestingOperations()
        try reader.assertAnchor("b#4", offset)
        let window = try XCTUnwrap(window)
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 844)
        window.layoutIfNeeded()
        reader.controller.view.layoutIfNeeded()
        try reader.assertAnchor("b#4", offset)
        XCTAssertEqual(reader.controller.pageFrame("b#4")?.width, 600)
        XCTAssertEqual(reader.controller.documentViewport.width, 240, accuracy: 0.001)
    }

    func testZoomedDeepPositionAndHorizontalPanSurviveChapterWindowEviction() async throws {
        let chapters = (1...5).map { chapter("c\($0)", Float32($0)) }
        let reader = try await openReader(chapters: chapters, initial: "c3", pageCount: 2)
        reader.controller.scrollView.setZoomScale(2.5, animated: false)
        reader.subject.viewModel.imageSession.setPrefetch([try reader.descriptor("c3#1")])
        try await reader.respond("c3#1", width: 400, height: 8_000)
        let offset = try reader.scroll(toPage: "c3#1", pixelOffset: -4_558.5)
        reader.controller.scrollView.contentOffset.x = 170
        for key in ["c2", "c1"] {
            reader.subject.loader.enqueue(.pages(pages(key, count: 2)), for: key)
            reader.subject.viewModel.prependPreviousChapter()
            await reader.subject.viewModel.waitForTestingOperations()
            try reader.assertAnchor("c3#1", offset)
        }
        for key in ["c4", "c5"] {
            reader.subject.loader.enqueue(.pages(pages(key, count: 2)), for: key)
            reader.subject.viewModel.appendNextChapter()
            await reader.subject.viewModel.waitForTestingOperations()
            try reader.assertAnchor("c3#1", offset)
        }
        XCTAssertEqual(reader.subject.viewModel.segments.map(\.chapter.key), ["c2", "c3", "c4", "c5"])
        XCTAssertEqual(reader.controller.scrollView.zoomScale, 2.5)
        XCTAssertEqual(reader.controller.scrollView.contentOffset.x, 170, accuracy: 0.001)
    }

    func testZoomedLongDocumentKeepsRendererAndVisibleLeasesWindowed() async throws {
        let reader = try await openReader(chapters: [chapter("a", 1)], initial: "a", pageCount: 200)
        try await reader.respond("a#0", width: 400, height: 800)
        let session = reader.subject.viewModel.imageSession
        let oldKey = try reader.descriptor("a#0").key
        let released = expectation(description: "The old visible cell releases its decoded image")
        let observation = session.observe(oldKey) { state in
            if case .idle = state.phase { released.fulfill() }
        }
        defer { observation.cancel() }
        reader.controller.scrollView.setZoomScale(4, animated: false)
        _ = try reader.scroll(toPage: "a#100", pixelOffset: -80)
        await fulfillment(of: [released], timeout: 5)
        XCTAssertLessThan(reader.controller.collectionView.visibleCells.count, 5)
        XCTAssertEqual(reader.controller.visiblePageIDs(), ["a#100"])
        XCTAssertFalse(reader.controller.collectionView.isScrollEnabled)
        XCTAssertGreaterThan(reader.controller.scrollView.contentSize.height, 100_000)
    }

    func testRetainedCellRedisplayReacquiresItsImageAndInvalidationReleasesIt() async throws {
        let reader = try await openReader(chapters: [chapter("a", 1)], initial: "a", pageCount: 1)
        try await reader.respond("a#0", width: 400, height: 800)
        let controller = reader.controller
        let index = IndexPath(item: 0, section: 0)
        let cell = try XCTUnwrap(controller.collectionView.cellForItem(at: index))
        let key = try reader.descriptor("a#0").key
        let released = expectation(description: "End-display releases the visible lease")
        let redisplayed = expectation(description: "The retained cell loads again without dequeue")
        let invalidated = expectation(description: "Invalidation releases the redisplayed lease")
        var idleTransitions = 0
        let observation = reader.subject.viewModel.imageSession.observe(key) { state in
            switch state.phase {
            case .idle:
                idleTransitions += 1
                if idleTransitions == 1 { released.fulfill() }
                if idleTransitions == 2 { invalidated.fulfill() }
            case .ready:
                redisplayed.fulfill()
            default:
                break
            }
        }
        defer { observation.cancel() }
        controller.collectionView(controller.collectionView, didEndDisplaying: cell, forItemAt: index)
        controller.collectionView(controller.collectionView, didEndDisplaying: cell, forItemAt: index)
        await fulfillment(of: [released], timeout: 5)
        XCTAssertTrue(controller.children.isEmpty)
        controller.collectionView(controller.collectionView, willDisplay: cell, forItemAt: index)
        await fulfillment(of: [redisplayed], timeout: 5)
        controller.invalidate()
        await fulfillment(of: [invalidated], timeout: 5)
        XCTAssertTrue(controller.children.isEmpty)
        XCTAssertEqual(idleTransitions, 2)
    }

    func testZoomedNavigationAndWebtoonSeamsUseDocumentCoordinates() async throws {
        let reader = try await openReader(chapters: [chapter("a", 1)], initial: "a", pageCount: 8)
        reader.subject.viewModel.setViewerOverride(.Webtoon)
        reader.controller.scrollView.setZoomScale(2.5, animated: false)
        let delivered = expectation(description: "Zoomed jump acknowledges the requested page")
        let subscription = reader.subject.viewModel.$continuousPageIndex.filter { $0 == 1 }.first().sink { _ in delivered.fulfill() }
        defer { subscription.cancel() }
        reader.subject.viewModel.nextPage()
        // A synchronous geometry transaction must land an in-flight navigation at its new frame.
        reader.subject.viewModel.setViewerOverride(.Vertical)
        await fulfillment(of: [delivered], timeout: 5)
        let target = try XCTUnwrap(reader.controller.pageFrame("a#1"))
        XCTAssertEqual(reader.controller.scrollView.contentOffset.y, target.minY * 2.5, accuracy: 0.001)
        XCTAssertNil(reader.subject.viewModel.scrollTarget)
        XCTAssertEqual(reader.subject.viewModel.continuousPageIndex, 1)
        reader.subject.viewModel.setViewerOverride(.Webtoon)
        let first = try XCTUnwrap(reader.controller.pageFrame("a#0"))
        let second = try XCTUnwrap(reader.controller.pageFrame("a#1"))
        XCTAssertEqual(first.maxY * 2.5, second.minY * 2.5)
    }

    func testBottomClampedLandingKeepsTheRequestedPageAndSavedProgress() async throws {
        for changesLayout in [false, true] {
            let reader = try await openReader(chapters: [chapter("a", 1)], initial: "a", pageCount: 2)
            defer { window?.isHidden = true }
            reader.subject.viewModel.imageSession.setPrefetch(try ["a#0", "a#1"].map(reader.descriptor))
            try await reader.respond("a#0", width: 400, height: 2_000)
            try await reader.respond("a#1", width: 400, height: 200)
            let selected = expectation(description: "The clamped requested page remains selected")
            let saved = expectation(description: "The clamped requested page is persisted")
            let subscription = reader.subject.viewModel.$continuousPageIndex.filter { $0 == 1 }.first().sink { _ in selected.fulfill() }
            defer { subscription.cancel() }
            reader.subject.progress.onPageSaved = { chapter, page in
                if chapter == "a", page == 1 { saved.fulfill() }
            }
            reader.subject.viewModel.nextPage()
            if changesLayout { reader.subject.viewModel.setViewerOverride(.Webtoon) }
            await fulfillment(of: [selected, saved], timeout: 5)
            XCTAssertNil(reader.subject.viewModel.scrollTarget)
            XCTAssertEqual(reader.subject.viewModel.continuousPageIndex, 1)
            XCTAssertEqual(reader.subject.progress.savedPages["a"], 1)
            XCTAssertEqual(reader.controller.visiblePageIDs(), ["a#0", "a#1"])
        }
    }

    func testCompletedFooterNavigationNearTheEndAppendsTheNextChapter() async throws {
        let reader = try await openReader(
            chapters: [chapter("a", 1), chapter("b", 2)], initial: "a", pageCount: 2
        )
        reader.subject.loader.enqueue(.pages(pages("b", count: 2)), for: "b")
        let appended = expectation(description: "Footer navigation loads the next chapter")
        let subscription = reader.subject.viewModel.$segments.filter {
            $0.contains { $0.chapter.key == "b" }
        }.first().sink { _ in appended.fulfill() }
        defer { subscription.cancel() }
        reader.subject.viewModel.nextPage()
        await fulfillment(of: [appended], timeout: 5)
        XCTAssertEqual(reader.subject.loader.callCount(for: "b"), 1)
        XCTAssertEqual(reader.subject.viewModel.segments.last?.chapter.key, "b")
    }

    func testDeferredProgressCannotMakeThePhysicalChapterEvictable() async throws {
        let chapters = (1...7).map { chapter("c\($0)", Float32($0)) }
        let reader = try await openReader(chapters: chapters, initial: "c1", pageCount: 2)
        for key in ["c2", "c3", "c4"] {
            reader.subject.loader.enqueue(.pages(pages(key, count: 2)), for: key)
            reader.subject.viewModel.appendNextChapter()
            await reader.subject.viewModel.waitForTestingOperations()
        }
        let current = expectation(description: "The delivered viewport is in chapter four")
        let selected = reader.subject.viewModel.$currentChapter.filter { $0.key == "c4" }.first().sink { _ in current.fulfill() }
        defer { selected.cancel() }
        _ = try reader.scroll(toPage: "c4#0", pixelOffset: -100)
        await fulfillment(of: [current], timeout: 5)

        let controller = reader.controller
        controller.scrollViewWillBeginZooming(
            controller.scrollView, with: controller.viewForZooming(in: controller.scrollView)
        )
        let offset = try reader.scroll(toPage: "c1#0", pixelOffset: -100)
        XCTAssertEqual(reader.subject.viewModel.currentChapter.key, "c4")
        for key in ["c5", "c6"] {
            reader.subject.loader.enqueue(.pages(pages(key, count: 2)), for: key)
            reader.subject.viewModel.appendNextChapter()
            await reader.subject.viewModel.waitForTestingOperations()
            let anchor = try XCTUnwrap(controller.visibleAnchor())
            XCTAssertEqual(anchor.pageID, "c1#0", "A load of \(key) must not evict the physical viewport")
            XCTAssertEqual(anchor.pixelOffset, offset, accuracy: 0.001)
            XCTAssertNotNil(controller.pageFrame("c1#0"))
            XCTAssertNil(reader.subject.viewModel.scrollTarget)
        }
        let resumed = expectation(description: "Progress catches up to the physical chapter")
        let subscription = reader.subject.viewModel.$currentChapter.filter { $0.key == "c1" }.first().sink { _ in resumed.fulfill() }
        defer { subscription.cancel() }
        controller.scrollViewDidEndZooming(
            controller.scrollView, with: controller.viewForZooming(in: controller.scrollView), atScale: 1
        )
        await fulfillment(of: [resumed], timeout: 5)
        XCTAssertEqual(reader.subject.viewModel.currentChapter.key, "c1")
    }

    func testImageSizeBelowViewportDoesNotStopNativeScrolling() async throws {
        let reader = try await openReader(chapters: [chapter("a", 1)], initial: "a", pageCount: 20)
        let descriptor = try reader.descriptor("a#10")
        let session = reader.subject.viewModel.imageSession
        let lease = session.acquire(descriptor, consumer: .visible)
        defer { session.release(lease) }
        defer { reader.controller.onLayoutCommitted = nil }
        let committed = expectation(description: "The below-viewport image changes layout during native movement")
        let arrived = expectation(description: "Native scrolling continues to its destination")
        let target: CGFloat = 2_000
        let observer = ContinuousZoomFrameObserver()
        var response: Task<Void, Error>?
        var changedDuringMotion = false
        reader.controller.onLayoutCommitted = {
            guard !changedDuringMotion else { return }
            let offset = reader.controller.scrollView.contentOffset.y
            changedDuringMotion = offset > 0 && offset < target
            if changedDuringMotion { committed.fulfill() }
        }
        observer.onFrame = { [weak observer] in
            let offset = reader.controller.scrollView.contentOffset.y
            if offset > 0, offset < target, response == nil {
                response = Task { try await reader.respond("a#10", width: 400, height: 4_000) }
            }
            if changedDuringMotion, abs(offset - target) < 0.5 {
                observer?.stop()
                arrived.fulfill()
            }
        }
        observer.start()
        defer { observer.stop() }
        reader.controller.scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
        await fulfillment(of: [committed, arrived], timeout: 5)
        try await response?.value
        XCTAssertEqual(reader.controller.scrollView.contentOffset.y, target, accuracy: 0.5)
    }

    func testColdImageDimensionsDoNotDisturbNativeZoomFocus() async throws {
        let reader = try await openReader(chapters: [chapter("a", 1)], initial: "a", pageCount: 20)
        try await reader.respond("a#0", width: 400, height: 4_000)
        let session = reader.subject.viewModel.imageSession
        let lease = session.acquire(try reader.descriptor("a#10"), consumer: .visible)
        defer {
            session.release(lease)
            reader.controller.onLayoutCommitted = nil
        }
        let scrollView = reader.controller.scrollView
        let document = try XCTUnwrap(reader.controller.viewForZooming(in: scrollView))
        let checked = expectation(description: "Intermediate zoom frames retain their focus after cold dimensions arrive")
        let finished = expectation(description: "Native zoom finishes after the metadata arrives")
        let observer = ContinuousZoomFrameObserver()
        var response: Task<Void, Error>?
        var decoded = false
        var checkedFocus = false
        let expectedHeight: CGFloat = {
            let scale = reader.controller.traitCollection.displayScale
            return (scrollView.bounds.width * 40 / 400 * scale).rounded(.down) / scale
        }()
        let laidOut = expectation(description: "The mid-zoom size is laid out once the zoom has ended")
        var reportedLayout = false
        reader.controller.onLayoutCommitted = {
            guard !reportedLayout, reader.controller.pageFrame("a#10")?.height == expectedHeight else { return }
            reportedLayout = true
            XCTAssertTrue(checkedFocus, "The size must not be laid out before the zoom finishes")
            XCTAssertEqual(scrollView.zoomScale, 2.5, accuracy: 0.001)
            laidOut.fulfill()
        }
        let observation = session.observe(try reader.descriptor("a#10").key) { state in
            if state.pixelSize != nil { decoded = true }
        }
        defer { observation.cancel() }
        observer.onFrame = { [weak observer] in
            guard let documentLayer = document.layer.presentation(),
                  let viewportLayer = scrollView.layer.presentation() else { return }
            let scale = documentLayer.frame.width / document.bounds.width
            if scale > 1.05, scale < 2.45 {
                if response == nil {
                    response = Task { try await reader.respond("a#10", width: 400, height: 40, verifiesLayout: false) }
                }
                if decoded {
                    let point = viewportLayer.convert(CGPoint(x: 100, y: 160), from: documentLayer)
                    XCTAssertEqual(point.x - viewportLayer.bounds.minX, 100, accuracy: 1)
                    XCTAssertEqual(point.y - viewportLayer.bounds.minY, 160, accuracy: 1)
                    if !checkedFocus { checkedFocus = true; checked.fulfill() }
                }
            }
            if checkedFocus, abs(scale - 2.5) < 0.001 {
                observer?.stop()
                finished.fulfill()
            }
        }
        observer.start()
        defer { observer.stop() }
        scrollView.zoom(to: ReaderZoomGeometry.targetRect(
            contentPoint: CGPoint(x: 100, y: 160), viewportPoint: CGPoint(x: 100, y: 160),
            viewportSize: scrollView.bounds.size, scale: 2.5
        ), animated: true)
        await fulfillment(of: [checked, finished, laidOut], timeout: 5)
        try await response?.value
    }

    func testImageResizeAboveTheAnchorWaitsForMomentumToEnd() async throws {
        let scrollView = MomentumScrollView()
        let reader = try await openReader(chapters: [chapter("a", 1)], initial: "a", pageCount: 20, scrollView: scrollView)
        let session = reader.subject.viewModel.imageSession
        let leases = try ["a#2", "a#15"].map { session.acquire(try reader.descriptor($0), consumer: .visible) }
        defer { leases.forEach(session.release) }
        let offset = try reader.scroll(toPage: "a#10", pixelOffset: -100)
        let placeholderHeight = try XCTUnwrap(reader.controller.pageFrame("a#2")?.height)
        let contentOffset = scrollView.contentOffset
        scrollView.simulatesDeceleration = true

        // Above the anchor: correcting the offset now would stop the fling, so it waits.
        try await reader.respond("a#2", width: 400, height: 4_000, verifiesLayout: false)
        XCTAssertEqual(reader.controller.pageFrame("a#2")?.height, placeholderHeight)
        XCTAssertEqual(scrollView.contentOffset, contentOffset)
        // Below the anchor: no correction is needed, so it applies at once.
        try await reader.respond("a#15", width: 400, height: 4_000)
        XCTAssertEqual(scrollView.contentOffset, contentOffset)

        scrollView.simulatesDeceleration = false
        reader.controller.scrollViewDidEndDecelerating(scrollView)
        let width = scrollView.bounds.width
        let scale = reader.controller.traitCollection.displayScale
        XCTAssertEqual(reader.controller.pageFrame("a#2")?.height, (width * 10 * scale).rounded(.down) / scale)
        try reader.assertAnchor("a#10", offset)
    }

    func testAnimatedZoomKeepsThePresentedViewportCoveredInBothDirections() async throws {
        let reader = try await openReader(chapters: [chapter("a", 1)], initial: "a", pageCount: 3)
        try await reader.respond("a#0", width: 400, height: 4_000)
        try await assertAnimatedViewportCoverage(reader.controller, targetScale: 2.5)
        try await assertAnimatedViewportCoverage(reader.controller, targetScale: 1)
    }

    private func assertAnimatedViewportCoverage(
        _ controller: MangaContinuousCollectionViewController, targetScale: CGFloat
    ) async throws {
        let scrollView = controller.scrollView
        let document = try XCTUnwrap(controller.viewForZooming(in: scrollView))
        let startingScale = scrollView.zoomScale
        let intermediate = expectation(description: "The native animation presents a covered intermediate frame")
        let completed = expectation(description: "The native zoom reaches its final presented scale")
        let observer = ContinuousZoomFrameObserver()
        var sampled = false
        observer.onFrame = { [weak observer] in
            guard let documentLayer = document.layer.presentation(),
                  let viewportLayer = scrollView.layer.presentation(),
                  let collectionLayer = controller.collectionView.layer.presentation() else { return }
            let scale = documentLayer.frame.width / document.bounds.width
            if scale > min(startingScale, targetScale) + 0.05,
               scale < max(startingScale, targetScale) - 0.05 {
                let visible = documentLayer.convert(viewportLayer.bounds, from: viewportLayer)
                let rendered = documentLayer.convert(collectionLayer.bounds, from: collectionLayer)
                XCTAssertTrue(
                    rendered.insetBy(dx: -0.5, dy: -0.5).contains(visible),
                    "Native zoom must not expose unrendered black borders: visible \(visible), rendered \(rendered)"
                )
                if !sampled {
                    sampled = true
                    intermediate.fulfill()
                }
            }
            if sampled, abs(scale - targetScale) < 0.001 {
                observer?.stop()
                completed.fulfill()
            }
        }
        observer.start()
        defer { observer.stop() }
        let point = CGPoint(x: 100, y: 160)
        let contentPoint = document.convert(
            CGPoint(x: scrollView.bounds.minX + point.x, y: scrollView.bounds.minY + point.y), from: scrollView
        )
        scrollView.zoom(to: ReaderZoomGeometry.targetRect(
            contentPoint: contentPoint, viewportPoint: point,
            viewportSize: scrollView.bounds.size, scale: targetScale
        ), animated: true)
        await fulfillment(of: [intermediate, completed], timeout: 5)
        XCTAssertEqual(scrollView.zoomScale, targetScale, accuracy: 0.001)
        XCTAssertLessThanOrEqual(controller.collectionView.bounds.width, scrollView.bounds.width * 2)
        XCTAssertLessThanOrEqual(controller.collectionView.bounds.height, scrollView.bounds.height * 2)
    }

    // MARK: - Fixtures

    private func openReader(
        chapters: [Manga.Chapter],
        initial: String,
        pageCount: Int,
        savedPage: Int? = nil,
        windowSize: CGSize = CGSize(width: 390, height: 844),
        scrollView: UIScrollView = UIScrollView()
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
        await subject.viewModel.waitForTestingOperations()
        XCTAssertEqual(subject.viewModel.loadPhase, .content)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: windowSize)
        let controller = MangaContinuousCollectionViewController(
            viewModel: subject.viewModel, onToggleUI: {}, scrollView: scrollView
        )
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
        controller.scrollView.contentOffset = CGPoint(
            x: 0, y: frame.minY * controller.scrollView.zoomScale - pixelOffset
        )
        controller.scrollView.layoutIfNeeded()
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

    /// Answers the page's image request once the session has made it, and by default checks the
    /// renderer applied the size: the session notifies the renderer in the same pass as this test.
    func respond(_ pageID: String, width: Int, height: Int, verifiesLayout: Bool = true) async throws {
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
        guard verifiesLayout else { return }
        // The row is the image's height at the reader's width, rounded down to a whole pixel.
        let scale = controller.traitCollection.displayScale
        let imageHeight = controller.scrollView.bounds.width * CGFloat(height) / CGFloat(width)
        XCTAssertEqual(controller.pageFrame(pageID)?.height, (imageHeight * scale).rounded(.down) / scale)
    }
}

/// UIKit sets deceleration only from a real touch; tests mark the native momentum phase here.
private final class MomentumScrollView: UIScrollView {
    var simulatesDeceleration = false
    override var isDecelerating: Bool { simulatesDeceleration || super.isDecelerating }
}

@MainActor
private final class ContinuousZoomFrameObserver: NSObject {
    var onFrame: (() -> Void)?
    private var displayLink: CADisplayLink?

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(frame))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func frame() { onFrame?() }
}

/// Holds image requests until the test answers them with a PNG of a chosen size. Once a URL is
/// answered, later requests for it get the same image at once: the reader may cancel a request
/// and make it again as cells and prefetch windows change, and the answer must not depend on
/// which of those requests was pending when the test answered.
final class GatedImageLoader: DataLoading, @unchecked Sendable {
    private struct Pending {
        let didReceiveData: @Sendable (Data, URLResponse) -> Void
        let completion: @Sendable (Error?) -> Void
    }

    private let lock = NSLock()
    private var pending: [URL: [Pending]] = [:]
    private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private var requests = 0
    private var answers: [URL: Data] = [:]

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
    ) -> any Nuke.Cancellable {
        guard let url = request.url else {
            completion(URLError(.badURL))
            return GatedImageCancellation()
        }
        let (answer, resumed) = lock.withLock { () -> (Data?, [CheckedContinuation<Void, Never>]) in
            requests += 1
            if let answer = answers[url] { return (answer, []) }
            pending[url, default: []].append(Pending(didReceiveData: didReceiveData, completion: completion))
            return (nil, waiters.removeValue(forKey: url) ?? [])
        }
        if let answer {
            didReceiveData(answer, Self.response(url, answer))
            completion(nil)
        }
        resumed.forEach { $0.resume() }
        return GatedImageCancellation()
    }

    func respond(_ url: URL, width: Int, height: Int) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .pngData { context in
                UIColor.gray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
        let waiting = lock.withLock {
            answers[url] = data
            return pending.removeValue(forKey: url) ?? []
        }
        for request in waiting {
            request.didReceiveData(data, Self.response(url, data))
            request.completion(nil)
        }
    }

    private static func response(_ url: URL, _ data: Data) -> URLResponse {
        URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil)
    }
}

private final class GatedImageCancellation: Nuke.Cancellable, Sendable {
    func cancel() {}
}
