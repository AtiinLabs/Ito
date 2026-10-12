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

actor AppNetModule: NetModule {
    private let urlSession: URLSession
    private let cloudflare: any AppNetCloudflareHandling
    private let retryLogger: any AppNetRetryLogging

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: config)
        self.cloudflare = LiveAppNetCloudflareHandler()
        self.retryLogger = OSLogAppNetRetryLogger()
    }

    init(
        urlSession: URLSession,
        cloudflare: any AppNetCloudflareHandling,
        retryLogger: any AppNetRetryLogging
    ) {
        self.urlSession = urlSession
        self.cloudflare = cloudflare
        self.retryLogger = retryLogger
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

        if let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty {
            var cookieMap: [String: String] = [:]

            let existingCookieStr = updatedHeaders["Cookie"] ?? updatedHeaders["cookie"] ?? ""
            let components = existingCookieStr.components(separatedBy: "; ")
            for comp in components {
                let parts = comp.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    cookieMap[String(parts[0]).trimmingCharacters(in: .whitespaces)] = String(parts[1]).trimmingCharacters(in: .whitespaces)
                }
            }

            for cookie in cookies {
                cookieMap[cookie.name] = cookie.value
            }

            updatedHeaders["Cookie"] = cookieMap.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        }

        for (key, value) in updatedHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        if let body = request.body {
            urlRequest.httpBody = Data(body)
        }

        let session = self.urlSession

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

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
}
