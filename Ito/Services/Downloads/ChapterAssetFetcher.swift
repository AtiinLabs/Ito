import Foundation

/// One fetched asset: held in memory when it is small, or a file the caller now owns.
nonisolated enum FetchedAsset: Sendable {
    case data(Data)
    case file(URL)
}

/// Transfers for chapter page assets. The attempt chooses the route; a fetcher only moves bytes and
/// checks the response. Tests substitute a fake.
nonisolated protocol DirectAssetFetching: Sendable {
    /// A direct http(s) page, requested with the page's headers as the reader requests it.
    func fetchDirect(_ request: URLRequest) async throws -> FetchedAsset
    /// An image a plugin resolved to a URL, fetched through the plugin's allowed origins.
    func fetchPluginImage(
        url: URL,
        headers: [String: String]?,
        allowedOrigins: [String],
        pluginID: String
    ) async throws -> FetchedAsset
}

/// A response the fetcher refused. Each case maps to a failure reason in the attempt.
nonisolated enum ChapterAssetError: Error, Equatable, Sendable {
    case httpStatus(Int)
    case tooLarge
}

/// Production transfers. Both routes use the bulk configuration, so the system refuses metered and Low
/// Data Mode paths, and neither route uses the URL cache.
nonisolated final class URLSessionAssetFetcher: DirectAssetFetching, Sendable {
    /// Largest single asset. The size check runs after the transfer, so it bounds what is kept, not
    /// what crosses the wire.
    static let maximumAssetBytes: Int64 = 64 * 1024 * 1024

    private let session: URLSession
    private let imageTransport: PluginImageTransport

    init(trust: PluginTrustStore, userAgent: String) {
        let configuration = URLSessionConfiguration.bulkDownload
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        session = URLSession(configuration: configuration)
        imageTransport = PluginImageTransport(configuration: configuration, trust: trust)
    }

    func fetchDirect(_ request: URLRequest) async throws -> FetchedAsset {
        let location: URL
        let response: URLResponse
        do {
            (location, response) = try await session.download(for: request)
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
        pluginID: String
    ) async throws -> FetchedAsset {
        let (data, response) = try await imageTransport.fetch(
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
