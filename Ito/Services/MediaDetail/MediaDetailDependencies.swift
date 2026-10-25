import Combine
import Foundation
import UIKit
import ito_runner

struct MediaDetailLibraryRecord: Equatable {
    let itemID: String
    let pluginID: String
    let mediaKind: MediaKind
}

struct MediaDetailLibraryState: Equatable {
    let records: [MediaDetailLibraryRecord]
    let hasCustomCategories: Bool

    /// Whether this media is saved. Stored ids are decoded to their media; the plugin's key is
    /// never treated as a stored id, even when it looks like one.
    func isSaved(media: MediaIdentity) -> Bool {
        records.contains {
            MediaIdentity(pluginId: $0.pluginID, itemId: $0.itemID, mediaKind: $0.mediaKind) == media
        }
    }
}

@MainActor
protocol MediaDetailLibraryServing: AnyObject {
    var state: MediaDetailLibraryState { get }
    var statePublisher: AnyPublisher<MediaDetailLibraryState, Never> { get }

    func saveManga(_ manga: Manga, pluginID: String) async throws -> String
    func saveAnime(_ anime: Anime, pluginID: String) async throws -> String
    func saveNovel(_ novel: Novel, pluginID: String) async throws -> String
    func unsave(media: MediaIdentity) async throws
    func refresh() async throws
}

extension LibraryManager: MediaDetailLibraryServing {
    var state: MediaDetailLibraryState {
        MediaDetailLibraryState(
            records: items.map {
                MediaDetailLibraryRecord(itemID: $0.id, pluginID: $0.pluginId, mediaKind: $0.effectiveType)
            },
            hasCustomCategories: categories.contains { !$0.isSystemCategory }
        )
    }

    var statePublisher: AnyPublisher<MediaDetailLibraryState, Never> {
        Publishers.CombineLatest($items, $categories)
            .map { items, categories in
                MediaDetailLibraryState(
                    records: items.map {
                        MediaDetailLibraryRecord(itemID: $0.id, pluginID: $0.pluginId, mediaKind: $0.effectiveType)
                    },
                    hasCustomCategories: categories.contains { !$0.isSystemCategory }
                )
            }
            .eraseToAnyPublisher()
    }

    func saveManga(_ manga: Manga, pluginID: String) async throws -> String {
        try await saveMangaDurably(manga: manga, pluginId: pluginID)
    }

    func saveAnime(_ anime: Anime, pluginID: String) async throws -> String {
        try await saveAnimeDurably(anime: anime, pluginId: pluginID)
    }

    func saveNovel(_ novel: Novel, pluginID: String) async throws -> String {
        try await saveNovelDurably(novel: novel, pluginId: pluginID)
    }

    func unsave(media: MediaIdentity) async throws {
        try await removeItemDurably(media: media)
    }

    func refresh() async throws {
        try await reload()
    }
}

@MainActor
protocol MediaDetailProgressServing: AnyObject {
    var progressPublisher: AnyPublisher<Void, Never> { get }

    func isRead(media: MediaIdentity, chapterID: String, chapterNumber: Float?) -> Bool
    func lastReadChapter(for media: MediaIdentity) -> String?
    func readChapterNumbers(for media: MediaIdentity) -> Set<Float>
    func markReadUpTo(
        media: MediaIdentity,
        maximumChapterNumber: Float,
        availableChapterNumbers: Set<Float>
    ) async throws
    func refresh() async throws
}

extension ReadProgressManager: MediaDetailProgressServing {
    var progressPublisher: AnyPublisher<Void, Never> {
        objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }

    func isRead(
        media: MediaIdentity,
        chapterID: String,
        chapterNumber: Float?
    ) -> Bool {
        isRead(media: media, chapterId: chapterID, chapterNum: chapterNumber)
    }

    func markReadUpTo(
        media: MediaIdentity,
        maximumChapterNumber: Float,
        availableChapterNumbers: Set<Float>
    ) async throws {
        try await markReadUpTo(
            media: media,
            maxChapterNum: maximumChapterNumber,
            availableChapterNumbers: availableChapterNumbers
        )
    }

    func refresh() async throws {
        try await reload()
    }
}

@MainActor
protocol MediaDetailThemeServing: DiscoverDetailThemeServing {}

extension ThemeManager: MediaDetailThemeServing {}

struct MediaDetailTrackerState: Equatable {
    let isAvailable: Bool
    let isTracked: Bool
    let anilistID: String?
}

@MainActor
protocol MediaDetailTrackerServing: AnyObject {
    var statePublisher: AnyPublisher<Void, Never> { get }
    /// - Parameter isAnime: Anime can be tracked only on trackers that list anime.
    func state(for media: MediaIdentity, isAnime: Bool) -> MediaDetailTrackerState
    func refresh() async throws
}

@MainActor
final class TrackingMediaDetailAdapter: MediaDetailTrackerServing {
    private let sheetService: any TrackerSheetServicing

    init(sheetService: any TrackerSheetServicing) {
        self.sheetService = sheetService
    }

    var statePublisher: AnyPublisher<Void, Never> {
        sheetService.sheetStatePublisher
    }

    func state(for media: MediaIdentity, isAnime: Bool) -> MediaDetailTrackerState {
        MediaDetailTrackerState(
            isAvailable: sheetService.authenticatedProviders().contains { !isAnime || $0.tracksAnime },
            isTracked: sheetService.hasAuthenticatedLink(for: media),
            anilistID: sheetService.remoteMediaID(for: media, providerID: "anilist")
        )
    }

