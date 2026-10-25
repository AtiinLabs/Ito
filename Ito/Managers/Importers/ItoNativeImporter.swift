import Foundation
import GRDB
import ito_runner

public struct ItoNativeImporter: BackupImporter {
    nonisolated private static let legacyRepositoriesKey = "ito_repositories"

    private let standardApplicationDomain: String

    public init(
        standardApplicationDomain: String = Bundle.main.bundleIdentifier ?? "moe.itoapp.ito"
    ) {
        self.standardApplicationDomain = standardApplicationDomain
    }

    public func canHandle(url: URL) -> Bool {
        url.pathExtension.lowercased() == "itobackup"
    }

    public func parse(url: URL) async throws -> ImportedBackup {
        let backupPool = try DatabasePool(path: url.path)

        return try await backupPool.read { db in
            let metadata = try fetchMetadata(in: db)
            var capabilities = try fetchCapabilities(in: db)
            let hasLegacyLibraryTables = try [
                LibraryCategory.databaseTableName,
                LibraryItem.databaseTableName,
                ItemCategoryLink.databaseTableName
            ].allSatisfy { try db.tableExists($0) }
            let hasLegacyHistoryTable = try db.tableExists(
                ReadingHistoryRecord.databaseTableName
            )
            let categories = try fetchIfPresent(LibraryCategory.self, in: db)
            let items = try fetchLibraryItems(in: db)
            let links = try fetchIfPresent(ItemCategoryLink.self, in: db)
            var legacyStateArchives = try fetchArchives(in: db)
            let capturedAt = metadata?.createdAt ?? Date()
            let resolver = try LegacyMediaKindResolver(db: db)
            func stateRows<Record: FetchableRecord & TableRecord>(
                _ type: Record.Type,
                _ component: BackupComponent,
                rowCode: String
            ) throws -> [Record] {
                try fetchKindScoped(
                    type,
                    component: component,
                    rowCode: rowCode,
                    identityColumns: ["pluginId", "canonicalMediaId"],
                    resolveKind: { row in
                        guard let pluginId: String = LegacyMediaKindResolver.value(row, "pluginId"),
                              let mediaId: String = LegacyMediaKindResolver.value(row, "canonicalMediaId") else {
                            return nil
                        }
                        return resolver.resolve(pluginID: pluginId, canonicalMediaID: mediaId)
                    },
                    capturedAt: capturedAt,
                    archives: &legacyStateArchives,
                    in: db
                )
            }
            let history = try fetchKindScoped(
                ReadingHistoryRecord.self,
                component: .readingHistory,
                rowCode: "invalidReadingHistoryRow",
                identityColumns: ["id", "pluginId", "mediaKey"],
                resolveKind: resolver.resolveHistory,
                capturedAt: capturedAt,
                archives: &legacyStateArchives,
                in: db
            )
            let sourceMappings = try capabilities.contains {
                $0.component == .sourceMappings
                    && $0.representation != .unrepresented
            }
                ? fetchSourceMappings(in: db)
                : []
            let preferences = try fetchIfPresent(AppPreference.self, in: db)
            let readProgressKeys = try stateRows(
                ReadProgressKeyRecord.self, .readProgressAndResume, rowCode: "invalidReadProgressKeyRow"
            )
            let readProgressNumbers = try stateRows(
                ReadProgressNumberRecord.self, .readProgressAndResume, rowCode: "invalidReadProgressNumberRow"
            )
            let mediaReadProgress = try stateRows(
                MediaReadProgressRecord.self, .readProgressAndResume, rowCode: "invalidMediaReadProgressRow"
            )
            var trackerLinks = try stateRows(TrackerLinkRecord.self, .trackerLinks, rowCode: "invalidTrackerLinkRow")
            let updateBadges = try stateRows(UpdateBadgeRecord.self, .updateBadges, rowCode: "invalidUpdateBadgeRow")
            legacyStateArchives = Self.uniqueArchives(legacyStateArchives)
            var repositories = try fetchIfPresent(RepositoryRecord.self, in: db)
            let importerAliases = try fetchIfPresent(
                PluginMigrationAliasRecord.self,
                in: db
            )
            let pluginIdentities = try fetchIfPresent(PluginIdentityRecord.self, in: db)
            let pluginIdentityAliases = try fetchIfPresent(
                PluginIdentityAliasRecord.self,
                in: db
            )
            let pluginSettings = try fetchIfPresent(PluginSettingRecord.self, in: db)
            let legacyUnscopedMediaState = try fetchIfPresent(
                LegacyUnscopedMediaStateRecord.self,
                in: db
            )
            var importedPreferences = preferences
            var legacyRepresentationOverrides: [BackupComponent: BackupRepresentation] = [:]

            if metadata == nil, capabilities.isEmpty {
                trackerLinks = synthesizeLegacyTrackerLinks(
                    items: items,
                    existingLinks: trackerLinks
                )
                let legacyRepositories = try synthesizeLegacyRepositories(
                    preferences: preferences,
                    existingRepositories: repositories
                )
                repositories = legacyRepositories.records
                if let representation = legacyRepositories.representation {
                    legacyRepresentationOverrides[.repositories] = representation
                }
                if hasLegacyLibraryTables {
                    legacyRepresentationOverrides[.libraryCore] = representation(
                        hasRows: !categories.isEmpty || !items.isEmpty || !links.isEmpty
                    )
                }
                if hasLegacyHistoryTable {
                    legacyRepresentationOverrides[.readingHistory] = representation(
                        hasRows: !history.isEmpty
                    )
                }
                if try db.tableExists(LegacyStateArchiveRecord.databaseTableName) || !legacyStateArchives.isEmpty {
                    legacyRepresentationOverrides[.legacyStateArchive] = representation(
                        hasRows: !legacyStateArchives.isEmpty
                    )
                }
                importedPreferences.removeAll { $0.key == Self.legacyRepositoriesKey }
            } else if !capabilities.isEmpty {
                capabilities = capabilities.map { cap in
                    switch cap.component {
                    case .legacyStateArchive:
                        if !legacyStateArchives.isEmpty && cap.representation != .representedNonempty {
                            return BackupCapabilityRecord(component: .legacyStateArchive, representation: .representedNonempty)
                        }
                    case .readProgressAndResume:
                        let hasRows = !readProgressKeys.isEmpty || !readProgressNumbers.isEmpty || !mediaReadProgress.isEmpty
                        if !hasRows && cap.representation == .representedNonempty {
                            return BackupCapabilityRecord(component: .readProgressAndResume, representation: .representedEmpty)
                        }
                    case .readingHistory:
                        if history.isEmpty && cap.representation == .representedNonempty {
                            return BackupCapabilityRecord(component: .readingHistory, representation: .representedEmpty)
                        }
                    case .trackerLinks:
                        if trackerLinks.isEmpty && cap.representation == .representedNonempty {
                            return BackupCapabilityRecord(component: .trackerLinks, representation: .representedEmpty)
                        }
                    case .updateBadges:
                        if updateBadges.isEmpty && cap.representation == .representedNonempty {
                            return BackupCapabilityRecord(component: .updateBadges, representation: .representedEmpty)
                        }
                    default:
                        break
                    }
                    return cap
                }
                if !legacyStateArchives.isEmpty,
                   !capabilities.contains(where: { $0.component == .legacyStateArchive }) {
                    capabilities.append(
                        BackupCapabilityRecord(component: .legacyStateArchive, representation: .representedNonempty)
                    )
                }
            }

            let imported = ImportedBackup(
                metadata: metadata,
                capabilities: capabilities,
                legacyRepresentationOverrides: legacyRepresentationOverrides,
                categories: categories,
                items: items,
                links: links,
                history: history,
                sourceMappings: sourceMappings,
                preferences: importedPreferences,
                representedPreferenceKeys: importedPreferences.map(\.key),
                readProgressKeys: readProgressKeys,
                readProgressNumbers: readProgressNumbers,
                mediaReadProgress: mediaReadProgress,
                trackerLinks: trackerLinks,
                updateBadges: updateBadges,
                repositories: repositories,
                importerAliases: importerAliases,
                pluginIdentities: pluginIdentities,
                pluginIdentityAliases: pluginIdentityAliases,
                pluginSettings: pluginSettings,
                legacyUnscopedMediaState: legacyUnscopedMediaState,
                legacyStateArchives: legacyStateArchives
            )
            try imported.validateCapabilityMetadata()
            try validateCapabilityRepresentations(imported)
            return imported
        }
    }

