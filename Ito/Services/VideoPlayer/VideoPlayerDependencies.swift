import AVFoundation
import Foundation
import ito_runner

@MainActor
protocol VideoStreamLoading: AnyObject {
    func videos(for anime: Anime, episode: Anime.Episode) async throws -> [Anime.Video]
}

@MainActor
final class ItoRunnerVideoStreamLoader: VideoStreamLoading {
    let runner: ItoRunner

    init(runner: ItoRunner) {
        self.runner = runner
    }

    func videos(for anime: Anime, episode: Anime.Episode) async throws -> [Anime.Video] {
        try await runner.getVideoList(anime: anime, episode: episode)
    }
}

@MainActor
protocol VideoSubtitleTextLoading: AnyObject {
    func text(from urlString: String) async throws -> String
}

enum VideoSubtitleLoaderError: Error {
    case invalidURL
    case nonUTF8Data
}

@MainActor
final class URLSessionVideoSubtitleLoader: VideoSubtitleTextLoading {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    func text(from urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw VideoSubtitleLoaderError.invalidURL
        }
        let (data, _) = try await session.data(from: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw VideoSubtitleLoaderError.nonUTF8Data
        }
        return text
    }
}

@MainActor
protocol VideoPlaybackSurface: AnyObject {}

@MainActor
protocol VideoPlaybackPreparation: AnyObject {}

@MainActor
protocol VideoPlaybackCoordinating: AnyObject {
    var surface: (any VideoPlaybackSurface)? { get }

    func prepare(video: Anime.Video) async -> (any VideoPlaybackPreparation)?
    /// Starts playing `preparation`, from `startTime` seconds when given.
    func activate(
        _ preparation: any VideoPlaybackPreparation,
        startTime: Double?,
        onTimeUpdate: @escaping @MainActor (Double, Double) -> Void
    ) -> Bool
    func play()
    func pause()
    func shutdown()
}

@MainActor
final class AVPlayerVideoPlaybackSurface: VideoPlaybackSurface {
    let player: AVPlayer

    init(player: AVPlayer) {
        self.player = player
    }
}

@MainActor
private final class AVPlayerVideoPlaybackPreparation: VideoPlaybackPreparation {
    let item: AVPlayerItem

    init(item: AVPlayerItem) {
        self.item = item
    }
}

@MainActor
final class AVPlayerVideoPlaybackCoordinator: VideoPlaybackCoordinating {
    private(set) var surface: (any VideoPlaybackSurface)?

    private var player: AVPlayer?
    private var periodicObserverToken: Any?
    private var observerGeneration: UInt64 = 0
    private var timeUpdate: (@MainActor (Double, Double) -> Void)?
    private var readyObservation: NSKeyValueObservation?
    /// True from activation until the seek to the start time finishes: until then the player
    /// reports 0:00, which must not reach (and be saved by) the caller.
    private var isSeekingToStart = false

    func prepare(video: Anime.Video) async -> (any VideoPlaybackPreparation)? {
        guard let url = URL(string: video.url) else { return nil }
        let asset = AVURLAsset(url: url, options: Self.assetOptions(for: video))
        return AVPlayerVideoPlaybackPreparation(item: AVPlayerItem(asset: asset))
    }

    static func assetOptions(for video: Anime.Video) -> [String: Any] {
        guard let headers = video.headers, !headers.isEmpty else { return [:] }
        return ["AVURLAssetHTTPHeaderFieldsKey": headers]
    }

    func activate(
        _ preparation: any VideoPlaybackPreparation,
        startTime: Double?,
        onTimeUpdate: @escaping @MainActor (Double, Double) -> Void
    ) -> Bool {
        guard let preparation = preparation as? AVPlayerVideoPlaybackPreparation else {
            return false
        }

        timeUpdate = onTimeUpdate
        readyObservation = nil
        if let player {
            player.replaceCurrentItem(with: preparation.item)
        } else {
            let player = AVPlayer(playerItem: preparation.item)
            self.player = player
            surface = AVPlayerVideoPlaybackSurface(player: player)
        }
        installPeriodicObserverIfNeeded()
        if let startTime, startTime > 0 {
            isSeekingToStart = true
            playWhenReady(preparation.item, from: startTime)
        } else {
            isSeekingToStart = false
            player?.play()
        }
        return true
    }

