import Foundation
import ito_runner
@testable import Ito

enum MangaReaderTestError: LocalizedError {
    case expected

    var errorDescription: String? { "expected reader failure" }
}

@MainActor
final class MangaReaderEventRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

@MainActor
final class MangaPageLoaderFake: MangaPageLoading {
    enum Response {
        case pages([Page])
        case failure(any Error)
        case suspended
    }

    private struct Pending {
        let chapterKey: String
        let continuation: CheckedContinuation<[Page], any Error>
    }

    var responses: [String: [Response]] = [:]
    private(set) var requestedChapterKeys: [String] = []
    private var pending: [Pending] = []

    func enqueue(_ response: Response, for chapterKey: String) {
        responses[chapterKey, default: []].append(response)
    }

    func pages(for manga: Manga, chapter: Manga.Chapter) async throws -> [Page] {
        _ = manga
        requestedChapterKeys.append(chapter.key)
        let response = responses[chapter.key]?.isEmpty == false
            ? responses[chapter.key]?.removeFirst()
            : .pages([])
        switch response ?? .pages([]) {
        case .pages(let pages):
            return pages
        case .failure(let error):
            throw error
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation in
                pending.append(
                    Pending(chapterKey: chapter.key, continuation: continuation)
                )
            }
        }
    }

    func callCount(for chapterKey: String) -> Int {
        requestedChapterKeys.filter { $0 == chapterKey }.count
    }

    func pendingCount(for chapterKey: String) -> Int {
        pending.filter { $0.chapterKey == chapterKey }.count
    }

    func resolveFirst(
        for chapterKey: String,
        with result: Result<[Page], any Error>
    ) {
        guard let index = pending.firstIndex(where: {
            $0.chapterKey == chapterKey
        }) else { return }
        pending.remove(at: index).continuation.resume(with: result)
    }
}

@MainActor
final class MangaReaderProgressFake: MangaReaderProgressTracking {
    struct Request {
        let context: PluginCompletionContext
        let chapterID: String
        let chapterNumber: Float?
    }

    let events: MangaReaderEventRecorder
    var error: (any Error)?
    private(set) var requests: [Request] = []
    private(set) var capturedContexts: [PluginCompletionContext] = []
    var originatingEpoch: String? = "epoch"
    /// Pages the reader starts at, keyed by chapter.
    var savedPages: [String: Int] = [:]
    private(set) var savedPageWrites: [(chapterID: String, page: Int)] = []
    var savedViewer: Manga.Viewer?
    private(set) var savedViewerWrites: [Manga.Viewer] = []

    init(events: MangaReaderEventRecorder) {
        self.events = events
    }

    func captureCompletionContext(
        media: MediaIdentity,
        mediaKey: String,
        kind: PluginCompletionKind
    ) -> PluginCompletionContext {
        let context = PluginCompletionContext(
            media: media,
            mediaKey: mediaKey,
            kind: kind,
            originatingEpoch: originatingEpoch
        )
        capturedContexts.append(context)
        return context
    }

    func markChapterRead(
        context: PluginCompletionContext,
        chapterID: String,
        chapterNumber: Float?
    ) async throws {
        events.record("progress:\(chapterID)")
        requests.append(
            Request(
                context: context,
                chapterID: chapterID,
                chapterNumber: chapterNumber
            )
        )
        if let error { throw error }
    }

    func savedPage(media: MediaIdentity, chapterID: String) -> Int? {
        _ = media
        return savedPages[chapterID]
    }

    func savePage(_ page: Int, media: MediaIdentity, chapterID: String) async throws {
        _ = media
        savedPageWrites.append((chapterID, page))
        savedPages[chapterID] = page
    }

    func savedViewer(media: MediaIdentity) -> Manga.Viewer? {
        _ = media
        return savedViewer
    }

    func saveViewer(_ viewer: Manga.Viewer, media: MediaIdentity, chapterID: String) async throws {
        _ = media
        _ = chapterID
        savedViewerWrites.append(viewer)
        savedViewer = viewer
    }
}

@MainActor
final class MangaReaderHistoryFake: MangaReaderHistoryRecording {
    struct Request {
        let manga: Manga
        let chapterKey: String
        let chapterTitle: String
        let pluginID: String
    }

    let events: MangaReaderEventRecorder
    private(set) var requests: [Request] = []

    init(events: MangaReaderEventRecorder) {
        self.events = events
    }

    func recordManga(
        _ manga: Manga,
        chapterKey: String,
        chapterTitle: String,
        pluginID: String
    ) {
        events.record("history:\(chapterKey)")
        requests.append(
            Request(
                manga: manga,
                chapterKey: chapterKey,
                chapterTitle: chapterTitle,
                pluginID: pluginID
            )
        )
    }
}