    nonisolated private func fetchMetadata(in db: Database) throws -> BackupMetadataRecord? {
        guard try db.tableExists(BackupMetadataRecord.databaseTableName) else {
            return nil
        }
        let requiredColumns = ["id", "formatVersion", "createdAt"]
        guard try hasColumns(requiredColumns, in: BackupMetadataRecord.databaseTableName, db: db)
        else {
            throw invalidCapability(code: "invalidMetadataColumns")
        }

        let rows = try Row.fetchAll(db, sql: "SELECT id, formatVersion, createdAt FROM backupMetadata")
        guard rows.count <= 1 else {
            throw invalidCapability(code: "duplicateMetadata")
        }
        guard let row = rows.first else { return nil }
        let id: Int? = LegacyMediaKindResolver.value(row, "id")
        let formatVersion: Int? = LegacyMediaKindResolver.value(row, "formatVersion")
        let createdAt: Date? = LegacyMediaKindResolver.value(row, "createdAt")
        guard id == 1, let formatVersion, let createdAt else {
            throw invalidCapability(code: "invalidMetadataRow")
        }
        return BackupMetadataRecord(formatVersion: formatVersion, createdAt: createdAt)
    }

    nonisolated private func fetchCapabilities(
        in db: Database
    ) throws -> [BackupCapabilityRecord] {
        guard try db.tableExists(BackupCapabilityRecord.databaseTableName) else {
            return []
        }
        guard try hasColumns(
            ["component", "representation"],
            in: BackupCapabilityRecord.databaseTableName,
            db: db
        ) else {
            throw invalidCapability(code: "invalidCapabilityColumns")
        }

        let rows = try Row.fetchAll(
            db,
            sql: "SELECT component, representation FROM backupCapability"
        )
        var seen = Set<BackupComponent>()
        return try rows.map { row in
            let componentValue: String? = LegacyMediaKindResolver.value(row, "component")
            let representationValue: String? = LegacyMediaKindResolver.value(row, "representation")
            guard let componentValue,
                  let component = BackupComponent(rawValue: componentValue) else {
                throw invalidCapability(code: "unknownComponent")
            }
            guard seen.insert(component).inserted else {
                throw invalidCapability(component: component, code: "duplicate")
            }
            guard let representationValue,
                  let representation = BackupRepresentation(rawValue: representationValue),
                  representation != .unrepresented else {
                throw invalidCapability(component: component, code: "invalidRepresentation")
            }
            return BackupCapabilityRecord(
                component: component,
                representation: representation
            )
        }
    }

