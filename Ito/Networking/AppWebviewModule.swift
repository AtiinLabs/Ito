import Combine
import Foundation
import UIKit
import WebKit
import ito_runner

/// The web view a plugin drives. With a live network policy every runner operation owns its own page, so
/// cancelling or replacing one operation's load never settles another's. Each page is bound to its source's
/// website data for the current authorization scope, never to a host shared across sources. Without a policy
/// (tests, previews) one unbound page serves every call.
@MainActor final class AppWebviewModule: WebviewModule {
    /// Live pages. More than this many retire the one used least recently: a page is a full web view.
    private static let maximumPages = 3

    private let contexts: PluginNetworkContexts?
    private var pages: [(operationID: UUID, page: WebviewManager)] = []
    private var unboundPage: WebviewManager?

    init(contexts: PluginNetworkContexts? = nil) {
        self.contexts = contexts
    }

    private func page(for context: NetworkOperationContext) async throws -> WebviewManager {
        guard let contexts else {
            if let unboundPage { return unboundPage }
            let created = await WebviewManager()
            unboundPage = created
            return created
        }
        let authority = NetworkRequestAuthority(contexts: contexts, context: context)
        try Task.checkCancellation()
        // A background or bulk operation never gets a page: it is told it needs the user, and no view is built.
        try authority.checkInteractive()
        var live: [(operationID: UUID, page: WebviewManager)] = []
        for entry in pages {
            if await !entry.page.isRetired { live.append(entry) }
        }
        pages = live
        if let index = pages.firstIndex(where: { $0.operationID == context.operationID }) {
            let entry = pages.remove(at: index)
            pages.append(entry)
            try await entry.page.validate(authority)
            return entry.page
        }
        let created = await WebviewManager(authority: authority)
        pages.append((context.operationID, created))
        // Capacity never retires another operation that still has a native waiter.
        while pages.count > Self.maximumPages {
            var idleIndex: Int?
            for index in pages.indices where pages[index].operationID != context.operationID {
                if await pages[index].page.isIdle { idleIndex = index; break }
            }
            guard let idleIndex else { break }
            let oldest = pages.remove(at: idleIndex)
            await oldest.page.retire(with: CancellationError())
        }
        return created
    }

    func loadUrl(request: WebviewRequest, context: NetworkOperationContext) async throws -> WebviewResponse {
        try await page(for: context).loadUrl(request: request)
    }

    func executeJs(script: String, context: NetworkOperationContext) async throws -> String {
        try await page(for: context).executeJs(script: script)
    }

    // A runner may drop its module from a background executor; release its WebKit pages on MainActor too.
    isolated deinit {}
}

@MainActor
class WebviewManager: NSObject, WKNavigationDelegate {
    /// The error a script ends with when the user closes the page (see `closeByUser`).
    static let closedByUser: Error = ItoError.hostModuleError(domain: "webview", message: "Verification was closed.")

    /// How long a page may take to load before the plugin gets a timeout.
    private let pageLoadDeadline: TimeInterval
    /// How long a plain script may take to answer: the page deadline unless a test shortens it.
    private let plainScriptDeadline: TimeInterval
    /// Whether the user can see the app, so a page may be shown to them. Injected so tests can refuse.
    private let isInteractive: @MainActor () -> Bool
    /// The authority of the operation that owns this page; nil for the unbound page.
    private let authority: NetworkRequestAuthority?
    private var policyObservation: AnyCancellable?
    var isIdle: Bool { pendingLoad == nil && pendingScripts.isEmpty }
    private var retirement: UUID?
    private(set) var isRetired = false

    /// Whether `incoming` is the operation that owns this page, and is still admitted.
    func validate(_ incoming: NetworkRequestAuthority) throws {
        guard !isRetired, let authority,
              authority.context.authorizationScope == incoming.context.authorizationScope,
              authority.context.sourceID == incoming.context.sourceID,
              authority.context.operationID == incoming.context.operationID else {
            throw HostNetworkPolicyOutcome.sourceAuthorizationFailure
        }
        try checkAdmission()
    }

    private func checkAdmission() throws {
        guard !isRetired else { throw HostNetworkPolicyOutcome.sourceAuthorizationFailure }
        try authority?.checkInteractive()
    }

    private var isAdmitted: Bool {
        do { try checkAdmission(); return true } catch { return false }
    }

