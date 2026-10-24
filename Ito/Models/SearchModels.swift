import Foundation
import ito_runner

public protocol SearchDetailLoading: AnyObject {
    var runner: ItoRunner { get }

    func loadManga(_ manga: Manga) async throws -> Manga
    func loadAnime(_ anime: Anime) async throws -> Anime
    func loadNovel(_ novel: Novel) async throws -> Novel
}

public enum SearchDestination {
    case manga(pluginID: String, context: any SearchDetailLoading, media: Manga)
    case anime(pluginID: String, context: any SearchDetailLoading, media: Anime)
    case novel(pluginID: String, context: any SearchDetailLoading, media: Novel)

    public var pluginID: String {
        switch self {
        case .manga(let pluginID, _, _),
             .anime(let pluginID, _, _),
             .novel(let pluginID, _, _):
            return pluginID
        }
    }

    public var context: any SearchDetailLoading {
        switch self {
        case .manga(_, let context, _),
             .anime(_, let context, _),
             .novel(_, let context, _):
            return context
        }
    }
}

public struct PluginSearchResult: Identifiable {
    public let id: String
    public let title: String
    public let cover: String?
    public let subtitle: String?
    public let pluginName: String?
    public let destination: SearchDestination

    public init(
        id: String,
        title: String,
        cover: String?,
        subtitle: String?,
        pluginName: String? = nil,
        destination: SearchDestination
    ) {
        self.id = id
        self.title = title
        self.cover = cover
        self.subtitle = subtitle
        self.pluginName = pluginName
        self.destination = destination
    }
}

public typealias SearchResults = [String: [PluginSearchResult]]

/// Volatile search-operation failures. Plugin-provided messages are for presentation only.
public struct SearchPluginFailure: Identifiable, Equatable {
    public let pluginID: String
    public let pluginName: String
    public let message: String
    public let canOpenSettings: Bool
    /// The source needs a sign-in on its website.
    public let canSignIn: Bool
    /// An untrusted certificate waiting for user confirmation, if any.
    public let pendingTrust: PendingTrust?

    public init(
        pluginID: String,
        pluginName: String,
        message: String,
        canOpenSettings: Bool,
        canSignIn: Bool = false,
        pendingTrust: PendingTrust? = nil
    ) {
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.message = message
        self.canOpenSettings = canOpenSettings
        self.canSignIn = canSignIn
        self.pendingTrust = pendingTrust
    }

    public var id: String { pluginID }
}

public enum SearchFailure: Equatable {
    case pluginUnavailable
    case pluginExecution
    case pluginTrap

    var presentationCategory: PresentationErrorCategory {
        switch self {
        case .pluginUnavailable:
            return .pluginUnavailable
        case .pluginExecution:
            return .pluginExecution
        case .pluginTrap:
            return .pluginTrap
        }
    }
}

public enum SearchPresentationState {
    case idle
    case loading(results: SearchResults, activePluginIDs: Set<String>)
    case content(results: SearchResults)
    case empty
    case partialFailure(results: SearchResults, failedPluginCount: Int)
    case failure(SearchFailure)
    case cancelled

    var results: SearchResults {
        switch self {
        case .loading(let results, _),
             .content(let results),
             .partialFailure(let results, _):
            return results
        case .idle, .empty, .failure, .cancelled:
            return [:]
        }
    }

    var activePluginIDs: Set<String> {
        guard case .loading(_, let activePluginIDs) = self else { return [] }
        return activePluginIDs
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

public enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All"
    case manga = "Manga"
    case anime = "Anime"
    case novel = "Novel"

    public var id: String { rawValue }
}
