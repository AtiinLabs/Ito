import SwiftUI
import UIKit
import Nuke
import ito_runner
import XCTest
@testable import Ito

@MainActor
final class ReaderPageImageSessionTests: XCTestCase {
    func testHostedMangaImageRetainsFailureAcrossRemountAndExplicitRetryStartsOnce() async throws {
        let host = "reader-image-session.test"
        ReaderSessionURLProtocol.reset()
        ReaderSessionURLProtocol.register(host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReaderSessionURLProtocol.self]
        let pipeline = ImagePipeline {
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.imageCache = nil
            $0.dataCache = nil
        }
        let session = ReaderPageImageSession(pipeline: pipeline)
        let url = try XCTUnwrap(URL(string: "https://\(host)/page.png"))
        let request = URLRequest(url: url)
        let descriptor = ReaderPageImageDescriptor(pageID: "chapter-page", request: request)
        let failure = expectation(description: "first request reaches terminal failure")
        var observation: ReaderImageObservation? = session.observe(descriptor.key) { state in
            if case .failed = state.phase { failure.fulfill() }
        }

        let image = MangaImage(
            urlStr: url.absoluteString,
            headers: nil,
            session: session,
            pageID: descriptor.pageID,
            interaction: .passive
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIHostingController(rootView: image)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        await fulfillment(of: [failure], timeout: 5)
        XCTAssertEqual(ReaderSessionURLProtocol.requestCount(for: host), 1)

        observation?.cancel()
        observation = nil
        window.isHidden = true
        window.rootViewController = nil
        let remounted = UIHostingController(rootView: image)
        window.makeKeyAndVisible()
        window.rootViewController = remounted
        remounted.view.frame = window.bounds
        remounted.view.layoutIfNeeded()
        let retryLease = session.acquire(descriptor, consumer: .visible)
        // Remounting acquires the page again; the failure stands and nothing restarts.
        if case .failed = session.state(for: descriptor.key).phase {} else {
            XCTFail("A remounted page must keep its failure until Try Again.")
        }
        XCTAssertEqual(ReaderSessionURLProtocol.requestCount(for: host), 1)

        let retryFailure = expectation(description: "explicit retry completes as failed")
        let retryObservation = session.observe(descriptor.key) { state in
            if case .failed = state.phase, state.revision > 0 { retryFailure.fulfill() }
        }
        session.retry(descriptor)
        await fulfillment(of: [retryFailure], timeout: 5)
        XCTAssertEqual(ReaderSessionURLProtocol.requestCount(for: host), 2)
        session.release(retryLease)
        retryObservation.cancel()
        window.isHidden = true
        window.rootViewController = nil
        session.deactivate()
    }

    func testChangedEffectiveHeadersProduceDistinctRequestKeys() throws {
        let url = try XCTUnwrap(URL(string: "https://reader-image-session.test/page.png"))
        var first = URLRequest(url: url)
        first.setValue("first", forHTTPHeaderField: "Authorization")
        var changed = URLRequest(url: url)
        changed.setValue("second", forHTTPHeaderField: "Authorization")

        XCTAssertNotEqual(ReaderPageImageKey(request: first), ReaderPageImageKey(request: changed))
    }

    func testChangedHeadersStartANewAttemptAfterTheOldRequestFailed() async throws {
        let host = "reader-changed-header.test"
        ReaderSessionURLProtocol.register(host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReaderSessionURLProtocol.self]
        let pipeline = ImagePipeline {
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.imageCache = nil
            $0.dataCache = nil
        }
        let session = ReaderPageImageSession(pipeline: pipeline)
        let url = try XCTUnwrap(URL(string: "https://\(host)/page.png"))
        var firstRequest = URLRequest(url: url)
        firstRequest.setValue("first", forHTTPHeaderField: "Authorization")
        var changedRequest = URLRequest(url: url)
        changedRequest.setValue("second", forHTTPHeaderField: "Authorization")
        let first = ReaderPageImageDescriptor(pageID: "page", request: firstRequest)
        let changed = ReaderPageImageDescriptor(pageID: "page", request: changedRequest)

        let firstFailure = expectation(description: "the old headers fail")
        let firstObservation = session.observe(first.key) { state in
            if case .failed = state.phase { firstFailure.fulfill() }
        }
        let firstLease = session.acquire(first, consumer: .visible)
        await fulfillment(of: [firstFailure], timeout: 5)

        // A plugin that refreshed its headers gets a fresh attempt, not the old failure.
        let changedFailure = expectation(description: "the refreshed headers are tried")
        let changedObservation = session.observe(changed.key) { state in
            if case .failed = state.phase { changedFailure.fulfill() }
        }
        let changedLease = session.acquire(changed, consumer: .visible)
        await fulfillment(of: [changedFailure], timeout: 5)
        XCTAssertEqual(ReaderSessionURLProtocol.requestCount(for: host), 2)
        if case .failed = session.state(for: first.key).phase {} else {
            XCTFail("The old headers' failure stays with the old request.")
        }

        session.release(firstLease)
        session.release(changedLease)
        firstObservation.cancel()
        changedObservation.cancel()
        session.deactivate()
    }

    func testPrefetchStartsAtMostTwoPipelineRequestsConcurrently() async throws {
        let starts = expectation(description: "two prefetched requests start")
        starts.expectedFulfillmentCount = 2
        let loader = PendingReaderDataLoader(started: [starts, starts])
        let pipeline = ImagePipeline {
            $0.dataLoader = loader
            $0.imageCache = nil
            $0.dataCache = nil
        }
        let session = ReaderPageImageSession(pipeline: pipeline)
        let descriptors = try (0..<5).map { index in
            ReaderPageImageDescriptor(
                pageID: "prefetch-\(index)",
                request: URLRequest(url: try XCTUnwrap(URL(string: "https://pending-reader.test/\(index).png")))
            )
        }

        session.setPrefetch(descriptors)
        await fulfillment(of: [starts], timeout: 5)
        XCTAssertEqual(loader.startedCount, 2)
        session.deactivate()
        loader.finishAll(with: URLError(.cancelled))
    }

    func testVisibleCancellationReturnsToIdleInsteadOfTerminalFailure() async throws {
        let started = expectation(description: "visible image request starts")
        let loader = PendingReaderDataLoader(started: [started])
        let pipeline = ImagePipeline {
            $0.dataLoader = loader
            $0.imageCache = nil
            $0.dataCache = nil
        }
        let session = ReaderPageImageSession(pipeline: pipeline)
        let descriptor = ReaderPageImageDescriptor(
            pageID: "cancelled-visible",
            request: URLRequest(url: try XCTUnwrap(URL(string: "https://pending-reader.test/cancel.png")))
        )
        let lease = session.acquire(descriptor, consumer: .visible)

        await fulfillment(of: [started], timeout: 5)
        session.release(lease)
        if case .idle = session.state(for: descriptor.key).phase {
            // Cancellation must not become the durable failed state.
        } else {
            XCTFail("A cancelled visible request must return to idle.")
        }
        session.deactivate()
        loader.finishAll(with: URLError(.cancelled))
    }

    func testClearingPrefetchKeepsSharedVisibleAttemptActive() async throws {
        let started = expectation(description: "shared request starts")
        let loader = PendingReaderDataLoader(started: [started])
        let pipeline = ImagePipeline {
            $0.dataLoader = loader
            $0.imageCache = nil
            $0.dataCache = nil
        }
        let session = ReaderPageImageSession(pipeline: pipeline)
        let descriptor = ReaderPageImageDescriptor(
            pageID: "visible-prefetched",
            request: URLRequest(url: try XCTUnwrap(URL(string: "https://pending-reader.test/shared.png")))
        )

        session.setPrefetch([descriptor])
        let visibleLease = session.acquire(descriptor, consumer: .visible)
        await fulfillment(of: [started], timeout: 5)
        session.setPrefetch([])
        XCTAssertEqual(loader.startedCount, 1)
        if case .loading = session.state(for: descriptor.key).phase {
            // Removing prefetch interest leaves the visible lease's task alive.
        } else {
            XCTFail("The visible lease must keep its shared request loading.")
        }
        session.release(visibleLease)
        loader.finishAll(with: URLError(.cancelled))
        session.deactivate()
    }

    func testAFailedPrefetchIsSilentAndAVisibleReadIsAdmittedOnItsOwn() async throws {
        let host = "reader-prefetch-session.test"
        ReaderSessionURLProtocol.register(host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReaderSessionURLProtocol.self]
        let pipeline = ImagePipeline {
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.imageCache = nil
            $0.dataCache = nil
        }
        let session = ReaderPageImageSession(pipeline: pipeline)
        let descriptor = ReaderPageImageDescriptor(
            pageID: "prefetched-page",
            request: URLRequest(url: try XCTUnwrap(URL(string: "https://\(host)/page.png")))
        )
        var sawLoading = false
        let prefetchSettled = expectation(description: "the failed prefetch settles back to idle")
        let visibleFailed = expectation(description: "the visible read fails on its own request")
        let observation = session.observe(descriptor.key) { state in
            switch state.phase {
            case .loading: sawLoading = true
            case .idle where sawLoading: sawLoading = false; prefetchSettled.fulfill()
            case .failed: visibleFailed.fulfill()
            default: break
            }
        }

        session.setPrefetch([descriptor])
        await fulfillment(of: [prefetchSettled], timeout: 5)
        // Speculative work is silent: no one is looking at the page, so its failure is not shown or kept.
        XCTAssertEqual(ReaderSessionURLProtocol.requestCount(for: host), 1)
        if case .idle = session.state(for: descriptor.key).phase {} else {
            XCTFail("A failed prefetch leaves the page startable.")
        }

        // A page the user reaches is read under foreground authority, never from the prefetch's outcome.
        let visibleLease = session.acquire(descriptor, consumer: .visible)
        await fulfillment(of: [visibleFailed], timeout: 5)
        XCTAssertEqual(ReaderSessionURLProtocol.requestCount(for: host), 2)
        session.release(visibleLease)
        observation.cancel()
        session.deactivate()
    }

    func testAPageShownAgainAppearsAtOnceFromMemory() async throws {
        let images = GatedImageLoader()
        let pipeline = ImagePipeline {
            $0.dataLoader = images
            $0.imageCache = ImageCache()
            $0.dataCache = nil
        }
        let session = ReaderPageImageSession(pipeline: pipeline)
        let url = try XCTUnwrap(URL(string: "https://memory-session.test/page.png"))
        let descriptor = ReaderPageImageDescriptor(pageID: "page", request: URLRequest(url: url))
        let ready = expectation(description: "the page loads")
        let observation = session.observe(descriptor.key) { state in
            if case .ready = state.phase { ready.fulfill() }
        }
        let first = session.acquire(descriptor, consumer: .visible)
        await images.waitForRequest(url)
        images.respond(url, width: 300, height: 900)
        await fulfillment(of: [ready], timeout: 5)
        observation.cancel()
        session.release(first)

        // Scrolled back: the decoded image is still in memory, so no spinner and no request.
        let second = session.acquire(descriptor, consumer: .visible)
        if case .ready = session.state(for: descriptor.key).phase {} else {
            XCTFail("A page whose image is in memory must show it at once.")
        }
        XCTAssertEqual(session.knownPixelSize(for: descriptor), CGSize(width: 300, height: 900))
        XCTAssertEqual(images.requestCount, 1)
        session.release(second)
        session.deactivate()
    }

    func testAPrefetchBeforeThePageViewKeepsAMemoryImageInstant() async throws {
        let images = GatedImageLoader()
        let pipeline = ImagePipeline {
            $0.dataLoader = images
            $0.imageCache = ImageCache()
            $0.dataCache = nil
        }
        let session = ReaderPageImageSession(pipeline: pipeline)
        let url = try XCTUnwrap(URL(string: "https://memory-session.test/turned.png"))
        let descriptor = ReaderPageImageDescriptor(pageID: "page", request: URLRequest(url: url))
        let ready = expectation(description: "the page loads")
        let observation = session.observe(descriptor.key) { state in
            if case .ready = state.phase { ready.fulfill() }
        }
        let first = session.acquire(descriptor, consumer: .visible)
        await images.waitForRequest(url)
        images.respond(url, width: 300, height: 900)
        await fulfillment(of: [ready], timeout: 5)
        observation.cancel()
        session.release(first)

        // A page button turns back: the window's prefetch reaches the page before its view does.
        session.setPrefetch([descriptor])
        let second = session.acquire(descriptor, consumer: .visible)
        if case .ready = session.state(for: descriptor.key).phase {} else {
            XCTFail("A prefetch must not hide an image already in memory behind a spinner.")
        }
        XCTAssertEqual(images.requestCount, 1)
        session.release(second)
        session.deactivate()
    }

    func testAVisibleReaderJoinsARunningPrefetchWithoutANewRequest() async throws {
        let loader = ScriptedReaderLoader()
        let session = ReaderPageImageSession(pipeline: scriptedPipeline(loader))
        let descriptor = scriptedDescriptor("joined")
        let started = expectation(description: "the prefetch transfer starts")
        loader.onStart = { _ in started.fulfill() }
        session.setPrefetch([descriptor])
        await fulfillment(of: [started], timeout: 5)

        // Half of the image arrives while the page is only a prefetch.
        let png = ScriptedReaderLoader.pngData()
        loader.receive(png.prefix(png.count / 2), at: 0)
        let ready = expectation(description: "the joined page is ready")
        let observation = session.observe(descriptor.key) { state in
            if case .ready = state.phase { ready.fulfill() }
        }
        let lease = session.acquire(descriptor, consumer: .visible)
        XCTAssertEqual(loader.transferCount, 1, "A visible reader joins the running transfer instead of making a second request")
        XCTAssertEqual(loader.cancelledIndices, [])

        loader.receive(png.dropFirst(png.count / 2), at: 0)
        loader.finish(at: 0)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(loader.transferCount, 1)
        XCTAssertEqual(loader.purpose(at: 0), .prefetch, "The transfer keeps the purpose it started with")
        XCTAssertEqual(session.state(for: descriptor.key).pixelSize, CGSize(width: 300, height: 900))
        observation.cancel()
        session.release(lease)
        session.deactivate()
    }

    func testAJoinedSpeculativeTransferKeepsItsSlotUntilItEnds() async throws {
        let loader = ScriptedReaderLoader()
        let session = ReaderPageImageSession(pipeline: scriptedPipeline(loader))
        let descriptors = (0..<4).map { scriptedDescriptor("slot-joined-\($0)") }
        let twoStarted = expectation(description: "two prefetches start; the third waits for a slot")
        loader.onStart = { count in if count == 2 { twoStarted.fulfill() } }
        session.setPrefetch(descriptors)
        await fulfillment(of: [twoStarted], timeout: 5)

        // The reader joins page 0's speculative transfer, which keeps its prefetch slot.
        let visibleLease = session.acquire(descriptors[0], consumer: .visible)

        // Page 1 ends and frees one slot: page 2 takes it. Page 3 must still wait, because page 0 holds the other
        // slot. Had joining released page 0's slot, page 3 would start in the same turn as page 2.
        let thirdStarted = expectation(description: "the third prefetch takes the freed slot")
        loader.onStart = { count in if count == 3 { thirdStarted.fulfill() } }
        loader.finish(at: loader.index(of: try XCTUnwrap(descriptors[1].request.url)), error: URLError(.networkConnectionLost))
        await fulfillment(of: [thirdStarted], timeout: 5)
        XCTAssertEqual(loader.purpose(at: 2), .prefetch)
        if case .idle = session.state(for: descriptors[3].key).phase {} else {
            XCTFail("A joined preload must keep its slot: page 3 may not start while page 0 still runs.")
        }

        let fourthStarted = expectation(description: "page 3 starts once page 0's transfer ends")
        loader.onStart = { count in if count == 4 { fourthStarted.fulfill() } }

        let ready = expectation(description: "page 0 is ready from its original transfer")
        let readyObservation = session.observe(descriptors[0].key) { state in
            if case .ready = state.phase { ready.fulfill() }
        }
        loader.respond(at: loader.index(of: try XCTUnwrap(descriptors[0].request.url)))
        await fulfillment(of: [ready, fourthStarted], timeout: 5)
        XCTAssertEqual(loader.cancelledIndices, [])
        XCTAssertEqual(loader.transferCount, 4)
        readyObservation.cancel()
        session.release(visibleLease)
        session.deactivate()
    }

    func testAFailedSpeculativeTransferGivesTheWaitingReaderOneForegroundAttempt() async throws {
        let loader = ScriptedReaderLoader()
        let session = ReaderPageImageSession(pipeline: scriptedPipeline(loader))
        let descriptor = scriptedDescriptor("fallback")
        let speculativeStart = expectation(description: "the speculative transfer starts")
        let fallbackStart = expectation(description: "the one foreground attempt starts")
        loader.onStart = { count in
            if count == 1 { speculativeStart.fulfill() } else if count == 2 { fallbackStart.fulfill() }
        }
        var failures = 0
        let terminal = expectation(description: "the fallback's failure is terminal")
        let observation = session.observe(descriptor.key) { state in
            if case .failed = state.phase {
                failures += 1
                terminal.fulfill()
            }
        }

        session.setPrefetch([descriptor])
        await fulfillment(of: [speculativeStart], timeout: 5)
        XCTAssertEqual(loader.purpose(at: 0), .prefetch)
        let lease = session.acquire(descriptor, consumer: .visible)
        XCTAssertEqual(loader.transferCount, 1, "Joining the speculative transfer makes no request")

        loader.finish(at: 0, error: URLError(.cannotConnectToHost))
        await fulfillment(of: [fallbackStart], timeout: 5)
        XCTAssertEqual(failures, 0, "The refused speculative attempt is not published as a failure")
        XCTAssertEqual(loader.purpose(at: 1), .foregroundReading)

        loader.finish(at: 1, error: URLError(.cannotConnectToHost))
        await fulfillment(of: [terminal], timeout: 5)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(loader.transferCount, 2, "One fallback only: its own failure starts no further attempt")
        observation.cancel()
        session.release(lease)
        session.deactivate()
    }

    func testAPolicyChangeToAnExpensivePathCancelsTheSpeculativeTransferAndTheReaderIsServedInTheForeground() async throws {
        let loader = ScriptedReaderLoader()
        let (session, path, _) = makeSourceScenario(loader)
        let descriptor = scriptedDescriptor("flip")
        let speculativeStart = expectation(description: "the speculative transfer starts")
        let fallbackStart = expectation(description: "the foreground attempt starts")
        loader.onStart = { count in
            if count == 1 { speculativeStart.fulfill() } else if count == 2 { fallbackStart.fulfill() }
        }
        let cancelled = expectation(description: "the speculative transfer is cancelled")
        loader.onCancel = { index in if index == 0 { cancelled.fulfill() } }
        var failures = 0
        let ready = expectation(description: "the foreground attempt is ready")
        let observation = session.observe(descriptor.key) { state in
            switch state.phase {
            case .ready: ready.fulfill()
            case .failed: failures += 1
            default: break
            }
        }

        session.setPrefetch([descriptor])
        await fulfillment(of: [speculativeStart], timeout: 5)
        XCTAssertEqual(loader.purpose(at: 0), .prefetch)
        let lease = session.acquire(descriptor, consumer: .visible)

        // Metered now: speculative work is refused, but a person reading the page is not.
        path.set(NetworkPathSnapshot(status: .satisfied, isExpensive: true))
        await fulfillment(of: [cancelled, fallbackStart], timeout: 5)
        XCTAssertEqual(loader.purpose(at: 1), .foregroundReading)
        XCTAssertEqual(failures, 0)

        loader.respond(at: 1)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(loader.transferCount, 2)
        observation.cancel()
        session.release(lease)
        session.deactivate()
    }

    func testWhenBothAttemptsAreRefusedTheReaderFailsTerminallyWithoutATransfer() async throws {
        let loader = ScriptedReaderLoader()
        let (session, path, _) = makeSourceScenario(loader)
        let descriptor = scriptedDescriptor("offline")
        let speculativeStart = expectation(description: "the speculative transfer starts")
        loader.onStart = { count in if count == 1 { speculativeStart.fulfill() } }
        var failures = 0
        let terminal = expectation(description: "the reader fails")
        let observation = session.observe(descriptor.key) { state in
            if case .failed = state.phase {
                failures += 1
                terminal.fulfill()
            }
        }

        session.setPrefetch([descriptor])
        await fulfillment(of: [speculativeStart], timeout: 5)
        let lease = session.acquire(descriptor, consumer: .visible)

        // No connection: the speculative attempt is refused, and so is the foreground attempt that follows it.
        path.set(NetworkPathSnapshot(status: .unsatisfied))
        await fulfillment(of: [terminal], timeout: 5)
        XCTAssertEqual(failures, 1, "Only the terminal failure is published")
        XCTAssertEqual(loader.transferCount, 1, "Only the speculative attempt reached the loader; the fallback was refused")
        observation.cancel()
        session.release(lease)
        session.deactivate()
    }

    func testARevokedSourceNeverBecomesReady() async throws {
        let loader = ScriptedReaderLoader()
        let (session, _, contexts) = makeSourceScenario(loader)
        let descriptor = scriptedDescriptor("revoked")
        let speculativeStart = expectation(description: "the speculative transfer starts")
        loader.onStart = { count in if count == 1 { speculativeStart.fulfill() } }
        let cancelled = expectation(description: "the speculative transfer is cancelled")
        loader.onCancel = { index in if index == 0 { cancelled.fulfill() } }
        var sawReady = false
        let observation = session.observe(descriptor.key) { state in
            if case .ready = state.phase { sawReady = true }
        }

        session.setPrefetch([descriptor])
        await fulfillment(of: [speculativeStart], timeout: 5)
        let lease = session.acquire(descriptor, consumer: .visible)

        // Revocation deactivates the session (observers are dropped), cancelling the speculative transfer.
        contexts.replaceEpochs(["A": String(repeating: "b", count: 32)])
        await fulfillment(of: [cancelled], timeout: 5)
        XCTAssertEqual(loader.transferCount, 1, "A revoked source starts no foreground attempt")
        XCTAssertFalse(sawReady)
        if case .ready = session.state(for: descriptor.key).phase {
            XCTFail("A revoked source's page must not become ready")
        }
        observation.cancel()
        session.release(lease)
        session.deactivate()
    }

    func testReleasingASpeculativeTransferFreesItsSlotForTheNextPage() async throws {
        let loader = ScriptedReaderLoader()
        let session = ReaderPageImageSession(pipeline: scriptedPipeline(loader))
        let descriptors = (0..<3).map { scriptedDescriptor("slot-\($0)") }
        let twoStarted = expectation(description: "two prefetches start")
        loader.onStart = { count in if count == 2 { twoStarted.fulfill() } }
        session.setPrefetch(descriptors)
        await fulfillment(of: [twoStarted], timeout: 5)

        let thirdStarted = expectation(description: "the queued page takes the released slot")
        loader.onStart = { count in if count == 3 { thirdStarted.fulfill() } }
        session.setPrefetch(Array(descriptors[1...]))
        await fulfillment(of: [thirdStarted], timeout: 5)
        XCTAssertEqual(loader.cancelledURLs, [descriptors[0].request.url].compactMap { $0 })
        XCTAssertEqual(loader.purpose(at: 2), .prefetch)
        XCTAssertEqual(loader.transferCount, 3)
        session.deactivate()
    }

    func testDeactivatingAVisibleSpeculativeTransferLeavesNoFallbackAndNoLeakedSlot() async throws {
        let loader = ScriptedReaderLoader()
        let session = ReaderPageImageSession(pipeline: scriptedPipeline(loader))
        let descriptors = (0..<4).map { scriptedDescriptor("late-\($0)") }
        let twoStarted = expectation(description: "two prefetches start")
        loader.onStart = { count in if count == 2 { twoStarted.fulfill() } }
        session.setPrefetch(Array(descriptors[0...1]))
        await fulfillment(of: [twoStarted], timeout: 5)
        let lease = session.acquire(descriptors[0], consumer: .visible)

        let cancelled = expectation(description: "both running transfers are cancelled")
        cancelled.expectedFulfillmentCount = 2
        loader.onCancel = { _ in cancelled.fulfill() }
        session.deactivate()
        await fulfillment(of: [cancelled], timeout: 5)
        loader.onCancel = nil
        // A result that arrives after cancellation is not published, and no fallback starts for it.
        loader.finish(at: 0, error: URLError(.networkConnectionLost))
        XCTAssertEqual(loader.transferCount, 2)
        session.release(lease)

        let freed = expectation(description: "the freed slots start the next two prefetches")
        loader.onStart = { count in if count == 4 { freed.fulfill() } }
        session.setPrefetch(Array(descriptors[2...3]))
        await fulfillment(of: [freed], timeout: 5)
        XCTAssertEqual(loader.purpose(at: 2), .prefetch)
        XCTAssertEqual(loader.purpose(at: 3), .prefetch)
        session.deactivate()
    }

    private func scriptedPipeline(_ loader: ScriptedReaderLoader) -> ImagePipeline {
        ImagePipeline {
            $0.dataLoader = loader
            $0.imageCache = nil
            $0.dataCache = nil
        }
    }

    private func scriptedDescriptor(_ name: String) -> ReaderPageImageDescriptor {
        ReaderPageImageDescriptor(
            pageID: name,
            request: URLRequest(url: URL(string: "https://scripted-reader.test/\(name).png")!)
        )
    }

    /// A session bound to source "A" through the real plugin loader and policy: the path and the source epoch
    /// are the test's to change.
    private func makeSourceScenario(
        _ loader: ScriptedReaderLoader
    ) -> (ReaderPageImageSession, ManualNetworkPathObserver, PluginNetworkContexts) {
        let path = ManualNetworkPathObserver(initial: .init(status: .satisfied))
        let contexts = PluginNetworkContexts(
            epochs: ["A": String(repeating: "a", count: 32)],
            policy: NetworkPolicyCenter(path: path)
        )
        let plugin = PluginDataLoader(
            configuration: .ephemeral,
            contexts: contexts,
            defaultLoader: loader,
            runnerProvider: { _ in throw URLError(.unsupportedURL) }
        )
        let session = ReaderPageImageSession(
            pipeline: ImagePipeline {
                $0.dataLoader = plugin
                $0.imageCache = nil
                $0.dataCache = nil
            },
            sourceAuthority: ImageRequestSourceAuthority.capture(pluginID: "A", contexts: contexts)
        )
        return (session, path, contexts)
    }
}

/// A data loader the test answers by hand. It records each transfer's purpose and the transfers it was asked to
/// cancel, so a test can show which attempt reached the network and which did not.
private final class ScriptedReaderLoader: AuthorizedDataLoading, @unchecked Sendable {
    private struct Transfer {
        let url: URL
        let purpose: NetworkOperationContext.Purpose?
        let receive: @Sendable (Data, URLResponse) -> Void
        let complete: @Sendable (Error?) -> Void
    }

