import Foundation
import Network
import UIKit
import WebKit
import Testing
import ito_runner
@testable import Ito

/// A local HTTP server that accepts connections and never answers, reporting each connection.
private final class SilentServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "WebviewManagerTests.SilentServer")
    private var connections: [NWConnection] = []
    private let connected = AsyncStream<Void>.makeStream()
    private let ready = AsyncStream<UInt16>.makeStream()

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connections.append(connection)
            connection.start(queue: queue)
            connected.continuation.yield()
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state, let port = listener.port?.rawValue else { return }
            ready.continuation.yield(port)
        }
        listener.start(queue: queue)
    }

    func url() async -> String {
        var iterator = ready.stream.makeAsyncIterator()
        let port = await iterator.next() ?? 0
        return "http://localhost:\(port)/"
    }

    func connectionArrived() async {
        var iterator = connected.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    deinit {
        listener.cancel()
        connections.forEach { $0.cancel() }
    }
}

/// Starts `body` as an async script and returns once the page has been sent it.
@MainActor
private func startAsyncScript(_ body: String, on manager: WebviewManager) async -> Task<String, Error> {
    let sent = AsyncStream<Void>.makeStream()
    manager.onAsyncScriptSent = { sent.continuation.yield() }
    defer { manager.onAsyncScriptSent = nil }
    let script = Task { try await manager.executeJs(script: "//# ito-async\n" + body) }
    var iterator = sent.stream.makeAsyncIterator()
    _ = await iterator.next()
    return script
}

/// Starts an async script that never settles and returns once the page has been sent it.
/// The test releases it by calling `window.__itoRelease` with the value it should resolve to.
@MainActor
private func startNeverSettlingScript(on manager: WebviewManager) async -> Task<String, Error> {
    await startAsyncScript("return new Promise(resolve => { window.__itoRelease = resolve; })", on: manager)
}

/// Routes the `itoShowPage` decisions of `manager` into a stream the test can await.
@MainActor
private func showPageDecisions(on manager: WebviewManager) -> AsyncStream<Bool> {
    let decisions = AsyncStream<Bool>.makeStream()
    manager.onShowPageDecision = { decisions.continuation.yield($0) }
    return decisions.stream
}

@MainActor
private func nextDecision(_ decisions: AsyncStream<Bool>) async -> Bool? {
    var iterator = decisions.makeAsyncIterator()
    return await iterator.next()
}

/// Has a waiting script ask the user to complete a verification, and returns the reply it gets.
@MainActor
private func askToShowPage(on manager: WebviewManager) async throws -> String {
    try await manager.executeJs(script: "//# ito-async\nreturn String(await window.webkit.messageHandlers.itoShowPage.postMessage(null))")
}

/// The overlay the web view is presented in, or nil while it is at home.
@MainActor
private func presentedOverlay(of manager: WebviewManager) -> PageOverlayViewController? {
    manager.webView?.window?.rootViewController as? PageOverlayViewController
}

/// The web view is back home: not presented, hidden, and not interactive.
@MainActor
private func expectHome(_ manager: WebviewManager) {
    #expect(presentedOverlay(of: manager) == nil)
    // Back in the app's own window, not detached: the page keeps rendering for later scripts.
    #expect(manager.webView?.window != nil)
    // UIKit stores alpha as a float: 0.01 reads back as 0.00999…, so compare with a tolerance.
    #expect(abs((manager.webView?.alpha ?? 1) - 0.01) < 0.001)
    #expect(manager.webView?.isUserInteractionEnabled == false)
}

/// The Close button in the overlay's view tree, as VoiceOver finds it by label.
@MainActor
private func closeButton(in view: UIView) -> UIButton? {
    if let button = view as? UIButton, button.accessibilityLabel == "Close" {
        return button
    }
    for subview in view.subviews {
        if let button = closeButton(in: subview) {
            return button
        }
    }
    return nil
}

