import Foundation

/// Owns asynchronous test response delivery without transferring URLProtocol's unavailable
/// Sendable conformance. Framework properties are snapshotted synchronously; all retained
/// callback identity, delivery and cancellation state stays behind the recursive lock.
final class TrackerTestResponseDelivery: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var owner: URLProtocol?
    private var client: (any URLProtocolClient)?
    private var url: URL?
    private var cancelled = false
    private var delivered = false

    func bind(to owner: URLProtocol) -> Bool {
        lock.withLock {
            guard !cancelled, self.owner == nil,
                  let client = owner.client, let url = owner.request.url else { return false }
            self.owner = owner
            self.client = client
            self.url = url
            return true
        }
    }

    func finish(status: Int, body: Data, headers: [String: String]? = nil) {
        lock.withLock {
            guard !cancelled, !delivered, let owner, let client, let url else { return }
            delivered = true
            defer { releaseIdentity() }
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers) else {
                client.urlProtocol(owner, didFailWithError: URLError(.badServerResponse))
                return
            }
            client.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
            guard !cancelled else { return }
            client.urlProtocol(owner, didLoad: body)
            guard !cancelled else { return }
            client.urlProtocolDidFinishLoading(owner)
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            releaseIdentity()
        }
    }

    private func releaseIdentity() {
        owner = nil
        client = nil
        url = nil
    }
}
