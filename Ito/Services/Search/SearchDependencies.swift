import Foundation
import ito_runner

nonisolated struct SearchPluginDescriptor: Equatable, Sendable {
    let id: String
    let name: String
    let kinds: Set<MediaKind>
    /// The source's website from its manifest, used to route a pasted link to the source it
    /// belongs to.
    let siteURL: String?

    init(id: String, name: String, kinds: Set<MediaKind>, siteURL: String? = nil) {
        self.id = id
        self.name = name
        self.kinds = kinds
        self.siteURL = siteURL
    }
}

enum SearchPluginExecutionError: Error, Equatable {
    case pluginUnavailable
    case pluginExecution
    case pluginTrap
}

@MainActor
protocol SearchPluginExecuting: AnyObject {
    var plugins: [SearchPluginDescriptor] { get }

    func search(
        plugin: SearchPluginDescriptor,
        kind: MediaKind?,
        query: String,
        limit: Int,
        operation: PluginNetworkOperation
    ) async throws -> [PluginSearchResult]

    func pendingTrust(for pluginID: String) -> PendingTrust?
    func clearPendingTrust(for pluginID: String)
}

extension SearchPluginExecuting {
    func pendingTrust(for pluginID: String) -> PendingTrust? { nil }
    func clearPendingTrust(for pluginID: String) {}
}

@MainActor
protocol RecentSearchPersisting {
    func load() -> [String]
    func save(_ searches: [String])
    func clear()
}

