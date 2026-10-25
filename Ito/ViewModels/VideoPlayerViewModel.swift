import Combine
import Foundation
import ito_runner

enum VideoPlayerLoadPhase: Equatable {
    case idle
    case loading
    case content
    case failure(String)
}

@MainActor
final class VideoPlayerViewModel: ObservableObject {
    @Published private(set) var loadPhase: VideoPlayerLoadPhase = .idle
    @Published private(set) var videos: [Anime.Video] = []
    @Published private(set) var selectedVideo: Anime.Video?
    @Published private(set) var selectedAudioTrack: Anime.AudioTrack?
    @Published private(set) var selectedSubtitle: Anime.Subtitle?
    @Published private(set) var parsedSubtitles: [VTTCue] = []
    @Published private(set) var currentSubtitleText: String?
    @Published private(set) var playbackSurface: (any VideoPlaybackSurface)?
    @Published private(set) var hasTrackedProgress = false
    /// A saved time in seconds to offer when the episode opens; the view asks whether to
    /// continue from it or start over, and nothing plays until it is answered.
    @Published private(set) var resumeOffer: Double?

    let streamLoader: any VideoStreamLoading
    let pluginID: String
    let anime: Anime
    let episode: Anime.Episode
    let playbackCoordinator: any VideoPlaybackCoordinating

    private let dependencies: PreparedVideoPlayerDependencies
    private let mediaIdentity: MediaIdentity
    /// Captured once per player session; every episode in the session shares it.
    private let completionContext: PluginCompletionContext

    private var isActive = true
    private var hasPresentedPresence = false
    private var sessionID = UUID()
    private var preparationGeneration: UInt64 = 0
    private var activePlaybackGeneration: UInt64 = 0

    private var streamLoadTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var subtitleTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    private var streamLoadOperationID: UUID?
    private var preparationOperationID: UUID?
    private var subtitleOperationID: UUID?
    private var progressOperationID: UUID?
    private var activeSubtitleToken: VideoSubtitleToken?
    private var finalizedLogOperations = Set<UUID>()
    private var deferredActivation: (
        preparation: any VideoPlaybackPreparation,
        session: UUID,
        generation: UInt64
    )?
    private var lastKnownTime: Double?
    private var lastSavedTime: Double?
    /// Time writes run one after another so an older write cannot land after a newer one.
    private var timeWriteTask: Task<Void, Never>?

    /// Saved times shorter than this start from the beginning without asking.
    static let minimumResumeTime: Double = 5
    /// How much playback passes between saves of the current time.
    static let timeSaveInterval: Double = 5

#if DEBUG
    private var testingOperationTasks: [UUID: Task<Void, Never>] = [:]
#endif

    init(
        streamLoader: any VideoStreamLoading,
        pluginID: String,
        anime: Anime,
        episode: Anime.Episode,
        dependencies: PreparedVideoPlayerDependencies
    ) {
        self.streamLoader = streamLoader
        self.pluginID = pluginID
        self.anime = anime
        self.episode = episode
        self.dependencies = dependencies
        mediaIdentity = MediaIdentity(pluginId: pluginID, canonicalMediaId: anime.key, mediaKind: .anime)
        completionContext = dependencies.progress.captureCompletionContext(
            media: mediaIdentity,
            mediaKey: anime.key
        )
        playbackCoordinator = dependencies.makePlaybackCoordinator()
    }

    // MARK: - Presentation lifecycle

    func start() {
        guard isActive else { return }
        switch loadPhase {
        case .content, .failure:
            return
        case .loading:
            if streamLoadOperationID != nil || preparationOperationID != nil { return }
        case .idle:
            break
        }
        beginStreamLoad()
    }

    func appear() {
        let shouldRestartLoad = !isActive && loadPhase == .loading
        if !isActive {
            isActive = true
            sessionID = UUID()
        }
        hasPresentedPresence = true
        presentPresence(resetTimer: true)
        if shouldRestartLoad {
            beginStreamLoad()
        }
    }

