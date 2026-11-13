import OSLog
import Combine
import Foundation
import GRDB
import SwiftUI
import ito_runner

nonisolated private struct LibrarySnapshot: Sendable {
    let categories: [LibraryCategory]
    let items: [LibraryItem]
    let links: [ItemCategoryLink]
}

nonisolated private struct LibraryPublication: Sendable {
    let revision: UInt64
    let snapshot: LibrarySnapshot
}

nonisolated private final class LibraryPublicationClock: TransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var transactionChangedLibrary = false

    func currentRevision() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    func revisionAfterCommit(changedLibrary: Bool) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return changedLibrary ? revision &+ 1 : revision
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        switch eventKind.tableName {
        case "libraryCategory", "libraryItem", "itemCategoryLink":
            return true
        default:
            return false
        }
    }

    func databaseDidChange() {
        markLibraryChanged()
    }

    func databaseDidChange(with event: DatabaseEvent) {
        markLibraryChanged()
    }

    func databaseDidCommit(_ db: Database) {
        _ = db
        lock.lock()
        if transactionChangedLibrary {
            revision &+= 1
            transactionChangedLibrary = false
        }
        lock.unlock()
    }

    func databaseDidRollback(_ db: Database) {
        _ = db
        lock.lock()
        transactionChangedLibrary = false
        lock.unlock()
    }

    private func markLibraryChanged() {
        lock.lock()
        transactionChangedLibrary = true
        lock.unlock()
        stopObservingDatabaseChangesUntilNextTransaction()
    }
}

nonisolated private struct LibraryPublicationOrder: Sendable {
    private(set) var appliedRevision: UInt64 = 0

    mutating func accepts(_ revision: UInt64) -> Bool {
        guard revision >= appliedRevision else { return false }
        appliedRevision = revision
        return true
    }
}

@MainActor
public class LibraryManager: ObservableObject {
    enum DurableMutationError: Error {
        case identifierCollision
    }

    @Published public private(set) var categories: [LibraryCategory] = []
    @Published public private(set) var items: [LibraryItem] = []
    @Published public private(set) var links: [ItemCategoryLink] = []

    @Published public var isLoading: Bool = true
    /// The saved details and edition policies the entire-series filter judges from. A separate observation publishes it.
    @Published private(set) var offlineProofSnapshot = LibraryOfflineProofSnapshot.loading

    private var libraryObserver: DatabaseCancellable?
    private var offlineProofObserver: DatabaseCancellable?
    private let dbPool: DatabasePool
    private let publicationClock = LibraryPublicationClock()
    private var publicationOrder = LibraryPublicationOrder()
    /// Told when removed series take their new-chapter badges with them.
    private weak var updateManager: UpdateManager?

    public convenience init(dbPool: DatabasePool) {
        self.init(
            dbPool: dbPool,
            observationScheduler: DelayedMainActorValueObservationScheduler.mainActor
        )
    }

    init<Scheduler: ValueObservationMainActorScheduler>(
        dbPool: DatabasePool,
        observationScheduler: Scheduler
    ) {
        self.dbPool = dbPool
        dbPool.writeWithoutTransaction { db in
            db.add(transactionObserver: publicationClock, extent: .observerLifetime)
        }
        startObservation(scheduling: observationScheduler)
        startOfflineProofObservation(scheduling: observationScheduler)
    }

    func configure(updateManager: UpdateManager) {
        self.updateManager = updateManager
    }

    public func reload() async throws {
        let revision = publicationClock.currentRevision()
        let snapshot = try await dbPool.read { db in
            try Self.fetchLibrarySnapshot(db)
        }
        apply(LibraryPublication(revision: revision, snapshot: snapshot))
    }

    // MARK: - Phase 3: Reactive State Observation
    private func startObservation<Scheduler: ValueObservationMainActorScheduler>(
        scheduling scheduler: Scheduler
    ) {
        let publicationClock = publicationClock
        var observation = ValueObservation.tracking { db -> LibraryPublication in
            LibraryPublication(
                revision: publicationClock.currentRevision(),
                snapshot: try Self.fetchLibrarySnapshot(db)
            )
        }
        observation.requiresWriteAccess = true

        libraryObserver = observation.start(
            in: dbPool,
            scheduling: scheduler,
            onError: { error in
                AppLogger.database.error("Library observation error: \(error)")
            },
            onChange: { [weak self] publication in
                self?.apply(publication)
            }
        )
    }

