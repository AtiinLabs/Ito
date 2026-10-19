import OSLog
import Foundation
import Combine
import anilist

@MainActor
public class AnilistTracker: TrackerProvider {
    public let identifier = "anilist"
    public let name = "AniList"

    @Published public private(set) var anilistToken: String?
    @Published public private(set) var username: String?

    public var isAuthenticated: Bool {
        return anilistToken != nil
    }

    private let usernameKey = "anilist_username"
    private let clientId = "36931"
    private let callbackScheme = "ito"
    private let credentialRepository: AniListCredentialRepository
    private let usernameDefaults: UserDefaults

    init(
        credentialRepository: AniListCredentialRepository,
        usernameDefaults: UserDefaults
    ) {
        self.credentialRepository = credentialRepository
        self.usernameDefaults = usernameDefaults
        self.anilistToken = nil
        self.username = usernameDefaults.string(forKey: usernameKey)
    }

    @discardableResult
    func bootstrapCredentials() async throws -> AniListCredentialRepository.BootstrapOutcome {
        try await credentialRepository.bootstrap { [weak self] token in
            self?.anilistToken = token
        }
    }

    @MainActor
    public func authenticate(using oauthManager: OAuthManager) async throws {
        let authURLString = "https://anilist.co/api/v2/oauth/authorize?client_id=\(clientId)&response_type=token"
        guard let url = URL(string: authURLString) else {
            throw URLError(.badURL)
        }

        let callbackURL = try await oauthManager.authenticate(url: url, callbackScheme: callbackScheme)

        guard let fragment = callbackURL.fragment else {
            throw URLError(.cannotParseResponse)
        }

        let params = fragment.components(separatedBy: "&").reduce(into: [String: String]()) { result, param in
            let pair = param.components(separatedBy: "=")
            if pair.count == 2 {
                result[pair[0]] = pair[1]
            }
        }

        guard let token = params["access_token"] else {
            throw URLError(.userAuthenticationRequired)
        }

        try await persistAuthenticatedToken(token)

        Task {
            do {
                try await self.fetchAnilistViewer(token: token)
            } catch {
                AppLogger.auth.error("Failed to fetch viewer: \(error)")
            }
        }
    }

    func persistAuthenticatedToken(_ token: String) async throws {
        try await credentialRepository.persistOAuthToken(token) { [weak self] verifiedToken in
            self?.anilistToken = verifiedToken
        }
    }

    public func logout() async throws {
        try await credentialRepository.logout { [weak self] _ in
            guard let self else { return }
            self.anilistToken = nil
            self.username = nil
            self.usernameDefaults.removeObject(forKey: self.usernameKey)
        }
    }

    public func searchMedia(title: String, isAnime: Bool) async throws -> [TrackerMedia] {
        let query = AniListQueries.SearchQuery(
            page: 1,
            perPage: 5,
            search: title,
            type: isAnime ? .anime : .manga,
            sort: [.searchMatch]
        )
        let media = try await client().execute(query).page?.media ?? []

        return media.map { media in
            let romaji = media.title?.romaji
            let title = media.title?.english ?? romaji ?? media.title?.native ?? "Unknown Title"
            return TrackerMedia(
                id: String(media.id),
                title: title,
                titleRomaji: romaji,
                coverImage: media.coverImage?.large,
                format: media.format?.rawValue,
                episodes: media.episodes,
                chapters: media.chapters
            )
        }
    }

    public func updateProgress(mediaId: String, progress: Int?, status: String?) async throws {
        let client = try client()
        guard let idInt = Int(mediaId) else { throw URLError(.badURL) }
        let listStatus = try status.map { rawValue in
            guard let listStatus = MediaListStatus(rawValue: rawValue) else {
                throw URLError(.cannotParseResponse)
            }
            return listStatus
        }

        if let progress = progress {
            do {
                if let entry = try await getMediaListEntry(mediaId: mediaId),
                   let currentProgress = entry.progress {
                    if currentProgress >= progress && (status == nil || entry.status == status) {
                        return
                    }
                }
            } catch {
                AppLogger.auth.error("Failed to fetch existing entry before updating, proceeding with update.")
            }
        }

        _ = try await client.execute(SaveMediaListEntryMutation(mediaId: idInt, status: listStatus, progress: progress))
    }

    public func getMediaListEntry(mediaId: String) async throws -> TrackerMediaEntry? {
        let client = try client()
        guard let username = username else { return nil }
        guard let idInt = Int(mediaId) else { throw URLError(.badURL) }

        let entry: MediaList?
        do {
            entry = try await client.execute(AniListQueries.MediaListEntryQuery(userName: username, mediaId: idInt)).mediaList
        } catch let error as AniListError where error.isNotFound {
            return nil
        }
        guard let entry else { return nil }

        return TrackerMediaEntry(
            status: entry.status?.rawValue,
            progress: entry.progress,
            score: entry.score,
            startDate: Self.date(from: entry.startedAt),
            finishDate: Self.date(from: entry.completedAt)
        )
    }

    private func fetchAnilistViewer(token: String) async throws {
        let viewer = try await AniListClient { token }.execute(AniListQueries.ViewerQuery()).viewer
        guard let name = viewer?.name else {
            throw URLError(.cannotParseResponse)
        }

        guard anilistToken == token else { return }
        username = name
        usernameDefaults.set(name, forKey: usernameKey)
    }

    private func client() throws -> AniListClient {
        guard let token = anilistToken else { throw URLError(.userAuthenticationRequired) }
        return AniListClient { token }
    }

    private static func date(from fuzzyDate: FuzzyDate?) -> Date? {
        guard let year = fuzzyDate?.year, let month = fuzzyDate?.month, let day = fuzzyDate?.day else {
            return nil
        }
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
    }
}
