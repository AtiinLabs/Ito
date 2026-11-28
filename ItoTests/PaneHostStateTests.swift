import SwiftUI
import XCTest
@testable import Ito

@MainActor
final class PaneHostStateTests: XCTestCase {
    private final class Owner {}

    private final class CollapseRecorder {
        var arrangements: [PaneArrangement?] = []
    }

    private final class Appearance {
        private(set) var appearCount = 0
        private(set) var disappearCount = 0

        func appear() {
            appearCount += 1
        }

        func disappear() {
            disappearCount += 1
        }
    }

    private func makeRoot(_ state: PaneHostState, key: String = "a") -> RetainedPaneRoot? {
        state.root(for: AnyHashable(key)) { AnyView(EmptyView()) }
    }

    func testUnfoldWithDetailBeginsHandover() {
        let state = PaneHostState()
        state.update(widthClass: .compact, hasDetail: true, willCollapse: {})
        XCTAssertEqual(state.arrangement, .stack)

        let owner = Owner()
        let token = UUID()
        let appearance = Appearance()
        state.lifecycle.install(owner: owner, token: token, onAppear: appearance.appear, onDisappear: appearance.disappear)

        state.update(widthClass: .wide, hasDetail: true, willCollapse: {})
        XCTAssertEqual(state.arrangement, .split)

        state.lifecycle.uninstall(owner: owner, token: token)
        XCTAssertEqual(appearance.disappearCount, 0)

        state.lifecycle.flushPending()
        XCTAssertEqual(appearance.disappearCount, 1)
    }

    func testUnfoldWithoutDetailDoesNotBeginHandover() {
        let state = PaneHostState()
        state.update(widthClass: .compact, hasDetail: false, willCollapse: {})

        let owner = Owner()
        let token = UUID()
        let appearance = Appearance()
        state.lifecycle.install(owner: owner, token: token, onAppear: appearance.appear, onDisappear: appearance.disappear)

        state.update(widthClass: .wide, hasDetail: false, willCollapse: {})
        XCTAssertEqual(state.arrangement, .split)

        state.lifecycle.uninstall(owner: owner, token: token)
        XCTAssertEqual(appearance.disappearCount, 1)
    }

    func testModalHoldDefersUnfoldUntilReleased() {
        let state = PaneHostState()
        state.update(widthClass: .compact, hasDetail: true, willCollapse: {})
        let hold = UUID()

        state.setModalHold(hold, active: true)
        state.update(widthClass: .wide, hasDetail: true, willCollapse: {})
        XCTAssertEqual(state.arrangement, .stack)

        state.setModalHold(hold, active: false)
        XCTAssertEqual(state.arrangement, .split)
    }

    func testFoldWhileHeldGoesDetailOnlyThenStackOnRelease() {
        let state = PaneHostState()
        state.update(widthClass: .wide, hasDetail: true, willCollapse: {})
        XCTAssertEqual(state.arrangement, .split)
        let hold = UUID()

        state.setModalHold(hold, active: true)
        state.update(widthClass: .compact, hasDetail: true, willCollapse: {})
        XCTAssertEqual(state.arrangement, .detailOnly)

        state.setModalHold(hold, active: false)
        XCTAssertEqual(state.arrangement, .stack)
    }

    func testWillCollapseRunsOnlyOnStackTransitionWithDetailBeforePublishing() {
        let state = PaneHostState()
        let recorder = CollapseRecorder()
        let collapse = { [weak state] in
            recorder.arrangements.append(state?.arrangement)
        }

        state.update(widthClass: .wide, hasDetail: true, willCollapse: collapse)
        XCTAssertTrue(recorder.arrangements.isEmpty)

        state.update(widthClass: .compact, hasDetail: true, willCollapse: collapse)
        XCTAssertEqual(recorder.arrangements, [.split])
        XCTAssertEqual(state.arrangement, .stack)

        state.update(widthClass: .compact, hasDetail: false, willCollapse: collapse)
        XCTAssertEqual(recorder.arrangements.count, 1)
    }

    func testHiddenHostIgnoresRootCoverage() {
        let state = PaneHostState()
        state.update(widthClass: .compact, hasDetail: true, willCollapse: {})
        guard let root = makeRoot(state) else {
            return XCTFail("Expected a retained root")
        }
        root.hasAppeared = true
        let token = UUID()
        state.lifecycle.install(owner: root, token: token, onAppear: {}, onDisappear: {})
        state.lifecycle.uninstall(owner: root, token: token)
        state.rootPresenceDidChange()
        XCTAssertTrue(state.isRootCovered)

        state.update(widthClass: .wide, hasDetail: true, willCollapse: {})
        XCTAssertEqual(state.arrangement, .split)
    }

    func testVisibleHostHoldsDetailWhileRootIsCovered() {
        let state = PaneHostState()
        state.update(widthClass: .compact, hasDetail: true, willCollapse: {})
        state.hostVisibilityDidChange(true)
        guard let root = makeRoot(state) else {
            return XCTFail("Expected a retained root")
        }
        root.hasAppeared = true
        let token = UUID()
        state.lifecycle.install(owner: root, token: token, onAppear: {}, onDisappear: {})
        state.lifecycle.uninstall(owner: root, token: token)
        state.rootPresenceDidChange()
        XCTAssertTrue(state.isRootCovered)

        state.update(widthClass: .wide, hasDetail: true, willCollapse: {})
        XCTAssertEqual(state.arrangement, .stack)
    }

    func testSameKeyReusesCachedRoot() {
        let state = PaneHostState()
        var made = 0
        let first = state.root(for: AnyHashable("a")) {
            made += 1
            return AnyView(EmptyView())
        }
        let second = state.root(for: AnyHashable("a")) {
            made += 1
            return AnyView(EmptyView())
        }

        XCTAssertTrue(first === second)
        XCTAssertEqual(made, 1)
    }

    func testNilKeyReleasesCurrentRoot() {
        let state = PaneHostState()
        let first = makeRoot(state)

        XCTAssertNil(state.root(for: nil))
        XCTAssertEqual(first?.isReleased, true)
        XCTAssertNil(state.currentRoot)
    }

    func testReselectingReleasedKeyRebuildsRoot() {
        let state = PaneHostState()
        var made = 0
        let build = {
            made += 1
            return AnyView(EmptyView())
        }
        _ = state.root(for: AnyHashable("a"), make: build)
        XCTAssertNil(state.root(for: nil))

        let rebuilt = state.root(for: AnyHashable("a"), make: build)

        XCTAssertEqual(made, 2)
        XCTAssertEqual(rebuilt?.isReleased, false)
    }
}
