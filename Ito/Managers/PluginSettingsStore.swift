import Combine
import Foundation
import GRDB
import OSLog

// swiftlint:disable file_length

nonisolated public struct PluginSettingsPersistenceError: Equatable, Sendable {
    public let operation: String
    public let pluginId: String
    public let occurredAt: Date
}

nonisolated public enum PluginSettingsReadinessError: Error, Equatable {
    case suiteUnavailable(String)
    case unresolvedSuites([String])
    case ambiguousSuiteOwnership(suiteDomain: String, existingPluginId: String, claimingPluginId: String)
    case ambiguousPluginIdentity(value: String, candidates: [String])
}

nonisolated public struct PluginSettingsPreparationError: Error {
    public let primaryError: any Error
    public let registeredSuiteLookupError: any Error
}

nonisolated public enum PluginSettingsArchiveConsistencyError: Error, Equatable {
    case archiveReadbackFailed(domain: String, key: String, fingerprint: String)
}

nonisolated public struct PluginSettingsDiscovery: Sendable {
    public let pluginId: String
    public let manifestId: String?
    public let filenameId: String?
    public let source: String

    public init(
        pluginId: String,
        manifestId: String? = nil,
        filenameId: String? = nil,
        source: String
    ) {
        self.pluginId = pluginId
        self.manifestId = manifestId
        self.filenameId = filenameId
        self.source = source
    }
}

