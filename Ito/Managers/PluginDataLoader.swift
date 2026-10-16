import Foundation
import Nuke
import ito_runner

/// Intercepts requests that have custom schemes or special paths
/// and routes them through the PluginManager to the appropriate Wasm module.
public final class PluginDataLoader: DataLoading, @unchecked Sendable {
    private let defaultLoader: DataLoader
    private let pluginManager: PluginManager

    public init(
        configuration: URLSessionConfiguration = .default,
        pluginManager: PluginManager
    ) {
        self.defaultLoader = DataLoader(configuration: configuration)
        self.pluginManager = pluginManager
    }

    public func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void, completion: @escaping @Sendable (Error?) -> Void) -> Cancellable {
        guard let url = request.url, url.scheme == "ito" else {
            // Pass-through to default URLSession loader
            return defaultLoader.loadData(with: request, didReceiveData: didReceiveData, completion: completion)
        }

        let cancellationLatch = CancellationLatch()
        let task = Task {
            do {
                // url format: ito://<plugin_id>/<real_url>
                guard let host = url.host else {
                    throw URLError(.badURL)
                }
                let pluginId = host
                // Extract real URL
                var realUrlString = url.path
                if realUrlString.hasPrefix("/") {
                    realUrlString.removeFirst()
                }
                if let query = url.query {
                    realUrlString += "?" + query
                }
                // Handle case where realUrlString has scheme like https:/ instead of https://
                realUrlString = realUrlString.replacingOccurrences(of: "https:/", with: "https://")
                realUrlString = realUrlString.replacingOccurrences(of: "http:/", with: "http://")
                realUrlString = realUrlString.replacingOccurrences(of: "https:///", with: "https://")

                guard let runner = try? await pluginManager.getRunner(for: pluginId) else {
                    throw URLError(.fileDoesNotExist)
                }

                if let data = try await runner.handleImage(realUrlString) {
                    let response = URLResponse(url: url, mimeType: "image/jpeg", expectedContentLength: data.count, textEncodingName: nil)
                    didReceiveData(data, response)
                    completion(nil)
                } else {
                    // Fallback to fetching the real URL directly if plugin doesn't intercept
                    if let realUrl = URL(string: realUrlString) {
                        var realRequest = request
                        realRequest.url = realUrl
                        guard !cancellationLatch.isCancelled && !Task.isCancelled else { return }
                        let sub = defaultLoader.loadData(with: realRequest, didReceiveData: didReceiveData, completion: completion)
                        cancellationLatch.setUnderlying(sub)
                    } else {
                        throw URLError(.badURL)
                    }
                }
            } catch {
                completion(error)
            }
        }

        return AnyCancellable {
            task.cancel()
            cancellationLatch.cancel()
        }
    }
}
nonisolated
final class CancellationLatch: @unchecked Sendable {
    private enum State {
        case idle
        case active(Cancellable)
        case cancelled
    }

    private let lock = NSLock()
    private var state: State = .idle

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .cancelled = state { return true }
        return false
    }

    func setUnderlying(_ cancellable: Cancellable) {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .idle:
            state = .active(cancellable)
        case .active(let existing):
            existing.cancel()
            state = .active(cancellable)
        case .cancelled:
            cancellable.cancel()
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .idle:
            state = .cancelled
        case .active(let cancellable):
            cancellable.cancel()
            state = .cancelled
        case .cancelled:
            break
        }
    }
}

private final class AnyCancellable: Cancellable, @unchecked Sendable {
    let closure: () -> Void
    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }
    func cancel() {
        closure()
    }
}
