import Foundation
import Nuke
import ito_runner

@MainActor
protocol MangaPageLoading: AnyObject {
    func pages(for entry: MediaEntry, chapter: Chapter) async throws -> [Page]
}

@MainActor
final class ItoRunnerMangaPageLoader: MangaPageLoading {
    let runner: ItoRunner

    init(runner: ItoRunner) {
        self.runner = runner
    }

    func pages(for entry: MediaEntry, chapter: Chapter) async throws -> [Page] {
        try await pluginCall { try await runner.getChapterPages(entry: entry, chapter: chapter) }
    }
}

@MainActor
protocol MangaReaderProgressTracking: PluginCompletionScopeCapturing, AnyObject {
    func markChapterRead(
        context: PluginCompletionContext,
        chapterID: String,
        chapterNumber: Float?
    ) async throws
    /// The page the reader last stopped on in `chapterID`, if that is the last chapter read.
    func savedPage(media: MediaIdentity, chapterID: String) -> Int?
    func savePage(_ page: Int, media: MediaIdentity, chapterID: String) async throws
    /// The reading mode chosen for the series, if one was chosen.
    func savedViewer(media: MediaIdentity) -> Manga.Viewer?
    func saveViewer(_ viewer: Manga.Viewer, media: MediaIdentity, chapterID: String) async throws
}

extension ReadProgressManager: MangaReaderProgressTracking {
    func markChapterRead(
        context: PluginCompletionContext,
        chapterID: String,
        chapterNumber: Float?
    ) async throws {
        try await markAsRead(
            context: context,
            chapterId: chapterID,
            chapterNum: chapterNumber
        )
    }

    func savedPage(media: MediaIdentity, chapterID: String) -> Int? {
        savedPosition(media: media, chapterKey: chapterID).map { Int($0) }
    }

    func savePage(_ page: Int, media: MediaIdentity, chapterID: String) async throws {
        try await savePosition(media: media, chapterKey: chapterID, position: Double(page))
    }

    func savedViewer(media: MediaIdentity) -> Manga.Viewer? {
        savedReaderViewer(media: media).flatMap { Manga.Viewer(rawValue: Int32($0)) }
    }

    func saveViewer(_ viewer: Manga.Viewer, media: MediaIdentity, chapterID: String) async throws {
        // `Default` means no choice: store nothing so the series' own mode applies.
        try await saveReaderViewer(
            viewer == .Default ? nil : Int(viewer.rawValue),
            media: media,
            chapterKey: chapterID
        )
    }
}

@MainActor
protocol MangaReaderHistoryRecording: AnyObject {
    func recordChapter(
        of entry: MediaEntry,
        chapterKey: String,
        chapterTitle: String,
        pluginID: String
    )
}

@MainActor
protocol MangaReaderTrackerUpdating: AnyObject {
    func anilistID(for media: MediaIdentity) -> String?
    func updateMangaProgress(media: MediaIdentity, progress: Int) async
}

extension TrackerManager: MangaReaderTrackerUpdating {
    func anilistID(for media: MediaIdentity) -> String? {
        trackerId(for: media, providerId: "anilist")
    }

    func updateMangaProgress(media: MediaIdentity, progress: Int) async {
        await updateProgress(media: media, progress: progress)
    }
}

@MainActor
protocol MangaReaderSettingsAccessing: AnyObject {
    var mangaReaderPreloadImageCount: Int { get }
    func setMangaReaderPreloadImageCount(_ value: Int) async throws
}

extension AppSettingsStore: MangaReaderSettingsAccessing {
    var mangaReaderPreloadImageCount: Int {
        preloadImageCount.rawValue
    }

    func setMangaReaderPreloadImageCount(_ value: Int) async throws {
        guard let preference = ImagePreloadCountPreference(rawValue: value) else { return }
        try await set(preference, for: AppPreferenceCatalog.preloadImageCount)
    }
}

nonisolated struct MangaReaderPresence: Equatable, Sendable {
    let details: String
    let state: String
    let activityType: Int
    let detailsURL: String?
    let largeImageText: String
    let imageURL: String?
    let resetTimer: Bool
}

@MainActor
protocol MangaReaderPresencePresenting: AnyObject {
    func presentMangaReaderPresence(_ presence: MangaReaderPresence)
    func clearMangaReaderPresence()
}

extension DiscordRPCManager: MangaReaderPresencePresenting {
    func presentMangaReaderPresence(_ presence: MangaReaderPresence) {
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

    func clearMangaReaderPresence() {
        clearActivity()
    }
}

@MainActor
protocol MangaReaderPluginMetadataProviding: AnyObject {
    func displayName(for pluginID: String) -> String?
}

extension PluginManager: MangaReaderPluginMetadataProviding {}

@MainActor
protocol MangaReaderImagePrefetching: AnyObject {
    func prefetch(_ pages: [Page])
    func stopPrefetching()
}

@MainActor
final class NukeMangaReaderImagePrefetcher: MangaReaderImagePrefetching {
    private let prefetcher: ImagePrefetcher