nonisolated public final class PluginSettingsStore: ObservableObject, @unchecked Sendable {
    public typealias DomainFactory = @Sendable (String) throws -> any LegacyDefaultsDomain
    public typealias FaultHandler = @Sendable (LegacyMigrationFaultPoint, LegacyDefaultsSourceTuple) throws -> Void
    public typealias OperationFault = @Sendable (String) throws -> Void

    private let publication = PluginSettingsPublication()

    public var revision: Int { publication.revision }
    public var lastPersistenceError: PluginSettingsPersistenceError? { publication.lastPersistenceError }
    public var revisionPublisher: Published<Int>.Publisher { publication.$revision }
    public var lastPersistenceErrorPublisher: Published<PluginSettingsPersistenceError?>.Publisher {
        publication.$lastPersistenceError
    }
    public var objectWillChange: ObservableObjectPublisher { publication.objectWillChange }

    private static let suitePrefix = "moe.ito.runners."
    private static let suiteEvidenceKey = "__ito_internal_plugin_suite_evidence__"

    /// Values of the plugins' secret settings, kept in the Keychain rather than this database.
    public let secrets: PluginSecretStore
    /// Each plugin's website cookies, kept in the Keychain rather than this database.
    public let cookies: PluginCookieJar
    /// Credentials plugins obtain themselves (`defaults::set_secret`), kept in the Keychain apart
    /// from the secrets the user entered. Changing one never rotates image caches or completion
    /// scopes: plugins refresh tokens routinely.
    public let tokens: PluginSecretStore
    /// Server certificates the user trusted for each source's self-hosted servers.
    public let trust: PluginTrustStore
    let completionStore: PluginCompletionStore
    private let dbPool: DatabasePool
    private let standardApplicationDomain: String
    private let domainFactory: DomainFactory
    private let faultHandler: FaultHandler
    private let operationFault: OperationFault
    private let clock: @Sendable () -> Date
    private let lock = NSRecursiveLock()
    private var failedSuites: Set<String> = []
    private let discoverySources = DiscoverySourceChanges()

    public init(
        dbPool: DatabasePool,
        standardApplicationDomain: String = Bundle.main.bundleIdentifier ?? "moe.itoapp.ito",
        domainFactory: @escaping DomainFactory = { domainName in
            guard let defaults = UserDefaults(suiteName: domainName) else {
                throw PluginSettingsReadinessError.suiteUnavailable(domainName)
            }
            return UserDefaultsLegacyDomain(
                defaults: defaults,
                domainName: domainName
            )
        },
        faultHandler: @escaping FaultHandler = { _, _ in },
        operationFault: @escaping OperationFault = { _ in },
        clock: @escaping @Sendable () -> Date = Date.init,
        secrets: PluginSecretStore = PluginSecretStore(),
        cookies: PluginCookieJar = PluginCookieJar(),
        tokens: PluginSecretStore = PluginSecretStore(
            keychain: SystemPluginSecretKeychain(service: PluginSecretStore.tokenService)
        ),
        trust: PluginTrustStore = PluginTrustStore()
    ) {
        self.dbPool = dbPool
        self.standardApplicationDomain = standardApplicationDomain
        self.domainFactory = domainFactory
        self.faultHandler = faultHandler
        self.operationFault = operationFault
        self.clock = clock
        self.secrets = secrets
        self.cookies = cookies
        self.tokens = tokens
        self.trust = trust
        completionStore = PluginCompletionStore(dbPool: dbPool, secrets: secrets, tokens: tokens)
        secrets.configureBeforeMutation { [dbPool] pluginID in
            try dbPool.write { db in
                try PluginImageCacheEpoch.rotate(in: db)
                try PluginCompletionScope.rotate(pluginID: pluginID, in: db)
            }
        }
        dbPool.add(transactionObserver: discoverySources, extent: .observerLifetime)
    }

    internal func observeImageCacheEpoch(
        _ onChange: @escaping @Sendable (String?) -> Void
    ) throws -> PluginImageCacheEpochObservation {
        try dbPool.writeWithoutTransaction { db in
            let observer = PluginImageCacheEpochObservation(onChange: onChange)
            db.add(transactionObserver: observer, extent: .observerLifetime)
            let initialEpoch = try PluginImageCacheEpoch.current(in: db)
            onChange(initialEpoch)
            return observer
        }
    }

    @discardableResult
    public func get(pluginId: String, key: String) -> String? {
        lock.withLock {
            do {
                let canonicalId = try prepareLocked(pluginId: pluginId)
                try operationFault("get")
                return try dbPool.read { db in
                    try PluginSettingRecord.fetchOne(
                        db,
                        key: ["pluginId": canonicalId, "key": key]
                    ).flatMap { String(data: $0.value, encoding: .utf8) }
                }
            } catch {
                publishFailure(operation: "get", pluginId: pluginId)
                return nil
            }
        }
    }

    @discardableResult
    public func set(pluginId: String, key: String, value: String) -> Bool {
        lock.withLock {
            do {
                let canonicalId = try prepareLocked(pluginId: pluginId)
                try operationFault("set")
                try dbPool.write { db in
                    try PluginSettingRecord(
                        pluginId: canonicalId,
                        key: key,
                        value: Data(value.utf8),
                        updatedAt: clock()
                    ).save(db)
                }
                publishSuccess()
                return true
            } catch {
                publishFailure(operation: "set", pluginId: pluginId)
                return false
            }
        }
    }

    @discardableResult
    public func remove(pluginId: String, key: String) -> Bool {
        lock.withLock {
            do {
                let canonicalId = try prepareLocked(pluginId: pluginId)
                try operationFault("remove")
                try dbPool.write { db in
                    _ = try PluginSettingRecord.deleteOne(
                        db,
                        key: ["pluginId": canonicalId, "key": key]
                    )
                }
                publishSuccess()
                return true
            } catch {
                publishFailure(operation: "remove", pluginId: pluginId)
                return false
            }
        }
    }

    /// Saves a secret setting in the Keychain and drops any plain value stored under the same key,
    /// so it can't be read back from the database or exported in a backup.
    @discardableResult
    public func setSecret(pluginId: String, key: String, value: String) -> Bool {
        do {
            try secrets.setValue(value, pluginID: pluginId, key: key)
        } catch {
            publishFailure(operation: "setSecret", pluginId: pluginId)
            return false
        }
        return remove(pluginId: pluginId, key: key)
    }

    @discardableResult
    public func removeSecret(pluginId: String, key: String) -> Bool {
        do {
            try secrets.removeValue(pluginID: pluginId, key: key)
        } catch {
            publishFailure(operation: "removeSecret", pluginId: pluginId)
            return false
        }
        return remove(pluginId: pluginId, key: key)
    }

    public func registerInstalledPlugin(manifestId: String, filenameId: String) throws {
        try lock.withLock {
            try register(
                PluginSettingsDiscovery(
                    pluginId: manifestId,
                    manifestId: manifestId,
                    filenameId: filenameId,
                    source: "installedFileScan"
                )
            )
        }
    }

    public func discover(_ discoveries: [PluginSettingsDiscovery] = []) throws {
        try lock.withLock {
            try discoverDatabaseSources()
            for discovery in discoveries {
                try register(discovery)
            }
        }
    }

    public func prepare(pluginId: String) throws {
        try lock.withLock {
            _ = try prepareLocked(pluginId: pluginId)
        }
    }

    public func prepareForDurableSnapshot(_ discoveries: [PluginSettingsDiscovery] = []) throws {
        try lock.withLock {
            try discover(discoveries)
            let pluginIds = try dbPool.read { db in
                try String.fetchAll(db, sql: "SELECT pluginId FROM pluginIdentityRegistry ORDER BY pluginId")
            }
            // discover(_:) just registered every database source under this lock;
            // rediscovering per plugin repeated that work once per registered plugin.
            for pluginId in pluginIds {
                _ = try prepareLocked(pluginId: pluginId, discoverSources: false)
            }
            let unresolved = try unresolvedRegisteredSuites()
            guard unresolved.isEmpty else {
                throw PluginSettingsReadinessError.unresolvedSuites(unresolved)
            }
        }
    }

    /// Captures a synchronous in-memory snapshot of settings for a single plugin.
    /// Lock order is secret lock -> token lock -> DB read. Fails closed if any stored setting has
    /// invalid UTF-8.
    func snapshot(pluginId: String) throws -> [String: String] {
        try secrets.withSnapshot(pluginID: pluginId) { secretValues in
            try tokens.withSnapshot(pluginID: pluginId) { tokenValues in
                try dbPool.read { db in
                    let rows = try PluginSettingRecord.filter(Column("pluginId") == pluginId).fetchAll(db)
                    return try Self.layeredSettings(rows: rows, tokens: tokenValues, secrets: secretValues)
                }
            }
        }
    }

    /// What a plugin reads for each key: the user's secret over the plugin's own token over the
    /// plain value, as `AppDefaultsModule.get` resolves it.
    nonisolated static func layeredSettings(
        rows: [PluginSettingRecord],
        tokens: [String: String],
        secrets: [String: String]
    ) throws -> [String: String] {
        var settings: [String: String] = [:]
        settings.reserveCapacity(rows.count + tokens.count + secrets.count)
        for row in rows {
            guard let value = String(data: row.value, encoding: .utf8) else {
                throw PluginCompletionScopeError.invalidSettingEncoding
            }
            settings[row.key] = value
        }
        settings.merge(tokens) { _, token in token }
        settings.merge(secrets) { _, secret in secret }
        return settings
    }

    public func reload() throws {
        try lock.withLock {
            try operationFault("reload")
            _ = try dbPool.read { db in
                try PluginSettingRecord.fetchCount(db)
            }
            publishSuccess()
        }
    }

    private func prepareLocked(pluginId: String, discoverSources: Bool = true) throws -> String {
        if discoverSources {
            try discoverDatabaseSources()
        }
        let canonicalId = try canonicalPluginId(for: pluginId) ?? pluginId
        if try canonicalPluginId(for: pluginId) == nil {
            try register(
                PluginSettingsDiscovery(
                    pluginId: pluginId,
                    manifestId: pluginId,
                    filenameId: pluginId,
                    source: "defensiveAccess"
                )
            )
        }
        do {
            try migrateRegisteredSuites(pluginId: canonicalId)
            failedSuites.subtract(try registeredSuiteDomains(pluginId: canonicalId))
            return canonicalId
        } catch {
            let primaryError = error
            do {
                failedSuites.formUnion(try registeredSuiteDomains(pluginId: canonicalId))
            } catch {
                throw PluginSettingsPreparationError(
                    primaryError: primaryError,
                    registeredSuiteLookupError: error
                )
            }
            throw primaryError
        }
    }

    private func register(_ discovery: PluginSettingsDiscovery) throws {
        let canonicalId = discovery.manifestId ?? discovery.pluginId
        let now = clock()
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO pluginIdentityRegistry (pluginId, manifestId, lastSeenAt)
                    VALUES (?, ?, ?)
                    ON CONFLICT(pluginId) DO UPDATE SET
                        manifestId = COALESCE(excluded.manifestId, manifestId),
                        lastSeenAt = excluded.lastSeenAt
                    """,
                arguments: [canonicalId, discovery.manifestId, now]
            )
            if let manifestId = discovery.manifestId {
                try upsertAlias(
                    pluginId: canonicalId,
                    kind: "manifestId",
                    value: manifestId,
                    suiteDomain: Self.suiteDomain(manifestId),
                    source: discovery.source,
                    date: now,
                    in: db
                )
            } else {
                try upsertAlias(
                    pluginId: canonicalId,
                    kind: "pluginId",
                    value: discovery.pluginId,
                    suiteDomain: Self.suiteDomain(discovery.pluginId),
                    source: discovery.source,
                    date: now,
                    in: db
                )
            }
            if let filenameId = discovery.filenameId,
               filenameId != discovery.manifestId {
                try upsertAlias(
                    pluginId: canonicalId,
                    kind: "filename",
                    value: filenameId,
                    suiteDomain: Self.suiteDomain(filenameId),
                    source: discovery.source,
                    date: now,
                    in: db
                )
            }
        }
    }

    private func upsertAlias(
        pluginId: String,
        kind: String,
        value: String,
        suiteDomain: String,
        source: String,
        date: Date,
        in db: Database
    ) throws {
        if let existing = try Row.fetchOne(
            db,
            sql: """
                SELECT pluginId, aliasKind FROM pluginIdentityAlias
                WHERE suiteDomain = ?
                """,
            arguments: [suiteDomain]
        ) {
            let existingPluginId: String = existing["pluginId"]
            guard existingPluginId == pluginId else {
                throw PluginSettingsReadinessError.ambiguousSuiteOwnership(
                    suiteDomain: suiteDomain,
                    existingPluginId: existingPluginId,
                    claimingPluginId: pluginId
                )
            }
            let existingKind: String = existing["aliasKind"]
            if kind == "manifestId", existingKind != "manifestId" {
                try db.execute(
                    sql: """
                        UPDATE pluginIdentityAlias
                        SET aliasKind = ?, aliasValue = ?, discoverySource = ?, lastSeenAt = ?
                        WHERE suiteDomain = ?
                        """,
                    arguments: [kind, value, source, date, suiteDomain]
                )
            } else {
                try db.execute(
                    sql: """
                        UPDATE pluginIdentityAlias
                        SET discoverySource = ?, lastSeenAt = ?
                        WHERE suiteDomain = ?
                        """,
                    arguments: [source, date, suiteDomain]
                )
            }
            return
        }
        try db.execute(
            sql: """
                INSERT INTO pluginIdentityAlias
                    (pluginId, aliasKind, aliasValue, suiteDomain, discoverySource, lastSeenAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(pluginId, aliasKind, aliasValue) DO UPDATE SET
                    suiteDomain = excluded.suiteDomain,
                    discoverySource = excluded.discoverySource,
                    lastSeenAt = excluded.lastSeenAt
                """,
            arguments: [pluginId, kind, value, suiteDomain, source, date]
        )
    }

    /// Registers identities found in durable rows and repository indexes. The scan decodes every
    /// repository index and runs before every settings read, so it only runs again after a commit
    /// changed something it reads (see `DiscoverySourceChanges`).
    private func discoverDatabaseSources() throws {
        guard discoverySources.consumeChange() else { return }
        do {
            try rescanDatabaseSources()
        } catch {
            discoverySources.markChanged()
            throw error
        }
    }

    private func rescanDatabaseSources() throws {
        let discoveries = try dbPool.read { db -> [PluginSettingsDiscovery] in
            var values: [PluginSettingsDiscovery] = []
            let rowPluginIds = try String.fetchAll(
                db,
                sql: """
                    SELECT pluginId FROM pluginSetting
                    UNION SELECT pluginId FROM libraryItem
                    UNION SELECT pluginId FROM readingHistory
                    UNION SELECT pluginId FROM pluginMigrationAlias
                    """
            )
            values += rowPluginIds.map {
                PluginSettingsDiscovery(pluginId: $0, source: "durableRows")
            }
            let migrationAliases = try Row.fetchAll(
                db,
                sql: "SELECT foreignId, pluginId FROM pluginMigrationAlias"
            )
            values += migrationAliases.map {
                PluginSettingsDiscovery(
                    pluginId: $0["pluginId"],
                    filenameId: $0["foreignId"],
                    source: "migrationAlias"
                )
            }
            // An index that can't be read only hides its packages until a refresh replaces it.
            // Nothing is lost: legacy settings are only moved out of a suite once it is
            // registered, so a suite only that index would have named stays where it is.
            let payloads = try Data.fetchAll(
                db,
                sql: "SELECT indexPayload FROM repository WHERE indexPayload IS NOT NULL"
            )
            for payload in payloads {
                guard let index = try? JSONDecoder().decode(RepoIndex.self, from: payload) else {
                    AppLogger.plugin.error("PluginSettingsStore: skipped a repository index that couldn't be read")
                    continue
                }
                values += index.packages.map {
                    PluginSettingsDiscovery(pluginId: $0.id, source: "repositoryPayload")
                }
            }
            return values
        }
        for discovery in discoveries {
            try register(discovery)
        }
    }

    private func canonicalPluginId(for pluginId: String) throws -> String? {
        try dbPool.read { db in
            if try PluginIdentityRecord.fetchOne(db, key: pluginId) != nil {
                return pluginId
            }
            let matches = try String.fetchAll(
                db,
                sql: """
                    SELECT pluginId FROM pluginIdentityAlias
                    WHERE aliasValue = ? OR suiteDomain = ?
                    ORDER BY CASE aliasKind WHEN 'manifestId' THEN 0 WHEN 'filename' THEN 1 ELSE 2 END,
                             pluginId
                    """,
                arguments: [pluginId, Self.suiteDomain(pluginId)]
            )
            let candidates = Array(Set(matches)).sorted()
            guard candidates.count <= 1 else {
                throw PluginSettingsReadinessError.ambiguousPluginIdentity(
                    value: pluginId,
                    candidates: candidates
                )
            }
            return candidates.first
        }
    }

    private func registeredSuiteDomains(pluginId: String) throws -> Set<String> {
        try operationFault("registeredSuiteDomains")
        return try dbPool.read { db in
            Set(try String.fetchAll(
                db,
                sql: """
                    SELECT suiteDomain FROM pluginIdentityAlias
                    WHERE pluginId = ? AND suiteDomain IS NOT NULL
                    """,
                arguments: [pluginId]
            ))
        }
    }

    private func migrateRegisteredSuites(pluginId: String) throws {
        let aliases = try dbPool.read { db in
            try PluginIdentityAliasRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM pluginIdentityAlias
                    WHERE pluginId = ? AND suiteDomain IS NOT NULL
                    """,
                arguments: [pluginId]
            )
        }
        let suiteAliases = Dictionary(grouping: aliases, by: { $0.suiteDomain! })
        for suiteDomain in suiteAliases.keys.sorted() {
            try captureAndClean(try domainFactory(suiteDomain))
        }
        try normalizeCapturedSettings(pluginId: pluginId, suiteAliases: suiteAliases)
    }

    private func captureAndClean(_ domain: any LegacyDefaultsDomain) throws {
        try validateMigrationStatuses(domain: domain.domainName)
        try ensureSuiteEvidence(domain)
        try repairInterruptedCleanup(domain)
        for key in domain.persistentDomain().keys.sorted() {
            let tuple = LegacyDefaultsSourceTuple(sourceDomain: domain.domainName, sourceKey: key)
            if tuple.classification(standardApplicationDomain: standardApplicationDomain) == .appManagedCredential {
                continue
            }
            guard let value = domain.persistentDomain()[key] else { continue }
            try faultHandler(.beforeDatabaseWrite, tuple)
            let capture = try CanonicalPropertyListCapture.make(value: value)
            try dbPool.write { db in
                try faultHandler(.duringInboxTransaction, tuple)
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO legacyDefaultsInbox
                            (sourceDomain, sourceKey, valueType, canonicalPayload, fingerprint,
                             expectedElementCount, capturedAt, lifecycleStatus)
                        VALUES (?, ?, ?, ?, ?, 1, ?, 'captured')
                        """,
                    arguments: [
                        domain.domainName, key, capture.valueType, capture.payload,
                        capture.fingerprint, clock()
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO legacyStateMigration
                            (sourceDomain, sourceKey, fingerprint, status, updatedAt)
                        VALUES (?, ?, ?, 'captured', ?)
                        """,
                    arguments: [domain.domainName, key, capture.fingerprint, clock()]
                )
            }
            try faultHandler(.afterInboxCommitBeforeReadback, tuple)
            let verified = try dbPool.read { db in
                try LegacyDefaultsInboxRecord.fetchOne(
                    db,
                    key: [
                        "sourceDomain": domain.domainName,
                        "sourceKey": key,
                        "fingerprint": capture.fingerprint
                    ]
                ).map {
                    $0.canonicalPayload == capture.payload
                        && $0.valueType == capture.valueType
                        && $0.fingerprint == CanonicalPropertyListCapture.digest($0.canonicalPayload)
                } ?? false
            }
            guard verified else {
                throw LegacyDefaultsMigrationError.canonicalReadbackFailed(
                    domain: domain.domainName,
                    key: key
                )
            }
            try faultHandler(.afterInboxReadbackBeforeRemoval, tuple)
            try supersedeStaleCaptures(
                domain: domain.domainName,
                key: key,
                authoritativeFingerprint: capture.fingerprint
            )
            try advanceStatus(
                .cleanupPending,
                domain: domain.domainName,
                key: key,
                fingerprint: capture.fingerprint
            )
            domain.removeObject(forKey: key)
            try faultHandler(.afterRemovalBeforeVerification, tuple)
            try faultHandler(.duringRemovalVerification, tuple)
            guard domain.persistentDomain()[key] == nil else {
                throw LegacyDefaultsMigrationError.persistentCleanupFailed(
                    domain: domain.domainName,
                    key: key
                )
            }
            try advanceStatus(
                .cleanupVerified,
                domain: domain.domainName,
                key: key,
                fingerprint: capture.fingerprint
            )
        }
    }

    private func supersedeStaleCaptures(
        domain: String, key: String, authoritativeFingerprint: String
    ) throws {
        try dbPool.write { db in
            let staleCaptures = try LegacyDefaultsInboxRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM legacyDefaultsInbox
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint != ?
                    ORDER BY fingerprint
                """,
                arguments: [
                    domain,
                    key,
                    authoritativeFingerprint
                ]
            )
            for stale in staleCaptures {
                let archiveId = try archive(
                    stale,
                    reason: "pluginSourceGenerationSuperseded",
                    in: db
                )
                try recordOutcome(
                    stale,
                    disposition: .archived,
                    targetKind: "legacyStateArchive",
                    targetIdentity: archiveId,
                    targetFingerprint: stale.fingerprint,
                    in: db
                )
                try resolve(stale, in: db)
            }
        }
    }

    private func ensureSuiteEvidence(_ domain: any LegacyDefaultsDomain) throws {
        let tuple = LegacyDefaultsSourceTuple(
            sourceDomain: domain.domainName,
            sourceKey: Self.suiteEvidenceKey
        )
        let capture = try CanonicalPropertyListCapture.make(value: "")
        let exists = try dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM legacyStateMigration
                    WHERE sourceDomain = ? AND sourceKey = ? AND status = 'resolved'
                """,
                arguments: [domain.domainName, Self.suiteEvidenceKey]
            ) ?? 0
        }
        guard exists == 0 else { return }
        try faultHandler(.beforeDatabaseWrite, tuple)
        try dbPool.write { db in
            try faultHandler(.duringInboxTransaction, tuple)
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO legacyDefaultsInbox
                        (sourceDomain, sourceKey, valueType, canonicalPayload, fingerprint,
                         expectedElementCount, capturedAt, lifecycleStatus)
                    VALUES (?, ?, ?, ?, ?, 0, ?, 'captured')
                    """,
                arguments: [
                    domain.domainName, Self.suiteEvidenceKey, capture.valueType,
                    capture.payload, capture.fingerprint, clock()
                ]
            )
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO legacyStateMigration
                        (sourceDomain, sourceKey, fingerprint, status, updatedAt)
                    VALUES (?, ?, ?, 'captured', ?)
                    """,
                arguments: [
                    domain.domainName, Self.suiteEvidenceKey, capture.fingerprint, clock()
                ]
            )
        }
        try faultHandler(.afterInboxCommitBeforeReadback, tuple)
        let verified = try dbPool.read { db in
            try LegacyDefaultsInboxRecord.fetchOne(
                db,
                key: [
                    "sourceDomain": domain.domainName,
                    "sourceKey": Self.suiteEvidenceKey,
                    "fingerprint": capture.fingerprint
                ]
            )?.canonicalPayload == capture.payload
        }
        guard verified else {
            throw LegacyDefaultsMigrationError.canonicalReadbackFailed(
                domain: domain.domainName,
                key: Self.suiteEvidenceKey
            )
        }
        try advanceStatus(
            .cleanupPending,
            domain: domain.domainName,
            key: Self.suiteEvidenceKey,
            fingerprint: capture.fingerprint
        )
        try advanceStatus(
            .cleanupVerified,
            domain: domain.domainName,
            key: Self.suiteEvidenceKey,
            fingerprint: capture.fingerprint
        )
        try dbPool.write { db in
            guard let row = try LegacyDefaultsInboxRecord.fetchOne(
                db,
                key: [
                    "sourceDomain": domain.domainName,
                    "sourceKey": Self.suiteEvidenceKey,
                    "fingerprint": capture.fingerprint
                ]
            ) else { return }
            try resolve(row, in: db)
        }
    }

    private func repairInterruptedCleanup(_ domain: any LegacyDefaultsDomain) throws {
        let pending = try dbPool.read { db in
            try LegacyDefaultsInboxRecord.fetchAll(
                db,
                sql: """
                    SELECT inbox.* FROM legacyDefaultsInbox inbox
                    JOIN legacyStateMigration ledger
                      ON ledger.sourceDomain = inbox.sourceDomain
                     AND ledger.sourceKey = inbox.sourceKey
                     AND ledger.fingerprint = inbox.fingerprint
                    WHERE inbox.sourceDomain = ?
                      AND inbox.lifecycleStatus = 'captured'
                      AND ledger.status IN ('captured', 'cleanupPending')
                      AND inbox.sourceKey != ?
                    ORDER BY inbox.sourceKey, inbox.fingerprint
                    """,
                arguments: [domain.domainName, Self.suiteEvidenceKey]
            )
        }
        for capture in pending where domain.persistentDomain()[capture.sourceKey] == nil {
            let status = try dbPool.read { db in
                try String.fetchOne(
                    db,
                    sql: """
                        SELECT status FROM legacyStateMigration
                        WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                        """,
                    arguments: [
                        capture.sourceDomain, capture.sourceKey, capture.fingerprint
                    ]
                )
            }
            if status == LegacyMigrationStatus.captured.rawValue {
                try advanceStatus(
                    .cleanupPending,
                    domain: capture.sourceDomain,
                    key: capture.sourceKey,
                    fingerprint: capture.fingerprint
                )
            }
            try advanceStatus(
                .cleanupVerified,
                domain: capture.sourceDomain,
                key: capture.sourceKey,
                fingerprint: capture.fingerprint
            )
        }
    }

    private func advanceStatus(
        _ target: LegacyMigrationStatus,
        domain: String,
        key: String,
        fingerprint: String
    ) throws {
        try dbPool.write { db in
            let currentRaw = try String.fetchOne(
                db,
                sql: """
                    SELECT status FROM legacyStateMigration
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [domain, key, fingerprint]
            )
            guard let currentRaw else {
                throw LegacyDefaultsMigrationError.missingMigrationStatus(
                    domain: domain,
                    key: key,
                    fingerprint: fingerprint
                )
            }
            guard let current = LegacyMigrationStatus(rawValue: currentRaw) else {
                throw LegacyDefaultsMigrationError.unknownMigrationStatus(
                    domain: domain,
                    key: key,
                    fingerprint: fingerprint,
                    status: currentRaw
                )
            }
            if current == target || current == .resolved { return }
            let next: LegacyMigrationStatus = current == .captured ? .cleanupPending : .cleanupVerified
            guard next == target else {
                throw LegacyDefaultsMigrationError.invalidStatusTransition(from: current, to: target)
            }
            try db.execute(
                sql: """
                    UPDATE legacyStateMigration SET status = ?, updatedAt = ?
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [target.rawValue, clock(), domain, key, fingerprint]
            )
        }
    }

    private func validateMigrationStatuses(domain: String) throws {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT inbox.sourceKey, inbox.fingerprint, ledger.status
                    FROM legacyDefaultsInbox inbox
                    LEFT JOIN legacyStateMigration ledger
                      ON ledger.sourceDomain = inbox.sourceDomain
                     AND ledger.sourceKey = inbox.sourceKey
                     AND ledger.fingerprint = inbox.fingerprint
                    WHERE inbox.sourceDomain = ?
                    """,
                arguments: [domain]
            )
            for row in rows {
                let key: String = row["sourceKey"]
                let fingerprint: String = row["fingerprint"]
                guard let status: String = row["status"] else {
                    throw LegacyDefaultsMigrationError.missingMigrationStatus(
                        domain: domain,
                        key: key,
                        fingerprint: fingerprint
                    )
                }
                guard LegacyMigrationStatus(rawValue: status) != nil else {
                    throw LegacyDefaultsMigrationError.unknownMigrationStatus(
                        domain: domain,
                        key: key,
                        fingerprint: fingerprint,
                        status: status
                    )
                }
            }
        }
    }

    private func normalizeCapturedSettings(
        pluginId: String,
        suiteAliases: [String: [PluginIdentityAliasRecord]]
    ) throws {
        let domains = suiteAliases.keys.sorted()
        guard !domains.isEmpty else { return }
        let placeholders = domains.map { _ in "?" }.joined(separator: ",")
        let captures = try dbPool.read { db in
            try LegacyDefaultsInboxRecord.fetchAll(
                db,
                sql: """
                    SELECT inbox.* FROM legacyDefaultsInbox inbox
                    JOIN legacyStateMigration ledger
                      ON ledger.sourceDomain = inbox.sourceDomain
                     AND ledger.sourceKey = inbox.sourceKey
                     AND ledger.fingerprint = inbox.fingerprint
                    WHERE inbox.sourceDomain IN (\(placeholders))
                      AND inbox.lifecycleStatus = 'captured'
                      AND ledger.status = 'cleanupVerified'
                      AND inbox.sourceKey != ?
                    ORDER BY inbox.sourceKey, inbox.sourceDomain, inbox.fingerprint
                    """,
                arguments: StatementArguments(domains + [Self.suiteEvidenceKey])
            )
        }
        let byKey = Dictionary(grouping: captures, by: \.sourceKey)
        try dbPool.write { db in
            for key in byKey.keys.sorted() {
                let rows = byKey[key, default: []]
                let existing = try PluginSettingRecord.fetchOne(
                    db,
                    key: ["pluginId": pluginId, "key": key]
                )
                let migrationOwnsExisting = try PluginSettingMigrationAuthorityRecord.fetchOne(
                    db,
                    key: ["pluginId": pluginId, "key": key]
                ) != nil
                let committedExisting = migrationOwnsExisting ? nil : existing
                let supported = try rows.compactMap { row -> (LegacyDefaultsInboxRecord, Data)? in
                    let decoded = try CanonicalPropertyListCapture(
                        valueType: row.valueType,
                        payload: row.canonicalPayload,
                        fingerprint: row.fingerprint
                    ).decodedValue()
                    guard let string = decoded as? String else { return nil }
                    return (row, Data(string.utf8))
                }.sorted {
                    precedence(of: $0.0.sourceDomain, aliases: suiteAliases)
                        < precedence(of: $1.0.sourceDomain, aliases: suiteAliases)
                }
                let winningValue = committedExisting?.value ?? supported.first?.1
                if committedExisting == nil, let winningValue {
                    try PluginSettingRecord(
                        pluginId: pluginId,
                        key: key,
                        value: winningValue,
                        updatedAt: clock()
                    ).save(db)
                    if let source = supported.first(where: { $0.1 == winningValue })?.0 {
                        try PluginSettingMigrationAuthorityRecord(
                            pluginId: pluginId,
                            key: key,
                            sourceDomain: source.sourceDomain,
                            sourceKey: source.sourceKey,
                            sourceFingerprint: source.fingerprint
                        ).save(db)
                    }
                }
                for row in rows {
                    let decoded = try CanonicalPropertyListCapture(
                        valueType: row.valueType,
                        payload: row.canonicalPayload,
                        fingerprint: row.fingerprint
                    ).decodedValue()
                    if let string = decoded as? String {
                        let value = Data(string.utf8)
                        if value == winningValue {
                            try recordOutcome(
                                row,
                                disposition: .normalized,
                                targetKind: "pluginSetting",
                                targetIdentity: "\(pluginId):\(key)",
                                targetFingerprint: CanonicalPropertyListCapture.digest(value),
                                in: db
                            )
                        } else {
                            let archiveId = try archive(row, reason: "pluginSettingConflict", in: db)
                            try recordOutcome(
                                row,
                                disposition: .archived,
                                targetKind: "legacyStateArchive",
                                targetIdentity: archiveId,
                                targetFingerprint: row.fingerprint,
                                in: db
                            )
                        }
                    } else {
                        let archiveId = try archive(row, reason: "unsupportedPluginSettingValue", in: db)
                        try recordOutcome(
                            row,
                            disposition: .archived,
                            targetKind: "legacyStateArchive",
                            targetIdentity: archiveId,
                            targetFingerprint: row.fingerprint,
                            in: db
                        )
                    }
                    try resolve(row, in: db)
                }
            }
            try faultHandler(
                .duringNormalizationTransaction,
                LegacyDefaultsSourceTuple(sourceDomain: domains[0], sourceKey: "*")
            )
        }
        if !captures.isEmpty {
            try faultHandler(
                .afterNormalizationCommit,
                LegacyDefaultsSourceTuple(sourceDomain: domains[0], sourceKey: "*")
            )
            publishSuccess()
        }
    }

    private func precedence(
        of domain: String,
        aliases: [String: [PluginIdentityAliasRecord]]
    ) -> String {
        let kinds = Set(aliases[domain, default: []].map(\.aliasKind))
        if kinds.contains("manifestId") { return "0:\(domain)" }
        if kinds.contains("filename") { return "1:\(domain)" }
        return "2:\(domain)"
    }

    private func archive(
        _ capture: LegacyDefaultsInboxRecord,
        reason: String,
        in db: Database
    ) throws -> String {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO legacyStateArchive
                    (sourceDomain, sourceKey, contentClass, valueType, valuePayload,
                     fingerprint, reason, createdAt)
                VALUES (?, ?, 'opaquePluginState', ?, ?, ?, ?, ?)
                """,
            arguments: [
                capture.sourceDomain, capture.sourceKey, capture.valueType,
                capture.canonicalPayload, capture.fingerprint, reason, clock()
            ]
        )
        do {
            try operationFault("archiveReadback")
            guard let id = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id FROM legacyStateArchive
                    WHERE sourceDomain = ? AND sourceKey = ? AND contentClass = 'opaquePluginState'
                      AND valueType = ? AND fingerprint = ?
                    """,
                arguments: [
                    capture.sourceDomain, capture.sourceKey,
                    capture.valueType, capture.fingerprint
                ]
            ) else {
                throw PluginSettingsArchiveConsistencyError.archiveReadbackFailed(
                    domain: capture.sourceDomain,
                    key: capture.sourceKey,
                    fingerprint: capture.fingerprint
                )
            }
            return String(id)
        } catch let error as PluginSettingsArchiveConsistencyError {
            throw error
        } catch {
            throw PluginSettingsArchiveConsistencyError.archiveReadbackFailed(
                domain: capture.sourceDomain,
                key: capture.sourceKey,
                fingerprint: capture.fingerprint
            )
        }
    }

    private func recordOutcome(
        _ capture: LegacyDefaultsInboxRecord,
        disposition: LegacyDefaultsDisposition,
        targetKind: String,
        targetIdentity: String,
        targetFingerprint: String,
        in db: Database
    ) throws {
        try LegacyDefaultsOutcomeRecord(
            sourceDomain: capture.sourceDomain,
            sourceKey: capture.sourceKey,
            fingerprint: capture.fingerprint,
            elementPath: "$",
            disposition: disposition,
            targetKind: targetKind,
            targetIdentity: targetIdentity,
            targetFingerprint: targetFingerprint
        ).insert(db, onConflict: .ignore)
    }

    private func resolve(_ capture: LegacyDefaultsInboxRecord, in db: Database) throws {
        try db.execute(
            sql: """
                UPDATE legacyDefaultsInbox SET lifecycleStatus = 'resolved'
                WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                """,
            arguments: [capture.sourceDomain, capture.sourceKey, capture.fingerprint]
        )
        try db.execute(
            sql: """
                UPDATE legacyStateMigration SET status = 'resolved', updatedAt = ?
                WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                """,
            arguments: [clock(), capture.sourceDomain, capture.sourceKey, capture.fingerprint]
        )
    }

    private func unresolvedRegisteredSuites() throws -> [String] {
        let registered = try dbPool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT suiteDomain FROM pluginIdentityAlias
                    WHERE suiteDomain IS NOT NULL
                    ORDER BY suiteDomain
                    """
            )
        }
        let pending = try dbPool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT ledger.sourceDomain
                    FROM legacyStateMigration ledger
                    WHERE ledger.status != 'resolved'
                      AND ledger.sourceDomain != ?
                    ORDER BY ledger.sourceDomain
                    """,
                arguments: [standardApplicationDomain]
            )
        }
        let withoutEvidence = try dbPool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT alias.suiteDomain
                    FROM pluginIdentityAlias alias
                    WHERE alias.suiteDomain IS NOT NULL
                      AND NOT EXISTS (
                        SELECT 1 FROM legacyStateMigration ledger
                        WHERE ledger.sourceDomain = alias.suiteDomain
                          AND ledger.sourceKey = ?
                          AND ledger.status = 'resolved'
                      )
                    ORDER BY alias.suiteDomain
                    """,
                arguments: [Self.suiteEvidenceKey]
            )
        }
        let nonempty = try registered.filter { domainName in
            let domain = try domainFactory(domainName)
            return !domain.persistentDomain().isEmpty
        }
        return Array(
            Set(pending)
                .union(withoutEvidence)
                .union(nonempty)
                .union(failedSuites)
        ).sorted()
    }

    private func publishSuccess() {
        publishOnMain { [weak self] in
            guard let self else { return }
            publication.revision &+= 1
            publication.lastPersistenceError = nil
        }
    }

    private func publishFailure(operation: String, pluginId: String) {
        AppLogger.plugin.critical(
            "Plugin settings persistence failed; operation=\(operation, privacy: .public), key=<redacted>, value=<redacted>"
        )
        let health = PluginSettingsPersistenceError(
            operation: operation,
            pluginId: pluginId,
            occurredAt: clock()
        )
        publishOnMain { [weak self] in
            self?.publication.lastPersistenceError = health
        }
    }

    private func publishOnMain(_ operation: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            operation()
        } else {
            DispatchQueue.main.async(execute: operation)
        }
    }

    private static func suiteDomain(_ pluginId: String) -> String {
        suitePrefix + pluginId
    }
}

