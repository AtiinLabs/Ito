import AVFoundation
import Combine
import Foundation
import ito_runner

@MainActor
protocol VideoStreamLoading: AnyObject {
    func videos(for anime: Anime, episode: Anime.Episode, operation: PluginNetworkOperation) async throws -> [Anime.Video]
}

@MainActor
final class ItoRunnerVideoStreamLoader: VideoStreamLoading {
    let runner: ItoRunner
    private let pluginID: String
    private let contexts: PluginNetworkContexts

    init(runner: ItoRunner, pluginID: String, contexts: PluginNetworkContexts) {
        self.runner = runner
        self.pluginID = pluginID
        self.contexts = contexts
    }

    func videos(for anime: Anime, episode: Anime.Episode, operation: PluginNetworkOperation) async throws -> [Anime.Video] {
        let context = contexts.context(pluginID: pluginID, operation)
        return try await pluginCall {
            try await runner.getEpisodeVideos(anime: anime, episode: episode, context: context)
        }
    }
}

@MainActor
protocol VideoSubtitleTextLoading: AnyObject {
    func text(from urlString: String, authority: NetworkRequestAuthority?) async throws -> String
}

extension VideoSubtitleTextLoading {
    func text(from urlString: String) async throws -> String {
        try await text(from: urlString, authority: nil)
    }
}

enum VideoSubtitleLoaderError: Error {
    case invalidURL
    case nonUTF8Data
}

@MainActor
final class URLSessionVideoSubtitleLoader: VideoSubtitleTextLoading {
    private let session: URLSession
    /// Where the subtitle download gets its authority. A subtitle is part of what the viewer asked to watch, so it
    /// is foreground reading; without a provider (tests) the request is not gated.
    private let authorities: AppNetworkAuthorityProvider?

    init(session: URLSession = URLSession(configuration: .default), authorities: AppNetworkAuthorityProvider? = nil) {
        self.session = session
        self.authorities = authorities
    }

    func text(from urlString: String, authority: NetworkRequestAuthority?) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw VideoSubtitleLoaderError.invalidURL
        }
        let transport = PolicyHTTPTransport(session: session, authority: authority ?? authorities?.authority(purpose: .foregroundReading))
        let (data, _) = try await transport.data(for: URLRequest(url: url))
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

    /// Called when a live policy change stops admitting the playing stream, after playback was stopped.
    var networkRefusalHandler: (@MainActor (HostNetworkPolicyOutcome) -> Void)? { get set }

    /// Admits and prepares `video`. A refusal by the network policy is thrown as its typed outcome before any
    /// remote asset exists; a nil result is a video that cannot be played for another reason.
    func prepare(video: Anime.Video, authority: NetworkRequestAuthority?) async throws -> (any VideoPlaybackPreparation)?
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
final class AVPlayerVideoPlaybackPreparation: VideoPlaybackPreparation {
    let item: AVPlayerItem
    let authority: NetworkRequestAuthority?

    init(item: AVPlayerItem, authority: NetworkRequestAuthority?) {
        self.item = item
        self.authority = authority
    }
}

extension VideoPlaybackCoordinating {
    func prepare(video: Anime.Video) async throws -> (any VideoPlaybackPreparation)? {
        try await prepare(video: video, authority: nil)
    }
}

/// Plays through `AVPlayer`.
///
/// What the network policy can enforce here is limited by AVFoundation. It is decided before the asset is
/// constructed and again when playback is activated; the system's expensive and constrained network flags are
/// set on the asset from the same decision; and a later policy change that stops admitting the stream stops it
/// at once. AVFoundation fetches HLS playlists, segments, keys and their adaptive retries internally, without a
/// per-request or redirect hook, so none of those individual requests is checked. The two flags are the only
/// per-request control, and they are the system's rule, not the host's policy. Video playback is therefore
/// outside any strict offline guarantee.
@MainActor
final class AVPlayerVideoPlaybackCoordinator: VideoPlaybackCoordinating {
    private(set) var surface: (any VideoPlaybackSurface)?
    var networkRefusalHandler: (@MainActor (HostNetworkPolicyOutcome) -> Void)?

    private var player: AVPlayer?
    private var periodicObserverToken: Any?
    private var observerGeneration: UInt64 = 0
    private var timeUpdate: (@MainActor (Double, Double) -> Void)?
    private var readyObservation: NSKeyValueObservation?
    private var policyObservation: AnyCancellable?
    private var networkObservationID: UUID?
#if DEBUG
    var onPolicyEvaluation: (() -> Void)?
#endif
    /// True from activation until the seek to the start time finishes: until then the player
    /// reports 0:00, which must not reach (and be saved by) the caller.
    private var isSeekingToStart = false

