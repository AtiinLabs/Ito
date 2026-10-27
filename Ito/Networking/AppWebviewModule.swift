import OSLog
import Foundation
import UIKit
import WebKit
import ito_runner

actor AppWebviewModule: WebviewModule {
    func loadUrl(request: WebviewRequest) async throws -> WebviewResponse {
        AppLogger.network.debug("AppWebviewModule: loadUrl called for \(request.url)")
        return try await WebviewManager.shared.loadUrl(request: request)
    }

    func executeJs(script: String) async throws -> String {
        AppLogger.network.debug("AppWebviewModule: executeJs called")
        return try await WebviewManager.shared.executeJs(script: script)
    }
}

@MainActor
class WebviewManager: NSObject, WKNavigationDelegate {
    static let shared = WebviewManager()
    /// The error a script ends with when the user closes the page (see `closeByUser`).
    static let closedByUser: Error = ItoError.hostModuleError(domain: "webview", message: "Verification was closed.")

    /// How long a page may take to load before the plugin gets a timeout.
    private let pageLoadDeadline: TimeInterval
    /// Whether the user can see the app, so a page may be shown to them. Injected so tests can refuse.
    private let isInteractive: @MainActor () -> Bool
    /// The origins the user closed a page for. A closed origin isn't shown again until the app becomes active.
    private var declinedOrigins: Set<String> = []
    private(set) var webView: WKWebView?
    /// The load in flight: its continuation, the navigation it started, and the deadline that
    /// fails it.
    private struct PendingLoad {
        let id: UUID
        let continuation: CheckedContinuation<WebviewResponse, Error>
        let deadline: Task<Void, Never>
        var navigation: WKNavigation?
    }
    private var pendingLoad: PendingLoad?
    /// The first line that makes a script an async function body (see `executeJs`).
    private static let asyncScriptMarker = "//# ito-async\n"
    /// The async scripts still waiting on the page, by ID. Each is resumed exactly once: by its
    /// completion, by its cancellation, or by a navigation that replaces the page.
    private var pendingScripts: [UUID: CheckedContinuation<String, Error>] = [:]
    /// The page shown to the user while a script waits on it. It exists only while `pendingScripts` isn't empty.
    private var presentation: PagePresentation?
#if DEBUG
    /// Test hook: called right after an async script is sent to the page.
    var onAsyncScriptSent: (() -> Void)?
    /// Test hook: called with the reply to each `itoShowPage` message.
    var onShowPageDecision: ((Bool) -> Void)?
#endif

    init(pageLoadDeadline: TimeInterval = 45, isInteractive: @escaping @MainActor () -> Bool = { PagePresentation.foregroundScene != nil }) {
        self.pageLoadDeadline = pageLoadDeadline
        self.isInteractive = isInteractive
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    private func setupWebView() {
        if webView == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = WKWebsiteDataStore.default()
            let prefs = WKWebpagePreferences()
            prefs.allowsContentJavaScript = true
            config.defaultWebpagePreferences = prefs
            // A weak proxy: the configuration's user content controller retains its handlers.
            config.userContentController.addScriptMessageHandler(WeakReplyProxy(self), contentWorld: .page, name: "itoShowPage")

            let wv = WKWebView(frame: UIScreen.main.bounds, configuration: config)
            // Use the same fallback UA as CloudflareManager
            wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
            wv.navigationDelegate = self
            wv.alpha = 0.01
            wv.isUserInteractionEnabled = false

            // Wait for window
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first {
                window.insertSubview(wv, at: 0)
            }
            self.webView = wv
        }
    }