    func refresh() async throws {
        try await sheetService.refreshState()
    }
}

@MainActor
protocol MediaDetailRelinkServing: AnyObject {
    func relink(
        pluginID: String,
        mediaKind: MediaKind,
        possibleSourceItemIDs: [String],
        destinationItemID: String,
        title: String,
        coverURL: String?,
        rawPayload: Data
    ) async throws
}

extension LibrarySourceRemapper: MediaDetailRelinkServing {
    func relink(
        pluginID: String,
        mediaKind: MediaKind,
        possibleSourceItemIDs: [String],
        destinationItemID: String,
        title: String,
        coverURL: String?,
        rawPayload: Data
    ) async throws {
        _ = try await relink(
            pluginId: pluginID,
            mediaKind: mediaKind,
            possibleSourceItemIds: possibleSourceItemIDs,
            destinationItemId: destinationItemID,
            title: title,
            coverUrl: coverURL,
            rawPayload: rawPayload
        )
    }
}

@MainActor
protocol MediaDetailBaselineAdvancing: AnyObject {
    func advanceBaseline(media: MediaIdentity, knownChapterCount: Int) async throws
    func refresh() async throws
}

extension UpdateManager: MediaDetailBaselineAdvancing {
    func refresh() async throws {
        try await reload()
    }
}

@MainActor
protocol MediaDetailSettingsReading: AnyObject {
    var alwaysShowCategoryPicker: Bool { get }
    var autoSyncTrackersToLocal: Bool { get }
}

extension AppSettingsStore: MediaDetailSettingsReading {}

@MainActor
protocol MediaDetailPluginMetadataProviding: AnyObject {
    func displayName(for pluginID: String) -> String?
}

extension PluginManager: MediaDetailPluginMetadataProviding {
    func displayName(for pluginID: String) -> String? {
        installedPlugins[pluginID]?.info.name
    }
}

struct MediaDetailDiscordActivity: Equatable {
    let details: String
    let state: String
    let activityType: Int
    let detailsURL: String?
    let largeImageText: String
    let imageURL: String?
    let resetTimer: Bool
}

@MainActor
protocol MediaDetailDiscordPresenting: AnyObject {
    func present(_ activity: MediaDetailDiscordActivity)
    func clear()
}

extension DiscordRPCManager: MediaDetailDiscordPresenting {
    func present(_ activity: MediaDetailDiscordActivity) {
        setActivity(
            details: activity.details,
            state: activity.state,
            activityType: activity.activityType,
            detailsUrl: activity.detailsURL,
            largeImageText: activity.largeImageText,
            imageUrl: activity.imageURL,
            resetTimer: activity.resetTimer
        )
    }

    func clear() {
        clearActivity()
    }
}

enum MediaDetailMessage: Equatable {
    case detailLoadFailed
    case saveFailed
    case unsaveFailed
    case trackerProgressFailed
}

@MainActor
protocol MediaDetailMessagePresenting: AnyObject {
    func present(_ message: MediaDetailMessage)
    func presentSaved(itemID: String)
}

@MainActor
final class AppMessageMediaDetailPresenter: MediaDetailMessagePresenting {
    private let messageCenter: AppMessageCenter

    init(messageCenter: AppMessageCenter) {
        self.messageCenter = messageCenter
    }

    func present(_ message: MediaDetailMessage) {
        switch message {
        case .detailLoadFailed:
            messageCenter.publish(.mediaDetailLoadFailed)
        case .saveFailed:
            messageCenter.publish(.mediaDetailSaveFailed)
        case .unsaveFailed:
            messageCenter.publish(.mediaDetailUnsaveFailed)
        case .trackerProgressFailed:
            messageCenter.publish(.mediaDetailTrackerProgressFailed)
        }
    }

    func presentSaved(itemID: String) {
        messageCenter.publishMediaDetailSaved(itemID: itemID)
    }
}

@MainActor
struct PreparedMediaDetailDependencies {
    let library: any MediaDetailLibraryServing
    let progress: any MediaDetailProgressServing
    let tracker: any MediaDetailTrackerServing
    let theme: any MediaDetailThemeServing
    let relink: any MediaDetailRelinkServing
    let baseline: any MediaDetailBaselineAdvancing
    let settings: any MediaDetailSettingsReading
    let pluginMetadata: any MediaDetailPluginMetadataProviding
    let discord: any MediaDetailDiscordPresenting

    static func production(
        libraryManager: LibraryManager,
        readProgressManager: ReadProgressManager,
        tracking: PreparedTrackingDependencies,
        themeManager: ThemeManager,
        librarySourceRemapper: LibrarySourceRemapper,
        updateManager: UpdateManager,
        settingsStore: AppSettingsStore,
        pluginManager: PluginManager,
        discordRPCManager: DiscordRPCManager
    ) -> Self {
        Self(
            library: libraryManager,
            progress: readProgressManager,
            tracker: TrackingMediaDetailAdapter(
                sheetService: tracking.sheetService
            ),
            theme: themeManager,
            relink: librarySourceRemapper,
            baseline: updateManager,
            settings: settingsStore,
            pluginMetadata: pluginManager,
            discord: discordRPCManager
        )
    }
}
