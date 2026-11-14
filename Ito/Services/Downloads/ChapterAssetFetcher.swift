import Foundation

/// One fetched asset: held in memory when it is small, or a file the caller now owns.
nonisolated enum FetchedAsset: Sendable {
    case data(Data)
    case file(URL)
}

/// Transfers for chapter page assets. The attempt chooses the route; a fetcher only moves bytes and
/// checks the response. Tests substitute a fake.
///
/// `allowsExpensiveAccess` says whether the policy admits an expensive path (cellular, hotspot) for this
/// transfer. When it does not, the system itself refuses such a path. Low Data Mode is refused either way.
nonisolated protocol DirectAssetFetching: Sendable {
    /// A direct http(s) page, requested with the page's headers as the reader requests it.
    func fetchDirect(_ request: URLRequest, allowsExpensiveAccess: Bool) async throws -> FetchedAsset
    /// An image a plugin resolved to a URL, fetched through the plugin's allowed origins.
    func fetchPluginImage(
        url: URL,
        headers: [String: String]?,
        allowedOrigins: [String],
        pluginID: String,
        allowsExpensiveAccess: Bool
    ) async throws -> FetchedAsset
}

/// A response the fetcher refused. Each case maps to a failure reason in the attempt.
nonisolated enum ChapterAssetError: Error, Equatable, Sendable {
    case httpStatus(Int)
    case tooLarge
}

/// Production transfers. Both routes use the bulk configuration, so the system refuses Low Data Mode paths,
/// and metered paths unless the policy admitted one, and neither route uses the URL cache.
nonisolated final class URLSessionAssetFetcher: DirectAssetFetching, Sendable {
    /// Largest single asset. The size check runs after the transfer, so it bounds what is kept, not
    /// what crosses the wire.
    static let maximumAssetBytes: Int64 = 64 * 1024 * 1024

    private struct Route: Sendable {
        let session: URLSession
        let imageTransport: PluginImageTransport
    }

    private let unmetered: Route
    private let metered: Route

    init(trust: PluginTrustStore, userAgent: String) {
        func route(allowingExpensiveAccess: Bool) -> Route {
            let configuration = URLSessionConfiguration.bulkDownload(allowingExpensiveAccess: allowingExpensiveAccess)
            configuration.urlCache = nil
            configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
            return Route(
                session: URLSession(configuration: configuration),
                imageTransport: PluginImageTransport(configuration: configuration, trust: trust)
            )
        }
        unmetered = route(allowingExpensiveAccess: false)
        metered = route(allowingExpensiveAccess: true)
    }

    private func route(allowingExpensiveAccess: Bool) -> Route {
        allowingExpensiveAccess ? metered : unmetered
    }

    func fetchDirect(_ request: URLRequest, allowsExpensiveAccess: Bool) async throws -> FetchedAsset {
        let location: URL
        let response: URLResponse
        do {
            (location, response) = try await route(allowingExpensiveAccess: allowsExpensiveAccess).session.download(for: request)
        } catch {
            // A cancelled transfer surfaces as a URL error; callers treat it as a cancellation.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
        do {
            try Self.checkStatus(response)
            guard response.expectedContentLength <= Self.maximumAssetBytes else {
                throw ChapterAssetError.tooLarge
            }
            guard try Self.byteCount(ofFile: location) <= Self.maximumAssetBytes else {
                throw ChapterAssetError.tooLarge
            }
            let owned = FileManager.default.temporaryDirectory
                .appendingPathComponent("ito-page-\(UUID().uuidString).download")
            try FileManager.default.moveItem(at: location, to: owned)
            return .file(owned)
        } catch {
            try? FileManager.default.removeItem(at: location)
            throw error
        }
    }

    func fetchPluginImage(
        url: URL,
        headers: [String: String]?,
        allowedOrigins: [String],
        pluginID: String,
        allowsExpensiveAccess: Bool
    ) async throws -> FetchedAsset {
        let (data, response) = try await route(allowingExpensiveAccess: allowsExpensiveAccess).imageTransport.fetch(
            url: url,
            headers: headers,
            allowedOrigins: allowedOrigins,
            pluginID: pluginID
        )
        try Self.checkStatus(response)
        guard Int64(data.count) <= Self.maximumAssetBytes else {
            throw ChapterAssetError.tooLarge
        }
        return .data(data)
    }

    /// The size of a file on disk, for the attempt's progress and the cap.
    static func byteCount(ofFile url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw URLError(.cannotOpenFile)
        }
        return size
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw ChapterAssetError.httpStatus(http.statusCode)
        }
    }
}