    func episodeDidChange() {
        guard isActive, hasPresentedPresence else { return }
        presentPresence(resetTimer: false)
    }

    func close() {
        playbackCoordinator.pause()
    }

    func disappear() {
        guard isActive else { return }
        // Keep where watching stopped, unless the episode was already counted as watched.
        if !hasTrackedProgress, let lastKnownTime {
            saveTime(lastKnownTime)
        }
        isActive = false
        hasPresentedPresence = false
        sessionID = UUID()
        resumeOffer = nil
        deferredActivation = nil
        cancelStreamLoad(outcome: .cancelled)
        cancelPreparation(outcome: .cancelled)
        cancelSubtitleLoad(outcome: .cancelled)
        cancelProgress(outcome: .cancelled)
        playbackCoordinator.shutdown()
        dependencies.presence.clearVideoPlayerPresence()
    }

    /// Answers `resumeOffer`: continue from the saved time, or start from the beginning.
    func resolveResumeOffer(continueWatching: Bool) {
        guard isActive,
              let offer = resumeOffer,
              let deferred = deferredActivation,
              deferred.session == sessionID,
              deferred.generation == preparationGeneration else { return }
        resumeOffer = nil
        deferredActivation = nil
        if !continueWatching {
            // Saved now, so closing before the next periodic save does not ask again.
            lastKnownTime = 0
            saveTime(0)
        }
        _ = activate(
            deferred.preparation,
            startTime: continueWatching ? offer : nil,
            session: deferred.session,
            generation: deferred.generation
        )
    }

    // MARK: - Selection intents

    func selectVideo(_ video: Anime.Video) {
        guard isActive else { return }
        selectedVideo = video
        beginPreparation(for: video, completesInitialLoad: false)
    }

    func selectAudioTrack(_ track: Anime.AudioTrack) {
        guard isActive else { return }
        selectedAudioTrack = track
    }

    func selectSubtitle(_ subtitle: Anime.Subtitle?) {
        guard isActive else { return }
        selectedSubtitle = subtitle
        guard let subtitle else {
            cancelSubtitleLoad(outcome: .cancelled)
            parsedSubtitles = []
            currentSubtitleText = nil
            return
        }
        beginSubtitleLoad(subtitle)
    }

    // MARK: - Stream loading and preparation

    private func beginStreamLoad() {
        guard isActive, streamLoadOperationID == nil else { return }

        dependencies.history.recordAnime(
            anime,
            episodeKey: episode.key,
            episodeTitle: episode.title ?? episode.key,
            pluginID: pluginID
        )

        let operationID = UUID()
        let session = sessionID
        let loader = streamLoader
        let anime = anime
        let episode = episode
        streamLoadOperationID = operationID
        loadPhase = .loading
        logStarted(kind: .streamLoad, operationID: operationID)

        let task = Task { @MainActor [weak self, loader, anime, episode] in
            defer { self?.finishTestingOperation(operationID) }
            do {
                let videos = try await loader.videos(for: anime, episode: episode)
                self?.completeStreamLoad(
                    videos,
                    operationID: operationID,
                    session: session
                )
            } catch {
                self?.failStreamLoad(
                    error,
                    operationID: operationID,
                    session: session
                )
            }
        }
        streamLoadTask = task
        retainTestingOperation(task, operationID: operationID)
    }

    private func completeStreamLoad(
        _ fetchedVideos: [Anime.Video],
        operationID: UUID,
        session: UUID
    ) {
        guard isCurrentStreamLoad(operationID: operationID, session: session) else {
            logFinishedOnce(
                kind: .streamLoad,
                operationID: operationID,
                outcome: .ignoredStale
            )
            return
        }

        streamLoadTask = nil
        streamLoadOperationID = nil
        videos = fetchedVideos
        logFinishedOnce(kind: .streamLoad, operationID: operationID, outcome: .succeeded)

        guard let first = fetchedVideos.first else {
            loadPhase = .content
            return
        }

        selectedVideo = first
        selectedAudioTrack = first.audioTracks?.first
        selectedSubtitle = first.subtitles?.first(where: { !$0.isHardsub })
            ?? first.subtitles?.first
        beginPreparation(for: first, completesInitialLoad: true)
    }