    nonisolated private func fetchLibraryItems(in db: Database) throws -> [LibraryItem] {
        guard try db.tableExists("libraryItem") else { return [] }
        let requiredColumns = [
            "id", "title", "coverUrl", "pluginId", "isAnime", "pluginType",
            "rawPayload", "anilistId"
        ]
        guard try hasColumns(requiredColumns, in: "libraryItem", db: db) else {
            throw BackupPreflightError.rejected(
                .invalidComponentData(component: .libraryCore, code: "invalidLibraryItemColumns")
            )
        }

        let availableColumns = Set(try db.columns(in: "libraryItem").map(\.name))
        let optionalColumns = ["status", "lastCheckedAt", "lastUpdatedAt", "knownChapterCount"]
        let projections = requiredColumns + optionalColumns.map { column in
            availableColumns.contains(column) ? column : "NULL AS \(column)"
        }
        return try LibraryItem.fetchAll(
            db,
            sql: "SELECT \(projections.joined(separator: ", ")) FROM libraryItem"
        )
    }

    nonisolated private func fetchArchives(
        in db: Database
    ) throws -> [LegacyStateArchiveRecord] {
        let archives: [LegacyStateArchiveRecord]
        do {
            archives = try fetchIfPresent(LegacyStateArchiveRecord.self, in: db)
        } catch {
            throw BackupPreflightError.rejected(
                .invalidComponentData(
                    component: .legacyStateArchive,
                    code: "invalidArchiveRow"
                )
            )
        }
        for archive in archives {
            let classification = LegacyDefaultsSourceTuple(
                sourceDomain: archive.sourceDomain,
                sourceKey: archive.sourceKey
            ).classification(standardApplicationDomain: standardApplicationDomain)

            switch classification {
            case .appManagedCredential:
                throw BackupPreflightError.rejected(
                    .credentialPayloadRejected(
                        sourceDomain: archive.sourceDomain,
                        sourceKey: archive.sourceKey
                    )
                )
            case .appNonSecret:
                guard archive.contentClass == .appNonSecret else {
                    throw invalidArchiveClassification()
                }
            case .opaquePluginState:
                // Rows archived for lacking a provable kind are app state from the six kind-scoped tables.
                if archive.reason == "kindUnknown",
                   archive.contentClass == .appNonSecret,
                   archive.valueType == "databaseRow",
                   LegacyMediaKindResolver.kindScopedTables.contains(archive.sourceDomain) {
                    break
                }
                guard archive.contentClass == .opaquePluginState else {
                    throw invalidArchiveClassification()
                }
            }
        }
        return archives
    }