    /// Loads `request.url` in the shared web view and returns the page once it finishes loading.
    /// A newer load replaces this one (it fails with `URLError(.cancelled)`); cancelling the
    /// caller or passing the deadline stops the page and fails the load.
    func loadUrl(request: WebviewRequest) async throws -> WebviewResponse {
        AppLogger.network.debug("WebviewManager: loadUrl requested")
        try Task.checkCancellation()
        finishLoad(with: .failure(URLError(.cancelled)))
        invalidatePendingScripts(with: URLError(.cancelled))
        guard let url = URL(string: request.url) else {
            throw URLError(.badURL)
        }
        setupWebView()

        let id = UUID()
        let deadlineNanoseconds = UInt64(pageLoadDeadline * 1_000_000_000)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self] in
                    guard (try? await Task.sleep(nanoseconds: deadlineNanoseconds)) != nil else { return }
                    self?.finishLoad(id, with: .failure(URLError(.timedOut)))
                }
                pendingLoad = PendingLoad(id: id, continuation: continuation, deadline: deadline)
                pendingLoad?.navigation = webView?.load(URLRequest(url: url))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishLoad(id, with: .failure(CancellationError()))
            }
        }
    }

    /// Resolves the pending load, if it is `id` (or any load when `id` is nil). A failed load
    /// stops the page so it doesn't keep running in the background.
    private func finishLoad(_ id: UUID? = nil, with result: Result<WebviewResponse, Error>) {
        guard let load = pendingLoad, id == nil || id == load.id else { return }
        pendingLoad = nil
        load.deadline.cancel()
        if case .failure = result {
            webView?.stopLoading()
        }
        load.continuation.resume(with: result)
    }

    /// Runs `script` in the page. A script that starts with the `//# ito-async` line is an async
    /// function body: it must `return` a value, and a Promise it returns is awaited. Any other
    /// script is evaluated with `evaluateJavaScript`. Either way the result is a string.
    func executeJs(script: String) async throws -> String {
        AppLogger.network.debug("WebviewManager: executing js script of length \(script.count)")
        if script.hasPrefix(WebviewManager.asyncScriptMarker) {
            return try await executeAsyncJs(script: script)
        }
        return try await withCheckedThrowingContinuation { continuation in
            guard let wv = webView else {
                AppLogger.network.debug("WebviewManager: webView is nil")
                continuation.resume(throwing: URLError(.badURL))
                return
            }
            wv.evaluateJavaScript(script) { result, error in
                if let error = error {
                    AppLogger.network.error("WebviewManager: evaluateJavaScript error: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    // `undefined` arrives as nil and `null` as NSNull: both are an empty result.
                    let resultStr = result.flatMap { $0 is NSNull ? nil : String(describing: $0) } ?? ""
                    AppLogger.network.debug("WebviewManager: evaluateJavaScript success, result length: \(resultStr.count)")
                    continuation.resume(returning: resultStr)
                }
            }
        }
    }

    /// Runs an async script. Its continuation is registered before the script is sent, so the
    /// completion or the cancellation that ends it always finds it; whichever arrives first removes it.
    private func executeAsyncJs(script: String) async throws -> String {
        guard let wv = webView else {
            AppLogger.network.debug("WebviewManager: webView is nil")
            throw URLError(.badURL)
        }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                pendingScripts[id] = continuation
                // WebKit's Objective-C entry point, not the Swift overlay: it needs no
                // libswiftWebKit symbol on older systems, reports `undefined` as nil rather than
                // unwrapping it, and completes on the main actor, so the script ends in this turn.
                wv.__callAsyncJavaScript(script, arguments: [:], inFrame: nil, in: .page) { [weak self] value, error in
                    self?.finishScript(id, with: error.map { .failure($0) } ?? .success(WebviewManager.scriptResult(value)))
                }
#if DEBUG
                onAsyncScriptSent?()
#endif
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishScript(id, with: .failure(CancellationError())) }
        }
    }

    /// Ends the async script `id` with `result`, if it is still waiting. A late completion for a
    /// script that was cancelled or invalidated finds no entry and is ignored.
    private func finishScript(_ id: UUID, with result: Result<String, Error>) {
        guard let continuation = pendingScripts.removeValue(forKey: id) else { return }
        endPresentationIfIdle()
        continuation.resume(with: result)
    }

    /// Fails every async script still waiting on the page. Their late completions are then ignored.
    private func invalidatePendingScripts(with error: Error) {
        let scripts = pendingScripts.values
        pendingScripts.removeAll()
        endPresentationIfIdle()
        for continuation in scripts {
            continuation.resume(throwing: error)
        }
    }

    /// Hides the page once no script waits on it. This runs before the waiting scripts resume, so the
    /// page is back home by the time they do.
    private func endPresentationIfIdle() {
        guard pendingScripts.isEmpty, let ended = presentation else { return }
        presentation = nil
        ended.end()
    }

    /// Shows the page for an `itoShowPage` message if every gate holds, and says whether it is shown.
    /// This runs synchronously, so the reply is final: a refused page is never shown later.
    fileprivate func showPage(for message: WKScriptMessage) -> Bool {
        let origin = WebviewManager.originKey(message.frameInfo.securityOrigin)
        let accepted = message.webView === webView
            && message.frameInfo.isMainFrame
            && !pendingScripts.isEmpty
            && isInteractive()
            && !declinedOrigins.contains(origin)
        if accepted, presentation == nil, let webView {
            presentation = PagePresentation(
                webView: webView, origin: origin, host: message.frameInfo.securityOrigin.host,
                onClose: { [weak self] in self?.closeByUser() })
        }
        let shown = accepted && presentation != nil
#if DEBUG
        onShowPageDecision?(shown)
#endif
        return shown
    }

    /// The user closed the page: its origin is declined until the app becomes active again, and the
    /// scripts waiting on it fail with `closedByUser`.
    private func closeByUser() {
        guard let presentation else { return }
        declinedOrigins.insert(presentation.origin)
        invalidatePendingScripts(with: WebviewManager.closedByUser)
    }

    /// Forgets the declined origins: the user may be shown a page again once they return to the app.
    @objc private func applicationDidBecomeActive() {
        declinedOrigins.removeAll()
    }

    /// The key a page's origin is declined by, such as `https://comix.to:443`.
    private static func originKey(_ origin: WKSecurityOrigin) -> String {
        "\(origin.protocol)://\(origin.host):\(origin.port)"
    }

    /// The string a script result becomes for the plugin. `undefined` (nil) and `null` are both empty.
    private static func scriptResult(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        return String(describing: value)
    }

    /// The pending load `navigation` belongs to. Callbacks for a navigation that was replaced or
    /// already resolved are ignored.
    private func loadID(for navigation: WKNavigation?) -> UUID? {
        guard let load = pendingLoad, let navigation, load.navigation === navigation else { return nil }
        return load.id
    }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A committed navigation replaces the document, so scripts still awaiting the old one can't
        // finish. Same-document changes (pushState, fragment) don't commit and keep their scripts.
        invalidatePendingScripts(with: URLError(.cancelled))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = loadID(for: navigation) else { return }
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] htmlResult, _ in
            let html = (htmlResult as? String) ?? ""
            let response = WebviewResponse(url: webView.url?.absoluteString ?? "", html: html)
            self?.finishLoad(id, with: .success(response))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let id = loadID(for: navigation) else { return }
        AppLogger.network.error("WebviewManager: navigation failed: \(error.localizedDescription)")
        finishLoad(id, with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let id = loadID(for: navigation) else { return }
        finishLoad(id, with: .failure(error))
    }
}

/// Receives `itoShowPage` messages for `WebviewManager`. The web view's user content controller
/// retains its handlers, so the proxy holds the manager weakly.
private final class WeakReplyProxy: NSObject, WKScriptMessageHandlerWithReply {
    private weak var target: WebviewManager?

    init(_ target: WebviewManager) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        replyHandler(target?.showPage(for: message) ?? false, nil)
    }
}
