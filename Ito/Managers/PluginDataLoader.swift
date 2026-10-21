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

                if let data = try await pluginCall({ try await runner.handleImage(realUrlString) }) {
                    let response = URLResponse(
                        url: url,
                        mimeType: Self.imageMIMEType(of: data),
                        expectedContentLength: data.count,
                        textEncodingName: nil
                    )
                    didReceiveData(data, response)
                    completion(nil)
                } else {
                    // The plugin doesn't handle images: fetch the URL directly. A plugin that
                    // handles images but refused this one throws instead, and nothing is fetched.
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
            } catch is CancellationError {
                completion(URLError(.cancelled))
            } catch {
                completion(error)
            }
        }

        return AnyCancellable {
            task.cancel()
            cancellationLatch.cancel()
        }
    }

    /// The image type of plugin-provided bytes, read from their signature. Plugins return raw
    /// bytes, so the response would otherwise have to guess.
    static func imageMIMEType(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + signature.count && Array(bytes[offset..<offset + signature.count]) == signature
        }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if starts(Array("GIF8".utf8)) { return "image/gif" }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return "image/webp" }
        if starts(Array("ftyp".utf8), at: 4) {
            let brand = bytes.count >= 12 ? String(bytes: bytes[8..<12], encoding: .ascii) ?? "" : ""
            if brand.hasPrefix("avi") { return "image/avif" }
            if ["heic", "heix", "mif1", "msf1"].contains(brand) { return "image/heic" }
        }
        return nil
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
