import Foundation
import ito_runner
import Testing
@testable import Ito

/// One row of the policy-outcome table: what a host policy outcome ends a download with.
nonisolated struct DownloadPolicyOutcomeRow: Sendable, CustomTestStringConvertible {
    let name: String
    let policy: HostNetworkPolicyOutcome
    let expected: DownloadAttemptOutcome

    var testDescription: String { name }
}

/// Counts the calls the runner makes into the module it holds.
private final class CountingNetModule: NetModule, @unchecked Sendable {
    private let wrapped: any NetModule
    let calls = DownloadCallCounter()

    init(_ wrapped: any NetModule) {
        self.wrapped = wrapped
    }

    func fetch(request: NetRequest, context: NetworkOperationContext) async throws -> NetResponse {
        calls.increment()
        return try await wrapped.fetch(request: request, context: context)
    }
}

/// A transport that fails every request with the same URL error.
private final class FailingNet: NetModule, @unchecked Sendable {
    private let error: URLError

    init(_ error: URLError) {
        self.error = error
    }

    func fetch(request: NetRequest, context: NetworkOperationContext) async throws -> NetResponse {
        throw error
    }
}

struct DownloadNetModuleTests {
    private static func request(_ url: String = "https://api.test/chapters") -> NetRequest {
        NetRequest(url: url, method: "GET", headers: [:], body: nil)
    }

    /// The URL error the system raises for a path that is unavailable for bulk work, with the reason it names.
    private static func urlError(_ reason: URLError.NetworkUnavailableReason) -> URLError {
        URLError(.notConnectedToInternet, userInfo: [
            NSURLErrorNetworkUnavailableReasonKey: reason.rawValue
        ])
    }

    static let policyOutcomeTable: [DownloadPolicyOutcomeRow] = [
        DownloadPolicyOutcomeRow(
            name: "unknown path waits for a reading",
            policy: .deferred(.unknownPath),
            expected: .waiting(.networkUnknown)
        ),
        DownloadPolicyOutcomeRow(
            name: "offline waits for a connection",
            policy: .deferred(.offline),
            expected: .waiting(.noConnection)
        ),
        DownloadPolicyOutcomeRow(
            name: "expensive path waits as metered",
            policy: .deferred(.expensivePath),
            expected: .waiting(.meteredNetwork)
        ),
        DownloadPolicyOutcomeRow(
            name: "constrained path waits as low data mode",
            policy: .deferred(.constrainedPath),
            expected: .waiting(.lowDataMode)
        ),
        DownloadPolicyOutcomeRow(
            name: "a policy change requeues the attempt",
            policy: .deferred(.policyChanged),
            expected: .queued
        ),
        DownloadPolicyOutcomeRow(
            name: "a web view or challenge fails the download as requiring the source",
            policy: .foregroundPermissionRequired,
            expected: .failed(.requiresInteractiveSource)
        ),
        DownloadPolicyOutcomeRow(
            name: "an authorization failure waits for the source settings",
            policy: .sourceAuthorizationFailure,
            expected: .waiting(.sourceConfigurationChanged)
        ),
        DownloadPolicyOutcomeRow(
            name: "a hard user block fails the download as a source error",
            policy: .hardUserBlocked,
            expected: .failed(.sourceError)
        )
    ]

    @Test(arguments: DownloadNetModuleTests.policyOutcomeTable)
    func everyPolicyOutcomeEndsAnAttemptWithItsTableOutcome(_ row: DownloadPolicyOutcomeRow) {
        #expect(DownloadAttemptOutcome(policy: row.policy) == row.expected)
    }

