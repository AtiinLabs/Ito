import Combine
import Foundation
import GRDB
import ito_runner

public final class LibrarySourceRemapper: ObservableObject, @unchecked Sendable {
    nonisolated struct Result: Equatable, Sendable {
        let remappedItemCount: Int
        let movedLinkCount: Int
        let movedHistoryCount: Int
    }

    nonisolated enum RemapError: Error, Equatable, LocalizedError {
        case sourceNotFound(String)
        case sourceOwnershipMismatch(itemId: String, expectedPluginId: String, actualPluginId: String)
        case noOpMapping(itemId: String)
        case destinationExists(String)
        case intraBatchDestinationCollision(destinationId: String, sourceItemIds: [String])
        case ambiguousHistoryAssociation(historyId: String, sourceItemIds: [String])
        case mediaStateDestinationCollision(table: String, canonicalMediaId: String)

        var errorDescription: String? {
            switch self {
            case .sourceNotFound(let itemId):
                return "The imported library item \"\(itemId)\" no longer exists."
            case .sourceOwnershipMismatch(let itemId, let expected, let actual):
                return "Library item \"\(itemId)\" belongs to \"\(actual)\", not \"\(expected)\"."
            case .noOpMapping(let itemId):
                return "Remapping \"\(itemId)\" would not change its identifier."
            case .destinationExists(let itemId):
                return "A library item already exists at the destination \"\(itemId)\"."
            case .intraBatchDestinationCollision(let destinationId, _):
                return "Multiple imported items would map to \"\(destinationId)\"."
            case .ambiguousHistoryAssociation(let historyId, _):
                return "Reading history \"\(historyId)\" matches multiple imported items."
            case .mediaStateDestinationCollision(let table, let canonicalMediaId):
                return "\(table) already contains state for destination media \"\(canonicalMediaId)\"."
            }
        }
    }

    typealias AliasWriter = @Sendable (_ foreignId: String, _ newPluginId: String) async throws -> Void

    nonisolated private struct Mapping: Sendable {
        let source: LibraryItem
        let destinationId: String
    }

