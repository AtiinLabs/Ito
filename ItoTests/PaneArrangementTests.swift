import CoreGraphics
import XCTest
@testable import Ito

final class PaneArrangementTests: XCTestCase {
    private let allArrangements: [PaneArrangement] = [.stack, .split, .detailOnly]

    func testPreferredArrangementFollowsWidthClass() {
        XCTAssertEqual(PaneArrangement.preferred(for: .compact), .stack)
        XCTAssertEqual(PaneArrangement.preferred(for: .regular), .stack)
        XCTAssertEqual(PaneArrangement.preferred(for: .wide), .split)
    }

    func testWithoutDetailEveryArrangementMovesToPreferred() {
        for widthClass in [WidthClass.compact, .regular, .wide] {
            for current in allArrangements {
                for isHeld in [false, true] {
                    XCTAssertEqual(
                        PaneArrangement.next(
                            from: current,
                            widthClass: widthClass,
                            hasDetail: false,
                            isDetailHeld: isHeld
                        ),
                        PaneArrangement.preferred(for: widthClass),
                        "current \(current), width \(widthClass), held \(isHeld)"
                    )
                }
            }
        }
    }

    func testUnheldDetailFollowsPreferredArrangement() {
        for current in allArrangements {
            XCTAssertEqual(
                PaneArrangement.next(from: current, widthClass: .wide, hasDetail: true, isDetailHeld: false),
                .split
            )
            XCTAssertEqual(
                PaneArrangement.next(from: current, widthClass: .compact, hasDetail: true, isDetailHeld: false),
                .stack
            )
        }
    }

    func testHeldDetailKeepsStackOnlyWhenAlreadyStackedAndWideWidthHeld() {
        XCTAssertEqual(
            PaneArrangement.next(from: .stack, widthClass: .wide, hasDetail: true, isDetailHeld: true),
            .stack
        )
        XCTAssertEqual(
            PaneArrangement.next(from: .split, widthClass: .wide, hasDetail: true, isDetailHeld: true),
            .split
        )
        XCTAssertEqual(
            PaneArrangement.next(from: .detailOnly, widthClass: .wide, hasDetail: true, isDetailHeld: true),
            .split
        )
    }

    func testHeldDetailFoldsSplitToDetailOnlyInsteadOfStack() {
        for widthClass in [WidthClass.compact, .regular] {
            XCTAssertEqual(
                PaneArrangement.next(from: .split, widthClass: widthClass, hasDetail: true, isDetailHeld: true),
                .detailOnly
            )
            XCTAssertEqual(
                PaneArrangement.next(from: .detailOnly, widthClass: widthClass, hasDetail: true, isDetailHeld: true),
                .detailOnly
            )
            XCTAssertEqual(
                PaneArrangement.next(from: .stack, widthClass: widthClass, hasDetail: true, isDetailHeld: true),
                .stack
            )
        }
    }

    func testReleasedHoldFoldsDetailOnlyToStack() {
        XCTAssertEqual(
            PaneArrangement.next(from: .detailOnly, widthClass: .compact, hasDetail: true, isDetailHeld: false),
            .stack
        )
    }

    func testReparentMatrixMarksOnlyStackSplitTransitions() {
        let reparenting: Set<String> = ["stack->split", "stack->detailOnly", "split->stack", "detailOnly->stack"]
        for previous in allArrangements {
            for next in allArrangements {
                let key = "\(previous)->\(next)"
                XCTAssertEqual(
                    PaneArrangement.reparentsDetail(from: previous, to: next),
                    reparenting.contains(key),
                    key
                )
            }
        }
    }

    func testHoldStateDetailHeldRules() {
        XCTAssertTrue(PaneHoldState(modalHoldCount: 1, isRootCovered: false, isHostVisible: false).isDetailHeld)
        XCTAssertTrue(PaneHoldState(modalHoldCount: 0, isRootCovered: true, isHostVisible: true).isDetailHeld)
        XCTAssertFalse(PaneHoldState(modalHoldCount: 0, isRootCovered: true, isHostVisible: false).isDetailHeld)
        XCTAssertFalse(PaneHoldState(modalHoldCount: 0, isRootCovered: false, isHostVisible: true).isDetailHeld)
    }

