import Foundation
import WebKit
import Combine
import UIKit
import ito_runner

@MainActor
final class CloudflareManager: NSObject, ObservableObject {
    static let shared = CloudflareManager()
    static let defaultUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
    private var challenges: [UUID: CloudflareChallenge] = [:]

    // A host-only lookup is not allowed to recover another source's authorization.
    func getCachedUserAgent(for host: String) -> String { Self.defaultUserAgent }
    func clearCachedUserAgents() {
        let retired = Array(challenges.values)
        challenges.removeAll()
        retired.forEach { $0.finish(.failure(CancellationError())) }
    }

    func resolveChallenge(for url: URL) async throws -> (userAgent: String, cookies: [HTTPCookie]) {
        throw HostNetworkPolicyOutcome.foregroundPermissionRequired
    }

    func resolveChallenge(for url: URL, authority: NetworkRequestAuthority) async throws -> AppNetCloudflareResolution {
        try Task.checkCancellation()
        try authority.checkInteractive()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let challenge = CloudflareChallenge(url: url, authority: authority) { [weak self] result in
                    self?.challenges[id] = nil
                    continuation.resume(with: result)
                }
                challenges[id] = challenge
                challenge.start()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.challenges[id]?.finish(.failure(CancellationError())) }
        }
    }
}

/// Each waiter owns its own page, deadline and continuation. No late callback can settle a newer challenge.
@MainActor
private final class CloudflareChallenge: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    private let url: URL
    private let authority: NetworkRequestAuthority
    private var completion: ((Result<AppNetCloudflareResolution, Error>) -> Void)?
    private var webView: WKWebView?
    private var presentation: PagePresentation?
    private var deadline: Task<Void, Never>?
    private var observation: AnyCancellable?
    private var retirement: UUID?

    init(url: URL, authority: NetworkRequestAuthority, completion: @escaping (Result<AppNetCloudflareResolution, Error>) -> Void) {
        self.url = url
        self.authority = authority
        self.completion = completion
    }

    func start() {
        do { try authority.checkInteractive() } catch { finish(.failure(error)); return }
        guard let host = url.host, PagePresentation.foregroundScene != nil else {
            finish(.failure(HostNetworkPolicyOutcome.foregroundPermissionRequired)); return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = SourceWebsiteContexts.shared.store(for: authority.context)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let page = WKWebView(frame: UIScreen.main.bounds, configuration: configuration)
        page.customUserAgent = CloudflareManager.defaultUserAgent
        page.navigationDelegate = self
        webView = page
        configuration.websiteDataStore.httpCookieStore.add(self)
        retirement = SourceWebsiteContexts.shared.observeRetirement { [weak self] in self?.finish(.failure(CancellationError())) }
        let authority = self.authority
        observation = authority.changes.sink { [weak self] _ in
            do {
                try authority.checkInteractive()
            } catch {
                Task { @MainActor [weak self] in self?.finish(.failure(error)) }
            }
        }
        presentation = PagePresentation(webView: page, origin: "\(url.scheme ?? "https")://\(host)", host: host,
                                        onClose: { [weak self] in self?.finish(.failure(CancellationError())) })
        guard presentation != nil else { finish(.failure(HostNetworkPolicyOutcome.foregroundPermissionRequired)); return }
        // This is a request deadline, not an ordering or cookie-polling mechanism.
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            self?.finish(.failure(ItoError.hostCallTimedOut(.webview)))
        }
        page.load(URLRequest(url: url))
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in self?.inspectCookies() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { inspectCookies() }

    private func inspectCookies() {
        guard completion != nil, let page = webView, let host = url.host?.lowercased() else { return }
        page.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self, weak page] cookies in
            guard let self, let page, self.webView === page, self.completion != nil else { return }
            let matching = cookies.filter { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return host == domain || host.hasSuffix("." + domain)
            }
            guard matching.contains(where: { $0.name == "cf_clearance" }) else { return }
            do { try self.authority.checkInteractive() } catch { self.finish(.failure(error)); return }
            self.finish(.success(AppNetCloudflareResolution(userAgent: page.customUserAgent ?? CloudflareManager.defaultUserAgent, cookies: matching)))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard self.webView === webView, completion != nil else { decisionHandler(.cancel); return }
        do {
            try authority.checkInteractive()
            guard let target = navigationAction.request.url,
                  target.scheme == "https" || target.scheme == "http", target.user == nil, target.password == nil,
                  !(url.scheme == "https" && target.scheme == "http") else { throw URLError(.unsupportedURL) }
            decisionHandler(.allow)
        } catch { decisionHandler(.cancel); finish(.failure(error)) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNavigation(error)
    }

    private func finishNavigation(_ error: Error) {
        // WebKit may cancel an old provisional navigation while following a redirect. Owner cancellation is
        // delivered separately through the token-matched cancellation handler.
        guard (error as? URLError)?.code != .cancelled else { return }
        finish(.failure(error))
    }

    func finish(_ result: Result<AppNetCloudflareResolution, Error>) {
        guard let completion else { return }
        self.completion = nil
        deadline?.cancel()
        observation?.cancel()
        if let retirement { SourceWebsiteContexts.shared.removeObserver(retirement) }
        webView?.configuration.websiteDataStore.httpCookieStore.remove(self)
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        presentation?.end()
        presentation = nil
        webView?.removeFromSuperview()
        webView = nil
        completion(result)
    }
}
