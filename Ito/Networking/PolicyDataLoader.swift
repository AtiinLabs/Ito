import Foundation
import Nuke

/// A default image loader that can carry the host's request authority to the wire.
///
/// Nuke's own `DataLoader` forwards one session-wide delegate and has no per-request hook, so it cannot
/// re-check one request's authority at a redirect. This loader performs the same non-incremental `URLSession`
/// transfer with a per-request redirect delegate, and validates the response the way `DataLoader` does.
nonisolated protocol AuthorizedDataLoading: DataLoading {
    func loadData(
        with request: URLRequest,
        authority: NetworkRequestAuthority,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable
}

nonisolated final class PolicyDataLoader: AuthorizedDataLoading, @unchecked Sendable {
    private let session: URLSession

    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        start(request, transport: PolicyHTTPTransport(session: session), didReceiveData: didReceiveData, completion: completion)
    }

    func loadData(
        with request: URLRequest,
        authority: NetworkRequestAuthority,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        start(
            request,
            transport: PolicyHTTPTransport(session: session, authority: authority),
            didReceiveData: didReceiveData,
            completion: completion
        )
    }

    private func start(
        _ request: URLRequest,
        transport: PolicyHTTPTransport,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        let task = Task {
            do {
                let (data, response) = try await transport.data(for: request)
                try Task.checkCancellation()
                if let invalid = DataLoader.validate(response: response) {
                    completion(invalid)
                    return
                }
                didReceiveData(data, response)
                completion(nil)
            } catch is CancellationError {
                completion(URLError(.cancelled))
            } catch {
                completion(error)
            }
        }
        return TaskCancellable(task: task)
    }
}

private nonisolated final class TaskCancellable: Cancellable, @unchecked Sendable {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}
