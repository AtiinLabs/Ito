import Combine
import Foundation
import GRDB
import Testing
@testable import Ito

@MainActor
struct PluginSettingsStoreTests {
    @Test func synchronousCRUDPublishesOnlyCommittedRowsToExistingObserver() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        try store.prepare(pluginId: "plugin")
        var revisions: [Int] = []
        var committedAtUIInvalidation: String?
        var invalidationWasOnMain = false
        let observation = store.revisionPublisher.dropFirst().sink { revisions.append($0) }
        let invalidation = store.objectWillChange.prefix(1).sink {
            committedAtUIInvalidation = try? persistedValue(fixture.database, pluginId: "plugin", key: "theme")
            invalidationWasOnMain = Thread.isMainThread
        }
        defer {
            observation.cancel()
            invalidation.cancel()
        }

        #expect(store.get(pluginId: "plugin", key: "theme") == nil)
        #expect(store.set(pluginId: "plugin", key: "theme", value: "dark"))
        #expect(store.get(pluginId: "plugin", key: "theme") == "dark")
        #expect(try persistedValue(fixture.database, pluginId: "plugin", key: "theme") == "dark")
        #expect(committedAtUIInvalidation == "dark")
        #expect(invalidationWasOnMain)
        #expect(store.remove(pluginId: "plugin", key: "theme"))
        #expect(store.get(pluginId: "plugin", key: "theme") == nil)
        #expect(try persistedValue(fixture.database, pluginId: "plugin", key: "theme") == nil)
        #expect(revisions.count == 2)
    }

    @Test(arguments: ["INSERT", "UPDATE", "DELETE"])
    func sqlAbortLeavesDatabaseModuleAndObservedStateCommitted(_ operation: String) async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        let module = AppDefaultsModule(pluginId: "plugin", store: store)
        try store.prepare(pluginId: "plugin")
        module.set(key: "setting", value: "committed")
        var revisions: [Int] = []
        var health: [PluginSettingsPersistenceError] = []
        let revisionObservation = store.revisionPublisher.dropFirst().sink { revisions.append($0) }
        let healthObservation = store.lastPersistenceErrorPublisher.compactMap(\.self).sink {
            health.append($0)
        }
        defer {
            revisionObservation.cancel()
            healthObservation.cancel()
        }
        let revisionBeforeFailure = store.revision
        try await fixture.database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER rejectPluginSetting\(operation)
                BEFORE \(operation) ON pluginSetting
                BEGIN SELECT RAISE(ABORT, 'secret fixture must not escape'); END
                """)
        }

        if operation == "DELETE" {
            module.remove(key: "setting")
        } else {
            module.set(
                key: operation == "INSERT" ? "new-setting" : "setting",
                value: "uncommitted-secret"
            )
        }

        #expect(module.get(key: "setting") == "committed")
        #expect(store.get(pluginId: "plugin", key: "setting") == "committed")
        #expect(try persistedValue(fixture.database, pluginId: "plugin", key: "setting") == "committed")
        if operation == "INSERT" {
            #expect(module.get(key: "new-setting") == nil)
        }
        #expect(store.revision == revisionBeforeFailure)
        #expect(revisions.isEmpty)
        #expect(health.last?.operation == (operation == "DELETE" ? "remove" : "set"))
    }

    @Test func manifestAndFilenameSuitesMigrateAfterCanonicalCleanup() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        fixture.domain("moe.ito.runners.manifest").set("manifest", forKey: "shared")
        fixture.domain("moe.ito.runners.filename").set("filename-only", forKey: "fileKey")
        fixture.domain("moe.ito.runners.filename").set(Data([0xff]), forKey: "unsupported")
        let store = fixture.store()

        try store.registerInstalledPlugin(manifestId: "manifest", filenameId: "filename")
        try store.prepare(pluginId: "manifest")

        #expect(store.get(pluginId: "filename", key: "shared") == "manifest")
        #expect(store.get(pluginId: "manifest", key: "fileKey") == "filename-only")
        #expect(fixture.domain("moe.ito.runners.manifest").persistentDomain().isEmpty)
        #expect(fixture.domain("moe.ito.runners.filename").persistentDomain().isEmpty)
        let unsupported = try fixture.database.dbPool.read { db in
            try LegacyStateArchiveRecord.fetchOne(
                db,
                sql: "SELECT * FROM legacyStateArchive WHERE sourceKey = 'unsupported'"
            )
        }
        #expect(unsupported?.contentClass == .opaquePluginState)
        #expect(unsupported?.sourceDomain == "moe.ito.runners.filename")
    }

    @Test func precedenceIsDiscoveryOrderIndependentAndArchivesEveryLosingSource() throws {
        let forward = try precedenceSnapshot(order: ["filename", "zeta", "alpha"])
        let reverse = try precedenceSnapshot(order: ["alpha", "zeta", "filename"])

        #expect(forward == reverse)
        #expect(forward.value == "manifest-wins")
        #expect(forward.archives == [
            "moe.ito.runners.alpha=equal-loser",
            "moe.ito.runners.filename=filename-loser",
            "moe.ito.runners.zeta=equal-loser"
        ])
    }

    @Test func existingGRDBRowPrecedesEveryAliasAndEqualWinnerValuesDeduplicate() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        #expect(store.set(pluginId: "manifest", key: "shared", value: "durable"))
        fixture.domain("moe.ito.runners.manifest").set("durable", forKey: "shared")
        fixture.domain("moe.ito.runners.filename").set("loser", forKey: "shared")

        try store.registerInstalledPlugin(manifestId: "manifest", filenameId: "filename")
        try store.prepare(pluginId: "manifest")

        #expect(store.get(pluginId: "manifest", key: "shared") == "durable")
        let archives = try fixture.database.dbPool.read { db in
            try LegacyStateArchiveRecord.fetchAll(db)
        }
        #expect(archives.count == 1)
        #expect(archives.first?.sourceDomain == "moe.ito.runners.filename")
    }

    @Test func runtimeRecommitOfMigratedValueRemainsAuthoritativeOverLaterGeneration() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let suite = "moe.ito.runners.authority"
        let domain = fixture.domain(suite)
        domain.set("A", forKey: "setting")
        let store = fixture.store()
        try store.registerInstalledPlugin(manifestId: "authority", filenameId: "authority")
        try store.prepare(pluginId: "authority")

        #expect(store.get(pluginId: "authority", key: "setting") == "A")
        #expect(try fixture.database.dbPool.read {
            try PluginSettingMigrationAuthorityRecord.fetchCount($0)
        } == 1)

        #expect(store.set(pluginId: "authority", key: "setting", value: "A"))
        #expect(try fixture.database.dbPool.read {
            try PluginSettingMigrationAuthorityRecord.fetchCount($0)
        } == 0)

        domain.set("B", forKey: "setting")
        try store.prepare(pluginId: "authority")

        #expect(store.get(pluginId: "authority", key: "setting") == "A")
        #expect(domain.persistentDomain()["setting"] == nil)
        let generationB = try CanonicalPropertyListCapture.make(value: "B")
        let evidence = try fixture.database.dbPool.read { db in
            (
                try LegacyDefaultsInboxRecord.fetchOne(
                    db,
                    key: [
                        "sourceDomain": suite,
                        "sourceKey": "setting",
                        "fingerprint": generationB.fingerprint
                    ]
                ),
                try LegacyStateMigrationRecord.fetchOne(
                    db,
                    key: [
                        "sourceDomain": suite,
                        "sourceKey": "setting",
                        "fingerprint": generationB.fingerprint
                    ]
                ),
                try LegacyStateArchiveRecord.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM legacyStateArchive
                        WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                        """,
                    arguments: [suite, "setting", generationB.fingerprint]
                ),
                try PluginSettingMigrationAuthorityRecord.fetchCount(db)
            )
        }
        #expect(evidence.0?.lifecycleStatus == .resolved)
        #expect(evidence.1?.status == .resolved)
        #expect(evidence.2?.reason == "pluginSettingConflict")
        #expect(evidence.3 == 0)
    }

    @Test func stickyRemovalFailsReadbackAndLeavesCanonicalCapturePending() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let sticky = MemoryPluginDomain(name: "moe.ito.runners.sticky", sticky: true)
        sticky.set("value", forKey: "setting")
        fixture.catalog.install(sticky)
        let store = fixture.store()
        try store.registerInstalledPlugin(manifestId: "sticky", filenameId: "sticky")

        #expect(throws: LegacyDefaultsMigrationError.self) {
            try store.prepare(pluginId: "sticky")
        }
        #expect(sticky.persistentDomain()["setting"] as? String == "value")
        let state = try fixture.database.dbPool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT status FROM legacyStateMigration
                    WHERE sourceDomain = ? AND sourceKey = ?
                    """,
                arguments: [sticky.domainName, "setting"]
            )
        }
        #expect(state == LegacyMigrationStatus.cleanupPending.rawValue)
    }

    @Test func postRemovalCrashRetriesIdempotentlyWithoutDuplicateRows() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        fixture.domain("moe.ito.runners.retry").set("value", forKey: "setting")
        let fault = OneShotPluginFault(.afterRemovalBeforeVerification)
        let failing = fixture.store(faultHandler: fault.hit)
        try failing.registerInstalledPlugin(manifestId: "retry", filenameId: "retry")
        #expect(throws: InjectedPluginFailure.self) {
            try failing.prepare(pluginId: "retry")
        }
        #expect(fixture.domain("moe.ito.runners.retry").persistentDomain()["setting"] == nil)

        let retry = fixture.store()
        try retry.prepare(pluginId: "retry")
        try retry.prepare(pluginId: "retry")
        #expect(retry.get(pluginId: "retry", key: "setting") == "value")
        let counts = try fixture.database.dbPool.read { db in
            (
                try PluginSettingRecord.fetchCount(db),
                try LegacyDefaultsInboxRecord.fetchCount(db),
                try LegacyDefaultsOutcomeRecord.fetchCount(db)
            )
        }
        #expect(counts.0 == 1)
        #expect(counts.1 == 2) // Suite evidence plus the setting capture.
        #expect(counts.2 == 1)
    }

    @Test func exactCredentialTupleIsExcludedWhileSameNamedPluginKeyMigrates() throws {
        let fixture = try StoreFixture(standardDomain: "moe.itoapp.ito")
        defer { fixture.cleanup() }
        fixture.domain("moe.itoapp.ito").set("app-secret", forKey: "anilist_access_token")
        fixture.domain("moe.ito.runners.plugin").set("plugin-value", forKey: "anilist_access_token")
        let store = fixture.store()

        try store.prepare(pluginId: "plugin")

        #expect(store.get(pluginId: "plugin", key: "anilist_access_token") == "plugin-value")
        #expect(
            fixture.domain("moe.itoapp.ito").persistentDomain()["anilist_access_token"] as? String
                == "app-secret"
        )
        let standardMigrationRows = try fixture.database.dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM legacyDefaultsInbox
                    WHERE sourceDomain = ? AND sourceKey = 'anilist_access_token'
                    """,
                arguments: ["moe.itoapp.ito"]
            ) ?? 0
        }
        #expect(standardMigrationRows == 0)
    }

    @Test func unregisteredLookalikeDomainRemainsByteForByteUntouched() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let lookalike = fixture.domain("moe.ito.runners.plugin.lookalike")
        lookalike.set(Data([0x01, 0x02, 0x03]), forKey: "blob")
        let before = try CanonicalPropertyListCapture.make(value: lookalike.persistentDomain()).payload

        try fixture.store().prepare(pluginId: "plugin")

        let after = try CanonicalPropertyListCapture.make(value: lookalike.persistentDomain()).payload
        #expect(after == before)
    }

    @Test func discoverySeedsRepositoryLibraryHistoryAliasTargetsAndPriorRows() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let repo = RepoIndex(
            repoName: "Test",
            repoUrl: "https://example.com",
            description: "",
            packages: [repoPackage(id: "repository-plugin")]
        )
        try fixture.database.dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO repository (url, indexPayload) VALUES (?, ?);
                    INSERT INTO pluginSetting (pluginId, key, value) VALUES (?, 'key', X'31');
                    INSERT INTO libraryItem
                        (id, title, pluginId, isAnime, rawPayload)
                    VALUES ('library-item', 'Library', 'library-plugin', 0, X'7B7D');
                    INSERT INTO readingHistory
                        (id, mediaKey, title, pluginId, mediaKind, chapterKey, readAt)
                    VALUES ('history-item', 'media', 'History', 'history-plugin', 'manga', 'chapter', ?);
                    INSERT INTO pluginMigrationAlias (foreignId, pluginId, updatedAt)
                    VALUES ('foreign-plugin', 'alias-target-plugin', ?)
                    """,
                arguments: [
                    "https://example.com",
                    try JSONEncoder().encode(repo),
                    "prior-row-plugin",
                    Date(),
                    Date()
                ]
            )
        }

        try fixture.store().discover()

        let ids = try fixture.database.dbPool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT pluginId FROM pluginIdentityRegistry"))
        }
        #expect(ids.isSuperset(of: [
            "repository-plugin",
            "library-plugin",
            "history-plugin",
            "alias-target-plugin",
            "prior-row-plugin"
        ]))
        let foreignSuite = try fixture.database.dbPool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT suiteDomain FROM pluginIdentityAlias
                    WHERE pluginId = 'alias-target-plugin' AND aliasValue = 'foreign-plugin'
                    """
            )
        }
        #expect(foreignSuite == "moe.ito.runners.foreign-plugin")
    }

    @Test func snapshotRegistersEachDiscoveredIdentityOncePerPass() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let pluginIds = (1...6).map { "repository-plugin-\($0)" }
        let repo = RepoIndex(
            repoName: "Test",
            repoUrl: "https://example.com",
            description: "",
            packages: pluginIds.map { repoPackage(id: $0) }
        )
        try fixture.database.dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO repository (url, indexPayload) VALUES (?, ?)",
                arguments: ["https://example.com", try JSONEncoder().encode(repo)]
            )
        }
        let aliasWrites = AliasWriteCounter()
        fixture.database.dbPool.add(transactionObserver: aliasWrites)

        try fixture.store().prepareForDurableSnapshot()

        // Rediscovering for every prepared plugin rewrote every alias again
        // (6 + 6 * 6 writes), growing quadratically with installed plugins.
        #expect(aliasWrites.count == pluginIds.count)
    }

    @Test func settingsReadsRescanOnlyAfterSomethingDiscoveryReadsChanged() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let repo = RepoIndex(
            repoName: "Test",
            repoUrl: "https://example.com",
            description: "",
            packages: [repoPackage(id: "repository-plugin")]
        )
        try fixture.database.dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO repository (url, indexPayload) VALUES (?, ?)",
                arguments: ["https://example.com", try JSONEncoder().encode(repo)]
            )
        }
        let store = fixture.store()
        try store.prepare(pluginId: "installed")
        let aliasWrites = AliasWriteCounter()
        fixture.database.dbPool.add(transactionObserver: aliasWrites)
        func registered() throws -> Set<String> {
            try fixture.database.dbPool.read { db in
                Set(try String.fetchAll(db, sql: "SELECT pluginId FROM pluginIdentityRegistry"))
            }
        }

        _ = store.get(pluginId: "installed", key: "mode")
        _ = store.get(pluginId: "installed", key: "mode")
        #expect(aliasWrites.count == 0)

        // A library item naming another plugin is discovered by the next read.
        try fixture.database.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO libraryItem (id, title, pluginId, isAnime, rawPayload)
                VALUES ('library-item', 'Library', 'library-plugin', 0, X'7B7D')
                """)
        }
        _ = store.get(pluginId: "installed", key: "mode")
        #expect(try registered().contains("library-plugin"))

        // A restore that drops every identity has them registered again.
        try fixture.database.dbPool.write { db in
            try PluginIdentityAliasRecord.deleteAll(db)
            try PluginIdentityRecord.deleteAll(db)
        }
        _ = store.get(pluginId: "installed", key: "mode")
        #expect(try registered().isSuperset(of: ["installed", "library-plugin", "repository-plugin"]))
    }

    @Test func aRepositoryIndexThatCantBeReadIsSkippedAndTheRestIsDiscovered() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let readable = RepoIndex(
            repoName: "Readable",
            repoUrl: "https://readable.example",
            description: "",
            packages: [repoPackage(id: "repository-plugin")]
        )
        try fixture.database.dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO repository (url, indexPayload) VALUES (?, ?)",
                arguments: ["https://malformed.example", Data("not-json".utf8)]
            )
            try db.execute(
                sql: "INSERT INTO repository (url, indexPayload) VALUES (?, ?)",
                arguments: ["https://readable.example", try JSONEncoder().encode(readable)]
            )
        }
        let store = fixture.store()

        try store.prepareForDurableSnapshot([
            PluginSettingsDiscovery(pluginId: "installed-plugin", source: "test")
        ])

        let registered = try fixture.database.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT pluginId FROM pluginIdentityRegistry ORDER BY pluginId")
        }
        #expect(registered == ["installed-plugin", "repository-plugin"])
    }

    @Test func readinessRejectsRegisteredSuiteWithoutEvidenceAndFailedPrepare() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let fault = OneShotPluginFault(.beforeDatabaseWrite)
        let store = fixture.store(faultHandler: fault.hit)
        try store.registerInstalledPlugin(manifestId: "pending", filenameId: "pending")

        #expect(throws: InjectedPluginFailure.self) {
            try store.prepareForDurableSnapshot()
        }
        let evidence = try fixture.database.dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM legacyStateMigration
                    WHERE sourceDomain = 'moe.ito.runners.pending'
                    """
            ) ?? 0
        }
        #expect(evidence == 0)
    }

    @Test func readinessRejectsPendingOrphanPluginSuiteLedgerWithoutIdentityAlias() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let orphanDomain = "moe.ito.runners.orphan"
        try fixture.database.dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO legacyDefaultsInbox
                        (sourceDomain, sourceKey, valueType, canonicalPayload, fingerprint,
                         expectedElementCount, capturedAt, lifecycleStatus)
                    VALUES (?, 'setting', 'string', X'41', 'orphan', 1, 0, 'captured');
                    INSERT INTO legacyStateMigration
                        (sourceDomain, sourceKey, fingerprint, status, updatedAt)
                    VALUES (?, 'setting', 'orphan', 'cleanupVerified', 0)
                    """,
                arguments: [orphanDomain, orphanDomain]
            )
        }

        #expect(throws: PluginSettingsReadinessError.unresolvedSuites([orphanDomain])) {
            try fixture.store().prepareForDurableSnapshot()
        }
    }

    @Test func readinessPropagatesUnavailableRegisteredSuiteWithoutFallbackMutation() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let suiteDomain = "moe.ito.runners.unavailable"
        let standardSentinel = fixture.domain(fixture.standardDomain)
        standardSentinel.set("must-remain", forKey: "standard-only")
        let store = PluginSettingsStore(
            dbPool: fixture.database.dbPool,
            standardApplicationDomain: fixture.standardDomain,
            domainFactory: { domainName in
                guard domainName != suiteDomain else {
                    throw PluginSettingsReadinessError.suiteUnavailable(domainName)
                }
                return standardSentinel
            }
        )
        try store.registerInstalledPlugin(manifestId: "unavailable", filenameId: "unavailable")
        let registrationBefore = try fixture.database.dbPool.read { db in
            (
                try PluginIdentityRecord.fetchAll(db),
                try PluginIdentityAliasRecord.fetchAll(db)
            )
        }

        #expect(throws: PluginSettingsReadinessError.suiteUnavailable(suiteDomain)) {
            try store.prepareForDurableSnapshot()
        }

        let stateAfter = try fixture.database.dbPool.read { db in
            (
                try PluginIdentityRecord.fetchAll(db),
                try PluginIdentityAliasRecord.fetchAll(db),
                try PluginSettingRecord.fetchCount(db),
                try LegacyDefaultsInboxRecord.fetchCount(db),
                try LegacyDefaultsOutcomeRecord.fetchCount(db),
                try LegacyStateMigrationRecord.fetchCount(db),
                try LegacyStateArchiveRecord.fetchCount(db)
            )
        }
        #expect(stateAfter.0 == registrationBefore.0)
        #expect(stateAfter.1 == registrationBefore.1)
        #expect(stateAfter.2 == 0)
        #expect(stateAfter.3 == 0)
        #expect(stateAfter.4 == 0)
        #expect(stateAfter.5 == 0)
        #expect(stateAfter.6 == 0)
        #expect(store.revision == 0)
        #expect(store.lastPersistenceError == nil)
        #expect(standardSentinel.persistentDomain()["standard-only"] as? String == "must-remain")
    }

    @Test(arguments: ["manifest", "filename", "historical"])
    func conflictingSuiteOwnershipRejectsWithoutTouchingEitherSource(_ conflictKind: String) throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let sharedSuite = "moe.ito.runners.shared"
        let claimantSuite = "moe.ito.runners.claimant"
        fixture.domain(sharedSuite).set(Data([0x01, 0x02]), forKey: "shared-source")
        fixture.domain(claimantSuite).set(Data([0x03, 0x04]), forKey: "claimant-source")
        let sharedBefore = try CanonicalPropertyListCapture.make(
            value: fixture.domain(sharedSuite).persistentDomain()
        ).payload
        let claimantBefore = try CanonicalPropertyListCapture.make(
            value: fixture.domain(claimantSuite).persistentDomain()
        ).payload
        let store = fixture.store()

        switch conflictKind {
        case "manifest":
            try store.registerInstalledPlugin(manifestId: "owner", filenameId: "shared")
        case "filename", "historical":
            try store.registerInstalledPlugin(manifestId: "shared", filenameId: "shared")
        default:
            Issue.record("Unexpected conflict kind \(conflictKind)")
            return
        }

        let discovery: [PluginSettingsDiscovery]
        if conflictKind == "historical" {
            try fixture.database.dbPool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO pluginMigrationAlias (foreignId, pluginId, updatedAt)
                        VALUES ('shared', 'claimant', ?)
                        """,
                    arguments: [Date()]
                )
            }
            discovery = []
        } else {
            discovery = [
                PluginSettingsDiscovery(
                    pluginId: conflictKind == "manifest" ? "shared" : "claimant",
                    manifestId: conflictKind == "manifest" ? "shared" : "claimant",
                    filenameId: conflictKind == "manifest" ? "claimant" : "shared",
                    source: "conflict-\(conflictKind)"
                )
            ]
        }

        #expect(throws: PluginSettingsReadinessError.ambiguousSuiteOwnership(
            suiteDomain: sharedSuite,
            existingPluginId: conflictKind == "manifest" ? "owner" : "shared",
            claimingPluginId: conflictKind == "manifest" ? "shared" : "claimant"
        )) {
            try store.prepareForDurableSnapshot(discovery)
        }

        let sharedAfter = try CanonicalPropertyListCapture.make(
            value: fixture.domain(sharedSuite).persistentDomain()
        ).payload
        let claimantAfter = try CanonicalPropertyListCapture.make(
            value: fixture.domain(claimantSuite).persistentDomain()
        ).payload
        #expect(sharedAfter == sharedBefore)
        #expect(claimantAfter == claimantBefore)
        let migrationCount = try fixture.database.dbPool.read {
            try LegacyStateMigrationRecord.fetchCount($0)
        }
        #expect(migrationCount == 0)
    }

    @Test(arguments: [
        LegacyMigrationFaultPoint.afterInboxCommitBeforeReadback,
        .afterInboxReadbackBeforeRemoval,
        .afterRemovalBeforeVerification,
        .duringRemovalVerification,
        .duringNormalizationTransaction,
        .afterNormalizationCommit
    ])
    func changedSourceGenerationSupersedesStaleCaptureAcrossRelaunch(
        _ point: LegacyMigrationFaultPoint
    ) throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let suite = "moe.ito.runners.generations"
        fixture.domain(suite).set("old", forKey: "setting")
        let oldCapture = try CanonicalPropertyListCapture.make(value: "old")
        let faultSourceKey = switch point {
        case .duringNormalizationTransaction, .afterNormalizationCommit: "*"
        default: "setting"
        }
        let fault = SourceTuplePluginFault(point, sourceKey: faultSourceKey)
        let firstLaunch = fixture.store(faultHandler: fault.hit)
        try firstLaunch.registerInstalledPlugin(
            manifestId: "generations",
            filenameId: "generations"
        )
        #expect(throws: InjectedPluginFailure.self) {
            try firstLaunch.prepare(pluginId: "generations")
        }

        fixture.domain(suite).set("new", forKey: "setting")
        let relaunched = fixture.store()
        try relaunched.prepare(pluginId: "generations")

        #expect(relaunched.get(pluginId: "generations", key: "setting") == "new")
        let evidence = try fixture.database.dbPool.read { db in
            (
                try LegacyDefaultsInboxRecord
                    .filter(Column("sourceDomain") == suite && Column("sourceKey") == "setting")
                    .order(Column("fingerprint"))
                    .fetchAll(db),
                try LegacyStateArchiveRecord
                    .filter(Column("sourceDomain") == suite && Column("sourceKey") == "setting")
                    .fetchAll(db),
                try LegacyDefaultsOutcomeRecord
                    .filter(Column("sourceDomain") == suite && Column("sourceKey") == "setting")
                    .fetchAll(db)
            )
        }
        #expect(evidence.0.count == 2)
        #expect(evidence.0.allSatisfy { $0.lifecycleStatus == .resolved })
        #expect(evidence.1.count == 1)
        #expect(evidence.1.first?.fingerprint == oldCapture.fingerprint)
        #expect(evidence.1.first?.reason == "pluginSourceGenerationSuperseded")
        #expect(evidence.2.contains {
            $0.fingerprint == oldCapture.fingerprint && $0.disposition == .archived
        })
        #expect(evidence.2.contains {
            $0.fingerprint != oldCapture.fingerprint && $0.disposition == .normalized
        })
    }

    @Test func archiveReadbackFailurePropagatesTypedErrorAndRollsBackResolution() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let losingSuite = "moe.ito.runners.filename"
        fixture.domain("moe.ito.runners.manifest").set("winner", forKey: "shared")
        fixture.domain(losingSuite).set("loser", forKey: "shared")
        let loserCapture = try CanonicalPropertyListCapture.make(value: "loser")
        let store = fixture.store(operationFault: { operation in
            if operation == "archiveReadback" {
                throw InjectedPluginFailure()
            }
        })
        try store.registerInstalledPlugin(manifestId: "manifest", filenameId: "filename")

        #expect(throws: PluginSettingsArchiveConsistencyError.archiveReadbackFailed(
            domain: losingSuite,
            key: "shared",
            fingerprint: loserCapture.fingerprint
        )) {
            try store.prepare(pluginId: "manifest")
        }

        let state = try fixture.database.dbPool.read { db in
            (
                try LegacyStateArchiveRecord.fetchCount(db),
                try LegacyDefaultsOutcomeRecord.fetchCount(db),
                try String.fetchOne(
                    db,
                    sql: """
                        SELECT lifecycleStatus FROM legacyDefaultsInbox
                        WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                        """,
                    arguments: [losingSuite, "shared", loserCapture.fingerprint]
                )
            )
        }
        #expect(state.0 == 0)
        #expect(state.1 == 0)
        #expect(state.2 == LegacyInboxLifecycleStatus.captured.rawValue)
    }

    @Test(arguments: ["missing", "unknown"])
    func corruptedPluginMigrationStatusFailsClosedWithoutMutation(_ corruption: String) throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let suite = "moe.ito.runners.status"
        fixture.domain(suite).set("value", forKey: "setting")
        let fault = SourceTuplePluginFault(.afterRemovalBeforeVerification, sourceKey: "setting")
        let firstLaunch = fixture.store(faultHandler: fault.hit)
        try firstLaunch.registerInstalledPlugin(manifestId: "status", filenameId: "status")
        #expect(throws: InjectedPluginFailure.self) {
            try firstLaunch.prepare(pluginId: "status")
        }
        let fingerprint = try fixture.database.dbPool.read { db in
            try #require(try String.fetchOne(
                db,
                sql: """
                    SELECT fingerprint FROM legacyDefaultsInbox
                    WHERE sourceDomain = ? AND sourceKey = 'setting'
                    """,
                arguments: [suite]
            ))
        }
        try corruptMigrationStatus(
            fixture.database,
            domain: suite,
            key: "setting",
            fingerprint: fingerprint,
            corruption: corruption
        )
        let before = try pluginMigrationState(fixture.database)
        let relaunched = fixture.store()

        if corruption == "missing" {
            #expect(throws: LegacyDefaultsMigrationError.missingMigrationStatus(
                domain: suite,
                key: "setting",
                fingerprint: fingerprint
            )) {
                try relaunched.prepare(pluginId: "status")
            }
        } else {
            #expect(throws: LegacyDefaultsMigrationError.unknownMigrationStatus(
                domain: suite,
                key: "setting",
                fingerprint: fingerprint,
                status: "corrupt"
            )) {
                try relaunched.prepare(pluginId: "status")
            }
        }

        #expect(try pluginMigrationState(fixture.database) == before)
        #expect(fixture.domain(suite).persistentDomain().isEmpty)
        #expect(relaunched.revision == 0)
    }

    @Test func secondaryRegisteredSuiteLookupFailurePreservesPrimaryFailure() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        fixture.domain("moe.ito.runners.aggregate").set("value", forKey: "setting")
        let primaryFault = OneShotPluginFault(.beforeDatabaseWrite)
        let store = fixture.store(
            faultHandler: primaryFault.hit,
            operationFault: { operation in
                if operation == "registeredSuiteDomains" {
                    throw InjectedSuiteLookupFailure()
                }
            }
        )
        try store.registerInstalledPlugin(manifestId: "aggregate", filenameId: "aggregate")

        do {
            try store.prepare(pluginId: "aggregate")
            Issue.record("Expected aggregate preparation failure")
        } catch let error as PluginSettingsPreparationError {
            #expect(error.primaryError is InjectedPluginFailure)
            #expect(error.registeredSuiteLookupError is InjectedSuiteLookupFailure)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(try fixture.database.dbPool.read { try LegacyDefaultsInboxRecord.fetchCount($0) } == 0)
        #expect(
            fixture.domain("moe.ito.runners.aggregate").persistentDomain()["setting"] as? String
                == "value"
        )
        #expect(store.revision == 0)
    }

    private func precedenceSnapshot(order: [String]) throws -> PrecedenceSnapshot {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        fixture.domain("moe.ito.runners.manifest").set("manifest-wins", forKey: "shared")
        fixture.domain("moe.ito.runners.filename").set("filename-loser", forKey: "shared")
        fixture.domain("moe.ito.runners.alpha").set("equal-loser", forKey: "shared")
        fixture.domain("moe.ito.runners.zeta").set("equal-loser", forKey: "shared")
        let store = fixture.store()
        for alias in order {
            try store.discover([
                PluginSettingsDiscovery(
                    pluginId: "manifest",
                    manifestId: "manifest",
                    filenameId: alias,
                    source: "permutation"
                )
            ])
        }
        try store.prepare(pluginId: "manifest")
        let archives = try fixture.database.dbPool.read { db in
            try LegacyStateArchiveRecord
                .filter(Column("sourceKey") == "shared")
                .order(Column("sourceDomain"))
                .fetchAll(db)
        }
        return PrecedenceSnapshot(
            value: store.get(pluginId: "manifest", key: "shared"),
            archives: try archives.map {
                let value = try CanonicalPropertyListCapture(
                    valueType: $0.valueType,
                    payload: $0.valuePayload,
                    fingerprint: $0.fingerprint
                ).decodedValue() as? String
                return "\($0.sourceDomain)=\(value ?? "")"
            }
        )
    }

    private func persistedValue(
        _ database: TestDatabase,
        pluginId: String,
        key: String
    ) throws -> String? {
        try database.dbPool.read { db in
            try PluginSettingRecord.fetchOne(
                db,
                key: ["pluginId": pluginId, "key": key]
            ).flatMap { String(data: $0.value, encoding: .utf8) }
        }
    }

    private func repoPackage(id: String) -> RepoPackage {
        RepoPackage(
            id: id,
            name: id,
            version: "1",
            minAppVersion: "1",
            downloadUrl: "plugin.ito",
            iconUrl: nil,
            sha256: "",
            pluginType: "manga",
            archived: nil,
            archivedReason: nil,
            archivedDate: nil
        )
    }
}