    func prepare(video: Anime.Video, authority: NetworkRequestAuthority?) async throws -> (any VideoPlaybackPreparation)? {
        guard let url = URL(string: video.url) else { return nil }
        var options = Self.assetOptions(for: video)
        let scheme = url.scheme?.lowercased()
        let remoteAuthority = scheme == "http" || scheme == "https" ? authority : nil
        if let authority = remoteAuthority {
            // Refused before an asset exists: nothing of this stream is requested.
            try authority.check()
            options[AVURLAssetAllowsExpensiveNetworkAccessKey] = authority.admitsExpensivePath
            options[AVURLAssetAllowsConstrainedNetworkAccessKey] = authority.admitsConstrainedPath
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        return AVPlayerVideoPlaybackPreparation(item: item, authority: remoteAuthority)
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
        // Decided again at activation: the path or the settings may have changed since preparation.
        if let authority = preparation.authority {
            do {
                try authority.check()
            } catch let outcome as HostNetworkPolicyOutcome {
                networkRefusalHandler?(outcome)
                return false
            } catch {
                return false
            }
            observePolicy(authority)
        } else {
            policyObservation = nil
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

    /// Best-effort stop of this stream on a source, revision or path refusal. Internal AVFoundation requests
    /// already in flight are outside the delegate boundary.
    private func observePolicy(_ authority: NetworkRequestAuthority) {
        let id = UUID()
        networkObservationID = id
        policyObservation = authority.changes.sink { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, self.networkObservationID == id else { return }
#if DEBUG
                defer { self.onPolicyEvaluation?() }
#endif
                do {
                    try authority.checkLiveSurface()
                } catch let outcome as HostNetworkPolicyOutcome {
                    self.stopForRefusal(outcome)
                } catch {}
            }
        }
    }

    private func stopForRefusal(_ outcome: HostNetworkPolicyOutcome) {
        policyObservation = nil
        networkObservationID = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        networkRefusalHandler?(outcome)
    }

    func shutdown() {
        policyObservation = nil
        networkObservationID = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
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
protocol VideoPlayerProgressTracking: PluginCompletionScopeCapturing, AnyObject {
    func markEpisodeWatched(
        context: PluginCompletionContext,
        episodeID: String,
        episodeNumber: Float?
    ) async throws
    /// Seconds into `episodeID` where watching stopped, if it is the last episode watched.
    func savedPlaybackTime(media: MediaIdentity, episodeID: String) -> Double?
    func savePlaybackTime(_ seconds: Double, media: MediaIdentity, episodeID: String) async throws
}

extension ReadProgressManager: VideoPlayerProgressTracking {
    func markEpisodeWatched(
        context: PluginCompletionContext,
        episodeID: String,
        episodeNumber: Float?
    ) async throws {
        try await markAsWatched(
            context: context,
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
    func recordEpisode(of anime: Anime, episode: HistoryChapter, pluginID: String)
}

extension HistoryManager: VideoPlayerHistoryRecording {
    func recordEpisode(of anime: Anime, episode: HistoryChapter, pluginID: String) {
        recordAnime(anime, episode: episode, pluginId: pluginID)
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
    /// The authority for one playback operation of a source, or nil where no network policy exists (tests, previews).
    var playbackAuthority: @MainActor (String, PluginNetworkOperation) -> NetworkRequestAuthority? = { _, _ in nil }

    static func production(
        readProgressManager: ReadProgressManager,
        historyManager: HistoryManager,
        trackerManager: TrackerManager,
        discordRPCManager: DiscordRPCManager,
        pluginManager: PluginManager,
        presentationLogger: any PresentationEventLogging
    ) -> Self {
        let contexts = pluginManager.pluginSettingsStore.networkContexts
        let authorities = AppNetworkAuthorityProvider()
        authorities.set(contexts)
        return Self(
            progress: readProgressManager,
            history: historyManager,
            tracker: trackerManager,
            presence: discordRPCManager,
            pluginMetadata: pluginManager,
            subtitleLoader: URLSessionVideoSubtitleLoader(authorities: authorities),
            makePlaybackCoordinator: { AVPlayerVideoPlaybackCoordinator() },
            presentationLogger: presentationLogger,
            playbackAuthority: { pluginID, operation in
                NetworkRequestAuthority(contexts: contexts, context: contexts.context(pluginID: pluginID, operation))
            }
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
    func captureCompletionContext(
        media: MediaIdentity,
        mediaKey: String
    ) -> PluginCompletionContext {
        PluginCompletionContext(media: media, mediaKey: mediaKey, originatingEpoch: nil)
    }

    func markEpisodeWatched(
        context: PluginCompletionContext,
        episodeID: String,
        episodeNumber: Float?
    ) async throws {
        _ = context
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

    func recordEpisode(of anime: Anime, episode: HistoryChapter, pluginID: String) {
        _ = anime
        _ = episode
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

    func text(from urlString: String, authority: NetworkRequestAuthority?) async throws -> String {
        _ = urlString
        throw VideoSubtitleLoaderError.invalidURL
    }
}

@MainActor
private final class UnavailableVideoPlaybackCoordinator: VideoPlaybackCoordinating {
    var surface: (any VideoPlaybackSurface)? { nil }
    var networkRefusalHandler: (@MainActor (HostNetworkPolicyOutcome) -> Void)?

    func prepare(video: Anime.Video, authority: NetworkRequestAuthority?) async throws -> (any VideoPlaybackPreparation)? {
        _ = video
        _ = authority
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
