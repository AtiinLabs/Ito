import OSLog
import Foundation
import WebKit
import ito_runner

enum AppNetRetryEvent: Equatable, Sendable {
    case challengeDetected
    case retryStarted
    case retryCompleted(status: Int32)
}

enum AppNetRetryDiagnostic {
    nonisolated static func format(_ event: AppNetRetryEvent) -> String {
        switch event {
        case .challengeDetected:
            return "[AppNetModule] Cloudflare challenge detected."
        case .retryStarted:
            return "[AppNetModule] Cloudflare retry started."
        case .retryCompleted(let status):
            return "[AppNetModule] Cloudflare retry completed with status code: \(status)"
        }
    }
}

nonisolated protocol AppNetRetryLogging: Sendable {
    nonisolated func log(_ event: AppNetRetryEvent)
}

struct OSLogAppNetRetryLogger: AppNetRetryLogging {
    nonisolated func log(_ event: AppNetRetryEvent) {
        AppLogger.network.debug("\(AppNetRetryDiagnostic.format(event))")
    }
}

struct AppNetCloudflareResolution: @unchecked Sendable {
    let userAgent: String
    let cookies: [HTTPCookie]
}

nonisolated protocol AppNetCloudflareHandling: Sendable {
    nonisolated func cachedUserAgent(for host: String) async -> String
    nonisolated func resolveChallenge(for url: URL) async throws -> AppNetCloudflareResolution
}

struct LiveAppNetCloudflareHandler: AppNetCloudflareHandling {
    nonisolated func cachedUserAgent(for host: String) async -> String {
        await MainActor.run {
            CloudflareManager.shared.getCachedUserAgent(for: host)
        }
    }

    nonisolated func resolveChallenge(for url: URL) async throws -> AppNetCloudflareResolution {
        let result = try await CloudflareManager.shared.resolveChallenge(for: url)
        return AppNetCloudflareResolution(
            userAgent: result.userAgent,
            cookies: result.cookies
        )
    }
}

