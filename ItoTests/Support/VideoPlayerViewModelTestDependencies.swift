import Foundation
import ito_runner
@testable import Ito

enum VideoPlayerTestError: LocalizedError {
    case expected
    case secret(String)

    var errorDescription: String? {
        switch self {
        case .expected:
            return "expected video player failure"
        case .secret(let value):
            return value
        }
    }
}

@MainActor
final class VideoPlayerEventRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

@MainActor
final class VideoStreamLoaderFake: VideoStreamLoading {
    enum Response {
        case success([Anime.Video])
        case failure(any Error)
        case suspended
    }

    struct Request {
        let anime: Anime
        let episode: Anime.Episode
    }

    private struct Pending {
        let continuation: CheckedContinuation<[Anime.Video], any Error>
    }

    private struct PendingWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    let events: VideoPlayerEventRecorder
    var responses: [Response] = []
    private(set) var requests: [Request] = []
    private var pending: [Pending] = []
    private var pendingWaiters: [PendingWaiter] = []

    init(events: VideoPlayerEventRecorder) {
        self.events = events
    }

    func videos(for anime: Anime, episode: Anime.Episode) async throws -> [Anime.Video] {
        events.record("stream")
        requests.append(Request(anime: anime, episode: episode))
        let response = responses.isEmpty ? .success([]) : responses.removeFirst()
        switch response {
        case .success(let videos):
            return videos
        case .failure(let error):
            throw error
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation in
                pending.append(Pending(continuation: continuation))
                resumeSatisfiedWaiters()
            }
        }
    }

    func waitForPendingCount(_ count: Int) async {
        guard pending.count < count else { return }
        await withCheckedContinuation { continuation in
            pendingWaiters.append(PendingWaiter(count: count, continuation: continuation))
        }
    }

    func resolveFirst(with result: Result<[Anime.Video], any Error>) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().continuation.resume(with: result)
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [PendingWaiter] = []
        for waiter in pendingWaiters {
            if pending.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        pendingWaiters = remaining
    }
}

@MainActor
final class VideoSubtitleLoaderFake: VideoSubtitleTextLoading {
    enum Response {
        case success(String)
        case failure(any Error)
        case suspended
    }

    private struct Pending {
        let url: String
        let continuation: CheckedContinuation<String, any Error>
    }

    private struct PendingWaiter {
        let url: String
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    var responses: [String: [Response]] = [:]
    private(set) var requestedURLs: [String] = []
    private var pending: [Pending] = []
    private var pendingWaiters: [PendingWaiter] = []

    func enqueue(_ response: Response, for url: String) {
        responses[url, default: []].append(response)
    }

    func text(from urlString: String) async throws -> String {
        requestedURLs.append(urlString)
        let response = responses[urlString]?.isEmpty == false
            ? responses[urlString]?.removeFirst()
            : .success("WEBVTT\n")
        switch response ?? .success("WEBVTT\n") {
        case .success(let text):
            return text
        case .failure(let error):
            throw error
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation in
                pending.append(Pending(url: urlString, continuation: continuation))
                resumeSatisfiedWaiters()
            }
        }
    }

    func waitForPendingCount(_ count: Int, for url: String) async {
        guard pendingCount(for: url) < count else { return }
        await withCheckedContinuation { continuation in
            pendingWaiters.append(
                PendingWaiter(url: url, count: count, continuation: continuation)
            )
        }
    }

    func resolveFirst(for url: String, with result: Result<String, any Error>) {
        guard let index = pending.firstIndex(where: { $0.url == url }) else { return }
        pending.remove(at: index).continuation.resume(with: result)
    }

    private func pendingCount(for url: String) -> Int {
        pending.filter { $0.url == url }.count
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [PendingWaiter] = []
        for waiter in pendingWaiters {
            if pendingCount(for: waiter.url) >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        pendingWaiters = remaining
    }
}

@MainActor
final class VideoPlaybackSurfaceFake: VideoPlaybackSurface {}

@MainActor
final class VideoPlaybackPreparationFake: VideoPlaybackPreparation {
    let id: String

    init(id: String) {
        self.id = id
    }
}

@MainActor
final class VideoPlaybackCoordinatorFake: VideoPlaybackCoordinating {
    enum Response {
        case preparation(String)
        case invalid
        case suspended
    }

    struct Request {
        let video: Anime.Video
    }

    private struct Pending {
        let videoURL: String
        let continuation: CheckedContinuation<(any VideoPlaybackPreparation)?, Never>
    }

    private struct CountWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var surface: (any VideoPlaybackSurface)?
    var responses: [String: [Response]] = [:]
    private(set) var requests: [Request] = []
    private(set) var activatedPreparationIDs: [String] = []
    private(set) var activatedStartTimes: [Double?] = []
    private(set) var observerInstallCount = 0
    private(set) var observerRemovalCount = 0
    private(set) var replacementCount = 0
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var shutdownCount = 0
    private var pending: [Pending] = []
    private var pendingWaiters: [CountWaiter] = []
    private var activationWaiters: [CountWaiter] = []
    private var hasObserver = false
    private var timeUpdate: (@MainActor (Double, Double) -> Void)?

