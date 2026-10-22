import Foundation

nonisolated enum PluginImageTransportError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case userInfoNotAllowed
    case unpermittedOrigin
    case unpermittedScheme
    case invalidHeaderName
    case invalidHeaderValue
    case prohibitedHeader
    case crossOriginRedirectBlocked
    case httpsDowngradeBlocked
    case badServerResponse
    case nonHTTPResponse
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The image URL is invalid."
        case .userInfoNotAllowed:
            return "Credentials or user information are not allowed in image URLs."
        case .unpermittedOrigin:
            return "The image URL origin is not permitted."
        case .unpermittedScheme:
            return "The image URL scheme must be HTTP or HTTPS."
        case .invalidHeaderName:
            return "An HTTP header name contains invalid characters."
        case .invalidHeaderValue:
            return "An HTTP header value contains invalid newline characters."
        case .prohibitedHeader:
            return "The specified HTTP header is prohibited."
        case .crossOriginRedirectBlocked:
            return "Cross-origin redirects are blocked for plugin image requests."
        case .httpsDowngradeBlocked:
            return "HTTPS to HTTP redirect downgrades are prohibited."
        case .badServerResponse:
            return "The server returned a non-success response."
        case .nonHTTPResponse:
            return "The server did not return a valid HTTP response."
        case .downloadFailed:
            return "The image could not be downloaded. Check the connection and source settings."
        }
    }
}

nonisolated final class PluginImageTransport: Sendable {
    private let session: URLSession

    private static let prohibitedHeaders: Set<String> = [
        "host",
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
        "content-length"
    ]

    // RFC 9110 token characters: DIGIT, ALPHA, and "!#$%&'*+-.^_`|~"
    private static let validHeaderNameChars = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~"
    )

    init(configuration: URLSessionConfiguration = .ephemeral) {
        let config: URLSessionConfiguration
        if let copied = configuration.copy() as? URLSessionConfiguration {
            config = copied
        } else {
            config = .ephemeral
        }
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
    }

    struct NormalizedOrigin: Equatable, Hashable, CustomStringConvertible, Sendable {
        let scheme: String
        let host: String
        let port: Int

        var description: String {
            let isDefaultPort = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
            if isDefaultPort {
                return "\(scheme)://\(host)"
            } else {
                return "\(scheme)://\(host):\(port)"
            }
        }
    }

    static func parseAndNormalizeOrigin(from url: URL) throws -> NormalizedOrigin {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PluginImageTransportError.invalidURL
        }
        return try parseAndNormalizeOrigin(from: components)
    }

    static func parseAndNormalizeOrigin(from string: String) throws -> NormalizedOrigin {
        guard let components = URLComponents(string: string) else {
            throw PluginImageTransportError.invalidURL
        }
        return try parseAndNormalizeOrigin(from: components)
    }

    private static func parseAndNormalizeOrigin(from components: URLComponents) throws -> NormalizedOrigin {
        if components.user != nil || components.password != nil {
            throw PluginImageTransportError.userInfoNotAllowed
        }

        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw PluginImageTransportError.unpermittedScheme
        }

        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw PluginImageTransportError.invalidURL
        }

        let port: Int
        if let explicitPort = components.port {
            guard explicitPort > 0 && explicitPort <= 65535 else {
                throw PluginImageTransportError.invalidURL
            }
            port = explicitPort
        } else {
            port = (scheme == "https") ? 443 : 80
        }

        return NormalizedOrigin(scheme: scheme, host: host, port: port)
    }

    private static func validateHeaders(_ headers: [String: String]?) throws -> [String: String] {
        guard let headers = headers, !headers.isEmpty else {
            return [:]
        }

        var validated: [String: String] = [:]
        for (name, value) in headers {
            guard !name.isEmpty else {
                throw PluginImageTransportError.invalidHeaderName
            }

            guard name.unicodeScalars.allSatisfy({ validHeaderNameChars.contains($0) }) else {
                throw PluginImageTransportError.invalidHeaderName
            }

            if value.utf8.contains(where: { $0 == 0x0D || $0 == 0x0A }) {
                throw PluginImageTransportError.invalidHeaderValue
            }

            let lowerName = name.lowercased()
            if prohibitedHeaders.contains(lowerName) {
                throw PluginImageTransportError.prohibitedHeader
            }

            validated[name] = value
        }

        return validated
    }

    func fetch(
        url: URL,
        headers: [String: String]?,
        allowedOrigins: [String]
    ) async throws -> (Data, HTTPURLResponse) {
        let initialOrigin = try Self.parseAndNormalizeOrigin(from: url)

        var normalizedAllowedOrigins = Set<NormalizedOrigin>()
        for allowed in allowedOrigins {
            let norm = try Self.parseAndNormalizeOrigin(from: allowed)
            normalizedAllowedOrigins.insert(norm)
        }

        guard normalizedAllowedOrigins.contains(initialOrigin) else {
            throw PluginImageTransportError.unpermittedOrigin
        }

        let validatedHeaders = try Self.validateHeaders(headers)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, val) in validatedHeaders {
            request.setValue(val, forHTTPHeaderField: key)
        }

        let delegate = RedirectDelegate(
            originalOrigin: initialOrigin,
            explicitHeaders: validatedHeaders
        )

        do {
            let (data, response) = try await session.data(for: request, delegate: delegate)

            if let redirectError = delegate.redirectError {
                throw redirectError
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw PluginImageTransportError.nonHTTPResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw PluginImageTransportError.badServerResponse
            }

            return (data, httpResponse)
        } catch {
            if let redirectError = delegate.redirectError {
                throw redirectError
            }
            if let safeError = error as? PluginImageTransportError {
                throw safeError
            }
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            // Foundation errors can retain signed URLs in userInfo, including when their
            // localized description looks harmless. Do not let that request material escape.
            throw PluginImageTransportError.downloadFailed
        }
    }
}

private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let originalOrigin: PluginImageTransport.NormalizedOrigin
    private let explicitHeaders: [String: String]
    private let lock = NSLock()
    private var _redirectError: Error?

    init(
        originalOrigin: PluginImageTransport.NormalizedOrigin,
        explicitHeaders: [String: String]
    ) {
        self.originalOrigin = originalOrigin
        self.explicitHeaders = explicitHeaders
        super.init()
    }

    var redirectError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return _redirectError
    }

    private func setRedirectError(_ error: Error) {
        lock.lock()
        _redirectError = error
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let newURL = request.url else {
            setRedirectError(PluginImageTransportError.invalidURL)
            completionHandler(nil)
            task.cancel()
            return
        }

        let newOrigin: PluginImageTransport.NormalizedOrigin
        do {
            newOrigin = try PluginImageTransport.parseAndNormalizeOrigin(from: newURL)
        } catch {
            setRedirectError(error)
            completionHandler(nil)
            task.cancel()
            return
        }

        if originalOrigin.scheme == "https" && newOrigin.scheme == "http" {
            setRedirectError(PluginImageTransportError.httpsDowngradeBlocked)
            completionHandler(nil)
            task.cancel()
            return
        }

        guard newOrigin == originalOrigin else {
            setRedirectError(PluginImageTransportError.crossOriginRedirectBlocked)
            completionHandler(nil)
            task.cancel()
            return
        }

        var redirectedRequest = request
        for (name, val) in explicitHeaders {
            if redirectedRequest.value(forHTTPHeaderField: name) == nil {
                redirectedRequest.setValue(val, forHTTPHeaderField: name)
            }
        }

        completionHandler(redirectedRequest)
    }
}
