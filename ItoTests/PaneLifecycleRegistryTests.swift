import XCTest
@testable import Ito

@MainActor
final class PaneLifecycleRegistryTests: XCTestCase {
    private final class Owner {}

    private final class Recorder {
        private(set) var appearCount = 0
        private(set) var disappearCount = 0

        func appear() {
            appearCount += 1
        }

        func disappear() {
            disappearCount += 1
        }
    }

    private var registry: PaneLifecycleRegistry!
    private var owner: Owner!
    private var recorder: Recorder!

    override func setUp() {
        super.setUp()
        registry = PaneLifecycleRegistry()
        owner = Owner()
        recorder = Recorder()
    }

    override func tearDown() {
        registry = nil
        owner = nil
        recorder = nil
        super.tearDown()
    }

    private func install(_ token: UUID) {
        registry.install(
            owner: owner,
            token: token,
            onAppear: recorder.appear,
            onDisappear: recorder.disappear
        )
    }

    func testFirstInstallForwardsAppearOnce() {
        install(UUID())
        install(UUID())

        XCTAssertEqual(recorder.appearCount, 1)
        XCTAssertEqual(recorder.disappearCount, 0)
    }

    func testLastUninstallWithoutHandoverForwardsDisappear() {
        let first = UUID()
        let second = UUID()
        install(first)
        install(second)

        registry.uninstall(owner: owner, token: first)
        XCTAssertEqual(recorder.disappearCount, 0)

        registry.uninstall(owner: owner, token: second)
        XCTAssertEqual(recorder.disappearCount, 1)
        XCTAssertFalse(registry.isPresent(owner))
    }

    func testCoverThenUncoverForwardsDisappearThenAppear() {
        let first = UUID()
        install(first)
        registry.uninstall(owner: owner, token: first)
        install(UUID())

        XCTAssertEqual(recorder.appearCount, 2)
        XCTAssertEqual(recorder.disappearCount, 1)
    }

    func testHandoverUninstallBeforeInstallForwardsNothing() {
        let old = UUID()
        install(old)
        registry.beginHandover()
        registry.uninstall(owner: owner, token: old)
        install(UUID())

        XCTAssertEqual(recorder.appearCount, 1)
        XCTAssertEqual(recorder.disappearCount, 0)
    }

    func testHandoverInstallBeforeUninstallForwardsNothing() {
        let old = UUID()
        install(old)
        registry.beginHandover()
        install(UUID())
        registry.uninstall(owner: owner, token: old)

        XCTAssertEqual(recorder.appearCount, 1)
        XCTAssertEqual(recorder.disappearCount, 0)
        XCTAssertTrue(registry.isPresent(owner))
    }

    func testHandoverWithoutReinstallForwardsOneDisappearOnFlush() {
        let old = UUID()
        install(old)
        registry.beginHandover()
        registry.uninstall(owner: owner, token: old)
        XCTAssertEqual(recorder.disappearCount, 0)

        registry.flushPending()
        XCTAssertEqual(recorder.disappearCount, 1)

        registry.flushPending()
        XCTAssertEqual(recorder.disappearCount, 1)
        XCTAssertFalse(registry.isPresent(owner))
    }

    func testOwnerThatAlreadyDisappearedIsNotPendingForNextHandover() {
        let first = UUID()
        install(first)
        registry.uninstall(owner: owner, token: first)
        XCTAssertEqual(recorder.disappearCount, 1)

        registry.beginHandover()
        install(UUID())

        XCTAssertEqual(recorder.appearCount, 2)
        XCTAssertEqual(recorder.disappearCount, 1)
    }

    func testIsPresentAcrossHandover() {
        XCTAssertFalse(registry.isPresent(owner))

        let old = UUID()
        install(old)
        XCTAssertTrue(registry.isPresent(owner))

        registry.beginHandover()
        XCTAssertTrue(registry.isPresent(owner))

        registry.uninstall(owner: owner, token: old)
        XCTAssertTrue(registry.isPresent(owner))

        let new = UUID()
        install(new)
        XCTAssertTrue(registry.isPresent(owner))

        registry.uninstall(owner: owner, token: new)
        XCTAssertFalse(registry.isPresent(owner))
    }
}
