import Foundation
import Testing
import UIKit
import WebKit
import ito_runner
@testable import Ito

/// Stands in for WebKit's script entry points. It holds every script the manager sends, so a test decides
/// when (and whether) WebKit answers and can order that answer against cancellation, deadlines and retirement.
@MainActor
private final class HeldEvaluator {
    struct Call {
        let kind: WebviewManager.ScriptKind
        let complete: @MainActor (Any?, Error?) -> Void
    }

    private var calls: [Call] = []
    private var taken = 0
    private let arrivals = AsyncStream<Void>.makeStream()

    var evaluator: WebviewManager.ScriptEvaluator {
        { [weak self] _, _, kind, completion in
            guard let self else { return }
            calls.append(Call(kind: kind, complete: completion))
            arrivals.continuation.yield()
        }
    }

    /// The next script the manager has sent, waiting for it if it hasn't yet.
    func nextCall() async -> Call {
        while taken >= calls.count {
            var iterator = arrivals.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        defer { taken += 1 }
        return calls[taken]
    }
}

private struct FixtureFailure: Error, Equatable {}

private let asyncMarker = "//# ito-async\n"

@MainActor
private func dispose(_ manager: WebviewManager) {
    if let overlay = presentedOverlay(of: manager) {
        _ = overlay.view.accessibilityPerformEscape()
    }
    manager.webView?.stopLoading()
    manager.webView?.removeFromSuperview()
}

@MainActor
private func presentedOverlay(of manager: WebviewManager) -> PageOverlayViewController? {
    manager.webView?.window?.rootViewController as? PageOverlayViewController
}

/// A manager whose scripts are held by `held`, with its page loaded.
@MainActor
private func loadedPage(
    _ held: HeldEvaluator,
    plainScriptDeadline: TimeInterval? = nil,
    authority: NetworkRequestAuthority? = nil
) async throws -> WebviewManager {
    let manager = WebviewManager(
        pageLoadDeadline: 20, authority: authority,
        scriptEvaluator: held.evaluator, plainScriptDeadline: plainScriptDeadline)
    do {
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>x</p>", script: nil))
        return manager
    } catch {
        dispose(manager)
        throw error
    }
}

/// Has the page post `itoShowPage` now, as a page asking for a verification would, and returns the decision.
@MainActor
private func postShowPage(on manager: WebviewManager) async throws -> Bool? {
    let decisions = AsyncStream<Bool>.makeStream()
    manager.onShowPageDecision = { decisions.continuation.yield($0) }
    defer { manager.onShowPageDecision = nil }
    _ = try await manager.webView?.evaluateJavaScript("window.webkit.messageHandlers.itoShowPage.postMessage(null); 'posted'")
    var iterator = decisions.stream.makeAsyncIterator()
    return await iterator.next()
}

@MainActor
@Suite("Web view script lifecycle", .serialized)
struct WebviewScriptLifecycleTests {
    @Test func cancellingAPlainScriptSettlesItBeforeWebKitAnswersAndTheLateAnswerIsIgnored() async throws {
        let held = HeldEvaluator()
        let manager = try await loadedPage(held)
        defer { dispose(manager) }

        let script = Task { try await manager.executeJs(script: "1 + 1") }
        let call = await held.nextCall()
        #expect(call.kind == .plain)
        #expect(!manager.isIdle)

        script.cancel()
        await #expect(throws: CancellationError.self) { try await script.value }
        // Settled by the cancellation alone: WebKit has not answered.
        #expect(manager.isIdle)

        // The late answer neither publishes data nor resumes the operation that follows.
        let next = Task { try await manager.executeJs(script: "2 + 2") }
        let nextCall = await held.nextCall()
        call.complete("stale", nil)
        #expect(!manager.isIdle)
        nextCall.complete(4, nil)
        #expect(try await next.value == "4")
        #expect(manager.isIdle)
    }

    @Test func aPlainScriptWebKitNeverAnswersEndsWithTheTypedTimeoutAndItsLateAnswerIsIgnored() async throws {
        let held = HeldEvaluator()
        let manager = try await loadedPage(held, plainScriptDeadline: 0.01)
        defer { dispose(manager) }

        let script = Task { try await manager.executeJs(script: "1 + 1") }
        let call = await held.nextCall()
        await #expect(throws: ItoError.hostCallTimedOut(.webview)) { try await script.value }
        #expect(manager.isIdle)

        call.complete("late", nil)
        #expect(manager.isIdle)
    }

