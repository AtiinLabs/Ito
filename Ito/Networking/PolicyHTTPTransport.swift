import Foundation
import ito_runner

/// App-owned HTTP (repositories, subtitles, trackers): one immutable authority is checked before the request,
/// at every redirect and, for reads, before the response is published. The session stays injectable; this is
/// not a proxy and holds no second policy.
nonisolated struct PolicyHTTPTransport: Sendable {
    let session: URLSession
    let authority: NetworkRequestAuthority?

    /// - Parameter authority: nil only where no policy-owning composition exists (tests, previews).
    init(session: URLSession = URLSession(configuration: .ephemeral), authority: NetworkRequestAuthority? = nil) {
        self.session = session
        self.authority = authority
    }

    /// - Parameter mutates: a write. Its response is never replaced by a later refusal, and a transfer the
    ///   system or a policy change cut short surfaces as the underlying error, because its outcome is unknown.
    func data(for request: URLRequest, mutates: Bool = false) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        try authority?.check()
        let redirects = PolicyHTTPRedirects(original: request.url, authority: authority)
        let method = request.httpMethod?.uppercased() ?? "GET"
        let isMutation = mutates || !["GET", "HEAD", "OPTIONS"].contains(method)
        let session = self.session
        let transfer: @Sendable () async throws -> (Data, URLResponse) = {
            try await session.data(for: request, delegate: redirects)
        }
        do {
            if let authority {
                return try await authority.perform(refusesLateResult: !isMutation, transfer)
            }
            return try await transfer()
        } catch {
            try Task.checkCancellation()
            if !isMutation, let refusal = redirects.refusal { throw refusal }
            throw error
        }
    }
}

private nonisolated final class PolicyHTTPRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let original: URL?
    private let authority: NetworkRequestAuthority?
    private let lock = NSLock()
    private var denied: Error?

    var refusal: Error? { lock.withLock { denied } }

    init(original: URL?, authority: NetworkRequestAuthority?) {
        self.original = original
        self.authority = authority
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        do {
            try authority?.check()
            guard let target = request.url, target.user == nil, target.password == nil,
                  target.scheme == "http" || target.scheme == "https",
                  !(response.url?.scheme == "https" && target.scheme == "http") else {
                throw URLError(.unsupportedURL)
            }
            var redirected = request
            let sameOrigin = target.scheme == original?.scheme
                && target.host?.lowercased() == original?.host?.lowercased()
                && target.port == original?.port
            if !sameOrigin {
                for header in ["Authorization", "Cookie", "Proxy-Authorization"] {
                    redirected.setValue(nil, forHTTPHeaderField: header)
                }
            }
            completionHandler(redirected)
        } catch {
            lock.withLock { denied = error }
            completionHandler(nil)
            task.cancel()
        }
    }
}