    private func failStreamLoad(
        _ error: any Error,
        operationID: UUID,
        session: UUID
    ) {
        guard isCurrentStreamLoad(operationID: operationID, session: session) else {
            logFinishedOnce(
                kind: .streamLoad,
                operationID: operationID,
                outcome: .ignoredStale
            )
            return
        }

        streamLoadTask = nil
        streamLoadOperationID = nil
        loadPhase = .failure(error.localizedDescription)
        let outcome: PresentationEventOutcome = error is CancellationError
            ? .cancelled
            : .failed(.pluginExecution)
        logFinishedOnce(kind: .streamLoad, operationID: operationID, outcome: outcome)
    }

    private func isCurrentStreamLoad(operationID: UUID, session: UUID) -> Bool {
        isActive
            && sessionID == session
            && streamLoadOperationID == operationID
            && !Task.isCancelled
    }

    private func beginPreparation(
        for video: Anime.Video,
        completesInitialLoad: Bool
    ) {
        guard isActive else { return }
        cancelPreparation(outcome: .cancelled)
        resumeOffer = nil
        deferredActivation = nil
        preparationGeneration &+= 1
        let generation = preparationGeneration
        let operationID = UUID()
        let session = sessionID
        let coordinator = playbackCoordinator
        preparationOperationID = operationID
        logStarted(kind: .playerPreparation, operationID: operationID)

        let task = Task { @MainActor [weak self, coordinator] in
            defer { self?.finishTestingOperation(operationID) }
            let preparation = await coordinator.prepare(video: video)
            self?.completePreparation(
                preparation,
                operationID: operationID,
                session: session,
                generation: generation,
                completesInitialLoad: completesInitialLoad
            )
        }
        preparationTask = task
        retainTestingOperation(task, operationID: operationID)
    }

    private func completePreparation(
        _ preparation: (any VideoPlaybackPreparation)?,
        operationID: UUID,
        session: UUID,
        generation: UInt64,
        completesInitialLoad: Bool
    ) {
        guard isCurrentPreparation(
            operationID: operationID,
            session: session,
            generation: generation
        ) else {
            logFinishedOnce(
                kind: .playerPreparation,
                operationID: operationID,
                outcome: .ignoredStale
            )
            return
        }

        preparationTask = nil
        preparationOperationID = nil
        let activated: Bool
        if let preparation {
            if completesInitialLoad, let saved = savedResumeTime() {
                // Ask first; `resolveResumeOffer` activates with the answer.
                deferredActivation = (preparation, session, generation)
                resumeOffer = saved
                activated = true
            } else {
                // A new quality or source carries on from the current time.
                activated = activate(
                    preparation,
                    startTime: completesInitialLoad ? nil : lastKnownTime,
                    session: session,
                    generation: generation
                )
            }
        } else {
            activated = false
        }

        if completesInitialLoad {
            loadPhase = .content
        }
        logFinishedOnce(
            kind: .playerPreparation,
            operationID: operationID,
            outcome: activated ? .succeeded : .failed(.unknown)
        )
    }

    private func activate(
        _ preparation: any VideoPlaybackPreparation,
        startTime: Double?,
        session: UUID,
        generation: UInt64
    ) -> Bool {
        let activated = playbackCoordinator.activate(
            preparation,
            startTime: startTime
        ) { [weak self] time, duration in
            self?.playbackTimeDidChange(
                currentTime: time,
                duration: duration,
                session: session,
                preparationGeneration: generation
            )
        }
        if activated {
            activePlaybackGeneration = generation
            playbackSurface = playbackCoordinator.surface
            if let selectedSubtitle {
                beginSubtitleLoad(selectedSubtitle)
            }
        }
        return activated
    }

