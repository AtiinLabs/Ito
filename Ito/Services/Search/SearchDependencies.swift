import Foundation
import ito_runner

enum SearchPluginKind: Equatable {
    case manga
    case anime
    case novel
    case unsupported
}

struct SearchPluginDescriptor: Equatable {
    let id: String
    let name: String
    let kind: SearchPluginKind
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
        try await pluginCall { try await runner.getMangaUpdate(manga: manga) }
    }

    public func loadAnime(_ anime: Anime) async throws -> Anime {
        try await pluginCall { try await runner.getAnimeUpdate(anime: anime) }
    }

    public func loadNovel(_ novel: Novel) async throws -> Novel {
        try await pluginCall { try await runner.getNovelUpdate(novel: novel) }
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
                kind: searchKind(for: plugin)
            )
        }
    }

    func search(
        plugin: SearchPluginDescriptor,
        query: String,
        limit: Int
    ) async throws -> [PluginSearchResult] {
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

        do {
            return try await pluginCall {
                switch plugin.kind {
                case .manga:
                    let response = try await runner.getSearchMangaList(query: query, page: 1, filters: nil)
                    try Task.checkCancellation()
                    return response.entries.prefix(limit).map { manga in
                        PluginSearchResult(
                            id: manga.key,
                            title: manga.title,
                            cover: manga.cover,
                            subtitle: manga.displayStatus,
                            pluginName: plugin.name,
                            destination: .manga(pluginID: plugin.id, context: context, media: manga)
                        )
                    }
                case .anime:
                    let response = try await runner.getSearchAnimeList(query: query, page: 1, filters: nil)
                    try Task.checkCancellation()
                    return response.entries.prefix(limit).map { anime in
                        PluginSearchResult(
                            id: anime.key,
                            title: anime.title,
                            cover: anime.cover,
                            subtitle: anime.displayStatus,
                            pluginName: plugin.name,
                            destination: .anime(pluginID: plugin.id, context: context, media: anime)
                        )
                    }
                case .novel:
                    let response = try await runner.getSearchNovelList(query: query, page: 1, filters: nil)
                    try Task.checkCancellation()
                    return response.entries.prefix(limit).map { novel in
                        PluginSearchResult(
                            id: novel.key,
                            title: novel.title,
                            cover: novel.cover,
                            subtitle: novel.displayStatus,
                            pluginName: plugin.name,
                            destination: .novel(pluginID: plugin.id, context: context, media: novel)
                        )
                    }
                case .unsupported:
                    return []
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.classify(error, fallback: .pluginExecution)
        }
    }

    func evictRunner(for pluginID: String) {
        pluginManager.evictRunner(for: pluginID)
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
