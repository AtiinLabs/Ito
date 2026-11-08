import SwiftUI
import UIKit
import XCTest
@testable import Ito

@MainActor
final class MangaPagedReaderControllerTests: XCTestCase {
    private var window: UIWindow?
    private var reported: [Int] = []

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    func testButtonPressesShowThatPageAndChapterChangesStartOver() throws {
        let controller = try mount(configuration(chapter: "a", index: 0))
        XCTAssertEqual(shownPosition(controller), 0)

        // A footer button changes the reader's index; the pager slides to exactly that page.
        controller.update(with: configuration(chapter: "a", index: 1))
        waitUntilShown(1, controller)
        controller.update(with: configuration(chapter: "a", index: 3))
        waitUntilShown(3, controller)
        controller.update(with: configuration(chapter: "a", index: 2))
        waitUntilShown(2, controller)
        let pageOfA = try XCTUnwrap(pager(controller).viewControllers?.first)

        // Another chapter shows a new page at that position, not the one kept from the last chapter.
        controller.update(with: configuration(chapter: "b", index: 2))
        waitUntilShown(2, controller)
        XCTAssertFalse(try XCTUnwrap(pager(controller).viewControllers?.first) === pageOfA)
        XCTAssertEqual(reported, [], "Index changes made by the reader are not reported back")
    }

    func testPressesDuringSlidesLandOnTheNewestPage() throws {
        let controller = try mount(configuration(chapter: "a", index: 0))
        controller.update(with: configuration(chapter: "a", index: 1))
        XCTAssertTrue(controller.isTransitioning)
        // Pressed twice more while the first slide is still moving: the pager waits, then
        // slides on to the newest page instead of replacing pages mid-slide.
        controller.update(with: configuration(chapter: "a", index: 2))
        controller.update(with: configuration(chapter: "a", index: 3))
        XCTAssertEqual(shownPosition(controller), 1)
        waitUntilShown(3, controller)
        XCTAssertEqual(reported, [], "Slides the reader asked for are not reported back as swipes")
    }

