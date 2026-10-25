import Combine
import UIKit
import XCTest
import ito_runner
@testable import Ito

@MainActor
func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTAssertTrue(condition())
}

enum MediaDetailTestFailure: Error {
    case expected
}

@MainActor
final class MediaRouteHarness<M: MediaDisplayable> {
    enum LoadResponse {
        case value(M)
        case failure
        case suspended
    }

    enum SearchResponse {
        case value([M])
        case failure
        case suspended
    }

    var loadResponses: [LoadResponse] = []
    var searchResponses: [SearchResponse] = []
    private(set) var loadRequests: [M] = []
    private(set) var searchQueries: [String] = []
    private var pendingLoads: [CheckedContinuation<M, any Error>] = []
    private var pendingSearches: [CheckedContinuation<[M], any Error>] = []

    var pendingLoadCount: Int { pendingLoads.count }
    var pendingSearchCount: Int { pendingSearches.count }

    func load(_ media: M) async throws -> M {
        loadRequests.append(media)
        guard !loadResponses.isEmpty else { return media }
        switch loadResponses.removeFirst() {
        case .value(let value): return value
        case .failure: throw MediaDetailTestFailure.expected
        case .suspended:
            return try await withCheckedThrowingContinuation {
                pendingLoads.append($0)
            }
        }
    }

    func search(_ query: String) async throws -> [M] {
        searchQueries.append(query)
        guard !searchResponses.isEmpty else { return [] }
        switch searchResponses.removeFirst() {
        case .value(let value): return value
        case .failure: throw MediaDetailTestFailure.expected
        case .suspended:
            return try await withCheckedThrowingContinuation {
                pendingSearches.append($0)
            }
        }
    }

    func resolveLoad(at index: Int, with result: Result<M, any Error>) {
        pendingLoads.remove(at: index).resume(with: result)
    }

    func resolveSearch(at index: Int, with result: Result<[M], any Error>) {
        pendingSearches.remove(at: index).resume(with: result)
    }
}

@MainActor
final class MediaDetailLibraryFake: MediaDetailLibraryServing {
    enum SaveKind: Equatable { case manga, anime, novel }

    private let subject: CurrentValueSubject<MediaDetailLibraryState, Never>
    var saveError: (any Error)?
    var unsaveError: (any Error)?
    var suspendSave = false
    var suspendUnsave = false
    var durableSavedItemID: String?
    var stateOnRefresh: MediaDetailLibraryState?
    private var pendingSaves: [CheckedContinuation<Void, any Error>] = []
    private var pendingUnsaves: [CheckedContinuation<Void, any Error>] = []
    private(set) var saveKinds: [SaveKind] = []
    private(set) var unsaveRequests: [MediaIdentity] = []
    private(set) var refreshCount = 0

    init(
        state: MediaDetailLibraryState = MediaDetailLibraryState(
            records: [],
            hasCustomCategories: false
        )
    ) {
        subject = CurrentValueSubject(state)
    }

    var state: MediaDetailLibraryState { subject.value }
    var statePublisher: AnyPublisher<MediaDetailLibraryState, Never> {
        subject.eraseToAnyPublisher()
    }
    var pendingSaveCount: Int { pendingSaves.count }
    var pendingUnsaveCount: Int { pendingUnsaves.count }

    func saveManga(_ manga: Manga, pluginID: String) async throws -> String {
        saveKinds.append(.manga)
        return try await performSave(itemID: manga.key, pluginID: pluginID, mediaKind: .manga)
    }

    func saveAnime(_ anime: Anime, pluginID: String) async throws -> String {
        saveKinds.append(.anime)
        return try await performSave(itemID: anime.key, pluginID: pluginID, mediaKind: .anime)
    }

    func saveNovel(_ novel: Novel, pluginID: String) async throws -> String {
        saveKinds.append(.novel)
        return try await performSave(itemID: novel.key, pluginID: pluginID, mediaKind: .novel)
    }

    func unsave(media: MediaIdentity) async throws {
        unsaveRequests.append(media)
        if let unsaveError { throw unsaveError }
        if suspendUnsave {
            try await withCheckedThrowingContinuation { pendingUnsaves.append($0) }
        }
        publish(
            records: state.records.filter {
                MediaIdentity(pluginId: $0.pluginID, itemId: $0.itemID, mediaKind: $0.mediaKind) != media
            },
            hasCustomCategories: state.hasCustomCategories
        )
    }

