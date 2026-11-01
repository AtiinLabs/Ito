import OSLog
import Combine
import Foundation
import GRDB
import ito_runner

// MARK: - Display Model (used by HistoryView)

public struct HistoryEntry: Identifiable, Hashable, Sendable {
    public var id: String { record.id }
    public let record: ReadingHistoryRecord

    public var seriesKey: HistorySeriesKey {
        HistorySeriesKey(pluginId: record.pluginId, mediaKind: record.mediaKind, mediaKey: record.mediaKey)
    }

    /// History keeps one row per chapter and at most this many rows, newest first. Older rows
    /// are deleted when a chapter is recorded.
    nonisolated public static let retentionLimit = 2_000
}

/// One series in history: the source, the kind of media and the source's key for it.
public struct HistorySeriesKey: Hashable, Sendable {
    public let pluginId: String
    public let mediaKind: MediaKind
    public let mediaKey: String

    var mediaIdentity: MediaIdentity {
        MediaIdentity(pluginId: pluginId, canonicalMediaId: mediaKey, mediaKind: mediaKind)
    }
}

/// A chapter or episode as the reader or player knows it when it is opened.
public struct HistoryChapter: Sendable {
    public let key: String
    public let title: String?
    public let number: Float?
    public let volume: Float?
    public let scanlator: String?
    public let format: HistoryReaderFormat
    public let textLength: Int?

    public init(
        key: String,
        title: String?,
        number: Float?,
        volume: Float? = nil,
        scanlator: String? = nil,
        format: HistoryReaderFormat,
        textLength: Int? = nil
    ) {
        self.key = key
        self.title = title.flatMap { $0.isEmpty ? nil : $0 }
        self.number = number
        self.volume = volume
        self.scanlator = scanlator.flatMap { $0.isEmpty ? nil : $0 }
        self.format = format
        self.textLength = textLength
    }
}

extension HistoryChapter {
    /// A manga or novel chapter, opened in the reader for `format`.
    init(_ chapter: Chapter, format: HistoryReaderFormat, textLength: Int? = nil) {
        self.init(
            key: chapter.key, title: chapter.title, number: chapter.chapter,
            volume: chapter.volume, scanlator: chapter.scanlator, format: format,
            textLength: textLength
        )
    }

    /// An episode; its language stands in for a group.
    init(_ episode: Anime.Episode) {
        self.init(key: episode.key, title: episode.title, number: episode.episode, scanlator: episode.scanlator, format: .video)
    }
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

    @discardableResult
    func recordManga(_ manga: Manga, chapter: HistoryChapter, pluginId: String) -> Task<Void, Never>? {
        record(
            mediaKey: manga.key, title: manga.title, coverUrl: manga.cover,
            mediaKind: .manga, chapter: chapter, pluginId: pluginId
        )
    }

    @discardableResult
    func recordNovel(_ novel: Novel, chapter: HistoryChapter, pluginId: String) -> Task<Void, Never>? {
        record(
            mediaKey: novel.key, title: novel.title, coverUrl: novel.cover,
            mediaKind: .novel, chapter: chapter, pluginId: pluginId
        )
    }

    @discardableResult
    func recordAnime(_ anime: Anime, episode: HistoryChapter, pluginId: String) -> Task<Void, Never>? {
        record(
            mediaKey: anime.key, title: anime.title, coverUrl: anime.cover,
            mediaKind: .anime, chapter: episode, pluginId: pluginId
        )
    }

    private func record(
        mediaKey: String,
        title: String,
        coverUrl: String?,
        mediaKind: MediaKind,
        chapter: HistoryChapter,
        pluginId: String
    ) -> Task<Void, Never>? {
        guard settingsStore?.incognitoMode == false else { return nil }
        let record = ReadingHistoryRecord(
            libraryItemId: libraryManager.savedItemID(
                media: MediaIdentity(pluginId: pluginId, canonicalMediaId: mediaKey, mediaKind: mediaKind)
            ),
            mediaKey: mediaKey,
            title: title,
            coverUrl: coverUrl,
            pluginId: pluginId,
            mediaKind: mediaKind,
            chapterKey: chapter.key,
            chapterTitle: chapter.title,
            chapterNumber: chapter.number.map(Double.init),
            volume: chapter.volume.map(Double.init),
            scanlator: chapter.scanlator,
            format: chapter.format,
            textLength: chapter.textLength
        )
        return Task {
            do {
                try await dbPool.write { db in
                    try Self.recordVisit(record, in: db)
                }
            } catch {
                AppLogger.general.error("[HistoryManager] Failed to record a visit: \(error)")
            }
        }
    }

