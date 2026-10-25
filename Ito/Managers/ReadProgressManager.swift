import Combine
import Foundation
import GRDB
import ito_runner

@MainActor
public final class ReadProgressManager: ObservableObject, PluginCompletionScopeCapturing {
    @Published private var readChapters: [MediaIdentity: Set<String>] = [:]
    @Published private var readChapterNumbers: [MediaIdentity: Set<Float>] = [:]
    @Published private var lastReadChapter: [MediaIdentity: String] = [:]
    // Not published: they change on every page turn and are only read when a reader opens, so
    // publishing them would re-render every screen watching read progress.
    private var lastReadPosition: [MediaIdentity: Double] = [:]
    private var readerViewer: [MediaIdentity: Int] = [:]

    private let dbPool: DatabasePool
    private weak var updateManager: UpdateManager?
    private var completionStore: PluginCompletionStore?
    private var onCompletionQueued: (@MainActor () -> Void)?

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    func configure(updateManager: UpdateManager) {
        self.updateManager = updateManager
    }

    func configureCompletionDelivery(store: PluginCompletionStore, onQueued: @escaping @MainActor () -> Void) {
        completionStore = store
        onCompletionQueued = onQueued
    }

    func captureCompletionContext(
        media: MediaIdentity,
        mediaKey: String
    ) -> PluginCompletionContext {
        completionStore?.captureContext(media: media, mediaKey: mediaKey)
            ?? PluginCompletionContext(media: media, mediaKey: mediaKey, originatingEpoch: nil)
    }

    public func reload() async throws {
        let snapshot = try await dbPool.read { db in
            let keys = try ReadProgressKeyRecord.fetchAll(db)
            let numbers = try ReadProgressNumberRecord.fetchAll(db)
            let resume = try MediaReadProgressRecord.fetchAll(db)
            return (keys, numbers, resume)
        }

        readChapters = Dictionary(grouping: snapshot.0) {
            MediaIdentity(pluginId: $0.pluginId, canonicalMediaId: $0.canonicalMediaId, mediaKind: $0.mediaKind)
        }.mapValues { Set($0.map(\.chapterKey)) }
        readChapterNumbers = Dictionary(grouping: snapshot.1) {
            MediaIdentity(pluginId: $0.pluginId, canonicalMediaId: $0.canonicalMediaId, mediaKind: $0.mediaKind)
        }.mapValues { Set($0.map { Float($0.chapterNumber) }) }
        lastReadChapter = Dictionary(
            uniqueKeysWithValues: snapshot.2.map {
                (
                    MediaIdentity(pluginId: $0.pluginId, canonicalMediaId: $0.canonicalMediaId, mediaKind: $0.mediaKind),
                    $0.lastReadChapterKey
                )
            }
        )
        lastReadPosition = Dictionary(
            uniqueKeysWithValues: snapshot.2.compactMap { record in
                record.lastReadPosition.map {
                    (
                        MediaIdentity(pluginId: record.pluginId, canonicalMediaId: record.canonicalMediaId, mediaKind: record.mediaKind),
                        $0
                    )
                }
            }
        )
        readerViewer = Dictionary(
            uniqueKeysWithValues: snapshot.2.compactMap { record in
                record.readerViewer.map {
                    (
                        MediaIdentity(pluginId: record.pluginId, canonicalMediaId: record.canonicalMediaId, mediaKind: record.mediaKind),
                        $0
                    )
                }
            }
        )
    }

    /// Remembers where the reader is inside `chapterKey`, which becomes the series' last-read chapter.
    public func savePosition(
        media: MediaIdentity,
        chapterKey: String,
        position: Double
    ) async throws {
        guard position.isFinite, position >= 0 else { return }
        let now = Date()
        try await dbPool.write { db in
            let existing = try MediaReadProgressRecord.fetchOne(
                db,
                key: [
                    "pluginId": media.pluginId,
                    "canonicalMediaId": media.canonicalMediaId,
                    "mediaKind": media.mediaKind.rawValue
                ]
            )
            try MediaReadProgressRecord(
                pluginId: media.pluginId,
                canonicalMediaId: media.canonicalMediaId,
                mediaKind: media.mediaKind,
                lastReadChapterKey: chapterKey,
                updatedAt: now,
                provenance: .runtime,
                lastReadPosition: position,
                readerViewer: existing?.readerViewer
            ).save(db)
        }
        if lastReadChapter[media] != chapterKey {
            lastReadChapter[media] = chapterKey
        }
        lastReadPosition[media] = position
    }

    /// The saved position inside `chapterKey`, if it is the series' last-read chapter.
    public func savedPosition(media: MediaIdentity, chapterKey: String) -> Double? {
        guard lastReadChapter[media] == chapterKey else { return nil }
        return lastReadPosition[media]
    }

    /// The manga reading mode chosen for the series, if any (`Manga.Viewer` raw value).
    public func savedReaderViewer(media: MediaIdentity) -> Int? {
        readerViewer[media]
    }