/// Combine storage stays outside the Sendable store; only `publishOnMain` mutates these values.
nonisolated private final class PluginSettingsPublication: ObservableObject {
    @Published var revision = 0
    @Published var lastPersistenceError: PluginSettingsPersistenceError?
}

/// Notes commits that change what identity discovery reads, so it runs again only after one.
/// Discovery only adds and updates identity rows, so their deletion (a restore) counts as well.
nonisolated private final class DiscoverySourceChanges: TransactionObserver, @unchecked Sendable {
    private static let sourceTables: Set<String> = [
        "pluginSetting", "libraryItem", "readingHistory", "pluginMigrationAlias", "repository"
    ]
    private static let identityTables: Set<String> = ["pluginIdentityRegistry", "pluginIdentityAlias"]

    private let lock = NSLock()
    private var changed = true
    /// Whether the open transaction changed a source. Only touched on the database writer.
    private var transactionChanged = false

    func consumeChange() -> Bool {
        lock.withLock {
            defer { changed = false }
            return changed
        }
    }

    func markChanged() {
        lock.withLock { changed = true }
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        if case .delete(let tableName) = eventKind, Self.identityTables.contains(tableName) {
            return true
        }
        return Self.sourceTables.contains(eventKind.tableName)
    }

    func databaseDidChange(with event: DatabaseEvent) {
        transactionChanged = true
        stopObservingDatabaseChangesUntilNextTransaction()
    }

    func databaseDidCommit(_ db: Database) {
        guard transactionChanged else { return }
        transactionChanged = false
        markChanged()
    }

    func databaseDidRollback(_ db: Database) {
        transactionChanged = false
    }
}