    private let lock = NSLock()
    private var transfers: [Transfer] = []
    private var cancelled: [Int] = []
    private var startHandler: (@Sendable (Int) -> Void)?
    private var cancelHandler: (@Sendable (Int) -> Void)?

    /// Called with the number of transfers started so far, after the transfer is recorded.
    var onStart: (@Sendable (Int) -> Void)? {
        get { lock.withLock { startHandler } }
        set { lock.withLock { startHandler = newValue } }
    }

    /// Called with the index of each transfer cancelled, once.
    var onCancel: (@Sendable (Int) -> Void)? {
        get { lock.withLock { cancelHandler } }
        set { lock.withLock { cancelHandler = newValue } }
    }

    var transferCount: Int { lock.withLock { transfers.count } }
    var cancelledIndices: [Int] { lock.withLock { cancelled } }

    func purpose(at index: Int) -> NetworkOperationContext.Purpose? {
        lock.withLock { transfers[index].purpose }
    }

    /// The index of the first transfer for `url`. Pages started together reach the loader in no fixed order, so
    /// a test that starts several at once must address them by URL, not by start position.
    func index(of url: URL) -> Int {
        lock.withLock { transfers.firstIndex { $0.url == url } ?? -1 }
    }

    var cancelledURLs: [URL] {
        lock.withLock { cancelled.map { transfers[$0].url } }
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        record(request, purpose: ImageRequestPurpose.marked(on: request)?.networkPurpose, receive: didReceiveData, complete: completion)
    }

