import Foundation
import ito_runner

public actor PluginSearchAdapter: PluginSearching {
    public let pluginID: String
    public let pluginVersion: String?
    public let mediaType: PluginMediaType

    private let runner: ItoRunner
    private let contexts: PluginNetworkContexts

    init(
        pluginID: String,
        pluginVersion: String?,
        mediaType: PluginMediaType,
        runner: ItoRunner,
        contexts: PluginNetworkContexts
    ) {
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.mediaType = mediaType
        self.runner = runner
        self.contexts = contexts
    }

    /// One search export of the resolver run that asked for it; the run's operation is shared by its queries.
    public func search(query: String, operation: PluginNetworkOperation) async throws -> [ResolvedPluginMedia] {
        let context = contexts.context(pluginID: pluginID, operation)
        return try await pluginCall {
            switch mediaType {
            case .manga:
                return try await runner.search(query: query, page: 1, kind: .manga, context: context).entries.compactMap(\.manga).map {
                    .manga($0)
                }
            case .anime:
                return try await runner.search(query: query, page: 1, kind: .anime, context: context).entries.compactMap(\.anime).map {
                    .anime($0)
                }
            case .novel:
                return try await runner.search(query: query, page: 1, kind: .novel, context: context).entries.compactMap(\.novel).map {
                    .novel($0)
                }
            }
        }
    }
}
