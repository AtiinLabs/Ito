import Combine
import Foundation
import GRDB

@MainActor
public final class ReadProgressManager: ObservableObject {
    @Published private var readChapters: [MediaIdentity: Set<String>] = [:]
    @Published private var readChapterNumbers: [MediaIdentity: Set<Float>] = [:]
    @Published private var lastReadChapter: [MediaIdentity: String] = [:]

    private let dbPool: DatabasePool
    private weak var updateManager: UpdateManager?

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    func configure(updateManager: UpdateManager) {
        self.updateManager = updateManager
    }

    public func reload() async throws {
        let snapshot = try await dbPool.read { db in
            let keys = try ReadProgressKeyRecord.fetchAll(db)
            let numbers = try ReadProgressNumberRecord.fetchAll(db)
            let resume = try MediaReadProgressRecord.fetchAll(db)
            return (keys, numbers, resume)
        }

        readChapters = Dictionary(grouping: snapshot.0) {
            MediaIdentity(pluginId: $0.pluginId, canonicalMediaId: $0.canonicalMediaId)
        }.mapValues { Set($0.map(\.chapterKey)) }
        readChapterNumbers = Dictionary(grouping: snapshot.1) {
            MediaIdentity(pluginId: $0.pluginId, canonicalMediaId: $0.canonicalMediaId)
        }.mapValues { Set($0.map { Float($0.chapterNumber) }) }
        lastReadChapter = Dictionary(
            uniqueKeysWithValues: snapshot.2.map {
                (
                    MediaIdentity(pluginId: $0.pluginId, canonicalMediaId: $0.canonicalMediaId),
                    $0.lastReadChapterKey
                )
            }
        )
    }

    public func markAsRead(
        media: MediaIdentity,
        chapterId: String,
        chapterNum: Float? = nil
    ) async throws {
        let now = Date()
        try await dbPool.write { db in
            try ReadProgressKeyRecord(
                pluginId: media.pluginId,
                canonicalMediaId: media.canonicalMediaId,
                chapterKey: chapterId,
                markedAt: now,
                provenance: .runtime
            ).save(db)
            if let chapterNum {
                try ReadProgressNumberRecord(
                    pluginId: media.pluginId,
                    canonicalMediaId: media.canonicalMediaId,
                    chapterNumber: Double(chapterNum),
                    markedAt: now,
                    provenance: .runtime
                ).save(db)
            }
            try MediaReadProgressRecord(
                pluginId: media.pluginId,
                canonicalMediaId: media.canonicalMediaId,
                lastReadChapterKey: chapterId,
                updatedAt: now,
                provenance: .runtime
            ).save(db)
        }

        readChapters[media, default: []].insert(chapterId)
        if let chapterNum {
            readChapterNumbers[media, default: []].insert(chapterNum)
        }
        lastReadChapter[media] = chapterId
    }

    public func markAsWatched(
        media: MediaIdentity,
        episodeId: String,
        episodeNum: Float? = nil
    ) async throws {
        try await markAsRead(media: media, chapterId: episodeId, chapterNum: episodeNum)
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
                    chapterNumber: Double(number),
                    markedAt: now,
                    provenance: .runtime
                ).save(db)
            }
            try UpdateBadgeRecord
                .filter(Column("pluginId") == media.pluginId)
                .filter(Column("canonicalMediaId") == media.canonicalMediaId)
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