    func loadData(
        with request: URLRequest,
        authority: NetworkRequestAuthority,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        record(request, purpose: authority.context.purpose, receive: didReceiveData, complete: completion)
    }

    /// Delivers a chunk of the body of transfer `index`.
    func receive(_ chunk: Data, at index: Int) {
        let transfer = lock.withLock { transfers[index] }
        transfer.receive(chunk, URLResponse(url: transfer.url, mimeType: "image/png", expectedContentLength: -1, textEncodingName: nil))
    }

    /// Ends transfer `index`, successfully or with `error`.
    func finish(at index: Int, error: Error? = nil) {
        let transfer = lock.withLock { transfers[index] }
        transfer.complete(error)
    }

    /// Answers transfer `index` with a whole 300 × 900 PNG.
    @MainActor
    func respond(at index: Int) {
        receive(Self.pngData(), at: index)
        finish(at: index)
    }

    @MainActor
    static func pngData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 300, height: 900), format: format).pngData { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 900))
        }
    }

    private func record(
        _ request: URLRequest,
        purpose: NetworkOperationContext.Purpose?,
        receive: @escaping @Sendable (Data, URLResponse) -> Void,
        complete: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        let (index, count, start) = lock.withLock { () -> (Int, Int, (@Sendable (Int) -> Void)?) in
            transfers.append(Transfer(
                url: request.url ?? URL(string: "about:blank")!,
                purpose: purpose,
                receive: receive,
                complete: complete
            ))
            return (transfers.count - 1, transfers.count, startHandler)
        }
        start?(count)
        return ScriptedTransferCancellation { [weak self] in self?.cancel(index) }
    }

    private func cancel(_ index: Int) {
        let handler = lock.withLock { () -> (@Sendable (Int) -> Void)? in
            guard !cancelled.contains(index) else { return nil }
            cancelled.append(index)
            return cancelHandler
        }
        handler?(index)
    }
}

