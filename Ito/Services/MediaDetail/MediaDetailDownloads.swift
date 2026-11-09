import Combine
import Foundation
import ito_runner

/// What a series' detail screen may do with downloads. The composition root passes the live download center
/// only where offline chapters are composed; everywhere else the unavailable seam hides every control.
@MainActor
protocol MediaDetailDownloadServing: AnyObject {
    /// Whether downloads exist on this build. False hides the indicator and the menu.
    var isAvailable: Bool { get }
    /// The download state of each of this series' chapters, keyed by chapter key, now and after every
    /// change. A chapter that was never downloaded or queued has no entry.
    func chapterStates(for media: MediaIdentity) -> AnyPublisher<[String: ChapterDownloadState], Never>
    func download(
        media: MediaIdentity,
        entry: MediaEntry,
        chapter: Chapter,
        seriesTitle: String
    ) async -> DownloadEnqueueOutcome
    func cancel(_ edition: OfflineChapterEdition) async throws
    func retry(_ edition: OfflineChapterEdition) async throws
    func delete(_ edition: OfflineChapterEdition) async throws
}

extension DownloadCenter: MediaDetailDownloadServing {
    var isAvailable: Bool { true }

    /// This series' slice of the observed states. Duplicate slices are dropped, so progress on another
    /// series' chapter does not touch this screen. `@Published` emits the new value, so the slice is
    /// read from the emitted map, not from `states`.
    func chapterStates(for media: MediaIdentity) -> AnyPublisher<[String: ChapterDownloadState], Never> {
        $states
            .map { $0[media] ?? [:] }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func download(
        media: MediaIdentity,
        entry: MediaEntry,
        chapter: Chapter,
        seriesTitle: String
    ) async -> DownloadEnqueueOutcome {
        await enqueue(
            pluginID: media.pluginId,
            mediaKind: media.mediaKind,
            canonicalMediaId: media.canonicalMediaId,
            entry: entry,
            chapter: chapter,
            seriesTitle: seriesTitle
        )
    }
}

/// The seam when no offline store is composed: nothing is downloaded and nothing can be queued.
@MainActor
final class UnavailableMediaDetailDownloads: MediaDetailDownloadServing {
    /// No download service exists. The controls are hidden, so these paths are reached only by mistake.
    private enum Unavailable: Error {
        case noOfflineStore
    }

    var isAvailable: Bool { false }

    func chapterStates(for media: MediaIdentity) -> AnyPublisher<[String: ChapterDownloadState], Never> {
        Just([:]).eraseToAnyPublisher()
    }

    func download(
        media: MediaIdentity,
        entry: MediaEntry,
        chapter: Chapter,
        seriesTitle: String
    ) async -> DownloadEnqueueOutcome {
        .refused(.unavailable)
    }

    func cancel(_ edition: OfflineChapterEdition) async throws {
        throw Unavailable.noOfflineStore
    }

    func retry(_ edition: OfflineChapterEdition) async throws {
        throw Unavailable.noOfflineStore
    }

    func delete(_ edition: OfflineChapterEdition) async throws {
        throw Unavailable.noOfflineStore
    }
}

/// What the detail screen offers for one chapter's download.
enum ChapterDownloadAction: Hashable, Identifiable {
    case download
    case cancel
    case retry
    case delete

    var id: Self { self }
}
