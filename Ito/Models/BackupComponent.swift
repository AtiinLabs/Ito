import Foundation
import GRDB

public enum BackupComponent: String, Codable, CaseIterable, Sendable {
    case libraryCore
    case readingHistory
    case sourceMappings
    case scalarAppPreferences
    case readProgressAndResume
    case trackerLinks
    case updateBadges
    case repositories
    case userImporterAliases
    case pluginIdentityAndAliases
    case pluginSettings
    case legacyUnscopedMediaState
    case savedLibraryThumbnails
    case legacyStateArchive
}

public enum BackupRepresentation: String, Codable, CaseIterable, Sendable {
    case unrepresented
    case representedEmpty
    case representedNonempty
}

public struct BackupMetadataRecord: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "backupMetadata"
    public let id: Int
    public let formatVersion: Int
    public let createdAt: Date

    public init(formatVersion: Int, createdAt: Date) {
        self.id = 1
        self.formatVersion = formatVersion
        self.createdAt = createdAt
    }
}

public struct BackupCapabilityRecord: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "backupCapability"
    public var id: BackupComponent { component }
    public let component: BackupComponent
    public let representation: BackupRepresentation

    public init(component: BackupComponent, representation: BackupRepresentation) {
        precondition(representation != .unrepresented, "Unrepresented components are expressed by an absent capability row")
        self.component = component
        self.representation = representation
    }
}