    /// The saved details and edition policies, read in an observation of their own. No payload is read here, so a
    /// refresh that changes only its time reaches the proofs without refetching any saved item.
    private func startOfflineProofObservation<Scheduler: ValueObservationMainActorScheduler>(
        scheduling scheduler: Scheduler
    ) {
        let observation = ValueObservation.tracking { db -> LibraryOfflineProofSnapshot in
            let states = try LibrarySnapshotStateRecord.fetchAll(db)
            let preferences = try SeriesEditionPreferenceRecord.fetchAll(db)
            return LibraryOfflineProofSnapshot(
                availability: .available,
                states: Dictionary(states.map { ($0.media, $0) }, uniquingKeysWith: { _, last in last }),
                preferences: Dictionary(
                    preferences.map { ($0.media, $0.selection) },
                    uniquingKeysWith: { _, last in last }
                )
            )
        }
        // Read-only: the proof tables are only read, so the observation needs no write access.
        offlineProofObserver = observation.start(
            in: dbPool,
            scheduling: scheduler,
            onError: { [weak self] _ in
                AppLogger.database.error("Library offline proof observation failed")
                self?.offlineProofSnapshot = .unavailable
            },
            onChange: { [weak self] snapshot in
                self?.offlineProofSnapshot = snapshot
            }
        )
    }

    // MARK: - Saved Media Lookup

    /// The library item saved for this media, matched by identity. The media key is the plugin's
    /// own key: it is never decoded as a local id, even when it looks like one.
    public func savedItemID(media: MediaIdentity) -> String? {
        items.first { $0.mediaIdentity == media }?.id
    }

    // MARK: - Awaitable Media Detail Mutations

    func saveMangaDurably(manga: Manga, pluginId: String) async throws -> String {
        let payload = try JSONEncoder().encode(manga)
        return try await saveItemDurably(
            media: MediaIdentity(pluginId: pluginId, canonicalMediaId: manga.key, mediaKind: .manga),
            item: LibraryItem(
                id: manga.key,
                title: manga.title,
                coverUrl: manga.cover,
                pluginId: pluginId,
                isAnime: false,
                pluginType: .manga,
                rawPayload: payload,
                anilistId: nil,
                knownChapterCount: manga.chapters?.distinctChapterCount ?? 0
            )
        )
    }

    func saveAnimeDurably(anime: Anime, pluginId: String) async throws -> String {
        let payload = try JSONEncoder().encode(anime)
        return try await saveItemDurably(
            media: MediaIdentity(pluginId: pluginId, canonicalMediaId: anime.key, mediaKind: .anime),
            item: LibraryItem(
                id: anime.key,
                title: anime.title,
                coverUrl: anime.cover,
                pluginId: pluginId,
                isAnime: true,
                pluginType: .anime,
                rawPayload: payload,
                anilistId: nil,
                knownChapterCount: anime.episodes?.distinctChapterCount ?? 0
            )
        )
    }

    func saveNovelDurably(novel: Novel, pluginId: String) async throws -> String {
        let payload = try JSONEncoder().encode(novel)
        return try await saveItemDurably(
            media: MediaIdentity(pluginId: pluginId, canonicalMediaId: novel.key, mediaKind: .novel),
            item: LibraryItem(
                id: novel.key,
                title: novel.title,
                coverUrl: novel.cover,
                pluginId: pluginId,
                isAnime: false,
                pluginType: .novel,
                rawPayload: payload,
                anilistId: nil,
                knownChapterCount: novel.chapters?.distinctChapterCount ?? 0
            )
        )
    }

    /// Removes the saved item of this media and its new-chapter badge in one transaction.
    func removeItemDurably(media: MediaIdentity) async throws {
        let candidates = ImportedMediaIdentity.localItemIDs(
            pluginId: media.pluginId,
            canonicalMediaId: media.canonicalMediaId,
            mediaKind: media.mediaKind
        )
        try await removeItemsDurably { db in
            try candidates.compactMap { try LibraryItem.fetchOne(db, key: $0) }
                .filter { $0.mediaIdentity == media }
        }
    }

    /// Removes the library item stored under exactly this id, when it still belongs to this
    /// source and kind, and its new-chapter badge in one transaction.
    func removeItemDurably(itemID: String, pluginId: String, mediaKind: MediaKind) async throws {
        try await removeItemsDurably { db in
            guard let existing = try LibraryItem.fetchOne(db, key: itemID),
                  existing.pluginId == pluginId,
                  existing.effectiveType == mediaKind else { return [] }
            return [existing]
        }
    }

