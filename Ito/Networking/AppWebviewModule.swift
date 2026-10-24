import OSLog
import Foundation
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

    /// How long a page may take to load before the plugin gets a timeout.
    private let pageLoadDeadline: TimeInterval
    private var webView: WKWebView?
    /// The load in flight: its continuation, the navigation it started, and the deadline that
    /// fails it.
    private struct PendingLoad {
        let id: UUID
        let continuation: CheckedContinuation<WebviewResponse, Error>
        let deadline: Task<Void, Never>
        var navigation: WKNavigation?
    }
    private var pendingLoad: PendingLoad?

    init(pageLoadDeadline: TimeInterval = 45) {
        self.pageLoadDeadline = pageLoadDeadline
        super.init()
    }

    private func setupWebView() {
        if webView == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = WKWebsiteDataStore.default()
            let prefs = WKWebpagePreferences()
            prefs.allowsContentJavaScript = true
            config.defaultWebpagePreferences = prefs

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

    func executeJs(script: String) async throws -> String {
        AppLogger.network.debug("WebviewManager: executing js script of length \(script.count)")
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

    /// The pending load `navigation` belongs to. Callbacks for a navigation that was replaced or
    /// already resolved are ignored.
    private func loadID(for navigation: WKNavigation?) -> UUID? {
        guard let load = pendingLoad, let navigation, load.navigation === navigation else { return nil }
        return load.id
    }

    // MARK: - WKNavigationDelegate
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