    /// Seeks once the item can play, then starts playback; a seek before then may be dropped.
    private func playWhenReady(_ item: AVPlayerItem, from startTime: Double) {
        let target = CMTime(seconds: startTime, preferredTimescale: 600)
        readyObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor [weak self] in
                guard let self, self.player?.currentItem === item, self.readyObservation != nil else {
                    return
                }
                self.readyObservation = nil
                item.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard self?.player?.currentItem === item else { return }
                        self?.isSeekingToStart = false
                        self?.player?.play()
                    }
                }
            }
        }
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func shutdown() {
        player?.pause()
        timeUpdate = nil
        readyObservation = nil
        observerGeneration &+= 1
        if let periodicObserverToken, let player {
            player.removeTimeObserver(periodicObserverToken)
            self.periodicObserverToken = nil
        }
    }

    private func installPeriodicObserverIfNeeded() {
        guard periodicObserverToken == nil, let player else { return }
        observerGeneration &+= 1
        let generation = observerGeneration
        periodicObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self,
                      self.periodicObserverToken != nil,
                      self.observerGeneration == generation,
                      !self.isSeekingToStart,
                      let timeUpdate = self.timeUpdate else { return }
                let duration = self.player?.currentItem?.duration.seconds ?? .nan
                timeUpdate(time.seconds, duration)
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            shutdown()
        }
    }
}

@MainActor
protocol VideoPlayerProgressTracking: AnyObject {
    func markEpisodeWatched(
        media: MediaIdentity,
        episodeID: String,
        episodeNumber: Float?
    ) async throws
    /// Seconds into `episodeID` where watching stopped, if it is the last episode watched.
    func savedPlaybackTime(media: MediaIdentity, episodeID: String) -> Double?
    func savePlaybackTime(_ seconds: Double, media: MediaIdentity, episodeID: String) async throws
}

extension ReadProgressManager: VideoPlayerProgressTracking {
    func markEpisodeWatched(
        media: MediaIdentity,
        episodeID: String,
        episodeNumber: Float?
    ) async throws {
        try await markAsWatched(
            media: media,
            episodeId: episodeID,
            episodeNum: episodeNumber
        )
    }

    func savedPlaybackTime(media: MediaIdentity, episodeID: String) -> Double? {
        savedPosition(media: media, chapterKey: episodeID)
    }

    func savePlaybackTime(_ seconds: Double, media: MediaIdentity, episodeID: String) async throws {
        try await savePosition(media: media, chapterKey: episodeID, position: seconds)
    }
}

@MainActor
protocol VideoPlayerHistoryRecording: AnyObject {
    func recordAnime(
        _ anime: Anime,
        episodeKey: String,
        episodeTitle: String,
        pluginID: String
    )
}

extension HistoryManager: VideoPlayerHistoryRecording {
    func recordAnime(
        _ anime: Anime,
        episodeKey: String,
        episodeTitle: String,
        pluginID: String
    ) {
        addAnime(
            anime,
            episodeKey: episodeKey,
            episodeTitle: episodeTitle,
            pluginId: pluginID
        )
    }
}

@MainActor
protocol VideoPlayerTrackerUpdating: AnyObject {
    func videoPlayerAnilistID(for media: MediaIdentity) -> String?
    func updateVideoProgress(media: MediaIdentity, progress: Int) async
}

extension TrackerManager: VideoPlayerTrackerUpdating {
    func videoPlayerAnilistID(for media: MediaIdentity) -> String? {
        trackerId(for: media, providerId: "anilist")
    }

    func updateVideoProgress(media: MediaIdentity, progress: Int) async {
        await updateProgress(media: media, progress: progress)
    }
}

nonisolated struct VideoPlayerPresence: Equatable, Sendable {
    let details: String
    let state: String
    let activityType: Int
    let detailsURL: String?
    let largeImageText: String
    let imageURL: String?
    let resetTimer: Bool
}

@MainActor
protocol VideoPlayerPresencePresenting: AnyObject {
    func presentVideoPlayerPresence(_ presence: VideoPlayerPresence)
    func clearVideoPlayerPresence()
}

extension DiscordRPCManager: VideoPlayerPresencePresenting {
    func presentVideoPlayerPresence(_ presence: VideoPlayerPresence) {
        setActivity(
            details: presence.details,
            state: presence.state,
            activityType: presence.activityType,
            detailsUrl: presence.detailsURL,
            largeImageText: presence.largeImageText,
            imageUrl: presence.imageURL,
            resetTimer: presence.resetTimer
        )
    }

    func clearVideoPlayerPresence() {
        clearActivity()
    }
}

