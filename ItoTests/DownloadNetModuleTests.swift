import Foundation
import ito_runner
import Testing
@testable import Ito

struct DownloadNetModuleTests {
    private static func request(_ url: String = "https://api.test/chapters") -> NetRequest {
        NetRequest(url: url, method: "GET", headers: [:], body: nil)
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

    @Test func aRefusedPathNeverReachesTheTransportAndLaterRequestsShortCircuit() async throws {
        let inner = ScriptedInnerNet(contexts: NetworkContextRecorder())
        let path = ManualNetworkPathObserver(initial: NetworkPathSnapshot(status: .satisfied, isExpensive: true))
        let recorder = DownloadPolicyRecorder()
        let net = DownloadNetModule(
            inner: inner,
            gate: NetworkPathAdmissionGate(observer: path),
            recorder: recorder
        )

        await #expect(throws: DownloadTransportDenied.self) {
            try await net.fetch(request: Self.request(), context: makeTestNetworkContext())
        }
        path.set(NetworkPathSnapshot(status: .satisfied))
        await #expect(throws: DownloadTransportDenied.self) {
            try await net.fetch(request: Self.request("https://api.test/pages"), context: makeTestNetworkContext())
        }

        #expect(inner.calls.count == 0)
        #expect(recorder.firstDenial == .waiting(.meteredNetwork))
    }

    @Test func theFirstDenialIsKeptWhenLaterDenialsArrive() {
        let recorder = DownloadPolicyRecorder()

        recorder.record(.waiting(.noConnection))
        recorder.record(.requiresInteractiveSource)

        #expect(recorder.firstDenial == .waiting(.noConnection))
        #expect(DownloadHostDenial.waiting(.noConnection).outcome == .waiting(.noConnection))
        #expect(DownloadHostDenial.requiresInteractiveSource.outcome == .failed(.requiresInteractiveSource))
    }

    @Test func aDenialRunsItsHandlerOnceAndAHandlerAddedAfterwardRunsImmediately() {
        let recorder = DownloadPolicyRecorder()
        let calls = DownloadCallCounter()

        recorder.onFirstDenial { calls.increment() }
        recorder.record(.waiting(.lowDataMode))
        recorder.record(.waiting(.meteredNetwork))
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
        await #expect(throws: DownloadTransportDenied.self) {
            try await handler.resolveChallenge(for: URL(string: "https://source.test/")!)
        }
        #expect(recorder.firstDenial == .requiresInteractiveSource)
    }

    @Test func aWebViewRequestIsRefusedAndRecorded() async throws {
        let recorder = DownloadPolicyRecorder()
        let webview = DownloadWebviewModule(recorder: recorder)

        await #expect(throws: ItoError.self) {
            try await webview.loadUrl(request: WebviewRequest(url: "https://source.test/", script: nil), context: makeTestNetworkContext())
        }
        #expect(recorder.firstDenial == .requiresInteractiveSource)
    }

    @Test func aScriptRequestIsRefusedAndRecorded() async throws {
        let recorder = DownloadPolicyRecorder()
        let webview = DownloadWebviewModule(recorder: recorder)

        await #expect(throws: ItoError.self) {
            try await webview.executeJs(script: "document.title", context: makeTestNetworkContext())
        }
        #expect(recorder.firstDenial == .requiresInteractiveSource)
    }
}
