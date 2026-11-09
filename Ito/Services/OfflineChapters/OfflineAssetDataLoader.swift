import Foundation
import Nuke

/// The `ito-offline://<lease-token>/<file>` locator that offline page images use. The host is the
/// lease token and the path is one manifest file name, so nothing else can be named.
nonisolated enum OfflineAssetLocator {
    static let scheme = "ito-offline"

    static func makeURLString(token: UUID, fileName: String) -> String {
        "\(scheme)://\(token.uuidString)/\(fileName)"
    }

    static func parse(_ url: URL) throws -> (token: UUID, fileName: String) {
        guard url.scheme == scheme,
              url.query == nil,
              url.fragment == nil,
              let token = UUID(uuidString: url.host ?? ""),
              url.pathComponents.count == 2 else {
            throw OfflineAssetError.invalidLocator
        }
        return (token, url.pathComponents[1])
    }
}

nonisolated enum OfflineAssetError: Error, Equatable, Sendable {
    case invalidLocator
    /// The lease that named the page was released, so its bytes are no longer pinned.
    case leaseReleased
}

/// Serves `ito-offline://` requests from leased copies. Bytes come only from the lease directory and
/// are verified against the manifest by `readVerifiedPage`. Nothing reaches the network.
nonisolated final class OfflineAssetDataLoader: DataLoading, @unchecked Sendable {
    private let reader: any OfflineChapterReading
    private let queue = DispatchQueue(
        label: "moe.itoapp.ito.offline-assets",
        qos: .utility,
        attributes: .concurrent
    )

    init(reader: any OfflineChapterReading) {
        self.reader = reader
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        let work = OfflineAssetWork()
        let reader = reader
        queue.async {
            guard !work.isCancelled else {
                completion(URLError(.cancelled))
                return
            }
            do {
                let (data, response) = try Self.load(request, reader: reader)
                didReceiveData(data, response)
                completion(nil)
            } catch {
                completion(error)
            }
        }
        return work
    }

    private static func load(
        _ request: URLRequest,
        reader: any OfflineChapterReading
    ) throws -> (Data, URLResponse) {
        guard let url = request.url else { throw OfflineAssetError.invalidLocator }
        let (token, fileName) = try OfflineAssetLocator.parse(url)
        guard let page = reader.leases.resolvePage(token: token, fileName: fileName) else {
            throw OfflineAssetError.leaseReleased
        }
        let data = try reader.readVerifiedPage(page)
        let response = URLResponse(
            url: url,
            mimeType: ImageSignature.detect(data)?.mediaType,
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        return (data, response)
    }
}

/// The cancellation handle for one offline load. Cancelling it only stops the completion from
/// reading; the completion still runs exactly once.
nonisolated private final class OfflineAssetWork: Cancellable, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }
}

/// The image pipeline for offline pages. It has no disk cache, so an offline page never writes to the
/// shared data cache, and its memory cache is its own and small.
nonisolated enum OfflineImagePipeline {
    static func make(reader: any OfflineChapterReading) -> ImagePipeline {
        let memoryCache = ImageCache(costLimit: 32 * 1024 * 1024, countLimit: 64)
        return ImagePipeline {
            $0.dataCache = nil
            $0.imageCache = memoryCache
            $0.dataLoader = OfflineAssetDataLoader(reader: reader)
            $0.makeImageDecoder = ItoImageDecoders.make(for:)
        }
    }
}