    private func savedResumeTime() -> Double? {
        guard let saved = dependencies.progress.savedPlaybackTime(
            media: mediaIdentity,
            episodeID: episode.key
        ), saved.isFinite, saved >= Self.minimumResumeTime else { return nil }
        return saved
    }

    private func saveTime(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0, seconds != lastSavedTime else { return }
        lastSavedTime = seconds
        let operationID = UUID()
        let progress = dependencies.progress
        let identity = mediaIdentity
        let episodeKey = episode.key
        let preceding = timeWriteTask
        let task = Task { @MainActor [weak self, progress] in
            defer { self?.finishTestingOperation(operationID) }
            await preceding?.value
            // Saving the time is best effort; playback carries on if it fails.
            try? await progress.savePlaybackTime(seconds, media: identity, episodeID: episodeKey)
        }
        timeWriteTask = task
        retainTestingOperation(task, operationID: operationID)
    }

    private func isCurrentPreparation(
        operationID: UUID,
        session: UUID,
        generation: UInt64
    ) -> Bool {
        isActive
            && sessionID == session
            && preparationGeneration == generation
            && preparationOperationID == operationID
            && !Task.isCancelled
    }

    // MARK: - Subtitle loading and playback-time effects

    private func beginSubtitleLoad(_ subtitle: Anime.Subtitle) {
        guard isActive else { return }
        let token = VideoSubtitleToken(subtitle)
        if subtitleOperationID != nil, activeSubtitleToken == token { return }

        cancelSubtitleLoad(outcome: .cancelled)
        let operationID = UUID()
        let session = sessionID
        let loader = dependencies.subtitleLoader
        activeSubtitleToken = token
        subtitleOperationID = operationID
        logStarted(kind: .subtitleLoad, operationID: operationID)

        let task = Task { @MainActor [weak self, loader] in
            defer { self?.finishTestingOperation(operationID) }
            do {
                let text = try await loader.text(from: subtitle.url)
                self?.completeSubtitleLoad(
                    VTTParser.parse(text),
                    token: token,
                    operationID: operationID,
                    session: session
                )
            } catch {
                self?.failSubtitleLoad(
                    error,
                    token: token,
                    operationID: operationID,
                    session: session
                )
            }
        }
        subtitleTask = task
        retainTestingOperation(task, operationID: operationID)
    }

    private func completeSubtitleLoad(
        _ cues: [VTTCue],
        token: VideoSubtitleToken,
        operationID: UUID,
        session: UUID
    ) {
        guard isCurrentSubtitleLoad(
            token: token,
            operationID: operationID,
            session: session
        ) else {
            logFinishedOnce(
                kind: .subtitleLoad,
                operationID: operationID,
                outcome: .ignoredStale
            )
            return
        }
        subtitleTask = nil
        subtitleOperationID = nil
        activeSubtitleToken = nil
        parsedSubtitles = cues
        logFinishedOnce(kind: .subtitleLoad, operationID: operationID, outcome: .succeeded)
    }

    private func failSubtitleLoad(
        _ error: any Error,
        token: VideoSubtitleToken,
        operationID: UUID,
        session: UUID
    ) {
        guard isCurrentSubtitleLoad(
            token: token,
            operationID: operationID,
            session: session
        ) else {
            logFinishedOnce(
                kind: .subtitleLoad,
                operationID: operationID,
                outcome: .ignoredStale
            )
            return
        }
        subtitleTask = nil
        subtitleOperationID = nil
        activeSubtitleToken = nil
        let outcome: PresentationEventOutcome = error is CancellationError
            ? .cancelled
            : .failed(.network)
        logFinishedOnce(kind: .subtitleLoad, operationID: operationID, outcome: outcome)
    }

    private func isCurrentSubtitleLoad(
        token: VideoSubtitleToken,
        operationID: UUID,
        session: UUID
    ) -> Bool {
        isActive
            && sessionID == session
            && subtitleOperationID == operationID
            && activeSubtitleToken == token
            && selectedSubtitle.map(VideoSubtitleToken.init) == token
            && !Task.isCancelled
    }