    private func removeItemsDurably(_ select: @escaping @Sendable (Database) throws -> [LibraryItem]) async throws {
        let publicationClock = publicationClock
        let (publication, removedMedia) = try await dbPool.write { db in
            var removedMedia: [MediaIdentity] = []
            for existing in try select(db) {
                try existing.delete(db)
                let media = existing.mediaIdentity
                try UpdateBadgeRecord
                    .filter(Column("pluginId") == media.pluginId)
                    .filter(Column("canonicalMediaId") == media.canonicalMediaId)
                    .filter(Column("mediaKind") == media.mediaKind.rawValue)
                    .deleteAll(db)
                try LibrarySnapshotStateRecord
                    .filter(Column("pluginId") == media.pluginId)
                    .filter(Column("canonicalMediaId") == media.canonicalMediaId)
                    .filter(Column("mediaKind") == media.mediaKind.rawValue)
                    .deleteAll(db)
                // A remembered scanlator choice is for a series in the Library.
                try SeriesEditionPreferenceRecord
                    .filter(Column("pluginId") == media.pluginId)
                    .filter(Column("canonicalMediaId") == media.canonicalMediaId)
                    .filter(Column("mediaKind") == media.mediaKind.rawValue)
                    .deleteAll(db)
                removedMedia.append(media)
            }
            let publication = try Self.makePublication(
                db,
                clock: publicationClock,
                changedLibrary: !removedMedia.isEmpty
            )
            return (publication, removedMedia)
        }
        apply(publication)
        updateManager?.forgetBadges(for: removedMedia)
    }

    // MARK: - Saved Details Snapshot

    /// Names the details saved for this media, to be read before its source is asked for fresh ones.
    /// Nil when the media is not in the Library.
    func snapshotToken(for media: MediaIdentity) async throws -> LibrarySnapshotToken? {
        let candidates = ImportedMediaIdentity.localItemIDs(
            pluginId: media.pluginId,
            canonicalMediaId: media.canonicalMediaId,
            mediaKind: media.mediaKind
        )
        return try await dbPool.read { db in
            for id in candidates {
                guard let item = try LibraryItem.fetchOne(db, key: id),
                      item.mediaIdentity == media else { continue }
                return LibrarySnapshotToken(
                    itemID: item.id,
                    media: media,
                    payloadSHA256: OfflineDigest.sha256Hex(item.rawPayload)
                )
            }
            return nil
        }
    }

    /// Replaces the details saved with a Library item by a refreshed copy, only while the item still holds
    /// the payload the token named, so a refresh that raced a relink, a restore or a new save changes
    /// nothing. The Library title is the user's own and is kept; a refresh without a cover keeps the
    /// saved one. Downloads are untouched, whatever chapters the new list leaves out.
    ///
    /// - Parameter catalog: How the source described the catalog. It is always the one recorded, even when it is
    ///   narrower than the one saved, so the entire-series claim drops as soon as the source reports less. The
    ///   same bytes and cover only record a new refresh time.
    func replaceSnapshotDurably(
        _ token: LibrarySnapshotToken,
        payload: Data,
        coverUrl: String?,
        chapterRowCount: Int,
        catalog: LibraryCatalogDescription = .unknown,
        refreshedAt: Date
    ) async throws -> LibrarySnapshotReplaceOutcome {
        guard chapterRowCount > 0 else { return .rejectedIncomplete }
        guard !Task.isCancelled else { return .stale }
        let publicationClock = publicationClock
        let result = try await dbPool.write { db -> (LibrarySnapshotReplaceOutcome, LibraryPublication?) in
            guard let item = try LibraryItem.fetchOne(db, key: token.itemID),
                  item.mediaIdentity == token.media,
                  OfflineDigest.sha256Hex(item.rawPayload) == token.payloadSHA256 else {
                return (.stale, nil)
            }
            let media = token.media
            let newCover = coverUrl.flatMap { $0.isEmpty ? nil : $0 }
            let payloadDigest = OfflineDigest.sha256Hex(payload)
            // The same bytes and cover change nothing the Library shows: only the refresh time is recorded,
            // and no publication is made.
            let isUnchanged = payloadDigest == token.payloadSHA256 && (newCover == nil || newCover == item.coverUrl)
            if !isUnchanged {
                try db.execute(
                    sql: "UPDATE libraryItem SET rawPayload = ?, coverUrl = COALESCE(?, coverUrl) WHERE id = ?",
                    arguments: [payload, newCover, item.id]
                )
            }
            try LibrarySnapshotStateRecord(
                pluginId: media.pluginId,
                mediaKind: media.mediaKind,
                canonicalMediaId: media.canonicalMediaId,
                payloadSHA256: payloadDigest,
                refreshedAt: refreshedAt,
                catalogScope: catalog.scope,
                catalogCompleteness: catalog.completeness,
                chapterRowCount: chapterRowCount
            ).save(db)
            guard !isUnchanged else { return (.replaced, nil) }
            let publication = try Self.makePublication(db, clock: publicationClock, changedLibrary: true)
            return (.replaced, publication)
        }
        if let publication = result.1 { apply(publication) }
        return result.0
    }