    func testDuoSplitFramesMatchDesignNumbers() {
        let frames = PaneMetrics.frames(
            for: .split,
            containerWidth: 951,
            leadingInset: 0,
            trailingInset: 71
        )

        XCTAssertEqual(frames.listWidth, 352)
        XCTAssertEqual(frames.listContentWidth, 352)
        XCTAssertEqual(frames.detailLeading, 353)
        XCTAssertEqual(frames.detailWidth, 598)
        XCTAssertEqual(frames.detailContentWidth, 527)
    }

    func testDuoSplitColumnsAreCompactWidthClass() {
        let frames = PaneMetrics.frames(
            for: .split,
            containerWidth: 951,
            leadingInset: 0,
            trailingInset: 71
        )

        XCTAssertEqual(
            WidthClass.make(size: CGSize(width: frames.listContentWidth, height: 393), verticallyRegular: true),
            .compact
        )
        XCTAssertEqual(
            WidthClass.make(size: CGSize(width: frames.detailContentWidth, height: 393), verticallyRegular: true),
            .compact
        )
    }

    func testStackListSpansContainerWidth() {
        let frames = PaneMetrics.frames(
            for: .stack,
            containerWidth: 951,
            leadingInset: 0,
            trailingInset: 71
        )

        XCTAssertEqual(frames.listWidth, 951)
        XCTAssertEqual(frames.listContentWidth, 880)
        XCTAssertEqual(frames.detailWidth, 0)
    }

    func testDetailOnlyDetailFillsContainer() {
        let frames = PaneMetrics.frames(
            for: .detailOnly,
            containerWidth: 951,
            leadingInset: 0,
            trailingInset: 71
        )

        XCTAssertEqual(frames.detailWidth, 951)
        XCTAssertEqual(frames.detailLeading, 0)
        XCTAssertEqual(frames.detailContentWidth, 880)
    }

    func testListColumnClampsToMinimumAndMaximum() {
        let narrow = PaneMetrics.frames(for: .split, containerWidth: 700, leadingInset: 0, trailingInset: 71)
        let wide = PaneMetrics.frames(for: .split, containerWidth: 1366, leadingInset: 0, trailingInset: 71)

        XCTAssertEqual(narrow.listContentWidth, 340)
        XCTAssertEqual(wide.listContentWidth, 420)
    }

    func testLeadingInsetShiftsSplitBoundary() {
        let frames = PaneMetrics.frames(
            for: .split,
            containerWidth: 951,
            leadingInset: 59,
            trailingInset: 71
        )

        XCTAssertEqual(frames.listWidth, 59 + frames.listContentWidth)
        XCTAssertEqual(frames.detailLeading, frames.listWidth + PaneMetrics.dividerWidth)
        XCTAssertEqual(frames.detailLeading, 400)
        XCTAssertEqual(frames.detailWidth, 951 - 400)
    }

    func testStackLinkRuleClearsOnlyWhenPoppingStackDetail() {
        XCTAssertTrue(PaneStackLinkRule.clearsSelection(whenSetActive: false, arrangement: .stack))
        XCTAssertFalse(PaneStackLinkRule.clearsSelection(whenSetActive: false, arrangement: .split))
        XCTAssertFalse(PaneStackLinkRule.clearsSelection(whenSetActive: false, arrangement: .detailOnly))
        XCTAssertFalse(PaneStackLinkRule.clearsSelection(whenSetActive: true, arrangement: .stack))
        XCTAssertFalse(PaneStackLinkRule.clearsSelection(whenSetActive: true, arrangement: .split))
        XCTAssertFalse(PaneStackLinkRule.clearsSelection(whenSetActive: true, arrangement: .detailOnly))
    }
}