    let dbPool: DatabasePool

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    func remap(
        oldPluginId: String,
        newPluginId: String,
        affectedItemIds: [String]
    ) async throws -> Result {
        try await dbPool.write { db in
            var mappings: [Mapping] = []
            mappings.reserveCapacity(affectedItemIds.count)

            for sourceId in affectedItemIds {
                guard let source = try LibraryItem.fetchOne(db, key: sourceId) else {
                    throw RemapError.sourceNotFound(sourceId)
                }
                guard source.pluginId == oldPluginId else {
                    throw RemapError.sourceOwnershipMismatch(
                        itemId: sourceId,
                        expectedPluginId: oldPluginId,
                        actualPluginId: source.pluginId
                    )
                }

                let destinationId = ImportedMediaIdentity.destinationId(
                    sourceItemId: sourceId,
                    oldPluginId: oldPluginId,
                    newPluginId: newPluginId,
                    mediaKind: source.effectiveType
                )
                guard destinationId != sourceId else {
                    throw RemapError.noOpMapping(itemId: sourceId)
                }
                mappings.append(Mapping(source: source, destinationId: destinationId))
            }

            let mappingsByIdentity = Dictionary(grouping: mappings, by: { $0.source.mediaIdentity })
            if let collision = mappingsByIdentity.values.first(where: { $0.count > 1 }),
               let preferredID = collision.first?.destinationId {
                throw RemapError.intraBatchDestinationCollision(
                    destinationId: preferredID,
                    sourceItemIds: collision.map(\.source.id).sorted()
                )
            }

            // Reserve each destination before considering the next item. At most one kind of
            // a source key may use an unscoped id, even when it arrived through another remap.
            var reserved: [String: (pluginId: String, mediaKind: MediaKind)] = [:]
            for index in mappings.indices {
                let mapping = mappings[index]
                let media = mapping.source.mediaIdentity
                let candidateIDs = ImportedMediaIdentity.localItemIDs(
                    pluginId: newPluginId, canonicalMediaId: media.canonicalMediaId, mediaKind: media.mediaKind
                )
                let targetMedia = MediaIdentity(
                    pluginId: newPluginId, canonicalMediaId: media.canonicalMediaId, mediaKind: media.mediaKind
                )
                for id in candidateIDs {
                    if let existing = try LibraryItem.fetchOne(db, key: id),
                       existing.id != mapping.source.id,
                       existing.mediaIdentity == targetMedia {
                        throw RemapError.destinationExists(id)
                    }
                }
                guard let destinationID = try ImportedMediaIdentity.newItemID(
                    preferred: mapping.destinationId,
                    pluginId: newPluginId,
                    canonicalMediaId: media.canonicalMediaId,
                    mediaKind: media.mediaKind,
                    occupant: { id in
                        if let claimed = reserved[id] { return claimed }
                        if oldPluginId == newPluginId, id == mapping.source.id { return nil }
                        return try LibraryItem.fetchOne(db, key: id).map { ($0.pluginId, $0.effectiveType) }
                    }
                ) else {
                    throw RemapError.destinationExists(candidateIDs[2])
                }
                reserved[destinationID] = (newPluginId, media.mediaKind)
                mappings[index] = Mapping(source: mapping.source, destinationId: destinationID)
            }

            let oldHistory = try ReadingHistoryRecord
                .filter(ReadingHistoryRecord.Columns.pluginId == oldPluginId)
                .fetchAll(db)
            var historyMappings: [(ReadingHistoryRecord, Mapping)] = []

            for history in oldHistory {
                let matches = mappings.filter {
                    $0.source.effectiveType == history.mediaKind
                        && ImportedMediaIdentity.historyIdentifiers(
                            history,
                            match: $0.source.id,
                            pluginId: oldPluginId,
                            mediaKind: $0.source.effectiveType
                        )
                }
                guard matches.count <= 1 else {
                    throw RemapError.ambiguousHistoryAssociation(
                        historyId: history.id,
                        sourceItemIds: matches.map(\.source.id).sorted()
                    )
                }
                if let match = matches.first {
                    historyMappings.append((history, match))
                }
            }

            for mapping in mappings {
                let sourceCanonicalId = ImportedMediaIdentity.canonicalMediaId(
                    itemId: mapping.source.id,
                    pluginId: oldPluginId,
                    mediaKind: mapping.source.effectiveType
                )
                let destinationCanonicalId = ImportedMediaIdentity.canonicalMediaId(
                    itemId: mapping.destinationId,
                    pluginId: newPluginId,
                    mediaKind: mapping.source.effectiveType
                )
                try preflightScopedState(
                    db: db,
                    oldPluginId: oldPluginId,
                    newPluginId: newPluginId,
                    mediaKind: mapping.source.effectiveType,
                    sourceCanonicalMediaId: sourceCanonicalId,
                    destinationCanonicalMediaId: destinationCanonicalId
                )
            }

            for mapping in mappings {
                let source = mapping.source
                let destination = LibraryItem(
                    id: mapping.destinationId,
                    title: source.title,
                    coverUrl: source.coverUrl,
                    pluginId: newPluginId,
                    isAnime: source.isAnime,
                    pluginType: source.pluginType,
                    rawPayload: source.rawPayload,
                    anilistId: source.anilistId,
                    status: source.status,
                    lastCheckedAt: source.lastCheckedAt,
                    lastUpdatedAt: source.lastUpdatedAt,
                    knownChapterCount: source.knownChapterCount
                )
                try destination.insert(db)
            }

            var movedLinkCount = 0
            for mapping in mappings {
                try db.execute(
                    sql: "UPDATE itemCategoryLink SET itemId = ? WHERE itemId = ?",
                    arguments: [mapping.destinationId, mapping.source.id]
                )
                movedLinkCount += db.changesCount
            }

            for (history, mapping) in historyMappings {
                try db.execute(
                    sql: """
                        UPDATE readingHistory
                        SET libraryItemId = ?, mediaKey = ?, pluginId = ?
                        WHERE id = ?
                        """,
                    arguments: [mapping.destinationId, mapping.destinationId, newPluginId, history.id]
                )
            }

            for mapping in mappings {
                let canonicalMediaId = ImportedMediaIdentity.canonicalMediaId(
                    itemId: mapping.source.id,
                    pluginId: oldPluginId,
                    mediaKind: mapping.source.effectiveType
                )
                for table in [
                    "readProgressKey",
                    "readProgressNumber",
                    "mediaReadProgress",
                    "trackerLink",
                    "updateBadge"
                ] {
                    try db.execute(
                        sql: """
                            UPDATE \(table)
                            SET pluginId = ?
                            WHERE pluginId = ? AND canonicalMediaId = ? AND mediaKind = ?
                            """,
                        arguments: [newPluginId, oldPluginId, canonicalMediaId, mapping.source.effectiveType.rawValue]
                    )
                }
            }

            for mapping in mappings {
                _ = try LibraryItem.deleteOne(db, key: mapping.source.id)
            }

            return Result(
                remappedItemCount: mappings.count,
                movedLinkCount: movedLinkCount,
                movedHistoryCount: historyMappings.count
            )
        }
    }