    /// When the details saved for this media were last refreshed. Nil when they never were, and when the
    /// saved payload is not the one that refresh wrote, as after a restore: its age is unknown.
    func snapshotRefreshDate(for media: MediaIdentity) async throws -> Date? {
        let candidates = ImportedMediaIdentity.localItemIDs(
            pluginId: media.pluginId,
            canonicalMediaId: media.canonicalMediaId,
            mediaKind: media.mediaKind
        )
        return try await dbPool.read { db in
            let state = try LibrarySnapshotStateRecord
                .filter(Column("pluginId") == media.pluginId)
                .filter(Column("canonicalMediaId") == media.canonicalMediaId)
                .filter(Column("mediaKind") == media.mediaKind.rawValue)
                .fetchOne(db)
            guard let state else { return nil }
            for id in candidates {
                guard let item = try LibraryItem.fetchOne(db, key: id),
                      item.mediaIdentity == media else { continue }
                return OfflineDigest.sha256Hex(item.rawPayload) == state.payloadSHA256 ? state.refreshedAt : nil
            }
            return nil
        }
    }

    /// What the saved details say about the series' catalog, with the digest of the payload saved now. Nil
    /// when no refresh was ever recorded for the series, or it is not in the Library.
    func snapshotBasis(for media: MediaIdentity) async throws -> LibrarySnapshotBasis? {
        let candidates = ImportedMediaIdentity.localItemIDs(
            pluginId: media.pluginId,
            canonicalMediaId: media.canonicalMediaId,
            mediaKind: media.mediaKind
        )
        return try await dbPool.read { db in
            let state = try LibrarySnapshotStateRecord
                .filter(Column("pluginId") == media.pluginId)
                .filter(Column("canonicalMediaId") == media.canonicalMediaId)
                .filter(Column("mediaKind") == media.mediaKind.rawValue)
                .fetchOne(db)
            guard let state else { return nil }
            for id in candidates {
                guard let item = try LibraryItem.fetchOne(db, key: id),
                      item.mediaIdentity == media else { continue }
                let digest = OfflineDigest.sha256Hex(item.rawPayload)
                // The rows only back a claim about the entire series, which needs a complete catalog that this
                // payload was saved with; for anything else they are not read.
                let backsClaim = state.coversEntireSeries && state.payloadSHA256 == digest
                return LibrarySnapshotBasis(
                    snapshot: state.offlineSnapshot,
                    currentPayloadSHA256: digest,
                    catalog: backsClaim ? Self.savedCatalog(payload: item.rawPayload, kind: item.effectiveType) : []
                )
            }
            return nil
        }
    }

    /// The one decoder for a saved catalog, shared by the detail basis and the Library's entire-series filter.
    /// A payload that cannot be read has no rows, which can never back a claim about the entire series.
    nonisolated static func savedCatalog(payload: Data, kind: MediaKind) -> [ChapterFacts] {
        let decoder = JSONDecoder()
        let chapters: [Chapter]?
        switch kind {
        case .manga: chapters = (try? decoder.decode(Manga.self, from: payload))?.chapters
        case .novel: chapters = (try? decoder.decode(Novel.self, from: payload))?.chapters
        case .anime: chapters = nil
        }
        return (chapters ?? []).map { ChapterFacts($0) }
    }

