import Combine
import Foundation
import OSLog
import mal

/// A MyAnimeList work id as stored in `trackerLink.remoteMediaId`: `anime:<id>` or `manga:<id>`.
/// MyAnimeList numbers anime and manga separately, so the kind is part of the id. Novels and
/// light novels are MyAnimeList manga.
nonisolated struct MALMediaID: Hashable, Sendable, CustomStringConvertible {
    nonisolated enum Kind: String, Sendable {
        case anime
        case manga
    }

    let kind: Kind
    let id: Int

    init(kind: Kind, id: Int) {
        self.kind = kind
        self.id = id
    }

    /// Parses `anime:<id>` or `manga:<id>` with a positive id; anything else is rejected.
    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let kind = Kind(rawValue: String(parts[0])),
              let id = Int(parts[1]), id > 0,
              "\(kind.rawValue):\(id)" == rawValue
        else {
            return nil
        }
        self.init(kind: kind, id: id)
    }

    var description: String {
        "\(kind.rawValue):\(id)"
    }
}

nonisolated enum MALTrackerError: Error, Equatable, Sendable, LocalizedError {
    case invalidMediaID
    case invalidStatus(String)
    case unsupportedRemoteStatus(String)

    var errorDescription: String? {
        switch self {
        case .invalidMediaID:
            "The linked MyAnimeList id is invalid."
        case .invalidStatus(let status):
            "\(status) is not a list status MyAnimeList supports."
        case .unsupportedRemoteStatus(let status):
            "MyAnimeList reports the list status \(status), which Ito does not support yet."
        }
    }
}

/// The parts of a MyAnimeList list entry and work that `MALWritePolicy` decides on.
nonisolated struct MALListSnapshot: Equatable, Sendable {
    nonisolated enum ListStatus: Equatable, Sendable {
        /// `watching` / `reading`.
        case active
        /// `plan_to_watch` / `plan_to_read`.
        case planned
        case completed
        case onHold
        case dropped
        case unknown(String)
    }

    /// `nil` when the work is not on the user's list.
    let listStatus: ListStatus?
    /// `is_rewatching` / `is_rereading`.
    let isRepeating: Bool
    /// Episodes watched or chapters read.
    let progress: Int
    /// Total episodes or chapters; 0 when unknown or still releasing.
    let total: Int
    /// The work has not aired or been published yet.
    let isUnreleased: Bool
    /// A manga the user tracks by volumes only, because MyAnimeList lists no chapter count.
    let tracksVolumesOnly: Bool
}

/// The fields of one list update. `nil` fields are not sent.
nonisolated struct MALListPatch: Equatable, Sendable {
    var status: MALListSnapshot.ListStatus?
    var isRepeating: Bool?
    var progress: Int?
}