/// Network for one plugin's runner. Requests carry the shared store's cookies (Cloudflare
/// clearance) and then this plugin's own cookies; cookies the site sets are kept for this plugin
/// only.
actor AppNetModule: NetModule {
    private let urlSession: URLSession
    private let cloudflare: any AppNetCloudflareHandling
    private let retryLogger: any AppNetRetryLogging
    private let pluginID: String
    private let cookieJar: PluginCookieJar

    init(pluginID: String, cookieJar: PluginCookieJar) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: config)
        self.cloudflare = LiveAppNetCloudflareHandler()
        self.retryLogger = OSLogAppNetRetryLogger()
        self.pluginID = pluginID
        self.cookieJar = cookieJar
    }

    init(
        urlSession: URLSession,
        cloudflare: any AppNetCloudflareHandling,
        retryLogger: any AppNetRetryLogging,
        pluginID: String,
        cookieJar: PluginCookieJar
    ) {
        self.urlSession = urlSession
        self.cloudflare = cloudflare
        self.retryLogger = retryLogger
        self.pluginID = pluginID
        self.cookieJar = cookieJar
    }

    deinit {
        urlSession.invalidateAndCancel()
    }

    func fetch(request: NetRequest) async throws -> NetResponse {
        return try await fetchInternal(request: request, isRetry: false)
    }

    private func fetchInternal(request: NetRequest, isRetry: Bool) async throws -> NetResponse {
        guard let url = URL(string: request.url) else {
            throw URLError(.badURL)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false

        var updatedHeaders = request.headers

        // Always apply the cached User-Agent for this host if we have one
        if let host = url.host {
            let cachedUA = await cloudflare.cachedUserAgent(for: host)
            if !cachedUA.isEmpty {
                // If Cloudflare manager has a specific UA for this host, we must use it
                updatedHeaders["User-Agent"] = cachedUA
            } else if updatedHeaders["User-Agent"] == nil && updatedHeaders["user-agent"] == nil {
                // Default fallback if plugin didn't provide one
                updatedHeaders["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            }
        }

        // The plugin's own Cookie header is for this URL's host only: a redirect elsewhere drops it.
        let explicitCookies = updatedHeaders["Cookie"] ?? updatedHeaders["cookie"]
        updatedHeaders["cookie"] = nil
        updatedHeaders["Cookie"] = Self.cookieHeader(
            stored: Self.storedCookies(for: url, pluginID: pluginID, in: cookieJar),
            explicit: explicitCookies
        )

        for (key, value) in updatedHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        if let body = request.body {
            urlRequest.httpBody = Data(body)
        }

        let session = self.urlSession
        let cookieJar = self.cookieJar
        let pluginID = self.pluginID
        let redirects = AppNetCookieRedirects(
            originalHost: url.host,
            explicitCookies: explicitCookies,
            storedCookies: { url in Self.storedCookies(for: url, pluginID: pluginID, in: cookieJar) },
            keep: { response in Self.keepSetCookies(of: response, pluginID: pluginID, in: cookieJar) }
        )

        let (data, response) = try await session.data(for: urlRequest, delegate: redirects)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        Self.keepSetCookies(of: httpResponse, pluginID: pluginID, in: cookieJar)

        // --- Cloudflare Bypass Interception ---
        let statusCode = httpResponse.statusCode
        if !isRetry && (statusCode == 403 || statusCode == 503) {
            let isCloudflare = httpResponse.allHeaderFields.contains { key, value in
                let keyStr = String(describing: key).lowercased()
                let valStr = String(describing: value).lowercased()
                return (keyStr == "server" && valStr.contains("cloudflare")) || keyStr == "cf-ray"
            }

            if isCloudflare {
                retryLogger.log(.challengeDetected)

                // The live handler routes through CloudflareManager on MainActor.
                let bypassResult = try await cloudflare.resolveChallenge(for: url)

                var retriedRequest = request
                var retriedHeaders = request.headers

                retriedHeaders["User-Agent"] = bypassResult.userAgent

                // Explicitly inject cookies into the request headers because HTTPCookieStorage drops subdomains
                var cookieStrings: [String] = []
                for cookie in bypassResult.cookies {
                    cookieStrings.append("\(cookie.name)=\(cookie.value)")
                }

                let cookieHeaderValue = cookieStrings.joined(separator: "; ")
                if !cookieHeaderValue.isEmpty {
                    retriedHeaders["Cookie"] = cookieHeaderValue
                }

                retriedRequest.headers = retriedHeaders

                retryLogger.log(.retryStarted)
                let retriedResponse = try await fetchInternal(request: retriedRequest, isRetry: true)
                retryLogger.log(.retryCompleted(status: retriedResponse.status))
                return retriedResponse
            }
        }
        // --------------------------------------

        var resHeaders: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            resHeaders[String(describing: key)] = String(describing: value)
        }

        // Inject the used User-Agent so plugins know what was sent
        if let sentUA = urlRequest.value(forHTTPHeaderField: "User-Agent") {
            resHeaders["X-Used-User-Agent"] = sentUA
        }

        return NetResponse(
            status: Int32(statusCode),
            headers: resHeaders,
            body: [UInt8](data)
        )
    }

    /// The shared store's cookies for `url` (Cloudflare clearance), then this plugin's own.
    nonisolated static func storedCookies(for url: URL, pluginID: String, in cookieJar: PluginCookieJar) -> [HTTPCookie] {
        (HTTPCookieStorage.shared.cookies(for: url) ?? []) + cookieJar.cookies(pluginID: pluginID, for: url)
    }

    /// The Cookie header for a request: the shared store's cookies (Cloudflare clearance), then this
    /// plugin's own, then those the plugin set itself; later layers win on the same name.
    nonisolated static func cookieHeader(stored: [HTTPCookie], explicit: String?) -> String? {
        var names: [String] = []
        var values: [String: String] = [:]
        func add(_ name: String, _ value: String) {
            if values[name] == nil { names.append(name) }
            values[name] = value
        }
        for cookie in stored {
            add(cookie.name, cookie.value)
        }
        for component in (explicit ?? "").components(separatedBy: ";") {
            let parts = component.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            add(String(parts[0]).trimmingCharacters(in: .whitespaces), String(parts[1]).trimmingCharacters(in: .whitespaces))
        }
        guard !names.isEmpty else { return nil }
        return names.map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "; ")
    }

    /// Keeps the cookies `response` sets, for the URL that actually answered. A Keychain failure
    /// loses only this update; the response still reaches the plugin.
    nonisolated static func keepSetCookies(of response: HTTPURLResponse, pluginID: String, in cookieJar: PluginCookieJar) {
        guard let url = response.url else { return }
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { fields, field in
            fields[String(describing: field.key)] = String(describing: field.value)
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !cookies.isEmpty else { return }
        try? cookieJar.store(cookies, pluginID: pluginID)
    }
}

/// Follows a request's redirects with the right cookies: each redirect's Set-Cookie is kept for
/// the URL that sent it, and the next request carries only the cookies stored for its own URL.
/// The plugin's own Cookie header goes along only while the host stays the same.
private nonisolated final class AppNetCookieRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let originalHost: String?
    private let explicitCookies: String?
    private let storedCookies: @Sendable (URL) -> [HTTPCookie]
    private let keep: @Sendable (HTTPURLResponse) -> Void

    init(
        originalHost: String?,
        explicitCookies: String?,
        storedCookies: @escaping @Sendable (URL) -> [HTTPCookie],
        keep: @escaping @Sendable (HTTPURLResponse) -> Void
    ) {
        self.originalHost = originalHost?.lowercased()
        self.explicitCookies = explicitCookies
        self.storedCookies = storedCookies
        self.keep = keep
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        keep(response)
        guard let url = request.url else {
            completionHandler(request)
            return
        }
        var redirected = request
        let sameHost = url.host?.lowercased() == originalHost
        let header = AppNetModule.cookieHeader(
            stored: storedCookies(url),
            explicit: sameHost ? explicitCookies : nil
        )
        redirected.setValue(header, forHTTPHeaderField: "Cookie")
        completionHandler(redirected)
    }
}
