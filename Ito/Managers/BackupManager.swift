import Foundation
import Combine
import GRDB
import ito_runner
import OSLog
import SystemConfiguration

nonisolated enum BackupMergeError: Error, Equatable {
    case ambiguousLocalIdentity(
        pluginId: String,
        canonicalMediaId: String,
        localItemIds: [String]
    )
    case invalidReplacementCategoryReference(
        itemId: String,
        categoryId: String
    )
    case noFreeLibraryID(pluginId: String, canonicalMediaId: String)
}

nonisolated struct BackupMergeResult: Sendable, Equatable {
    let insertedItemCount: Int
    let insertedHistoryCount: Int
    let skippedUnassociatedOrAmbiguousHistoryCount: Int
    let skippedByPolicyHistoryCount: Int
    let skippedDuplicateHistoryCount: Int
    let persistedTargetIdsByImportedItemId: [String: String]

    var consideredHistoryCount: Int {
        insertedHistoryCount
            + skippedUnassociatedOrAmbiguousHistoryCount
            + skippedByPolicyHistoryCount
            + skippedDuplicateHistoryCount
    }

    func retargetedMigrationReport(_ report: MigrationReport?) -> MigrationReport? {
        report?.retargetingAffectedItemIds(using: persistedTargetIdsByImportedItemId)
    }
}