/// Decides what Ito may write to a MyAnimeList list entry. The rules exist so that Ito never
/// damages a list: it never deletes entries, never lowers progress on its own, never touches
/// scores, dates, tags, comments, priority or rewatch counts, and on automatic sync only moves
/// an entry the user is actively watching or reading.
nonisolated enum MALWritePolicy {
    /// - Parameters:
    ///   - snapshot: The entry and work as just read from MyAnimeList.
    ///   - progress: The episode or chapter to record.
    ///   - status: An explicit Ito tracker status from the tracker sheet, or `nil` for automatic sync.
    /// - Returns: The update to send, or `nil` to send nothing.
    static func patch(for snapshot: MALListSnapshot, progress: Int?, status: String?) throws -> MALListPatch? {
        guard let status else {
            return automaticPatch(for: snapshot, progress: progress)
        }
        return try explicitPatch(for: snapshot, progress: progress, status: status)
    }

    /// The Ito tracker status for an entry, or `nil` when the work is not on the list.
    static func trackerStatus(for snapshot: MALListSnapshot) throws -> String? {
        guard let listStatus = snapshot.listStatus else { return nil }
        if snapshot.isRepeating {
            return "REPEATING"
        }
        switch listStatus {
        case .active: return "CURRENT"
        case .planned: return "PLANNING"
        case .completed: return "COMPLETED"
        case .onHold: return "PAUSED"
        case .dropped: return "DROPPED"
        case .unknown(let raw): throw MALTrackerError.unsupportedRemoteStatus(raw)
        }
    }

    private static func automaticPatch(for snapshot: MALListSnapshot, progress: Int?) -> MALListPatch? {
        // Never create entries, touch unreleased works, or record nonsense progress automatically.
        guard let listStatus = snapshot.listStatus,
              !snapshot.isUnreleased,
              !snapshot.tracksVolumesOnly,
              let progress, progress > 0
        else {
            return nil
        }
        let target = capped(progress, total: snapshot.total)
        if listStatus == .active || snapshot.isRepeating {
            return target > snapshot.progress ? MALListPatch(progress: target) : nil
        }
        // Starting the first episode or chapter of a planned work; opening a later one is a peek.
        if listStatus == .planned, snapshot.progress == 0, target == 1 {
            return MALListPatch(status: .active, progress: 1)
        }
        return nil
    }

    private static func explicitPatch(for snapshot: MALListSnapshot, progress: Int?, status: String) throws -> MALListPatch? {
        if case .unknown(let raw) = snapshot.listStatus {
            throw MALTrackerError.unsupportedRemoteStatus(raw)
        }
        var patch = MALListPatch()
        let repeating = status == "REPEATING"
        switch status {
        case "CURRENT", "REPEATING": patch.status = .active
        case "PLANNING": patch.status = .planned
        case "COMPLETED": patch.status = .completed
        case "PAUSED": patch.status = .onHold
        case "DROPPED": patch.status = .dropped
        default: throw MALTrackerError.invalidStatus(status)
        }
        // MyAnimeList keeps a rewatch as `completed` + `is_rewatching`; leave that status alone.
        if patch.status == snapshot.listStatus || repeating && snapshot.listStatus == .completed {
            patch.status = nil
        }
        if repeating != snapshot.isRepeating {
            patch.isRepeating = repeating
        }
        if let progress, progress >= 0 {
            let target = capped(progress, total: snapshot.total)
            if snapshot.listStatus == nil {
                patch.progress = target > 0 ? target : nil
            } else if repeating {
                // Starting a rewatch may reset progress; everything else only moves forward.
                patch.progress = target != snapshot.progress ? target : nil
            } else {
                patch.progress = target > snapshot.progress ? target : nil
            }
        }
        return patch == MALListPatch() ? nil : patch
    }

    private static func capped(_ progress: Int, total: Int) -> Int {
        total > 0 ? min(progress, total) : progress
    }
}

/// MyAnimeList tracking. See `MALWritePolicy` for what it writes.
@MainActor
public final class MALTracker: TrackerProvider {
    /// Ito's MyAnimeList API client ID (an "iOS" app; public clients have no secret).
    static let clientID = "30f79466293f72290f670bd0476ba094"

    public let identifier = MALCredentialRepository.providerID
    public let name = "MyAnimeList"

    @Published private(set) var isSignedIn = false
    @Published public private(set) var username: String?

    public var isAuthenticated: Bool {
        isSignedIn
    }

    private let usernameKey = "mal_username"
    private let credentialRepository: MALCredentialRepository
    private let oauth: MALOAuth
    private let session: URLSession
    private let usernameDefaults: UserDefaults
    private var writeChains: [MALMediaID: Task<Void, any Error>] = [:]

    init(
        credentialRepository: MALCredentialRepository,
        oauth: MALOAuth,
        usernameDefaults: UserDefaults,
        session: URLSession = .shared
    ) {
        self.credentialRepository = credentialRepository
        self.oauth = oauth
        self.usernameDefaults = usernameDefaults
        self.session = session
        self.username = usernameDefaults.string(forKey: usernameKey)
    }

    func bootstrapCredentials() async -> MALCredentialRepository.BootstrapState {
        let result = await credentialRepository.bootstrap()
        isSignedIn = result.isSignedIn
        if !result.isSignedIn, result.state == .ready {
            clearUsername()
        }
        return result.state
    }

    public func authenticate(using oauthManager: OAuthManager) async throws {
        let request = oauth.authorizationRequest()
        let callbackURL = try await oauthManager.authenticate(url: request.url, callbackScheme: "ito")
        let code = try oauth.authorizationCode(from: callbackURL, matching: request)
        let token = try await oauth.exchangeCode(code, for: request)
        await credentialRepository.persist(token)
        isSignedIn = true
        do {
            let user = try await perform(CurrentUserRequest(fields: []))
            username = user.name
            usernameDefaults.set(user.name, forKey: usernameKey)
        } catch {
            AppLogger.auth.error("Failed to fetch the MyAnimeList user: \(error.localizedDescription)")
        }
    }