    nonisolated private func fetchSourceMappings(
        in db: Database
    ) throws -> [SourceMappingRecord] {
        do {
            return try fetchIfPresent(SourceMappingRecord.self, in: db)
        } catch {
            throw BackupPreflightError.rejected(
                .invalidComponentData(
                    component: .sourceMappings,
                    code: "invalidSourceMappingRow"
                )
            )
        }
    }

    nonisolated private func synthesizeLegacyTrackerLinks(
        items: [LibraryItem],
        existingLinks: [TrackerLinkRecord]
    ) -> [TrackerLinkRecord] {
        var links = existingLinks
        var representedKeys = Set(
            links.map { "\($0.pluginId)\u{0}\($0.canonicalMediaId)\u{0}\($0.mediaKind.rawValue)\u{0}\($0.providerId)" }
        )
        for item in items {
            guard let anilistId = item.anilistId else { continue }
            let canonicalMediaId = ImportedMediaIdentity.canonicalMediaId(
                itemId: item.id,
                pluginId: item.pluginId,
                mediaKind: item.effectiveType
            )
            let key = "\(item.pluginId)\u{0}\(canonicalMediaId)\u{0}\(item.effectiveType.rawValue)\u{0}anilist"
            guard representedKeys.insert(key).inserted else { continue }
            links.append(
                TrackerLinkRecord(
                    pluginId: item.pluginId,
                    canonicalMediaId: canonicalMediaId,
                    mediaKind: item.effectiveType,
                    providerId: "anilist",
                    remoteMediaId: String(anilistId),
                    updatedAt: nil,
                    provenance: .legacyUnknownTime
                )
            )
        }
        return links
    }

