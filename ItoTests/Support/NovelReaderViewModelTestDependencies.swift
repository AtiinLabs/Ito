import Combine
import Foundation
import ito_runner
@testable import Ito

enum NovelReaderTestError: LocalizedError {
    case expected
    case secret(String)

    var errorDescription: String? {
        switch self {
        case .expected: return "expected novel reader failure"
        case .secret(let value): return value
        }
    }
}

@MainActor
final class NovelReaderEventRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func clear() {
        events.removeAll()
    }
}

@MainActor
final class NovelChapterLoaderFake: NovelChapterLoading {
    enum Response {
        case pages([Page])
        case failure(any Error)
        case suspended
    }

    struct Request {
        let entry: MediaEntry
        let chapter: Chapter
    }

    private struct Pending {
        let chapterKey: String
        let continuation: CheckedContinuation<[Page], any Error>
    }

    private struct PendingWaiter {
        let chapterKey: String
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    var responses: [String: [Response]] = [:]
    private(set) var requests: [Request] = []
    private var pending: [Pending] = []
    private var pendingWaiters: [PendingWaiter] = []

    func enqueue(_ response: Response, for chapterKey: String) {
        responses[chapterKey, default: []].append(response)
    }

    func content(for entry: MediaEntry, chapter: Chapter) async throws -> [Page] {
        requests.append(Request(entry: entry, chapter: chapter))
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
                resumeSatisfiedPendingWaiters()
            }
        }
    }

    func callCount(for chapterKey: String) -> Int {
        requests.filter { $0.chapter.key == chapterKey }.count
    }

    func pendingCount(for chapterKey: String) -> Int {
        pending.filter { $0.chapterKey == chapterKey }.count
    }

    func waitForPendingCount(_ count: Int, for chapterKey: String) async {
        guard pendingCount(for: chapterKey) < count else { return }
        await withCheckedContinuation { continuation in
            pendingWaiters.append(
                PendingWaiter(
                    chapterKey: chapterKey,
                    count: count,
                    continuation: continuation
                )
            )
        }
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

    private func resumeSatisfiedPendingWaiters() {
        var remaining: [PendingWaiter] = []
        for waiter in pendingWaiters {
            if pendingCount(for: waiter.chapterKey) >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        pendingWaiters = remaining
    }
}

@MainActor
final class NovelReaderProgressFake: NovelReaderProgressTracking {
    enum Response {
        case success
        case failure(any Error)
        case suspended
    }

    struct Request {
        let context: PluginCompletionContext
        let chapterID: String
        let chapterNumber: Float?
    }

    let events: NovelReaderEventRecorder
    var responses: [Response] = []
    private(set) var requests: [Request] = []
    private(set) var capturedContexts: [PluginCompletionContext] = []
    var originatingEpoch: String? = "epoch"
    /// The series' saved position, keyed by its chapter. Like the real store it holds at most
    /// one chapter: saving another replaces it, and finishing another chapter clears it.
    var savedOffsets: [String: Int] = [:]
    private(set) var savedOffsetWrites: [(chapterID: String, offset: Int)] = []
    private var pending: [CheckedContinuation<Void, any Error>] = []

    init(events: NovelReaderEventRecorder) {
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

    func markNovelChapterRead(
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
        if savedOffsets[chapterID] == nil {
            savedOffsets.removeAll()
        }
        let response = responses.isEmpty ? .success : responses.removeFirst()
        switch response {
        case .success:
            return
        case .failure(let error):
            throw error
        case .suspended:
            try await withCheckedThrowingContinuation { continuation in
                pending.append(continuation)
                resumeSatisfiedPendingWaiters()
            }
        }
    }

    func enqueue(_ response: Response) {
        responses.append(response)
    }

    func savedNovelOffset(media: MediaIdentity, chapterID: String) -> Int? {
        _ = media
        return savedOffsets[chapterID]
    }

    func saveNovelOffset(_ offset: Int, media: MediaIdentity, chapterID: String) async throws {
        _ = media
        savedOffsetWrites.append((chapterID, offset))
        savedOffsets = [chapterID: offset]
    }

    var pendingCount: Int { pending.count }

    private var pendingWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func waitForPendingCount(_ count: Int) async {
        guard pendingCount < count else { return }
        await withCheckedContinuation { continuation in
            pendingWaiters.append((count, continuation))
        }
    }

    func resolveFirst(with result: Result<Void, any Error> = .success(())) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(with: result)
    }

    private func resumeSatisfiedPendingWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in pendingWaiters {
            if pendingCount >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        pendingWaiters = remaining
    }
}

@MainActor
final class NovelReaderHistoryFake: NovelReaderHistoryRecording {
    struct Request {
        let entry: MediaEntry
        let chapterKey: String
        let chapterTitle: String
        let pluginID: String
    }

    let events: NovelReaderEventRecorder
    var onRecord: (() -> Void)?
    private(set) var requests: [Request] = []

    init(events: NovelReaderEventRecorder) {
        self.events = events
    }

    func recordChapter(
        of entry: MediaEntry,
        chapterKey: String,
        chapterTitle: String,
        pluginID: String
    ) {
        onRecord?()
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
final class NovelReaderTrackerFake: NovelReaderTrackerUpdating {
    struct Request {
        let media: MediaIdentity
        let progress: Int
    }

    let events: NovelReaderEventRecorder
    var anilistIDs: [MediaIdentity: String] = [:]
    private(set) var requests: [Request] = []

    init(events: NovelReaderEventRecorder) {
        self.events = events
    }

    func novelReaderAnilistID(for media: MediaIdentity) -> String? {
        anilistIDs[media]
    }

    func updateNovelProgress(media: MediaIdentity, progress: Int) async {
        events.record("tracker:\(progress)")
        requests.append(Request(media: media, progress: progress))
    }
}

@MainActor
final class NovelReaderSettingsFake: NovelReaderSettingsAccessing {
    enum Key: Hashable {
        case fontSize
        case lineSpacing
        case fontFamily
        case theme
        case isPaging
        case prefetchChapters
    }

    enum Response {
        case success
        case failure(any Error)
        case suspended
    }

    enum Write: Equatable {
        case fontSize(Double)
        case lineSpacing(Double)
        case fontFamily(NovelFontPreference)
        case theme(NovelThemePreference)
        case isPaging(Bool)
        case prefetchChapters(Bool)
    }

    private struct Pending {
        let key: Key
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct PendingWaiter {
        let key: Key
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let subject: CurrentValueSubject<NovelReaderSettingsSnapshot, Never>
    private var responses: [Key: [Response]] = [:]
    private var pending: [Pending] = []
    private var pendingWaiters: [PendingWaiter] = []
    private(set) var writes: [Write] = []

    init(
        settings: NovelReaderSettingsSnapshot = NovelReaderSettingsSnapshot(
            fontSize: 18,
            lineSpacing: 8,
            fontFamily: .system,
            theme: .system,
            isPaging: false,
            prefetchChapters: true
        )
    ) {
        subject = CurrentValueSubject(settings)
    }

    var novelReaderSettings: NovelReaderSettingsSnapshot { subject.value }

    var novelReaderSettingsUpdates: AnyPublisher<NovelReaderSettingsSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }

    func enqueue(_ response: Response, for key: Key) {
        responses[key, default: []].append(response)
    }

    func pendingCount(for key: Key) -> Int {
        pending.filter { $0.key == key }.count
    }

    func waitForPendingCount(_ count: Int, for key: Key) async {
        guard pendingCount(for: key) < count else { return }
        await withCheckedContinuation { continuation in
            pendingWaiters.append(
                PendingWaiter(
                    key: key,
                    count: count,
                    continuation: continuation
                )
            )
        }
    }

    func resolveFirst(for key: Key, with result: Result<Void, any Error> = .success(())) {
        guard let index = pending.firstIndex(where: { $0.key == key }) else { return }
        pending.remove(at: index).continuation.resume(with: result)
    }

    func setNovelFontSize(_ value: Double) async throws {
        writes.append(.fontSize(value))
        try await perform(.fontSize)
        publish { current in
            NovelReaderSettingsSnapshot(
                fontSize: value,
                lineSpacing: current.lineSpacing,
                fontFamily: current.fontFamily,
                theme: current.theme,
                isPaging: current.isPaging,
                prefetchChapters: current.prefetchChapters
            )
        }
    }

    func setNovelLineSpacing(_ value: Double) async throws {
        writes.append(.lineSpacing(value))
        try await perform(.lineSpacing)
        publish { current in
            NovelReaderSettingsSnapshot(
                fontSize: current.fontSize,
                lineSpacing: value,
                fontFamily: current.fontFamily,
                theme: current.theme,
                isPaging: current.isPaging,
                prefetchChapters: current.prefetchChapters
            )
        }
    }

    func setNovelFontFamily(_ value: NovelFontPreference) async throws {
        writes.append(.fontFamily(value))
        try await perform(.fontFamily)
        publish { current in
            NovelReaderSettingsSnapshot(
                fontSize: current.fontSize,
                lineSpacing: current.lineSpacing,
                fontFamily: value,
                theme: current.theme,
                isPaging: current.isPaging,
                prefetchChapters: current.prefetchChapters
            )
        }
    }

    func setNovelTheme(_ value: NovelThemePreference) async throws {
        writes.append(.theme(value))
        try await perform(.theme)
        publish { current in
            NovelReaderSettingsSnapshot(
                fontSize: current.fontSize,
                lineSpacing: current.lineSpacing,
                fontFamily: current.fontFamily,
                theme: value,
                isPaging: current.isPaging,
                prefetchChapters: current.prefetchChapters
            )
        }
    }

    func setNovelIsPaging(_ value: Bool) async throws {
        writes.append(.isPaging(value))
        try await perform(.isPaging)
        publish { current in
            NovelReaderSettingsSnapshot(
                fontSize: current.fontSize,
                lineSpacing: current.lineSpacing,
                fontFamily: current.fontFamily,
                theme: current.theme,
                isPaging: value,
                prefetchChapters: current.prefetchChapters
            )
        }
    }

    func setNovelPrefetchChapters(_ value: Bool) async throws {
        writes.append(.prefetchChapters(value))
        try await perform(.prefetchChapters)
        publish { current in
            NovelReaderSettingsSnapshot(
                fontSize: current.fontSize,
                lineSpacing: current.lineSpacing,
                fontFamily: current.fontFamily,
                theme: current.theme,
                isPaging: current.isPaging,
                prefetchChapters: value
            )
        }
    }

    private func perform(_ key: Key) async throws {
        let response = responses[key]?.isEmpty == false
            ? responses[key]?.removeFirst()
            : .success
        switch response ?? .success {
        case .success:
            return
        case .failure(let error):
            throw error
        case .suspended:
            try await withCheckedThrowingContinuation { continuation in
                pending.append(Pending(key: key, continuation: continuation))
                resumeSatisfiedPendingWaiters()
            }
        }
    }

    private func resumeSatisfiedPendingWaiters() {
        var remaining: [PendingWaiter] = []
        for waiter in pendingWaiters {
            if pendingCount(for: waiter.key) >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        pendingWaiters = remaining
    }

    private func publish(
        _ update: (NovelReaderSettingsSnapshot) -> NovelReaderSettingsSnapshot
    ) {
        subject.send(update(subject.value))
    }
}

@MainActor
final class NovelReaderPresenceFake: NovelReaderPresencePresenting {
    enum Event: Equatable {
        case present(NovelReaderPresence)
        case clear
    }

    private(set) var events: [Event] = []

    func presentNovelReaderPresence(_ presence: NovelReaderPresence) {
        events.append(.present(presence))
    }

    func clearNovelReaderPresence() {
        events.append(.clear)
    }

    var presented: [NovelReaderPresence] {
        events.compactMap {
            if case .present(let presence) = $0 { return presence }
            return nil
        }
    }
}

@MainActor
final class NovelReaderPluginMetadataFake: NovelReaderPluginMetadataProviding {
    var names: [String: String] = [:]

    func novelReaderPluginDisplayName(for pluginID: String) -> String? {
        names[pluginID]
    }
}

@MainActor
struct NovelReaderTestSubject {
    let viewModel: NovelReaderViewModel
    let loader: NovelChapterLoaderFake
    let events: NovelReaderEventRecorder
    let progress: NovelReaderProgressFake
    let history: NovelReaderHistoryFake
    let tracker: NovelReaderTrackerFake
    let settings: NovelReaderSettingsFake
    let presence: NovelReaderPresenceFake
    let metadata: NovelReaderPluginMetadataFake
    let logger: PresentationEventCaptureSpy
}

@MainActor
func makeNovelReaderSubject(
    novel: Novel,
    initialChapter: Novel.Chapter,
    settingsSnapshot: NovelReaderSettingsSnapshot = NovelReaderSettingsSnapshot(
        fontSize: 18,
        lineSpacing: 8,
        fontFamily: .system,
        theme: .system,
        isPaging: false,
        prefetchChapters: true
    )
) -> NovelReaderTestSubject {
    makeNovelReaderSubject(entry: .novel(novel), initialChapter: initialChapter, settingsSnapshot: settingsSnapshot)
}

@MainActor
func makeNovelReaderSubject(
    entry: MediaEntry,
    initialChapter: Chapter,
    settingsSnapshot: NovelReaderSettingsSnapshot = NovelReaderSettingsSnapshot(
        fontSize: 18,
        lineSpacing: 8,
        fontFamily: .system,
        theme: .system,
        isPaging: false,
        prefetchChapters: true
    )
) -> NovelReaderTestSubject {
    let events = NovelReaderEventRecorder()
    let loader = NovelChapterLoaderFake()
    let progress = NovelReaderProgressFake(events: events)
    let history = NovelReaderHistoryFake(events: events)
    let tracker = NovelReaderTrackerFake(events: events)
    let settings = NovelReaderSettingsFake(settings: settingsSnapshot)
    let presence = NovelReaderPresenceFake()
    let metadata = NovelReaderPluginMetadataFake()
    let logger = PresentationEventCaptureSpy()
    let dependencies = PreparedNovelReaderDependencies(
        progress: progress,
        history: history,
        tracker: tracker,
        settings: settings,
        presence: presence,
        pluginMetadata: metadata,
        presentationLogger: logger
    )
    let viewModel = NovelReaderViewModel(
        chapterLoader: loader,
        pluginID: "plugin.test",
        entry: entry,
        initialChapter: initialChapter,
        dependencies: dependencies
    )
    return NovelReaderTestSubject(
        viewModel: viewModel,
        loader: loader,
        events: events,
        progress: progress,
        history: history,
        tracker: tracker,
        settings: settings,
        presence: presence,
        metadata: metadata,
        logger: logger
    )
}
