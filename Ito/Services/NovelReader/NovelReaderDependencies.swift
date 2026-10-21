import Combine
import Foundation
import ito_runner

@MainActor
protocol NovelChapterLoading: AnyObject {
    func content(for novel: Novel, chapter: Novel.Chapter) async throws -> [Page]
}

@MainActor
final class ItoRunnerNovelChapterLoader: NovelChapterLoading {
    let runner: ItoRunner

    init(runner: ItoRunner) {
        self.runner = runner
    }

    func content(for novel: Novel, chapter: Novel.Chapter) async throws -> [Page] {
        try await pluginCall { try await runner.getChapterContent(novel: novel, chapter: chapter) }
    }
}

@MainActor
protocol NovelReaderProgressTracking: AnyObject {
    func markNovelChapterRead(
        media: MediaIdentity,
        chapterID: String,
        chapterNumber: Float?
    ) async throws
    /// Where the reader last stopped in `chapterID` (see `NovelTextOffsets`), if that is the
    /// last chapter read.
    func savedNovelOffset(media: MediaIdentity, chapterID: String) -> Int?
    func saveNovelOffset(_ offset: Int, media: MediaIdentity, chapterID: String) async throws
}

extension ReadProgressManager: NovelReaderProgressTracking {
    func markNovelChapterRead(
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

    func savedNovelOffset(media: MediaIdentity, chapterID: String) -> Int? {
        savedPosition(media: media, chapterKey: chapterID).map { Int($0) }
    }

    func saveNovelOffset(_ offset: Int, media: MediaIdentity, chapterID: String) async throws {
        try await savePosition(media: media, chapterKey: chapterID, position: Double(offset))
    }
}

@MainActor
protocol NovelReaderHistoryRecording: AnyObject {
    func recordNovel(
        _ novel: Novel,
        chapterKey: String,
        chapterTitle: String,
        pluginID: String
    )
}

extension HistoryManager: NovelReaderHistoryRecording {
    func recordNovel(
        _ novel: Novel,
        chapterKey: String,
        chapterTitle: String,
        pluginID: String
    ) {
        addNovel(
            novel,
            chapterKey: chapterKey,
            chapterTitle: chapterTitle,
            pluginId: pluginID
        )
    }
}

@MainActor
protocol NovelReaderTrackerUpdating: AnyObject {
    func novelReaderAnilistID(for media: MediaIdentity) -> String?
    func updateNovelProgress(media: MediaIdentity, progress: Int) async
}

extension TrackerManager: NovelReaderTrackerUpdating {
    func novelReaderAnilistID(for media: MediaIdentity) -> String? {
        trackerId(for: media, providerId: "anilist")
    }

    func updateNovelProgress(media: MediaIdentity, progress: Int) async {
        await updateProgress(media: media, progress: progress)
    }
}

struct NovelReaderSettingsSnapshot: Equatable {
    let fontSize: Double
    let lineSpacing: Double
    let fontFamily: NovelFontPreference
    let theme: NovelThemePreference
    let isPaging: Bool
    let prefetchChapters: Bool
}

@MainActor
protocol NovelReaderSettingsAccessing: AnyObject {
    var novelReaderSettings: NovelReaderSettingsSnapshot { get }
    var novelReaderSettingsUpdates: AnyPublisher<NovelReaderSettingsSnapshot, Never> { get }

    func setNovelFontSize(_ value: Double) async throws
    func setNovelLineSpacing(_ value: Double) async throws
    func setNovelFontFamily(_ value: NovelFontPreference) async throws
    func setNovelTheme(_ value: NovelThemePreference) async throws
    func setNovelIsPaging(_ value: Bool) async throws
    func setNovelPrefetchChapters(_ value: Bool) async throws
}

extension AppSettingsStore: NovelReaderSettingsAccessing {
    var novelReaderSettings: NovelReaderSettingsSnapshot {
        NovelReaderSettingsSnapshot(
            fontSize: novelFontSize,
            lineSpacing: novelLineSpacing,
            fontFamily: novelFontFamily,
            theme: novelTheme,
            isPaging: novelIsPaging,
            prefetchChapters: novelPrefetchChapters
        )
    }

    var novelReaderSettingsUpdates: AnyPublisher<NovelReaderSettingsSnapshot, Never> {
        Publishers.CombineLatest3(
            Publishers.CombineLatest($novelFontSize, $novelLineSpacing),
            Publishers.CombineLatest($novelFontFamily, $novelTheme),
            Publishers.CombineLatest($novelIsPaging, $novelPrefetchChapters)
        )
        .map { typography, appearance, reading in
            NovelReaderSettingsSnapshot(
                fontSize: typography.0,
                lineSpacing: typography.1,
                fontFamily: appearance.0,
                theme: appearance.1,
                isPaging: reading.0,
                prefetchChapters: reading.1
            )
        }
        .eraseToAnyPublisher()
    }

    func setNovelFontSize(_ value: Double) async throws {
        try await set(value, for: AppPreferenceCatalog.novelFontSize)
    }

    func setNovelLineSpacing(_ value: Double) async throws {
        try await set(value, for: AppPreferenceCatalog.novelLineSpacing)
    }

