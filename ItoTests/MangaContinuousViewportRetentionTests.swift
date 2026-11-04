import XCTest
@testable import Ito

@MainActor
final class MangaContinuousViewportRetentionTests: XCTestCase {
    private let pages = ["a#0": 0, "b#0": 1, "c#0": 2]

    func testUnknownLiveViewportDoesNotFallBackToStaleProgress() {
        var registry = MangaContinuousViewportRetentionRegistry()
        let lease = registry.makeLease()
        XCTAssertNil(registry.protectionIDs(fallback: ["c#0"], validPages: pages))
        lease.update([])
        XCTAssertNil(registry.protectionIDs(fallback: ["c#0"], validPages: pages))
        lease.update(["removed#0"])
        XCTAssertNil(registry.protectionIDs(fallback: ["c#0"], validPages: pages))
        lease.update(["a#0", "b#0", "removed#0"])
        XCTAssertEqual(registry.protectionIDs(fallback: ["c#0"], validPages: pages), ["a#0", "b#0"])
    }

    func testOldRendererCannotReplaceOrInvalidateNewViewport() {
        var registry = MangaContinuousViewportRetentionRegistry()
        let old = registry.makeLease()
        old.update(["a#0"])
        let current = registry.makeLease()
        current.update(["b#0"])
        old.update(["c#0"])
        old.invalidate()
        XCTAssertEqual(registry.protectionIDs(fallback: ["c#0"], validPages: pages), ["b#0"])
    }

    func testReleasedNewestRendererDoesNotResurrectOlderViewport() {
        var registry = MangaContinuousViewportRetentionRegistry()
        let old = registry.makeLease()
        old.update(["a#0"])
        var current: MangaContinuousViewportRetention? = registry.makeLease()
        current?.update(["b#0"])
        weak var released = current
        current = nil
        XCTAssertNil(released)
        XCTAssertEqual(registry.protectionIDs(fallback: ["c#0"], validPages: pages), ["c#0"])
        withExtendedLifetime(old) {}
    }

    func testInvalidatedViewportCannotPublishAgain() {
        var registry = MangaContinuousViewportRetentionRegistry()
        let lease = registry.makeLease()
        lease.update(["a#0"])
        lease.invalidate()
        lease.update(["b#0"])
        XCTAssertEqual(registry.protectionIDs(fallback: ["c#0"], validPages: pages), ["c#0"])
        XCTAssertEqual(registry.protectionIDs(fallback: [], validPages: pages), [])
    }
}