    func playbackTimeDidChange(currentTime: Double, duration: Double) {
        playbackTimeDidChange(
            currentTime: currentTime,
            duration: duration,
            session: sessionID,
            preparationGeneration: activePlaybackGeneration
        )
    }

    private func playbackTimeDidChange(
        currentTime: Double,
        duration: Double,
        session: UUID,
        preparationGeneration: UInt64
    ) {
        guard isActive,
              sessionID == session,
              activePlaybackGeneration == preparationGeneration else { return }

        if currentTime.isFinite, currentTime >= 0 {
            lastKnownTime = currentTime
        }
        if !hasTrackedProgress,
           currentTime.isFinite,
           duration.isFinite,
           duration > 0,
           currentTime / duration >= 0.8 {
            hasTrackedProgress = true
            beginProgressEffects()
            // Watched: reopening the episode starts over, and Resume moves to the next one.
            saveTime(0)
        } else if !hasTrackedProgress, currentTime.isFinite, currentTime >= 0,
                  abs(currentTime - (lastSavedTime ?? 0)) >= Self.timeSaveInterval {
            saveTime(currentTime)
        }

        let activeCue = parsedSubtitles.first {
            currentTime >= $0.start && currentTime <= $0.end
        }
        let nextText = activeCue?.text
        if currentSubtitleText != nextText {
            currentSubtitleText = nextText
        }
    }

    // MARK: - Watched progress

    private func beginProgressEffects() {
        guard isActive, progressOperationID == nil else { return }
        let operationID = UUID()
        let session = sessionID
        let progress = dependencies.progress
        let tracker = dependencies.tracker
        let mediaIdentity = mediaIdentity
        let context = completionContext
        let episode = episode
        let trackerProgress = Self.trackerProgress(for: episode)
        progressOperationID = operationID
        logStarted(kind: .playbackProgress, operationID: operationID)

        let task = Task { @MainActor [weak self, progress, tracker] in
            defer { self?.finishTestingOperation(operationID) }
            do {
                try await progress.markEpisodeWatched(
                    context: context,
                    episodeID: episode.key,
                    episodeNumber: episode.episode
                )
                guard let self,
                      self.isCurrentProgress(operationID: operationID, session: session) else {
                    return
                }
                if let trackerProgress {
                    await tracker.updateVideoProgress(
                        media: mediaIdentity,
                        progress: trackerProgress
                    )
                }
                self.finishProgress(operationID: operationID, outcome: .succeeded)
            } catch {
                self?.finishProgress(
                    operationID: operationID,
                    outcome: .failed(.persistence)
                )
            }
        }
        progressTask = task
        retainTestingOperation(task, operationID: operationID)
    }

    private func isCurrentProgress(operationID: UUID, session: UUID) -> Bool {
        isActive
            && sessionID == session
            && progressOperationID == operationID
            && !Task.isCancelled
    }

    private func finishProgress(
        operationID: UUID,
        outcome: PresentationEventOutcome
    ) {
        guard progressOperationID == operationID else { return }
        progressTask = nil
        progressOperationID = nil
        logFinishedOnce(kind: .playbackProgress, operationID: operationID, outcome: outcome)
    }

    static func trackerProgress(for episode: Anime.Episode) -> Int? {
        if let episodeNumber = episode.episode {
            return Int(episodeNumber)
        }
        return TrackerProgressParser.number(inTitle: episode.title ?? episode.key)
    }

    // MARK: - Presence

