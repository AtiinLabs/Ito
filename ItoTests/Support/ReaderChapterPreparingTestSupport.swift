import Foundation
import ito_runner
@testable import Ito

/// Prepares chapters through a loader fake, as the readers used to load them directly: every chapter is in one
/// fixed format, unless `formats` says a chapter is saved in another form.
@MainActor
final class LoaderBackedChapterPreparer: ReaderChapterPreparing {
    private let load: (MediaEntry, Chapter, PluginNetworkOperation) async throws -> [Page]
    private let reopening: (any DownloadedCopyReopening)?
    let resolver: OfflineChapterSourceResolver
    let format: HistoryReaderFormat
    /// The actual form of chapters that differ from `format`, by exact key.
    var formats: [String: HistoryReaderFormat] = [:]
    private(set) var preparedKeys: [String] = []

    init(manga loader: any MangaPageLoading, format: HistoryReaderFormat = .pages) {
        let resolving = loader as? ResolvingMangaPageLoader
        resolver = resolving?.resolver ?? Self.makeResolver()
        reopening = resolving
        self.format = format
        load = { entry, chapter, operation in try await loader.pages(for: entry, chapter: chapter, operation: operation) }
    }

    init(novel loader: any NovelChapterLoading, format: HistoryReaderFormat = .text) {
        let resolving = loader as? ResolvingNovelChapterLoader
        resolver = resolving?.resolver ?? Self.makeResolver()
        reopening = resolving
        self.format = format
        load = { entry, chapter, operation in try await loader.content(for: entry, chapter: chapter, operation: operation) }
    }

    private static func makeResolver() -> OfflineChapterSourceResolver {
        OfflineChapterSourceResolver(pluginID: "plugin.test", local: UnavailableOfflineChapterReading(), hasRemote: true)
    }

    func isReadingRemoteThisTime(chapterKey: String) -> Bool {
        reopening?.isReadingRemoteThisTime(chapterKey: chapterKey) ?? false
    }

    func readLocalFirst(chapterKey: String) {
        reopening?.readDownloadedCopy(chapterKey: chapterKey)
    }

    func prepareChapter(
        entry: MediaEntry,
        chapter: Chapter,
        operation: PluginNetworkOperation
    ) async throws -> ReaderPreparedChapter {
        preparedKeys.append(chapter.key)
        let pages = try await load(entry, chapter, operation)
        let actual = formats[chapter.key] ?? format
        var overridden = chapter
        overridden.kind = actual == .text ? .text : .images
        return ReaderPreparedChapter(
            entry: formats[chapter.key] == nil ? entry : entry.pinning(overridden),
            chapter: chapter,
            pages: ReaderPageOrdering.ascending(pages),
            format: actual,
            resolver: resolver,
            content: ReaderContentSource(remote: nil)
        )
    }
}

/// A route session over a reader test's progress fake, as a route captures it once.
@MainActor
func makeReaderRouteSession(
    entry: MediaEntry,
    pluginID: String = "plugin.test",
    scope: any PluginCompletionScopeCapturing
) -> ReaderRouteSession {
    ReaderRouteSession(
        media: MediaIdentity(pluginId: pluginID, canonicalMediaId: entry.key, mediaKind: entry.kind),
        mediaKey: entry.key,
        scope: scope
    )
}