    func enqueue(_ response: Response, for videoURL: String) {
        responses[videoURL, default: []].append(response)
    }

    func prepare(video: Anime.Video) async -> (any VideoPlaybackPreparation)? {
        requests.append(Request(video: video))
        let response = responses[video.url]?.isEmpty == false
            ? responses[video.url]?.removeFirst()
            : .preparation(video.url)
        switch response ?? .preparation(video.url) {
        case .preparation(let id):
            return VideoPlaybackPreparationFake(id: id)
        case .invalid:
            return nil
        case .suspended:
            return await withCheckedContinuation { continuation in
                pending.append(Pending(videoURL: video.url, continuation: continuation))
                resumePendingWaiters()
            }
        }
    }

    func activate(
        _ preparation: any VideoPlaybackPreparation,
        startTime: Double?,
        onTimeUpdate: @escaping @MainActor (Double, Double) -> Void
    ) -> Bool {
        guard let preparation = preparation as? VideoPlaybackPreparationFake else {
            return false
        }
        if surface == nil {
            surface = VideoPlaybackSurfaceFake()
        } else {
            replacementCount += 1
        }
        if !hasObserver {
            hasObserver = true
            observerInstallCount += 1
        }
        timeUpdate = onTimeUpdate
        activatedPreparationIDs.append(preparation.id)
        activatedStartTimes.append(startTime)
        playCount += 1
        resumeActivationWaiters()
        return true
    }

    func play() {
        playCount += 1
    }

    func pause() {
        pauseCount += 1
    }

    func shutdown() {
        shutdownCount += 1
        pauseCount += 1
        timeUpdate = nil
        if hasObserver {
            hasObserver = false
            observerRemovalCount += 1
        }
    }

    func emit(currentTime: Double, duration: Double) {
        timeUpdate?(currentTime, duration)
    }

    func waitForPendingCount(_ count: Int) async {
        guard pending.count < count else { return }
        await withCheckedContinuation { continuation in
            pendingWaiters.append(CountWaiter(count: count, continuation: continuation))
        }
    }

    func waitForActivationCount(_ count: Int) async {
        guard activatedPreparationIDs.count < count else { return }
        await withCheckedContinuation { continuation in
            activationWaiters.append(CountWaiter(count: count, continuation: continuation))
        }
    }

    func resolveFirst(
        for videoURL: String,
        preparationID: String?
    ) {
        guard let index = pending.firstIndex(where: { $0.videoURL == videoURL }) else { return }
        let result = preparationID.map { VideoPlaybackPreparationFake(id: $0) }
        pending.remove(at: index).continuation.resume(returning: result)
    }