nonisolated struct BackupMergeOperation: Sendable {
    nonisolated private struct ItemDisposition: Sendable {
        let importedItem: LibraryItem
        let targetId: String
        let isPreexisting: Bool
    }

    nonisolated private struct DispositionIndex: Sendable {
        let dispositions: [ItemDisposition]
        private let direct: [String: [Int]]
        private let aliases: [String: [Int]]
        private let canonical: [ImportedMediaIdentity.Key: [Int]]

        init(_ dispositions: [ItemDisposition]) {
            self.dispositions = dispositions
            var direct: [String: [Int]] = [:]
            var aliases: [String: [Int]] = [:]
            var canonical: [ImportedMediaIdentity.Key: [Int]] = [:]

            for (index, disposition) in dispositions.enumerated() {
                let item = disposition.importedItem
                let key = ImportedMediaIdentity.key(
                    itemId: item.id,
                    pluginId: item.pluginId,
                    mediaKind: item.effectiveType
                )
                direct[item.id, default: []].append(index)
                canonical[key, default: []].append(index)
                for alias in Set([item.id, key.canonicalMediaId, "\(item.pluginId)_\(key.canonicalMediaId)"]) {
                    aliases[alias, default: []].append(index)
                }
            }

            self.direct = direct
            self.aliases = aliases
            self.canonical = canonical
        }

        func disposition(for identifier: String) -> ItemDisposition? {
            if let directMatches = direct[identifier], directMatches.count == 1 {
                return dispositions[directMatches[0]]
            }
            guard let matches = aliases[identifier], matches.count == 1 else { return nil }
            return dispositions[matches[0]]
        }

        func disposition(for history: ReadingHistoryRecord) -> ItemDisposition? {
            var matches = Set<Int>()
            for identifier in [history.libraryItemId, history.mediaKey].compactMap({ $0 }) {
                let key = ImportedMediaIdentity.key(
                    itemId: identifier,
                    pluginId: history.pluginId,
                    mediaKind: history.mediaKind
                )
                matches.formUnion(canonical[key] ?? [])
            }
            guard matches.count == 1, let match = matches.first else { return nil }
            return dispositions[match]
        }
    }

    nonisolated private struct LibraryItemIdentityIndex: Sendable {
        private let itemsByIdentity: [ImportedMediaIdentity.Key: [LibraryItem]]

        init(_ items: [LibraryItem]) {
            itemsByIdentity = Dictionary(grouping: items) {
                ImportedMediaIdentity.key(itemId: $0.id, pluginId: $0.pluginId, mediaKind: $0.effectiveType)
            }
        }

        func uniqueIdentity(for history: ReadingHistoryRecord) -> ImportedMediaIdentity.Key? {
            var itemIds = Set<String>()
            var identityByItemId: [String: ImportedMediaIdentity.Key] = [:]
            for identifier in [history.libraryItemId, history.mediaKey].compactMap({ $0 }) {
                let key = ImportedMediaIdentity.key(
                    itemId: identifier,
                    pluginId: history.pluginId,
                    mediaKind: history.mediaKind
                )
                for item in itemsByIdentity[key] ?? [] {
                    itemIds.insert(item.id)
                    identityByItemId[item.id] = key
                }
            }
            guard itemIds.count == 1, let itemId = itemIds.first else { return nil }
            return identityByItemId[itemId]
        }
    }

    nonisolated private struct HistorySemanticKey: Hashable {
        let mediaIdentity: ImportedMediaIdentity.Key
        let chapterKey: String
        let readAt: Date
    }

    let dbPool: DatabasePool

    func analyze(_ importedBackup: ImportedBackup) async throws -> [MergeConflict] {
        try await dbPool.read { db in
            let localCategories = try LibraryCategory.fetchAll(db)
            let localLinks = try ItemCategoryLink.fetchAll(db)
            let localItems = try LibraryItem.fetchAll(db)
            let localHistory = try ReadingHistoryRecord.fetchAll(db)
            let dispositions = try makeDispositions(
                importedItems: importedBackup.items,
                localItems: localItems
            )
            let dispositionIndex = DispositionIndex(dispositions)
            let localItemsById = Dictionary(uniqueKeysWithValues: localItems.map { ($0.id, $0) })
            let localCategoriesById = Dictionary(uniqueKeysWithValues: localCategories.map { ($0.id, $0) })
            let backupCategoriesById = Dictionary(uniqueKeysWithValues: importedBackup.categories.map { ($0.id, $0) })
            let localLinksByItemId = Dictionary(grouping: localLinks, by: \.itemId)
            let backupLinksByTargetId = Dictionary(grouping: importedBackup.links.compactMap { link in
                dispositionIndex.disposition(for: link.itemId).map { ($0.targetId, link) }
            }, by: { $0.0 })
            let localHistoryCounts = Dictionary(grouping: localHistory.compactMap { history in
                dispositionIndex.disposition(for: history)?.targetId
            }, by: { $0 }).mapValues(\.count)
            let backupHistoryCounts = Dictionary(grouping: importedBackup.history.compactMap { history in
                dispositionIndex.disposition(for: history)?.targetId
            }, by: { $0 }).mapValues(\.count)

            return dispositions.compactMap { disposition in
                guard disposition.isPreexisting,
                      let localItem = localItemsById[disposition.targetId]
                else { return nil }

                let localLink = localLinksByItemId[disposition.targetId]?.first
                let backupLink = backupLinksByTargetId[disposition.targetId]?.first?.1
                let localCategory = localLink.flatMap { localCategoriesById[$0.categoryId]?.name }
                let backupCategory = backupLink.flatMap { backupCategoriesById[$0.categoryId]?.name }
                let localHistoryCount = localHistoryCounts[disposition.targetId] ?? 0
                let backupHistoryCount = backupHistoryCounts[disposition.targetId] ?? 0

                guard localCategory != backupCategory || localHistoryCount != backupHistoryCount else {
                    return nil
                }
                return MergeConflict(
                    item: localItem,
                    localCategoryName: localCategory,
                    backupCategoryName: backupCategory,
                    localHistoryCount: localHistoryCount,
                    backupHistoryCount: backupHistoryCount
                )
            }
        }
    }

    func restore(
        _ importedBackup: ImportedBackup,
        mode: BackupRestoreMode,
        resolvedConflicts: [String: ConflictResolution] = [:]
    ) async throws -> BackupMergeResult {
        try await dbPool.write { db in
            let localItems = try LibraryItem.fetchAll(db)
            let dispositions = try makeDispositions(
                importedItems: importedBackup.items,
                localItems: mode == .merge ? localItems : []
            )
            let dispositionIndex = DispositionIndex(dispositions)
            let currentSystemId = try LibraryCategory
                .filter(Column("isSystemCategory") == true)
                .fetchOne(db)?.id
            let backupSystemId = importedBackup.categories.first(where: \.isSystemCategory)?.id

            if mode == .wipe {
                try ReadingHistoryRecord.deleteAll(db)
                try ItemCategoryLink.deleteAll(db)
                try LibraryItem.deleteAll(db)
                try LibraryCategory.filter(Column("isSystemCategory") == false).deleteAll(db)
            }

            for category in importedBackup.categories where !category.isSystemCategory {
                if mode == .merge {
                    if try LibraryCategory.fetchOne(db, key: category.id) == nil {
                        try category.insert(db)
                    }
                } else {
                    try category.save(db)
                }
            }

            let groupedLinks = Dictionary(grouping: importedBackup.links.compactMap { link -> (ItemDisposition, ItemCategoryLink)? in
                guard let disposition = dispositionIndex.disposition(for: link.itemId) else { return nil }
                let categoryId = link.categoryId == backupSystemId ? (currentSystemId ?? link.categoryId) : link.categoryId
                return (
                    disposition,
                    ItemCategoryLink(itemId: disposition.targetId, categoryId: categoryId, addedAt: link.addedAt)
                )
            }, by: { $0.0.targetId })
            let validCategoryIds = Set(try String.fetchAll(db, sql: "SELECT id FROM libraryCategory"))

            for (targetId, linkEntries) in groupedLinks {
                guard linkEntries.first?.0.isPreexisting == true,
                      keepsBackup(resolvedConflicts[targetId])
                else { continue }
                for (_, link) in linkEntries where !validCategoryIds.contains(link.categoryId) {
                    throw BackupMergeError.invalidReplacementCategoryReference(
                        itemId: targetId,
                        categoryId: link.categoryId
                    )
                }
            }

            var insertedItemCount = 0
            for disposition in dispositions {
                if disposition.isPreexisting {
                    if keepsBackup(resolvedConflicts[disposition.targetId]) {
                        try retarget(disposition.importedItem, to: disposition.targetId).update(db)
                    }
                } else {
                    try retarget(disposition.importedItem, to: disposition.targetId).insert(db)
                    insertedItemCount += 1
                }
            }

            var existingCategoryIdsByItemId: [String: Set<String>] = [:]
            for link in try ItemCategoryLink.fetchAll(db) {
                existingCategoryIdsByItemId[link.itemId, default: []].insert(link.categoryId)
            }

            for (targetId, linkEntries) in groupedLinks {
                guard let disposition = linkEntries.first?.0 else { continue }
                if disposition.isPreexisting {
                    guard keepsBackup(resolvedConflicts[targetId]) else { continue }
                    try ItemCategoryLink.filter(Column("itemId") == targetId).deleteAll(db)
                    existingCategoryIdsByItemId[targetId] = []
                }
                for (_, link) in linkEntries {
                    guard validCategoryIds.contains(link.categoryId) else { continue }
                    if existingCategoryIdsByItemId[link.itemId, default: []]
                        .insert(link.categoryId).inserted {
                        try link.insert(db)
                    }
                }
            }

            var existingHistoryIds = Set(try String.fetchAll(
                db,
                sql: "SELECT id FROM readingHistory"
            ))
            let persistedHistory = try ReadingHistoryRecord.fetchAll(db)
            let localItemIdentityIndex = LibraryItemIdentityIndex(localItems)
            var semanticKeys = Set(persistedHistory.map { history in
                let identity = localItemIdentityIndex.uniqueIdentity(for: history)
                    ?? ImportedMediaIdentity.key(
                        itemId: history.mediaKey,
                        pluginId: history.pluginId,
                        mediaKind: history.mediaKind
                    )
                return HistorySemanticKey(
                    mediaIdentity: identity,
                    chapterKey: history.chapterKey,
                    readAt: history.readAt
                )
            })
            var insertedHistoryCount = 0
            var skippedUnassociatedOrAmbiguousHistoryCount = 0
            var skippedByPolicyHistoryCount = 0
            var skippedDuplicateHistoryCount = 0

            for history in importedBackup.history {
                if mode == .wipe {
                    var rewritten = history
                    if let disposition = dispositionIndex.disposition(for: history) {
                        rewritten.libraryItemId = disposition.targetId
                        rewritten.mediaKey = disposition.targetId
                    }
                    try rewritten.save(db)
                    insertedHistoryCount += 1
                    continue
                }
                guard let disposition = dispositionIndex.disposition(for: history) else {
                    skippedUnassociatedOrAmbiguousHistoryCount += 1
                    continue
                }
                if disposition.isPreexisting,
                   !keepsBackup(resolvedConflicts[disposition.targetId]) {
                    skippedByPolicyHistoryCount += 1
                    continue
                }

                let semanticKey = HistorySemanticKey(
                    mediaIdentity: ImportedMediaIdentity.key(
                        itemId: disposition.importedItem.id,
                        pluginId: disposition.importedItem.pluginId,
                        mediaKind: disposition.importedItem.effectiveType
                    ),
                    chapterKey: history.chapterKey,
                    readAt: history.readAt
                )
                guard !existingHistoryIds.contains(history.id), !semanticKeys.contains(semanticKey) else {
                    skippedDuplicateHistoryCount += 1
                    continue
                }

                var rewritten = history
                rewritten.libraryItemId = disposition.targetId
                rewritten.mediaKey = disposition.targetId
                try rewritten.insert(db)
                existingHistoryIds.insert(rewritten.id)
                semanticKeys.insert(semanticKey)
                insertedHistoryCount += 1
            }

            if mode == .wipe {
                try AppPreference.deleteAll(db)
            }
            for preference in importedBackup.preferences {
                try preference.save(db)
            }

            let result = BackupMergeResult(
                insertedItemCount: insertedItemCount,
                insertedHistoryCount: insertedHistoryCount,
                skippedUnassociatedOrAmbiguousHistoryCount: skippedUnassociatedOrAmbiguousHistoryCount,
                skippedByPolicyHistoryCount: skippedByPolicyHistoryCount,
                skippedDuplicateHistoryCount: skippedDuplicateHistoryCount,
                persistedTargetIdsByImportedItemId: dispositions.reduce(into: [:]) { mapping, disposition in
                    mapping[disposition.importedItem.id] = disposition.targetId
                }
            )
            precondition(result.consideredHistoryCount == importedBackup.history.count)
            return result
        }
    }

    private func makeDispositions(
        importedItems: [LibraryItem],
        localItems: [LibraryItem]
    ) throws -> [ItemDisposition] {
        let localIndex = Dictionary(grouping: localItems) {
            ImportedMediaIdentity.key(itemId: $0.id, pluginId: $0.pluginId, mediaKind: $0.effectiveType)
        }
        // Ids already taken, so a new item never lands on (and replaces) a different series.
        var occupants = Dictionary(
            localItems.map { ($0.id, (pluginId: $0.pluginId, mediaKind: $0.effectiveType)) },
            uniquingKeysWith: { first, _ in first }
        )
        return try importedItems.map { importedItem in
            let identity = ImportedMediaIdentity.key(
                itemId: importedItem.id,
                pluginId: importedItem.pluginId,
                mediaKind: importedItem.effectiveType
            )
            let matches = localIndex[identity] ?? []
            guard matches.count <= 1 else {
                throw BackupMergeError.ambiguousLocalIdentity(
                    pluginId: identity.pluginId,
                    canonicalMediaId: identity.canonicalMediaId,
                    localItemIds: matches.map(\.id).sorted()
                )
            }
            if let match = matches.first {
                return ItemDisposition(importedItem: importedItem, targetId: match.id, isPreexisting: true)
            }
            guard let targetId = ImportedMediaIdentity.newItemID(
                preferred: importedItem.id,
                pluginId: identity.pluginId,
                canonicalMediaId: identity.canonicalMediaId,
                mediaKind: identity.mediaKind,
                occupant: { occupants[$0] }
            ) else {
                throw BackupMergeError.noFreeLibraryID(
                    pluginId: identity.pluginId,
                    canonicalMediaId: identity.canonicalMediaId
                )
            }
            occupants[targetId] = (pluginId: identity.pluginId, mediaKind: identity.mediaKind)
            return ItemDisposition(importedItem: importedItem, targetId: targetId, isPreexisting: false)
        }
    }

    private func retarget(_ item: LibraryItem, to id: String) -> LibraryItem {
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

    private func keepsBackup(_ resolution: ConflictResolution?) -> Bool {
        if case .keepBackup = resolution { return true }
        return false
    }
}

@MainActor
public class BackupManager: ObservableObject {
    @Published public private(set) var isExporting: Bool = false
    @Published public private(set) var isRestoring: Bool = false
    @Published public private(set) var lastRestoreReport: BackupRestoreReport?
    @Published public private(set) var committedRefreshPendingOperationId: String?

    private let dbPool: DatabasePool
    private let sourceDatabaseURL: URL
    private let exportReadiness: BackupExportOperation.ReadinessGate
    private let restoreRefresher: BackupRestoreRefresher
    private let pluginSecrets: PluginSecretStore
    private let onAllReportsAcknowledged: @MainActor @Sendable () async throws -> Void
    private var acknowledgmentInFlight = false
    private var registeredImporters: [BackupImporter] = [ItoNativeImporter()]

    public init(
        dbPool: DatabasePool,
        sourceDatabaseURL: URL,
        exportReadiness: @escaping BackupExportOperation.ReadinessGate,
        restoreRefresher: BackupRestoreRefresher,
        pluginSecrets: PluginSecretStore,
        onAllReportsAcknowledged: @escaping @MainActor @Sendable () async throws -> Void = {}
    ) {
        self.dbPool = dbPool
        self.sourceDatabaseURL = sourceDatabaseURL
        self.exportReadiness = exportReadiness
        self.restoreRefresher = restoreRefresher
        self.pluginSecrets = pluginSecrets
        self.onAllReportsAcknowledged = onAllReportsAcknowledged
    }

    func configure(pluginResolver: PluginResolver) {
        registeredImporters = [
            AidokuImporter(resolver: pluginResolver),
            PaperbackImporter(resolver: pluginResolver),
            ItoNativeImporter()
        ]
    }

    private func parseBackup(url: URL) async throws -> ImportedBackup {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }

        for importer in registeredImporters {
            if importer.canHandle(url: url) {
                return try await importer.parse(url: url)
            }
        }
        throw URLError(.cannotDecodeRawData)
    }

    /// Exports the current AppDatabase to a temporary .itobackup file and returns its URL.
    public func createBackupFile() async throws -> URL {
        isExporting = true
        defer { isExporting = false }

        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let backupFileName = "Ito_Backup_\(Int(Date().timeIntervalSince1970)).itobackup"
        let backupFileURL = tempDir.appendingPathComponent(backupFileName)

        if fileManager.fileExists(atPath: backupFileURL.path) {
            try fileManager.removeItem(at: backupFileURL)
        }

        try await BackupExportOperation(
            dbPool: dbPool,
            sourceDatabaseURL: sourceDatabaseURL,
            readinessGate: exportReadiness
        ).export(to: backupFileURL)

        return backupFileURL
    }

    public func analyzeMerge(from url: URL) async throws -> [MergeConflict] {
        let importedBackup = try await parseBackup(url: url)
        return try await BackupMergeOperation(dbPool: dbPool)
            .analyze(importedBackup)
    }

    public func restoreBackup(
        from url: URL,
        mode: BackupRestoreMode,
        resolvedConflicts: [String: ConflictResolution] = [:]
    ) async throws -> BackupRestoreReport {
        isRestoring = true
        defer { isRestoring = false }

        let importedBackup = try await parseBackup(url: url)
        let committedReport = try await ComponentAwareBackupRestoreOperation(
            dbPool: dbPool
        ).restore(
            importedBackup,
            mode: mode,
            resolvedConflicts: resolvedConflicts
        )
        if mode == .wipe {
            // Backups never carry plugin secrets, so a restore that replaces everything replaces
            // them with nothing too. The restore is already committed, so a failure here is logged.
            do {
                try pluginSecrets.removeAll()
            } catch {
                AppLogger.plugin.error("Plugin secrets could not be cleared after a wipe restore.")
            }
        }
        do {
            let report = try await restoreRefresher.refreshCommittedRestore(
                operationId: committedReport.operationId
            )
            committedRefreshPendingOperationId = nil
            lastRestoreReport = try await restoreRefresher.loadReadyToPresentReport()
            return report
        } catch {
            committedRefreshPendingOperationId = committedReport.operationId
            lastRestoreReport = nil
            throw BackupRestoreError.restoreCommittedRefreshPending(
                operationId: committedReport.operationId
            )
        }
    }

    public func retryCommittedRefresh() async throws {
        guard let operationId = committedRefreshPendingOperationId else { return }
        _ = try await restoreRefresher.refreshCommittedRestore(operationId: operationId)
        committedRefreshPendingOperationId = nil
        lastRestoreReport = try await restoreRefresher.loadReadyToPresentReport()
    }

    public func loadReadyReportForPresentation() async throws {
        lastRestoreReport = try await restoreRefresher.loadReadyToPresentReport()
    }

    @discardableResult
    public func acknowledgeRestoreReport() async throws -> Bool {
        guard !acknowledgmentInFlight, let report = lastRestoreReport else {
            return false
        }
        acknowledgmentInFlight = true
        defer { acknowledgmentInFlight = false }
        let acknowledged = try await restoreRefresher.acknowledgeReadyToPresent(
            operationId: report.operationId
        )
        lastRestoreReport = try await restoreRefresher.loadReadyToPresentReport()
        if acknowledged, lastRestoreReport == nil {
            try await onAllReportsAcknowledged()
        }
        return acknowledged
    }
}