    /// Keeps one row per chapter: a visit to a chapter already in history replaces its row, under
    /// the row's existing id. Rows that arrived from elsewhere (older versions, restored backups)
    /// are reduced to the newest row per chapter, then history is trimmed to
    /// `HistoryEntry.retentionLimit` chapters.
    nonisolated static func recordVisit(_ record: ReadingHistoryRecord, in db: Database) throws {
        let kept = try chapterRows(
            HistorySeriesKey(pluginId: record.pluginId, mediaKind: record.mediaKind, mediaKey: record.mediaKey),
            chapterKey: record.chapterKey
        )
        .order(ReadingHistoryRecord.Columns.readAt.desc, ReadingHistoryRecord.Columns.id.desc)
        .fetchOne(db)
        if let kept {
            var visit = record
            visit.id = kept.id
            // Visits are written by separate tasks; a late write never moves a chapter back.
            visit.readAt = max(kept.readAt, record.readAt)
            try visit.update(db)
        } else {
            try record.insert(db)
        }
        try db.execute(
            sql: """
                DELETE FROM readingHistory WHERE id IN (
                    SELECT id FROM (
                        SELECT id, ROW_NUMBER() OVER (
                            PARTITION BY pluginId, mediaKind, mediaKey, chapterKey
                            ORDER BY readAt DESC, id DESC
                        ) AS position
                        FROM readingHistory
                    ) WHERE position > 1
                )
                """
        )
        try db.execute(
            sql: """
                DELETE FROM readingHistory WHERE id NOT IN (
                    SELECT id FROM readingHistory ORDER BY readAt DESC, id DESC LIMIT ?
                )
                """,
            arguments: [HistoryEntry.retentionLimit]
        )
    }

    // MARK: - Delete

    /// Removes every row of one chapter of a series.
    func removeChapterDurably(_ series: HistorySeriesKey, chapterKey: String) async throws {
        try await deleteDurably { db in
            try Self.chapterRows(series, chapterKey: chapterKey).deleteAll(db)
        }
    }

    /// Removes every row of the given series, together.
    func removeSeriesDurably(_ series: [HistorySeriesKey]) async throws {
        try await deleteDurably { db in
            try series.reduce(0) { count, series in
                count + (try Self.seriesRows(series).deleteAll(db))
            }
        }
    }

    func clearHistoryDurably() async throws {
        try await deleteDurably { db in
            try ReadingHistoryRecord.deleteAll(db)
        }
    }

    private func deleteDurably(_ delete: @escaping @Sendable (Database) throws -> Int) async throws {
        let publicationClock = publicationClock
        let publication = try await dbPool.write { db in
            let deletedCount = try delete(db)
            return HistoryPublication(
                revision: publicationClock.revisionAfterCommit(changedHistory: deletedCount > 0),
                records: try Self.fetchHistory(db)
            )
        }
        apply(publication)
    }

    nonisolated private static func seriesRows(_ series: HistorySeriesKey) -> QueryInterfaceRequest<ReadingHistoryRecord> {
        ReadingHistoryRecord
            .filter(ReadingHistoryRecord.Columns.pluginId == series.pluginId)
            .filter(ReadingHistoryRecord.Columns.mediaKind == series.mediaKind.rawValue)
            .filter(ReadingHistoryRecord.Columns.mediaKey == series.mediaKey)
    }

    nonisolated private static func chapterRows(
        _ series: HistorySeriesKey,
        chapterKey: String
    ) -> QueryInterfaceRequest<ReadingHistoryRecord> {
        seriesRows(series).filter(ReadingHistoryRecord.Columns.chapterKey == chapterKey)
    }

    nonisolated private static func fetchHistory(_ db: Database) throws -> [ReadingHistoryRecord] {
        try ReadingHistoryRecord
            .order(ReadingHistoryRecord.Columns.readAt.desc, ReadingHistoryRecord.Columns.id.desc)
            .limit(HistoryEntry.retentionLimit)
            .fetchAll(db)
    }

    private func apply(_ publication: HistoryPublication) {
        guard publicationOrder.accepts(publication.revision) else { return }
        history = publication.records.map { HistoryEntry(record: $0) }
    }

}