    private func resumePendingWaiters() {
        var remaining: [CountWaiter] = []
        for waiter in pendingWaiters {
            if pending.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        pendingWaiters = remaining
    }

    private func resumeActivationWaiters() {
        var remaining: [CountWaiter] = []
        for waiter in activationWaiters {
            if activatedPreparationIDs.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        activationWaiters = remaining
    }
}

@MainActor
final class VideoPlayerHistoryFake: VideoPlayerHistoryRecording {
    struct Request {
        let anime: Anime
        let episodeKey: String
        let episodeTitle: String
        let pluginID: String
    }

    let events: VideoPlayerEventRecorder
    private(set) var requests: [Request] = []

    init(events: VideoPlayerEventRecorder) {
        self.events = events
    }

    func recordAnime(
        _ anime: Anime,
        episodeKey: String,
        episodeTitle: String,
        pluginID: String
    ) {
        events.record("history")
        requests.append(
            Request(
                anime: anime,
                episodeKey: episodeKey,
                episodeTitle: episodeTitle,
                pluginID: pluginID
            )
        )
    }
}

@MainActor
final class VideoPlayerProgressFake: VideoPlayerProgressTracking {
    enum Response {
        case success
        case failure(any Error)
        case suspended
    }

    struct Request {
        let context: PluginCompletionContext
        let episodeID: String
        let episodeNumber: Float?
    }

    let events: VideoPlayerEventRecorder
    var responses: [Response] = []
    private(set) var requests: [Request] = []
    private(set) var capturedContexts: [PluginCompletionContext] = []
    var originatingEpoch: String? = "epoch"
    /// Seconds an episode starts at, keyed by episode.
    var savedTimes: [String: Double] = [:]
    private(set) var savedTimeWrites: [Double] = []
    private var pending: [CheckedContinuation<Void, any Error>] = []
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []

    init(events: VideoPlayerEventRecorder) {
        self.events = events
    }

    func captureCompletionContext(
        media: MediaIdentity,
        mediaKey: String
    ) -> PluginCompletionContext {
        let context = PluginCompletionContext(
            media: media,
            mediaKey: mediaKey,
            originatingEpoch: originatingEpoch
        )
        capturedContexts.append(context)
        return context
    }

    func markEpisodeWatched(
        context: PluginCompletionContext,
        episodeID: String,
        episodeNumber: Float?
    ) async throws {
        events.record("progress")
        requests.append(
            Request(context: context, episodeID: episodeID, episodeNumber: episodeNumber)
        )
        let response = responses.isEmpty ? .success : responses.removeFirst()
        switch response {
        case .success:
            return
        case .failure(let error):
            throw error
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation in
                pending.append(continuation)
                let waiters = pendingWaiters
                pendingWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
    }

    func waitUntilPending() async {
        guard pending.isEmpty else { return }
        await withCheckedContinuation { pendingWaiters.append($0) }
    }

    func savedPlaybackTime(media: MediaIdentity, episodeID: String) -> Double? {
        _ = media
        return savedTimes[episodeID]
    }

    func savePlaybackTime(_ seconds: Double, media: MediaIdentity, episodeID: String) async throws {
        _ = media
        savedTimeWrites.append(seconds)
        savedTimes[episodeID] = seconds
    }

    func resolveFirst(with result: Result<Void, any Error>) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(with: result)
    }
}

@MainActor
final class VideoPlayerTrackerFake: VideoPlayerTrackerUpdating {
    let events: VideoPlayerEventRecorder
    var anilistID: String?
    private(set) var requests: [(media: MediaIdentity, progress: Int)] = []

    init(events: VideoPlayerEventRecorder) {
        self.events = events
    }

    func videoPlayerAnilistID(for media: MediaIdentity) -> String? {
        _ = media
        return anilistID
    }

    func updateVideoProgress(media: MediaIdentity, progress: Int) async {
        events.record("tracker")
        requests.append((media: media, progress: progress))
    }
}

@MainActor
final class VideoPlayerPresenceFake: VideoPlayerPresencePresenting {
    private(set) var presented: [VideoPlayerPresence] = []
    private(set) var clearCount = 0

    func presentVideoPlayerPresence(_ presence: VideoPlayerPresence) {
        presented.append(presence)
    }

    func clearVideoPlayerPresence() {
        clearCount += 1
    }
}

@MainActor
final class VideoPlayerPluginMetadataFake: VideoPlayerPluginMetadataProviding {
    var displayName: String?

    func videoPlayerPluginDisplayName(for pluginID: String) -> String? {
        _ = pluginID
        return displayName
    }
}

@MainActor
struct VideoPlayerTestSubject {
    let viewModel: VideoPlayerViewModel
    let events: VideoPlayerEventRecorder
    let streamLoader: VideoStreamLoaderFake
    let subtitleLoader: VideoSubtitleLoaderFake
    let playback: VideoPlaybackCoordinatorFake
    let history: VideoPlayerHistoryFake
    let progress: VideoPlayerProgressFake
    let tracker: VideoPlayerTrackerFake
    let presence: VideoPlayerPresenceFake
    let metadata: VideoPlayerPluginMetadataFake
    let logger: PresentationEventCaptureSpy
}

@MainActor
func makeVideoPlayerSubject(
    anime: Anime = Anime(key: "anime", title: "Anime"),
    episode: Anime.Episode = Anime.Episode(key: "episode", title: "Episode 1", episode: 1)
) -> VideoPlayerTestSubject {
    let events = VideoPlayerEventRecorder()
    let streamLoader = VideoStreamLoaderFake(events: events)
    let subtitleLoader = VideoSubtitleLoaderFake()
    let playback = VideoPlaybackCoordinatorFake()
    let history = VideoPlayerHistoryFake(events: events)
    let progress = VideoPlayerProgressFake(events: events)
    let tracker = VideoPlayerTrackerFake(events: events)
    let presence = VideoPlayerPresenceFake()
    let metadata = VideoPlayerPluginMetadataFake()
    let logger = PresentationEventCaptureSpy()
    let dependencies = PreparedVideoPlayerDependencies(
        progress: progress,
        history: history,
        tracker: tracker,
        presence: presence,
        pluginMetadata: metadata,
        subtitleLoader: subtitleLoader,
        makePlaybackCoordinator: { playback },
        presentationLogger: logger
    )
    let viewModel = VideoPlayerViewModel(
        streamLoader: streamLoader,
        pluginID: "plugin.test",
        anime: anime,
        episode: episode,
        dependencies: dependencies
    )
    return VideoPlayerTestSubject(
        viewModel: viewModel,
        events: events,
        streamLoader: streamLoader,
        subtitleLoader: subtitleLoader,
        playback: playback,
        history: history,
        progress: progress,
        tracker: tracker,
        presence: presence,
        metadata: metadata,
        logger: logger
    )
}

func video(
    _ url: String,
    quality: String = "1080p",
    headers: [String: String]? = nil,
    audioTracks: [Anime.AudioTrack]? = nil,
    subtitles: [Anime.Subtitle]? = nil
) -> Anime.Video {
    Anime.Video(
        url: url,
        quality: quality,
        headers: headers,
        audioTracks: audioTracks,
        subtitles: subtitles
    )
}

func subtitle(
    _ url: String,
    language: String,
    isHardsub: Bool = false
) -> Anime.Subtitle {
    Anime.Subtitle(
        url: url,
        language: language,
        format: "vtt",
        isHardsub: isHardsub
    )
}
