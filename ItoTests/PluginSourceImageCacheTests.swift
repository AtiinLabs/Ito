import Foundation
import Nuke
import XCTest
import UIKit
import ito_runner
@testable import Ito

@MainActor
final class PluginSourceImageCacheTests: XCTestCase {
    func testProductionSourceCacheRetainsPrefetchForImmediateVisibleAcquire() async throws {
        let fixture = makeFixture()
        let descriptor = try fixture.descriptor("retained")
        let completed = expectation(description: "prefetch completion publishes idle dimensions")
        let observation = fixture.session.observe(descriptor.key) { state in
            guard state.pixelSize == CGSize(width: 300, height: 900), case .idle = state.phase else { return }
            completed.fulfill()
        }

        fixture.session.setPrefetch([descriptor])
        fixture.loader.respond(try XCTUnwrap(descriptor.request.url), width: 300, height: 900)
        await fulfillment(of: [completed], timeout: 5)
        // Releasing the visible lease below publishes `.idle` again; this observation was for the prefetch only.
        observation.cancel()

        XCTAssertEqual(fixture.cache.entryCostLimit, 1.0)
        XCTAssertGreaterThan(fixture.cache.totalCost, Int(Double(fixture.cache.costLimit) * 0.1))
        XCTAssertLessThan(fixture.cache.totalCost, fixture.cache.costLimit)
        fixture.session.setPrefetch([])
        let visible = fixture.session.acquire(descriptor, consumer: .visible)
        guard case .ready(let image) = fixture.session.state(for: descriptor.key).phase else {
            XCTFail("A prefetched source image below the total cache budget must be immediately ready.")
            return
        }
        XCTAssertEqual(image.size, CGSize(width: 300, height: 900))
        XCTAssertEqual(fixture.loader.requestCount, 1)
        fixture.session.release(visible)
        fixture.session.deactivate()
    }

    func testSourceCacheKeepsTotalBudgetAndEvictsLeastRecentlyUsedPage() async throws {
        let fixture = makeFixture()
        let first = try fixture.descriptor("first")
        let second = try fixture.descriptor("second")
        let third = try fixture.descriptor("third")
        let fourth = try fixture.descriptor("fourth")

        // Budget for three of these images but not four, from the cost the cache actually charged for one,
        // so the test does not depend on the decoded pixel format.
        try await fixture.prefetch(first)
        XCTAssertEqual(fixture.cache.totalCount, 1)
        let cost = fixture.cache.totalCost
        XCTAssertGreaterThan(cost, 0)
        fixture.cache.costLimit = 3 * cost + cost / 2
        XCTAssertGreaterThan(cost, Int(Double(fixture.cache.costLimit) * 0.1), "Each image exceeds Nuke's default per-entry share.")

        for descriptor in [second, third] {
            try await fixture.prefetch(descriptor)
            XCTAssertLessThanOrEqual(fixture.cache.totalCost, fixture.cache.costLimit)
        }
        XCTAssertEqual(fixture.cache.totalCount, 3)
        let touch = fixture.session.acquire(first, consumer: .visible)
        guard case .ready = fixture.session.state(for: first.key).phase else {
            XCTFail("The first page should remain cached before the overflow.")
            return
        }
        fixture.session.release(touch)

        try await fixture.prefetch(fourth)
        XCTAssertLessThanOrEqual(fixture.cache.totalCost, fixture.cache.costLimit)
        XCTAssertEqual(fixture.cache.totalCount, 3, "Four images exceed a budget sized for three and a half.")

        let retained = fixture.session.acquire(first, consumer: .visible)
        guard case .ready = fixture.session.state(for: first.key).phase else {
            XCTFail("The recently used page should survive LRU eviction.")
            return
        }
        fixture.session.release(retained)

        let victim = try await fixture.reload(second)
        XCTAssertEqual(fixture.loader.requestCount, 5, "The least-recently-used page should require a new transfer.")
        fixture.session.release(victim)
        fixture.session.deactivate()
    }

