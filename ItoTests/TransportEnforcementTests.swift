import Combine
import Foundation
import Nuke
import WebKit
import XCTest
import ito_runner
@testable import Ito

/// No endpoint is contacted. Admission and redirect callbacks are driven explicitly.
final class TransportEnforcementTests: XCTestCase {
    func testPrefetchCannotBorrowForegroundOrBatchAuthority() throws {
        let path = ManualNetworkPathObserver(initial: .init(status: .satisfied, isExpensive: true))
        var configuration = NetworkPolicyConfiguration.defaults
        configuration.downloadMode = .askMetered
        let policy = NetworkPolicyCenter(configuration: configuration, path: path)
        policy.enterForeground()
        let contexts = PluginNetworkContexts(policy: policy)
        let batch = UUID()
        let binding = contexts.consentBinding(batchID: batch, pluginID: "fixture")
        XCTAssertNotNil(policy.mintBatchConsent(binding))
        let bulk = authority(contexts, .manualBulkDownload, batch: batch)
        try bulk.check()
        try authority(contexts, .foregroundReading).check()
        assertRefusal(.deferred(.expensivePath)) { try self.authority(contexts, .prefetch, batch: batch).check() }
        // Reconfirming the same stored batch creates a different capability incarnation. The old attempt cannot
        // borrow it just because the batch ID still matches.
        XCTAssertNotNil(policy.mintBatchConsent(binding))
        assertRefusal(.deferred(.expensivePath)) { try bulk.check() }
        assertRefusal(.deferred(.expensivePath)) { try self.authority(contexts, .manualBulkDownload, batch: UUID()).check() }
    }

    func testRetryRetainsRevisionAndSourceScope() throws {
        let contexts = makeContexts()
        let frozen = authority(contexts, .foregroundReading)
        try frozen.check()
        var changed = contexts.policy.current
        changed.preloadImageCount = 0
        contexts.policy.apply(changed)
        assertRefusal(.deferred(.policyChanged)) { try frozen.check() }
        // A new operation may be admitted; a retry of the original cannot acquire its revision.
        try authority(contexts, .foregroundReading).check()
        let accountBound = authority(contexts, .foregroundReading)
        contexts.replaceEpochs([:])
        assertRefusal(.sourceAuthorizationFailure) { try accountBound.check() }
    }