    /// Reads one kind-scoped table. Rows with a `mediaKind` column decode as stored. Older kindless rows take the
    /// kind `resolveKind` proves and are otherwise archived unchanged. A row whose identity or fields are malformed
    /// rejects the backup, whichever format it has.
    nonisolated private func fetchKindScoped<Record: FetchableRecord & TableRecord>(
        _: Record.Type,
        component: BackupComponent,
        rowCode: String,
        identityColumns: [String],
        resolveKind: (Row) -> MediaKind?,
        capturedAt: Date,
        archives: inout [LegacyStateArchiveRecord],
        in db: Database
    ) throws -> [Record] {
        let table = Record.databaseTableName
        guard try db.tableExists(table) else { return [] }
        let storesKind = try hasColumns(["mediaKind"], in: table, db: db)
        func rejected(_ code: String) -> BackupPreflightError {
            .rejected(.invalidComponentData(component: component, code: code))
        }
        var records: [Record] = []
        for row in try Row.fetchAll(db, sql: "SELECT * FROM \(table)") {
            let kindedRow: Row
            if storesKind {
                guard let rawKind: String = LegacyMediaKindResolver.value(row, "mediaKind"),
                      MediaKind(rawValue: rawKind) != nil else {
                    throw rejected("invalidMediaKind")
                }
                kindedRow = row
            } else {
                guard identityColumns.allSatisfy({ (LegacyMediaKindResolver.value(row, $0) as String?) != nil }) else {
                    throw rejected(rowCode)
                }
                guard let kind = resolveKind(row) else {
                    archives.append(
                        try LegacyMediaKindResolver.archiveRecord(table: table, row: row, capturedAt: capturedAt)
                    )
                    continue
                }
                var columns: [String: (any DatabaseValueConvertible)?] = [:]
                for (column, value) in row {
                    columns[column] = value
                }
                columns["mediaKind"] = kind.rawValue
                kindedRow = Row(columns)
            }
            do {
                records.append(try Record(row: kindedRow))
            } catch {
                throw rejected(rowCode)
            }
        }
        return records
    }

    nonisolated private static func uniqueArchives(_ archives: [LegacyStateArchiveRecord]) -> [LegacyStateArchiveRecord] {
        var seen = Set<[String]>()
        return archives.filter {
            seen.insert([$0.sourceDomain, $0.sourceKey, $0.contentClass.rawValue, $0.valueType, $0.fingerprint]).inserted
        }
    }

    nonisolated private func synthesizeLegacyRepositories(
        preferences: [AppPreference],
        existingRepositories: [RepositoryRecord]
    ) throws -> (
        records: [RepositoryRecord],
        representation: BackupRepresentation?
    ) {
        let legacyPreferences = preferences.filter { $0.key == Self.legacyRepositoriesKey }
        guard legacyPreferences.count <= 1 else {
            throw BackupPreflightError.rejected(
                .invalidKeyData(
                    component: .repositories,
                    key: Self.legacyRepositoriesKey,
                    code: "duplicateLegacyPayload"
                )
            )
        }
        guard let preference = legacyPreferences.first else {
            return (existingRepositories, nil)
        }

        guard let legacyRepositories = try? JSONDecoder().decode(
            [Repository].self,
            from: preference.value
        ) else {
            throw BackupPreflightError.rejected(
                .invalidKeyData(
                    component: .repositories,
                    key: Self.legacyRepositoriesKey,
                    code: "invalidLegacyPayload"
                )
            )
        }

        var repositoriesByURL: [String: RepositoryRecord] = [:]
        for repository in existingRepositories {
            guard repositoriesByURL.updateValue(repository, forKey: repository.url) == nil else {
                throw BackupPreflightError.rejected(
                    .invalidComponentData(
                        component: .repositories,
                        code: "duplicateRepositoryURL"
                    )
                )
            }
        }
        for repository in legacyRepositories where repositoriesByURL[repository.url] == nil {
            repositoriesByURL[repository.url] = RepositoryRecord(
                url: repository.url,
                lastFetched: repository.lastFetched,
                indexPayload: try repository.index.map { try JSONEncoder().encode($0) }
            )
        }
        return (
            repositoriesByURL.values.sorted { $0.url < $1.url },
            legacyRepositories.isEmpty ? .representedEmpty : .representedNonempty
        )
    }

