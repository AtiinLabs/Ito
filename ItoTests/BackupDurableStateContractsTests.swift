import Foundation
import Testing
import ito_runner
@testable import Ito

struct BackupDurableStateContractsTests {
    @Test func importedBackupDefaultsAreBackwardCompatibleAndUnrepresented() {
        let backup = ImportedBackup()

        #expect(backup.metadata == nil)
        #expect(backup.capabilities.isEmpty)
        #expect(backup.legacyRepresentationOverrides.isEmpty)
        #expect(backup.formatVersion == nil)
        #expect(backup.categories.isEmpty)
        #expect(backup.items.isEmpty)
        #expect(backup.links.isEmpty)
        #expect(backup.history.isEmpty)
        #expect(backup.sourceMappings.isEmpty)
        #expect(backup.preferences.isEmpty)
        #expect(backup.representedPreferenceKeys.isEmpty)
        #expect(backup.readProgressKeys.isEmpty)
        #expect(backup.readProgressNumbers.isEmpty)
        #expect(backup.mediaReadProgress.isEmpty)
        #expect(backup.trackerLinks.isEmpty)
        #expect(backup.updateBadges.isEmpty)
        #expect(backup.repositories.isEmpty)
        #expect(backup.importerAliases.isEmpty)
        #expect(backup.pluginIdentities.isEmpty)
        #expect(backup.pluginIdentityAliases.isEmpty)
        #expect(backup.pluginSettings.isEmpty)
        #expect(backup.legacyUnscopedMediaState.isEmpty)
        #expect(backup.legacyStateArchives.isEmpty)
        #expect(backup.migrationReport == nil)
        #expect(backup.representedComponents.isEmpty)
    }

    @Test func preCapabilityRowsMapEveryLogicalComponentWithoutClaimingEmptyComponents() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let preference = AppPreference(key: "row-level-key", value: Data([1]))
        let backup = ImportedBackup(
            categories: [
                LibraryCategory(
                    id: "category",
                    name: "Category",
                    sortOrder: 0,
                    createdAt: date
                )
            ],
            history: [
                ReadingHistoryRecord(
                    id: "history",
                    mediaKey: "media",
                    title: "Title",
                    coverUrl: nil,
                    pluginId: "plugin",
                    mediaKind: .manga,
                    chapterKey: "chapter",
                    chapterTitle: nil,
                    readAt: date
                )
            ],
            sourceMappings: [
                SourceMappingRecord(
                    canonicalProvider: "anilist",
                    canonicalMediaId: "42",
                    mediaType: .manga,
                    pluginId: "plugin",
                    pluginMediaKey: "media",
                    decision: .autoConfirm,
                    matchMethod: .exactPreferred,
                    confidence: 1,
                    titleSnapshot: "Title",
                    createdAt: date,
                    updatedAt: date
                )
            ],
            preferences: [preference],
            representedPreferenceKeys: ["z-key", preference.key, "z-key"],
            readProgressKeys: [
                ReadProgressKeyRecord(
                    pluginId: "plugin",
                    canonicalMediaId: "media",
                    mediaKind: .manga,
                    chapterKey: "chapter",
                    markedAt: date,
                    provenance: .runtime
                )
            ],
            readProgressNumbers: [
                ReadProgressNumberRecord(
                    pluginId: "plugin",
                    canonicalMediaId: "media",
                    mediaKind: .manga,
                    chapterNumber: 1,
                    markedAt: date,
                    provenance: .runtime
                )
            ],
            mediaReadProgress: [
                MediaReadProgressRecord(
                    pluginId: "plugin",
                    canonicalMediaId: "media",
                    mediaKind: .manga,
                    lastReadChapterKey: "chapter",
                    updatedAt: date,
                    provenance: .runtime
                )
            ],
            trackerLinks: [
                TrackerLinkRecord(
                    pluginId: "plugin",
                    canonicalMediaId: "media",
                    mediaKind: .manga,
                    providerId: "tracker",
                    remoteMediaId: "remote",
                    updatedAt: date,
                    provenance: .runtime
                )
            ],
            updateBadges: [
                UpdateBadgeRecord(
                    pluginId: "plugin",
                    canonicalMediaId: "media",
                    mediaKind: .manga,
                    count: 1,
                    updatedAt: date,
                    provenance: .runtime
                )
            ],
            repositories: [
                RepositoryRecord(url: "https://example.com", lastFetched: date, indexPayload: nil)
            ],
            importerAliases: [
                PluginMigrationAliasRecord(
                    foreignId: "foreign",
                    pluginId: "plugin",
                    updatedAt: date
                )
            ],
            pluginIdentities: [
                PluginIdentityRecord(
                    pluginId: "plugin",
                    manifestId: "manifest",
                    lastSeenAt: date
                )
            ],
            pluginIdentityAliases: [
                PluginIdentityAliasRecord(
                    pluginId: "plugin",
                    aliasKind: "suite",
                    aliasValue: "alias",
                    suiteDomain: "suite",
                    discoverySource: "test",
                    lastSeenAt: date
                )
            ],
            pluginSettings: [
                PluginSettingRecord(
                    pluginId: "plugin",
                    key: "setting",
                    value: Data([2]),
                    updatedAt: date
                )
            ],
            legacyUnscopedMediaState: [
                LegacyUnscopedMediaStateRecord(
                    sourceKey: "source",
                    legacyMediaId: "legacy",
                    canonicalPayload: Data([3]),
                    candidates: Data([4]),
                    fingerprint: "unscoped"
                )
            ],
            legacyStateArchives: [
                LegacyStateArchiveRecord(
                    id: nil,
                    sourceDomain: "plugin.example",
                    sourceKey: "state",
                    contentClass: .opaquePluginState,
                    valueType: "data",
                    valuePayload: Data([5]),
                    fingerprint: "archive",
                    reason: "unresolved",
                    createdAt: date
                )
            ]
        )