    private func presentPresence(resetTimer: Bool) {
        guard isActive else { return }
        let anilistID = dependencies.tracker.videoPlayerAnilistID(for: mediaIdentity)
        let detailsURL = anilistID.map { "https://anilist.co/anime/\($0)" }
        let pluginName = dependencies.pluginMetadata
            .videoPlayerPluginDisplayName(for: pluginID) ?? "Unknown Plugin"
        let subgroup = episode.lang?.uppercased() ?? "Original"
        dependencies.presence.presentVideoPlayerPresence(
            VideoPlayerPresence(
                details: anime.title,
                state: "Watching \(episode.title ?? "Episode \(episode.chapterNumber ?? 0)")",
                activityType: 3,
                detailsURL: detailsURL,
                largeImageText: "Watching from \(subgroup) at \(pluginName)",
                imageURL: anime.cover,
                resetTimer: resetTimer
            )
        )
    }

    // MARK: - Cancellation and typed logging

    private func cancelStreamLoad(outcome: PresentationEventOutcome) {
        if let operationID = streamLoadOperationID {
            logFinishedOnce(kind: .streamLoad, operationID: operationID, outcome: outcome)
        }
        streamLoadTask?.cancel()
        streamLoadTask = nil
        streamLoadOperationID = nil
    }

    private func cancelPreparation(outcome: PresentationEventOutcome) {
        if let operationID = preparationOperationID {
            logFinishedOnce(
                kind: .playerPreparation,
                operationID: operationID,
                outcome: outcome
            )
        }
        preparationTask?.cancel()
        preparationTask = nil
        preparationOperationID = nil
    }

    private func cancelSubtitleLoad(outcome: PresentationEventOutcome) {
        if let operationID = subtitleOperationID {
            logFinishedOnce(kind: .subtitleLoad, operationID: operationID, outcome: outcome)
        }
        subtitleTask?.cancel()
        subtitleTask = nil
        subtitleOperationID = nil
        activeSubtitleToken = nil
    }

    private func cancelProgress(outcome: PresentationEventOutcome) {
        if let operationID = progressOperationID {
            logFinishedOnce(kind: .playbackProgress, operationID: operationID, outcome: outcome)
        }
        progressTask?.cancel()
        progressTask = nil
        progressOperationID = nil
    }

    private func logStarted(kind: PresentationEventKind, operationID: UUID) {
        dependencies.presentationLogger.log(
            .started(feature: .videoPlayer, kind: kind, operationID: operationID)
        )
    }

    private func logFinishedOnce(
        kind: PresentationEventKind,
        operationID: UUID,
        outcome: PresentationEventOutcome
    ) {
        guard finalizedLogOperations.insert(operationID).inserted else { return }
        dependencies.presentationLogger.log(
            .finished(
                feature: .videoPlayer,
                kind: kind,
                operationID: operationID,
                outcome: outcome
            )
        )
    }

    // Exact task joins keep async tests deterministic without timing heuristics.
#if DEBUG
    func waitForCurrentStreamLoadForTesting() async {
        await streamLoadTask?.value
    }

    func waitForCurrentPreparationForTesting() async {
        await preparationTask?.value
    }

    func waitForCurrentSubtitleLoadForTesting() async {
        await subtitleTask?.value
    }

    func waitForCurrentProgressForTesting() async {
        await progressTask?.value
    }

    func waitForAllOperationsForTesting() async {
        while !testingOperationTasks.isEmpty {
            let tasks = Array(testingOperationTasks.values)
            for task in tasks {
                await task.value
            }
        }
    }

    private func retainTestingOperation(
        _ task: Task<Void, Never>,
        operationID: UUID
    ) {
        testingOperationTasks[operationID] = task
    }

    private func finishTestingOperation(_ operationID: UUID) {
        testingOperationTasks[operationID] = nil
    }
#else
    private func retainTestingOperation(
        _: Task<Void, Never>,
        operationID _: UUID
    ) {}

    private func finishTestingOperation(_: UUID) {}
#endif
}

private struct VideoSubtitleToken: Equatable {
    let url: String
    let language: String
    let format: String
    let isHardsub: Bool

    init(_ subtitle: Anime.Subtitle) {
        url = subtitle.url
        language = subtitle.language
        format = subtitle.format
        isHardsub = subtitle.isHardsub
    }
}
