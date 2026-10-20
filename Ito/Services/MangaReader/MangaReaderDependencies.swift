import Foundation
import Nuke
import ito_runner

@MainActor
protocol MangaPageLoading: AnyObject {
    func pages(for manga: Manga, chapter: Manga.Chapter) async throws -> [Page]
}

@MainActor
final class ItoRunnerMangaPageLoader: MangaPageLoading {
    let runner: ItoRunner

    init(runner: ItoRunner) {
        self.runner = runner
    }

    func pages(for manga: Manga, chapter: Manga.Chapter) async throws -> [Page] {
        try await runner.getPageList(manga: manga, chapter: chapter)
    }
}

@MainActor
protocol MangaReaderProgressTracking: AnyObject {
    func markChapterRead(
        media: MediaIdentity,
        chapterID: String,
        chapterNumber: Float?
    ) async throws
    /// The page the reader last stopped on in `chapterID`, if that is the last chapter read.
    func savedPage(media: MediaIdentity, chapterID: String) -> Int?
    func savePage(_ page: Int, media: MediaIdentity, chapterID: String) async throws
}

extension ReadProgressManager: MangaReaderProgressTracking {
    func markChapterRead(
        media: MediaIdentity,
        chapterID: String,
        chapterNumber: Float?
    ) async throws {
        try await markAsRead(
            media: media,
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
}

@MainActor
protocol MangaReaderHistoryRecording: AnyObject {
    func recordManga(
        _ manga: Manga,
        chapterKey: String,
        chapterTitle: String,
        pluginID: String
    )
}

extension HistoryManager: MangaReaderHistoryRecording {
    func recordManga(
        _ manga: Manga,
        chapterKey: String,
        chapterTitle: String,
        pluginID: String
    ) {
        addManga(
            manga,
            chapterKey: chapterKey,
            chapterTitle: chapterTitle,
            pluginId: pluginID
        )
    }
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
        var request = URLRequest(url: url)
        if let headers = page.headers, !headers.isEmpty {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        } else {
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue(urlString, forHTTPHeaderField: "Referer")
        }
        return ImageRequest(urlRequest: request)
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

    func markChapterRead(
        media: MediaIdentity,
        chapterID: String,
        chapterNumber: Float?
    ) async throws {
        _ = media
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

    func recordManga(
        _ manga: Manga,
        chapterKey: String,
        chapterTitle: String,
        pluginID: String
    ) {
        _ = manga
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