    /// Remembers the reading mode chosen for the series; nil goes back to its default. A series
    /// with no reading state yet starts it at `chapterKey`, the chapter being read.
    public func saveReaderViewer(
        _ viewer: Int?,
        media: MediaIdentity,
        chapterKey: String
    ) async throws {
        let now = Date()
        let chapter = try await dbPool.write { db -> String in
            let key: [String: DatabaseValueConvertible] = [
                "pluginId": media.pluginId,
                "canonicalMediaId": media.canonicalMediaId,
                "mediaKind": media.mediaKind.rawValue
            ]
            if var existing = try MediaReadProgressRecord.fetchOne(db, key: key) {
                existing.readerViewer = viewer
                try existing.update(db)
                return existing.lastReadChapterKey
            }
            try MediaReadProgressRecord(
                pluginId: media.pluginId,
                canonicalMediaId: media.canonicalMediaId,
                mediaKind: media.mediaKind,
                lastReadChapterKey: chapterKey,
                updatedAt: now,
                provenance: .runtime,
                readerViewer: viewer
            ).insert(db)
            return chapterKey
        }
        if lastReadChapter[media] != chapter {
            lastReadChapter[media] = chapter
        }
        readerViewer[media] = viewer
    }

    func markAsRead(
        context: PluginCompletionContext,
        chapterId: String,
        chapterNum: Float? = nil
    ) async throws {
        let media = context.media
        let now = Date()
        try await dbPool.write { db in
            try ReadProgressKeyRecord(
                pluginId: media.pluginId,
                canonicalMediaId: media.canonicalMediaId,
                mediaKind: media.mediaKind,
                chapterKey: chapterId,
                markedAt: now,
                provenance: .runtime
            ).save(db)
            if let chapterNum {
                try ReadProgressNumberRecord(
                    pluginId: media.pluginId,
                    canonicalMediaId: media.canonicalMediaId,
                    mediaKind: media.mediaKind,
                    chapterNumber: Double(chapterNum),
                    markedAt: now,
                    provenance: .runtime
                ).save(db)
            }
            // Marking a chapter read never moves the series' reading place: readers save that
            // themselves, and a late mark for an earlier chapter must not undo a newer place.
            // Only a series with no reading state yet starts one at this chapter.
            let key: [String: DatabaseValueConvertible] = [
                "pluginId": media.pluginId,
                "canonicalMediaId": media.canonicalMediaId,
                "mediaKind": media.mediaKind.rawValue
            ]
            if try MediaReadProgressRecord.fetchOne(db, key: key) == nil {
                try MediaReadProgressRecord(
                    pluginId: media.pluginId,
                    canonicalMediaId: media.canonicalMediaId,
                    mediaKind: media.mediaKind,
                    lastReadChapterKey: chapterId,
                    updatedAt: now,
                    provenance: .runtime
                ).insert(db)
            }
            try PluginCompletionStore.enqueue(context: context, unitKey: chapterId, now: now, in: db)
        }

        readChapters[media, default: []].insert(chapterId)
        if let chapterNum {
            readChapterNumbers[media, default: []].insert(chapterNum)
        }
        if lastReadChapter[media] == nil {
            lastReadChapter[media] = chapterId
        }
        onCompletionQueued?()
    }

    func markAsWatched(
        context: PluginCompletionContext,
        episodeId: String,
        episodeNum: Float? = nil
    ) async throws {
        try await markAsRead(context: context, chapterId: episodeId, chapterNum: episodeNum)
    }

    public func isRead(
        media: MediaIdentity,
        chapterId: String,
        chapterNum: Float? = nil
    ) -> Bool {
        if readChapters[media]?.contains(chapterId) == true {
            return true
        }
        return chapterNum.map { readChapterNumbers[media]?.contains($0) == true } ?? false
    }

    public func markReadUpTo(media: MediaIdentity, maxChapterNum: Float) async throws {
        guard maxChapterNum.isFinite, maxChapterNum >= 1 else {
            return
        }

        let now = Date()
        let numbers: Set<Float> = {
            var values = Set((1...Int(maxChapterNum)).map(Float.init))
            values.insert(maxChapterNum)
            return values
        }()
        try await dbPool.write { db in
            for number in numbers {
                try ReadProgressNumberRecord(
                    pluginId: media.pluginId,
                    canonicalMediaId: media.canonicalMediaId,
                    mediaKind: media.mediaKind,
                    chapterNumber: Double(number),
                    markedAt: now,
                    provenance: .runtime
                ).save(db)
            }
            try UpdateBadgeRecord
                .filter(Column("pluginId") == media.pluginId)
                .filter(Column("canonicalMediaId") == media.canonicalMediaId)
                .filter(Column("mediaKind") == media.mediaKind.rawValue)
                .deleteAll(db)
        }

        readChapterNumbers[media, default: []].formUnion(numbers)
        try await updateManager?.reload()
    }

    public func lastReadChapter(for media: MediaIdentity) -> String? {
        lastReadChapter[media]
    }

    public func readChapterNumbers(for media: MediaIdentity) -> Set<Float> {
        readChapterNumbers[media] ?? []
    }
}
