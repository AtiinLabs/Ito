import Foundation
import Nuke
@testable import Ito

/// Test helpers for reading offline copies: serving one locator's bytes, and waiting for a reader page.
@MainActor
enum OfflineReadingTestSupport {
    /// The bytes one offline locator serves, or the error the loader reports.
    nonisolated static func load(_ loader: OfflineAssetDataLoader, _ request: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = loader.loadData(
                with: request,
                didReceiveData: { data, _ in continuation.resume(returning: data) },
                completion: { error in
                    if let error { continuation.resume(throwing: error) }
                }
            )
        }
    }

    /// Waits until the page settles. Observers run on every publication, so the first ready or failed
    /// state decides the answer. The answer is whether the page decoded.
    static func awaitSettled(
        _ session: ReaderPageImageSession,
        _ descriptor: ReaderPageImageDescriptor
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let waiter = SettlementWaiter(continuation)
            waiter.observation = session.observe(descriptor.key) { state in
                switch state.phase {
                case .ready:
                    waiter.settle(true)
                case .failed:
                    waiter.settle(false)
                case .idle, .loading:
                    break
                }
            }
            _ = session.acquire(descriptor, consumer: .visible)
        }
    }
}

@MainActor
private final class SettlementWaiter {
    private var continuation: CheckedContinuation<Bool, Never>?
    var observation: ReaderImageObservation?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func settle(_ decoded: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: decoded)
    }
}

/// Counts the requests a pipeline sends to the network. It never answers, so any count above zero is
/// a request the offline path should not have made.
final class CountingDataLoader: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        _ = (request, didReceiveData)
        lock.lock()
        requests += 1
        lock.unlock()
        completion(URLError(.notConnectedToInternet))
        return NoopCancellation()
    }
}

private final class NoopCancellation: Cancellable, @unchecked Sendable {
    func cancel() {}
}
