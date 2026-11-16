import Foundation
import WebKit
import Combine
import UIKit
import ito_runner

@MainActor
final class CloudflareManager: NSObject, ObservableObject {
    nonisolated static let defaultUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
    private var challenges: [UUID: CloudflareChallenge] = [:]
    private let websites: SourceWebsiteContexts

    init(websites: SourceWebsiteContexts) {
        self.websites = websites
        super.init()
    }

    func resolveChallenge(for url: URL, authority: NetworkRequestAuthority) async throws -> AppNetCloudflareResolution {
        try Task.checkCancellation()
        try authority.checkInteractive()
        guard !websites.isClearing else { throw CancellationError() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let challenge = CloudflareChallenge(url: url, authority: authority, websites: websites) { [weak self] result in
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
final class CloudflareChallenge: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    private let url: URL
    private let authority: NetworkRequestAuthority
    private let websites: SourceWebsiteContexts
    private var completion: ((Result<AppNetCloudflareResolution, Error>) -> Void)?
    private(set) var webView: WKWebView?
    private var presentation: PagePresentation?
    private var deadline: Task<Void, Never>?
    private var observation: AnyCancellable?
    private var retirement: UUID?
    private let presentsPage: Bool
    private let loadPage: @MainActor (WKWebView, URL) -> Void
#if DEBUG
    var onPolicyEvaluation: (() -> Void)?
#endif

    init(
        url: URL, authority: NetworkRequestAuthority, websites: SourceWebsiteContexts,
        presentsPage: Bool = true,
        loadPage: @escaping @MainActor (WKWebView, URL) -> Void = { page, url in page.load(URLRequest(url: url)) },
        completion: @escaping (Result<AppNetCloudflareResolution, Error>) -> Void
    ) {
        self.url = url
        self.authority = authority
        self.websites = websites
        self.completion = completion
        self.presentsPage = presentsPage
        self.loadPage = loadPage
    }

    func start() {
        do { try authority.checkInteractive() } catch { finish(.failure(error)); return }
        guard let host = url.host, !presentsPage || PagePresentation.foregroundScene != nil else {
            finish(.failure(HostNetworkPolicyOutcome.foregroundPermissionRequired)); return
        }
        let configuration = WKWebViewConfiguration()
        do {
            configuration.websiteDataStore = try websites.store(for: authority.context)
        } catch { finish(.failure(error)); return }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let page = WKWebView(frame: UIScreen.main.bounds, configuration: configuration)
        page.customUserAgent = CloudflareManager.defaultUserAgent
        page.navigationDelegate = self
        webView = page
        configuration.websiteDataStore.httpCookieStore.add(self)
        retirement = websites.observeRetirement { [weak self] in self?.finish(.failure(CancellationError())) }
        let authority = self.authority
        observation = authority.changes.sink { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
#if DEBUG
                defer { self.onPolicyEvaluation?() }
#endif
                do {
                    try authority.checkLiveSurface()
                } catch {
                    self.finish(.failure(error))
                }
            }
        }
        if presentsPage {
            presentation = PagePresentation(webView: page, origin: "\(url.scheme ?? "https")://\(host)", host: host,
                                            onClose: { [weak self] in self?.finish(.failure(CancellationError())) })
            guard presentation != nil else { finish(.failure(HostNetworkPolicyOutcome.foregroundPermissionRequired)); return }
        }
        // This is a request deadline, not an ordering or cookie-polling mechanism.
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            self?.finish(.failure(ItoError.hostCallTimedOut(.webview)))
        }
        loadPage(page, url)
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
            do { try self.authority.checkLiveSurface() } catch { self.finish(.failure(error)); return }
            self.finish(.success(AppNetCloudflareResolution(userAgent: page.customUserAgent ?? CloudflareManager.defaultUserAgent, cookies: matching)))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard self.webView === webView else { decisionHandler(.cancel); return }
        decisionHandler(decideNavigation(to: navigationAction.request.url))
    }

    /// The policy for one navigation of the challenge page, in any frame. Local `about:`, `blob:` and `data:`
    /// documents make no HTTP request and need no network admission; an HTTP(S) request needs the interactive
    /// admission, and a downgrade or credentials in the URL end the challenge. Any other scheme is cancelled.
    func decideNavigation(to target: URL?) -> WKNavigationActionPolicy {
        guard completion != nil, let target, let scheme = target.scheme?.lowercased() else { return .cancel }
        if ["about", "blob", "data"].contains(scheme) { return .allow }
        guard scheme == "https" || scheme == "http" else { return .cancel }
        do {
            try authority.checkInteractive()
            guard target.user == nil, target.password == nil,
                  !(url.scheme == "https" && scheme == "http") else { throw URLError(.unsupportedURL) }
            return .allow
        } catch HostNetworkPolicyOutcome.foregroundPermissionRequired {
            return .cancel
        } catch {
            finish(.failure(error))
            return .cancel
        }
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
        if let retirement { websites.removeObserver(retirement) }
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