private final class ScriptedTransferCancellation: Cancellable, @unchecked Sendable {
    private let action: @Sendable () -> Void

    init(_ action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    func cancel() {
        action()
    }
}

private final class ReaderSessionURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestsByHost: [String: Int] = [:]
    nonisolated(unsafe) private static var hosts: Set<String> = []

    static func requestCount(for host: String) -> Int {
        lock.withLock { requestsByHost[host, default: 0] }
    }

    static func reset() {
        lock.withLock {
            requestsByHost.removeAll()
            hosts.removeAll()
        }
    }

    static func register(host: String) {
        _ = lock.withLock { hosts.insert(host) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { hosts.contains(host) }
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock {
            let host = request.url?.host ?? ""
            Self.requestsByHost[host, default: 0] += 1
        }
        client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
    }

    override func stopLoading() {}
}

private final class PendingReaderDataLoader: DataLoading, @unchecked Sendable {
    private struct Pending {
        let id: UUID
        let completion: @Sendable (Error?) -> Void
    }

    private let lock = NSLock()
    private var started: [XCTestExpectation]
    private var pending: [Pending] = []

    init(started: [XCTestExpectation]) {
        self.started = started
    }

    var startedCount: Int {
        lock.withLock { pending.count }
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        let id = UUID()
        let event = lock.withLock { () -> XCTestExpectation? in
            pending.append(Pending(id: id, completion: completion))
            return started.isEmpty ? nil : started.removeFirst()
        }
        event?.fulfill()
        return PendingReaderSubscription {}
    }

    func finish(at index: Int, with error: Error?) {
        let completion = lock.withLock { pending[index].completion }
        completion(error)
    }

    func finishAll(with error: Error?) {
        let completions = lock.withLock { pending.map(\.completion) }
        completions.forEach { $0(error) }
    }
}

private final class PendingReaderSubscription: Cancellable, @unchecked Sendable {
    private let onCancel: @Sendable () -> Void
    private let lock = NSLock()
    private var isCancelled = false

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        let shouldCancel = lock.withLock {
            guard !isCancelled else { return false }
            isCancelled = true
            return true
        }
        if shouldCancel { onCancel() }
    }
}
