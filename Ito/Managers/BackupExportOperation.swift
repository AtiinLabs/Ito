import Foundation
import GRDB

nonisolated public struct BackupExportOperation: Sendable {
    public static let currentFormatVersion = 2

    public enum Phase: Equatable, Sendable {
        case didCreateSnapshot
        case didSanitize
        case didValidate
        case willPublish
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case missingTable(String)
        case durableRowCountChanged(BackupComponent)
        case excludedRowsRemain(String)
        case credentialPayloadRemains
        case invalidScalarPreferenceCatalog
        case invalidMetadata
        case invalidCapabilities
        case integrityCheckFailed(String)
        case foreignKeyCheckFailed
    }

    public enum SafetyError: Error, Equatable, Sendable {
        case destinationSidecarsPresent
        case outputAliasesSourceDatabase
    }

    public typealias ReadinessGate = @Sendable () async throws -> Void
    public typealias FaultHandler = @Sendable (Phase) throws -> Void
    public typealias Publisher = @Sendable (_ stagingURL: URL, _ outputURL: URL) throws -> Void

    private static let databaseArtifactSuffixes = ["", "-wal", "-shm", "-journal"]
    private static let destinationSidecarSuffixes = ["-wal", "-shm", "-journal"]
    private static let sanitizedTables = [
        LegacyDefaultsOutcomeRecord.databaseTableName,
        LegacyDefaultsInboxRecord.databaseTableName,
        LegacyStateMigrationRecord.databaseTableName,
        PluginSettingMigrationAuthorityRecord.databaseTableName,
        BackupRestoreJournalRecord.databaseTableName,
        ThemeCacheRecord.databaseTableName,
        FirstRunSetupRecord.databaseTableName,
        PluginImageCacheEpoch.tableName,
        PluginCompletionScope.outboxTableName,
        PluginCompletionScope.tableName
    ]

    static let excludedTableReasons: [String: String] = [
        LegacyDefaultsOutcomeRecord.databaseTableName:
            "Installation-local migration bookkeeping; rebuilt from migration inputs.",
        LegacyDefaultsInboxRecord.databaseTableName:
            "Installation-local migration capture; never restored onto another installation.",
        LegacyStateMigrationRecord.databaseTableName:
            "Installation-local migration lifecycle ledger.",
        PluginSettingMigrationAuthorityRecord.databaseTableName:
            "Installation-local authority tying migrated settings to one capture.",
        BackupRestoreJournalRecord.databaseTableName:
            "Transient restore presentation journal.",
        ThemeCacheRecord.databaseTableName:
            "Derived visual cache that is regenerated from media artwork.",
        BackupMetadataRecord.databaseTableName:
            "Backup envelope metadata rewritten for every export.",
        BackupCapabilityRecord.databaseTableName:
            "Backup envelope capabilities recomputed from exported durable rows.",
        FirstRunSetupRecord.databaseTableName:
            "Installation-local marker that this device's one-time setup has run.",
        PluginImageCacheEpoch.tableName:
            "Installation-local cache invalidation epoch; never exported in backups.",
        PluginCompletionScope.outboxTableName:
            "Installation-local remote completion authorization; never replayed from a backup.",
        PluginCompletionScope.tableName:
            "Installation-local source/account authorization scopes; never exported in backups."
    ]

    static let durableTablesByComponent: [BackupComponent: [String]] = [
        .libraryCore: [
            LibraryCategory.databaseTableName,
            LibraryItem.databaseTableName,
            ItemCategoryLink.databaseTableName
        ],
        .readingHistory: [ReadingHistoryRecord.databaseTableName],
        .sourceMappings: [SourceMappingRecord.databaseTableName],
        .scalarAppPreferences: [AppPreference.databaseTableName],
        .readProgressAndResume: [
            ReadProgressKeyRecord.databaseTableName,
            ReadProgressNumberRecord.databaseTableName,
            MediaReadProgressRecord.databaseTableName
        ],
        .trackerLinks: [TrackerLinkRecord.databaseTableName],
        .updateBadges: [UpdateBadgeRecord.databaseTableName],
        .repositories: [RepositoryRecord.databaseTableName],
        .userImporterAliases: [PluginMigrationAliasRecord.databaseTableName],
        .pluginIdentityAndAliases: [
            PluginIdentityRecord.databaseTableName,
            PluginIdentityAliasRecord.databaseTableName
        ],
        .pluginSettings: [PluginSettingRecord.databaseTableName],
        .legacyUnscopedMediaState: [LegacyUnscopedMediaStateRecord.databaseTableName],
        .legacyStateArchive: [LegacyStateArchiveRecord.databaseTableName]
    ]

    private let dbPool: DatabasePool
    private let sourceDatabaseURL: URL
    private let readinessGate: ReadinessGate
    private let standardApplicationDomain: String
    private let clock: @Sendable () -> Date
    private let faultHandler: FaultHandler
    private let publisher: Publisher?

    public init(
        dbPool: DatabasePool,
        sourceDatabaseURL: URL,
        standardApplicationDomain: String = Bundle.main.bundleIdentifier ?? "moe.itoapp.ito",
        readinessGate: @escaping ReadinessGate,
        clock: @escaping @Sendable () -> Date = Date.init,
        faultHandler: @escaping FaultHandler = { _ in },
        publisher: Publisher? = nil
    ) {
        self.dbPool = dbPool
        self.sourceDatabaseURL = sourceDatabaseURL
        self.standardApplicationDomain = standardApplicationDomain
        self.readinessGate = readinessGate
        self.clock = clock
        self.faultHandler = faultHandler
        self.publisher = publisher
    }

    public func export(to outputURL: URL) async throws {
        try preflightDestination(outputURL)
        do {
            try await readinessGate()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BackupExportError.incompleteMigration
        }

        let fileManager = FileManager.default
        let stagingURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).staging-\(UUID().uuidString)")
        var stagingDatabase: DatabaseQueue?

        defer {
            try? stagingDatabase?.close()
            Self.removeDatabaseArtifacts(at: stagingURL, using: fileManager)
        }

        let database = try DatabaseQueue(path: stagingURL.path)
        stagingDatabase = database
        try dbPool.backup(to: database)
        try faultHandler(.didCreateSnapshot)

        let expectedCounts = try await database.read { db in
            try expectedDurableCounts(db)
        }
        try sanitize(database)
        try faultHandler(.didSanitize)
        try validate(database, expectedCounts: expectedCounts)
        try faultHandler(.didValidate)

        try database.close()
        stagingDatabase = nil
        try faultHandler(.willPublish)
        try preflightDestination(outputURL)
        if let publisher {
            try publisher(stagingURL, outputURL)
        } else {
            try Self.publish(stagingURL: stagingURL, outputURL: outputURL)
        }
    }

    private func sanitize(_ database: DatabaseQueue) throws {
        try database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        try database.write { db in
            for table in Self.sanitizedTables {
                try db.execute(sql: "DELETE FROM \(table)")
            }

            try db.execute(
                sql: """
                    DELETE FROM legacyStateArchive
                    WHERE contentClass NOT IN (?, ?)
                       OR (sourceDomain = ? AND sourceKey = ?)
                    """,
                arguments: [
                    LegacyArchiveContentClass.appNonSecret.rawValue,
                    LegacyArchiveContentClass.opaquePluginState.rawValue,
                    standardApplicationDomain,
                    LegacyDefaultsSourceTuple.aniListAccessTokenKey
                ]
            )
            try db.execute(
                sql: "DELETE FROM appPreference WHERE key = ?",
                arguments: [LegacyDefaultsSourceTuple.aniListAccessTokenKey]
            )
            try Self.validateScalarPreferences(in: db)

            try db.execute(sql: "DELETE FROM backupMetadata")
            try BackupMetadataRecord(
                formatVersion: Self.currentFormatVersion,
                createdAt: clock()
            ).insert(db)

            try db.execute(sql: "DELETE FROM backupCapability")
            for component in BackupComponent.allCases {
                let representation = try Self.representation(for: component, in: db)
                try BackupCapabilityRecord(
                    component: component,
                    representation: representation
                ).insert(db)
            }
        }

        try database.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }

    private func validate(
        _ database: DatabaseQueue,
        expectedCounts: [BackupComponent: Int]
    ) throws {
        try database.read { db in
            for table in Self.requiredTables {
                guard try db.tableExists(table) else {
                    throw ValidationError.missingTable(table)
                }
            }

            for component in BackupComponent.allCases {
                guard try Self.durableRowCount(for: component, in: db) == expectedCounts[component] else {
                    throw ValidationError.durableRowCountChanged(component)
                }
            }

            for table in Self.sanitizedTables where try Self.rowCount(table: table, in: db) != 0 {
                throw ValidationError.excludedRowsRemain(table)
            }

            let credentialCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM legacyStateArchive
                    WHERE sourceDomain = ? AND sourceKey = ?
                    """,
                arguments: [
                    standardApplicationDomain,
                    LegacyDefaultsSourceTuple.aniListAccessTokenKey
                ]
            ) ?? 0
            guard credentialCount == 0 else {
                throw ValidationError.credentialPayloadRemains
            }
            guard try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM appPreference WHERE key = ?",
                arguments: [LegacyDefaultsSourceTuple.aniListAccessTokenKey]
            ) == 0 else {
                throw ValidationError.credentialPayloadRemains
            }

            let contentClasses = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT contentClass FROM legacyStateArchive"
            )
            guard Set(contentClasses).isSubset(of: Set(LegacyArchiveContentClass.allCases.map(\.rawValue))) else {
                throw ValidationError.credentialPayloadRemains
            }
            try Self.validateScalarPreferences(in: db)

            let metadata = try BackupMetadataRecord.fetchAll(db)
            guard metadata.count == 1,
                  metadata[0].id == 1,
                  metadata[0].formatVersion == Self.currentFormatVersion
            else {
                throw ValidationError.invalidMetadata
            }

            let capabilities = try BackupCapabilityRecord.fetchAll(db)
            let capabilitiesByComponent = Dictionary(
                capabilities.map { ($0.component, $0.representation) },
                uniquingKeysWith: { first, _ in first }
            )
            guard capabilities.count == BackupComponent.allCases.count,
                  capabilitiesByComponent.count == BackupComponent.allCases.count
            else {
                throw ValidationError.invalidCapabilities
            }
            for component in BackupComponent.allCases {
                let expected = try Self.representation(for: component, in: db)
                guard capabilitiesByComponent[component] == expected else {
                    throw ValidationError.invalidCapabilities
                }
            }

            let integrityRows = try String.fetchAll(db, sql: "PRAGMA integrity_check")
            guard integrityRows == ["ok"] else {
                throw ValidationError.integrityCheckFailed(integrityRows.joined(separator: ","))
            }
            guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
                throw ValidationError.foreignKeyCheckFailed
            }
        }
    }

    private static var requiredTables: Set<String> {
        Set(durableTablesByComponent.values.flatMap { $0 })
            .union(excludedTableReasons.keys)
    }

    private func expectedDurableCounts(_ db: Database) throws -> [BackupComponent: Int] {
        var counts: [BackupComponent: Int] = [:]
        for component in BackupComponent.allCases {
            switch component {
            case .scalarAppPreferences:
                counts[component] = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM appPreference WHERE key != ?",
                    arguments: [LegacyDefaultsSourceTuple.aniListAccessTokenKey]
                ) ?? 0
            case .legacyStateArchive:
                counts[component] = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM legacyStateArchive
                        WHERE contentClass IN (?, ?)
                          AND NOT (sourceDomain = ? AND sourceKey = ?)
                        """,
                    arguments: [
                        LegacyArchiveContentClass.appNonSecret.rawValue,
                        LegacyArchiveContentClass.opaquePluginState.rawValue,
                        standardApplicationDomain,
                        LegacyDefaultsSourceTuple.aniListAccessTokenKey
                    ]
                ) ?? 0
            default:
                counts[component] = try Self.durableRowCount(for: component, in: db)
            }
        }
        return counts
    }

    private static func validateScalarPreferences(in db: Database) throws {
        let preferences = try AppPreference.fetchAll(db)
        let entriesByKey = Dictionary(
            uniqueKeysWithValues: AppPreferenceCatalogEntry.allCases.map { ($0.rawValue, $0) }
        )
        guard preferences.count == entriesByKey.count,
              Set(preferences.map(\.key)) == Set(entriesByKey.keys)
        else {
            throw ValidationError.invalidScalarPreferenceCatalog
        }

        for preference in preferences {
            guard let entry = entriesByKey[preference.key],
                  let value = try? JSONSerialization.jsonObject(
                    with: preference.value,
                    options: .fragmentsAllowed
                  ),
                  entry.acceptsLegacyValue(value)
            else {
                throw ValidationError.invalidScalarPreferenceCatalog
            }
        }
    }

    private static func representation(
        for component: BackupComponent,
        in db: Database
    ) throws -> BackupRepresentation {
        if component == .scalarAppPreferences {
            try validateScalarPreferences(in: db)
            return .representedNonempty
        }
        return try durableRowCount(for: component, in: db) == 0
            ? .representedEmpty
            : .representedNonempty
    }

    private static func durableRowCount(
        for component: BackupComponent,
        in db: Database
    ) throws -> Int {
        guard let tables = durableTablesByComponent[component] else { return 0 }
        return try tables.reduce(into: 0) { count, table in
            count += try rowCount(table: table, in: db)
        }
    }

    private static func rowCount(table: String, in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }

    private func preflightDestination(_ outputURL: URL) throws {
        let outputArtifacts = Self.databaseArtifactURLs(for: outputURL)
        let sourceArtifacts = Self.databaseArtifactURLs(for: sourceDatabaseURL)
        for outputArtifact in outputArtifacts {
            for sourceArtifact in sourceArtifacts where Self.urlsAlias(outputArtifact, sourceArtifact) {
                throw SafetyError.outputAliasesSourceDatabase
            }
        }

        let fileManager = FileManager.default
        for suffix in Self.destinationSidecarSuffixes {
            let sidecarURL = Self.resolvedURL(
                URL(fileURLWithPath: outputURL.path + suffix)
            )
            if fileManager.fileExists(atPath: sidecarURL.path) {
                throw SafetyError.destinationSidecarsPresent
            }
        }
    }

    private static func databaseArtifactURLs(for url: URL) -> [URL] {
        databaseArtifactSuffixes.map {
            resolvedURL(URL(fileURLWithPath: url.path + $0))
        }
    }

    private static func resolvedURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func urlsAlias(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhs = resolvedURL(lhs)
        let rhs = resolvedURL(rhs)
        if lhs.path == rhs.path {
            return true
        }

        let fileManager = FileManager.default
        guard let lhsAttributes = try? fileManager.attributesOfItem(atPath: lhs.path),
              let rhsAttributes = try? fileManager.attributesOfItem(atPath: rhs.path),
              let lhsDevice = lhsAttributes[.systemNumber] as? NSNumber,
              let rhsDevice = rhsAttributes[.systemNumber] as? NSNumber,
              let lhsFile = lhsAttributes[.systemFileNumber] as? NSNumber,
              let rhsFile = rhsAttributes[.systemFileNumber] as? NSNumber
        else {
            return false
        }
        return lhsDevice == rhsDevice && lhsFile == rhsFile
    }

    private static func publish(stagingURL: URL, outputURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: outputURL)
        }
    }

    private static func removeDatabaseArtifacts(at url: URL, using fileManager: FileManager) {
        for suffix in databaseArtifactSuffixes {
            try? fileManager.removeItem(atPath: url.path + suffix)
        }
    }
}
