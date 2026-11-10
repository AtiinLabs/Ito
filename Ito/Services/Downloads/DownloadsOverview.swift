import Combine
import Foundation
import GRDB
import ito_runner

/// Lightweight manager rows. Snapshot JSON is decoded by the database observation, not by a view.
nonisolated struct DownloadListRow: Identifiable, Equatable, Sendable {
    var edition: OfflineChapterEdition
    var title: String?
    var number: Float?
    var volume: Float?
    var scanlator: String?
    var state: ChapterDownloadState
    var byteCount: Int64
    var jobID: String?
    var id: OfflineChapterEdition { edition }

    var canRetry: Bool {
        switch state {
        case .failed: true
        case .waiting(let reason): reason.requiresRetry
        default: false
        }
    }
}

nonisolated struct DownloadsSeries: Identifiable, Equatable, Sendable {
    var id: MediaIdentity
    var title: String
    var rows: [DownloadListRow]
    var byteCount: Int64 { rows.reduce(0) { $0 + $1.byteCount } }
    var damagedCount: Int { rows.filter { $0.state == .damaged }.count }
}

nonisolated struct DownloadsSnapshot: Sendable {
    var inProgress: [DownloadsSeries] = []
    var downloaded: [DownloadsSeries] = []
    var byteCount: Int64 { downloaded.reduce(0) { $0 + $1.byteCount } }

    /// Queue groups keep first appearance in queue order. Inventory groups sort by title, then identity.
    static func read(_ db: Database) throws -> Self {
        let decoder = JSONDecoder()
        var queue: [DownloadsSeries] = []
        var saved: [DownloadsSeries] = []
        for job in try DownloadJobRecord.order(DownloadJobRecord.queueOrder).fetchAll(db) {
            let chapter = try? decoder.decode(Chapter.self, from: job.chapterSnapshot)
            append(DownloadListRow(
                edition: job.edition, title: chapter?.title, number: chapter?.chapter,
                volume: chapter?.volume, scanlator: chapter?.scanlator,
                state: DownloadCenter.state(of: job, progress: nil), byteCount: 0, jobID: job.id
            ), title: job.seriesTitle, to: &queue)
        }
        for copy in try DownloadedChapterRecord.order(Column("verifiedAt"), Column("chapterKey")).fetchAll(db) {
            let chapter = try? decoder.decode(Chapter.self, from: copy.chapterSnapshot)
            append(DownloadListRow(
                edition: copy.edition, title: chapter?.title, number: chapter?.chapter,
                volume: chapter?.volume, scanlator: chapter?.scanlator,
                state: copy.state == .verified ? .downloaded : .damaged,
                byteCount: copy.byteCount, jobID: nil
            ), title: copy.seriesTitle, to: &saved)
        }
        for index in saved.indices { saved[index].rows = readingOrder(saved[index].rows) }
        saved.sort {
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return identityKey($0.id) < identityKey($1.id)
        }
        return Self(inProgress: queue, downloaded: saved)
    }

    private static func identityKey(_ identity: MediaIdentity) -> String {
        "\(identity.pluginId)\u{0}\(identity.mediaKind.rawValue)\u{0}\(identity.canonicalMediaId)"
    }

    private static func append(_ row: DownloadListRow, title: String, to groups: inout [DownloadsSeries]) {
        let identity = MediaIdentity(
            pluginId: row.edition.pluginId, canonicalMediaId: row.edition.canonicalMediaId,
            mediaKind: row.edition.mediaKind
        )
        if let index = groups.firstIndex(where: { $0.id == identity }) {
            groups[index].rows.append(row)
        } else {
            groups.append(DownloadsSeries(id: identity, title: title, rows: [row]))
        }
    }

    /// Numbered inventory can be ordered even without the live source list. For unknown ordering,
    /// retain the stable inventory order; never infer edition identity from numbers.
    static func readingOrder(_ rows: [DownloadListRow]) -> [DownloadListRow] {
        guard rows.allSatisfy({ $0.number?.isFinite == true }) else { return rows }
        let fullVolumes = rows.allSatisfy { $0.volume?.isFinite == true }
        let noVolumes = rows.allSatisfy { $0.volume == nil }
        if !fullVolumes && !noVolumes {
            let numbers = rows.compactMap(\.number)
            guard Set(numbers).count == numbers.count else { return rows }
        }
        return rows.enumerated().sorted { left, right in
            if fullVolumes, left.element.volume != right.element.volume {
                return (left.element.volume ?? 0) < (right.element.volume ?? 0)
            }
            if left.element.number != right.element.number {
                return (left.element.number ?? 0) < (right.element.number ?? 0)
            }
            return left.offset < right.offset
        }.map(\.element)
    }

    func applying(progress: [String: DownloadProgress]) -> Self {
        var result = self
        for group in result.inProgress.indices {
            for index in result.inProgress[group].rows.indices {
                let row = result.inProgress[group].rows[index]
                guard case .downloading = row.state, let id = row.jobID,
                      let report = progress[id], report.jobID == id else { continue }
                result.inProgress[group].rows[index].state = .downloading(
                    completed: report.completedPages, total: report.totalPages
                )
            }
        }
        return result
    }
}