private struct PrecedenceSnapshot: Equatable {
    let value: String?
    let archives: [String]
}

private struct PluginMigrationState: Equatable {
    let inbox: Int
    let ledger: Int
    let outcomes: Int
    let settings: Int
}

private func pluginMigrationState(_ database: TestDatabase) throws -> PluginMigrationState {
    try database.dbPool.read { db in
        PluginMigrationState(
            inbox: try LegacyDefaultsInboxRecord.fetchCount(db),
            ledger: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM legacyStateMigration") ?? 0,
            outcomes: try LegacyDefaultsOutcomeRecord.fetchCount(db),
            settings: try PluginSettingRecord.fetchCount(db)
        )
    }
}

private func corruptMigrationStatus(
    _ database: TestDatabase,
    domain: String,
    key: String,
    fingerprint: String,
    corruption: String
) throws {
    try database.dbPool.write { db in
        if corruption == "missing" {
            try db.execute(
                sql: """
                    DELETE FROM legacyStateMigration
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [domain, key, fingerprint]
            )
        } else {
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
            try db.execute(
                sql: """
                    UPDATE legacyStateMigration SET status = 'corrupt'
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [domain, key, fingerprint]
            )
        }
    }
}

private final class StoreFixture {
    let database: TestDatabase
    let catalog = PluginDomainCatalog()
    let standardDomain: String