    nonisolated private func preflightScopedState(
        db: Database,
        oldPluginId: String,
        newPluginId: String,
        mediaKind: MediaKind,
        sourceCanonicalMediaId: String,
        destinationCanonicalMediaId: String
    ) throws {
        let scalarTables = ["mediaReadProgress", "updateBadge"]
        for table in scalarTables {
            let sourceExists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE pluginId = ? AND canonicalMediaId = ? AND mediaKind = ?)",
                arguments: [oldPluginId, sourceCanonicalMediaId, mediaKind.rawValue]
            ) ?? false
            let destinationExists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE pluginId = ? AND canonicalMediaId = ? AND mediaKind = ?)",
                arguments: [newPluginId, destinationCanonicalMediaId, mediaKind.rawValue]
            ) ?? false
            if sourceExists && destinationExists {
                throw RemapError.mediaStateDestinationCollision(
                    table: table,
                    canonicalMediaId: destinationCanonicalMediaId
                )
            }
        }

        let keyedTables = [
            ("readProgressKey", "chapterKey"),
            ("readProgressNumber", "chapterNumber"),
            ("trackerLink", "providerId")
        ]
        for (table, logicalKey) in keyedTables {
            let collision = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM \(table) source
                        JOIN \(table) destination
                          ON destination.\(logicalKey) = source.\(logicalKey)
                         AND destination.mediaKind = source.mediaKind
                        WHERE source.pluginId = ?
                          AND source.canonicalMediaId = ?
                          AND source.mediaKind = ?
                          AND destination.pluginId = ?
                          AND destination.canonicalMediaId = ?
                          AND destination.mediaKind = ?
                    )
                    """,
                arguments: [
                    oldPluginId,
                    sourceCanonicalMediaId,
                    mediaKind.rawValue,
                    newPluginId,
                    destinationCanonicalMediaId,
                    mediaKind.rawValue
                ]
            ) ?? false
            if collision {
                throw RemapError.mediaStateDestinationCollision(
                    table: table,
                    canonicalMediaId: destinationCanonicalMediaId
                )
            }
        }
    }

    func relink(
        pluginId: String,
        mediaKind: MediaKind,
        possibleSourceItemIds: [String],
        destinationItemId: String,
        title: String,
        coverUrl: String?,
        rawPayload: Data
    ) async throws -> Result {
        try await dbPool.write { db in
            guard let source = try possibleSourceItemIds.lazy.compactMap({
                try LibraryItem.fetchOne(db, key: $0)
            }).first(where: { $0.effectiveType == mediaKind }) else {
                throw RemapError.sourceNotFound(possibleSourceItemIds.joined(separator: ","))
            }
            guard source.pluginId == pluginId else {
                throw RemapError.sourceOwnershipMismatch(
                    itemId: source.id,
                    expectedPluginId: pluginId,
                    actualPluginId: source.pluginId
                )
            }
            guard source.id != destinationItemId else {
                throw RemapError.noOpMapping(itemId: source.id)
            }
            guard try LibraryItem.fetchOne(db, key: destinationItemId) == nil else {
                throw RemapError.destinationExists(destinationItemId)
            }

            let sourceCanonicalMediaId = ImportedMediaIdentity.canonicalMediaId(
                itemId: source.id,
                pluginId: pluginId,
                mediaKind: mediaKind
            )
            let destinationCanonicalMediaId = ImportedMediaIdentity.canonicalMediaId(
                itemId: destinationItemId,
                pluginId: pluginId,
                mediaKind: mediaKind
            )
            try preflightScopedState(
                db: db,
                oldPluginId: pluginId,
                newPluginId: pluginId,
                mediaKind: mediaKind,
                sourceCanonicalMediaId: sourceCanonicalMediaId,
                destinationCanonicalMediaId: destinationCanonicalMediaId
            )

            try LibraryItem(
                id: destinationItemId,
                title: title,
                coverUrl: coverUrl,
                pluginId: pluginId,
                isAnime: source.isAnime,
                pluginType: source.pluginType ?? mediaKind,
                rawPayload: rawPayload,
                anilistId: source.anilistId,
                status: source.status,
                lastCheckedAt: source.lastCheckedAt,
                lastUpdatedAt: source.lastUpdatedAt,
                knownChapterCount: source.knownChapterCount
            ).insert(db)

            try db.execute(
                sql: "UPDATE itemCategoryLink SET itemId = ? WHERE itemId = ?",
                arguments: [destinationItemId, source.id]
            )
            let movedLinkCount = db.changesCount

            let histories = try ReadingHistoryRecord
                .filter(ReadingHistoryRecord.Columns.pluginId == pluginId)
                .filter(ReadingHistoryRecord.Columns.mediaKind == mediaKind.rawValue)
                .fetchAll(db)
                .filter {
                    ImportedMediaIdentity.historyIdentifiers(
                        $0,
                        match: source.id,
                        pluginId: pluginId,
                        mediaKind: mediaKind
                    )
                }
            for history in histories {
                try db.execute(
                    sql: """
                        UPDATE readingHistory
                        SET libraryItemId = ?, mediaKey = ?
                        WHERE id = ?
                        """,
                    arguments: [destinationItemId, destinationItemId, history.id]
                )
            }

            for table in [
                "readProgressKey",
                "readProgressNumber",
                "mediaReadProgress",
                "trackerLink",
                "updateBadge"
            ] {
                try db.execute(
                    sql: """
                        UPDATE \(table)
                        SET canonicalMediaId = ?
                        WHERE pluginId = ? AND canonicalMediaId = ? AND mediaKind = ?
                        """,
                    arguments: [destinationCanonicalMediaId, pluginId, sourceCanonicalMediaId, mediaKind.rawValue]
                )
            }

            _ = try LibraryItem.deleteOne(db, key: source.id)
            return Result(
                remappedItemCount: 1,
                movedLinkCount: movedLinkCount,
                movedHistoryCount: histories.count
            )
        }
    }

    /// The database and alias store cannot share a transaction. The database commits first;
    /// a process crash in the narrow window before this callback can leave the alias unwritten.
    func remapAndPersistAlias(
        foreignId: String,
        oldPluginId: String,
        newPluginId: String,
        affectedItemIds: [String],
        aliasWriter: AliasWriter
    ) async throws -> Result {
        let result = try await remap(
            oldPluginId: oldPluginId,
            newPluginId: newPluginId,
            affectedItemIds: affectedItemIds
        )
        try await aliasWriter(foreignId, newPluginId)
        return result
    }
}