    @Test func aRequestOnAnAdmittedPathReachesTheTransport() async throws {
        let inner = ScriptedInnerNet(contexts: NetworkContextRecorder())
        let path = ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .satisfied))
        let recorder = DownloadPolicyRecorder()
        let net = DownloadNetModule(
            inner: inner,
            gate: NetworkPathAdmissionGate(observer: path),
            recorder: recorder
        )

        let response = try await net.fetch(request: Self.request(), context: makeTestNetworkContext())

        #expect(response.status == 200)
        #expect(inner.calls.count == 1)
        #expect(recorder.firstDenial == nil)
    }

    @Test func aRefusedPathThrowsItsOutcomeAndLaterRequestsThrowTheSameWithoutTheTransport() async throws {
        let inner = ScriptedInnerNet(contexts: NetworkContextRecorder())
        let path = ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .satisfied, isExpensive: true))
        let recorder = DownloadPolicyRecorder()
        let net = DownloadNetModule(
            inner: inner,
            gate: NetworkPathAdmissionGate(observer: path),
            recorder: recorder
        )

        await #expect(throws: HostNetworkPolicyOutcome.deferred(.expensivePath)) {
            try await net.fetch(request: Self.request(), context: makeTestNetworkContext())
        }
        path.set(NetworkPathSnapshot(status: .satisfied))
        await #expect(throws: HostNetworkPolicyOutcome.deferred(.expensivePath)) {
            try await net.fetch(request: Self.request("https://api.test/pages"), context: makeTestNetworkContext())
        }

        #expect(inner.calls.count == 0)
        #expect(recorder.firstDenial == .deferred(.expensivePath))
    }

    @Test func aSystemRefusalOfAnExpensivePathIsRecordedAsItsDeferral() async throws {
        let error = Self.urlError(.expensive)
        try #require(error.networkUnavailableReason == .expensive)
        let recorder = DownloadPolicyRecorder()
        let net = DownloadNetModule(
            inner: FailingNet(error),
            gate: NetworkPathAdmissionGate(observer: ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .satisfied))),
            recorder: recorder
        )

        await #expect(throws: HostNetworkPolicyOutcome.deferred(.expensivePath)) {
            try await net.fetch(request: Self.request(), context: makeTestNetworkContext())
        }
        #expect(recorder.firstDenial == .deferred(.expensivePath))
    }

    @Test func aSystemRefusalOfAConstrainedPathIsRecordedAsItsDeferral() async throws {
        let error = Self.urlError(.constrained)
        try #require(error.networkUnavailableReason == .constrained)
        let recorder = DownloadPolicyRecorder()
        let net = DownloadNetModule(
            inner: FailingNet(error),
            gate: NetworkPathAdmissionGate(observer: ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .satisfied))),
            recorder: recorder
        )

        await #expect(throws: HostNetworkPolicyOutcome.deferred(.constrainedPath)) {
            try await net.fetch(request: Self.request(), context: makeTestNetworkContext())
        }
        #expect(recorder.firstDenial == .deferred(.constrainedPath))
    }

    @Test func aURLErrorThatNamesNoPathReasonKeepsItsOwnMeaning() async throws {
        let recorder = DownloadPolicyRecorder()
        let net = DownloadNetModule(
            inner: FailingNet(URLError(.timedOut)),
            gate: NetworkPathAdmissionGate(observer: ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .satisfied))),
            recorder: recorder
        )

        await #expect(throws: URLError.self) {
            try await net.fetch(request: Self.request(), context: makeTestNetworkContext())
        }
        #expect(recorder.firstDenial == nil)
    }

    @Test func theFirstDenialIsKeptWhenLaterDenialsArrive() {
        let recorder = DownloadPolicyRecorder()

        #expect(recorder.record(.deferred(.offline)) == .deferred(.offline))
        #expect(recorder.record(.foregroundPermissionRequired) == .deferred(.offline))

        #expect(recorder.firstDenial == .deferred(.offline))
    }

    /// Precedence: the outcome is stored under the lock before the handler runs, so the handler (which cancels
    /// the attempt) already reads the recorded outcome. Later denials neither replace it nor run the handler again.
    @Test func theOutcomeIsStoredBeforeTheHandlerRunsAndTheHandlerRunsOnce() {
        let recorder = DownloadPolicyRecorder()
        let handlerSawOutcome = DownloadCallCounter()

        recorder.onFirstDenial {
            if recorder.firstDenial == .deferred(.expensivePath) {
                handlerSawOutcome.increment()
            }
        }
        recorder.record(.deferred(.expensivePath))
        recorder.record(.foregroundPermissionRequired)

        #expect(handlerSawOutcome.count == 1)
        #expect(recorder.firstDenial == .deferred(.expensivePath))
    }

    @Test func aDenialRunsItsHandlerOnceAndAHandlerAddedAfterwardRunsImmediately() {
        let recorder = DownloadPolicyRecorder()
        let calls = DownloadCallCounter()

        recorder.onFirstDenial { calls.increment() }
        recorder.record(.deferred(.constrainedPath))
        recorder.record(.deferred(.expensivePath))
        #expect(calls.count == 1)

        recorder.onFirstDenial { calls.increment() }
        #expect(calls.count == 2)
    }

    @Test func aCloudflareChallengeIsRefusedWithoutSolvingItButAnEarnedUserAgentIsReused() async throws {
        let recorder = DownloadPolicyRecorder()
        let handler = RefusingCloudflareHandler(recorder: recorder) { host in
            host == "source.test" ? "Cleared-Agent" : ""
        }

        #expect(await handler.cachedUserAgent(for: "source.test") == "Cleared-Agent")
        #expect(await handler.cachedUserAgent(for: "other.test").isEmpty)
        await #expect(throws: HostNetworkPolicyOutcome.foregroundPermissionRequired) {
            try await handler.resolveChallenge(for: URL(string: "https://source.test/")!)
        }
        #expect(recorder.firstDenial == .foregroundPermissionRequired)
    }

    @Test func aWebViewRequestIsRefusedWithPermissionAndRecorded() async throws {
        let recorder = DownloadPolicyRecorder()
        let webview = DownloadWebviewModule(recorder: recorder)

        await #expect(throws: HostNetworkPolicyOutcome.foregroundPermissionRequired) {
            try await webview.loadUrl(request: WebviewRequest(url: "https://source.test/", script: nil), context: makeTestNetworkContext())
        }
        #expect(recorder.firstDenial == .foregroundPermissionRequired)
    }

    @Test func aScriptRequestIsRefusedWithPermissionAndRecorded() async throws {
        let recorder = DownloadPolicyRecorder()
        let webview = DownloadWebviewModule(recorder: recorder)

        await #expect(throws: HostNetworkPolicyOutcome.foregroundPermissionRequired) {
            try await webview.executeJs(script: "document.title", context: makeTestNetworkContext())
        }
        #expect(recorder.firstDenial == .foregroundPermissionRequired)
    }

    /// The module throws the recorded outcome, not its own, so the runner never sees an outcome the recorder lacks.
    @Test func aWebViewRequestAfterAnEarlierDenialThrowsTheRecordedOutcome() async throws {
        let recorder = DownloadPolicyRecorder()
        recorder.record(.deferred(.expensivePath))
        let webview = DownloadWebviewModule(recorder: recorder)

        await #expect(throws: HostNetworkPolicyOutcome.deferred(.expensivePath)) {
            try await webview.loadUrl(request: WebviewRequest(url: "https://source.test/", script: nil), context: makeTestNetworkContext())
        }
        #expect(recorder.firstDenial == .deferred(.expensivePath))
    }

    /// A real ABI 2 export that fetches twice through a refusing download module: the runner throws the policy
    /// outcome, and the runner short-circuits the second fetch, so the module is called once.
    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aRealExportStopsAtTheFirstRefusalAndTheModuleSeesOneCall() async throws {
        let inner = ScriptedInnerNet(contexts: NetworkContextRecorder())
        let path = ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .satisfied, isExpensive: true))
        let recorder = DownloadPolicyRecorder()
        let module = CountingNetModule(DownloadNetModule(
            inner: inner,
            gate: NetworkPathAdmissionGate(observer: path),
            recorder: recorder
        ))
        let runner = ItoRunner()
        await runner.setNetModule(module)
        await runner.setWebviewModule(DownloadWebviewModule(recorder: recorder))
        try await runner.loadPlugin(fromBytes: TestWasm.build(try TestWasm.sending(Self.request(), times: 2)))

        await #expect(throws: ItoError.networkPolicy(.deferred(.expensivePath))) {
            try await runner.markCompleted(
                kind: .manga, mediaKey: "media", unitKey: "unit",
                context: makeTestNetworkContext(purpose: .manualBulkDownload)
            )
        }

        #expect(module.calls.count == 1)
        #expect(inner.calls.count == 0)
        #expect(recorder.firstDenial == .deferred(.expensivePath))
    }

    /// Recorder precedence under cancellation. The handler cancels the export as the denial is recorded, so the
    /// export ends in either of exactly two ways. Both leave the recorder holding the denial, and nothing else.
    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func aCancelledExportAfterARecordedDenialLeavesTheDenialAsTheRecorderOutcome() async throws {
        let inner = ScriptedInnerNet(contexts: NetworkContextRecorder())
        let path = ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .satisfied, isExpensive: true))
        let recorder = DownloadPolicyRecorder()
        let runner = ItoRunner()
        await runner.setNetModule(DownloadNetModule(
            inner: inner,
            gate: NetworkPathAdmissionGate(observer: path),
            recorder: recorder
        ))
        await runner.setWebviewModule(DownloadWebviewModule(recorder: recorder))
        try await runner.loadPlugin(fromBytes: TestWasm.build(try TestWasm.sending(Self.request(), times: 2)))

        let export = Task {
            try await runner.markCompleted(
                kind: .manga, mediaKey: "media", unitKey: "unit",
                context: makeTestNetworkContext(purpose: .manualBulkDownload)
            )
        }
        recorder.onFirstDenial { export.cancel() }

        switch await export.result {
        case .success:
            Issue.record("A refused export must not succeed")
        case .failure(let error):
            let isCancellation = error is CancellationError
            let isPolicyRefusal = (error as? ItoError) == .networkPolicy(.deferred(.expensivePath))
            #expect(isCancellation || isPolicyRefusal, "Unexpected export error: \(error)")
        }
        #expect(recorder.firstDenial == .deferred(.expensivePath))
        #expect(inner.calls.count == 0)
    }
}