    init(pipeline: ImagePipeline = .shared) {
        prefetcher = ImagePrefetcher(
            pipeline: pipeline,
            destination: .diskCache,
            maxConcurrentRequestCount: 2
        )
    }

    func prefetch(_ pages: [Page]) {
        let requests = pages.compactMap(Self.request(for:))
        guard !requests.isEmpty else { return }
        prefetcher.startPrefetching(with: requests)
    }

    func stopPrefetching() {
        prefetcher.stopPrefetching()
    }

    static func request(for page: Page) -> ImageRequest? {
        guard case .url(let urlString) = page.content,
              let url = URL(string: urlString) else {
            return nil
        }
        return ImageRequest(urlRequest: urlRequest(url: url, headers: page.headers))
    }

    /// The request for a page image: the plugin's headers as given. No Referer is guessed (the
    /// image's own URL isn't what a site checks for; a plugin whose site needs one sends it), and
    /// the image session's User-Agent, the one Cloudflare clearances are made with, applies
    /// unless the plugin sets its own.
    nonisolated static func urlRequest(url: URL, headers: [String: String]?) -> URLRequest {
        var request = URLRequest(url: url)
        for (key, value) in headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }
}

@MainActor
struct PreparedMangaReaderDependencies {
    let progress: any MangaReaderProgressTracking
    let history: any MangaReaderHistoryRecording
    let tracker: any MangaReaderTrackerUpdating
    let settings: any MangaReaderSettingsAccessing
    let presence: any MangaReaderPresencePresenting
    let pluginMetadata: any MangaReaderPluginMetadataProviding
    let makeImagePrefetcher: () -> any MangaReaderImagePrefetching
    let presentationLogger: any PresentationEventLogging

    static func production(
        readProgressManager: ReadProgressManager,
        historyManager: HistoryManager,
        trackerManager: TrackerManager,
        settingsStore: AppSettingsStore,
        discordRPCManager: DiscordRPCManager,
        pluginManager: PluginManager,
        presentationLogger: any PresentationEventLogging
    ) -> Self {
        Self(
            progress: readProgressManager,
            history: historyManager,
            tracker: trackerManager,
            settings: settingsStore,
            presence: discordRPCManager,
            pluginMetadata: pluginManager,
            makeImagePrefetcher: { NukeMangaReaderImagePrefetcher() },
            presentationLogger: presentationLogger
        )
    }

    static func unavailable() -> Self {
        let unavailable = UnavailableMangaReaderDependencies()
        return Self(
            progress: unavailable,
            history: unavailable,
            tracker: unavailable,
            settings: unavailable,
            presence: unavailable,
            pluginMetadata: unavailable,
            makeImagePrefetcher: { unavailable },
            presentationLogger: OSLogPresentationEventLogger()
        )
    }
}

@MainActor
private final class UnavailableMangaReaderDependencies:
    MangaReaderProgressTracking,
    MangaReaderHistoryRecording,
    MangaReaderTrackerUpdating,
    MangaReaderSettingsAccessing,
    MangaReaderPresencePresenting,
    MangaReaderPluginMetadataProviding,
    MangaReaderImagePrefetching {
    var mangaReaderPreloadImageCount: Int {
        AppPreferenceCatalog.preloadImageCount.defaultValue.rawValue
    }

    func captureCompletionContext(
        media: MediaIdentity,
        mediaKey: String,
        kind: PluginCompletionKind
    ) -> PluginCompletionContext {
        PluginCompletionContext(media: media, mediaKey: mediaKey, kind: kind, originatingEpoch: nil)
    }

    func markChapterRead(
        context: PluginCompletionContext,
        chapterID: String,
        chapterNumber: Float?
    ) async throws {
        _ = context
        _ = chapterID
        _ = chapterNumber
    }

    func savedPage(media: MediaIdentity, chapterID: String) -> Int? {
        _ = media
        _ = chapterID
        return nil
    }

    func savePage(_ page: Int, media: MediaIdentity, chapterID: String) async throws {
        _ = page
        _ = media
        _ = chapterID
    }

    func savedViewer(media: MediaIdentity) -> Manga.Viewer? {
        _ = media
        return nil
    }

    func saveViewer(_ viewer: Manga.Viewer, media: MediaIdentity, chapterID: String) async throws {
        _ = viewer
        _ = media
        _ = chapterID
    }

    func recordChapter(
        of entry: MediaEntry,
        chapterKey: String,
        chapterTitle: String,
        pluginID: String
    ) {
        _ = entry
        _ = chapterKey
        _ = chapterTitle
        _ = pluginID
    }

    func anilistID(for media: MediaIdentity) -> String? {
        _ = media
        return nil
    }

    func updateMangaProgress(media: MediaIdentity, progress: Int) async {
        _ = media
        _ = progress
    }

    func setMangaReaderPreloadImageCount(_ value: Int) async throws {
        _ = value
    }

    func presentMangaReaderPresence(_ presence: MangaReaderPresence) {
        _ = presence
    }

    func clearMangaReaderPresence() {}

    func displayName(for pluginID: String) -> String? {
        _ = pluginID
        return nil
    }

    func prefetch(_ pages: [Page]) {
        _ = pages
    }

    func stopPrefetching() {}
}
