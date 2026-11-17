import Foundation
import WebKit

/// The host has no WebKit user agent to bind a clearance to. Its challenge fails rather than resolve without one.
enum WebKitUserAgentError: Error, Equatable {
    case unavailable
}

/// The user agent WebKit sends when nothing overrides it: the one every plugin web view sends, and so the
/// one a Cloudflare clearance is bound to. Plugin HTTP, image transfers and downloads send this same value,
/// so a clearance earned in a web view also works for the requests that follow it.
///
/// The value is read from a web view's `navigator.userAgent` on the main actor, then kept in memory. Callers
/// await it; nothing waits on the main thread. A failed read is not cached, so the next caller probes again.
actor WebKitUserAgent {
    private let probe: @Sendable @MainActor () async -> String?
    private var known: String?
    private var probing: Task<String?, Never>?

    init(probe: @escaping @Sendable @MainActor () async -> String? = WebKitUserAgent.probeWebKit) {
        self.probe = probe
    }

    /// The WebKit user agent, or nil if WebKit reports none.
    func value() async -> String? {
        if let known { return known }
        if let probing { return await probing.value }
        let probe = self.probe
        let task = Task<String?, Never> { @MainActor in await probe() }
        probing = task
        let result = await task.value
        probing = nil
        known = result
        return result
    }

    /// `request` with the WebKit user agent set, unless the request already names one. A plugin's own
    /// `User-Agent` header is kept, as the image and download transfers always kept it.
    func withUserAgent(_ request: URLRequest) async -> URLRequest {
        guard request.value(forHTTPHeaderField: "User-Agent") == nil, let agent = await value() else {
            return request
        }
        var sent = request
        sent.setValue(agent, forHTTPHeaderField: "User-Agent")
        return sent
    }

    /// Reads `navigator.userAgent` from a web view with the default configuration, which is the configuration
    /// plugin and challenge web views use, so it reports the same value they send.
    @MainActor
    static func probeWebKit() async -> String? {
        let page = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let result = try? await page.evaluateJavaScript("navigator.userAgent")
        withExtendedLifetime(page) {}
        return result as? String
    }
}