        #expect(backup.representedPreferenceKeys == ["row-level-key", "z-key"])
        #expect(backup.representedComponents == BackupComponent.allCases)
        for component in BackupComponent.allCases {
            #expect(backup.representation(of: component) == .representedNonempty)
        }
    }

    @Test func capabilityMetadataDistinguishesRepresentedEmptyFromUnrepresented() {
        let backup = ImportedBackup(
            metadata: BackupMetadataRecord(
                formatVersion: 1,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            capabilities: [
                BackupCapabilityRecord(
                    component: .repositories,
                    representation: .representedEmpty
                )
            ],
            history: [
                ReadingHistoryRecord(
                    mediaKey: "media",
                    title: "Title",
                    coverUrl: nil,
                    pluginId: "plugin",
                    mediaKind: .manga,
                    chapterKey: "chapter",
                    chapterTitle: nil
                )
            ]
        )

        #expect(backup.formatVersion == 1)
        #expect(backup.representation(of: .repositories) == .representedEmpty)
        #expect(backup.representation(of: .readingHistory) == .unrepresented)
        #expect(backup.representedComponents == [.repositories])
    }

    @Test func legacyRepresentationOverridesAreScopedAndValidatedDeterministically() throws {
        let explicitEmpty = ImportedBackup(
            legacyRepresentationOverrides: [.repositories: .representedEmpty]
        )
        try explicitEmpty.validateCapabilityMetadata()
        #expect(explicitEmpty.representation(of: .repositories) == .representedEmpty)
        #expect(explicitEmpty.representedComponents == [.repositories])

        let explicitNonempty = ImportedBackup(
            legacyRepresentationOverrides: [.repositories: .representedNonempty],
            repositories: [
                RepositoryRecord(
                    url: "https://example.com",
                    lastFetched: nil,
                    indexPayload: nil
                )
            ]
        )
        try explicitNonempty.validateCapabilityMetadata()
        #expect(explicitNonempty.representation(of: .repositories) == .representedNonempty)

        let mixedMetadata = ImportedBackup(
            metadata: BackupMetadataRecord(
                formatVersion: 1,
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            legacyRepresentationOverrides: [.repositories: .representedEmpty]
        )
        #expect(
            throws: BackupPreflightError.rejected(
                .invalidCapabilityMetadata(
                    component: nil,
                    code: "legacyOverridesWithCapabilityMetadata"
                )
            )
        ) {
            try mixedMetadata.validateCapabilityMetadata()
        }

        let invalidEmpty = ImportedBackup(
            legacyRepresentationOverrides: [.repositories: .representedEmpty],
            repositories: [
                RepositoryRecord(
                    url: "https://example.com",
                    lastFetched: nil,
                    indexPayload: nil
                )
            ]
        )
        #expect(
            throws: BackupPreflightError.rejected(
                .invalidCapabilityMetadata(
                    component: .repositories,
                    code: "legacyOverrideRepresentedEmptyHasRows"
                )
            )
        ) {
            try invalidEmpty.validateCapabilityMetadata()
        }

        let invalidNonempty = ImportedBackup(
            legacyRepresentationOverrides: [.repositories: .representedNonempty]
        )
        #expect(
            throws: BackupPreflightError.rejected(
                .invalidCapabilityMetadata(
                    component: .repositories,
                    code: "legacyOverrideRepresentedNonemptyHasNoRows"
                )
            )
        ) {
            try invalidNonempty.validateCapabilityMetadata()
        }
    }

    @Test func invalidCapabilityRowsAndDuplicatesAreRejected() throws {
        let metadata = BackupMetadataRecord(
            formatVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let capability = BackupCapabilityRecord(
            component: .repositories,
            representation: .representedEmpty
        )
        let duplicate = ImportedBackup(
            metadata: metadata,
            capabilities: [capability, capability]
        )
        #expect(throws: BackupPreflightError.self) {
            try duplicate.validateCapabilityMetadata()
        }

        let invalidPayload = Data(
            #"{"component":"repositories","representation":"unrepresented"}"#.utf8
        )
        let invalidCapability = try JSONDecoder().decode(
            BackupCapabilityRecord.self,
            from: invalidPayload
        )
        let invalid = ImportedBackup(metadata: metadata, capabilities: [invalidCapability])
        #expect(throws: BackupPreflightError.self) {
            try invalid.validateCapabilityMetadata()
        }
        #expect(invalid.representation(of: .repositories) == .unrepresented)
    }

    @Test func reportOrdersOutcomesAndWarningsAndComputesTotals() throws {
        let outcomes = [
            try ComponentOutcome(component: .pluginSettings, skipped: 2),
            try ComponentOutcome(
                component: .libraryCore,
                inserted: 1,
                replaced: 2,
                preservedLocal: 3,
                unresolved: 4,
                dependencyRepaired: 5
            )
        ]
        let warnings = [
            BackupPreflightWarning(reason: .missingPluginIdentity(pluginId: "z")),
            BackupPreflightWarning(
                reason: .invalidCapabilityMetadata(component: nil, code: "duplicate")
            )
        ]
        let report = try BackupRestoreReport(
            operationId: "operation",
            mode: .merge,
            representedComponents: [.pluginSettings, .libraryCore],
            outcomes: outcomes,
            preflightWarnings: warnings,
            createdAt: Date(timeIntervalSince1970: 2)
        )

        #expect(report.outcomes.map(\.component) == [.libraryCore, .pluginSettings])
        #expect(
            report.preflightWarnings.map(\.reason) == [
                .invalidCapabilityMetadata(component: nil, code: "duplicate"),
                .missingPluginIdentity(pluginId: "z")
            ]
        )
        #expect(
            report.totals == .init(
                inserted: 1,
                replaced: 2,
                preservedLocal: 3,
                skipped: 2,
                unresolved: 4,
                dependencyRepaired: 5
            )
        )
        #expect(report.totals.total == 17)
    }

    @Test func reportJSONRoundTripsForeignMigrationCandidates() throws {
        let migrationReport = MigrationReport(
            unresolvedPlugins: [
                .init(
                    foreignId: "foreign",
                    resolvedId: "resolved",
                    confidence: 75,
                    isInstalled: false,
                    affectedItemIds: ["item"],
                    candidates: [
                        (id: "candidate-a", score: 90),
                        (id: "candidate-b", score: 80)
                    ]
                )
            ],
            totalItemsImported: 1,
            totalItemsSkipped: 2
        )
        let report = try BackupRestoreReport(
            operationId: "operation",
            mode: .wipe,
            outcomes: [try ComponentOutcome(component: .libraryCore, inserted: 1)],
            migrationReport: migrationReport,
            createdAt: Date(timeIntervalSince1970: 3)
        )

        let payload = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(BackupRestoreReport.self, from: payload)

        #expect(decoded == report)
        #expect(decoded.migrationReport == migrationReport)
        #expect(decoded.migrationReport?.unresolvedPlugins[0].candidates[1].id == "candidate-b")
    }

    @Test func everyTypedPreflightReasonRoundTripsWithoutPayloadValues() throws {
        let reasons: [BackupPreflightReason] = [
            .invalidCapabilityMetadata(component: .libraryCore, code: "duplicate"),
            .invalidLibraryClosure(itemId: "item", categoryId: "category"),
            .mediaIdentityCollision(pluginId: "plugin", canonicalMediaId: "media"),
            .ambiguousPluginIdentity(identity: "suite"),
            .missingPluginIdentity(pluginId: "plugin"),
            .orphanedRetainedPluginState(pluginId: "plugin", component: .pluginSettings),
            .credentialPayloadRejected(sourceDomain: "domain", sourceKey: "key"),
            .invalidComponentData(component: .repositories, code: "invalidURL"),
            .invalidKeyData(
                component: .scalarAppPreferences,
                key: "font-size",
                code: "invalidType"
            )
        ]

        for reason in reasons {
            let payload = try JSONEncoder().encode(BackupPreflightWarning(reason: reason))
            let decoded = try JSONDecoder().decode(BackupPreflightWarning.self, from: payload)
            #expect(decoded.reason == reason)
            #expect(!(String(data: payload, encoding: .utf8) ?? "").contains("secret-value"))
        }
    }

    @Test func operationFailureContractsAreTypedAndCodable() throws {
        let exportFailure = BackupExportError.incompleteMigration
        let exportPayload = try JSONEncoder().encode(exportFailure)
        #expect(
            try JSONDecoder().decode(BackupExportError.self, from: exportPayload)
                == exportFailure
        )

        let refreshPending = BackupRestoreError.restoreCommittedRefreshPending(
            operationId: "operation"
        )
        let refreshPayload = try JSONEncoder().encode(refreshPending)
        #expect(
            try JSONDecoder().decode(BackupRestoreError.self, from: refreshPayload)
                == refreshPending
        )
    }

    @Test func invalidCountsAndReportShapeAreRejected() throws {
        #expect(throws: ComponentOutcome.ValidationError.self) {
            try ComponentOutcome(component: .libraryCore, inserted: -1)
        }
        let invalidPayload = Data(
            """
            {
              "component": "libraryCore",
              "inserted": -1,
              "replaced": 0,
              "preservedLocal": 0,
              "skipped": 0,
              "unresolved": 0,
              "dependencyRepaired": 0
            }
            """.utf8
        )
        #expect(throws: ComponentOutcome.ValidationError.self) {
            try JSONDecoder().decode(ComponentOutcome.self, from: invalidPayload)
        }

        let valid = try ComponentOutcome(component: .libraryCore)
        #expect(throws: BackupRestoreReport.ValidationError.self) {
            try BackupRestoreReport(
                operationId: "operation",
                mode: .merge,
                outcomes: [valid, valid]
            )
        }
        #expect(throws: BackupRestoreReport.ValidationError.self) {
            try BackupRestoreReport(
                operationId: "operation",
                mode: .wipe,
                representedComponents: [.libraryCore, .repositories],
                outcomes: [valid]
            )
        }
        #expect(throws: BackupRestoreReport.ValidationError.self) {
            try BackupRestoreReport(
                operationId: "operation",
                mode: .wipe,
                representedComponents: [.libraryCore],
                outcomes: [
                    valid,
                    try ComponentOutcome(component: .pluginSettings, dependencyRepaired: 1)
                ]
            )
        }

        let repair = try ComponentOutcome(component: .readingHistory, dependencyRepaired: 1)
        let report = try BackupRestoreReport(
            operationId: "operation",
            mode: .wipe,
            representedComponents: [.libraryCore],
            outcomes: [valid, repair]
        )
        #expect(report.outcomes.map(\.component) == [.libraryCore, .readingHistory])
    }
}