    func testExplicitRestrictiveSourceCacheIsNotChanged() async throws {
        let cache = ImageCache(costLimit: 2 * 1024 * 1024)
        cache.entryCostLimit = 0.1
        let fixture = makeFixture(cache: cache)
        let descriptor = try fixture.descriptor("restrictive")
        try await fixture.prefetch(descriptor)
        XCTAssertEqual(cache.entryCostLimit, 0.1)
        XCTAssertEqual(cache.totalCost, 0)

        let visible = try await fixture.reload(descriptor)
        XCTAssertEqual(fixture.loader.requestCount, 2, "An explicitly injected restrictive cache remains restrictive.")
        fixture.session.release(visible)
        fixture.session.deactivate()
    }

    func testClearPluginMemoryCacheForcesSourceImageReload() async throws {
        let fixture = makeFixture()
        let descriptor = try fixture.descriptor("cleared")
        try await fixture.prefetch(descriptor)
        fixture.controller.clearPluginMemoryCache()

        let visible = try await fixture.reload(descriptor)
        XCTAssertEqual(fixture.loader.requestCount, 2)
        fixture.session.release(visible)
        fixture.session.deactivate()
    }

    private func makeFixture(cache: ImageCache? = nil) -> SourceCacheFixture {
        let loader = GatedImageLoader()
        let sourceCache: ImageCache
        if let cache {
            sourceCache = cache
        } else {
            sourceCache = PluginImagePipelineController.makeSourceMemoryCache()
            sourceCache.costLimit = 2 * 1024 * 1024
        }
        let contexts = PluginNetworkContexts(
            epochs: ["cache-source": String(repeating: "a", count: 32)],
            policy: NetworkPolicyCenter(path: ManualNetworkPathObserver(initial: .init(status: .satisfied)))
        )
        let recorder = SourceCachePipelineRecorder()
        let controller = PluginImagePipelineController(
            dataCache: nil,
            dataLoader: loader,
            diagnostics: NukeDiagnosticDelegate(),
            publish: { recorder.record($0) },
            contexts: contexts,
            sourceMemory: sourceCache
        )
        controller.install(epoch: String(repeating: "b", count: 32))
        let pipeline = recorder.latest!
        let session = ReaderPageImageSession.sourceBound(pluginID: "cache-source", contexts: contexts, pipeline: pipeline)
        return SourceCacheFixture(loader: loader, cache: sourceCache, controller: controller, session: session)
    }
}

@MainActor
private struct SourceCacheFixture {
    let loader: GatedImageLoader
    let cache: ImageCache
    let controller: PluginImagePipelineController
    let session: ReaderPageImageSession

    func descriptor(_ name: String) throws -> ReaderPageImageDescriptor {
        let url = try XCTUnwrap(URL(string: "https://source-cache.test/\(name).png"))
        return ReaderPageImageDescriptor(pageID: name, request: URLRequest(url: url))
    }

    func prefetch(_ descriptor: ReaderPageImageDescriptor) async throws {
        let url = try XCTUnwrap(descriptor.request.url)
        let completed = XCTestExpectation(description: "prefetch for \(descriptor.pageID) publishes idle dimensions")
        let observation = session.observe(descriptor.key) { state in
            guard state.pixelSize == CGSize(width: 300, height: 900), case .idle = state.phase else { return }
            completed.fulfill()
        }
        session.setPrefetch([descriptor])
        loader.respond(url, width: 300, height: 900)
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(result, .completed)
        observation.cancel()
        session.setPrefetch([])
    }

    func reload(_ descriptor: ReaderPageImageDescriptor) async throws -> ReaderImageLease {
        let ready = XCTestExpectation(description: "a cache miss reloads \(descriptor.pageID)")
        let observation = session.observe(descriptor.key) { state in
            if case .ready = state.phase { ready.fulfill() }
        }
        let lease = session.acquire(descriptor, consumer: .visible)
        if case .loading = session.state(for: descriptor.key).phase {} else {
            XCTFail("An evicted source image must reload instead of using stale memory.")
        }
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(result, .completed)
        observation.cancel()
        return lease
    }
}

private final class SourceCachePipelineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pipeline: ImagePipeline?
    var latest: ImagePipeline? { lock.withLock { pipeline } }
    func record(_ pipeline: ImagePipeline) { lock.withLock { self.pipeline = pipeline } }
}
