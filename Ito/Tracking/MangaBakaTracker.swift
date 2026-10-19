import Combine
import Foundation
import MangaBakaSDK
import OSLog

nonisolated enum MangaBakaTrackerError: Error, Equatable, Sendable, LocalizedError, TrackerUserFacingError {
    case invalidMediaID
    case invalidStatus(String)
    case unsupportedRemoteStatus(String)
    /// The linked series was merged into another MangaBaka series.
    case seriesMerged(into: Int)
    /// The linked series was removed from MangaBaka.
    case seriesUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidMediaID:
            "The linked MangaBaka id is invalid."
        case .invalidStatus(let status):
            "\(status) is not a library state MangaBaka supports."
        case .unsupportedRemoteStatus(let status):
            "MangaBaka reports the library state \(status), which Ito does not support yet."
        case .seriesMerged(let id):
            "MangaBaka merged this series into series \(id). Stop tracking it and link it again."
        case .seriesUnavailable:
            "This series is no longer available on MangaBaka. Stop tracking it and link it again."
        }
    }

    var userMessage: String {
        errorDescription ?? "MangaBaka could not be reached."
    }
}

/// The parts of a MangaBaka library entry and series that `MangaBakaWritePolicy` decides on.
nonisolated struct MangaBakaEntrySnapshot: Equatable, Sendable {
    nonisolated enum State: Equatable, Sendable {
        case reading
        case rereading
        case planToRead
        case considering
        case completed
        case paused
        case dropped
        case unknown(String)
    }

    /// `nil` when the series is not in the user's library.
    let state: State?
    /// Chapters read. MangaBaka allows fractional chapters, such as 12.5.
    let progress: Double
    /// The chapter count of a finished series; 0 when unknown or still releasing.
    let total: Int
    /// The series has not been published yet.
    let isUnreleased: Bool
    /// The user tracks this series by volumes only.
    let tracksVolumesOnly: Bool
}

/// The fields of one library write. `nil` fields are not sent.
nonisolated struct MangaBakaEntryPatch: Equatable, Sendable {
    var state: MangaBakaEntrySnapshot.State?
    var progress: Int?
}

/// Decides what Ito may write to a MangaBaka library entry, so that Ito never damages a library:
/// it never removes entries or lowers progress on its own, never touches ratings, dates, notes,
/// priority, privacy or reread counts, and on automatic sync only moves an entry the user is
/// actively reading.
nonisolated enum MangaBakaWritePolicy {
    /// - Parameters:
    ///   - snapshot: The entry and series as just read from MangaBaka.
    ///   - progress: The chapter to record.
    ///   - status: An explicit Ito tracker status from the tracker sheet, or `nil` for automatic sync.
    /// - Returns: The write to send, or `nil` to send nothing.
    static func patch(for snapshot: MangaBakaEntrySnapshot, progress: Int?, status: String?) throws -> MangaBakaEntryPatch? {
        guard let status else {
            return automaticPatch(for: snapshot, progress: progress)
        }
        return try explicitPatch(for: snapshot, progress: progress, status: status)
    }

    /// The Ito tracker status for an entry, or `nil` when the series is not in the library.
    static func trackerStatus(for snapshot: MangaBakaEntrySnapshot) throws -> String? {
        guard let state = snapshot.state else { return nil }
        switch state {
        case .reading: return "CURRENT"
        case .rereading: return "REPEATING"
        case .planToRead, .considering: return "PLANNING"
        case .completed: return "COMPLETED"
        case .paused: return "PAUSED"
        case .dropped: return "DROPPED"
        case .unknown(let raw): throw MangaBakaTrackerError.unsupportedRemoteStatus(raw)
        }
    }

    private static func automaticPatch(for snapshot: MangaBakaEntrySnapshot, progress: Int?) -> MangaBakaEntryPatch? {
        // Never create entries, touch unpublished series, or record nonsense progress automatically.
        guard let state = snapshot.state,
              !snapshot.isUnreleased,
              !snapshot.tracksVolumesOnly,
              let progress, progress > 0
        else {
            return nil
        }
        let target = capped(progress, total: snapshot.total)
        switch state {
        case .reading, .rereading:
            return Double(target) > snapshot.progress ? MangaBakaEntryPatch(progress: target) : nil
        case .planToRead where snapshot.progress == 0 && target == 1,
             .considering where snapshot.progress == 0 && target == 1:
            // Starting chapter 1 of a planned series; opening a later chapter is a peek.
            return MangaBakaEntryPatch(state: .reading, progress: 1)
        default:
            return nil
        }
    }

    private static func explicitPatch(for snapshot: MangaBakaEntrySnapshot, progress: Int?, status: String) throws -> MangaBakaEntryPatch? {
        if case .unknown(let raw) = snapshot.state {
            throw MangaBakaTrackerError.unsupportedRemoteStatus(raw)
        }
        var patch = MangaBakaEntryPatch()
        let rereading = status == "REPEATING"
        switch status {
        case "CURRENT": patch.state = .reading
        case "REPEATING": patch.state = .rereading
        case "PLANNING": patch.state = .planToRead
        case "COMPLETED": patch.state = .completed
        case "PAUSED": patch.state = .paused
        case "DROPPED": patch.state = .dropped
        default: throw MangaBakaTrackerError.invalidStatus(status)
        }
        // Ito shows `considering` as Planning; keeping Planning leaves it as it is.
        if patch.state == snapshot.state || patch.state == .planToRead && snapshot.state == .considering {
            patch.state = nil
        }
        if let progress, progress >= 0 {
            let target = capped(progress, total: snapshot.total)
            if snapshot.state == nil {
                patch.progress = target > 0 ? target : nil
            } else if rereading {
                // Starting a reread may reset progress. The sheet shows MangaBaka's progress rounded
                // down, so saving that value unchanged leaves a fractional chapter alone.
                patch.progress = progress != Int(snapshot.progress.rounded(.down)) ? target : nil
            } else {
                patch.progress = Double(target) > snapshot.progress ? target : nil
            }
        }
        return patch == MangaBakaEntryPatch() ? nil : patch
    }

    private static func capped(_ progress: Int, total: Int) -> Int {
        total > 0 ? min(progress, total) : progress
    }
}