struct UserDefaultsRecentSearchStore: RecentSearchPersisting {
    static let key = "Ito.RecentSearches"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    func save(_ searches: [String]) {
        defaults.set(searches, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

public final class ItoRunnerSearchContext: SearchDetailLoading {
    public let runner: ItoRunner
    let pluginID: String
    private let contexts: PluginNetworkContexts

    init(runner: ItoRunner, pluginID: String, contexts: PluginNetworkContexts) {
        self.runner = runner
        self.pluginID = pluginID
        self.contexts = contexts
    }

    /// The host context of one export of `operation` for this source. Each call is a new export.
    func networkContext(_ operation: PluginNetworkOperation) -> NetworkOperationContext {
        contexts.context(pluginID: pluginID, operation)
    }

    public func loadManga(_ manga: Manga, operation: PluginNetworkOperation) async throws -> Manga {
        let context = networkContext(operation)
        return try await pluginCall { try await runner.getMediaUpdate(.manga(manga), context: context).expecting(\.manga) }
    }

    public func loadAnime(_ anime: Anime, operation: PluginNetworkOperation) async throws -> Anime {
        let context = networkContext(operation)
        return try await pluginCall { try await runner.getMediaUpdate(.anime(anime), context: context).expecting(\.anime) }
    }

    public func loadNovel(_ novel: Novel, operation: PluginNetworkOperation) async throws -> Novel {
        let context = networkContext(operation)
        return try await pluginCall { try await runner.getMediaUpdate(.novel(novel), context: context).expecting(\.novel) }
    }
}

@MainActor
final class PluginManagerSearchExecutor: SearchPluginExecuting {
    private let pluginManager: PluginManager

    init(pluginManager: PluginManager) {
        self.pluginManager = pluginManager
    }

    var plugins: [SearchPluginDescriptor] {
        pluginManager.installedPlugins.values.map { plugin in
            SearchPluginDescriptor(
                id: plugin.id,
                name: plugin.info.name,
                kinds: Set(plugin.info.supportedKinds),
                siteURL: plugin.info.url
            )
        }
    }

    func search(
        plugin: SearchPluginDescriptor,
        kind: MediaKind?,
        query: String,
        limit: Int,
        operation: PluginNetworkOperation
    ) async throws -> [PluginSearchResult] {
        clearPendingTrust(for: plugin.id)
        let link = SearchLink(query: query)
        if let link, !link.belongs(toSite: plugin.siteURL) { return [] }

        let runner: ItoRunner
        do {
            runner = try await pluginManager.getRunner(for: plugin.id)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.classify(error, fallback: .pluginUnavailable)
        }
        guard !Task.isCancelled else { throw CancellationError() }
        let context = ItoRunnerSearchContext(
            runner: runner,
            pluginID: plugin.id,
            contexts: pluginManager.pluginSettingsStore.networkContexts
        )

        if let link {
            return try await open(link, plugin: plugin, kind: kind, runner: runner, context: context, operation: operation)
        }

        let searchContext = context.networkContext(operation)
        do {
            return try await pluginCall {
                if let kind, !plugin.kinds.contains(kind) { return [] }
                let response = try await runner.search(query: query, page: 1, kind: kind, context: searchContext)
                try Task.checkCancellation()
                // Other kinds cannot leak into a scoped search or consume its result limit.
                return Array(response.entries.lazy.filter { kind == nil || $0.kind == kind }.prefix(limit).map { entry in
                    self.result(for: entry, plugin: plugin, context: context)
                })
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            retireIfCrashed(error, runner: runner, pluginID: plugin.id)
            throw Self.classify(error, fallback: .pluginExecution)
        }
    }

    /// Asks the source to open a pasted link from its own site, then loads the title's details so
    /// the result shows a real title and cover. Links the source returns as another web address or
    /// a listing, and sources without `handle_url`, yield no result.
    private func open(
        _ link: SearchLink,
        plugin: SearchPluginDescriptor,
        kind: MediaKind?,
        runner: ItoRunner,
        context: ItoRunnerSearchContext,
        operation: PluginNetworkOperation
    ) async throws -> [PluginSearchResult] {
        do {
            return try await pluginCall {
                guard let value = try await runner.handleUrl(link.url, context: context.networkContext(operation)) else { return [] }
                try Task.checkCancellation()
                switch value {
                case .manga(let linked):
                    guard kind == nil || kind == .manga, plugin.kinds.contains(.manga) else { return [] }
                    let manga = try await runner.getMediaUpdate(
                        .manga(linked), needsUnits: false, context: context.networkContext(operation)
                    ).expecting(\.manga)
                    try Task.checkCancellation()
                    return [PluginSearchResult(
                        id: manga.key, title: manga.title, cover: manga.cover, subtitle: manga.displayStatus,
                        pluginName: plugin.name,
                        destination: .manga(pluginID: plugin.id, context: context, media: manga)
                    )]
                case .anime(let linked):
                    guard kind == nil || kind == .anime, plugin.kinds.contains(.anime) else { return [] }
                    let anime = try await runner.getMediaUpdate(
                        .anime(linked), needsUnits: false, context: context.networkContext(operation)
                    ).expecting(\.anime)
                    try Task.checkCancellation()
                    return [PluginSearchResult(
                        id: anime.key, title: anime.title, cover: anime.cover, subtitle: anime.displayStatus,
                        pluginName: plugin.name,
                        destination: .anime(pluginID: plugin.id, context: context, media: anime)
                    )]
                case .novel(let linked):
                    guard kind == nil || kind == .novel, plugin.kinds.contains(.novel) else { return [] }
                    let novel = try await runner.getMediaUpdate(
                        .novel(linked), needsUnits: false, context: context.networkContext(operation)
                    ).expecting(\.novel)
                    try Task.checkCancellation()
                    return [PluginSearchResult(
                        id: novel.key, title: novel.title, cover: novel.cover, subtitle: novel.displayStatus,
                        pluginName: plugin.name,
                        destination: .novel(pluginID: plugin.id, context: context, media: novel)
                    )]
                case .url, .listing:
                    return []
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            retireIfCrashed(error, runner: runner, pluginID: plugin.id)
            throw Self.classify(error, fallback: .pluginExecution)
        }
    }

    private func result(
        for entry: MediaEntry,
        plugin: SearchPluginDescriptor,
        context: ItoRunnerSearchContext
    ) -> PluginSearchResult {
        switch entry {
        case .manga(let manga):
            return PluginSearchResult(
                id: manga.key, title: manga.title, cover: manga.cover, subtitle: manga.displayStatus,
                pluginName: plugin.name, destination: .manga(pluginID: plugin.id, context: context, media: manga)
            )
        case .anime(let anime):
            return PluginSearchResult(
                id: anime.key, title: anime.title, cover: anime.cover, subtitle: anime.displayStatus,
                pluginName: plugin.name, destination: .anime(pluginID: plugin.id, context: context, media: anime)
            )
        case .novel(let novel):
            return PluginSearchResult(
                id: novel.key, title: novel.title, cover: novel.cover, subtitle: novel.displayStatus,
                pluginName: plugin.name, destination: .novel(pluginID: plugin.id, context: context, media: novel)
            )
        }
    }

    /// Retires the runner that crashed during a search, matched by instance, so a stale crash never evicts a newer
    /// runner. It runs whether or not the search is still wanted; the caller publishes nothing from a stale one.
    private func retireIfCrashed(_ error: any Error, runner: ItoRunner, pluginID: String) {
        guard (error as? PluginCallError)?.kind == .crashed else { return }
        pluginManager.retireRunner(for: pluginID, matching: runner)
    }

    func pendingTrust(for pluginID: String) -> PendingTrust? {
        pluginManager.pluginSettingsStore.trust.pending(pluginID: pluginID)
    }

    func clearPendingTrust(for pluginID: String) {
        pluginManager.pluginSettingsStore.trust.clearPending(pluginID: pluginID)
    }

    /// Preserve the plugin's user-facing reason; the view model separately classifies telemetry.
    static func classify(
        _ error: any Error,
        fallback: SearchPluginExecutionError
    ) -> any Error {
        let wrapped = PluginCallError.wrapping(error)
        if let pluginError = wrapped as? PluginCallError { return pluginError }
        return fallback
    }
}
