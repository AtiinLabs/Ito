import Foundation
import GRDB
import ito_runner

// The restore DAG is intentionally isolated in one owned file for G006 integration.
// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
nonisolated struct ComponentAwareBackupRestoreOperation: Sendable {
    typealias LateTransactionFailure = @Sendable (Database) throws -> Void

    private struct ItemDisposition: Sendable {
        let imported: LibraryItem
        let targetId: String
        let isPreexisting: Bool

        var sourceIdentity: ImportedMediaIdentity.Key {
            ImportedMediaIdentity.key(
                itemId: imported.id,
                pluginId: imported.pluginId,
                mediaKind: imported.effectiveType
            )
        }
    }

    private struct LibraryPlan: Sendable {
        let dispositions: [ItemDisposition]
        let targetIdByImportedId: [String: String]
        let targetIdentityBySourceIdentity:
            [ImportedMediaIdentity.Key: ImportedMediaIdentity.Key]
        let currentSystemCategoryId: String?
        let importedSystemCategoryId: String?
    }

    private struct LocalState: Sendable {
        let categories: [LibraryCategory]
        let items: [LibraryItem]
        let links: [ItemCategoryLink]
        let history: [ReadingHistoryRecord]
        let preferences: [AppPreference]
        let readProgressKeys: [ReadProgressKeyRecord]
        let readProgressNumbers: [ReadProgressNumberRecord]
        let mediaReadProgress: [MediaReadProgressRecord]
        let trackerLinks: [TrackerLinkRecord]
        let updateBadges: [UpdateBadgeRecord]
        let repositories: [RepositoryRecord]
        let importerAliases: [PluginMigrationAliasRecord]
        let pluginIdentities: [PluginIdentityRecord]
        let pluginIdentityAliases: [PluginIdentityAliasRecord]
        let pluginSettings: [PluginSettingRecord]
        let unscopedMediaState: [LegacyUnscopedMediaStateRecord]
        let archives: [LegacyStateArchiveRecord]
    }

    private struct RestorePlan: Sendable {
        let backup: ImportedBackup
        let mode: BackupRestoreMode
        let operationId: String
        let createdAt: Date
        let represented: Set<BackupComponent>
        let resolvedConflicts: [String: ConflictResolution]
        let library: LibraryPlan
        let repositories: [RepositoryRecord]
        let trackerLinks: [TrackerLinkRecord]
    }

    private struct MutableOutcome {
        var inserted = 0
        var replaced = 0
        var preservedLocal = 0
        var skipped = 0
        var unresolved = 0
        var dependencyRepaired = 0

        func make(component: BackupComponent) throws -> ComponentOutcome {
            try ComponentOutcome(
                component: component,
                inserted: inserted,
                replaced: replaced,
                preservedLocal: preservedLocal,
                skipped: skipped,
                unresolved: unresolved,
                dependencyRepaired: dependencyRepaired
            )
        }
    }

    private struct ReadProgressKey: Hashable {
        let pluginId: String
        let canonicalMediaId: String
        let mediaKind: MediaKind
        let chapterKey: String
    }

    private struct ReadProgressNumberKey: Hashable {
        let pluginId: String
        let canonicalMediaId: String
        let mediaKind: MediaKind
        let chapterNumber: Double
    }

    private struct MediaKey: Hashable {
        let pluginId: String
        let canonicalMediaId: String
        let mediaKind: MediaKind
    }

    private struct TrackerKey: Hashable {
        let pluginId: String
        let canonicalMediaId: String
        let mediaKind: MediaKind
        let providerId: String
    }

    private struct IdentityAliasKey: Hashable {
        let pluginId: String
        let aliasKind: String
        let aliasValue: String
    }

    private struct PluginSettingKey: Hashable {
        let pluginId: String
        let key: String
    }

    private struct HistorySemanticKey: Hashable {
        let pluginId: String
        let canonicalMediaId: String
        let mediaKind: MediaKind
        let chapterKey: String
        let readAt: Date
    }

    private struct SourceMappingKey: Hashable {
        let canonicalProvider: String
        let canonicalMediaId: String
        let mediaType: String
        let pluginId: String
        let pluginMediaKey: String
    }

    private struct UnscopedKey: Hashable {
        let sourceKey: String
        let legacyMediaId: String
        let fingerprint: String
    }

    private struct ArchiveKey: Hashable {
        let sourceDomain: String
        let sourceKey: String
        let contentClass: LegacyArchiveContentClass
        let valueType: String
        let fingerprint: String
    }

    let dbPool: DatabasePool
    let standardApplicationDomain: String
    let operationIdProvider: @Sendable () -> String
    let now: @Sendable () -> Date
    let afterPreflightBeforeTransaction: (@Sendable () throws -> Void)?
    let lateTransactionFailure: LateTransactionFailure?

    init(
        dbPool: DatabasePool,
        standardApplicationDomain: String = Bundle.main.bundleIdentifier ?? "moe.itoapp.ito",
        operationIdProvider: @escaping @Sendable () -> String = {
            UUID().uuidString
        },
        now: @escaping @Sendable () -> Date = Date.init,
        afterPreflightBeforeTransaction: (@Sendable () throws -> Void)? = nil,
        lateTransactionFailure: LateTransactionFailure? = nil
    ) {
        self.dbPool = dbPool
        self.standardApplicationDomain = standardApplicationDomain
        self.operationIdProvider = operationIdProvider
        self.now = now
        self.afterPreflightBeforeTransaction = afterPreflightBeforeTransaction
        self.lateTransactionFailure = lateTransactionFailure
    }

    func restore(
        _ backup: ImportedBackup,
        mode: BackupRestoreMode,
        operationId requestedOperationId: String? = nil,
        resolvedConflicts: [String: ConflictResolution] = [:]
    ) async throws -> BackupRestoreReport {
        let operationId = requestedOperationId ?? operationIdProvider()
        guard !operationId.isEmpty else {
            throw BackupPreflightError.rejected(
                .invalidComponentData(component: .libraryCore, code: "emptyOperationId")
            )
        }

        return try await dbPool.writeWithoutTransaction { db in
            let local = try fetchLocalState(db)
            let plan = try makePlan(
                backup: backup,
                mode: mode,
                operationId: operationId,
                createdAt: now(),
                resolvedConflicts: resolvedConflicts,
                local: local
            )
            try afterPreflightBeforeTransaction?()
            var result: BackupRestoreReport?
            try db.inTransaction {
                result = try execute(plan, db: db)
                return .commit
            }
            guard let result else {
                throw BackupPreflightError.rejected(
                    .invalidComponentData(
                        component: .libraryCore,
                        code: "missingTransactionResult"
                    )
                )
            }
            return result
        }
    }

    private func execute(
        _ plan: RestorePlan,
        db: Database
    ) throws -> BackupRestoreReport {
        var outcomes = Dictionary(
            uniqueKeysWithValues: plan.represented.map {
                ($0, MutableOutcome())
            }
        )
        try restoreLibrary(plan, db: db, outcomes: &outcomes)
        try restoreHistory(plan, db: db, outcomes: &outcomes)
        try repairRetainedHistoryPointers(plan, db: db, outcomes: &outcomes)
        try restoreSourceMappings(plan, db: db, outcomes: &outcomes)
        try restorePreferences(plan, db: db, outcomes: &outcomes)
        try restoreReadProgress(plan, db: db, outcomes: &outcomes)
        try restoreTrackerLinks(plan, db: db, outcomes: &outcomes)
        try restoreUpdateBadges(plan, db: db, outcomes: &outcomes)
        try restoreRepositories(plan, db: db, outcomes: &outcomes)
        try restoreImporterAliases(plan, db: db, outcomes: &outcomes)
        try restorePluginIdentity(plan, db: db, outcomes: &outcomes)
        try restorePluginSettings(plan, db: db, outcomes: &outcomes)
        try restoreUnscopedMediaState(plan, db: db, outcomes: &outcomes)
        try restoreArchives(plan, db: db, outcomes: &outcomes)

        let report = try makeReport(plan: plan, outcomes: outcomes)
        let journal = BackupRestoreJournalRecord(
            operationId: plan.operationId,
            status: .pendingRefresh,
            reportPayload: try JSONEncoder().encode(report),
            updatedAt: plan.createdAt
        )
        try journal.save(db)
        try lateTransactionFailure?(db)
        return report
    }

    private func fetchLocalState(_ db: Database) throws -> LocalState {
        try LocalState(
            categories: LibraryCategory.fetchAll(db),
            items: LibraryItem.fetchAll(db),
            links: ItemCategoryLink.fetchAll(db),
            history: ReadingHistoryRecord.fetchAll(db),
            preferences: AppPreference.fetchAll(db),
            readProgressKeys: ReadProgressKeyRecord.fetchAll(db),
            readProgressNumbers: ReadProgressNumberRecord.fetchAll(db),
            mediaReadProgress: MediaReadProgressRecord.fetchAll(db),
            trackerLinks: TrackerLinkRecord.fetchAll(db),
            updateBadges: UpdateBadgeRecord.fetchAll(db),
            repositories: RepositoryRecord.fetchAll(db),
            importerAliases: PluginMigrationAliasRecord.fetchAll(db),
            pluginIdentities: PluginIdentityRecord.fetchAll(db),
            pluginIdentityAliases: PluginIdentityAliasRecord.fetchAll(db),
            pluginSettings: PluginSettingRecord.fetchAll(db),
            unscopedMediaState: LegacyUnscopedMediaStateRecord.fetchAll(db),
            archives: LegacyStateArchiveRecord.fetchAll(db)
        )
    }

    private func makePlan(
        backup: ImportedBackup,
        mode: BackupRestoreMode,
        operationId: String,
        createdAt: Date,
        resolvedConflicts: [String: ConflictResolution],
        local: LocalState
    ) throws -> RestorePlan {
        try backup.validateCapabilityMetadata()
        var represented = Set(backup.representedComponents)
        if backup.metadata == nil, backup.items.contains(where: { $0.anilistId != nil }) {
            represented.insert(.trackerLinks)
        }
        try validateRepresentationPayloads(backup, represented: represented)
        try validateComponentData(backup)
        let library = try makeLibraryPlan(
            backup: backup,
            mode: mode,
            represented: represented,
            local: local
        )
        let repositories = try normalizedRepositories(backup.repositories)
        let trackerLinks = try synthesizedTrackerLinks(
            backup: backup,
            represented: represented
        )

        try validateLibraryClosure(
            backup: backup,
            mode: mode,
            represented: represented,
            local: local,
            library: library
        )
        try validateMediaCollisions(
            backup: backup,
            represented: represented,
            library: library,
            trackerLinks: trackerLinks
        )
        try validatePluginIdentityDAG(
            backup: backup,
            mode: mode,
            represented: represented,
            local: local
        )
        try validateCredentialPayloads(backup.legacyStateArchives)

        return RestorePlan(
            backup: backup,
            mode: mode,
            operationId: operationId,
            createdAt: createdAt,
            represented: represented,
            resolvedConflicts: resolvedConflicts,
            library: library,
            repositories: repositories,
            trackerLinks: trackerLinks
        )
    }

    private func validateRepresentationPayloads(
        _ backup: ImportedBackup,
        represented: Set<BackupComponent>
    ) throws {
        for component in BackupComponent.allCases {
            let representation = backup.representation(of: component)
            let hasRows = componentHasRows(component, backup: backup)
            if !represented.contains(component), hasRows {
                throw rejection(
                    .invalidCapabilityMetadata(
                        component: component,
                        code: "unrepresentedContainsRows"
                    )
                )
            }
            if representation == .representedEmpty, hasRows {
                throw rejection(
                    .invalidCapabilityMetadata(
                        component: component,
                        code: "representedEmptyContainsRows"
                    )
                )
            }
            if representation == .representedNonempty, !hasRows {
                throw rejection(
                    .invalidCapabilityMetadata(
                        component: component,
                        code: "representedNonemptyWithoutRows"
                    )
                )
            }
        }

        let preferenceKeys = Set(backup.representedPreferenceKeys)
        for preference in backup.preferences where !preferenceKeys.contains(preference.key) {
            throw rejection(
                .invalidKeyData(
                    component: .scalarAppPreferences,
                    key: preference.key,
                    code: "unrepresentedPreference"
                )
            )
        }
        if backup.metadata != nil,
           backup.representation(of: .scalarAppPreferences) == .representedNonempty {
            let catalog = Set(AppPreferenceCatalogEntry.allCases.map(\.rawValue))
            guard preferenceKeys == catalog,
                  Set(backup.preferences.map(\.key)) == catalog else {
                throw rejection(
                    .invalidCapabilityMetadata(
                        component: .scalarAppPreferences,
                        code: "incompletePreferenceCatalog"
                    )
                )
            }
        }
    }

    private func componentHasRows(
        _ component: BackupComponent,
        backup: ImportedBackup
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
                || (
                    backup.metadata == nil
                        && backup.items.contains(where: { $0.anilistId != nil })
                )
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

    private func validateComponentData(_ backup: ImportedBackup) throws {
        try requireUnique(
            backup.categories.map(\.id),
            component: .libraryCore,
            code: "duplicateCategory"
        )
        try requireUnique(
            backup.items.map(\.id),
            component: .libraryCore,
            code: "duplicateItemId"
        )
        try requireUnique(
            backup.links.map { "\($0.itemId)\u{1F}\($0.categoryId)" },
            component: .libraryCore,
            code: "duplicateCategoryLink"
        )
        try requireUnique(
            backup.history.map(\.id),
            component: .readingHistory,
            code: "duplicateHistoryId"
        )
        try validateSourceMappings(backup.sourceMappings)
        try requireUnique(
            backup.preferences.map(\.key),
            component: .scalarAppPreferences,
            code: "duplicatePreference"
        )
        try requireUnique(
            backup.repositories.map(\.url),
            component: .repositories,
            code: "duplicateRepository"
        )
        try requireUnique(
            backup.importerAliases.map(\.foreignId),
            component: .userImporterAliases,
            code: "duplicateImporterAlias"
        )
        try requireUnique(
            backup.pluginIdentities.map(\.pluginId),
            component: .pluginIdentityAndAliases,
            code: "duplicatePluginIdentity"
        )
        try requireUnique(
            backup.pluginIdentityAliases.map {
                "\($0.pluginId)\u{1F}\($0.aliasKind)\u{1F}\($0.aliasValue)"
            },
            component: .pluginIdentityAndAliases,
            code: "duplicatePluginIdentityAlias"
        )
        try requireUnique(
            backup.pluginSettings.map { "\($0.pluginId)\u{1F}\($0.key)" },
            component: .pluginSettings,
            code: "duplicatePluginSetting"
        )

        for category in backup.categories {
            try requireNonempty(
                category.id,
                component: .libraryCore,
                code: "emptyCategoryId"
            )
        }
        for item in backup.items {
            try requireNonempty(item.id, component: .libraryCore, code: "emptyItemId")
            try requireNonempty(
                item.pluginId,
                component: .libraryCore,
                code: "emptyPluginId"
            )
        }
        for link in backup.links {
            try requireNonempty(
                link.itemId,
                component: .libraryCore,
                code: "emptyLinkItemId"
            )
            try requireNonempty(
                link.categoryId,
                component: .libraryCore,
                code: "emptyLinkCategoryId"
            )
        }
        for history in backup.history {
            try requireNonempty(
                history.pluginId,
                component: .readingHistory,
                code: "emptyPluginId"
            )
            try requireNonempty(
                history.mediaKey,
                component: .readingHistory,
                code: "emptyMediaIdentity"
            )
            try requireNonempty(
                history.chapterKey,
                component: .readingHistory,
                code: "emptyChapterKey"
            )
        }
        try validatePreferences(backup)
        try validateScopedRecords(backup)
        try validatePluginRecords(backup)
        try validateRecoveryRecords(backup)
    }

    private func validateSourceMappings(
        _ records: [SourceMappingRecord]
    ) throws {
        var recordsByKey: [SourceMappingKey: SourceMappingRecord] = [:]
        for record in records {
            for value in [
                record.canonicalProvider,
                record.canonicalMediaId,
                record.pluginId,
                record.pluginMediaKey
            ] where value.isEmpty {
                throw rejection(
                    .invalidComponentData(
                        component: .sourceMappings,
                        code: "invalidLogicalIdentity"
                    )
                )
            }
            guard record.confidence.isFinite else {
                throw rejection(
                    .invalidComponentData(
                        component: .sourceMappings,
                        code: "invalidConfidence"
                    )
                )
            }

            let key = sourceMappingKey(record)
            if let existing = recordsByKey[key] {
                throw rejection(
                    .invalidComponentData(
                        component: .sourceMappings,
                        code: existing == record
                            ? "duplicateLogicalIdentity"
                            : "conflictingLogicalIdentity"
                    )
                )
            }
            recordsByKey[key] = record
        }
    }

    private func validatePreferences(_ backup: ImportedBackup) throws {
        for key in backup.representedPreferenceKeys {
            guard let entry = AppPreferenceCatalogEntry(rawValue: key) else {
                throw rejection(
                    .invalidKeyData(
                        component: .scalarAppPreferences,
                        key: key,
                        code: "unknownKey"
                    )
                )
            }
            guard let preference = backup.preferences.first(where: { $0.key == key })
            else {
                continue
            }
            guard let value = try? JSONSerialization.jsonObject(
                with: preference.value,
                options: [.fragmentsAllowed]
            ), entry.acceptsLegacyValue(value) else {
                throw rejection(
                    .invalidKeyData(
                        component: .scalarAppPreferences,
                        key: key,
                        code: "invalidValue"
                    )
                )
            }
        }
    }

    private func validateScopedRecords(_ backup: ImportedBackup) throws {
        for record in backup.readProgressKeys {
            try requireMediaIdentity(
                pluginId: record.pluginId,
                canonicalMediaId: record.canonicalMediaId,
                component: .readProgressAndResume
            )
            try requireNonempty(
                record.chapterKey,
                component: .readProgressAndResume,
                code: "emptyChapterKey"
            )
        }
        for record in backup.readProgressNumbers {
            try requireMediaIdentity(
                pluginId: record.pluginId,
                canonicalMediaId: record.canonicalMediaId,
                component: .readProgressAndResume
            )
            guard record.chapterNumber.isFinite else {
                throw rejection(
                    .invalidComponentData(
                        component: .readProgressAndResume,
                        code: "invalidChapterNumber"
                    )
                )
            }
        }
        for record in backup.mediaReadProgress {
            try requireMediaIdentity(
                pluginId: record.pluginId,
                canonicalMediaId: record.canonicalMediaId,
                component: .readProgressAndResume
            )
            try requireNonempty(
                record.lastReadChapterKey,
                component: .readProgressAndResume,
                code: "emptyResumeChapterKey"
            )
        }
        for record in backup.trackerLinks {
            try requireMediaIdentity(
                pluginId: record.pluginId,
                canonicalMediaId: record.canonicalMediaId,
                component: .trackerLinks
            )
            try requireNonempty(
                record.providerId,
                component: .trackerLinks,
                code: "emptyProviderId"
            )
            try requireNonempty(
                record.remoteMediaId,
                component: .trackerLinks,
                code: "emptyRemoteMediaId"
            )
        }
        for record in backup.updateBadges {
            try requireMediaIdentity(
                pluginId: record.pluginId,
                canonicalMediaId: record.canonicalMediaId,
                component: .updateBadges
            )
            guard record.count >= 0 else {
                throw rejection(
                    .invalidComponentData(
                        component: .updateBadges,
                        code: "negativeCount"
                    )
                )
            }
        }
    }

    private func validatePluginRecords(_ backup: ImportedBackup) throws {
        for identity in backup.pluginIdentities {
            try requireNonempty(
                identity.pluginId,
                component: .pluginIdentityAndAliases,
                code: "emptyPluginId"
            )
        }
        for alias in backup.pluginIdentityAliases {
            try requireNonempty(
                alias.pluginId,
                component: .pluginIdentityAndAliases,
                code: "emptyPluginId"
            )
            try requireNonempty(
                alias.aliasKind,
                component: .pluginIdentityAndAliases,
                code: "emptyAliasKind"
            )
            try requireNonempty(
                alias.aliasValue,
                component: .pluginIdentityAndAliases,
                code: "emptyAliasValue"
            )
        }
        for alias in backup.importerAliases {
            try requireNonempty(
                alias.foreignId,
                component: .userImporterAliases,
                code: "emptyForeignId"
            )
            try requireNonempty(
                alias.pluginId,
                component: .userImporterAliases,
                code: "emptyPluginId"
            )
        }
        for setting in backup.pluginSettings {
            try requireNonempty(
                setting.pluginId,
                component: .pluginSettings,
                code: "emptyPluginId"
            )
            try requireNonempty(
                setting.key,
                component: .pluginSettings,
                code: "emptySettingKey"
            )
        }
    }

    private func validateRecoveryRecords(_ backup: ImportedBackup) throws {
        var unscopedKeys = Set<UnscopedKey>()
        for record in backup.legacyUnscopedMediaState {
            for value in [record.sourceKey, record.legacyMediaId, record.fingerprint]
            where value.isEmpty {
                throw rejection(
                    .invalidComponentData(
                        component: .legacyUnscopedMediaState,
                        code: "invalidLogicalIdentity"
                    )
                )
            }
            let logicalKey = UnscopedKey(
                sourceKey: record.sourceKey,
                legacyMediaId: record.legacyMediaId,
                fingerprint: record.fingerprint
            )
            guard unscopedKeys.insert(logicalKey).inserted else {
                throw rejection(
                    .invalidComponentData(
                        component: .legacyUnscopedMediaState,
                        code: "duplicateLogicalIdentity"
                    )
                )
            }
            guard CanonicalPropertyListCapture.digest(record.canonicalPayload)
                    == record.fingerprint else {
                throw rejection(
                    .invalidKeyData(
                        component: .legacyUnscopedMediaState,
                        key: record.sourceKey,
                        code: "payloadFingerprintMismatch"
                    )
                )
            }
        }
        var archiveKeys = Set<ArchiveKey>()
        for record in backup.legacyStateArchives {
            for value in [
                record.sourceDomain,
                record.sourceKey,
                record.valueType,
                record.fingerprint
            ] where value.isEmpty {
                throw rejection(
                    .invalidComponentData(
                        component: .legacyStateArchive,
                        code: "invalidLogicalIdentity"
                    )
                )
            }
            let logicalKey = ArchiveKey(
                sourceDomain: record.sourceDomain,
                sourceKey: record.sourceKey,
                contentClass: record.contentClass,
                valueType: record.valueType,
                fingerprint: record.fingerprint
            )
            guard archiveKeys.insert(logicalKey).inserted else {
                throw rejection(
                    .invalidComponentData(
                        component: .legacyStateArchive,
                        code: "duplicateLogicalIdentity"
                    )
                )
            }
            guard CanonicalPropertyListCapture.digest(record.valuePayload)
                    == record.fingerprint else {
                throw rejection(
                    .invalidKeyData(
                        component: .legacyStateArchive,
                        key: record.sourceKey,
                        code: "payloadFingerprintMismatch"
                    )
                )
            }
        }
    }

    private func makeLibraryPlan(
        backup: ImportedBackup,
        mode: BackupRestoreMode,
        represented: Set<BackupComponent>,
        local: LocalState
    ) throws -> LibraryPlan {
        let localItems = mode == .merge || !represented.contains(.libraryCore)
            ? local.items
            : []
        let localByIdentity = Dictionary(grouping: localItems) {
            ImportedMediaIdentity.key(itemId: $0.id, pluginId: $0.pluginId, mediaKind: $0.effectiveType)
        }
        var seenImportedIdentities = Set<ImportedMediaIdentity.Key>()
        var dispositions: [ItemDisposition] = []

        for item in backup.items.sorted(by: { $0.id < $1.id }) {
            let identity = ImportedMediaIdentity.key(
                itemId: item.id,
                pluginId: item.pluginId,
                mediaKind: item.effectiveType
            )
            guard seenImportedIdentities.insert(identity).inserted else {
                throw rejection(
                    .mediaIdentityCollision(
                        pluginId: identity.pluginId,
                        canonicalMediaId: identity.canonicalMediaId
                    )
                )
            }
            let localMatches = localByIdentity[identity] ?? []
            guard localMatches.count <= 1 else {
                throw rejection(
                    .mediaIdentityCollision(
                        pluginId: identity.pluginId,
                        canonicalMediaId: identity.canonicalMediaId
                    )
                )
            }
            dispositions.append(
                ItemDisposition(
                    imported: item,
                    targetId: localMatches.first?.id ?? item.id,
                    isPreexisting: !localMatches.isEmpty
                )
            )
        }

        let targetIdByImportedId = Dictionary(
            uniqueKeysWithValues: dispositions.map { ($0.imported.id, $0.targetId) }
        )
        let targetIdentityBySourceIdentity = Dictionary(
            uniqueKeysWithValues: dispositions.map {
                (
                    $0.sourceIdentity,
                    ImportedMediaIdentity.key(
                        itemId: $0.targetId,
                        pluginId: $0.imported.pluginId,
                        mediaKind: $0.imported.effectiveType
                    )
                )
            }
        )

        return LibraryPlan(
            dispositions: dispositions,
            targetIdByImportedId: targetIdByImportedId,
            targetIdentityBySourceIdentity: targetIdentityBySourceIdentity,
            currentSystemCategoryId: mode == .merge
                ? local.categories.first(where: \.isSystemCategory)?.id
                : nil,
            importedSystemCategoryId: backup.categories.first(where: \.isSystemCategory)?.id
        )
    }

    private func validateLibraryClosure(
        backup: ImportedBackup,
        mode: BackupRestoreMode,
        represented: Set<BackupComponent>,
        local: LocalState,
        library: LibraryPlan
    ) throws {
        guard represented.contains(.libraryCore) else {
            return
        }
        var itemIds = mode == .merge ? Set(local.items.map(\.id)) : []
        itemIds.formUnion(library.dispositions.map(\.targetId))

        var categoryIds: Set<String>
        if mode == .merge {
            categoryIds = Set(local.categories.map(\.id))
            categoryIds.formUnion(
                backup.categories.filter { !$0.isSystemCategory }.map(\.id)
            )
            if let currentSystem = library.currentSystemCategoryId {
                categoryIds.insert(currentSystem)
            } else if let importedSystem = library.importedSystemCategoryId {
                categoryIds.insert(importedSystem)
            }
        } else {
            categoryIds = Set(backup.categories.map(\.id))
        }

        for link in backup.links {
            let itemId = library.targetIdByImportedId[link.itemId] ?? link.itemId
            let categoryId = remappedCategoryId(link.categoryId, library: library)
            guard itemIds.contains(itemId), categoryIds.contains(categoryId) else {
                throw rejection(
                    .invalidLibraryClosure(
                        itemId: link.itemId,
                        categoryId: link.categoryId
                    )
                )
            }
        }
    }

    private func validateMediaCollisions(
        backup: ImportedBackup,
        represented: Set<BackupComponent>,
        library: LibraryPlan,
        trackerLinks: [TrackerLinkRecord]
    ) throws {
        if represented.contains(.readProgressAndResume) {
            try requireUniqueMediaTargets(
                backup.readProgressKeys.map {
                    let identity = remappedIdentity(
                        pluginId: $0.pluginId,
                        canonicalMediaId: $0.canonicalMediaId,
                        mediaKind: $0.mediaKind,
                        library: library
                    )
                    return (
                        identity,
                        "\(identity.pluginId)\u{1F}\(identity.canonicalMediaId)\u{1F}\(identity.mediaKind.rawValue)"
                            + "\u{1F}\($0.chapterKey)"
                    )
                }
            )
            try requireUniqueMediaTargets(
                backup.readProgressNumbers.map {
                    let identity = remappedIdentity(
                        pluginId: $0.pluginId,
                        canonicalMediaId: $0.canonicalMediaId,
                        mediaKind: $0.mediaKind,
                        library: library
                    )
                    return (
                        identity,
                        "\(identity.pluginId)\u{1F}\(identity.canonicalMediaId)\u{1F}\(identity.mediaKind.rawValue)"
                            + "\u{1F}\($0.chapterNumber)"
                    )
                }
            )
            try requireUniqueMediaTargets(
                backup.mediaReadProgress.map {
                    let identity = remappedIdentity(
                        pluginId: $0.pluginId,
                        canonicalMediaId: $0.canonicalMediaId,
                        mediaKind: $0.mediaKind,
                        library: library
                    )
                    return (
                        identity,
                        "\(identity.pluginId)\u{1F}\(identity.canonicalMediaId)\u{1F}\(identity.mediaKind.rawValue)"
                    )
                }
            )
        }
        if represented.contains(.trackerLinks) {
            try requireUniqueMediaTargets(
                trackerLinks.map {
                    let identity = remappedIdentity(
                        pluginId: $0.pluginId,
                        canonicalMediaId: $0.canonicalMediaId,
                        mediaKind: $0.mediaKind,
                        library: library
                    )
                    return (
                        identity,
                        "\(identity.pluginId)\u{1F}\(identity.canonicalMediaId)\u{1F}\(identity.mediaKind.rawValue)"
                            + "\u{1F}\($0.providerId)"
                    )
                }
            )
        }
        if represented.contains(.updateBadges) {
            try requireUniqueMediaTargets(
                backup.updateBadges.map {
                    let identity = remappedIdentity(
                        pluginId: $0.pluginId,
                        canonicalMediaId: $0.canonicalMediaId,
                        mediaKind: $0.mediaKind,
                        library: library
                    )
                    return (
                        identity,
                        "\(identity.pluginId)\u{1F}\(identity.canonicalMediaId)\u{1F}\(identity.mediaKind.rawValue)"
                    )
                }
            )
        }
    }

    private func requireUniqueMediaTargets(
        _ identitiesAndKeys: [(ImportedMediaIdentity.Key, String)]
    ) throws {
        var seen = Set<String>()
        for (identity, key) in identitiesAndKeys where !seen.insert(key).inserted {
            throw rejection(
                .mediaIdentityCollision(
                    pluginId: identity.pluginId,
                    canonicalMediaId: identity.canonicalMediaId
                )
            )
        }
    }

    private func validatePluginIdentityDAG(
        backup: ImportedBackup,
        mode: BackupRestoreMode,
        represented: Set<BackupComponent>,
        local: LocalState
    ) throws {
        let registryRepresented = represented.contains(.pluginIdentityAndAliases)
        var identities = mode == .wipe && registryRepresented
            ? Set<String>()
            : Set(local.pluginIdentities.map(\.pluginId))
        identities.formUnion(backup.pluginIdentities.map(\.pluginId))

        let retainedIdentityAliases = mode == .wipe && registryRepresented
            ? []
            : local.pluginIdentityAliases
        let finalIdentityAliases = retainedIdentityAliases + backup.pluginIdentityAliases
        let suites = Dictionary(
            grouping: finalIdentityAliases.compactMap { alias -> (String, String)? in
                alias.suiteDomain.map { ($0, alias.pluginId) }
            },
            by: \.0
        )
        for (suite, entries) in suites
        where Set(entries.map(\.1)).count > 1 {
            throw rejection(.ambiguousPluginIdentity(identity: suite))
        }

        for alias in backup.pluginIdentityAliases
        where !identities.contains(alias.pluginId) {
            throw rejection(.missingPluginIdentity(pluginId: alias.pluginId))
        }
        for setting in backup.pluginSettings
        where !identities.contains(setting.pluginId) {
            throw rejection(.missingPluginIdentity(pluginId: setting.pluginId))
        }
        for alias in backup.importerAliases
        where !identities.contains(alias.pluginId) {
            throw rejection(.missingPluginIdentity(pluginId: alias.pluginId))
        }

        let retainedSettings = mode == .wipe && represented.contains(.pluginSettings)
            ? []
            : local.pluginSettings
        for setting in retainedSettings where !identities.contains(setting.pluginId) {
            throw rejection(
                .orphanedRetainedPluginState(
                    pluginId: setting.pluginId,
                    component: .pluginSettings
                )
            )
        }
        let retainedImporterAliases =
            mode == .wipe && represented.contains(.userImporterAliases)
            ? []
            : local.importerAliases
        for alias in retainedImporterAliases where !identities.contains(alias.pluginId) {
            throw rejection(
                .orphanedRetainedPluginState(
                    pluginId: alias.pluginId,
                    component: .userImporterAliases
                )
            )
        }
    }

    private func validateCredentialPayloads(
        _ archives: [LegacyStateArchiveRecord]
    ) throws {
        for archive in archives {
            let tuple = LegacyDefaultsSourceTuple(
                sourceDomain: archive.sourceDomain,
                sourceKey: archive.sourceKey
            )
            guard tuple.classification(
                standardApplicationDomain: standardApplicationDomain
            ) != .appManagedCredential else {
                throw rejection(
                    .credentialPayloadRejected(
                        sourceDomain: archive.sourceDomain,
                        sourceKey: archive.sourceKey
                    )
                )
            }
        }
    }

    private func normalizedRepositories(
        _ repositories: [RepositoryRecord]
    ) throws -> [RepositoryRecord] {
        var result: [RepositoryRecord] = []
        var seen = Set<String>()
        for repository in repositories {
            let normalized = normalizeRepositoryURL(repository.url)
            guard let normalized,
                  seen.insert(normalized).inserted else {
                throw rejection(
                    .invalidComponentData(
                        component: .repositories,
                        code: normalized == nil ? "invalidURL" : "duplicateNormalizedURL"
                    )
                )
            }
            result.append(
                RepositoryRecord(
                    url: normalized,
                    lastFetched: repository.lastFetched,
                    indexPayload: repository.indexPayload
                )
            )
        }
        return result.sorted { $0.url < $1.url }
    }

    private func normalizeRepositoryURL(_ raw: String) -> String? {
        guard var components = URLComponents(
            string: raw.trimmingCharacters(in: .whitespacesAndNewlines)
        ), let scheme = components.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           !(components.host ?? "").isEmpty else {
            return nil
        }
        components.scheme = scheme
        if components.path.hasSuffix("/index.json") {
            components.path.removeLast("/index.json".count)
        }
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url?.absoluteString
    }

    private func synthesizedTrackerLinks(
        backup: ImportedBackup,
        represented: Set<BackupComponent>
    ) throws -> [TrackerLinkRecord] {
        guard represented.contains(.trackerLinks) else {
            return backup.trackerLinks
        }
        if backup.metadata != nil,
           backup.representation(of: .trackerLinks) == .representedEmpty {
            return backup.trackerLinks
        }
        var result = backup.trackerLinks
        var keys = Set(result.map {
            TrackerKey(
                pluginId: $0.pluginId,
                canonicalMediaId: $0.canonicalMediaId,
                mediaKind: $0.mediaKind,
                providerId: $0.providerId
            )
        })
        for item in backup.items {
            guard let anilistId = item.anilistId else {
                continue
            }
            let key = TrackerKey(
                pluginId: item.pluginId,
                canonicalMediaId: ImportedMediaIdentity.canonicalMediaId(
                    itemId: item.id,
                    pluginId: item.pluginId,
                    mediaKind: item.effectiveType
                ),
                mediaKind: item.effectiveType,
                providerId: "anilist"
            )
            guard keys.insert(key).inserted else {
                continue
            }
            result.append(
                TrackerLinkRecord(
                    pluginId: key.pluginId,
                    canonicalMediaId: key.canonicalMediaId,
                    mediaKind: key.mediaKind,
                    providerId: key.providerId,
                    remoteMediaId: String(anilistId),
                    updatedAt: nil,
                    provenance: .legacyUnknownTime
                )
            )
        }
        return result
    }

    private func restoreLibrary(
        _ plan: RestorePlan,
        db: Database,
        outcomes: inout [BackupComponent: MutableOutcome]
    ) throws {
        guard plan.represented.contains(.libraryCore) else {
            return
        }
        if plan.mode == .wipe {
            outcomes[.libraryCore]?.replaced += try ItemCategoryLink.deleteAll(db)
            outcomes[.libraryCore]?.replaced += try LibraryItem.deleteAll(db)
            outcomes[.libraryCore]?.replaced += try LibraryCategory.deleteAll(db)
        }

        for category in plan.backup.categories.sorted(by: { $0.id < $1.id }) {
            if plan.mode == .merge,
               category.isSystemCategory,
               plan.library.currentSystemCategoryId != nil {
                outcomes[.libraryCore]?.skipped += 1
                continue
            }
            try mergeOrInsert(
                category,
                key: category.id,
                mode: plan.mode,
                component: .libraryCore,
                db: db,
                outcomes: &outcomes,
                equals: ==
            )
        }

        for disposition in plan.library.dispositions {
            let item = retarget(disposition.imported, to: disposition.targetId)
            if let local = try LibraryItem.fetchOne(db, key: disposition.targetId) {
                if semanticallyEqual(local, item) {
                    outcomes[.libraryCore]?.skipped += 1
                } else if plan.mode == .merge,
                          !keepsBackup(
                            plan.resolvedConflicts[disposition.targetId]
                          ) {
                    outcomes[.libraryCore]?.preservedLocal += 1
                } else {
                    try item.save(db)
                    outcomes[.libraryCore]?.replaced += 1
                }
            } else {
                try item.insert(db)
                outcomes[.libraryCore]?.inserted += 1
            }
        }

        if plan.mode == .merge {
            for disposition in plan.library.dispositions
            where disposition.isPreexisting
                && keepsBackup(plan.resolvedConflicts[disposition.targetId]) {
                outcomes[.libraryCore]?.replaced += try ItemCategoryLink
                    .filter(Column("itemId") == disposition.targetId)
                    .deleteAll(db)
            }
        }
        for link in plan.backup.links.sorted(by: linkSort) {
            let disposition = plan.library.dispositions.first {
                $0.imported.id == link.itemId
            }
            if plan.mode == .merge,
               let disposition,
               disposition.isPreexisting,
               !keepsBackup(plan.resolvedConflicts[disposition.targetId]) {
                outcomes[.libraryCore]?.skipped += 1
                continue
            }
            let rewritten = ItemCategoryLink(
                itemId: plan.library.targetIdByImportedId[link.itemId] ?? link.itemId,
                categoryId: remappedCategoryId(link.categoryId, library: plan.library),
                addedAt: link.addedAt
            )
            let key: [String: DatabaseValueConvertible] = [
                "itemId": rewritten.itemId,
                "categoryId": rewritten.categoryId
            ]
            if try ItemCategoryLink.fetchOne(db, key: key) == nil {
                try rewritten.insert(db)
                outcomes[.libraryCore]?.inserted += 1
            } else {
                outcomes[.libraryCore]?.skipped += 1
            }
        }
        // A wipe can remove the system list, and backups from installs that never had one
        // carry series in no list. Both end up in Uncategorized.
        try AppDatabase.ensureSystemCategory(in: db)
    }

    private func restoreHistory(
        _ plan: RestorePlan,
        db: Database,
        outcomes: inout [BackupComponent: MutableOutcome]
    ) throws {
        guard plan.represented.contains(.readingHistory) else {
            return
        }
        if plan.mode == .wipe {
            outcomes[.readingHistory]?.replaced += try ReadingHistoryRecord.deleteAll(db)
        }

        var existingById = Dictionary(
            uniqueKeysWithValues: try ReadingHistoryRecord.fetchAll(db).map { ($0.id, $0) }
        )
        var semanticKeys = Set(existingById.values.map(historySemanticKey))
        for history in plan.backup.history.sorted(by: historySort) {
            let disposition = disposition(for: history, library: plan.library)
            if plan.mode == .merge,
               let disposition,
               disposition.isPreexisting,
               !keepsBackup(plan.resolvedConflicts[disposition.targetId]) {
                outcomes[.readingHistory]?.skipped += 1
                continue
            }
            let rewritten = retarget(history, library: plan.library)
            let semanticKey = historySemanticKey(rewritten)
            if let existing = existingById[rewritten.id] {
                if existing == rewritten
                    || (
                        plan.mode == .merge
                            && semanticKeys.contains(semanticKey)
                    ) {
                    outcomes[.readingHistory]?.skipped += 1
                } else {
                    outcomes[.readingHistory]?.preservedLocal += 1
                }
                continue
            }
            guard plan.mode != .merge || !semanticKeys.contains(semanticKey) else {
                outcomes[.readingHistory]?.skipped += 1
                continue
            }
            try rewritten.insert(db)
            existingById[rewritten.id] = rewritten
            semanticKeys.insert(semanticKey)
            outcomes[.readingHistory]?.inserted += 1
        }
    }

    private func repairRetainedHistoryPointers(
        _ plan: RestorePlan,
        db: Database,
        outcomes: inout [BackupComponent: MutableOutcome]
    ) throws {
        guard plan.represented.contains(.libraryCore),
              !plan.represented.contains(.readingHistory) else {
            return
        }
        let finalItems = try LibraryItem.fetchAll(db)
        let finalById = Dictionary(uniqueKeysWithValues: finalItems.map { ($0.id, $0) })
        let finalByIdentity = Dictionary(grouping: finalItems) {
            ImportedMediaIdentity.key(itemId: $0.id, pluginId: $0.pluginId, mediaKind: $0.effectiveType)
        }
        let dispositionByImportedId = Dictionary(
            uniqueKeysWithValues: plan.library.dispositions.map {
                ($0.imported.id, $0)
            }
        )
        var repaired = 0

        for var history in try ReadingHistoryRecord.fetchAll(db) {
            guard let pointer = history.libraryItemId else {
                continue
            }
            let historyIdentity = ImportedMediaIdentity.key(
                itemId: history.mediaKey,
                pluginId: history.pluginId,
                mediaKind: history.mediaKind
            )
            let replacement: String?
            if let disposition = dispositionByImportedId[pointer],
               disposition.sourceIdentity == historyIdentity,
               let finalItem = finalById[disposition.targetId],
               ImportedMediaIdentity.key(
                itemId: finalItem.id,
                pluginId: finalItem.pluginId,
                mediaKind: finalItem.effectiveType
               ) == historyIdentity {
                replacement = disposition.targetId
            } else {
                let matches = finalByIdentity[historyIdentity] ?? []
                replacement = matches.count == 1 ? matches[0].id : nil
            }
            guard replacement != pointer else {
                continue
            }
            history.libraryItemId = replacement
            try history.update(db)
            repaired += 1
        }
        guard repaired > 0 else {
            return
        }
        outcomes[.readingHistory, default: MutableOutcome()]
            .dependencyRepaired += repaired
    }

    private func restorePreferences(
        _ plan: RestorePlan,
        db: Database,
        outcomes: inout [BackupComponent: MutableOutcome]
    ) throws {
        guard plan.represented.contains(.scalarAppPreferences) else {
            return
        }
        let representedKeys: Set<String>
        if plan.backup.metadata != nil {
            representedKeys = Set(AppPreferenceCatalogEntry.allCases.map(\.rawValue))
        } else {
            representedKeys = Set(plan.backup.representedPreferenceKeys)
        }
        if plan.mode == .wipe {
            for key in representedKeys.sorted()
            where try AppPreference.deleteOne(db, key: key) {
                outcomes[.scalarAppPreferences]?.replaced += 1
            }
        }
        for preference in plan.backup.preferences.sorted(by: { $0.key < $1.key }) {
            if let local = try AppPreference.fetchOne(db, key: preference.key) {
                if local == preference {
                    outcomes[.scalarAppPreferences]?.skipped += 1
                } else {
                    outcomes[.scalarAppPreferences]?.preservedLocal += 1
                }
            } else {
                try preference.insert(db)
                outcomes[.scalarAppPreferences]?.inserted += 1
            }
        }
    }

    /// `sourceMapping` uses its declared five-column primary key as merge identity.
    /// Merge preserves a differing local row; represented wipe replaces the table.
    private func restoreSourceMappings(
        _ plan: RestorePlan,
        db: Database,
        outcomes: inout [BackupComponent: MutableOutcome]
    ) throws {
        guard plan.represented.contains(.sourceMappings) else {
            return
        }
        if plan.mode == .wipe {
            outcomes[.sourceMappings]?.replaced += try SourceMappingRecord.deleteAll(db)
        }
        for record in plan.backup.sourceMappings.sorted(by: sourceMappingSort) {
            let key: [String: DatabaseValueConvertible] = [
                "canonicalProvider": record.canonicalProvider,
                "canonicalMediaId": record.canonicalMediaId,
                "mediaType": sourceMappingMediaType(record.mediaType),
                "pluginId": record.pluginId,
                "pluginMediaKey": record.pluginMediaKey
            ]
            try mergeScalarRecord(
                record,
                existing: SourceMappingRecord.fetchOne(db, key: key),
                component: .sourceMappings,
                db: db,
                outcomes: &outcomes
            )
        }
    }

    private func restoreReadProgress(
        _ plan: RestorePlan,
        db: Database,
        outcomes: inout [BackupComponent: MutableOutcome]
    ) throws {
        guard plan.represented.contains(.readProgressAndResume) else {
            return
        }
        if plan.mode == .wipe {
            outcomes[.readProgressAndResume]?.replaced +=
                try ReadProgressKeyRecord.deleteAll(db)
            outcomes[.readProgressAndResume]?.replaced +=
                try ReadProgressNumberRecord.deleteAll(db)
            outcomes[.readProgressAndResume]?.replaced +=
                try MediaReadProgressRecord.deleteAll(db)
        }

        for record in plan.backup.readProgressKeys.sorted(by: readProgressKeySort) {
            let rewritten = retarget(record, library: plan.library)
            let key = ReadProgressKey(
                pluginId: rewritten.pluginId,
                canonicalMediaId: rewritten.canonicalMediaId,
                mediaKind: rewritten.mediaKind,
                chapterKey: rewritten.chapterKey
            )
            try mergeSetRecord(
                rewritten,
                existing: ReadProgressKeyRecord.fetchOne(
                    db,
                    key: [
                        "pluginId": key.pluginId,
                        "canonicalMediaId": key.canonicalMediaId,
                        "mediaKind": key.mediaKind.rawValue,
                        "chapterKey": key.chapterKey
                    ]
                ),
                component: .readProgressAndResume,
                db: db,
                outcomes: &outcomes
            )
        }
        for record in plan.backup.readProgressNumbers.sorted(by: readProgressNumberSort) {
            let rewritten = retarget(record, library: plan.library)
            let key = ReadProgressNumberKey(
                pluginId: rewritten.pluginId,
                canonicalMediaId: rewritten.canonicalMediaId,
                mediaKind: rewritten.mediaKind,
                chapterNumber: rewritten.chapterNumber
            )
            try mergeSetRecord(
                rewritten,
                existing: ReadProgressNumberRecord.fetchOne(
                    db,
                    key: [
                        "pluginId": key.pluginId,
                        "canonicalMediaId": key.canonicalMediaId,
                        "mediaKind": key.mediaKind.rawValue,
                        "chapterNumber": key.chapterNumber
                    ]
                ),
                component: .readProgressAndResume,
                db: db,
                outcomes: &outcomes
            )
        }
        for record in plan.backup.mediaReadProgress.sorted(by: mediaReadProgressSort) {
            let rewritten = retarget(record, library: plan.library)
            let key: [String: DatabaseValueConvertible] = [
                "pluginId": rewritten.pluginId,
                "canonicalMediaId": rewritten.canonicalMediaId,
                "mediaKind": rewritten.mediaKind.rawValue
            ]
            try mergeScalarRecord(
                rewritten,
                existing: MediaReadProgressRecord.fetchOne(db, key: key),
                component: .readProgressAndResume,
                db: db,
                outcomes: &outcomes
            )
        }
    }

    private func restoreTrackerLinks(
        _ plan: RestorePlan,
        db: Database,
        outcomes: inout [BackupComponent: MutableOutcome]
    ) throws {
        guard plan.represented.contains(.trackerLinks) else {
            return
        }
        if plan.mode == .wipe {
            outcomes[.trackerLinks]?.replaced += try TrackerLinkRecord.deleteAll(db)
        }
        for record in plan.trackerLinks.sorted(by: trackerSort) {
            let rewritten = retarget(record, library: plan.library)
            let key: [String: DatabaseValueConvertible] = [
                "pluginId": rewritten.pluginId,
                "canonicalMediaId": rewritten.canonicalMediaId,
                "mediaKind": rewritten.mediaKind.rawValue,
                "providerId": rewritten.providerId
            ]
            try mergeScalarRecord(
                rewritten,
                existing: TrackerLinkRecord.fetchOne(db, key: key),
                component: .trackerLinks,
                db: db,
                outcomes: &outcomes
            )
        }
    }

    private func restoreUpdateBadges(
        _ plan: RestorePlan,
        db: Database,
        outcomes: inout [BackupComponent: MutableOutcome]
    ) throws {
        guard plan.represented.contains(.updateBadges) else {
            return
        }
        if plan.mode == .wipe {
            outcomes[.updateBadges]?.replaced += try UpdateBadgeRecord.deleteAll(db)
        }
        for record in plan.backup.updateBadges.sorted(by: updateBadgeSort) {
            let rewritten = retarget(record, library: plan.library)
            let key: [String: DatabaseValueConvertible] = [
                "pluginId": rewritten.pluginId,
                "canonicalMediaId": rewritten.canonicalMediaId,
                "mediaKind": rewritten.mediaKind.rawValue
            ]
            try mergeScalarRecord(
                rewritten,
                existing: UpdateBadgeRecord.fetchOne(db, key: key),
                component: .updateBadges,
                db: db,
                outcomes: &outcomes
            )
        }
    }

    private func restoreRepositories(
        _ plan: RestorePlan,
        db: Database,
        outcomes: inout [BackupComponent: MutableOutcome]
    ) throws {
        guard plan.represented.contains(.repositories) else {
            return
        }
        if plan.mode == .wipe {
            outcomes[.repositories]?.replaced += try RepositoryRecord.deleteAll(db)
        }
        for record in plan.repositories {
            try mergeScalarRecord(
                record,
                existing: RepositoryRecord.fetchOne(db, key: record.url),
                component: .repositories,
                db: db,
                outcomes: &outcomes
            )
        }
    }

    private func restoreImporterAliases(
        _ plan: RestorePlan,
        db: Database,
        outcomes: inout [BackupComponent: MutableOutcome]
    ) throws {
        guard plan.represented.contains(.userImporterAliases) else {
            return
        }
        if plan.mode == .wipe {
            outcomes[.userImporterAliases]?.replaced +=
                try PluginMigrationAliasRecord.deleteAll(db)
        }
        for record in plan.backup.importerAliases.sorted(by: { $0.foreignId < $1.foreignId }) {
            try mergeScalarRecord(
                record,
                existing: PluginMigrationAliasRecord.fetchOne(db, key: record.foreignId),
                component: .userImporterAliases,
                db: db,
                outcomes: &outcomes
            )
        }
    }

    private func restorePluginIdentity(
        _ plan: RestorePlan,
        db: Database,
        outcomes: inout [BackupComponent: MutableOutcome]
    ) throws {
        guard plan.represented.contains(.pluginIdentityAndAliases) else {
            return
        }
        if plan.mode == .wipe {
            outcomes[.pluginIdentityAndAliases]?.replaced +=
                try PluginIdentityAliasRecord.deleteAll(db)
            outcomes[.pluginIdentityAndAliases]?.replaced +=
                try PluginIdentityRecord.deleteAll(db)
        }
        for record in plan.backup.pluginIdentities.sorted(by: { $0.pluginId < $1.pluginId }) {
            try mergeScalarRecord(
                record,
                existing: PluginIdentityRecord.fetchOne(db, key: record.pluginId),
                component: .pluginIdentityAndAliases,
                db: db,
                outcomes: &outcomes
            )
        }
        for record in plan.backup.pluginIdentityAliases.sorted(by: identityAliasSort) {
            let key: [String: DatabaseValueConvertible] = [
                "pluginId": record.pluginId,
                "aliasKind": record.aliasKind,
                "aliasValue": record.aliasValue
            ]
            try mergeScalarRecord(
                record,
                existing: PluginIdentityAliasRecord.fetchOne(db, key: key),
                component: .pluginIdentityAndAliases,
                db: db,
                outcomes: &outcomes
            )
        }
    }

    private func restorePluginSettings(
        _ plan: RestorePlan,
        db: Database,
        outcomes: inout [BackupComponent: MutableOutcome]
    ) throws {
        guard plan.represented.contains(.pluginSettings) else {
            return
        }
        if plan.mode == .wipe {
            outcomes[.pluginSettings]?.replaced += try PluginSettingRecord.deleteAll(db)
        }
        for record in plan.backup.pluginSettings.sorted(by: pluginSettingSort) {
            let key: [String: DatabaseValueConvertible] = [
                "pluginId": record.pluginId,
                "key": record.key
            ]
            try mergeScalarRecord(
                record,
                existing: PluginSettingRecord.fetchOne(db, key: key),
                component: .pluginSettings,
                db: db,
                outcomes: &outcomes
            )
        }
    }

    private func restoreUnscopedMediaState(
        _ plan: RestorePlan,
        db: Database,
        outcomes: inout [BackupComponent: MutableOutcome]
    ) throws {
        guard plan.represented.contains(.legacyUnscopedMediaState) else {
            return
        }
        if plan.mode == .wipe {
            outcomes[.legacyUnscopedMediaState]?.replaced +=
                try LegacyUnscopedMediaStateRecord.deleteAll(db)
        }
        for record in plan.backup.legacyUnscopedMediaState.sorted(by: unscopedSort) {
            let key: [String: DatabaseValueConvertible] = [
                "sourceKey": record.sourceKey,
                "legacyMediaId": record.legacyMediaId,
                "fingerprint": record.fingerprint
            ]
            try mergeSetRecord(
                record,
                existing: LegacyUnscopedMediaStateRecord.fetchOne(db, key: key),
                component: .legacyUnscopedMediaState,
                db: db,
                outcomes: &outcomes
            )
        }
    }

    private func restoreArchives(
        _ plan: RestorePlan,
        db: Database,
        outcomes: inout [BackupComponent: MutableOutcome]
    ) throws {
        guard plan.represented.contains(.legacyStateArchive) else {
            return
        }
        if plan.mode == .wipe {
            outcomes[.legacyStateArchive]?.replaced +=
                try LegacyStateArchiveRecord.deleteAll(db)
        }
        for record in plan.backup.legacyStateArchives.sorted(by: archiveSort) {
            let existing = try LegacyStateArchiveRecord
                .filter(Column("sourceDomain") == record.sourceDomain)
                .filter(Column("sourceKey") == record.sourceKey)
                .filter(Column("contentClass") == record.contentClass.rawValue)
                .filter(Column("valueType") == record.valueType)
                .filter(Column("fingerprint") == record.fingerprint)
                .fetchOne(db)
            if existing == nil {
                var inserted = record
                inserted.id = nil
                try inserted.insert(db)
                outcomes[.legacyStateArchive]?.inserted += 1
            } else {
                outcomes[.legacyStateArchive]?.skipped += 1
            }
        }
    }

    private func makeReport(
        plan: RestorePlan,
        outcomes: [BackupComponent: MutableOutcome]
    ) throws -> BackupRestoreReport {
        let componentOutcomes = try BackupComponent.allCases.compactMap {
            try outcomes[$0]?.make(component: $0)
        }
        return try BackupRestoreReport(
            operationId: plan.operationId,
            mode: plan.mode,
            representedComponents: BackupComponent.allCases.filter {
                plan.represented.contains($0)
            },
            outcomes: componentOutcomes,
            migrationReport: plan.backup.migrationReport?.retargetingAffectedItemIds(
                using: plan.library.targetIdByImportedId
            ),
            createdAt: plan.createdAt
        )
    }

    private func mergeOrInsert<Record: FetchableRecord & PersistableRecord>(
        _ record: Record,
        key: String,
        mode: BackupRestoreMode,
        component: BackupComponent,
        db: Database,
        outcomes: inout [BackupComponent: MutableOutcome],
        equals: (Record, Record) -> Bool
    ) throws {
        if let local = try Record.fetchOne(db, key: key) {
            if equals(local, record) {
                outcomes[component]?.skipped += 1
            } else if mode == .merge {
                outcomes[component]?.preservedLocal += 1
            } else {
                try record.save(db)
                outcomes[component]?.replaced += 1
            }
        } else {
            try record.insert(db)
            outcomes[component]?.inserted += 1
        }
    }

    private func mergeSetRecord<Record>(
        _ record: Record,
        existing: Record?,
        component: BackupComponent,
        db: Database,
        outcomes: inout [BackupComponent: MutableOutcome]
    ) throws where Record: PersistableRecord {
        if existing == nil {
            try record.insert(db)
            outcomes[component]?.inserted += 1
        } else {
            outcomes[component]?.skipped += 1
        }
    }

    private func mergeScalarRecord<Record>(
        _ record: Record,
        existing: Record?,
        component: BackupComponent,
        db: Database,
        outcomes: inout [BackupComponent: MutableOutcome]
    ) throws where Record: PersistableRecord & Equatable {
        if let existing {
            if existing == record {
                outcomes[component]?.skipped += 1
            } else {
                outcomes[component]?.preservedLocal += 1
            }
        } else {
            try record.insert(db)
            outcomes[component]?.inserted += 1
        }
    }

    private func requireUnique(
        _ values: [String],
        component: BackupComponent,
        code: String
    ) throws {
        guard Set(values).count == values.count else {
            throw rejection(.invalidComponentData(component: component, code: code))
        }
    }

    private func requireNonempty(
        _ value: String,
        component: BackupComponent,
        code: String
    ) throws {
        guard !value.isEmpty else {
            throw rejection(.invalidComponentData(component: component, code: code))
        }
    }

    private func requireMediaIdentity(
        pluginId: String,
        canonicalMediaId: String,
        component: BackupComponent
    ) throws {
        guard !pluginId.isEmpty, !canonicalMediaId.isEmpty else {
            throw rejection(
                .invalidComponentData(component: component, code: "invalidMediaIdentity")
            )
        }
    }

    private func rejection(
        _ reason: BackupPreflightReason
    ) -> BackupPreflightError {
        .rejected(reason)
    }

    private func remappedCategoryId(
        _ categoryId: String,
        library: LibraryPlan
    ) -> String {
        guard categoryId == library.importedSystemCategoryId,
              let current = library.currentSystemCategoryId else {
            return categoryId
        }
        return current
    }

    private func remappedIdentity(
        pluginId: String,
        canonicalMediaId: String,
        mediaKind: MediaKind,
        library: LibraryPlan
    ) -> ImportedMediaIdentity.Key {
        let source = ImportedMediaIdentity.Key(
            pluginId: pluginId,
            canonicalMediaId: canonicalMediaId,
            mediaKind: mediaKind
        )
        return library.targetIdentityBySourceIdentity[source] ?? source
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

    private func retarget(
        _ history: ReadingHistoryRecord,
        library: LibraryPlan
    ) -> ReadingHistoryRecord {
        var result = history
        if let disposition = disposition(for: history, library: library) {
            result.libraryItemId = disposition.targetId
            result.mediaKey = disposition.targetId
        }
        return result
    }

    private func disposition(
        for history: ReadingHistoryRecord,
        library: LibraryPlan
    ) -> ItemDisposition? {
        let identities = Set(
            [history.libraryItemId, Optional(history.mediaKey)]
                .compactMap { $0 }
                .map {
                    ImportedMediaIdentity.key(
                        itemId: $0,
                        pluginId: history.pluginId,
                        mediaKind: history.mediaKind
                    )
                }
        )
        let matches = library.dispositions.filter {
            identities.contains($0.sourceIdentity)
        }
        guard matches.count == 1 else {
            return nil
        }
        return matches[0]
    }

    private func keepsBackup(_ resolution: ConflictResolution?) -> Bool {
        if case .keepBackup = resolution {
            return true
        }
        return false
    }

    private func retarget(
        _ record: ReadProgressKeyRecord,
        library: LibraryPlan
    ) -> ReadProgressKeyRecord {
        let identity = remappedIdentity(
            pluginId: record.pluginId,
            canonicalMediaId: record.canonicalMediaId,
            mediaKind: record.mediaKind,
            library: library
        )
        return ReadProgressKeyRecord(
            pluginId: identity.pluginId,
            canonicalMediaId: identity.canonicalMediaId,
            mediaKind: identity.mediaKind,
            chapterKey: record.chapterKey,
            markedAt: record.markedAt,
            provenance: record.provenance
        )
    }

    private func retarget(
        _ record: ReadProgressNumberRecord,
        library: LibraryPlan
    ) -> ReadProgressNumberRecord {
        let identity = remappedIdentity(
            pluginId: record.pluginId,
            canonicalMediaId: record.canonicalMediaId,
            mediaKind: record.mediaKind,
            library: library
        )
        return ReadProgressNumberRecord(
            pluginId: identity.pluginId,
            canonicalMediaId: identity.canonicalMediaId,
            mediaKind: identity.mediaKind,
            chapterNumber: record.chapterNumber,
            markedAt: record.markedAt,
            provenance: record.provenance
        )
    }

    private func retarget(
        _ record: MediaReadProgressRecord,
        library: LibraryPlan
    ) -> MediaReadProgressRecord {
        let identity = remappedIdentity(
            pluginId: record.pluginId,
            canonicalMediaId: record.canonicalMediaId,
            mediaKind: record.mediaKind,
            library: library
        )
        return MediaReadProgressRecord(
            pluginId: identity.pluginId,
            canonicalMediaId: identity.canonicalMediaId,
            mediaKind: identity.mediaKind,
            lastReadChapterKey: record.lastReadChapterKey,
            updatedAt: record.updatedAt,
            provenance: record.provenance,
            lastReadPosition: record.lastReadPosition,
            readerViewer: record.readerViewer
        )
    }

    private func retarget(
        _ record: TrackerLinkRecord,
        library: LibraryPlan
    ) -> TrackerLinkRecord {
        let identity = remappedIdentity(
            pluginId: record.pluginId,
            canonicalMediaId: record.canonicalMediaId,
            mediaKind: record.mediaKind,
            library: library
        )
        return TrackerLinkRecord(
            pluginId: identity.pluginId,
            canonicalMediaId: identity.canonicalMediaId,
            mediaKind: identity.mediaKind,
            providerId: record.providerId,
            remoteMediaId: record.remoteMediaId,
            updatedAt: record.updatedAt,
            provenance: record.provenance
        )
    }

    private func retarget(
        _ record: UpdateBadgeRecord,
        library: LibraryPlan
    ) -> UpdateBadgeRecord {
        let identity = remappedIdentity(
            pluginId: record.pluginId,
            canonicalMediaId: record.canonicalMediaId,
            mediaKind: record.mediaKind,
            library: library
        )
        return UpdateBadgeRecord(
            pluginId: identity.pluginId,
            canonicalMediaId: identity.canonicalMediaId,
            mediaKind: identity.mediaKind,
            count: record.count,
            updatedAt: record.updatedAt,
            provenance: record.provenance
        )
    }

    private func historySemanticKey(
        _ history: ReadingHistoryRecord
    ) -> HistorySemanticKey {
        HistorySemanticKey(
            pluginId: history.pluginId,
            canonicalMediaId: ImportedMediaIdentity.canonicalMediaId(
                itemId: history.mediaKey,
                pluginId: history.pluginId,
                mediaKind: history.mediaKind
            ),
            mediaKind: history.mediaKind,
            chapterKey: history.chapterKey,
            readAt: history.readAt
        )
    }

    private func sourceMappingKey(
        _ record: SourceMappingRecord
    ) -> SourceMappingKey {
        SourceMappingKey(
            canonicalProvider: record.canonicalProvider,
            canonicalMediaId: record.canonicalMediaId,
            mediaType: sourceMappingMediaType(record.mediaType),
            pluginId: record.pluginId,
            pluginMediaKey: record.pluginMediaKey
        )
    }

    private func sourceMappingMediaType(_ mediaType: PluginMediaType) -> String {
        switch mediaType {
        case .manga: "manga"
        case .anime: "anime"
        }
    }

    private func semanticallyEqual(
        _ lhs: LibraryItem,
        _ rhs: LibraryItem
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.coverUrl == rhs.coverUrl
            && lhs.pluginId == rhs.pluginId
            && lhs.isAnime == rhs.isAnime
            && lhs.pluginType == rhs.pluginType
            && lhs.rawPayload == rhs.rawPayload
            && lhs.anilistId == rhs.anilistId
            && lhs.status == rhs.status
            && lhs.lastCheckedAt == rhs.lastCheckedAt
            && lhs.lastUpdatedAt == rhs.lastUpdatedAt
            && lhs.knownChapterCount == rhs.knownChapterCount
    }

    private func linkSort(_ lhs: ItemCategoryLink, _ rhs: ItemCategoryLink) -> Bool {
        (lhs.itemId, lhs.categoryId) < (rhs.itemId, rhs.categoryId)
    }

    private func historySort(
        _ lhs: ReadingHistoryRecord,
        _ rhs: ReadingHistoryRecord
    ) -> Bool {
        (lhs.pluginId, lhs.mediaKind.rawValue, lhs.mediaKey, lhs.chapterKey, lhs.readAt, lhs.id)
            < (rhs.pluginId, rhs.mediaKind.rawValue, rhs.mediaKey, rhs.chapterKey, rhs.readAt, rhs.id)
    }

    private func sourceMappingSort(
        _ lhs: SourceMappingRecord,
        _ rhs: SourceMappingRecord
    ) -> Bool {
        let lhsKey = sourceMappingKey(lhs)
        let rhsKey = sourceMappingKey(rhs)
        return (
            lhsKey.canonicalProvider,
            lhsKey.canonicalMediaId,
            lhsKey.mediaType,
            lhsKey.pluginId,
            lhsKey.pluginMediaKey
        ) < (
            rhsKey.canonicalProvider,
            rhsKey.canonicalMediaId,
            rhsKey.mediaType,
            rhsKey.pluginId,
            rhsKey.pluginMediaKey
        )
    }

    private func readProgressKeySort(
        _ lhs: ReadProgressKeyRecord,
        _ rhs: ReadProgressKeyRecord
    ) -> Bool {
        (lhs.pluginId, lhs.mediaKind.rawValue, lhs.canonicalMediaId, lhs.chapterKey)
            < (rhs.pluginId, rhs.mediaKind.rawValue, rhs.canonicalMediaId, rhs.chapterKey)
    }

    private func readProgressNumberSort(
        _ lhs: ReadProgressNumberRecord,
        _ rhs: ReadProgressNumberRecord
    ) -> Bool {
        (lhs.pluginId, lhs.mediaKind.rawValue, lhs.canonicalMediaId, lhs.chapterNumber)
            < (rhs.pluginId, rhs.mediaKind.rawValue, rhs.canonicalMediaId, rhs.chapterNumber)
    }

    private func mediaReadProgressSort(
        _ lhs: MediaReadProgressRecord,
        _ rhs: MediaReadProgressRecord
    ) -> Bool {
        (lhs.pluginId, lhs.mediaKind.rawValue, lhs.canonicalMediaId)
            < (rhs.pluginId, rhs.mediaKind.rawValue, rhs.canonicalMediaId)
    }

    private func trackerSort(
        _ lhs: TrackerLinkRecord,
        _ rhs: TrackerLinkRecord
    ) -> Bool {
        (lhs.pluginId, lhs.mediaKind.rawValue, lhs.canonicalMediaId, lhs.providerId)
            < (rhs.pluginId, rhs.mediaKind.rawValue, rhs.canonicalMediaId, rhs.providerId)
    }

    private func updateBadgeSort(
        _ lhs: UpdateBadgeRecord,
        _ rhs: UpdateBadgeRecord
    ) -> Bool {
        (lhs.pluginId, lhs.mediaKind.rawValue, lhs.canonicalMediaId)
            < (rhs.pluginId, rhs.mediaKind.rawValue, rhs.canonicalMediaId)
    }

    private func identityAliasSort(
        _ lhs: PluginIdentityAliasRecord,
        _ rhs: PluginIdentityAliasRecord
    ) -> Bool {
        (lhs.pluginId, lhs.aliasKind, lhs.aliasValue)
            < (rhs.pluginId, rhs.aliasKind, rhs.aliasValue)
    }

    private func pluginSettingSort(
        _ lhs: PluginSettingRecord,
        _ rhs: PluginSettingRecord
    ) -> Bool {
        (lhs.pluginId, lhs.key) < (rhs.pluginId, rhs.key)
    }

    private func unscopedSort(
        _ lhs: LegacyUnscopedMediaStateRecord,
        _ rhs: LegacyUnscopedMediaStateRecord
    ) -> Bool {
        (lhs.sourceKey, lhs.legacyMediaId, lhs.fingerprint)
            < (rhs.sourceKey, rhs.legacyMediaId, rhs.fingerprint)
    }

    private func archiveSort(
        _ lhs: LegacyStateArchiveRecord,
        _ rhs: LegacyStateArchiveRecord
    ) -> Bool {
        (
            lhs.sourceDomain,
            lhs.sourceKey,
            lhs.contentClass.rawValue,
            lhs.valueType,
            lhs.fingerprint
        ) < (
            rhs.sourceDomain,
            rhs.sourceKey,
            rhs.contentClass.rawValue,
            rhs.valueType,
            rhs.fingerprint
        )
    }
}
