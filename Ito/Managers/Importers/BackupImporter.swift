import Foundation

// MARK: - Migration Report

nonisolated public struct MigrationReport: Codable, Equatable, Sendable {
    nonisolated public struct UnresolvedPlugin: Codable, Equatable, Sendable, Identifiable {
        public var id: String { foreignId }
        public let foreignId: String
        public let resolvedId: String
        public let confidence: Int
        public let isInstalled: Bool
        public let affectedItemIds: [String]
        public let candidates: [(id: String, score: Int)]

        public var affectedItemCount: Int { affectedItemIds.count }

        public init(
            foreignId: String,
            resolvedId: String,
            confidence: Int,
            isInstalled: Bool,
            affectedItemIds: [String],
            candidates: [(id: String, score: Int)]
        ) {
            self.foreignId = foreignId
            self.resolvedId = resolvedId
            self.confidence = confidence
            self.isInstalled = isInstalled
            self.affectedItemIds = affectedItemIds
            self.candidates = candidates
        }

        public static func == (lhs: UnresolvedPlugin, rhs: UnresolvedPlugin) -> Bool {
            lhs.foreignId == rhs.foreignId
                && lhs.resolvedId == rhs.resolvedId
                && lhs.confidence == rhs.confidence
                && lhs.isInstalled == rhs.isInstalled
                && lhs.affectedItemIds == rhs.affectedItemIds
                && lhs.candidates.elementsEqual(rhs.candidates) {
                    $0.id == $1.id && $0.score == $1.score
                }
        }

        private struct Candidate: Codable {
            let id: String
            let score: Int
        }

        private enum CodingKeys: String, CodingKey {
            case foreignId
            case resolvedId
            case confidence
            case isInstalled
            case affectedItemIds
            case candidates
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            foreignId = try container.decode(String.self, forKey: .foreignId)
            resolvedId = try container.decode(String.self, forKey: .resolvedId)
            confidence = try container.decode(Int.self, forKey: .confidence)
            isInstalled = try container.decode(Bool.self, forKey: .isInstalled)
            affectedItemIds = try container.decode([String].self, forKey: .affectedItemIds)
            candidates = try container.decode([Candidate].self, forKey: .candidates).map {
                (id: $0.id, score: $0.score)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(foreignId, forKey: .foreignId)
            try container.encode(resolvedId, forKey: .resolvedId)
            try container.encode(confidence, forKey: .confidence)
            try container.encode(isInstalled, forKey: .isInstalled)
            try container.encode(affectedItemIds, forKey: .affectedItemIds)
            try container.encode(
                candidates.map { Candidate(id: $0.id, score: $0.score) },
                forKey: .candidates
            )
        }
    }

    public let unresolvedPlugins: [UnresolvedPlugin]
    public let totalItemsImported: Int
    public let totalItemsSkipped: Int

    public var hasIssues: Bool { !unresolvedPlugins.isEmpty }

    public init(
        unresolvedPlugins: [UnresolvedPlugin],
        totalItemsImported: Int,
        totalItemsSkipped: Int
    ) {
        self.unresolvedPlugins = unresolvedPlugins
        self.totalItemsImported = totalItemsImported
        self.totalItemsSkipped = totalItemsSkipped
    }

    nonisolated func retargetingAffectedItemIds(
        using persistedTargetIdsByImportedItemId: [String: String]
    ) -> MigrationReport {
        MigrationReport(
            unresolvedPlugins: unresolvedPlugins.map { plugin in
                var seen = Set<String>()
                let affectedItemIds: [String] = plugin.affectedItemIds.compactMap { importedItemId in
                    let targetId = persistedTargetIdsByImportedItemId[importedItemId] ?? importedItemId
                    guard seen.insert(targetId).inserted else { return nil }
                    return targetId
                }
                return UnresolvedPlugin(
                    foreignId: plugin.foreignId,
                    resolvedId: plugin.resolvedId,
                    confidence: plugin.confidence,
                    isInstalled: plugin.isInstalled,
                    affectedItemIds: affectedItemIds,
                    candidates: plugin.candidates
                )
            },
            totalItemsImported: totalItemsImported,
            totalItemsSkipped: totalItemsSkipped
        )
    }
}

// MARK: - Imported Backup

nonisolated public struct ImportedBackup: Sendable {
    public let metadata: BackupMetadataRecord?
    public let capabilities: [BackupCapabilityRecord]
    public let legacyRepresentationOverrides: [BackupComponent: BackupRepresentation]
    public let categories: [LibraryCategory]
    public let items: [LibraryItem]
    public let links: [ItemCategoryLink]
    public let history: [ReadingHistoryRecord]
    public let sourceMappings: [SourceMappingRecord]
    public let preferences: [AppPreference]
    public let representedPreferenceKeys: [String]
    public let readProgressKeys: [ReadProgressKeyRecord]
    public let readProgressNumbers: [ReadProgressNumberRecord]
    public let mediaReadProgress: [MediaReadProgressRecord]
    public let trackerLinks: [TrackerLinkRecord]
    public let updateBadges: [UpdateBadgeRecord]
    public let repositories: [RepositoryRecord]
    public let importerAliases: [PluginMigrationAliasRecord]
    public let pluginIdentities: [PluginIdentityRecord]
    public let pluginIdentityAliases: [PluginIdentityAliasRecord]
    public let pluginSettings: [PluginSettingRecord]
    public let legacyUnscopedMediaState: [LegacyUnscopedMediaStateRecord]
    public let legacyStateArchives: [LegacyStateArchiveRecord]
    public let migrationReport: MigrationReport?

    public var formatVersion: Int? { metadata?.formatVersion }

    public var representedComponents: [BackupComponent] {
        BackupComponent.allCases.filter { representation(of: $0) != .unrepresented }
    }

    nonisolated public init(
        metadata: BackupMetadataRecord? = nil,
        capabilities: [BackupCapabilityRecord] = [],
        legacyRepresentationOverrides: [BackupComponent: BackupRepresentation] = [:],
        categories: [LibraryCategory] = [],
        items: [LibraryItem] = [],
        links: [ItemCategoryLink] = [],
        history: [ReadingHistoryRecord] = [],
        sourceMappings: [SourceMappingRecord] = [],
        preferences: [AppPreference] = [],
        representedPreferenceKeys: [String]? = nil,
        readProgressKeys: [ReadProgressKeyRecord] = [],
        readProgressNumbers: [ReadProgressNumberRecord] = [],
        mediaReadProgress: [MediaReadProgressRecord] = [],
        trackerLinks: [TrackerLinkRecord] = [],
        updateBadges: [UpdateBadgeRecord] = [],
        repositories: [RepositoryRecord] = [],
        importerAliases: [PluginMigrationAliasRecord] = [],
        pluginIdentities: [PluginIdentityRecord] = [],
        pluginIdentityAliases: [PluginIdentityAliasRecord] = [],
        pluginSettings: [PluginSettingRecord] = [],
        legacyUnscopedMediaState: [LegacyUnscopedMediaStateRecord] = [],
        legacyStateArchives: [LegacyStateArchiveRecord] = [],
        migrationReport: MigrationReport? = nil
    ) {
        self.metadata = metadata
        self.capabilities = capabilities
        self.legacyRepresentationOverrides = legacyRepresentationOverrides
        self.categories = categories
        self.items = items
        self.links = links
        self.history = history
        self.sourceMappings = sourceMappings
        self.preferences = preferences
        self.representedPreferenceKeys = Array(
            Set(representedPreferenceKeys ?? preferences.map(\.key))
        ).sorted()
        self.readProgressKeys = readProgressKeys
        self.readProgressNumbers = readProgressNumbers
        self.mediaReadProgress = mediaReadProgress
        self.trackerLinks = trackerLinks
        self.updateBadges = updateBadges
        self.repositories = repositories
        self.importerAliases = importerAliases
        self.pluginIdentities = pluginIdentities
        self.pluginIdentityAliases = pluginIdentityAliases
        self.pluginSettings = pluginSettings
        self.legacyUnscopedMediaState = legacyUnscopedMediaState
        self.legacyStateArchives = legacyStateArchives.filter {
            LegacyArchiveContentClass.allCases.contains($0.contentClass)
        }
        self.migrationReport = migrationReport
    }

    public func representation(of component: BackupComponent) -> BackupRepresentation {
        if metadata != nil || !capabilities.isEmpty {
            let matches = capabilities.filter { $0.component == component }
            guard matches.count == 1, matches[0].representation != .unrepresented else {
                return .unrepresented
            }
            return matches[0].representation
        }
        if let representation = legacyRepresentationOverrides[component] {
            return representation
        }

        return hasLegacyRows(for: component) ? .representedNonempty : .unrepresented
    }

    public func validateCapabilityMetadata() throws {
        if let metadata, metadata.formatVersion < 1 || metadata.formatVersion > BackupExportOperation.currentFormatVersion {
            throw BackupPreflightError.rejected(
                .invalidCapabilityMetadata(component: nil, code: "invalidFormatVersion")
            )
        }
        if metadata == nil, !capabilities.isEmpty {
            throw BackupPreflightError.rejected(
                .invalidCapabilityMetadata(component: nil, code: "missingMetadata")
            )
        }
        if !legacyRepresentationOverrides.isEmpty,
           metadata != nil || !capabilities.isEmpty {
            throw BackupPreflightError.rejected(
                .invalidCapabilityMetadata(
                    component: nil,
                    code: "legacyOverridesWithCapabilityMetadata"
                )
            )
        }

        for component in BackupComponent.allCases {
            let matches = capabilities.filter { $0.component == component }
            if matches.count > 1 {
                throw BackupPreflightError.rejected(
                    .invalidCapabilityMetadata(component: component, code: "duplicate")
                )
            }
            if matches.first?.representation == .unrepresented {
                throw BackupPreflightError.rejected(
                    .invalidCapabilityMetadata(
                        component: component,
                        code: "unrepresentedCapability"
                    )
                )
            }

            guard let legacyRepresentation = legacyRepresentationOverrides[component] else {
                continue
            }
            guard legacyRepresentation != .unrepresented else {
                throw BackupPreflightError.rejected(
                    .invalidCapabilityMetadata(
                        component: component,
                        code: "unrepresentedLegacyOverride"
                    )
                )
            }

            let hasRows = hasLegacyRows(for: component)
            if legacyRepresentation == .representedEmpty, hasRows {
                throw BackupPreflightError.rejected(
                    .invalidCapabilityMetadata(
                        component: component,
                        code: "legacyOverrideRepresentedEmptyHasRows"
                    )
                )
            }
            if legacyRepresentation == .representedNonempty, !hasRows {
                throw BackupPreflightError.rejected(
                    .invalidCapabilityMetadata(
                        component: component,
                        code: "legacyOverrideRepresentedNonemptyHasNoRows"
                    )
                )
            }
        }
    }

    private func hasLegacyRows(for component: BackupComponent) -> Bool {
        switch component {
        case .libraryCore:
            !categories.isEmpty || !items.isEmpty || !links.isEmpty
        case .readingHistory:
            !history.isEmpty
        case .sourceMappings:
            !sourceMappings.isEmpty
        case .scalarAppPreferences:
            !representedPreferenceKeys.isEmpty
        case .readProgressAndResume:
            !readProgressKeys.isEmpty || !readProgressNumbers.isEmpty || !mediaReadProgress.isEmpty
        case .trackerLinks:
            !trackerLinks.isEmpty
        case .updateBadges:
            !updateBadges.isEmpty
        case .repositories:
            !repositories.isEmpty
        case .userImporterAliases:
            !importerAliases.isEmpty
        case .pluginIdentityAndAliases:
            !pluginIdentities.isEmpty || !pluginIdentityAliases.isEmpty
        case .pluginSettings:
            !pluginSettings.isEmpty
        case .legacyUnscopedMediaState:
            !legacyUnscopedMediaState.isEmpty
        case .legacyStateArchive:
            !legacyStateArchives.isEmpty
        }
    }
}

// MARK: - BackupImporter Protocol

public protocol BackupImporter: Sendable {
    /// Tests if this importer can handle this specific file extension or magic bytes
    func canHandle(url: URL) -> Bool

    /// Parses the file and standardizes it into the Ito format
    func parse(url: URL) async throws -> ImportedBackup
}
