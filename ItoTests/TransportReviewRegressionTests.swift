import AVFoundation
import Foundation
import Nuke
import UIKit
import WebKit
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class TransportReviewRegressionTests: XCTestCase {
    private func fixture(_ purpose: NetworkOperationContext.Purpose = .foregroundReading) -> (ManualNetworkPathObserver, PluginNetworkContexts, NetworkRequestAuthority) {
        let path = ManualNetworkPathObserver(initial: .init(status: .satisfied))
        let policy = NetworkPolicyCenter(path: path)
        policy.enterForeground()
        let contexts = PluginNetworkContexts(epochs: ["fixture": String(repeating: "a", count: 32)], policy: policy)
        let context = contexts.context(pluginID: "fixture", PluginNetworkOperation(purpose: purpose, operationID: UUID()))
        return (path, contexts, NetworkRequestAuthority(contexts: contexts, context: context))
    }

    /// Policy callbacks may arrive more than once for one change (a revoked consent and a scope change).
    private func hookExpectation(_ description: String) -> XCTestExpectation {
        let hook = expectation(description: description)
        hook.assertForOverFulfill = false
        return hook
    }

    func testReaderStartsPagesUnderCurrentPolicyButKeepsSourceAndOperation() async throws {
        let (_, contexts, authority) = fixture()
        let loader = ReviewImageLoader()
        let pipeline = ImagePipeline { $0.dataLoader = loader; $0.imageCache = nil; $0.dataCache = nil }
        let session = ReaderPageImageSession(pipeline: pipeline, sourceAuthority: authority)
        defer { session.deactivate() }
        for index in 0..<3 {
            var configuration = contexts.policy.current
            configuration.preloadImageCount = index == 0 ? 5 : 0
            configuration.downloadMode = index == 2 ? .allowMetered : .unmeteredOnly
            contexts.policy.apply(configuration)
            let page = ReaderPageImageDescriptor(pageID: "\(index)", request: URLRequest(url: URL(string: "https://fixture.invalid/\(index)")!))
            let ready = expectation(description: "page ready under current policy")
            let observation = session.observe(page.key) { if case .ready = $0.phase { ready.fulfill() } }
            _ = session.acquire(page, consumer: .visible)
            await fulfillment(of: [ready], timeout: 5)
            observation.cancel()
        }
        XCTAssertEqual(loader.authorities.count, 3)
        for started in loader.authorities {
            XCTAssertEqual(started.context.authorizationScope, authority.context.authorizationScope)
            XCTAssertEqual(started.context.operationID, authority.context.operationID)
        }
        XCTAssertEqual(loader.authorities.last?.context.policyRevision, contexts.policy.revision)
        contexts.replaceEpochs(["fixture": String(repeating: "b", count: 32)])
        let rebuilt = ImageRequestSourceAuthority.withPurpose(.foregroundReading, authority: authority)
        XCTAssertThrowsError(try rebuilt.check()) { XCTAssertEqual($0 as? HostNetworkPolicyOutcome, .sourceAuthorizationFailure) }
    }

    func testBackgroundQueueScopeChangeRetiresBoundPageAndCancelsReaderImage() async throws {
        let (path, contexts, authority) = fixture()
        let cancelled = expectation(description: "reader image cancelled on scope change")
        let started = expectation(description: "reader image started")
        let loader = ReviewImageLoader(held: true, onStart: { started.fulfill() }, onCancel: { cancelled.fulfill() })
        let pipeline = ImagePipeline { $0.dataLoader = loader; $0.imageCache = nil; $0.dataCache = nil }
        let session = ReaderPageImageSession(pipeline: pipeline, sourceAuthority: authority)
        let page = ReaderPageImageDescriptor(pageID: "held", request: URLRequest(url: URL(string: "https://fixture.invalid/held")!))
        _ = session.acquire(page, consumer: .visible)
        await fulfillment(of: [started], timeout: 5)
        let manager = WebviewManager(authority: authority)
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>bound</p>", script: nil))
        // A path change from the monitor's queue is transient: the page lives, the reader image keeps its transfer.
        let pathHandled = hookExpectation("page handled a background-queue path change")
        manager.onPolicyEvaluation = { pathHandled.fulfill() }
        DispatchQueue.global().async { path.set(.init(status: .unsatisfied)) }
        await fulfillment(of: [pathHandled], timeout: 5)
        XCTAssertFalse(manager.isRetired)
        let retired = hookExpectation("page handled a background-queue scope change")
        manager.onPolicyEvaluation = { retired.fulfill() }
        DispatchQueue.global().async {
            contexts.replaceEpochs(["fixture": String(repeating: "b", count: 32)])
        }
        await fulfillment(of: [cancelled, retired], timeout: 5)
        XCTAssertTrue(manager.isRetired)
        XCTAssertNil(manager.webView)
        withExtendedLifetime(session) {}
    }

    func testLivePageSurvivesBackgroundAndRefusesNewLoadsUntilForeground() async throws {
        let (_, contexts, authority) = fixture()
        let manager = WebviewManager(authority: authority)
        defer { manager.retire(with: CancellationError()) }
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>verification</p>", script: nil))
        let original = manager.webView
        let evaluated = hookExpectation("background evaluated")
        manager.onPolicyEvaluation = { evaluated.fulfill() }
        contexts.policy.enterBackground()
        await fulfillment(of: [evaluated], timeout: 5)
        XCTAssertFalse(manager.isRetired)
        XCTAssertTrue(manager.webView === original)
        do {
            _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,replacement", script: nil))
            XCTFail("A background request must be refused")
        } catch { XCTAssertEqual(error as? HostNetworkPolicyOutcome, .foregroundPermissionRequired) }
        XCTAssertTrue(manager.webView === original)
        contexts.policy.enterForeground()
        let result = try await manager.executeJs(script: "document.body.textContent")
        XCTAssertEqual(result, "verification")
    }

    func testChallengeGatesOnlyHTTPNavigationsAndAllowsLocalFrameSchemes() async throws {
        let (_, contexts, authority) = fixture()
        var results = 0
        let challenge = CloudflareChallenge(
            url: URL(string: "https://fixture.invalid/")!, authority: authority, websites: SourceWebsiteContexts(),
            presentsPage: false, loadPage: { _, _ in }, completion: { _ in results += 1 }
        )
        challenge.start()
        _ = try XCTUnwrap(challenge.webView)
        func decision(_ urlString: String) -> WKNavigationActionPolicy {
            challenge.decideNavigation(to: URL(string: urlString))
        }
        // A challenge page may host about:blank, about:srcdoc, blob: and data: frames; none of them is a request.
        for local in ["about:blank", "about:srcdoc", "blob:https://fixture.invalid/id", "data:text/html,x"] {
            XCTAssertEqual(decision(local), .allow, local)
        }
        XCTAssertEqual(decision("https://fixture.invalid/frame"), .allow)
        XCTAssertEqual(results, 0, "Allowed frames leave the challenge pending")
        // Network navigations keep their rules.
        XCTAssertEqual(decision("http://fixture.invalid/downgrade"), .cancel)
        XCTAssertEqual(results, 1)
        withExtendedLifetime(contexts) {}
    }

    func testChallengeSurvivesBackgroundingAndRefusesNewNetworkNavigations() async throws {
        let (_, contexts, authority) = fixture()
        var results = 0
        let challenge = CloudflareChallenge(
            url: URL(string: "https://fixture.invalid/")!, authority: authority, websites: SourceWebsiteContexts(),
            presentsPage: false, loadPage: { _, _ in }, completion: { _ in results += 1 }
        )
        challenge.start()
        let page = try XCTUnwrap(challenge.webView)
        let evaluated = hookExpectation("challenge background evaluated")
        challenge.onPolicyEvaluation = { evaluated.fulfill() }
        contexts.policy.enterBackground()
        await fulfillment(of: [evaluated], timeout: 5)
        XCTAssertTrue(challenge.webView === page)
        XCTAssertEqual(results, 0)
        XCTAssertEqual(
            challenge.decideNavigation(to: URL(string: "https://fixture.invalid/next")), .cancel,
            "A new request while backgrounded is refused by the interactive check"
        )
        XCTAssertEqual(results, 0, "Refusing that request does not end the verification")
        challenge.finish(.failure(CancellationError()))
        challenge.finish(.failure(CancellationError()))
        XCTAssertEqual(results, 1)
    }

    func testClearBarrierRefusesPagesChallengesAndStoresStartedDuringClear() async throws {
        let (_, contexts, authority) = fixture()
        let websites = SourceWebsiteContexts()
        let existing = WebviewManager(authority: authority, websites: websites)
        websites.beginClearing()
        defer { websites.endClearing() }
        XCTAssertTrue(existing.isRetired)
        XCTAssertThrowsError(try websites.store(for: authority.context))
        let page = WebviewManager(authority: authority, websites: websites)
        XCTAssertTrue(page.isRetired)
        do {
            _ = try await AppWebviewModule(contexts: contexts, websites: websites).loadUrl(
                request: WebviewRequest(url: "data:text/html,no", script: nil), context: authority.context)
            XCTFail("Page started during clear")
        } catch {}
        do {
            _ = try await CloudflareManager(websites: websites).resolveChallenge(for: URL(string: "https://fixture.invalid/")!, authority: authority)
            XCTFail("Challenge started during clear")
        } catch is CancellationError {} catch { XCTFail("Unexpected clear refusal") }
        await websites.clear()
        XCTAssertTrue(websites.isClearing, "Inner website await must not release the outer settings barrier")
    }

    func testModuleKeepsInterleavedOperationPagesUpToTheIdleBound() async throws {
        let (_, contexts, _) = fixture()
        let module = AppWebviewModule(contexts: contexts)
        var operations: [NetworkOperationContext] = []
        for index in 0..<4 {
            let context = contexts.context(pluginID: "fixture", PluginNetworkOperation(purpose: .foregroundReading, operationID: UUID()))
            operations.append(context)
            _ = try await module.loadUrl(request: WebviewRequest(url: "data:text/html,idle", script: nil), context: context)
            XCTAssertEqual(module.retainedPageCount, min(index + 1, 3))
        }
        // An earlier operation's page keeps its document after a later operation ran in between.
        let value = try await module.executeJs(script: "document.body.textContent", context: operations[2])
        XCTAssertEqual(value, "idle")
    }

    func testVideoKeepsBufferedItemOnTransientLossButStopsOnScopeRevocation() async throws {
        let (path, contexts, authority) = fixture()
        let coordinator = AVPlayerVideoPlaybackCoordinator()
        defer { coordinator.shutdown() }
        let item = AVPlayerItem(asset: AVURLAsset(url: URL(fileURLWithPath: "/nonexistent-local-fixture.mp4")))
        let preparation = AVPlayerVideoPlaybackPreparation(item: item, authority: authority)
        XCTAssertTrue(coordinator.activate(preparation, startTime: nil, onTimeUpdate: { _, _ in }))
        let player = try XCTUnwrap((coordinator.surface as? AVPlayerVideoPlaybackSurface)?.player)
        for snapshot in [NetworkPathSnapshot(status: .unsatisfied), .unknown, .init(status: .satisfied)] {
            let evaluated = hookExpectation("video path evaluated")
            coordinator.onPolicyEvaluation = { evaluated.fulfill() }
            path.set(snapshot)
            await fulfillment(of: [evaluated], timeout: 5)
            XCTAssertTrue(player.currentItem === item)
        }
        let refused = expectation(description: "scope refusal delivered")
        coordinator.networkRefusalHandler = { XCTAssertEqual($0, .sourceAuthorizationFailure); refused.fulfill() }
        coordinator.onPolicyEvaluation = nil
        contexts.replaceEpochs(["fixture": String(repeating: "b", count: 32)])
        await fulfillment(of: [refused], timeout: 5)
        XCTAssertNil(player.currentItem)
    }

    func testVideoStopsOnNonTransientExpensivePolicyRefusal() async throws {
        let (path, _, authority) = fixture(.prefetch)
        let coordinator = AVPlayerVideoPlaybackCoordinator()
        defer { coordinator.shutdown() }
        let item = AVPlayerItem(asset: AVURLAsset(url: URL(fileURLWithPath: "/nonexistent-local-fixture.mp4")))
        XCTAssertTrue(coordinator.activate(AVPlayerVideoPlaybackPreparation(item: item, authority: authority), startTime: nil, onTimeUpdate: { _, _ in }))
        let refused = expectation(description: "metered policy refusal delivered")
        coordinator.networkRefusalHandler = { XCTAssertEqual($0, .deferred(.expensivePath)); refused.fulfill() }
        path.set(.init(status: .satisfied, isExpensive: true))
        await fulfillment(of: [refused], timeout: 5)
        XCTAssertNil((coordinator.surface as? AVPlayerVideoPlaybackSurface)?.player.currentItem)
    }
}

