import Combine
import Foundation
import Nuke
import UIKit
import ito_runner
@testable import Ito

/// Prepares chapters by script: every chapter is one text page in its configured format, immediately, or
/// when the test lets it go. Calls, their operations and pending requests are observable without waiting on time.
@MainActor
final class ScriptedChapterPreparer: ReaderChapterPreparing {
    struct Call {
        let key: String
        let operation: PluginNetworkOperation
    }

    private struct Pending {
        let key: String
        let prepared: ReaderPreparedChapter
        let continuation: CheckedContinuation<ReaderPreparedChapter, any Error>
    }

    private(set) var calls: [Call] = []
    /// The actual form of chapters that are not pages, by exact key.
    var formats: [String: HistoryReaderFormat] = [:]
    var pages: [String: [Page]] = [:]
    var suspended: Set<String> = []
    var failures: [String: any Error] = [:]
    private var pending: [Pending] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private let resolver = OfflineChapterSourceResolver(
        pluginID: "plugin.test", local: UnavailableOfflineChapterReading(), hasRemote: true
    )

    func callCount(_ key: String) -> Int { calls.filter { $0.key == key }.count }
    var pendingCount: Int { pending.count }

    func isReadingRemoteThisTime(chapterKey: String) -> Bool { false }
    func readLocalFirst(chapterKey: String) {}

    func prepareChapter(
        entry: MediaEntry,
        chapter: Chapter,
        operation: PluginNetworkOperation
    ) async throws -> ReaderPreparedChapter {
        calls.append(Call(key: chapter.key, operation: operation))
        if let failure = failures[chapter.key] { throw failure }
        let format = formats[chapter.key] ?? .pages
        var overridden = chapter
        overridden.kind = format == .text ? .text : .images
        let prepared = ReaderPreparedChapter(
            entry: (chapter.kind ?? entry.kind.defaultContentKind) == overridden.kind ? entry : entry.pinning(overridden),
            chapter: chapter,
            pages: pages[chapter.key] ?? [Page(index: 0, content: .text("text of \(chapter.key)"))],
            format: format,
            resolver: resolver,
            content: ReaderContentSource(remote: nil)
        )
        guard suspended.contains(chapter.key) else { return prepared }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(key: chapter.key, prepared: prepared, continuation: continuation))
            let ready = waiters.filter { pending.count >= $0.0 }
            waiters.removeAll { pending.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }

    func waitForPending(_ count: Int) async {
        guard pending.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    /// Answers the oldest waiting request.
    func resolveFirst(failing error: (any Error)? = nil) {
        guard !pending.isEmpty else { return }
        let next = pending.removeFirst()
        if let error { next.continuation.resume(throwing: error) } else { next.continuation.resume(returning: next.prepared) }
    }
}

/// The network facts a route reads, moved by hand.
@MainActor
final class RouteNetworkFake: ReaderRouteNetworking {
    var scope = UUID()
    var policyRevision: UInt64 = 1
    var pathGeneration: UInt64 = 0
    let policy = PassthroughSubject<Void, Never>()
    let scopeSubject = PassthroughSubject<Void, Never>()
    private(set) var scopeReads = 0

    func liveScope(pluginID: String) -> UUID {
        scopeReads += 1
        return scope
    }

    var policyChanges: AnyPublisher<Void, Never> { policy.eraseToAnyPublisher() }
    var scopeChanges: AnyPublisher<Void, Never> { scopeSubject.eraseToAnyPublisher() }
}

/// Builds the readers of a test route from shared fakes, one image session per reader.
@MainActor
final class RoutePresentationFake: ReaderRoutePresentationMaking {
    let manga: MangaReaderTestSubject
    let novel: NovelReaderTestSubject
    /// The pipeline the destination's image session uses, when a test needs real image states.
    var imagePipeline: ImagePipeline?
    private(set) var created: [ReaderRoutePresentation] = []

    init(manga: MangaReaderTestSubject, novel: NovelReaderTestSubject) {
        self.manga = manga
        self.novel = novel
    }

