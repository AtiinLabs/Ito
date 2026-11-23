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
    /// The host's WebKit user agent, or "" when none can be read now. Throws `CancellationError` if the caller is cancelled.
    nonisolated func cachedUserAgent(for host: String) async throws -> String
    nonisolated func resolveChallenge(for url: URL, authority: NetworkRequestAuthority?) async throws -> AppNetCloudflareResolution
}

struct LiveAppNetCloudflareHandler: AppNetCloudflareHandling {
    let manager: CloudflareManager?

    nonisolated func cachedUserAgent(for host: String) async throws -> String {
        try await manager?.userAgent.value() ?? ""
    }

    nonisolated func resolveChallenge(for url: URL, authority: NetworkRequestAuthority?) async throws -> AppNetCloudflareResolution {
        guard let authority, let manager else { throw HostNetworkPolicyOutcome.foregroundPermissionRequired }
        return try await manager.resolveChallenge(for: url, authority: authority)
    }
}

/// Network for one plugin's runner. Site cookies are stored for this plugin only.
actor AppNetModule: NetModule {
    /// Replaced when this plugin's trust changes; see `PluginSessionPool`.
    private let sessions: PluginSessionPool
    private let cloudflare: any AppNetCloudflareHandling
    private let retryLogger: any AppNetRetryLogging
    private let pluginID: String
    private let cookieJar: PluginCookieJar
    private let trust: PluginTrustStore?
    private let contexts: PluginNetworkContexts?
    private let admitContext: @Sendable (NetworkOperationContext) throws -> Void
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// A rate-limited safe request is sent again at most this many times.
    static let maxRateLimitRetries = 2
    /// The longest `Retry-After` the host waits out. A longer one, or none, goes back to the plugin as the 429.
    static let maxRateLimitWait: TimeInterval = 15
    /// Hosts one of this plugin's requests is solving a challenge for. A request reaching the same challenge
    /// meanwhile gets the challenge response as is: concurrent requests never stack challenge pages for the user.
    private var hostsSolvingChallenge: Set<String> = []

    init(pluginID: String, cookieJar: PluginCookieJar, trust: PluginTrustStore, contexts: PluginNetworkContexts? = nil, cloudflare: CloudflareManager?) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.urlCredentialStorage = nil
        self.sessions = PluginSessionPool(configuration: Self.uncached(config), trust: trust)
        self.cloudflare = LiveAppNetCloudflareHandler(manager: cloudflare)
        self.retryLogger = OSLogAppNetRetryLogger()
        self.pluginID = pluginID
        self.cookieJar = cookieJar
        self.trust = trust
        self.contexts = contexts
        self.admitContext = { _ in }
        self.sleep = Self.taskSleep
    }

    init(
        configuration: URLSessionConfiguration,
        cloudflare: any AppNetCloudflareHandling,
        retryLogger: any AppNetRetryLogging,
        pluginID: String,
        cookieJar: PluginCookieJar,
        trust: PluginTrustStore? = nil,
        contexts: PluginNetworkContexts? = nil,
        admitContext: @escaping @Sendable (NetworkOperationContext) throws -> Void = { _ in },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = AppNetModule.taskSleep
    ) {
        self.sessions = PluginSessionPool(configuration: Self.uncached(configuration), trust: trust)
        self.cloudflare = cloudflare
        self.retryLogger = retryLogger
        self.pluginID = pluginID
        self.cookieJar = cookieJar
        self.trust = trust
        self.contexts = contexts
        self.admitContext = admitContext
        self.sleep = sleep
    }

    @Sendable nonisolated static func taskSleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// A cached answer skips the TLS handshake, so a changed or revoked pin would never be
    /// checked; plugin requests therefore neither read nor write any response cache.
    private static func uncached(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        let config = (configuration.copy() as? URLSessionConfiguration) ?? .default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }

    func fetch(request: NetRequest, context: NetworkOperationContext) async throws -> NetResponse {
        return try await fetchInternal(request: request, context: context, isRetry: false, rateLimitRetries: 0)
    }

    private func fetchInternal(
        request: NetRequest,
        context: NetworkOperationContext,
        isRetry: Bool,
        rateLimitRetries: Int
    ) async throws -> NetResponse {
        try Task.checkCancellation()
        try admitContext(context)
        let authority = contexts.map { NetworkRequestAuthority(contexts: $0, context: context) }
        try authority?.check()
        let cookieGeneration = cookieJar.captureWriteGeneration()
        guard let url = URL(string: request.url) else {
            throw URLError(.badURL)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false

        var updatedHeaders = request.headers

        // The host's WebKit user agent replaces any the plugin sent, under whatever case it used: a clearance is bound to
        // it, and `X-Used-User-Agent` reports what was sent. Without one, the plugin's own header (if any) is kept.
        if !isRetry, let host = url.host {
            let cachedUA = try await cloudflare.cachedUserAgent(for: host)
            if !cachedUA.isEmpty {
                updatedHeaders = Self.headers(updatedHeaders, settingUserAgent: cachedUA)
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

        let sessions = self.sessions
        let cookieJar = self.cookieJar
        let pluginID = self.pluginID
        let admitContext = self.admitContext
        let redirects = AppNetCookieRedirects(
            originalHost: url.host,
            explicitCookies: explicitCookies,
            storedCookies: { url in Self.storedCookies(for: url, pluginID: pluginID, in: cookieJar) },
            keep: { response in
                Self.keepSetCookies(of: response, pluginID: pluginID, in: cookieJar, generation: cookieGeneration)
            },
            pluginID: pluginID,
            trust: trust,
            admission: {
                try admitContext(context)
                try authority?.check()
            }
        )

        let data: Data
        let response: URLResponse
        let wireRequest = urlRequest
        let method = request.method.uppercased()
        let refusesLateResult = ["GET", "HEAD", "OPTIONS"].contains(method)
        do {
            let transfer: @Sendable () async throws -> (Data, URLResponse) = {
                try await sessions.withSession(for: pluginID) { session in
                    try await session.data(for: wireRequest, delegate: redirects)
                }
            }

            if let authority {
                (data, response) = try await authority.perform(refusesLateResult: refusesLateResult, transfer)
            } else {
                (data, response) = try await transfer()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if refusesLateResult, let refusal = redirects.policyError { throw refusal }
            if let trustError = redirects.trustError { throw trustError }
            if (error as? URLError)?.code == .timedOut { throw ItoError.hostCallTimedOut(.net) }
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        Self.keepSetCookies(of: httpResponse, pluginID: pluginID, in: cookieJar, generation: cookieGeneration)

        // --- Cloudflare challenge interception ---
        // Cloudflare marks every challenge page with `cf-mitigated: challenge`. A block page
        // ("Sorry, you have been blocked") also comes from Cloudflare with 403 and CF-Ray but
        // has no such header: no web view can solve it, so it goes back to the plugin as is.
        let statusCode = httpResponse.statusCode
        if !isRetry {
            let isChallenge = httpResponse.allHeaderFields.contains { key, value in
                String(describing: key).lowercased() == "cf-mitigated"
                    && String(describing: value).trimmingCharacters(in: .whitespaces).lowercased() == "challenge"
            }

            let challengeHost = url.host ?? ""
            if isChallenge, !hostsSolvingChallenge.contains(challengeHost) {
                retryLogger.log(.challengeDetected)
                try authority?.checkInteractive()
                hostsSolvingChallenge.insert(challengeHost)
                defer { hostsSolvingChallenge.remove(challengeHost) }

                // The live handler routes through CloudflareManager on MainActor.
                let bypassResult = try await cloudflare.resolveChallenge(for: url, authority: authority)

                try Task.checkCancellation()
                try authority?.check()
                guard try cookieJar.store(bypassResult.cookies, pluginID: pluginID, ifCurrent: cookieGeneration) else {
                    throw CancellationError()
                }
                var retriedRequest = request
                var retriedHeaders = request.headers

                retriedHeaders = Self.headers(retriedHeaders, settingUserAgent: bypassResult.userAgent)

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
                let retriedResponse = try await fetchInternal(
                    request: retriedRequest, context: context, isRetry: true, rateLimitRetries: rateLimitRetries
                )
                retryLogger.log(.retryCompleted(status: retriedResponse.status))
                return retriedResponse
            }
        }
        // --------------------------------------

        // A site that is rate limiting says how long to wait. A safe request is sent again after a short wait, so
        // a plugin reading many pages gets them all instead of a 429 it may take for the end of the list. The
        // retry is admitted again like any request.
        if statusCode == 429, refusesLateResult, rateLimitRetries < Self.maxRateLimitRetries,
           let delay = Self.rateLimitDelay(httpResponse, now: Date()) {
            try await sleep(delay)
            try Task.checkCancellation()
            return try await fetchInternal(
                request: request, context: context, isRetry: isRetry, rateLimitRetries: rateLimitRetries + 1
            )
        }

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

    /// How long `response` asks to wait, when it is a wait the host takes on: `Retry-After` in seconds or as an
    /// HTTP date, at most `maxRateLimitWait` away.
    nonisolated static func rateLimitDelay(_ response: HTTPURLResponse, now: Date) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else { return nil }
        let delay: TimeInterval
        if let seconds = Int(value) {
            delay = TimeInterval(seconds)
        } else if let date = httpDate(value) {
            delay = max(0, date.timeIntervalSince(now))
        } else {
            return nil
        }
        return (0...maxRateLimitWait).contains(delay) ? delay : nil
    }

    /// An IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), the form HTTP dates are sent in.
    private nonisolated static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }

    /// The headers with one `User-Agent`: every spelling the plugin used is replaced, so two can never be sent together.
    nonisolated static func headers(_ headers: [String: String], settingUserAgent agent: String) -> [String: String] {
        var result = headers.filter { $0.key.lowercased() != "user-agent" }
        result["User-Agent"] = agent
        return result
    }

    /// Cookies belong to this source. Shared browser clearance is never source authorization.
    nonisolated static func storedCookies(for url: URL, pluginID: String, in cookieJar: PluginCookieJar) -> [HTTPCookie] {
        cookieJar.cookies(pluginID: pluginID, for: url)
    }

    /// The Cookie header for a request: this plugin's stored cookies, then those the plugin set itself;
    /// later layers win on the same name.
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
    nonisolated static func keepSetCookies(
        of response: HTTPURLResponse, pluginID: String, in cookieJar: PluginCookieJar, generation: UInt64
    ) {
        guard let url = response.url else { return }
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { fields, field in
            fields[String(describing: field.key)] = String(describing: field.value)
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !cookies.isEmpty else { return }
        _ = try? cookieJar.store(cookies, pluginID: pluginID, ifCurrent: generation)
    }
}

/// Follows a request's redirects with the right cookies: each redirect's Set-Cookie is kept for
/// the URL that sent it, and the next request carries only the cookies stored for its own URL.
/// The plugin's own Cookie header goes along only while the host stays the same.
nonisolated final class AppNetCookieRedirects: PluginTrustDelegate, @unchecked Sendable {
    private let originalHost: String?
    private let explicitCookies: String?
    private let storedCookies: @Sendable (URL) -> [HTTPCookie]
    private let keep: @Sendable (HTTPURLResponse) -> Void
    private let admission: @Sendable () throws -> Void
    private let policyLock = NSLock()
    private var refusal: Error?
    var policyError: Error? { policyLock.withLock { refusal } }

    init(
        originalHost: String?,
        explicitCookies: String?,
        storedCookies: @escaping @Sendable (URL) -> [HTTPCookie],
        keep: @escaping @Sendable (HTTPURLResponse) -> Void,
        pluginID: String,
        trust: PluginTrustStore?,
        admission: @escaping @Sendable () throws -> Void = {}
    ) {
        self.originalHost = originalHost?.lowercased()
        self.explicitCookies = explicitCookies
        self.storedCookies = storedCookies
        self.keep = keep
        self.admission = admission
        super.init(pluginID: pluginID, trustStore: trust)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        do { try admission() } catch {
            policyLock.withLock { refusal = error }
            completionHandler(nil)
            task.cancel()
            return
        }
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