    private func saveItemDurably(
        media: MediaIdentity,
        item: LibraryItem
    ) async throws -> String {
        let candidateIDs = ImportedMediaIdentity.localItemIDs(
            pluginId: media.pluginId,
            canonicalMediaId: media.canonicalMediaId,
            mediaKind: media.mediaKind
        )
        let publicationClock = publicationClock
        let mutation = try await dbPool.write { db in
            var occupants: [String: LibraryItem] = [:]
            for id in candidateIDs {
                occupants[id] = try LibraryItem.fetchOne(db, key: id)
            }
            // Only an item of exactly this media is reused; another media of the same source
            // and kind may hold one of the candidate ids.
            let ownedItem = candidateIDs
                .compactMap { occupants[$0] }
                .first { $0.mediaIdentity == media }
            let storedItem: LibraryItem
            if let ownedItem {
                storedItem = ownedItem
            } else {
                guard let id = ImportedMediaIdentity.newItemID(
                    preferred: nil,
                    pluginId: media.pluginId,
                    canonicalMediaId: media.canonicalMediaId,
                    mediaKind: media.mediaKind,
                    occupant: { occupants[$0].map { ($0.pluginId, $0.effectiveType) } }
                ) else {
                    throw DurableMutationError.identifierCollision
                }
                storedItem = item.id == id ? item : Self.copy(item, replacingIDWith: id)
                try storedItem.insert(db)
                if let uncategorized = try LibraryCategory
                    .filter(Column("isSystemCategory") == true)
                    .fetchOne(db) {
                    try ItemCategoryLink(
                        itemId: storedItem.id,
                        categoryId: uncategorized.id
                    ).insert(db)
                }
            }
            let publication = try Self.makePublication(
                db,
                clock: publicationClock,
                changedLibrary: ownedItem == nil
            )
            return (publication, storedItem.id)
        }
        apply(mutation.0)
        return mutation.1
    }

    nonisolated private static func copy(
        _ item: LibraryItem,
        replacingIDWith id: String
    ) -> LibraryItem {
        LibraryItem(
            id: id,
            title: item.title,
            coverUrl: item.coverUrl,
            pluginId: item.pluginId,
            isAnime: item.isAnime,
            pluginType: item.pluginType,
            rawPayload: item.rawPayload,
            anilistId: item.anilistId,
            status: item.status,
            lastCheckedAt: item.lastCheckedAt,
            lastUpdatedAt: item.lastUpdatedAt,
            knownChapterCount: item.knownChapterCount
        )
    }

    nonisolated private static func fetchLibrarySnapshot(
        _ db: Database
    ) throws -> LibrarySnapshot {
        LibrarySnapshot(
            categories: try LibraryCategory.order(Column("sortOrder")).fetchAll(db),
            // Finder-style order: case-insensitive, with numbers compared by value.
            items: try LibraryItem.order(Column("title").collating(.localizedStandardCompare)).fetchAll(db),
            links: try ItemCategoryLink.fetchAll(db)
        )
    }

    nonisolated private static func makePublication(
        _ db: Database,
        clock: LibraryPublicationClock,
        changedLibrary: Bool
    ) throws -> LibraryPublication {
        LibraryPublication(
            revision: clock.revisionAfterCommit(changedLibrary: changedLibrary),
            snapshot: try fetchLibrarySnapshot(db)
        )
    }

    private func apply(_ publication: LibraryPublication) {
        guard publicationOrder.accepts(publication.revision) else { return }
        categories = publication.snapshot.categories
        items = publication.snapshot.items
        links = publication.snapshot.links
        isLoading = false
    }

    // MARK: - Category CRUD

    public func createCategory(name: String) async throws -> String {
        let publicationClock = publicationClock
        let result = try await dbPool.write { db in
            let maxOrder = try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM libraryCategory") ?? 0
            let newCat = LibraryCategory(name: name, sortOrder: maxOrder + 1)
            try newCat.insert(db)
            let publication = try Self.makePublication(
                db,
                clock: publicationClock,
                changedLibrary: true
            )
            return (newCat.id, publication)
        }
        apply(result.1)
        return result.0
    }

    public func renameCategory(id: String, to name: String) async throws {
        let publicationClock = publicationClock
        let publication = try await dbPool.write { db in
            guard var category = try LibraryCategory.fetchOne(db, key: id) else {
                throw LibraryCategory.recordNotFound(key: ["id": id])
            }
            category.name = name
            try category.update(db)
            return try Self.makePublication(
                db,
                clock: publicationClock,
                changedLibrary: true
            )
        }
        apply(publication)
    }