    private var mangaDependencies: PreparedMangaReaderDependencies {
        let pipeline = imagePipeline
        let base = manga.dependencies
        return PreparedMangaReaderDependencies(
            progress: base.progress, history: base.history, tracker: base.tracker, settings: base.settings,
            presence: base.presence, pluginMetadata: base.pluginMetadata,
            makeImagePrefetcher: { _ in MangaReaderImagePrefetcherFake(imageSession: ReaderPageImageSession(pipeline: pipeline)) },
            presentationLogger: base.presentationLogger
        )
    }

    private var novelDependencies: PreparedNovelReaderDependencies {
        let pipeline = imagePipeline
        let base = novel.dependencies
        return PreparedNovelReaderDependencies(
            progress: base.progress, history: base.history, tracker: base.tracker, settings: base.settings,
            presence: base.presence, pluginMetadata: base.pluginMetadata, presentationLogger: base.presentationLogger,
            makeImageSession: { _ in ReaderPageImageSession(pipeline: pipeline) }
        )
    }

    private func make(
        format: HistoryReaderFormat,
        entry: MediaEntry,
        chapter: Chapter,
        session: ReaderRouteSession,
        preparer: any ReaderChapterPreparing,
        visitID: UUID,
        mode: ReaderPresentationMode
    ) -> ReaderRoutePresentation {
        let presentation: ReaderRoutePresentation
        switch format {
        case .text:
            presentation = .text(visitID: visitID, NovelReaderViewModel(
                chapterPreparer: preparer, routeSession: session, routeVisitID: visitID, presentationMode: mode,
                pluginID: "plugin.test", entry: entry, initialChapter: chapter,
                dependencies: novelDependencies, offline: ReaderOfflineContext()
            ))
        case .pages, .video:
            presentation = .pages(visitID: visitID, MangaReaderViewModel(
                chapterPreparer: preparer, routeSession: session, routeVisitID: visitID, presentationMode: mode,
                pluginID: "plugin.test", entry: entry, initialChapter: chapter,
                dependencies: mangaDependencies, offline: ReaderOfflineContext()
            ))
        }
        created.append(presentation)
        return presentation
    }

    func makeInitialPresentation(
        format: HistoryReaderFormat,
        entry: MediaEntry,
        chapter: Chapter,
        session: ReaderRouteSession,
        preparer: any ReaderChapterPreparing,
        visitID: UUID
    ) -> ReaderRoutePresentation {
        make(format: format, entry: entry, chapter: chapter, session: session, preparer: preparer, visitID: visitID, mode: .live)
    }

    func makePreparedPresentation(
        _ prepared: ReaderPreparedChapter,
        position: ReaderEntryPosition,
        session: ReaderRouteSession,
        preparer: any ReaderChapterPreparing,
        visitID: UUID,
        mode: ReaderPresentationMode
    ) -> ReaderRoutePresentation {
        let presentation = make(
            format: prepared.format, entry: prepared.entry, chapter: prepared.chapter,
            session: session, preparer: preparer, visitID: visitID, mode: mode
        )
        switch presentation {
        case .pages(_, let model):
            model.installPreparedChapter(prepared.pages, position: position)
            model.retain(prepared)
        case .text(_, let model):
            model.installPreparedChapter(prepared.pages, position: position)
            model.retain(prepared)
        }
        return presentation
    }
}

/// A whole route over fakes: both readers' dependencies, the scripted preparer and the hand-moved network.
@MainActor
struct RouteFixture {
    let route: ReaderRouteCoordinator
    let manga: MangaReaderTestSubject
    let novel: NovelReaderTestSubject
    let preparer: ScriptedChapterPreparer
    let network: RouteNetworkFake
    let presentations: RoutePresentationFake
    let session: ReaderRouteSession

    var pagesModel: MangaReaderViewModel? {
        if case .pages(_, let model)? = route.active { return model }
        return nil
    }

    var textModel: NovelReaderViewModel? {
        if case .text(_, let model)? = route.active { return model }
        return nil
    }