@MainActor
@Suite("Web view page loads")
struct WebviewManagerTests {
    @Test func aPageThatNeverAnswersTimesOut() async throws {
        let server = try SilentServer()
        let manager = WebviewManager(pageLoadDeadline: 0.3)

        await #expect(throws: URLError(.timedOut)) {
            try await manager.loadUrl(request: WebviewRequest(url: await server.url(), script: nil))
        }
    }

    @Test func cancellingTheCallerEndsTheLoad() async throws {
        let server = try SilentServer()
        let manager = WebviewManager()
        let url = await server.url()

        let load = Task { try await manager.loadUrl(request: WebviewRequest(url: url, script: nil)) }
        await server.connectionArrived()
        load.cancel()

        await #expect(throws: CancellationError.self) { try await load.value }
    }

    @Test func aNewerLoadReplacesThePendingOne() async throws {
        let server = try SilentServer()
        let replacementServer = try SilentServer()
        let manager = WebviewManager()
        let url = await server.url()
        let replacementURL = await replacementServer.url()

        let first = Task { try await manager.loadUrl(request: WebviewRequest(url: url, script: nil)) }
        await server.connectionArrived()
        let second = Task { try await manager.loadUrl(request: WebviewRequest(url: replacementURL, script: nil)) }
        await #expect(throws: URLError(.cancelled)) { try await first.value }

        // Distinct endpoints require a new navigation request, not a second connection for
        // the same URL (which WebKit may reuse). Late old-navigation callbacks must not end it.
        let cancellation = Task {
            await replacementServer.connectionArrived()
            second.cancel()
        }
        await #expect(throws: CancellationError.self) { try await second.value }
        cancellation.cancel()
        await cancellation.value
    }

    @Test func cancellingAPendingAsyncScriptEndsItAndLaterScriptsStillRun() async throws {
        let manager = WebviewManager()
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>x</p>", script: nil))

        let pending = await startNeverSettlingScript(on: manager)
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }

        #expect(try await manager.executeJs(script: "6 * 7") == "42")
        #expect(try await manager.executeJs(script: "//# ito-async\nreturn 5") == "5")
    }

    @Test func loadingAnotherPageEndsPendingAsyncScriptsWithCancelled() async throws {
        let manager = WebviewManager()
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>one</p>", script: nil))
        let pending = await startNeverSettlingScript(on: manager)

        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>two</p>", script: nil))
        await #expect(throws: URLError(.cancelled)) { try await pending.value }
    }

    @Test func aPageNavigationEndsPendingAsyncScriptsWithCancelled() async throws {
        let manager = WebviewManager()
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>x</p>", script: nil))
        let pending = await startNeverSettlingScript(on: manager)

        // WebKit refuses script-initiated reloads of data URLs. about:blank is a real,
        // permitted replacement document and exercises the navigation delegate's commit.
        _ = try await manager.executeJs(script: "setTimeout(() => { location.href = 'about:blank'; }, 0); 'scheduled'")
        await #expect(throws: URLError(.cancelled)) { try await pending.value }
    }

    @Test func aFragmentChangeInThePageKeepsPendingAsyncScripts() async throws {
        let manager = WebviewManager()
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>x</p>", script: nil))
        let pending = await startNeverSettlingScript(on: manager)

        // A same-document navigation does not replace the document, so the script is still pending.
        _ = try await manager.executeJs(script: "location.hash = 'next'; 'changed'")
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
    }

    @Test func aWaitingScriptCanShowThePageInAModalOverlay() async throws {
        let manager = WebviewManager()
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>x</p>", script: nil))
        let pending = await startNeverSettlingScript(on: manager)

        #expect(try await askToShowPage(on: manager) == "true")

        let webView = try #require(manager.webView)
        let overlay = try #require(presentedOverlay(of: manager))
        #expect(webView.window?.rootViewController === overlay)
        #expect(webView.alpha == 1)
        #expect(webView.isUserInteractionEnabled)
        #expect(overlay.view.accessibilityViewIsModal)
        #expect(closeButton(in: overlay.view) != nil)

        _ = try await manager.executeJs(script: "window.__itoRelease('done'); 'released'")
        #expect(try await pending.value == "done")
    }

    @Test func releasingTheLastWaitingScriptHidesThePage() async throws {
        let manager = WebviewManager()
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>x</p>", script: nil))
        let pending = await startNeverSettlingScript(on: manager)
        #expect(try await askToShowPage(on: manager) == "true")

        _ = try await manager.executeJs(script: "window.__itoRelease('done'); 'released'")
        #expect(try await pending.value == "done")
        expectHome(manager)
    }

    @Test func thePageStaysUpUntilItsLastWaitingScriptEnds() async throws {
        let manager = WebviewManager()
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>x</p>", script: nil))
        let first = await startNeverSettlingScript(on: manager)
        let last = await startNeverSettlingScript(on: manager)
        #expect(try await askToShowPage(on: manager) == "true")

        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(presentedOverlay(of: manager) != nil)

        _ = try await manager.executeJs(script: "window.__itoRelease('done'); 'released'")
        #expect(try await last.value == "done")
        expectHome(manager)
    }

    @Test func aRejectedWaitingScriptHidesThePage() async throws {
        let manager = WebviewManager()
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>x</p>", script: nil))
        let pending = await startAsyncScript(
            "await new Promise(resolve => { window.__itoRelease = resolve; }); throw new Error('boom');", on: manager)
        #expect(try await askToShowPage(on: manager) == "true")

        _ = try await manager.executeJs(script: "window.__itoRelease('x'); 'released'")
        await #expect(throws: (any Error).self) { try await pending.value }
        expectHome(manager)
    }

    @Test func aCancelledWaitingScriptHidesThePage() async throws {
        let manager = WebviewManager()
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>x</p>", script: nil))
        let pending = await startNeverSettlingScript(on: manager)
        #expect(try await askToShowPage(on: manager) == "true")

        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        expectHome(manager)
    }

    @Test func navigatingThePageAwayHidesIt() async throws {
        let manager = WebviewManager()
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>x</p>", script: nil))
        let pending = await startNeverSettlingScript(on: manager)
        #expect(try await askToShowPage(on: manager) == "true")

        _ = try await manager.executeJs(script: "setTimeout(() => { location.href = 'about:blank'; }, 0); 'scheduled'")
        await #expect(throws: URLError(.cancelled)) { try await pending.value }
        expectHome(manager)
    }

    @Test func loadingAnotherPageHidesIt() async throws {
        let manager = WebviewManager()
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>one</p>", script: nil))
        let pending = await startNeverSettlingScript(on: manager)
        #expect(try await askToShowPage(on: manager) == "true")

        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>two</p>", script: nil))
        await #expect(throws: URLError(.cancelled)) { try await pending.value }
        expectHome(manager)
    }

    @Test func closingThePageFailsItsScriptsAndDeclinesTheOriginUntilTheAppReturns() async throws {
        let manager = WebviewManager()
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>x</p>", script: nil))
        let pending = await startNeverSettlingScript(on: manager)
        #expect(try await askToShowPage(on: manager) == "true")

        let overlay = try #require(presentedOverlay(of: manager))
        let close = try #require(closeButton(in: overlay.view))
        close.sendActions(for: .primaryActionTriggered)
        await #expect(throws: ItoError.hostModuleError(domain: "webview", message: "Verification was closed.")) {
            try await pending.value
        }
        expectHome(manager)

        // The page's own release arrives after the close; the script is no longer waiting, so it is ignored.
        _ = try await manager.executeJs(script: "window.__itoRelease && window.__itoRelease('late'); 'released'")
        expectHome(manager)

        // The closed origin is declined, even with a script waiting, until the app becomes active.
        let waiting = await startNeverSettlingScript(on: manager)
        #expect(try await askToShowPage(on: manager) == "false")
        expectHome(manager)

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(try await askToShowPage(on: manager) == "true")

        _ = try await manager.executeJs(script: "window.__itoRelease('done'); 'released'")
        #expect(try await waiting.value == "done")
        expectHome(manager)
    }

    @Test func theAccessibilityEscapeClosesThePageLikeClose() async throws {
        let manager = WebviewManager()
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>x</p>", script: nil))
        let pending = await startNeverSettlingScript(on: manager)
        #expect(try await askToShowPage(on: manager) == "true")

        let overlay = try #require(presentedOverlay(of: manager))
        #expect(overlay.view.accessibilityPerformEscape())

        await #expect(throws: ItoError.hostModuleError(domain: "webview", message: "Verification was closed.")) {
            try await pending.value
        }
        expectHome(manager)

        // Same as Close: the origin is now declined until the app becomes active.
        let waiting = await startNeverSettlingScript(on: manager)
        #expect(try await askToShowPage(on: manager) == "false")
        _ = try await manager.executeJs(script: "window.__itoRelease('done'); 'released'")
        #expect(try await waiting.value == "done")
    }

    @Test func aPostWithNoWaitingScriptIsRefused() async throws {
        let manager = WebviewManager()
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>x</p>", script: nil))
        let decisions = showPageDecisions(on: manager)

        _ = try await manager.executeJs(script: "window.webkit.messageHandlers.itoShowPage.postMessage(null); 'posted'")
        #expect(await nextDecision(decisions) == false)
        expectHome(manager)
    }

    @Test func aPostFromASubframeIsRefusedWhileAScriptWaits() async throws {
        let manager = WebviewManager()
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>x</p>", script: nil))
        let pending = await startNeverSettlingScript(on: manager)
        let decisions = showPageDecisions(on: manager)

        _ = try await manager.executeJs(script: "const frame = document.createElement('iframe'); frame.srcdoc = \"<script>window.webkit.messageHandlers.itoShowPage.postMessage(null)</script>\"; document.body.appendChild(frame); 'framed'")
        #expect(await nextDecision(decisions) == false)
        expectHome(manager)

        _ = try await manager.executeJs(script: "window.__itoRelease('done'); 'released'")
        #expect(try await pending.value == "done")
    }

    @Test func aPageIsNotShownWhileTheAppIsNotInteractive() async throws {
        let manager = WebviewManager(isInteractive: { false })
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>x</p>", script: nil))
        let pending = await startNeverSettlingScript(on: manager)
        let decisions = showPageDecisions(on: manager)

        #expect(try await askToShowPage(on: manager) == "false")
        #expect(await nextDecision(decisions) == false)
        expectHome(manager)

        _ = try await manager.executeJs(script: "window.__itoRelease('done'); 'released'")
        #expect(try await pending.value == "done")
    }

    @Test func aShowPagePostNotAwaitedByItsScriptLeavesNoPageBehind() async throws {
        let manager = WebviewManager()
        _ = try await manager.loadUrl(request: WebviewRequest(url: "data:text/html,<p>x</p>", script: nil))
        let decisions = showPageDecisions(on: manager)

        // The script ends without awaiting the reply, so the page is shown or refused in either order.
        let result = try await manager.executeJs(script: "//# ito-async\nwindow.webkit.messageHandlers.itoShowPage.postMessage(null); return 'x'")
        #expect(result == "x")
        _ = await nextDecision(decisions)
        expectHome(manager)
    }
}