    public func logout() async throws {
        try await credentialRepository.logout()
        isSignedIn = false
        clearUsername()
    }

    public func searchMedia(title: String, isAnime: Bool) async throws -> [TrackerMedia] {
        // MyAnimeList answers HTTP 400 for queries shorter than 3 characters.
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 3 else { return [] }

        if isAnime {
            let fields: [AnimeField] = [.alternativeTitles, .mediaType, .numEpisodes]
            return try await perform(AnimeSearchRequest(query: query, limit: 10, fields: fields)).data.map { item in
                let anime = item.node
                return Self.trackerMedia(
                    id: MALMediaID(kind: .anime, id: anime.id),
                    title: anime.title,
                    englishTitle: anime.alternativeTitles?.english,
                    picture: anime.mainPicture,
                    mediaType: anime.mediaType?.rawValue,
                    episodes: anime.numEpisodes,
                    chapters: nil
                )
            }
        }
        let fields: [MangaField] = [.alternativeTitles, .mediaType, .numChapters]
        return try await perform(MangaSearchRequest(query: query, limit: 10, fields: fields)).data.map { item in
            let manga = item.node
            return Self.trackerMedia(
                id: MALMediaID(kind: .manga, id: manga.id),
                title: manga.title,
                englishTitle: manga.alternativeTitles?.english,
                picture: manga.mainPicture,
                mediaType: manga.mediaType?.rawValue,
                episodes: nil,
                chapters: manga.numChapters
            )
        }
    }

    public func getMediaListEntry(mediaId: String) async throws -> TrackerMediaEntry? {
        guard let id = MALMediaID(rawValue: mediaId) else { throw MALTrackerError.invalidMediaID }
        let entry = try await read(id)
        guard let status = try MALWritePolicy.trackerStatus(for: entry.snapshot) else {
            return nil
        }
        return TrackerMediaEntry(
            status: status,
            progress: entry.snapshot.progress,
            score: entry.score.flatMap { $0 > 0 ? Double($0) : nil },
            startDate: Self.date(from: entry.startDate),
            finishDate: Self.date(from: entry.finishDate)
        )
    }

    public func updateProgress(mediaId: String, progress: Int?, status: String?) async throws {
        guard let id = MALMediaID(rawValue: mediaId) else { throw MALTrackerError.invalidMediaID }
        // One write per entry at a time, so each pre-read sees the previous write.
        let previous = writeChains[id]
        let task = Task { @MainActor in
            _ = await previous?.result
            try await self.applyProgress(id: id, progress: progress, status: status)
        }
        writeChains[id] = task
        defer {
            if writeChains[id] == task {
                writeChains[id] = nil
            }
        }
        try await task.value
    }

    private func applyProgress(id: MALMediaID, progress: Int?, status: String?) async throws {
        // Fail closed: without a fresh read of the entry, nothing is written.
        let entry = try await read(id)
        guard let patch = try MALWritePolicy.patch(for: entry.snapshot, progress: progress, status: status) else {
            return
        }
        switch id.kind {
        case .anime:
            _ = try await perform(UpdateAnimeListStatusRequest(
                animeID: id.id,
                status: patch.status.map(Self.animeStatus),
                isRewatching: patch.isRepeating,
                numWatchedEpisodes: patch.progress
            ))
        case .manga:
            _ = try await perform(UpdateMangaListStatusRequest(
                mangaID: id.id,
                status: patch.status.map(Self.mangaStatus),
                isRereading: patch.isRepeating,
                numChaptersRead: patch.progress
            ))
        }
    }

    private struct RemoteEntry {
        let snapshot: MALListSnapshot
        let score: Int?
        let startDate: MALDate?
        let finishDate: MALDate?
    }