@MainActor
final class MangaReaderTrackerFake: MangaReaderTrackerUpdating {
    struct Request {
        let media: MediaIdentity
        let progress: Int
    }

    let events: MangaReaderEventRecorder
    var anilistIDs: [MediaIdentity: String] = [:]
    private(set) var requests: [Request] = []

    init(events: MangaReaderEventRecorder) {
        self.events = events
    }

    func anilistID(for media: MediaIdentity) -> String? {
        anilistIDs[media]
    }

    func updateMangaProgress(media: MediaIdentity, progress: Int) async {
        events.record("tracker:\(progress)")
        requests.append(Request(media: media, progress: progress))
    }
}

@MainActor
final class MangaReaderSettingsFake: MangaReaderSettingsAccessing {
    var mangaReaderPreloadImageCount: Int
    var error: (any Error)?
    private(set) var writtenValues: [Int] = []

    init(preloadImageCount: Int = 5) {
        mangaReaderPreloadImageCount = preloadImageCount
    }

    func setMangaReaderPreloadImageCount(_ value: Int) async throws {
        writtenValues.append(value)
        if let error { throw error }
        mangaReaderPreloadImageCount = value
    }
}

@MainActor
final class MangaReaderPresenceFake: MangaReaderPresencePresenting {
    enum Event: Equatable {
        case present(MangaReaderPresence)
        case clear
    }

    private(set) var events: [Event] = []

    func presentMangaReaderPresence(_ presence: MangaReaderPresence) {
        events.append(.present(presence))
    }

    func clearMangaReaderPresence() {
        events.append(.clear)
    }

    var presented: [MangaReaderPresence] {
        events.compactMap {
            if case .present(let presence) = $0 { return presence }
            return nil
        }
    }
}

@MainActor
final class MangaReaderPluginMetadataFake: MangaReaderPluginMetadataProviding {
    var names: [String: String] = [:]

    func displayName(for pluginID: String) -> String? {
        names[pluginID]
    }
}

@MainActor
final class MangaReaderImagePrefetcherFake: MangaReaderImagePrefetching {
    private(set) var batches: [[Page]] = []
    private(set) var stopCount = 0

    func prefetch(_ pages: [Page]) {
        batches.append(pages)
    }

    func stopPrefetching() {
        stopCount += 1
    }
}

@MainActor
struct MangaReaderTestSubject {
    let viewModel: MangaReaderViewModel
    let loader: MangaPageLoaderFake
    let events: MangaReaderEventRecorder
    let progress: MangaReaderProgressFake
    let history: MangaReaderHistoryFake
    let tracker: MangaReaderTrackerFake
    let settings: MangaReaderSettingsFake
    let presence: MangaReaderPresenceFake
    let metadata: MangaReaderPluginMetadataFake
    let imagePrefetcher: MangaReaderImagePrefetcherFake
    let logger: PresentationEventCaptureSpy
    let dependencies: PreparedMangaReaderDependencies
}

@MainActor
func makeMangaReaderSubject(
    manga: Manga,
    initialChapter: Manga.Chapter,
    preloadImageCount: Int = 5
) -> MangaReaderTestSubject {
    let events = MangaReaderEventRecorder()
    let loader = MangaPageLoaderFake()
    let progress = MangaReaderProgressFake(events: events)
    let history = MangaReaderHistoryFake(events: events)
    let tracker = MangaReaderTrackerFake(events: events)
    let settings = MangaReaderSettingsFake(preloadImageCount: preloadImageCount)
    let presence = MangaReaderPresenceFake()
    let metadata = MangaReaderPluginMetadataFake()
    let imagePrefetcher = MangaReaderImagePrefetcherFake()
    let logger = PresentationEventCaptureSpy()
    let dependencies = PreparedMangaReaderDependencies(
        progress: progress,
        history: history,
        tracker: tracker,
        settings: settings,
        presence: presence,
        pluginMetadata: metadata,
        makeImagePrefetcher: { imagePrefetcher },
        presentationLogger: logger
    )
    let viewModel = MangaReaderViewModel(
        pageLoader: loader,
        pluginID: "plugin.test",
        manga: manga,
        initialChapter: initialChapter,
        dependencies: dependencies
    )
    return MangaReaderTestSubject(
        viewModel: viewModel,
        loader: loader,
        events: events,
        progress: progress,
        history: history,
        tracker: tracker,
        settings: settings,
        presence: presence,
        metadata: metadata,
        imagePrefetcher: imagePrefetcher,
        logger: logger,
        dependencies: dependencies
    )
}
