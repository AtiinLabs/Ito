import Foundation
import Nuke
import ito_runner

/// The optional image exports needed by the loader. The actor keeps WASM resolution serialized;
/// native HTTP work starts only after these calls return.
protocol PluginImageRunner: Sendable {
    func getImageRequest(_ locator: String) async throws -> PluginImageRequest?
    func getImageOrigins() async throws -> [String]?
    func handleImage(_ locator: String) async throws -> Data?
}

extension ItoRunner: PluginImageRunner {}

/// Intercepts requests that have custom schemes or special paths
/// and routes them through the PluginManager to the appropriate Wasm module.
public final class PluginDataLoader: DataLoading, @unchecked Sendable {
    private let defaultLoader: any DataLoading
    private let runnerProvider: @Sendable (String) async throws -> any PluginImageRunner
    private let runnerEvictor: (@Sendable (String, any PluginImageRunner) async -> Void)?
    private let imageTransport: PluginImageTransport

    public convenience init(
        configuration: URLSessionConfiguration = .default,
        pluginManager: PluginManager
    ) {
        self.init(
            configuration: configuration,
            trust: pluginManager.pluginSettingsStore.trust,
            runnerProvider: { try await pluginManager.getImageRunner(for: $0) },
            runnerEvictor: { pluginId, runner in
                if let itoRunner = runner as? ItoRunner {
                    await pluginManager.evictImageRunner(for: pluginId, matching: itoRunner)
                }
            }
        )
    }

    /// - Parameter defaultLoader: loads every request that is not `ito://`, and the direct requests a plugin
    ///   resolves to. Nil uses Nuke's loader over `configuration`.
    init(
        configuration: URLSessionConfiguration,
        trust: PluginTrustStore? = nil,
        defaultLoader: (any DataLoading)? = nil,
        runnerProvider: @escaping @Sendable (String) async throws -> any PluginImageRunner,
        runnerEvictor: (@Sendable (String, any PluginImageRunner) async -> Void)? = nil
    ) {
        self.defaultLoader = defaultLoader ?? DataLoader(configuration: configuration)
        self.runnerProvider = runnerProvider
        self.runnerEvictor = runnerEvictor
        self.imageTransport = PluginImageTransport(configuration: configuration, trust: trust)
    }

    public func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void, completion: @escaping @Sendable (Error?) -> Void) -> Cancellable {
        guard let url = request.url, url.scheme == "ito" else {
            // Pass-through to default URLSession loader
            return defaultLoader.loadData(with: request, didReceiveData: didReceiveData, completion: completion)
        }

        let cancellationLatch = CancellationLatch()
        let task = Task {
            var usedRunner: (any PluginImageRunner)?
            var targetPluginId: String?
            do {
                let locator = try PluginImageLocator.parse(url)
                let pluginId = locator.pluginID
                targetPluginId = pluginId

                let runner = try await runnerProvider(pluginId)
                usedRunner = runner
                try Task.checkCancellation()

                switch try await PluginImageResolution.resolve(locator, runner: runner) {
                case .fetch(let target, let headers, let allowedOrigins):
                    let (data, response) = try await imageTransport.fetch(
                        url: target,
                        headers: headers,
                        allowedOrigins: allowedOrigins,
                        pluginID: pluginId
                    )
                    try Task.checkCancellation()
                    didReceiveData(data, response)
                    completion(nil)
                case .bytes(let data):
                    let response = URLResponse(
                        url: url,
                        mimeType: ImageSignature.detect(data)?.mediaType,
                        expectedContentLength: data.count,
                        textEncodingName: nil
                    )
                    didReceiveData(data, response)
                    completion(nil)
                case .direct(let realUrl):
                    var realRequest = request
                    realRequest.url = realUrl
                    guard !cancellationLatch.isCancelled && !Task.isCancelled else { throw CancellationError() }
                    let sub = defaultLoader.loadData(with: realRequest, didReceiveData: didReceiveData, completion: completion)
                    cancellationLatch.setUnderlying(sub)
                }
            } catch is CancellationError {
                completion(URLError(.cancelled))
            } catch {
                if let runner = usedRunner,
                   let pluginId = targetPluginId,
                   let callError = error as? PluginCallError,
                   callError.kind == .crashed {
                    await runnerEvictor?(pluginId, runner)
                }
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
