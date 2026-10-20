import OSLog
import Combine
import Foundation
import GRDB
import ito_runner

// MARK: - Display Model (used by HistoryView)

public struct HistoryEntry: Identifiable, Hashable, Sendable {
    public var id: String { record.id }
    public let record: ReadingHistoryRecord

    /// Maximum number of entries fetched and shown; older entries stay stored.
    nonisolated public static let fetchLimit = 200
}

nonisolated private struct HistoryPublication: Sendable {
    let revision: UInt64
    let records: [ReadingHistoryRecord]
}

nonisolated private final class HistoryPublicationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0

    func currentRevision() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    func advance() {
        lock.lock()
        revision &+= 1
        lock.unlock()
    }

    func revisionAfterCommit(changedHistory: Bool) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return changedHistory ? revision &+ 1 : revision
    }
}

nonisolated struct HistoryPublicationOrder: Sendable {
    private(set) var appliedRevision: UInt64 = 0

    mutating func accepts(_ revision: UInt64) -> Bool {
        guard revision >= appliedRevision else { return false }
        appliedRevision = revision
        return true
    }
}

// MARK: - History Manager

@MainActor
public class HistoryManager: ObservableObject {
    @Published public private(set) var history: [HistoryEntry] = []

    private let dbPool: DatabasePool
    private let libraryManager: LibraryManager
    private let publicationClock = HistoryPublicationClock()
    private var observationCancellable: DatabaseCancellable?
    private var settingsStore: AppSettingsStore?
    private var publicationOrder = HistoryPublicationOrder()

    public convenience init(dbPool: DatabasePool, libraryManager: LibraryManager) {
        self.init(
            dbPool: dbPool,
            libraryManager: libraryManager,
            observationScheduler: ImmediateValueObservationScheduler()
        )
    }

    init<Scheduler: ValueObservationMainActorScheduler>(
        dbPool: DatabasePool,
        libraryManager: LibraryManager,
        observationScheduler: Scheduler
    ) {
        self.dbPool = dbPool
        self.libraryManager = libraryManager
        startObservation(scheduling: observationScheduler)
    }

    func configure(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
    }

    public func reload() async throws {
        let revision = publicationClock.currentRevision()
        let records = try await dbPool.read { try Self.fetchHistory($0) }
        apply(HistoryPublication(revision: revision, records: records))
    }

    // MARK: - Observation

    private func startObservation<Scheduler: ValueObservationMainActorScheduler>(
        scheduling scheduler: Scheduler
    ) {
        let publicationClock = publicationClock
        let observation = ValueObservation.tracking { db -> HistoryPublication in
            let revision = publicationClock.currentRevision()
            return HistoryPublication(
                revision: revision,
                records: try Self.fetchHistory(db)
            )
        }
        .handleEvents(databaseDidChange: publicationClock.advance)

        observationCancellable = observation.start(
            in: dbPool,
            scheduling: scheduler,
            onError: { error in
                AppLogger.general.error("[HistoryManager] Observation error: \(error)")
            },
            onChange: { [weak self] publication in
                self?.apply(publication)
            }
        )
    }

    // MARK: - Add History

    public func addManga(_ manga: Manga, chapterKey: String, chapterTitle: String, pluginId: String) {
        guard settingsStore?.incognitoMode == false else { return }

        let libraryItemId = libraryManager.isSaved(id: manga.key) ? manga.key : nil

        let record = ReadingHistoryRecord(
            libraryItemId: libraryItemId,
            mediaKey: manga.key,
            title: manga.title,
            coverUrl: manga.cover,
            pluginId: pluginId,
            chapterKey: chapterKey,
            chapterTitle: chapterTitle
        )
        insertRecord(record)
    }

    public func addNovel(_ novel: Novel, chapterKey: String, chapterTitle: String, pluginId: String) {
        guard settingsStore?.incognitoMode == false else { return }

        let libraryItemId = libraryManager.isSaved(id: novel.key) ? novel.key : nil

        let record = ReadingHistoryRecord(
            libraryItemId: libraryItemId,
            mediaKey: novel.key,
            title: novel.title,
            coverUrl: novel.cover,
            pluginId: pluginId,
            chapterKey: chapterKey,
            chapterTitle: chapterTitle
        )
        insertRecord(record)
    }

    public func addAnime(_ anime: Anime, episodeKey: String, episodeTitle: String, pluginId: String) {
        guard settingsStore?.incognitoMode == false else { return }

        let libraryItemId = libraryManager.isSaved(id: anime.key) ? anime.key : nil

        let record = ReadingHistoryRecord(
            libraryItemId: libraryItemId,
            mediaKey: anime.key,
            title: anime.title,
            coverUrl: anime.cover,
            pluginId: pluginId,
            chapterKey: episodeKey,
            chapterTitle: episodeTitle
        )
        insertRecord(record)
    }

    private func insertRecord(_ record: ReadingHistoryRecord) {
        Task {
            do {
                try await dbPool.write { db in
                    try record.insert(db)
                }
            } catch {
                AppLogger.general.error("[HistoryManager] Failed to insert: \(error)")
            }
        }
    }

    // MARK: - Delete

    func removeEntryDurably(id: String) async throws {
        let publicationClock = publicationClock
        let publication = try await dbPool.write { db in
            let deleted = try ReadingHistoryRecord.deleteOne(db, key: id)
            return HistoryPublication(
                revision: publicationClock.revisionAfterCommit(changedHistory: deleted),
                records: try Self.fetchHistory(db)
            )
        }
        apply(publication)
    }

    func clearHistoryDurably() async throws {
        let publicationClock = publicationClock
        let publication = try await dbPool.write { db in
            let deletedCount = try ReadingHistoryRecord.deleteAll(db)
            return HistoryPublication(
                revision: publicationClock.revisionAfterCommit(changedHistory: deletedCount > 0),
                records: try Self.fetchHistory(db)
            )
        }
        apply(publication)
    }

    nonisolated private static func fetchHistory(_ db: Database) throws -> [ReadingHistoryRecord] {
        try ReadingHistoryRecord
            .order(ReadingHistoryRecord.Columns.readAt.desc)
            .limit(HistoryEntry.fetchLimit)
            .fetchAll(db)
    }

    private func apply(_ publication: HistoryPublication) {
        guard publicationOrder.accepts(publication.revision) else { return }
        history = publication.records.map { HistoryEntry(record: $0) }
    }

}