    /// Ends this page: its pending load and scripts settle with `error` once, and the web view goes away. Only
    /// this page's waiters are affected.
    func retire(with error: Error) {
        guard !isRetired else { return }
        isRetired = true
        policyObservation?.cancel()
        policyObservation = nil
        if let retirement { SourceWebsiteContexts.shared.removeObserver(retirement) }
        retirement = nil
        finishLoad(with: .failure(error))
        invalidatePendingScripts(with: error)
        presentation?.end()
        presentation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

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

    /// How a script runs on the page, which decides whether it may put the page in front of the user.
    enum ScriptKind: Equatable {
        /// A script evaluated in its own turn. It is tracked and settled like any native work, but it
        /// never authorizes a page presentation.
        case plain
        /// An async function body the plugin waits on. Only this kind authorizes `itoShowPage`.
        case waitingAsync
    }

    /// Sends a script to the web view; `completion` reports its result once, on the main actor. The default
    /// is WebKit itself. Tests hold the callback to order it against cancellation, deadlines and retirement.
    typealias ScriptEvaluator = @MainActor (
        _ webView: WKWebView,
        _ script: String,
        _ kind: ScriptKind,
        _ completion: @escaping @MainActor (Any?, Error?) -> Void
    ) -> Void

    private let evaluator: ScriptEvaluator

    private static let webKitEvaluator: ScriptEvaluator = { webView, script, kind, completion in
        switch kind {
        case .plain:
            webView.evaluateJavaScript(script) { result, error in completion(result, error) }
        case .waitingAsync:
            // WebKit's Objective-C entry point, not the Swift overlay: it needs no
            // libswiftWebKit symbol on older systems, reports `undefined` as nil rather than
            // unwrapping it, and completes on the main actor, so the script ends in this turn.
            webView.__callAsyncJavaScript(script, arguments: [:], inFrame: nil, in: .page) { value, error in
                completion(value, error)
            }
        }
    }

    /// A script still waiting on the page. It is resumed exactly once: by its completion, its
    /// cancellation, its deadline, or a lifecycle change that ends the page or replaces its document.
    private struct PendingScript {
        let continuation: CheckedContinuation<String, Error>
        let kind: ScriptKind
        /// Fails a plain script whose native work never answers. A waiting script has none: the user may take
        /// as long as a verification needs, and the runner's own watchdog bounds the plugin call.
        let deadline: Task<Void, Never>?
    }
    /// The scripts still waiting on the page, by ID, plain and async.
    private var pendingScripts: [UUID: PendingScript] = [:]
    /// Whether a script the plugin waits on is pending: the only state in which a page may be shown.
    private var hasWaitingScript: Bool { pendingScripts.values.contains { $0.kind == .waitingAsync } }
    /// The page shown to the user while a script waits on it. It exists only while `hasWaitingScript`.
    private var presentation: PagePresentation?
#if DEBUG
    /// Test hook: called right after an async script is sent to the page.
    var onAsyncScriptSent: (() -> Void)?
    /// Test hook: called with the reply to each `itoShowPage` message.
    var onShowPageDecision: ((Bool) -> Void)?
#endif

    init(
        pageLoadDeadline: TimeInterval = 45,
        isInteractive: @escaping @MainActor () -> Bool = { PagePresentation.foregroundScene != nil },
        authority: NetworkRequestAuthority? = nil,
        scriptEvaluator: ScriptEvaluator? = nil,
        plainScriptDeadline: TimeInterval? = nil
    ) {
        self.authority = authority
        self.pageLoadDeadline = pageLoadDeadline
        self.plainScriptDeadline = plainScriptDeadline ?? pageLoadDeadline
        self.isInteractive = isInteractive
        self.evaluator = scriptEvaluator ?? WebviewManager.webKitEvaluator
        super.init()
        if let authority {
            retirement = SourceWebsiteContexts.shared.observeRetirement { [weak self] in
                self?.retire(with: CancellationError())
            }
            // A live change that no longer admits this operation ends only this page.
            policyObservation = authority.changes.sink { [weak self] _ in
                do {
                    try authority.checkInteractive()
                } catch {
                    Task { @MainActor [weak self] in self?.retire(with: error) }
                }
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupWebView() {
        if webView == nil {
            let config = WKWebViewConfiguration()
            // A page owned by an operation uses its source's website data for the current scope; the unbound page
            // keeps the app's default store.
            config.websiteDataStore = authority.map { SourceWebsiteContexts.shared.store(for: $0.context) } ?? .default()
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

            // Home is the app's own window, never a page overlay that may be up at the moment.
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first(where: { !($0.rootViewController is PageOverlayViewController) }) {
                window.insertSubview(wv, at: 0)
            }
            self.webView = wv
        }
    }

    /// Loads `request.url` in the shared web view and returns the page once it finishes loading.
    /// A newer load replaces this one (it fails with `URLError(.cancelled)`); cancelling the
    /// caller or passing the deadline stops the page and fails the load.
    func loadUrl(request: WebviewRequest) async throws -> WebviewResponse {
        try Task.checkCancellation()
        try checkAdmission()
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
                    self?.finishLoad(id, with: .failure(ItoError.hostCallTimedOut(.webview)))
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
    ///
    /// Both kinds are registered before they are sent, so the completion, cancellation, deadline or
    /// lifecycle change that ends one always finds it; whichever arrives first removes it, and every later
    /// callback for it is ignored. Only an async script can authorize a page presentation (see `showPage`).
    func executeJs(script: String) async throws -> String {
        try Task.checkCancellation()
        try checkAdmission()
        let kind: ScriptKind = script.hasPrefix(WebviewManager.asyncScriptMarker) ? .waitingAsync : .plain
        guard let wv = webView else {
            throw URLError(.badURL)
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                pendingScripts[id] = PendingScript(
                    continuation: continuation, kind: kind, deadline: kind == .plain ? startScriptDeadline(for: id) : nil)
                evaluator(wv, script, kind) { [weak self] value, error in
                    self?.finishScript(id, with: error.map { .failure($0) } ?? .success(WebviewManager.scriptResult(value)))
                }
#if DEBUG
                if kind == .waitingAsync { onAsyncScriptSent?() }
#endif
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishScript(id, with: .failure(CancellationError())) }
        }
    }

    /// The native work timeout of a plain script, the same typed timeout a page load gets.
    private func startScriptDeadline(for id: UUID) -> Task<Void, Never> {
        let nanoseconds = UInt64(plainScriptDeadline * 1_000_000_000)
        return Task { [weak self] in
            guard (try? await Task.sleep(nanoseconds: nanoseconds)) != nil else { return }
            self?.finishScript(id, with: .failure(ItoError.hostCallTimedOut(.webview)))
        }
    }

    /// Ends the script `id` with `result`, if it is still waiting. A late completion for a
    /// script that was cancelled, timed out or invalidated finds no entry and is ignored. A result is
    /// published only while the operation is still admitted.
    private func finishScript(_ id: UUID, with resultFromCallback: Result<String, Error>) {
        guard let script = pendingScripts.removeValue(forKey: id) else { return }
        script.deadline?.cancel()
        let result: Result<String, Error>
        if case .success = resultFromCallback {
            do { try checkAdmission(); result = resultFromCallback } catch { result = .failure(error) }
        } else {
            result = resultFromCallback
        }
        endPresentationIfIdle()
        script.continuation.resume(with: result)
    }

    /// Fails the scripts still waiting on the page, or only those the plugin waits on. Their late
    /// completions are then ignored.
    private func invalidatePendingScripts(with error: Error, waitingOnly: Bool = false) {
        let ended = pendingScripts.filter { !waitingOnly || $0.value.kind == .waitingAsync }
        for id in ended.keys { pendingScripts.removeValue(forKey: id) }
        endPresentationIfIdle()
        for script in ended.values {
            script.deadline?.cancel()
            script.continuation.resume(throwing: error)
        }
    }

    /// Hides the page once no waiting script remains. This runs before the waiting scripts resume, so the
    /// page is back home by the time they do.
    private func endPresentationIfIdle() {
        guard !hasWaitingScript, let ended = presentation else { return }
        presentation = nil
        ended.end()
    }

    /// Shows the page for an `itoShowPage` message if every gate holds, and says whether it is shown.
    /// This runs synchronously, so the reply is final: a refused page is never shown later.
    fileprivate func showPage(for message: WKScriptMessage) -> Bool {
        let origin = WebviewManager.originKey(message.frameInfo.securityOrigin)
        let accepted = message.webView === webView
            && message.frameInfo.isMainFrame
            && hasWaitingScript
            && isInteractive()
            && isAdmitted
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
        invalidatePendingScripts(with: WebviewManager.closedByUser, waitingOnly: true)
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
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // A navigation of an operation's page is a network request: it is decided against the live policy, and
        // one that is no longer admitted ends this page. Local schemes (data, about) are not network.
        guard authority != nil, let target = navigationAction.request.url,
              target.scheme == "https" || target.scheme == "http" else {
            decisionHandler(.allow)
            return
        }
        do {
            try checkAdmission()
            decisionHandler(.allow)
        } catch {
            decisionHandler(.cancel)
            retire(with: error)
        }
    }

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