@MainActor
protocol VideoPlayerPluginMetadataProviding: AnyObject {
    func videoPlayerPluginDisplayName(for pluginID: String) -> String?
}

extension PluginManager: VideoPlayerPluginMetadataProviding {
    func videoPlayerPluginDisplayName(for pluginID: String) -> String? {
        installedPlugins[pluginID]?.info.name
    }
}

@MainActor
struct PreparedVideoPlayerDependencies {
    let progress: any VideoPlayerProgressTracking
    let history: any VideoPlayerHistoryRecording
    let tracker: any VideoPlayerTrackerUpdating
    let presence: any VideoPlayerPresencePresenting
    let pluginMetadata: any VideoPlayerPluginMetadataProviding
    let subtitleLoader: any VideoSubtitleTextLoading
    let makePlaybackCoordinator: () -> any VideoPlaybackCoordinating
    let presentationLogger: any PresentationEventLogging

    static func production(
        readProgressManager: ReadProgressManager,
        historyManager: HistoryManager,
        trackerManager: TrackerManager,
        discordRPCManager: DiscordRPCManager,
        pluginManager: PluginManager,
        presentationLogger: any PresentationEventLogging
    ) -> Self {
        Self(
            progress: readProgressManager,
            history: historyManager,
            tracker: trackerManager,
            presence: discordRPCManager,
            pluginMetadata: pluginManager,
            subtitleLoader: URLSessionVideoSubtitleLoader(),
            makePlaybackCoordinator: { AVPlayerVideoPlaybackCoordinator() },
            presentationLogger: presentationLogger
        )
    }

    static func unavailable() -> Self {
        let unavailable = UnavailableVideoPlayerDependencies()
        return Self(
            progress: unavailable,
            history: unavailable,
            tracker: unavailable,
            presence: unavailable,
            pluginMetadata: unavailable,
            subtitleLoader: unavailable,
            makePlaybackCoordinator: { UnavailableVideoPlaybackCoordinator() },
            presentationLogger: OSLogPresentationEventLogger()
        )
    }
}

@MainActor
private final class UnavailableVideoPlayerDependencies:
    VideoPlayerProgressTracking,
    VideoPlayerHistoryRecording,
    VideoPlayerTrackerUpdating,
    VideoPlayerPresencePresenting,
    VideoPlayerPluginMetadataProviding,
    VideoSubtitleTextLoading {
    func markEpisodeWatched(
        media: MediaIdentity,
        episodeID: String,
        episodeNumber: Float?
    ) async throws {
        _ = media
        _ = episodeID
        _ = episodeNumber
    }

    func savedPlaybackTime(media: MediaIdentity, episodeID: String) -> Double? {
        _ = media
        _ = episodeID
        return nil
    }

    func savePlaybackTime(_ seconds: Double, media: MediaIdentity, episodeID: String) async throws {
        _ = seconds
        _ = media
        _ = episodeID
    }

    func recordAnime(
        _ anime: Anime,
        episodeKey: String,
        episodeTitle: String,
        pluginID: String
    ) {
        _ = anime
        _ = episodeKey
        _ = episodeTitle
        _ = pluginID
    }

    func videoPlayerAnilistID(for media: MediaIdentity) -> String? {
        _ = media
        return nil
    }

    func updateVideoProgress(media: MediaIdentity, progress: Int) async {
        _ = media
        _ = progress
    }

    func presentVideoPlayerPresence(_ presence: VideoPlayerPresence) {
        _ = presence
    }

    func clearVideoPlayerPresence() {}

    func videoPlayerPluginDisplayName(for pluginID: String) -> String? {
        _ = pluginID
        return nil
    }

    func text(from urlString: String) async throws -> String {
        _ = urlString
        throw VideoSubtitleLoaderError.invalidURL
    }
}

@MainActor
private final class UnavailableVideoPlaybackCoordinator: VideoPlaybackCoordinating {
    var surface: (any VideoPlaybackSurface)? { nil }

    func prepare(video: Anime.Video) async -> (any VideoPlaybackPreparation)? {
        _ = video
        return nil
    }

    func activate(
        _ preparation: any VideoPlaybackPreparation,
        startTime: Double?,
        onTimeUpdate: @escaping @MainActor (Double, Double) -> Void
    ) -> Bool {
        _ = preparation
        _ = startTime
        _ = onTimeUpdate
        return false
    }

    func play() {}
    func pause() {}
    func shutdown() {}
}