    func testASwipeStartedDuringASlideKeepsThePagerWaitingUntilItEnds() throws {
        let controller = try mount(configuration(chapter: "a", index: 0))
        let pager = try pager(controller)
        controller.update(with: configuration(chapter: "a", index: 1))
        XCTAssertTrue(controller.isSliding)
        let current = try XCTUnwrap(pager.viewControllers?.first)
        let next = try XCTUnwrap(controller.pageViewController(pager, viewControllerAfter: current))
        controller.pageViewController(pager, willTransitionTo: [next])

        // The slide finishing must not end the swipe: the reader's next page waits for it.
        let slideEnded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !controller.isSliding }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [slideEnded], timeout: 5), .completed)
        XCTAssertTrue(controller.isTransitioning)
        controller.update(with: configuration(chapter: "a", index: 2))
        XCTAssertEqual(shownPosition(controller), 1)

        controller.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [current], transitionCompleted: false)
        waitUntilShown(2, controller)
        XCTAssertEqual(reported, [])
    }

    func testASlideOwnsThePagerUntilItEnds() throws {
        let controller = try mount(configuration(chapter: "a", index: 0))
        let pager = try pager(controller)
        controller.update(with: configuration(chapter: "a", index: 1))
        // A finger cannot start a swipe while a button's slide moves the pager.
        XCTAssertFalse(pager.view.isUserInteractionEnabled)
        let shown = try XCTUnwrap(pager.viewControllers?.first)
        let other = try XCTUnwrap(controller.pageViewController(pager, viewControllerAfter: shown))
        // Even if a swipe completed meanwhile, its page is not reported over the slide's page.
        controller.pageViewController(pager, willTransitionTo: [other])
        controller.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [shown], transitionCompleted: true)
        XCTAssertEqual(reported, [])
        waitUntilShown(1, controller)
        XCTAssertTrue(pager.view.isUserInteractionEnabled)
    }

    func testAPagePressDuringASwipeWinsOverTheSwipe() throws {
        let controller = try mount(configuration(chapter: "a", index: 1))
        let pager = try pager(controller)
        let start = try XCTUnwrap(pager.viewControllers?.first)
        let swiped = try XCTUnwrap(controller.pageViewController(pager, viewControllerBefore: start))
        controller.pageViewController(pager, willTransitionTo: [swiped])
        // The reader moves on while the finger is still down; the pager waits for the swipe.
        controller.update(with: configuration(chapter: "a", index: 2))
        XCTAssertTrue(pager.viewControllers?.first === start)
        pager.setViewControllers([swiped], direction: .reverse, animated: false)
        controller.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [start], transitionCompleted: true)
        XCTAssertEqual(reported, [], "The swipe's page must not overwrite the reader's newer page")
        waitUntilShown(2, controller)
    }

    func testNeighboursFollowReadingDirectionAndChapterEdges() throws {
        let controller = try mount(configuration(chapter: "a", index: 0, hasPrevious: true, hasNext: true))
        let pager = try pager(controller)
        let first = try XCTUnwrap(pager.viewControllers?.first)
        // Left to right: the next page is after, the previous chapter's loading page before.
        XCTAssertEqual(position(controller.pageViewController(pager, viewControllerAfter: first)), 1)
        XCTAssertEqual(position(controller.pageViewController(pager, viewControllerBefore: first)), -1)

        controller.update(with: configuration(chapter: "a", index: 3, hasPrevious: false, hasNext: false))
        let last = try XCTUnwrap(pager.viewControllers?.first)
        XCTAssertNil(controller.pageViewController(pager, viewControllerAfter: last))

        // Right to left: the next page is on the left.
        controller.update(with: configuration(chapter: "r", index: 1, rightToLeft: true))
        let middle = try XCTUnwrap(pager.viewControllers?.first)
        XCTAssertEqual(position(controller.pageViewController(pager, viewControllerBefore: middle)), 2)
        XCTAssertEqual(position(controller.pageViewController(pager, viewControllerAfter: middle)), 0)
    }

    func testCompletedSwipeReportsTheLandedPageOnce() throws {
        let controller = try mount(configuration(chapter: "a", index: 0))
        let pager = try pager(controller)
        let first = try XCTUnwrap(pager.viewControllers?.first)
        let next = try XCTUnwrap(controller.pageViewController(pager, viewControllerAfter: first))
        pager.setViewControllers([next], direction: .forward, animated: false)

        controller.pageViewController(pager, willTransitionTo: [next])
        controller.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [first], transitionCompleted: false)
        XCTAssertEqual(reported, [], "A cancelled swipe changes nothing")
        controller.pageViewController(pager, willTransitionTo: [next])
        controller.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [first], transitionCompleted: true)
        XCTAssertEqual(reported, [1])
        // The reader then publishes that index; it is already shown and is not set again.
        controller.update(with: configuration(chapter: "a", index: 1))
        XCTAssertTrue(pager.viewControllers?.first === next)
    }

    // MARK: - Fixtures

    /// Waits until `position` is shown and no slide is still moving.
    private func waitUntilShown(_ position: Int, _ controller: MangaPagedReaderController) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.shownPosition(controller) == position && !controller.isTransitioning
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed, "Page \(position) never shown")
    }

    private func configuration(
        chapter: String,
        index: Int,
        hasPrevious: Bool = false,
        hasNext: Bool = false,
        rightToLeft: Bool = false
    ) -> MangaPagedReaderView<Text> {
        MangaPagedReaderView(
            chapterKey: chapter,
            pageCount: 4,
            hasPrevious: hasPrevious,
            hasNext: hasNext,
            index: index,
            isRightToLeft: rightToLeft,
            content: { position in Text("\(chapter)#\(position)") },
            onIndexChange: { [weak self] in self?.reported.append($0) }
        )
    }

    private func mount(_ configuration: MangaPagedReaderView<Text>) throws -> MangaPagedReaderController {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let controller = MangaPagedReaderController()
        controller.update(with: configuration)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        self.window = window
        return controller
    }

    private func pager(_ controller: MangaPagedReaderController) throws -> UIPageViewController {
        try XCTUnwrap(controller.children.first as? UIPageViewController)
    }

    private func shownPosition(_ controller: MangaPagedReaderController) -> Int? {
        position(controller.children.first.flatMap { ($0 as? UIPageViewController)?.viewControllers?.first })
    }

    private func position(_ viewController: UIViewController?) -> Int? {
        (viewController as? MangaPagedPageHost)?.position
    }
}
