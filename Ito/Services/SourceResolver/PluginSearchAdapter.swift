import Foundation
import ito_runner

public actor PluginSearchAdapter: PluginSearching {
    public let pluginID: String
    public let pluginVersion: String?
    public let mediaType: PluginMediaType

    private let runner: ItoRunner

    public init(pluginID: String, pluginVersion: String?, mediaType: PluginMediaType, runner: ItoRunner) {
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.mediaType = mediaType
        self.runner = runner
    }

    public func search(query: String) async throws -> [ResolvedPluginMedia] {
        try await pluginCall {
            switch mediaType {
            case .manga:
                let res = try await runner.getSearchMangaList(query: query, page: 1, filters: nil)
                return res.entries.map { .manga($0) }
            case .anime:
                let res = try await runner.getSearchAnimeList(query: query, page: 1, filters: nil)
                return res.entries.map { .anime($0) }
            }
        }
    }
}
