import Foundation
import ito_runner

nonisolated enum SearchPluginKind: Equatable, Sendable {
    case manga
    case anime
    case novel
    case unsupported
}

nonisolated struct SearchPluginDescriptor: Equatable, Sendable {
    let id: String
    let name: String
    let kind: SearchPluginKind
    /// The source's website from its manifest, used to route a pasted link to the source it
    /// belongs to.
    let siteURL: String?

    init(id: String, name: String, kind: SearchPluginKind, siteURL: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
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
        query: String,
        limit: Int
    ) async throws -> [PluginSearchResult]

    func evictRunner(for pluginID: String)
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

    public init(runner: ItoRunner) {
        self.runner = runner
    }

    public func loadManga(_ manga: Manga) async throws -> Manga {
        try await pluginCall { try await runner.getMediaUpdate(.manga(manga)).expecting(\.manga) }
    }

    public func loadAnime(_ anime: Anime) async throws -> Anime {
        try await pluginCall { try await runner.getMediaUpdate(.anime(anime)).expecting(\.anime) }
    }

    public func loadNovel(_ novel: Novel) async throws -> Novel {
        try await pluginCall { try await runner.getMediaUpdate(.novel(novel)).expecting(\.novel) }
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
                kind: searchKind(for: plugin),
                siteURL: plugin.info.url
            )
        }
    }

    func search(
        plugin: SearchPluginDescriptor,
        query: String,
        limit: Int
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
        let context = ItoRunnerSearchContext(runner: runner)

        if let link {
            return try await open(link, plugin: plugin, runner: runner, context: context)
        }

        do {
            return try await pluginCall {
                let kind: MediaKind
                switch plugin.kind {
                case .manga: kind = .manga
                case .anime: kind = .anime
                case .novel: kind = .novel
                case .unsupported: return []
                }
                let response = try await runner.search(query: query, page: 1, kind: kind)
                try Task.checkCancellation()
                // A plugin serving several kinds may mix them; this scope shows only `kind`.
                return Array(response.entries.lazy.filter { $0.kind == kind }.prefix(limit).map { entry in
                    self.result(for: entry, plugin: plugin, context: context)
                })
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.classify(error, fallback: .pluginExecution)
        }
    }

    /// Asks the source to open a pasted link from its own site, then loads the title's details so
    /// the result shows a real title and cover. Links the source returns as another web address or
    /// a listing, and sources without `handle_url`, yield no result.
    private func open(
        _ link: SearchLink,
        plugin: SearchPluginDescriptor,
        runner: ItoRunner,
        context: ItoRunnerSearchContext
    ) async throws -> [PluginSearchResult] {
        do {
            return try await pluginCall {
                guard let value = try await runner.handleUrl(link.url) else { return [] }
                try Task.checkCancellation()
                switch value {
                case .manga(let linked):
                    let manga = try await runner.getMediaUpdate(.manga(linked), needsUnits: false).expecting(\.manga)
                    try Task.checkCancellation()
                    return [PluginSearchResult(
                        id: manga.key, title: manga.title, cover: manga.cover, subtitle: manga.displayStatus,
                        pluginName: plugin.name,
                        destination: .manga(pluginID: plugin.id, context: context, media: manga)
                    )]
                case .anime(let linked):
                    let anime = try await runner.getMediaUpdate(.anime(linked), needsUnits: false).expecting(\.anime)
                    try Task.checkCancellation()
                    return [PluginSearchResult(
                        id: anime.key, title: anime.title, cover: anime.cover, subtitle: anime.displayStatus,
                        pluginName: plugin.name,
                        destination: .anime(pluginID: plugin.id, context: context, media: anime)
                    )]
                case .novel(let linked):
                    let novel = try await runner.getMediaUpdate(.novel(linked), needsUnits: false).expecting(\.novel)
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

    func evictRunner(for pluginID: String) {
        pluginManager.evictRunner(for: pluginID)
    }

    func pendingTrust(for pluginID: String) -> PendingTrust? {
        pluginManager.pluginSettingsStore.trust.pending(pluginID: pluginID)
    }

    private func searchKind(for plugin: InstalledPlugin) -> SearchPluginKind {
        switch plugin.info.type {
        case .manga:
            return .manga
        case .anime:
            return .anime
        case .novel:
            return .novel
        @unknown default:
            return .unsupported
        }
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