    @Test func aPendingPlainScriptDoesNotAuthorizeThePage() async throws {
        let held = HeldEvaluator()
        let manager = try await loadedPage(held)
        defer { dispose(manager) }

        let script = Task { try await manager.executeJs(script: "1 + 1") }
        let call = await held.nextCall()

        #expect(try await postShowPage(on: manager) == false)
        #expect(presentedOverlay(of: manager) == nil)

        call.complete(2, nil)
        #expect(try await script.value == "2")
    }

    @Test func aWaitingAsyncScriptStillAuthorizesThePageAndEndingItHidesItWhileAPlainScriptPends() async throws {
        let held = HeldEvaluator()
        let manager = try await loadedPage(held)
        defer { dispose(manager) }

        let waiting = Task { try await manager.executeJs(script: asyncMarker + "return 'verified'") }
        let waitingCall = await held.nextCall()
        #expect(waitingCall.kind == .waitingAsync)
        let plain = Task { try await manager.executeJs(script: "1 + 1") }
        let plainCall = await held.nextCall()
        #expect(plainCall.kind == .plain)

        #expect(try await postShowPage(on: manager) == true)
        #expect(presentedOverlay(of: manager) != nil)

        // The plain script that is still pending does not keep the page up.
        waitingCall.complete("verified", nil)
        #expect(try await waiting.value == "verified")
        #expect(presentedOverlay(of: manager) == nil)
        #expect(!manager.isIdle)
        #expect(try await postShowPage(on: manager) == false)

        plainCall.complete(2, nil)
        #expect(try await plain.value == "2")
    }

    @Test func retiringThePageSettlesEveryOwnedScriptOnceAndIgnoresLaterAnswers() async throws {
        let held = HeldEvaluator()
        let manager = try await loadedPage(held)
        defer { dispose(manager) }

        let plain = Task { try await manager.executeJs(script: "1 + 1") }
        let plainCall = await held.nextCall()
        let waiting = Task { try await manager.executeJs(script: asyncMarker + "return 1") }
        let waitingCall = await held.nextCall()

        manager.retire(with: FixtureFailure())
        await #expect(throws: FixtureFailure()) { try await plain.value }
        await #expect(throws: FixtureFailure()) { try await waiting.value }
        #expect(manager.isIdle)

        // Answers that arrive after retirement, and a second retirement, settle nothing again.
        plainCall.complete("late", nil)
        waitingCall.complete("late", nil)
        manager.retire(with: CancellationError())
        #expect(manager.isIdle)
        await #expect(throws: HostNetworkPolicyOutcome.sourceAuthorizationFailure) {
            try await manager.executeJs(script: "1 + 1")
        }
    }

    @Test func aPlainAnswerThatArrivesAfterItsSourceScopeChangedIsNotPublished() async throws {
        let policy = NetworkPolicyCenter(path: ManualNetworkPathObserver(initial: .init(status: .satisfied)))
        policy.enterForeground()
        let contexts = PluginNetworkContexts(policy: policy)
        let authority = NetworkRequestAuthority(
            contexts: contexts,
            context: contexts.context(
                pluginID: "fixture", PluginNetworkOperation(purpose: .foregroundReading, operationID: UUID())))
        let held = HeldEvaluator()
        let manager = try await loadedPage(held, authority: authority)
        defer { dispose(manager) }

        let script = Task { try await manager.executeJs(script: "document.title") }
        let call = await held.nextCall()

        // A settings change that does not withdraw this page keeps it live, so its answer is still the page's own.
        var changed = policy.current
        changed.preloadImageCount = 0
        policy.apply(changed)
        // The source's sign-in or settings scope rotates before the answer lands: admission is re-checked at
        // publication and the answer belongs to the old scope.
        contexts.replaceEpochs(["fixture": String(repeating: "b", count: 32)])
        call.complete("secret", nil)

        await #expect(throws: HostNetworkPolicyOutcome.sourceAuthorizationFailure) { try await script.value }
        #expect(manager.isIdle)
    }
}
