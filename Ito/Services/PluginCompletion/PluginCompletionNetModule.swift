import Foundation
import ito_runner

/// Host networking for one completion attempt.
///
/// Each instance owns a private ephemeral session and is discarded with its attempt. It carries
/// no browser state of its own: no URL cache, no credential store, no Cloudflare solving and no
/// web view. The plugin's stored website cookies are sent read-only; cookies the response sets are
/// ignored, so an attempt never changes the session. Every redirect is refused, so a credentialed
/// request can never be forwarded to another location; the redirect response itself is returned
/// to the plugin, which reports it as an unexpected response. Cancelling the calling task cancels
/// the underlying transfer. A change to the source's trusted certificates cancels transfers in
/// flight at once, and every later request fails as a configuration change.
nonisolated final class PluginCompletionNetModule: NetModule, Sendable {
    static let requestTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 60
    /// Completion endpoints answer with an empty or tiny body. A larger body is not read into
    /// memory; the request fails like any other transport failure.
    static let defaultMaximumResponseBytes = 8 * 1_024 * 1_024

    private static let headerNameCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~"
    )

    private let session: URLSession
    private let maximumResponseBytes: Int
    private let cookies: @Sendable (URL) -> [HTTPCookie]
    private let trust: (pluginID: String, store: PluginTrustStore)?
    private let trustObservation: PluginTrustObservation?
    /// The source's trust generation when this attempt started.
    private let trustGeneration: UUID?
    private let transfers = TrustBoundTransfers()

    /// `cookies` returns the plugin's stored cookies for a URL. `configuration` and
    /// `maximumResponseBytes` exist so tests can install a protocol stub and a small limit.
    /// Whatever the configuration carries, the session is made stateless here.
    init(
        configuration: URLSessionConfiguration = .ephemeral,
        maximumResponseBytes: Int = PluginCompletionNetModule.defaultMaximumResponseBytes,
        cookies: @escaping @Sendable (URL) -> [HTTPCookie] = { _ in [] },
        trust: (pluginID: String, store: PluginTrustStore)? = nil
    ) {
        let hardened = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        hardened.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        hardened.urlCache = nil
        hardened.httpCookieStorage = nil
        hardened.httpCookieAcceptPolicy = .never
        hardened.httpShouldSetCookies = false
        hardened.urlCredentialStorage = nil
        hardened.waitsForConnectivity = false
        hardened.timeoutIntervalForRequest = Self.requestTimeout
        hardened.timeoutIntervalForResource = Self.resourceTimeout
        let session = URLSession(configuration: hardened)
        self.session = session
        self.maximumResponseBytes = maximumResponseBytes
        self.cookies = cookies
        self.trust = trust
        if let trust {
            // A connection authenticated under the old trust must not carry another byte. The
            // session itself is only invalidated by `invalidate()`, never while a request may be
            // about to start on it.
            let transfers = transfers
            let observed = trust.store.observeTrustChanges(pluginID: trust.pluginID) {
                transfers.revoke()
            }
            trustObservation = observed.observation
            trustGeneration = observed.generation
        } else {
            trustObservation = nil
            trustGeneration = nil
        }
    }

    deinit {
        trustObservation?.cancel()
        session.invalidateAndCancel()
    }

    /// False once the source's trusted certificates changed after this attempt started.
    var isTrustCurrent: Bool {
        guard let trust, let trustGeneration else { return true }
        return !transfers.isRevoked && trust.store.transportGeneration(for: trust.pluginID) == trustGeneration
    }

    /// Ends the session now: transfers still running are cancelled and later requests fail.
    func invalidate() {
        trustObservation?.cancel()
        session.invalidateAndCancel()
    }

    func fetch(request: NetRequest) async throws -> NetResponse {
        guard isTrustCurrent else { throw PluginCompletionExecutionFailure.configurationChanged }
        let urlRequest = try Self.makeRequest(from: request, cookies: cookies)
        let refusal = RedirectRefusal(pluginID: trust?.pluginID, trustStore: trust?.store, recordsPending: false)
        let id = UUID()
        // Registered atomically with a trust change: either the change refuses it here, or it
        // cancels the registered transfer.
        guard let running = transfers.start(id, { Task { try await self.transfer(urlRequest, refusal: refusal) } }) else {
            throw PluginCompletionExecutionFailure.configurationChanged
        }
        defer { transfers.finish(id) }
        do {
            let response = try await withTaskCancellationHandler {
                try await running.value
            } onCancel: {
                running.cancel()
            }
            guard isTrustCurrent else { throw PluginCompletionExecutionFailure.configurationChanged }
            return response
        } catch {
            // Whatever ended the transfer, a trust change is what the attempt reports.
            if !isTrustCurrent { throw PluginCompletionExecutionFailure.configurationChanged }
            if let redirect = refusal.response { return redirect }
            if !Task.isCancelled, let error = refusal.trustError { throw error }
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func transfer(_ request: URLRequest, refusal: RedirectRefusal) async throws -> NetResponse {
        let (bytes, response) = try await session.bytes(for: request, delegate: refusal)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.expectedContentLength > Int64(maximumResponseBytes) {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var body: [UInt8] = []
        for try await byte in bytes {
            guard body.count < maximumResponseBytes else { throw URLError(.dataLengthExceedsMaximum) }
            body.append(byte)
        }
        return Self.netResponse(from: http, body: body)
    }

    fileprivate static func netResponse(from response: HTTPURLResponse, body: [UInt8]) -> NetResponse {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            headers[String(describing: name)] = String(describing: value)
        }
        return NetResponse(status: Int32(response.statusCode), headers: headers, body: body)
    }

    private static func makeRequest(
        from request: NetRequest,
        cookies: (URL) -> [HTTPCookie]
    ) throws -> URLRequest {
        guard let url = URL(string: request.url),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            // Only the network: a plugin cannot point this module at a local file or another scheme.
            throw URLError(.unsupportedURL)
        }
        guard isToken(request.method) else { throw URLError(.badURL) }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlRequest.timeoutInterval = requestTimeout
        for (name, value) in request.headers {
            guard isToken(name), !value.utf8.contains(where: { $0 == 0x0D || $0 == 0x0A || $0 == 0x00 }) else {
                throw URLError(.badURL)
            }
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if urlRequest.value(forHTTPHeaderField: "Cookie") == nil {
            let stored = cookies(url)
            if !stored.isEmpty {
                urlRequest.setValue(stored.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
            }
        }
        if let body = request.body {
            urlRequest.httpBody = Data(body)
        }
        return urlRequest
    }

    /// An RFC 9110 token: what an HTTP method or header name may be made of.
    private static func isToken(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { headerNameCharacters.contains($0) }
    }
}

/// Refuses every redirect. The redirect response is kept so the caller can return it as the
/// answer, whichever way URLSession then ends the transfer.
private nonisolated final class RedirectRefusal: PluginTrustDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var refused: NetResponse?

    var response: NetResponse? {
        lock.withLock { refused }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let redirect = PluginCompletionNetModule.netResponse(from: response, body: [])
        lock.withLock { refused = redirect }
        completionHandler(nil)
        task.cancel()
    }
}

/// The transfers of one attempt, and whether the source's trust changed under it. Starting a
/// transfer and revoking are serialized, so a revocation either refuses a transfer before it
/// starts or cancels it once registered.
private nonisolated final class TrustBoundTransfers: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    private var running: [UUID: Task<NetResponse, any Error>] = [:]

    var isRevoked: Bool {
        lock.withLock { revoked }
    }

    /// Starts the transfer `make` creates and registers it, or returns nil after a revocation.
    func start(_ id: UUID, _ make: () -> Task<NetResponse, any Error>) -> Task<NetResponse, any Error>? {
        lock.withLock {
            guard !revoked else { return nil }
            let task = make()
            running[id] = task
            return task
        }
    }

    func finish(_ id: UUID) {
        lock.withLock { running[id] = nil }
    }

    /// Cancels every running transfer and refuses later ones.
    func revoke() {
        let cancelled = lock.withLock { () -> [Task<NetResponse, any Error>] in
            revoked = true
            defer { running.removeAll() }
            return Array(running.values)
        }
        cancelled.forEach { $0.cancel() }
    }
}
