import Foundation
import ito_runner

/// The session delegate of an app-owned `URLSession` whose requests are made by code the app does not own, such as
/// a tracker SDK that only accepts a `URLSession`. A session delegate receives the redirects of every task of
/// its session, including `session.data(for:)`, so a redirect is checked against the live policy without a hook
/// in that code and without a proxy.
///
/// A redirect the policy no longer admits, one that leaves HTTPS, or one that carries user information ends the
/// request: the caller receives the redirect response, which is not a success. A redirect to another origin never
/// carries credentials.
nonisolated final class PolicyRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let authorities: AppNetworkAuthorityProvider
    private let purpose: NetworkOperationContext.Purpose

    init(authorities: AppNetworkAuthorityProvider, purpose: NetworkOperationContext.Purpose) {
        self.authorities = authorities
        self.purpose = purpose
    }

    /// A session over `configuration` whose redirects this delegate decides.
    static func session(
        configuration: URLSessionConfiguration = .default,
        authorities: AppNetworkAuthorityProvider,
        purpose: NetworkOperationContext.Purpose
    ) -> URLSession {
        URLSession(
            configuration: configuration,
            delegate: PolicyRedirectDelegate(authorities: authorities, purpose: purpose),
            delegateQueue: nil
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        do {
            try authorities.authority(purpose: purpose)?.check()
        } catch {
            completionHandler(nil)
            return
        }
        guard let target = request.url, target.user == nil, target.password == nil,
              target.scheme == "https" || (target.scheme == "http" && response.url?.scheme != "https") else {
            completionHandler(nil)
            return
        }
        var redirected = request
        let origin = task.originalRequest?.url
        let sameOrigin = target.scheme == origin?.scheme
            && target.host?.lowercased() == origin?.host?.lowercased()
            && target.port == origin?.port
        if !sameOrigin {
            for header in ["Authorization", "Cookie", "Proxy-Authorization"] {
                redirected.setValue(nil, forHTTPHeaderField: header)
            }
        }
        completionHandler(redirected)
    }

    /// Every task of the session ends here, including `session.data(for:)` calls inside the tracker SDKs, so a failed
    /// tracker request is logged without a hook in their code.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        NetworkFailureDiagnostics.record(error, host: task.originalRequest?.url?.host, transport: "tracker")
    }
}
