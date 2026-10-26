import CoreGraphics
import Foundation
import ImageIO
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
    private(set) var requestedEntries: [MediaEntry] = []
    private var pending: [Pending] = []
    func enqueue(_ response: Response, for chapterKey: String) {
        responses[chapterKey, default: []].append(response)
    }

    func pages(for entry: MediaEntry, chapter: Chapter) async throws -> [Page] {
        requestedEntries.append(entry)
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
        let entry: MediaEntry
        let chapterKey: String
        let chapterTitle: String
        let pluginID: String
    }

    let events: MangaReaderEventRecorder
    private(set) var requests: [Request] = []

    init(events: MangaReaderEventRecorder) {
        self.events = events
    }

    func recordChapter(
        of entry: MediaEntry,
        chapterKey: String,
        chapterTitle: String,
        pluginID: String
    ) {
        events.record("history:\(chapterKey)")
        requests.append(
            Request(
                entry: entry,
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
    var mangaReaderWordLookupEnabled = true
    var error: (any Error)?
    private(set) var writtenValues: [Int] = []
    private(set) var writtenWordLookupValues: [Bool] = []

    init(preloadImageCount: Int = 5) {
        mangaReaderPreloadImageCount = preloadImageCount
    }

    func setMangaReaderPreloadImageCount(_ value: Int) async throws {
        writtenValues.append(value)
        if let error { throw error }
        mangaReaderPreloadImageCount = value
    }

    func setMangaReaderWordLookupEnabled(_ value: Bool) async throws {
        writtenWordLookupValues.append(value)
        if let error { throw error }
        mangaReaderWordLookupEnabled = value
    }
}

/// Holds each `words(in:)` call until the test completes it.
nonisolated final class PageTextRecognizerFake: PageTextRecognizing, @unchecked Sendable {
    final class Request: @unchecked Sendable {
        fileprivate let continuation: CheckedContinuation<[RecognizedWord], any Error>
        private let lock = NSLock()
        private var isFinished = false

        fileprivate init(continuation: CheckedContinuation<[RecognizedWord], any Error>) {
            self.continuation = continuation
        }

        func complete(_ result: Result<[RecognizedWord], any Error>) {
            let resumes = lock.withLock { () -> Bool in
                defer { isFinished = true }
                return !isFinished
            }
            if resumes { continuation.resume(with: result) }
        }
    }

    /// When false, a cancelled read still waits for `complete`, like a recognizer that finishes
    /// work already under way.
    let honorsCancellation: Bool
    private let lock = NSLock()
    private var requests: [Request] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Request, Never>)] = []

    init(honorsCancellation: Bool = true) {
        self.honorsCancellation = honorsCancellation
    }

    func words(in image: CGImage, orientation: CGImagePropertyOrientation) async throws -> [RecognizedWord] {
        _ = image
        _ = orientation
        let slot = CancellationSlot()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let registered = Request(continuation: continuation)
                let ready = lock.withLock { () -> [CheckedContinuation<Request, Never>] in
                    requests.append(registered)
                    let count = requests.count
                    let matched = waiters.filter { $0.count == count }
                    waiters.removeAll { $0.count == count }
                    return matched.map(\.continuation)
                }
                ready.forEach { $0.resume(returning: registered) }
                if honorsCancellation, slot.register(registered) {
                    registered.complete(.failure(CancellationError()))
                }
            }
        } onCancel: { [honorsCancellation] in
            if honorsCancellation { slot.cancel()?.complete(.failure(CancellationError())) }
        }
    }

    /// Hands a read to cancellation whichever of the two happens first.
    private final class CancellationSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var request: Request?
        private var cancelled = false

        /// Stores `request`; true when cancellation already happened.
        func register(_ request: Request) -> Bool {
            lock.withLock {
                self.request = request
                return cancelled
            }
        }

        /// Marks cancellation; returns the read to cancel when it has started.
        func cancel() -> Request? {
            lock.withLock {
                cancelled = true
                return request
            }
        }
    }

    /// The `number`th read (1-based), once it has started.
    func request(_ number: Int) async -> Request {
        await withCheckedContinuation { continuation in
            let existing = lock.withLock { () -> Request? in
                if requests.count >= number { return requests[number - 1] }
                waiters.append((number, continuation))
                return nil
            }
            if let existing { continuation.resume(returning: existing) }
        }
    }
}

@MainActor
final class DictionaryFake: DictionaryDefinitionChecking {
    var definedTerms: Set<String> = []
    private(set) var checkedTerms: [String] = []

    func hasDefinition(for term: String) -> Bool {
        checkedTerms.append(term)
        return definedTerms.contains(term)
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
    let textRecognizer: PageTextRecognizerFake
    let dictionary: DictionaryFake
    let logger: PresentationEventCaptureSpy
    let dependencies: PreparedMangaReaderDependencies
}

@MainActor
func makeMangaReaderSubject(
    entry: MediaEntry,
    initialChapter: Chapter,
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
    let textRecognizer = PageTextRecognizerFake()
    let dictionary = DictionaryFake()
    let logger = PresentationEventCaptureSpy()
    let dependencies = PreparedMangaReaderDependencies(
        progress: progress,
        history: history,
        tracker: tracker,
        settings: settings,
        presence: presence,
        pluginMetadata: metadata,
        makeImagePrefetcher: { imagePrefetcher },
        textRecognizer: textRecognizer,
        dictionary: dictionary,
        presentationLogger: logger
    )
    let viewModel = MangaReaderViewModel(
        pageLoader: loader,
        pluginID: "plugin.test",
        entry: entry,
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
        textRecognizer: textRecognizer,
        dictionary: dictionary,
        logger: logger,
        dependencies: dependencies
    )
}

@MainActor
func makeMangaReaderSubject(
    manga: Manga,
    initialChapter: Manga.Chapter,
    preloadImageCount: Int = 5
) -> MangaReaderTestSubject {
    makeMangaReaderSubject(
        entry: .manga(manga),
        initialChapter: initialChapter,
        preloadImageCount: preloadImageCount
    )
}
