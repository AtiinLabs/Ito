import Foundation
import ito_runner

/// Every exact upload a source listed for one series when the user asked it to, as the runner validated and
/// returned them. The app owns this type so the presentation and its tests never depend on how the runner
/// builds its own result; nothing here is checked a second time.
///
/// It describes one enumeration for one presentation. It is not the series' chapter list: it is never stored
/// with the Library item, never counted as the catalog and never merged into the normal list.
nonisolated struct EnumeratedChapterEditions: Sendable {
    /// The uploads in the order the source's pages gave them. Unique by exact key.
    let editions: [Chapter]
    /// The one scope every page reported.
    let scope: CatalogScope
    /// Whether the list holds everything within `scope`. `partial` after a bounded traversal.
    let completeness: CatalogCompleteness
    let termination: ChapterEditionsResult.Termination

    init(
        editions: [Chapter],
        scope: CatalogScope,
        completeness: CatalogCompleteness,
        termination: ChapterEditionsResult.Termination
    ) {
        self.editions = editions
        self.scope = scope
        self.completeness = completeness
        self.termination = termination
    }

    init(_ result: ChapterEditionsResult) {
        self.init(
            editions: result.editions,
            scope: result.scope,
            completeness: result.completeness,
            termination: result.termination
        )
    }
}

/// Lists a series' exact uploads. The detail screen runs it only for the explicit "Find All Uploads" action.
/// The parameters are the series as a stored entry, the operation the call belongs to, and the source epoch
/// the user's review froze. A nil result means the source does not take part; any other outcome that is not
/// a validated listing throws, and nothing of a failed listing is kept.
typealias ChapterEditionEnumeration = (MediaEntry, PluginNetworkOperation, String) async throws -> EnumeratedChapterEditions?

/// Runs the runner's optional editions export for one installed source. The context is built here, under the
/// epoch the caller froze, so the whole traversal belongs to the source authorization the user reviewed.
@MainActor
struct ChapterEditionsAdapter {
    typealias Fetch = (MediaEntry, NetworkOperationContext) async throws -> EnumeratedChapterEditions?

    private let pluginID: String
    private let contexts: PluginNetworkContexts
    private let fetch: Fetch

    init(pluginID: String, contexts: PluginNetworkContexts, fetch: @escaping Fetch) {
        self.pluginID = pluginID
        self.contexts = contexts
        self.fetch = fetch
    }

    init(runner: ItoRunner, pluginID: String, contexts: PluginNetworkContexts) {
        self.init(pluginID: pluginID, contexts: contexts) { entry, context in
            try await runner.getChapterEditions(entry, context: context).map { EnumeratedChapterEditions($0) }
        }
    }

    /// The validated listing, nil when the source does not list uploads, or a `PluginCallError`. The
    /// operation's purpose is the caller's: this is a user-started request, never a background one.
    func enumerate(
        _ entry: MediaEntry,
        operation: PluginNetworkOperation,
        sourceEpoch: String
    ) async throws -> EnumeratedChapterEditions? {
        let context = contexts.context(pluginID: pluginID, operation, frozenScope: sourceEpoch)
        return try await pluginCall { try await fetch(entry, context) }
    }
}