private nonisolated let reviewPNG: Data = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
    UIColor.red.setFill()
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
}

private nonisolated final class ReviewImageLoader: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [NetworkRequestAuthority] = []
    private let held: Bool
    private let onStart: @Sendable () -> Void
    private let onCancel: @Sendable () -> Void
    var authorities: [NetworkRequestAuthority] { lock.withLock { captured } }

    init(held: Bool = false, onStart: @escaping @Sendable () -> Void = {}, onCancel: @escaping @Sendable () -> Void = {}) {
        self.held = held
        self.onStart = onStart
        self.onCancel = onCancel
    }

    func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void, completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable {
        do {
            let authority = try XCTUnwrap(ImageRequestSourceAuthority.marked(on: request))
            try authority.checkImageAdmission()
            lock.withLock { captured.append(authority) }
            onStart()
            if !held {
                let bytes = reviewPNG
                didReceiveData(bytes, URLResponse(url: request.url!, mimeType: "image/png", expectedContentLength: bytes.count, textEncodingName: nil))
                completion(nil)
            }
        } catch { completion(error) }
        return ReviewImageCancellation(onCancel)
    }
}

private nonisolated final class ReviewImageCancellation: Cancellable, @unchecked Sendable {
    private let cancelAction: @Sendable () -> Void
    init(_ cancelAction: @escaping @Sendable () -> Void) { self.cancelAction = cancelAction }
    func cancel() { cancelAction() }
}

