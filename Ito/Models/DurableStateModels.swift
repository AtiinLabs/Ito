import Foundation
import GRDB

nonisolated public struct MediaIdentity: Codable, Hashable, Sendable {
    public let pluginId: String
    public let canonicalMediaId: String

    public init(pluginId: String, canonicalMediaId: String) {
        self.pluginId = pluginId
        self.canonicalMediaId = canonicalMediaId
    }

    public init(pluginId: String, itemId: String) {
        self.init(
            pluginId: pluginId,
            canonicalMediaId: ImportedMediaIdentity.canonicalMediaId(
                itemId: itemId,
                pluginId: pluginId
            )
        )
    }
}

public enum DurableStateProvenance: String, Codable, CaseIterable, Sendable {
    case runtime
    case legacyUnknownTime
}

public struct ReadProgressKeyRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "readProgressKey"
    public let pluginId: String
    public let canonicalMediaId: String
    public let chapterKey: String
    public var markedAt: Date?
    public var provenance: DurableStateProvenance?
}

public struct ReadProgressNumberRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "readProgressNumber"
    public let pluginId: String
    public let canonicalMediaId: String
    public let chapterNumber: Double
    public var markedAt: Date?
    public var provenance: DurableStateProvenance?
}

public struct MediaReadProgressRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mediaReadProgress"
    public let pluginId: String
    public let canonicalMediaId: String
    public var lastReadChapterKey: String
    public var updatedAt: Date?
    public var provenance: DurableStateProvenance?
    /// Position inside `lastReadChapterKey`: page index (manga), character offset (novel) or
    /// seconds (video).
    public var lastReadPosition: Double?
    /// Manga reading mode chosen for the series (`Manga.Viewer` raw value); nil for its default.
    public var readerViewer: Int?
}

public struct TrackerLinkRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "trackerLink"
    public let pluginId: String
    public let canonicalMediaId: String
    public let providerId: String
    public var remoteMediaId: String
    public var updatedAt: Date?
    public var provenance: DurableStateProvenance?
}

public struct UpdateBadgeRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "updateBadge"
    public let pluginId: String
    public let canonicalMediaId: String
    public var count: Int
    public var updatedAt: Date?
    public var provenance: DurableStateProvenance?
}

public struct RepositoryRecord: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "repository"
    public var id: String { url }
    public let url: String
    public var lastFetched: Date?
    public var indexPayload: Data?
}

/// Marks this database's one-time setup as done. Installation-local; never exported.
public struct FirstRunSetupRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "firstRunSetup"
    public var id = 1
    public let completedAt: Date
}

public struct PluginMigrationAliasRecord: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "pluginMigrationAlias"
    public var id: String { foreignId }
    public let foreignId: String
    public var pluginId: String
    public var updatedAt: Date
}

public struct PluginSettingRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "pluginSetting"
    public let pluginId: String
    public let key: String
    public var value: Data
    public var updatedAt: Date?
}

public struct PluginSettingMigrationAuthorityRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "pluginSettingMigrationAuthority"
    public let pluginId: String
    public let key: String
    public let sourceDomain: String
    public let sourceKey: String
    public let sourceFingerprint: String
}

public struct PluginIdentityRecord: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "pluginIdentityRegistry"
    public var id: String { pluginId }
    public let pluginId: String
    public var manifestId: String?
    public var lastSeenAt: Date
}

public struct PluginIdentityAliasRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "pluginIdentityAlias"
    public let pluginId: String
    public let aliasKind: String
    public let aliasValue: String
    public var suiteDomain: String?
    public var discoverySource: String
    public var lastSeenAt: Date
}

public enum LegacyInboxLifecycleStatus: String, Codable, CaseIterable, Sendable {
    case captured
    case resolved
}

public struct LegacyDefaultsInboxRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "legacyDefaultsInbox"
    public let sourceDomain: String
    public let sourceKey: String
    public let valueType: String
    public let canonicalPayload: Data
    public let fingerprint: String
    public let expectedElementCount: Int
    public let capturedAt: Date
    public var lifecycleStatus: LegacyInboxLifecycleStatus
}

public enum LegacyDefaultsDisposition: String, Codable, CaseIterable, Sendable {
    case normalized
    case archived
    case unscoped
}

public struct LegacyDefaultsOutcomeRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "legacyDefaultsOutcome"
    public let sourceDomain: String
    public let sourceKey: String
    public let fingerprint: String
    public let elementPath: String
    public let disposition: LegacyDefaultsDisposition
    public let targetKind: String
    public let targetIdentity: String
    public let targetFingerprint: String
}

public struct LegacyUnscopedMediaStateRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "legacyUnscopedMediaState"
    public let sourceKey: String
    public let legacyMediaId: String
    public let canonicalPayload: Data
    public let candidates: Data
    public let fingerprint: String
}

public enum LegacyMigrationStatus: String, Codable, CaseIterable, Sendable {
    case captured
    case cleanupPending
    case cleanupVerified
    case resolved
}

public struct LegacyStateMigrationRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "legacyStateMigration"
    public let sourceDomain: String
    public let sourceKey: String
    public let fingerprint: String
    public var status: LegacyMigrationStatus
    public var updatedAt: Date
}

public enum LegacyArchiveContentClass: String, Codable, CaseIterable, Sendable {
    case appNonSecret
    case opaquePluginState
}

public struct LegacyStateArchiveRecord: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "legacyStateArchive"
    public var id: Int64?
    public let sourceDomain: String
    public let sourceKey: String
    public let contentClass: LegacyArchiveContentClass
    public let valueType: String
    public let valuePayload: Data
    public let fingerprint: String
    public let reason: String
    public let createdAt: Date
}

nonisolated public enum LegacyDefaultsSourceClassification: Equatable, Sendable {
    case appManagedCredential
    case appNonSecret
    case opaquePluginState
}

nonisolated public struct LegacyDefaultsSourceTuple: Hashable, Sendable {
    public static let aniListAccessTokenKey = "anilist_access_token"

    public let sourceDomain: String
    public let sourceKey: String

    public init(sourceDomain: String, sourceKey: String) {
        self.sourceDomain = sourceDomain
        self.sourceKey = sourceKey
    }

    public func classification(standardApplicationDomain: String) -> LegacyDefaultsSourceClassification {
        if sourceDomain == standardApplicationDomain && sourceKey == Self.aniListAccessTokenKey {
            return .appManagedCredential
        }
        if sourceDomain == standardApplicationDomain {
            return .appNonSecret
        }
        return .opaquePluginState
    }
}

public enum RestoreOperationStatus: String, Codable, CaseIterable, Sendable {
    case pendingRefresh
    case readyToPresent
}

public struct BackupRestoreJournalRecord: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "backupRestoreJournal"
    public var id: String { operationId }
    public let operationId: String
    public var status: RestoreOperationStatus
    public var reportPayload: Data
    public var updatedAt: Date
}