    /// The request a pending phase works on.
    var requestID: UUID? { route.phase.request?.id }
}

/// A route that opens `chapter` of `entry` in the reader `format` names, loaded and idle.
@MainActor
func makeRouteFixture(
    entry: MediaEntry,
    chapter: Chapter,
    format: HistoryReaderFormat,
    preparer: ScriptedChapterPreparer = ScriptedChapterPreparer(),
    imagePipeline: ImagePipeline? = nil,
    epoch: String? = "epoch",
    preloadImageCount: Int = 5
) async -> RouteFixture {
    let manga = makeMangaReaderSubject(entry: entry, initialChapter: chapter, preloadImageCount: preloadImageCount)
    let novel = makeNovelReaderSubject(entry: entry, initialChapter: chapter)
    manga.progress.originatingEpoch = epoch
    novel.progress.originatingEpoch = epoch
    let session = makeReaderRouteSession(entry: entry, scope: manga.progress)
    let presentations = RoutePresentationFake(manga: manga, novel: novel)
    presentations.imagePipeline = imagePipeline
    let network = RouteNetworkFake()
    let route = ReaderRouteCoordinator(
        rootID: UUID(), pluginID: "plugin.test", entry: entry, chapter: chapter, format: format,
        session: session, preparer: preparer,
        presentations: presentations, settings: manga.settings, network: network
    )
    let fixture = RouteFixture(
        route: route, manga: manga, novel: novel, preparer: preparer, network: network,
        presentations: presentations, session: session
    )
    if let model = fixture.pagesModel {
        model.start()
        await model.waitForTestingOperations()
    } else if let model = fixture.textModel {
        model.start()
        await model.waitForAllOperationsForTesting()
    }
    return fixture
}

/// Records what a reader sends its route.
@MainActor
final class RecordingHandoffRouter: ReaderHandoffRouting {
    private(set) var events: [ReaderHandoffEvent] = []
    private(set) var preparedEvents: [(event: ReaderHandoffEvent, key: String)] = []
    private(set) var corrections: [(key: String, position: ReaderEntryPosition)] = []
    var acceptsCorrections = true
    private(set) var boundaryLeaves = 0
    /// Called after each event is recorded, so a test can wait on the renderer's delivery.
    var onEvent: (() -> Void)?

    func requestHandoff(_ event: ReaderHandoffEvent) {
        events.append(event)
        onEvent?()
    }
    func requestHandoff(_ event: ReaderHandoffEvent, prepared: ReaderPreparedChapter) {
        preparedEvents.append((event, prepared.chapter.key))
    }
    func requestFormatCorrection(visitID: UUID, prepared: ReaderPreparedChapter, position: ReaderEntryPosition) -> Bool {
        corrections.append((prepared.chapter.key, position))
        return acceptsCorrections
    }
    func handoffBoundaryLeft(visitID: UUID) { boundaryLeaves += 1 }
}

/// An image pipeline whose data loader answers each URL from a script, so image states are real and no network is used.
final class ScriptedImageData: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var failing: Set<URL> = []
    private(set) var requested: [URL] = []
    private var holding = false
    private var held: [() -> Void] = []

    func fail(_ url: URL) { lock.withLock { _ = failing.insert(url) } }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping (Data, URLResponse) -> Void,
        completion: @escaping ((any Error)?) -> Void
    ) -> any Nuke.Cancellable {
        let url = request.url
        let shouldFail = lock.withLock {
            if let url { requested.append(url) }
            return url.map { failing.contains($0) } ?? true
        }
        let deliver: () -> Void = {
            if shouldFail {
                completion(URLError(.badServerResponse))
            } else if let url {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
                    UIColor.red.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
                }
                didReceiveData(image, URLResponse(url: url, mimeType: "image/png", expectedContentLength: image.count, textEncodingName: nil))
                completion(nil)
            }
        }
        let deferred = lock.withLock {
            if holding { held.append(deliver) }
            return holding
        }
        if !deferred { deliver() }
        return ScriptedCancel {}
    }

    /// Answers nothing until `releaseLoads()`, so a test can check what happens while an image is still loading.
    func holdLoads() { lock.withLock { holding = true } }

    func releaseLoads() {
        let work = lock.withLock {
            holding = false
            defer { held = [] }
            return held
        }
        work.forEach { $0() }
    }

    func requestCount(for url: URL) -> Int { lock.withLock { requested.filter { $0 == url }.count } }
}

private final class ScriptedCancel: Nuke.Cancellable, @unchecked Sendable {
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    private let onCancel: () -> Void
    func cancel() { onCancel() }
}

func makeScriptedPipeline(_ data: ScriptedImageData) -> ImagePipeline {
    ImagePipeline {
        $0.dataLoader = data
        $0.imageCache = nil
        $0.dataCache = nil
    }
}