    func refresh() async throws {
        refreshCount += 1
        if let stateOnRefresh { subject.send(stateOnRefresh) }
    }

    func publish(records: [MediaDetailLibraryRecord], hasCustomCategories: Bool) {
        subject.send(
            MediaDetailLibraryState(
                records: records,
                hasCustomCategories: hasCustomCategories
            )
        )
    }

    func resolveSave(with result: Result<Void, any Error>) {
        pendingSaves.removeFirst().resume(with: result)
    }

    func resolveUnsave(with result: Result<Void, any Error>) {
        pendingUnsaves.removeFirst().resume(with: result)
    }

    private func performSave(itemID: String, pluginID: String, mediaKind: MediaKind) async throws -> String {
        if let saveError { throw saveError }
        if suspendSave {
            try await withCheckedThrowingContinuation { pendingSaves.append($0) }
        }
        let storedItemID = durableSavedItemID ?? itemID
        var records = state.records
        let record = MediaDetailLibraryRecord(itemID: storedItemID, pluginID: pluginID, mediaKind: mediaKind)
        if !records.contains(record) { records.append(record) }
        publish(records: records, hasCustomCategories: state.hasCustomCategories)
        return storedItemID
    }
}

@MainActor
final class MediaDetailProgressFake: MediaDetailProgressServing {
    struct ReadRequest {
        let media: MediaIdentity
        let chapterID: String
        let chapterNumber: Float?
    }
    struct MarkRequest {
        let media: MediaIdentity
        let maximum: Float
    }

    private let subject = PassthroughSubject<Void, Never>()
    var readChapterIDs: [MediaIdentity: Set<String>] = [:]
    var readChapterNumbers: [MediaIdentity: Set<Float>] = [:]
    var lastRead: [MediaIdentity: String] = [:]
    var markError: (any Error)?
    private(set) var readRequests: [ReadRequest] = []
    private(set) var markRequests: [MarkRequest] = []
    private(set) var refreshCount = 0

    var progressPublisher: AnyPublisher<Void, Never> {
        subject.eraseToAnyPublisher()
    }

    func isRead(media: MediaIdentity, chapterID: String, chapterNumber: Float?) -> Bool {
        readRequests.append(ReadRequest(media: media, chapterID: chapterID, chapterNumber: chapterNumber))
        let hasReadChapterID = readChapterIDs[media]?.contains(chapterID) == true
        let hasReadChapterNumber = chapterNumber.map {
            readChapterNumbers[media]?.contains($0) == true
        } ?? false
        return hasReadChapterID || hasReadChapterNumber
    }

    func lastReadChapter(for media: MediaIdentity) -> String? {
        lastRead[media]
    }

    func readChapterNumbers(for media: MediaIdentity) -> Set<Float> {
        readChapterNumbers[media] ?? []
    }

    func markReadUpTo(media: MediaIdentity, maximumChapterNumber: Float) async throws {
        markRequests.append(MarkRequest(media: media, maximum: maximumChapterNumber))
        if let markError { throw markError }
        subject.send()
    }

    func refresh() async throws {
        refreshCount += 1
        subject.send()
    }
}

@MainActor
final class MediaDetailTrackerFake: MediaDetailTrackerServing {
    private let subject = PassthroughSubject<Void, Never>()
    var states: [MediaIdentity: MediaDetailTrackerState] = [:]
    private(set) var refreshCount = 0

    var statePublisher: AnyPublisher<Void, Never> {
        subject.eraseToAnyPublisher()
    }

    func state(for media: MediaIdentity, isAnime: Bool) -> MediaDetailTrackerState {
        states[media] ?? MediaDetailTrackerState(
            isAvailable: false,
            isTracked: false,
            anilistID: nil
        )
    }

    func refresh() async throws {
        refreshCount += 1
        subject.send()
    }

    func publish(_ state: MediaDetailTrackerState, for media: MediaIdentity) {
        states[media] = state
        subject.send()
    }
}

@MainActor
final class MediaDetailThemeFake: MediaDetailThemeServing {
    enum Response {
        case value(ThemeColors?)
        case suspended
    }

    var cachedResponses: [Response] = []
    var extractionResponses: [Response] = []
    private(set) var cachedKeys: [String] = []
    private(set) var extractionKeys: [String] = []
    private var pendingCached: [CheckedContinuation<ThemeColors?, Never>] = []
    private var pendingExtractions: [CheckedContinuation<ThemeColors?, Never>] = []