    private func read(_ id: MALMediaID) async throws -> RemoteEntry {
        switch id.kind {
        case .anime:
            let anime = try await perform(AnimeDetailsRequest(id: id.id, fields: [.status, .numEpisodes, .myListStatusAll]))
            let list = anime.myListStatus
            return RemoteEntry(
                snapshot: MALListSnapshot(
                    listStatus: list?.status.map { Self.listStatus($0.rawValue) },
                    isRepeating: list?.isRewatching ?? false,
                    progress: list?.numEpisodesWatched ?? 0,
                    total: anime.numEpisodes ?? 0,
                    isUnreleased: anime.status == .notYetAired,
                    tracksVolumesOnly: false
                ),
                score: list?.score,
                startDate: list?.startDate,
                finishDate: list?.finishDate
            )
        case .manga:
            let manga = try await perform(MangaDetailsRequest(id: id.id, fields: [.status, .numChapters, .numVolumes, .myListStatusAll]))
            let list = manga.myListStatus
            let chapters = manga.numChapters ?? 0
            return RemoteEntry(
                snapshot: MALListSnapshot(
                    listStatus: list?.status.map { Self.listStatus($0.rawValue) },
                    isRepeating: list?.isRereading ?? false,
                    progress: list?.numChaptersRead ?? 0,
                    total: chapters,
                    isUnreleased: manga.status == .notYetPublished,
                    tracksVolumesOnly: chapters == 0
                        && (manga.numVolumes ?? 0) > 0
                        && (list?.numChaptersRead ?? 0) == 0
                        && (list?.numVolumesRead ?? 0) > 0
                ),
                score: list?.score,
                startDate: list?.startDate,
                finishDate: list?.finishDate
            )
        }
    }

    /// Sends a request with a valid token, refreshing once if MyAnimeList answers 401.
    private func perform<R: MALRequest>(_ request: R) async throws -> R.Response {
        do {
            let token = try await credentialRepository.validAccessToken()
            do {
                return try await client(token).execute(request)
            } catch let error as MALError where error.isUnauthorized {
                let replacement = try await credentialRepository.accessToken(replacing: token)
                return try await client(replacement).execute(request)
            }
        } catch let error as MALCredentialRepository.CredentialError {
            isSignedIn = false
            clearUsername()
            throw error
        }
    }

    private func client(_ token: String) -> MALClient {
        MALClient(clientID: Self.clientID, session: session) { token }
    }

    private func clearUsername() {
        username = nil
        usernameDefaults.removeObject(forKey: usernameKey)
    }

    private static func listStatus(_ raw: String) -> MALListSnapshot.ListStatus {
        switch raw {
        case "watching", "reading": .active
        case "plan_to_watch", "plan_to_read": .planned
        case "completed": .completed
        case "on_hold": .onHold
        case "dropped": .dropped
        default: .unknown(raw)
        }
    }

    private static func animeStatus(_ status: MALListSnapshot.ListStatus) -> AnimeWatchStatus {
        switch status {
        case .active: .watching
        case .planned: .planToWatch
        case .completed: .completed
        case .onHold: .onHold
        case .dropped: .dropped
        case .unknown(let raw): AnimeWatchStatus(rawValue: raw)
        }
    }

    private static func mangaStatus(_ status: MALListSnapshot.ListStatus) -> MangaReadStatus {
        switch status {
        case .active: .reading
        case .planned: .planToRead
        case .completed: .completed
        case .onHold: .onHold
        case .dropped: .dropped
        case .unknown(let raw): MangaReadStatus(rawValue: raw)
        }
    }

    private static func trackerMedia(
        id: MALMediaID,
        title: String,
        englishTitle: String?,
        picture: Picture?,
        mediaType: String?,
        episodes: Int?,
        chapters: Int?
    ) -> TrackerMedia {
        let english = englishTitle.flatMap { $0.isEmpty ? nil : $0 }
        return TrackerMedia(
            id: id.description,
            title: english ?? title,
            titleRomaji: english == nil ? nil : title,
            coverImage: picture?.large ?? picture?.medium,
            format: mediaType.flatMap { $0 == "unknown" ? nil : $0.uppercased() },
            episodes: episodes.flatMap { $0 > 0 ? $0 : nil },
            chapters: chapters.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    private static func date(from date: MALDate?) -> Date? {
        guard let date, let month = date.month, let day = date.day else { return nil }
        return Calendar.current.date(from: DateComponents(year: date.year, month: month, day: day))
    }
}