/// MangaBaka tracking for manga and novels. See `MangaBakaWritePolicy` for what it writes.
@MainActor
public final class MangaBakaTracker: TrackerProvider, TrackerTokenAuthenticating {
    /// Ito's MangaBaka OAuth client ID (a public application; public clients have no secret).
    static let clientID = "mIujtlrWyyjQyUEYToReIpJwsWeBJkaH"
    static let redirectURI = "ito://mangabaka-callback"

    public let identifier = MangaBakaCredentialRepository.providerID
    public let name = "MangaBaka"
    public let tracksAnime = false
    let tokenCreationURL = URL(string: "https://mangabaka.org/my/settings/api-and-apps")!

    @Published private(set) var isSignedIn = false
    @Published public private(set) var username: String?

    public var isAuthenticated: Bool {
        isSignedIn
    }

    private static let userAgent = "Ito/\(AppVersion.marketing) (https://github.com/AtiinLabs/Ito)"
    /// Tracker screens wait for a retry at most this long instead of the SDK's 30 seconds.
    private static let retryPolicy = MangaBakaRetryPolicy(maximumRetries: 2, initialDelay: 1, maximumDelay: 10)

    private let usernameKey = "mangabaka_username"
    private let credentialRepository: MangaBakaCredentialRepository
    private let oauth: MangaBakaOAuth
    private let usernameDefaults: UserDefaults
    private let session: URLSession
    private let catalog: MangaBakaClient
    private var writeChains: [Int: Task<Void, any Error>] = [:]

    init(
        credentialRepository: MangaBakaCredentialRepository,
        oauth: MangaBakaOAuth,
        usernameDefaults: UserDefaults,
        session: URLSession = .shared
    ) {
        self.credentialRepository = credentialRepository
        self.oauth = oauth
        self.usernameDefaults = usernameDefaults
        self.session = session
        catalog = Self.client(credential: nil, session: session)
        username = usernameDefaults.string(forKey: usernameKey)
    }

    func bootstrapCredentials() async -> MangaBakaCredentialRepository.BootstrapState {
        let result = await credentialRepository.bootstrap()
        isSignedIn = result.isSignedIn
        if !result.isSignedIn, result.state == .ready {
            clearUsername()
        }
        return result.state
    }