    func deleteCategoryDurably(id: String) async throws {
        let publicationClock = publicationClock
        let publication = try await dbPool.write { db in
            guard let category = try LibraryCategory.fetchOne(db, key: id),
                  !category.isSystemCategory else {
                return try Self.makePublication(
                    db,
                    clock: publicationClock,
                    changedLibrary: false
                )
            }
            try category.delete(db)

            if let systemID = try LibraryCategory
                .filter(Column("isSystemCategory") == true)
                .fetchOne(db)?.id {
                let orphanedItems = try LibraryItem.fetchAll(db, sql: """
                    SELECT libraryItem.* FROM libraryItem
                    LEFT JOIN itemCategoryLink ON libraryItem.id = itemCategoryLink.itemId
                    WHERE itemCategoryLink.categoryId IS NULL
                    """)
                for item in orphanedItems {
                    try ItemCategoryLink(itemId: item.id, categoryId: systemID).insert(db)
                }
            }
            return try Self.makePublication(
                db,
                clock: publicationClock,
                changedLibrary: true
            )
        }
        apply(publication)
    }

    func toggleCategoryDurably(forItemID itemID: String, categoryID: String) async throws {
        let publicationClock = publicationClock
        let publication = try await dbPool.write { db in
            let systemCategory = try LibraryCategory
                .filter(Column("isSystemCategory") == true)
                .fetchOne(db)
            if let existing = try ItemCategoryLink.fetchOne(
                db,
                key: ["itemId": itemID, "categoryId": categoryID]
            ) {
                try existing.delete(db)
                let remaining = try ItemCategoryLink
                    .filter(Column("itemId") == itemID)
                    .fetchCount(db)
                if remaining == 0, let systemID = systemCategory?.id {
                    try ItemCategoryLink(itemId: itemID, categoryId: systemID).insert(db)
                }
            } else {
                try ItemCategoryLink(itemId: itemID, categoryId: categoryID).insert(db)
                if let systemID = systemCategory?.id, categoryID != systemID,
                   let uncategorizedLink = try ItemCategoryLink.fetchOne(
                       db,
                       key: ["itemId": itemID, "categoryId": systemID]
                   ) {
                    try uncategorizedLink.delete(db)
                }
            }
            return try Self.makePublication(
                db,
                clock: publicationClock,
                changedLibrary: true
            )
        }
        apply(publication)
    }

    func reorderCategoriesDurably(userCategoryIDs: [String]) async throws {
        let publicationClock = publicationClock
        let publication = try await dbPool.write { db in
            let current = try LibraryCategory.order(Column("sortOrder")).fetchAll(db)
            let systemCategories = current.filter(\.isSystemCategory)
            let userCategories = current.filter { !$0.isSystemCategory }
            let currentIDs = Set(userCategories.map(\.id))
            guard currentIDs.count == userCategoryIDs.count,
                  currentIDs == Set(userCategoryIDs) else {
                throw DurableMutationError.identifierCollision
            }
            let categoriesByID = Dictionary(uniqueKeysWithValues: userCategories.map { ($0.id, $0) })
            let ordered = systemCategories + userCategoryIDs.compactMap { categoriesByID[$0] }
            for (index, category) in ordered.enumerated() {
                var updated = category
                updated.sortOrder = index
                try updated.update(db)
            }
            return try Self.makePublication(
                db,
                clock: publicationClock,
                changedLibrary: !ordered.isEmpty
            )
        }
        apply(publication)
    }

    func createCategoryAndAssignDurably(name: String, itemID: String) async throws -> String {
        let publicationClock = publicationClock
        let result = try await dbPool.write { db in
            let maxOrder = try Int.fetchOne(
                db,
                sql: "SELECT MAX(sortOrder) FROM libraryCategory"
            ) ?? 0
            let category = LibraryCategory(name: name, sortOrder: maxOrder + 1)
            try category.insert(db)
            try ItemCategoryLink(itemId: itemID, categoryId: category.id).insert(db)
            if let systemID = try LibraryCategory
                .filter(Column("isSystemCategory") == true)
                .fetchOne(db)?.id,
               let uncategorizedLink = try ItemCategoryLink.fetchOne(
                   db,
                   key: ["itemId": itemID, "categoryId": systemID]
               ) {
                try uncategorizedLink.delete(db)
            }
            let publication = try Self.makePublication(
                db,
                clock: publicationClock,
                changedLibrary: true
            )
            return (category.id, publication)
        }
        apply(result.1)
        return result.0
    }

}