    func setNovelFontFamily(_ value: NovelFontPreference) async throws {
        try await set(value, for: AppPreferenceCatalog.novelFontFamily)
    }

    func setNovelTheme(_ value: NovelThemePreference) async throws {
        try await set(value, for: AppPreferenceCatalog.novelTheme)
    }

    func setNovelIsPaging(_ value: Bool) async throws {
        try await set(value, for: AppPreferenceCatalog.novelIsPaging)
    }

    func setNovelPrefetchChapters(_ value: Bool) async throws {
        try await set(value, for: AppPreferenceCatalog.novelPrefetchChapters)
    }
}

nonisolated struct NovelReaderPresence: Equatable, Sendable {
    let details: String
    let state: String
    let activityType: Int
    let detailsURL: String?
    let largeImageText: String
    let imageURL: String?
    let resetTimer: Bool
}

@MainActor
protocol NovelReaderPresencePresenting: AnyObject {
    func presentNovelReaderPresence(_ presence: NovelReaderPresence)
    func clearNovelReaderPresence()
}

extension DiscordRPCManager: NovelReaderPresencePresenting {
    func presentNovelReaderPresence(_ presence: NovelReaderPresence) {
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

    func clearNovelReaderPresence() {
        clearActivity()
    }
}

@MainActor
protocol NovelReaderPluginMetadataProviding: AnyObject {
    func novelReaderPluginDisplayName(for pluginID: String) -> String?
}

extension PluginManager: NovelReaderPluginMetadataProviding {
    func novelReaderPluginDisplayName(for pluginID: String) -> String? {
        installedPlugins[pluginID]?.info.name
    }
}

@MainActor
struct PreparedNovelReaderDependencies {
    let progress: any NovelReaderProgressTracking
    let history: any NovelReaderHistoryRecording
    let tracker: any NovelReaderTrackerUpdating
    let settings: any NovelReaderSettingsAccessing
    let presence: any NovelReaderPresencePresenting
    let pluginMetadata: any NovelReaderPluginMetadataProviding
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
            presentationLogger: presentationLogger
        )
    }

    static func unavailable() -> Self {
        let unavailable = UnavailableNovelReaderDependencies()
        return Self(
            progress: unavailable,
            history: unavailable,
            tracker: unavailable,
            settings: unavailable,
            presence: unavailable,
            pluginMetadata: unavailable,
            presentationLogger: OSLogPresentationEventLogger()
        )
    }
}

@MainActor
private final class UnavailableNovelReaderDependencies:
    NovelReaderProgressTracking,
    NovelReaderHistoryRecording,
    NovelReaderTrackerUpdating,
    NovelReaderSettingsAccessing,
    NovelReaderPresencePresenting,
    NovelReaderPluginMetadataProviding {
    private let settings = NovelReaderSettingsSnapshot(
        fontSize: AppPreferenceCatalog.novelFontSize.defaultValue,
        lineSpacing: AppPreferenceCatalog.novelLineSpacing.defaultValue,
        fontFamily: AppPreferenceCatalog.novelFontFamily.defaultValue,
        theme: AppPreferenceCatalog.novelTheme.defaultValue,
        isPaging: AppPreferenceCatalog.novelIsPaging.defaultValue,
        prefetchChapters: AppPreferenceCatalog.novelPrefetchChapters.defaultValue
    )

    var novelReaderSettings: NovelReaderSettingsSnapshot { settings }

    var novelReaderSettingsUpdates: AnyPublisher<NovelReaderSettingsSnapshot, Never> {
        Just(settings).eraseToAnyPublisher()
    }

    func markNovelChapterRead(
        media: MediaIdentity,
        chapterID: String,
        chapterNumber: Float?
    ) async throws {
        _ = media
        _ = chapterID
        _ = chapterNumber
    }

    func savedNovelOffset(media: MediaIdentity, chapterID: String) -> Int? {
        _ = media
        _ = chapterID
        return nil
    }

    func saveNovelOffset(_ offset: Int, media: MediaIdentity, chapterID: String) async throws {
        _ = offset
        _ = media
        _ = chapterID
    }

    func recordNovel(
        _ novel: Novel,
        chapterKey: String,
        chapterTitle: String,
        pluginID: String
    ) {
        _ = novel
        _ = chapterKey
        _ = chapterTitle
        _ = pluginID
    }

    func novelReaderAnilistID(for media: MediaIdentity) -> String? {
        _ = media
        return nil
    }

    func updateNovelProgress(media: MediaIdentity, progress: Int) async {
        _ = media
        _ = progress
    }

    func setNovelFontSize(_ value: Double) async throws { _ = value }
    func setNovelLineSpacing(_ value: Double) async throws { _ = value }
    func setNovelFontFamily(_ value: NovelFontPreference) async throws { _ = value }
    func setNovelTheme(_ value: NovelThemePreference) async throws { _ = value }
    func setNovelIsPaging(_ value: Bool) async throws { _ = value }
    func setNovelPrefetchChapters(_ value: Bool) async throws { _ = value }

    func presentNovelReaderPresence(_ presence: NovelReaderPresence) {
        _ = presence
    }

    func clearNovelReaderPresence() {}

    func novelReaderPluginDisplayName(for pluginID: String) -> String? {
        _ = pluginID
        return nil
    }
}
