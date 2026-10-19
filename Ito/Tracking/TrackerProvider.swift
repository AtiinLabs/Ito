import Foundation

public struct TrackerMediaEntry: Equatable, Sendable {
    public let status: String?
    public let progress: Int?
    public let score: Double?
    public let startDate: Date?
    public let finishDate: Date?

    public init(status: String?, progress: Int?, score: Double?, startDate: Date?, finishDate: Date?) {
        self.status = status
        self.progress = progress
        self.score = score
        self.startDate = startDate
        self.finishDate = finishDate
    }
}

public struct TrackerMedia: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let titleRomaji: String?
    public let coverImage: String?
    public let format: String?
    public let episodes: Int?
    public let chapters: Int?

    public init(id: String, title: String, titleRomaji: String?, coverImage: String?, format: String?, episodes: Int?, chapters: Int?) {
        self.id = id
        self.title = title
        self.titleRomaji = titleRomaji
        self.coverImage = coverImage
        self.format = format
        self.episodes = episodes
        self.chapters = chapters
    }
}

@MainActor
public protocol TrackerProvider: ObservableObject {
    var identifier: String { get } // e.g., "anilist"
    var name: String { get } // e.g., "AniList"
    var isAuthenticated: Bool { get }
    var username: String? { get }
    /// Whether the tracker lists anime. Trackers that do not are offered for manga and novels only.
    var tracksAnime: Bool { get }

    func authenticate(using oauthManager: OAuthManager) async throws
    func logout() async throws

    func searchMedia(title: String, isAnime: Bool) async throws -> [TrackerMedia]
    func updateProgress(mediaId: String, progress: Int?, status: String?) async throws
    func getMediaListEntry(mediaId: String) async throws -> TrackerMediaEntry?
}

/// A tracker the user signs in to by pasting a token created on the tracker's website, for
/// services that offer no OAuth flow an app can use.
@MainActor
protocol TrackerTokenAuthenticating: TrackerProvider {
    /// The page where the user creates a token.
    var tokenCreationURL: URL { get }

    /// Verifies the token with the tracker and stores it.
    func authenticate(token: String) async throws
}

nonisolated enum TrackerTokenError: Error, Equatable, Sendable, LocalizedError {
    /// The tracker did not accept the token.
    case rejected

    var errorDescription: String? {
        "The token was not accepted."
    }
}

nonisolated enum TrackerWriteRules {
    /// Trackers whose entries Ito moves only forward: explicit saves cannot lower progress except
    /// when starting a reread or rewatch, and automatic sync only advances entries the user is
    /// reading or watching.
    static func movesProgressForwardOnly(_ providerID: String) -> Bool {
        providerID == MALCredentialRepository.providerID || providerID == MangaBakaCredentialRepository.providerID
    }
}