    nonisolated private func validateCapabilityRepresentations(
        _ backup: ImportedBackup
    ) throws {
        guard backup.metadata != nil else { return }
        for component in BackupComponent.allCases
        where backup.representation(of: component) == .unrepresented
            && backupHasRows(backup, for: component) {
            throw invalidCapability(
                component: component,
                code: "unrepresentedContainsRows"
            )
        }
        for capability in backup.capabilities {
            if capability.component == .scalarAppPreferences,
               capability.representation == .representedNonempty {
                let catalogKeys = Set(AppPreferenceCatalogEntry.allCases.map(\.rawValue))
                let preferenceKeys = Set(backup.preferences.map(\.key))
                guard backup.preferences.count == catalogKeys.count,
                      preferenceKeys == catalogKeys,
                      Set(backup.representedPreferenceKeys) == catalogKeys else {
                    throw invalidCapability(
                        component: .scalarAppPreferences,
                        code: "incompletePreferenceCatalog"
                    )
                }
            }

            let hasRows = backupHasRows(backup, for: capability.component)
            switch (capability.representation, hasRows) {
            case (.representedEmpty, true):
                throw invalidCapability(
                    component: capability.component,
                    code: "representedEmptyHasRows"
                )
            case (.representedNonempty, false):
                throw invalidCapability(
                    component: capability.component,
                    code: "representedNonemptyHasNoRows"
                )
            default:
                break
            }
        }
    }

    nonisolated private func representation(
        hasRows: Bool
    ) -> BackupRepresentation {
        hasRows ? .representedNonempty : .representedEmpty
    }

    nonisolated private func backupHasRows(
        _ backup: ImportedBackup,
        for component: BackupComponent
    ) -> Bool {
        switch component {
        case .libraryCore:
            !backup.categories.isEmpty || !backup.items.isEmpty || !backup.links.isEmpty
        case .readingHistory:
            !backup.history.isEmpty
        case .sourceMappings:
            !backup.sourceMappings.isEmpty
        case .scalarAppPreferences:
            !backup.representedPreferenceKeys.isEmpty
        case .readProgressAndResume:
            !backup.readProgressKeys.isEmpty
                || !backup.readProgressNumbers.isEmpty
                || !backup.mediaReadProgress.isEmpty
        case .trackerLinks:
            !backup.trackerLinks.isEmpty
        case .updateBadges:
            !backup.updateBadges.isEmpty
        case .repositories:
            !backup.repositories.isEmpty
        case .userImporterAliases:
            !backup.importerAliases.isEmpty
        case .pluginIdentityAndAliases:
            !backup.pluginIdentities.isEmpty || !backup.pluginIdentityAliases.isEmpty
        case .pluginSettings:
            !backup.pluginSettings.isEmpty
        case .legacyUnscopedMediaState:
            !backup.legacyUnscopedMediaState.isEmpty
        case .legacyStateArchive:
            !backup.legacyStateArchives.isEmpty
        }
    }

    nonisolated private func fetchIfPresent<Record>(
        _ type: Record.Type,
        in db: Database
    ) throws -> [Record] where Record: FetchableRecord & TableRecord {
        guard try db.tableExists(Record.databaseTableName) else { return [] }
        return try Record.fetchAll(db)
    }

    nonisolated private func hasColumns(
        _ requiredColumns: [String],
        in table: String,
        db: Database
    ) throws -> Bool {
        let columns = Set(try db.columns(in: table).map(\.name))
        return requiredColumns.allSatisfy(columns.contains)
    }

    nonisolated private func invalidCapability(
        component: BackupComponent? = nil,
        code: String
    ) -> BackupPreflightError {
        .rejected(.invalidCapabilityMetadata(component: component, code: code))
    }

    nonisolated private func invalidArchiveClassification() -> BackupPreflightError {
        .rejected(
            .invalidComponentData(
                component: .legacyStateArchive,
                code: "contentClassSourceMismatch"
            )
        )
    }
}
