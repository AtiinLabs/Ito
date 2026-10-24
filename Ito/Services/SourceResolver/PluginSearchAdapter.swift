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
                return try await runner.search(query: query, page: 1, kind: .manga).entries.compactMap(\.manga).map {
                    .manga($0)
                }
            case .anime:
                return try await runner.search(query: query, page: 1, kind: .anime).entries.compactMap(\.anime).map {
                    .anime($0)
                }
            }
        }
    }
}