    init(standardDomain: String = "moe.itoapp.ito") throws {
        database = try TestDatabase()
        self.standardDomain = standardDomain
    }

    func store(
        faultHandler: @escaping PluginSettingsStore.FaultHandler = { _, _ in },
        operationFault: @escaping PluginSettingsStore.OperationFault = { _ in }
    ) -> PluginSettingsStore {
        PluginSettingsStore(
            dbPool: database.dbPool,
            standardApplicationDomain: standardDomain,
            domainFactory: catalog.domain,
            faultHandler: faultHandler,
            operationFault: operationFault
        )
    }

    func domain(_ name: String) -> MemoryPluginDomain {
        catalog.memoryDomain(name)
    }

    func cleanup() {
        database.cleanup()
    }
}

private final class PluginDomainCatalog: @unchecked Sendable {
    private let lock = NSLock()
    private var domains: [String: MemoryPluginDomain] = [:]

    func install(_ domain: MemoryPluginDomain) {
        lock.withLock { domains[domain.domainName] = domain }
    }

    func memoryDomain(_ name: String) -> MemoryPluginDomain {
        lock.withLock {
            if let domain = domains[name] { return domain }
            let domain = MemoryPluginDomain(name: name)
            domains[name] = domain
            return domain
        }
    }

    func domain(_ name: String) -> any LegacyDefaultsDomain {
        memoryDomain(name)
    }
}