@MainActor
protocol StorageDownloadsServing: AnyObject {
    func inventorySummary() async throws -> [OfflineInventorySummary]
    /// Every series that has a queued, waiting, downloading or failed job, with or without a saved copy.
    func queuedMedia() async throws -> [MediaIdentity]
    func deleteMedia(_ media: MediaIdentity, suppress: Bool) async throws -> DownloadDeleteSummary
}

@MainActor
protocol DownloadsOverviewServing: StorageDownloadsServing {
    /// Each subscription owns one manager-only observation and cancels it when the screen disappears.
    func observe(_ receive: @escaping (Result<DownloadsSnapshot, Error>) -> Void) -> AnyCancellable
    func availableCapacity() async throws -> Int64
    func cancel(jobIDs: [String]) async throws
    func retry(jobIDs: [String]) async throws
    func delete(_ editions: [OfflineChapterEdition], suppress: Bool) async throws -> DownloadDeleteSummary
}

/// Reuses the Library's durable cover service and verifies the current Library cover address.
@MainActor
protocol DownloadsThumbnailServing {
    func thumbnail(for item: LibraryItem) async -> LibraryDurableCover?
    var changes: AnyPublisher<String, Never> { get }
}

extension DownloadsThumbnailServing {
    var changes: AnyPublisher<String, Never> { Empty().eraseToAnyPublisher() }
}

struct UnavailableDownloadsThumbnails: DownloadsThumbnailServing {
    func thumbnail(for item: LibraryItem) async -> LibraryDurableCover? { nil }
}

struct LibraryDownloadsThumbnails: DownloadsThumbnailServing {
    let covers: any LibraryCoverThumbnailServing
    var changes: AnyPublisher<String, Never> { covers.thumbnailChanges }

    func thumbnail(for item: LibraryItem) async -> LibraryDurableCover? {
        guard let address = item.coverUrl,
              let cover = await covers.thumbnail(for: item.id),
              cover.coverURLSHA256 == LibraryCoverThumbnailStore.coverHash(address) else { return nil }
        return cover
    }
}

@MainActor
final class LiveDownloadsOverview: DownloadsOverviewServing {
    private let center: DownloadCenter
    private let store: OfflineChapterStore

    init(center: DownloadCenter, store: OfflineChapterStore) {
        self.center = center
        self.store = store
    }

    func observe(_ receive: @escaping (Result<DownloadsSnapshot, Error>) -> Void) -> AnyCancellable {
        let session = DownloadsObservation(center: center, receive: receive)
        session.start(in: store.database)
        return AnyCancellable { Task { @MainActor in session.cancel() } }
    }

    func inventorySummary() async throws -> [OfflineInventorySummary] { try await store.inventorySummary() }
    func queuedMedia() async throws -> [MediaIdentity] {
        var seen: Set<MediaIdentity> = []
        return try await store.jobs().compactMap { job in
            let identity = MediaIdentity(pluginId: job.pluginId, canonicalMediaId: job.canonicalMediaId,
                                         mediaKind: job.mediaKind)
            return seen.insert(identity).inserted ? identity : nil
        }
    }
    func availableCapacity() async throws -> Int64 { try await store.availableDownloadCapacity() }
    func cancel(jobIDs: [String]) async throws { try await center.cancel(jobIDs: jobIDs) }
    func retry(jobIDs: [String]) async throws { try await center.retry(jobIDs: jobIDs) }
    func delete(_ editions: [OfflineChapterEdition], suppress: Bool) async throws -> DownloadDeleteSummary {
        try await center.delete(editions, suppress: suppress)
    }
    func deleteMedia(_ media: MediaIdentity, suppress: Bool) async throws -> DownloadDeleteSummary {
        try await center.deleteMedia(media, suppress: suppress)
    }
}

@MainActor
private final class DownloadsObservation {
    private let center: DownloadCenter
    private let receive: (Result<DownloadsSnapshot, Error>) -> Void
    private var snapshot: DownloadsSnapshot?
    private var reports: [String: DownloadProgress] = [:]
    private var observation: DatabaseCancellable?
    private var progress: AnyCancellable?

    init(center: DownloadCenter, receive: @escaping (Result<DownloadsSnapshot, Error>) -> Void) {
        self.center = center
        self.receive = receive
    }

    func start(in database: DatabasePool) {
        progress = center.$jobProgress.sink { @MainActor [weak self] reports in
            self?.reports = reports
            self?.publish()
        }
        observation = ValueObservation.tracking { db in try DownloadsSnapshot.read(db) }.start(
            in: database,
            scheduling: DelayedMainActorValueObservationScheduler.mainActor,
            onError: { [weak self] error in self?.receive(.failure(error)) },
            onChange: { [weak self] snapshot in
                self?.snapshot = snapshot
                self?.publish()
            }
        )
    }

    func cancel() {
        observation?.cancel()
        observation = nil
        progress?.cancel()
        progress = nil
    }

    private func publish() {
        guard let snapshot else { return }
        receive(.success(snapshot.applying(progress: reports)))
    }
}
