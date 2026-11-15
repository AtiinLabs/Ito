import Foundation
import ito_runner

/// Lists the pages of one chapter. `ItoRunner` provides it; tests substitute a fake.
nonisolated protocol ChapterPageProviding: Sendable {
    func getChapterPages(entry: MediaEntry, chapter: Chapter, context: NetworkOperationContext) async throws -> [Page]
    /// Re-reads the exact target on the same dedicated runtime. Nil is unconfirmed, not missing.
    func replacementChapter(entry: MediaEntry, key: String, context: NetworkOperationContext) async throws -> Chapter?
}

extension ItoRunner: ChapterPageProviding {
    func replacementChapter(entry: MediaEntry, key: String, context: NetworkOperationContext) async throws -> Chapter? {
        let updated = try await getMediaUpdate(entry, needsDetails: false, needsUnits: true, context: context)
        let chapters: [Chapter]?
        switch updated {
        case .manga(let manga): chapters = manga.chapters
        case .novel(let novel): chapters = novel.chapters
        case .anime: chapters = nil
        }
        let matches = chapters?.filter { $0.key == key } ?? []
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Builds the runtime one download attempt runs on. `PluginManager` provides it; tests substitute a fake.
/// Every runner of the attempt runs under the same `operation` and `frozenScope` (the job's source epoch).
protocol DownloadRuntimeProviding: AnyObject {
    @MainActor
    func makeDownloadRuntime(
        for pluginId: String,
        modules: PluginRunnerHostModules,
        operation: PluginNetworkOperation,
        frozenScope: String?
    ) async throws -> DownloadPluginRuntime
}

/// What one download attempt runs on. Every runner here belongs to that attempt alone: none is taken
/// from or stored in the foreground caches, so reader traffic and download traffic never share a runner.
nonisolated struct DownloadPluginRuntime: Sendable {
    /// The dedicated runner that lists the chapter's pages.
    let pages: any ChapterPageProviding
    /// Creates the runner that resolves `ito://` images. The attempt calls it at most once, and only
    /// when a page needs it.
    let makeImageRunner: @Sendable () async throws -> any PluginImageRunner
    /// False once the installed plugin was republished or removed after this runtime was built.
    let isPluginCurrent: @Sendable () -> Bool
    /// False once the source's trusted certificates changed after this runtime was built.
    let isTrustCurrent: @Sendable () -> Bool
}

extension PluginManager: DownloadRuntimeProviding {}