    var pendingCachedCount: Int { pendingCached.count }
    var pendingExtractionCount: Int { pendingExtractions.count }

    func cachedTheme(for mediaKey: String) async -> ThemeColors? {
        cachedKeys.append(mediaKey)
        guard !cachedResponses.isEmpty else { return nil }
        switch cachedResponses.removeFirst() {
        case .value(let value): return value
        case .suspended:
            return await withCheckedContinuation { pendingCached.append($0) }
        }
    }

    func extractTheme(from image: UIImage, for mediaKey: String) async -> ThemeColors? {
        _ = image
        extractionKeys.append(mediaKey)
        guard !extractionResponses.isEmpty else { return nil }
        switch extractionResponses.removeFirst() {
        case .value(let value): return value
        case .suspended:
            return await withCheckedContinuation { pendingExtractions.append($0) }
        }
    }

    func resolveCached(at index: Int, value: ThemeColors?) {
        pendingCached.remove(at: index).resume(returning: value)
    }

    func resolveExtraction(at index: Int, value: ThemeColors?) {
        pendingExtractions.remove(at: index).resume(returning: value)
    }
}

@MainActor
final class MediaDetailRelinkFake: MediaDetailRelinkServing {
    struct Request {
        let pluginID: String
        let mediaKind: MediaKind
        let possibleSourceItemIDs: [String]
        let destinationItemID: String
        let title: String
        let coverURL: String?
        let rawPayload: Data
    }

    var error: (any Error)?
    var suspend = false
    private var pending: [CheckedContinuation<Void, any Error>] = []
    private(set) var requests: [Request] = []
    var pendingCount: Int { pending.count }

    func relink(
        pluginID: String,
        mediaKind: MediaKind,
        possibleSourceItemIDs: [String],
        destinationItemID: String,
        title: String,
        coverURL: String?,
        rawPayload: Data
    ) async throws {
        requests.append(
            Request(
                pluginID: pluginID,
                mediaKind: mediaKind,
                possibleSourceItemIDs: possibleSourceItemIDs,
                destinationItemID: destinationItemID,
                title: title,
                coverURL: coverURL,
                rawPayload: rawPayload
            )
        )
        if let error { throw error }
        if suspend {
            try await withCheckedThrowingContinuation { pending.append($0) }
        }
    }

    func resolve(with result: Result<Void, any Error>) {
        pending.removeFirst().resume(with: result)
    }
}

@MainActor
final class MediaDetailBaselineFake: MediaDetailBaselineAdvancing {
    struct Request {
        let media: MediaIdentity
        let knownChapterCount: Int
    }

    var error: (any Error)?
    private(set) var requests: [Request] = []
    private(set) var refreshCount = 0

    func advanceBaseline(media: MediaIdentity, knownChapterCount: Int) async throws {
        requests.append(Request(media: media, knownChapterCount: knownChapterCount))
        if let error { throw error }
    }

    func refresh() async throws {
        refreshCount += 1
    }
}

@MainActor
final class MediaDetailSettingsFake: MediaDetailSettingsReading {
    var alwaysShowCategoryPicker: Bool
    var autoSyncTrackersToLocal: Bool

    init(
        alwaysShowCategoryPicker: Bool = false,
        autoSyncTrackersToLocal: Bool = true
    ) {
        self.alwaysShowCategoryPicker = alwaysShowCategoryPicker
        self.autoSyncTrackersToLocal = autoSyncTrackersToLocal
    }
}

@MainActor
final class MediaDetailPluginMetadataFake: MediaDetailPluginMetadataProviding {
    var names: [String: String] = [:]
    func displayName(for pluginID: String) -> String? { names[pluginID] }
}

@MainActor
final class MediaDetailDiscordFake: MediaDetailDiscordPresenting {
    enum Event {
        case present(MediaDetailDiscordActivity)
        case clear
    }
    private(set) var events: [Event] = []
    func present(_ activity: MediaDetailDiscordActivity) { events.append(.present(activity)) }
    func clear() { events.append(.clear) }
}

@MainActor
final class MediaDetailMessageSpy: MediaDetailMessagePresenting {
    private(set) var messages: [MediaDetailMessage] = []
    private(set) var savedItemIDs: [String] = []
    func present(_ message: MediaDetailMessage) { messages.append(message) }
    func presentSaved(itemID: String) {
        savedItemIDs.append(itemID)
    }
}