    /// Signs in through MangaBaka's OAuth page with PKCE.
    public func authenticate(using oauthManager: OAuthManager) async throws {
        let request = oauth.authorizationRequest()
        let callbackURL = try await oauthManager.authenticate(url: request.url, callbackScheme: "ito")
        let code = try oauth.authorizationCode(from: callbackURL, matching: request)
        let token = try await oauth.exchangeCode(code, for: request)
        await credentialRepository.persist(.oauth(token))
        isSignedIn = true
        do {
            storeUsername(of: try await Self.client(credential: .oauthAccessToken(token.accessToken), session: session).profile())
        } catch {
            AppLogger.auth.error("Failed to fetch the MangaBaka profile: \(error.localizedDescription)")
        }
    }

    /// Signs in with a Personal Access Token the user created on mangabaka.org.
    func authenticate(token: String) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw TrackerTokenError.rejected }
        let profile: MangaBakaProfile
        do {
            profile = try await Self.client(credential: .personalAccessToken(token), session: session).profile()
        } catch MangaBakaError.unauthorized, MangaBakaError.forbidden {
            throw TrackerTokenError.rejected
        }
        await credentialRepository.persist(.personalAccessToken(token))
        isSignedIn = true
        storeUsername(of: profile)
    }

    public func logout() async throws {
        let token = try await credentialRepository.logout()
        isSignedIn = false
        clearUsername()
        if let token {
            // Ending the session on MangaBaka is best effort; the local session is already gone.
            try? await oauth.revoke(token)
        }
    }

    public func searchMedia(title: String, isAnime: Bool) async throws -> [TrackerMedia] {
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isAnime, !query.isEmpty else { return [] }
        // Every content rating: the user is looking for a series they are already reading.
        let page = try await catalog.searchSeries(SeriesSearchQuery(
            text: query,
            contentRatings: [.safe, .suggestive, .erotica, .pornographic],
            limit: 10
        ))
        return page.items.filter { $0.state == .active }.map(Self.trackerMedia)
    }

    public func getMediaListEntry(mediaId: String) async throws -> TrackerMediaEntry? {
        let entry = try await read(try Self.seriesID(mediaId))
        guard let status = try MangaBakaWritePolicy.trackerStatus(for: entry.snapshot), let library = entry.library else {
            return nil
        }
        return TrackerMediaEntry(
            status: status,
            progress: Int(entry.snapshot.progress),
            // MangaBaka rates 0–100; Ito shows scores out of 10.
            score: library.rating.flatMap { $0 > 0 ? $0 / 10 : nil },
            startDate: Self.date(from: library.startDate),
            finishDate: Self.date(from: library.finishDate)
        )
    }

    public func updateProgress(mediaId: String, progress: Int?, status: String?) async throws {
        let id = try Self.seriesID(mediaId)
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

    private func applyProgress(id: Int, progress: Int?, status: String?) async throws {
        // Fail closed: without a fresh read of the entry and series, nothing is written.
        let entry = try await read(id)
        guard let patch = try MangaBakaWritePolicy.patch(for: entry.snapshot, progress: progress, status: status) else {
            return
        }
        let changes = LibraryEntryChanges(
            state: patch.state.map(Self.libraryState),
            progressChapter: patch.progress.map(Double.init)
        )
        if entry.library == nil {
            guard changes.state != nil else { return }
            try await perform { try await $0.createLibraryEntry(seriesID: id, changes) }
        } else {
            try await perform { try await $0.updateLibraryEntry(seriesID: id, changes) }
        }
    }

    private struct RemoteEntry {
        let snapshot: MangaBakaEntrySnapshot
        let library: LibraryEntry?
    }

    private func read(_ id: Int) async throws -> RemoteEntry {
        async let seriesRead = catalog.series(id: id)
        let library = try await perform { try await $0.libraryEntry(seriesID: id) }
        let series = try await seriesRead
        switch series.state {
        case .active:
            break
        case .merged:
            guard let target = series.mergedWith else { throw MangaBakaTrackerError.seriesUnavailable }
            throw MangaBakaTrackerError.seriesMerged(into: target)
        default:
            throw MangaBakaTrackerError.seriesUnavailable
        }
        let chapters = library?.progressChapter ?? 0
        return RemoteEntry(
            snapshot: MangaBakaEntrySnapshot(
                state: library.map { Self.snapshotState($0.state) },
                progress: chapters,
                total: series.status == .completed ? Self.count(series.totalChapters) ?? 0 : 0,
                isUnreleased: series.status == .upcoming,
                tracksVolumesOnly: chapters == 0 && (library?.progressVolume ?? 0) > 0
            ),
            library: library
        )
    }

    /// Runs a library request with the saved credential. After a 401 it retries once with a
    /// refreshed OAuth token, or with a credential saved since the request started; it signs out
    /// when MangaBaka rejects the session.
    private func perform<T>(_ operation: (MangaBakaClient) async throws -> T) async throws -> T {
        do {
            let credential = try await credentialRepository.validCredential()
            do {
                return try await operation(Self.client(credential: credential, session: session))
            } catch MangaBakaError.unauthorized {
                let replacement = try await credentialRepository.credential(replacing: credential)
                return try await operation(Self.client(credential: replacement, session: session))
            }
        } catch let error as MangaBakaCredentialRepository.CredentialError {
            markSignedOut()
            throw error
        }
    }

    private func storeUsername(of profile: MangaBakaProfile) {
        if let name = profile.preferredUsername ?? profile.nickname {
            username = name
            usernameDefaults.set(name, forKey: usernameKey)
        } else {
            clearUsername()
        }
    }

    private func markSignedOut() {
        isSignedIn = false
        clearUsername()
    }

    private func clearUsername() {
        username = nil
        usernameDefaults.removeObject(forKey: usernameKey)
    }

    private static func client(credential: MangaBakaCredential?, session: URLSession) -> MangaBakaClient {
        MangaBakaClient(
            configuration: MangaBakaConfiguration(
                userAgent: userAgent,
                credentialProvider: credential,
                retryPolicy: retryPolicy
            ),
            session: session
        )
    }

    private static func seriesID(_ mediaID: String) throws -> Int {
        guard let id = Int(mediaID), id > 0 else { throw MangaBakaTrackerError.invalidMediaID }
        return id
    }

    private static func snapshotState(_ state: LibraryState?) -> MangaBakaEntrySnapshot.State {
        switch state {
        case .reading?: .reading
        case .rereading?: .rereading
        case .planToRead?: .planToRead
        case .considering?: .considering
        case .completed?: .completed
        case .paused?: .paused
        case .dropped?: .dropped
        case let other?: .unknown(other.rawValue)
        case nil: .unknown("none")
        }
    }

    private static func libraryState(_ state: MangaBakaEntrySnapshot.State) -> LibraryState {
        switch state {
        case .reading: .reading
        case .rereading: .rereading
        case .planToRead: .planToRead
        case .considering: .considering
        case .completed: .completed
        case .paused: .paused
        case .dropped: .dropped
        case .unknown(let raw): LibraryState(rawValue: raw)
        }
    }

    private static func trackerMedia(_ series: Series) -> TrackerMedia {
        let title = series.title(preferring: ["en", "ja-Latn", "ja"]) ?? "MangaBaka \(series.id)"
        let romanized = series.titles.first { $0.language == "ja-Latn" && $0.isPrimary }?.title
        return TrackerMedia(
            id: String(series.id),
            title: title,
            titleRomaji: romanized == title ? nil : romanized,
            coverImage: (series.cover.x250 ?? series.cover.raw)?.absoluteString,
            format: format(series.type),
            episodes: nil,
            chapters: count(series.totalChapters)
        )
    }

    /// Ito's format names. Every MangaBaka type is read, so each maps to a reading format.
    private static func format(_ type: SeriesType) -> String {
        switch type {
        case .novel: "NOVEL"
        case .manhwa: "MANHWA"
        case .manhua: "MANHUA"
        case .oel: "OEL"
        default: "MANGA"
        }
    }

    private static func count(_ value: Double?) -> Int? {
        guard let value, value.isFinite, value >= 1, value < 1_000_000 else { return nil }
        return Int(value)
    }

    private static func date(from day: LibraryDate?) -> Date? {
        guard let day else { return nil }
        return Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
    }
}