private final class MemoryPluginDomain: LegacyDefaultsDomain, @unchecked Sendable {
    let domainName: String
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private let sticky: Bool

    init(name: String, sticky: Bool = false) {
        domainName = name
        self.sticky = sticky
    }

    func persistentDomain() -> [String: Any] {
        lock.withLock { values }
    }

    func removeObject(forKey key: String) {
        guard !sticky else { return }
        _ = lock.withLock { values.removeValue(forKey: key) }
    }

    func set(_ value: Any, forKey key: String) {
        lock.withLock { values[key] = value }
    }
}

private struct InjectedPluginFailure: Error {}
private struct InjectedSuiteLookupFailure: Error {}

private final class OneShotPluginFault: @unchecked Sendable {
    private let lock = NSLock()
    private let point: LegacyMigrationFaultPoint
    private var fired = false

    init(_ point: LegacyMigrationFaultPoint) {
        self.point = point
    }

    func hit(_ point: LegacyMigrationFaultPoint, tuple: LegacyDefaultsSourceTuple) throws {
        let shouldThrow = lock.withLock {
            guard point == self.point, !fired else { return false }
            fired = true
            return true
        }
        if shouldThrow { throw InjectedPluginFailure() }
    }
}

private final class SourceTuplePluginFault: @unchecked Sendable {
    private let lock = NSLock()
    private let point: LegacyMigrationFaultPoint
    private let sourceKey: String
    private var fired = false

    init(_ point: LegacyMigrationFaultPoint, sourceKey: String) {
        self.point = point
        self.sourceKey = sourceKey
    }

    func hit(_ point: LegacyMigrationFaultPoint, tuple: LegacyDefaultsSourceTuple) throws {
        let shouldThrow = lock.withLock {
            guard point == self.point, tuple.sourceKey == sourceKey, !fired else { return false }
            fired = true
            return true
        }
        if shouldThrow { throw InjectedPluginFailure() }
    }
}

/// Counts inserted, updated, and deleted `pluginIdentityAlias` rows.
private final class AliasWriteCounter: TransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0

    var count: Int { lock.withLock { writes } }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        eventKind.tableName == "pluginIdentityAlias"
    }

    func databaseDidChange(with event: DatabaseEvent) {
        lock.withLock { writes += 1 }
    }

    func databaseDidCommit(_ db: Database) {}

    func databaseDidRollback(_ db: Database) {}
}
