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

    private var libraryObserver: DatabaseCancellable?
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

    // MARK: - Saved Media Lookup

    public func savedItemID(sourceItemID: String, pluginId: String, mediaKind: MediaKind) -> String? {
        let rawID = ImportedMediaIdentity.canonicalMediaId(itemId: sourceItemID, pluginId: pluginId, mediaKind: mediaKind)
        let candidateIDs = [
            sourceItemID,
            rawID,
            "\(pluginId)_\(rawID)",
            "\(pluginId)\u{1F}\(mediaKind.rawValue)\u{1F}\(rawID)"
        ]
        return items.first { item in
            item.pluginId == pluginId && item.effectiveType == mediaKind && candidateIDs.contains(item.id)
        }?.id
    }

    // MARK: - Awaitable Media Detail Mutations

    func saveMangaDurably(manga: Manga, pluginId: String) async throws -> String {
        let payload = try JSONEncoder().encode(manga)
        return try await saveItemDurably(
            sourceItemID: manga.key,
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
            sourceItemID: anime.key,
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
            sourceItemID: novel.key,
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

    /// Removes a series and its new-chapter badge in one transaction.
    func removeItemDurably(id: String, pluginId: String, mediaKind: MediaKind) async throws {
        let rawID = ImportedMediaIdentity.canonicalMediaId(itemId: id, pluginId: pluginId, mediaKind: mediaKind)
        let candidates = ImportedMediaIdentity.localItemIDs(pluginId: pluginId, canonicalMediaId: rawID, mediaKind: mediaKind)
        let publicationClock = publicationClock
        let (publication, removedMedia) = try await dbPool.write { db in
            var removedMedia: [MediaIdentity] = []
            for candidateID in candidates {
                guard let existing = try LibraryItem.fetchOne(db, key: candidateID),
                      existing.pluginId == pluginId,
                      existing.effectiveType == mediaKind else { continue }
                try existing.delete(db)
                let media = MediaIdentity(pluginId: pluginId, canonicalMediaId: rawID, mediaKind: mediaKind)
                try UpdateBadgeRecord
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

    private func saveItemDurably(
        sourceItemID: String,
        item: LibraryItem
    ) async throws -> String {
        let rawID = ImportedMediaIdentity.canonicalMediaId(itemId: sourceItemID, pluginId: item.pluginId, mediaKind: item.effectiveType)
        let candidateIDs = ImportedMediaIdentity.localItemIDs(
            pluginId: item.pluginId,
            canonicalMediaId: rawID,
            mediaKind: item.effectiveType
        )
        let publicationClock = publicationClock
        let mutation = try await dbPool.write { db in
            var occupants: [String: LibraryItem] = [:]
            for id in candidateIDs {
                occupants[id] = try LibraryItem.fetchOne(db, key: id)
            }
            let ownedItem = candidateIDs
                .compactMap { occupants[$0] }
                .first { $0.pluginId == item.pluginId && $0.effectiveType == item.effectiveType }
            let storedItem: LibraryItem
            if let ownedItem {
                storedItem = ownedItem
            } else {
                guard let id = ImportedMediaIdentity.newItemID(
                    preferred: nil,
                    pluginId: item.pluginId,
                    canonicalMediaId: rawID,
                    mediaKind: item.effectiveType,
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