    func testRedirectRechecksAuthorityBeforeFollowing() throws {
        let path = ManualNetworkPathObserver(initial: .init(status: .satisfied))
        let contexts = makeContexts(path: path)
        let frozen = authority(contexts, .prefetch)
        try frozen.check()
        path.set(.init(status: .satisfied, isConstrained: true))
        let delegate = AppNetCookieRedirects(
            originalHost: "fixture.invalid", explicitCookies: nil, storedCookies: { _ in [] }, keep: { _ in },
            pluginID: "fixture", trust: nil, admission: { try frozen.check() }
        )
        let url = try XCTUnwrap(URL(string: "https://fixture.invalid/image"))
        let request = URLRequest(url: url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil))
        let result = RedirectResult()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // Not resumed: this task exists only to invoke the delegate deterministically.
        let task = session.dataTask(with: request)
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
            result.set($0)
        }
        XCTAssertTrue(result.wasCalled)
        XCTAssertNil(result.request)
        XCTAssertEqual(delegate.policyError as? HostNetworkPolicyOutcome, .deferred(.constrainedPath))
    }

    func testImageCancellationSettlesOnlyItsOwner() {
        let contexts = makeContexts()
        let received = CompletionCounts()
        let cancelled = AdmittedImageLoad(authority: authority(contexts, .foregroundReading)) { _ in received.increment(0) }
        let remaining = AdmittedImageLoad(authority: authority(contexts, .foregroundReading)) { _ in received.increment(1) }
        cancelled.cancel()
        cancelled.complete(nil)
        remaining.complete(nil)
        remaining.complete(nil)
        XCTAssertEqual(received.values, [0, 1])
    }

    func testImageRevocationSettlesOnceWithoutUpgradingPurpose() {
        let path = ManualNetworkPathObserver(initial: .init(status: .satisfied))
        let contexts = makeContexts(path: path)
        let received = CompletionCounts()
        let prefetch = AdmittedImageLoad(authority: authority(contexts, .prefetch)) { _ in received.increment(0) }
        let visible = AdmittedImageLoad(authority: authority(contexts, .foregroundReading)) { _ in received.increment(1) }
        path.set(.init(status: .satisfied, isExpensive: true))
        prefetch.complete(nil)
        XCTAssertEqual(received.values, [1, 0])
        visible.complete(nil)
        XCTAssertEqual(received.values, [1, 1])
    }

    @MainActor
    func testBackgroundChallengeRefusesWithoutCreatingAPage() async throws {
        let contexts = makeContexts()
        let module = AppWebviewModule(contexts: contexts)
        let context = authority(contexts, .automaticLibraryUpdate).context
        do {
            _ = try await module.loadUrl(request: WebviewRequest(url: "https://fixture.invalid/", script: nil), context: context)
            XCTFail("A background export must not create a web page")
        } catch {
            XCTAssertEqual(error as? HostNetworkPolicyOutcome, .foregroundPermissionRequired)
        }
    }

    @MainActor
    func testWebsiteDataAndRetirementAreScoped() async {
        let contexts = makeContexts()
        let first = authority(contexts, .foregroundReading).context
        let second = contexts.context(pluginID: "other", PluginNetworkOperation(purpose: .foregroundReading, operationID: UUID()))
        let websites = SourceWebsiteContexts()
        XCTAssertTrue(websites.store(for: first) === websites.store(for: first))
        XCTAssertFalse(websites.store(for: first) === websites.store(for: second))
        var ended: [Int] = []
        let detached = websites.observeRetirement { ended.append(0) }
        _ = websites.observeRetirement { ended.append(1) }
        websites.removeObserver(detached)
        await websites.clear()
        XCTAssertEqual(ended, [1])
    }

    @MainActor
    func testVideoRefusalIsTypedBeforeAssetCreation() async {
        let path = ManualNetworkPathObserver(initial: .init(status: .unsatisfied))
        let coordinator = AVPlayerVideoPlaybackCoordinator()
        do {
            let fixtureVideo = video("https://fixture.invalid/stream.m3u8")
            _ = try await coordinator.prepare(video: fixtureVideo, authority: authority(makeContexts(path: path), .foregroundReading))
            XCTFail("An offline asset must not be constructed")
        } catch {
            XCTAssertEqual(error as? HostNetworkPolicyOutcome, .deferred(.offline))
        }
        XCTAssertNil(coordinator.surface)
    }

    @MainActor
    func testTrackerDeferralIsNotAcknowledgmentOrUnknownWriteFailure() {
        var report = TrackerManager.ProgressUpdateReport()
        report.recordFailure(providerID: "anilist", error: HostNetworkPolicyOutcome.deferred(.offline))
        report.recordFailure(providerID: "mal", error: URLError(.networkConnectionLost))
        XCTAssertTrue(report.sent.isEmpty)
        XCTAssertEqual(report.deferred, ["anilist"])
        XCTAssertEqual(report.failed, ["mal"])
    }

    func testZeroEffectiveImagePreloadRefusesSpeculativeResolution() {
        let contexts = makeContexts()
        var configured = contexts.policy.current
        configured.preloadImageCount = 0
        contexts.policy.apply(configured)
        assertRefusal(.deferred(.policyChanged)) {
            try self.authority(contexts, .prefetch).checkImageAdmission()
        }
        XCTAssertNoThrow(try authority(contexts, .foregroundReading).checkImageAdmission())
    }

    func testProductionPipelineDoesNotCoalesceDifferentAuthoritiesByURL() throws {
        let published = PipelineCapture()
        let controller = PluginImagePipelineController(
            dataCache: nil,
            dataLoader: PolicyDataLoader(configuration: .ephemeral),
            diagnostics: EmptyImageDiagnostics(),
            publish: { published.set($0) }
        )
        controller.install(epoch: String(repeating: "a", count: 32))
        let pipeline = try XCTUnwrap(published.pipeline)
        XCTAssertFalse(pipeline.configuration.isTaskCoalescingEnabled)
    }

    func testSourceRotationCancelsOnlyRequestsBoundToThatScope() {
        let otherEpoch = String(repeating: "b", count: 32)
        let epochs = ["fixture": String(repeating: "a", count: 32), "other": otherEpoch]
        let contexts = PluginNetworkContexts(epochs: epochs, policy: NetworkPolicyCenter(path: ManualNetworkPathObserver(initial: .init(status: .satisfied))))
        let received = CompletionCounts()
        let first = AdmittedImageLoad(authority: authority(contexts, .foregroundReading)) { _ in received.increment(0) }
        let other = NetworkRequestAuthority(
            contexts: contexts,
            context: contexts.context(pluginID: "other", PluginNetworkOperation(purpose: .foregroundReading, operationID: UUID()))
        )
        let second = AdmittedImageLoad(authority: other) { _ in received.increment(1) }
        contexts.replaceEpochs(["fixture": String(repeating: "c", count: 32), "other": otherEpoch])
        first.complete(nil)
        XCTAssertEqual(received.values, [1, 0])
        second.complete(nil)
        XCTAssertEqual(received.values, [1, 1])
    }

    private func makeContexts(path: ManualNetworkPathObserver = ManualNetworkPathObserver(initial: .init(status: .satisfied))) -> PluginNetworkContexts {
        PluginNetworkContexts(policy: NetworkPolicyCenter(path: path))
    }

    private func authority(_ contexts: PluginNetworkContexts, _ purpose: NetworkOperationContext.Purpose, batch: UUID? = nil) -> NetworkRequestAuthority {
        var operation = PluginNetworkOperation(purpose: purpose, operationID: UUID(), batchID: batch)
        if purpose == .manualBulkDownload || purpose == .automaticBulkDownload, let batch {
            operation.scopedGrant = contexts.policy.authorizeBatchOperation(
                contexts.consentBinding(batchID: batch, pluginID: "fixture"),
                operationID: operation.operationID
            )
        }
        return NetworkRequestAuthority(contexts: contexts, context: contexts.context(pluginID: "fixture", operation))
    }

    private func assertRefusal(_ expected: HostNetworkPolicyOutcome, operation: () throws -> Void) {
        XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? HostNetworkPolicyOutcome, expected) }
    }
}

private final class CompletionCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = [0, 0]
    var values: [Int] { lock.withLock { counts } }
    func increment(_ index: Int) { lock.withLock { counts[index] += 1 } }
}

private final class RedirectResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLRequest?
    private var called = false
    var request: URLRequest? { lock.withLock { value } }
    var wasCalled: Bool { lock.withLock { called } }
    func set(_ request: URLRequest?) { lock.withLock { called = true; value = request } }
}

private final class EmptyImageDiagnostics: ImagePipelineDelegate {}

private final class PipelineCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var held: ImagePipeline?
    var pipeline: ImagePipeline? { lock.withLock { held } }
    func set(_ pipeline: ImagePipeline) { lock.withLock { held = pipeline } }
}
