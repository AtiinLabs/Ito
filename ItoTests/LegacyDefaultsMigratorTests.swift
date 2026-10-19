import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

@MainActor
struct LegacyDefaultsMigratorTests {
    @Test func canonicalCaptureIsDeterministicTypedAndLossless() throws {
        var first: [String: Any] = [:]
        first["z"] = [NSNumber(value: 2), NSNumber(value: false)]
        first["a"] = "value"
        var second: [String: Any] = [:]
        second["a"] = "value"
        second["z"] = [NSNumber(value: 2), NSNumber(value: false)]

        let firstCapture = try CanonicalPropertyListCapture.make(value: first)
        let secondCapture = try CanonicalPropertyListCapture.make(value: second)
        #expect(firstCapture == secondCapture)

        let reversedArray = try CanonicalPropertyListCapture.make(
            value: [NSNumber(value: false), NSNumber(value: 2)]
        )
        #expect(firstCapture.fingerprint != reversedArray.fingerprint)

        let scalarCaptures = try [
            CanonicalPropertyListCapture.make(value: NSNumber(value: true)),
            CanonicalPropertyListCapture.make(value: NSNumber(value: 1)),
            CanonicalPropertyListCapture.make(value: NSNumber(value: 1.0)),
            CanonicalPropertyListCapture.make(value: "1"),
            CanonicalPropertyListCapture.make(value: Date(timeIntervalSince1970: 1))
        ]
        #expect(Set(scalarCaptures.map(\.valueType)).count == scalarCaptures.count)
        #expect(Set(scalarCaptures.map(\.fingerprint)).count == scalarCaptures.count)

        let bytes = Data([0, 255, 7, 4, 0])
        let dataCapture = try CanonicalPropertyListCapture.make(value: bytes)
        #expect(dataCapture.valueType == "data")
        #expect(dataCapture.payload == bytes)
        #expect((try dataCapture.decodedValue() as? Data) == bytes)

        let setA = try CanonicalPropertyListCapture.make(
            value: NSSet(array: ["z", "a", "m"]),
            normalizeSet: true
        )
        let setB = try CanonicalPropertyListCapture.make(
            value: NSSet(array: ["m", "z", "a"]),
            normalizeSet: true
        )
        #expect(setA == setB)
    }

    @Test func allScalarDefaultsMaterializeAndRegisteredDefaultsDoNotBlockCleanup() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.register(defaults: [AppPreferenceKeys.backgroundUpdatesEnabled: true])
        fixture.defaults.set(false, forKey: AppPreferenceKeys.backgroundUpdatesEnabled)
        fixture.defaults.set(88.5, forKey: AppPreferenceKeys.novelFontSize)

        try fixture.migrator().migrate()

        #expect(fixture.persistentDomain()[AppPreferenceKeys.backgroundUpdatesEnabled] == nil)
        #expect(fixture.defaults.object(forKey: AppPreferenceKeys.backgroundUpdatesEnabled) as? Bool == true)
        try fixture.database.dbPool.read { db in
            let count = try AppPreference.fetchCount(db)
            let background = try #require(try AppPreference.fetchOne(db, key: AppPreferenceKeys.backgroundUpdatesEnabled))
            let backgroundValue = try JSONDecoder().decode(Bool.self, from: background.value)
            let font = try #require(try AppPreference.fetchOne(db, key: AppPreferenceKeys.novelFontSize))
            let fontValue = try JSONDecoder().decode(Double.self, from: font.value)
            #expect(count == AppPreferenceCatalogEntry.allCases.count)
            #expect(backgroundValue == false)
            #expect(fontValue == 88.5)
        }
    }

    @Test func exactStandardCredentialTupleIsUntouchedAndNeverCaptured() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("credential-fixture", forKey: LegacyDefaultsSourceTuple.aniListAccessTokenKey)

        try fixture.migrator().migrate()

        #expect(fixture.persistentDomain()[LegacyDefaultsSourceTuple.aniListAccessTokenKey] as? String == "credential-fixture")
        try fixture.database.dbPool.read { db in
            let inboxCount = try LegacyDefaultsInboxRecord.fetchCount(db)
            let archiveCount = try LegacyStateArchiveRecord.fetchCount(db)
            let outcomeCount = try LegacyDefaultsOutcomeRecord.fetchCount(db)
            #expect(inboxCount == 0)
            #expect(archiveCount == 0)
            #expect(outcomeCount == 0)
        }
    }

    @Test func scalarConflictAndMalformedValueArchiveWithoutOverwritingDestination() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("Light", forKey: AppPreferenceKeys.appTheme)
        fixture.defaults.set(Data([0xff, 0x00]), forKey: "ito_user_migration_aliases")
        try fixture.database.dbPool.write { db in
            try AppPreference(key: AppPreferenceCatalog.appTheme, value: .dark).insert(db)
        }

        try fixture.migrator().migrate()

        try fixture.database.dbPool.read { db in
            let theme = try #require(try AppPreference.fetchOne(db, key: AppPreferenceKeys.appTheme))
            let themeValue = try JSONDecoder().decode(String.self, from: theme.value)
            #expect(themeValue == "Dark")
            let archives = try LegacyStateArchiveRecord.fetchAll(db)
            #expect(Set(archives.map(\.sourceKey)) == [AppPreferenceKeys.appTheme, "ito_user_migration_aliases"])
            #expect(archives.first { $0.sourceKey == "ito_user_migration_aliases" }?.valuePayload == Data([0xff, 0x00]))
        }
    }

    @Test func nonfiniteScalarIsRejectedToArchiveAndDefaulted() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(Double.infinity, forKey: AppPreferenceKeys.novelFontSize)

        try fixture.migrator().migrate()

        try fixture.database.dbPool.read { db in
            let preference = try #require(try AppPreference.fetchOne(db, key: AppPreferenceKeys.novelFontSize))
            let value = try JSONDecoder().decode(Double.self, from: preference.value)
            let archiveCount = try LegacyStateArchiveRecord.fetchCount(db)
            #expect(value == 18)
            #expect(archiveCount == 1)
        }
    }

    @Test func oneCollectionCanResolveWithNormalizedUnscopedAndArchivedOutcomes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let items = [
            fixture.item(id: "unique", pluginID: "one"),
            fixture.item(id: "alpha_same", pluginID: "alpha"),
            fixture.item(id: "beta_same", pluginID: "beta"),
            fixture.item(id: "conflict", pluginID: "one")
        ]
        try fixture.database.dbPool.write { db in
            for item in items { try item.insert(db) }
            try UpdateBadgeRecord(
                pluginId: "one", canonicalMediaId: "conflict", count: 9,
                updatedAt: nil, provenance: .runtime
            ).insert(db)
        }
        fixture.defaults.set(
            try JSONEncoder().encode(["unique": 1, "same": 2, "conflict": 3]),
            forKey: "Ito.NewChapterCounts"
        )

        try fixture.migrator().migrate()

        try fixture.database.dbPool.read { db in
            let outcomes = try LegacyDefaultsOutcomeRecord.fetchAll(db)
                .filter { $0.sourceKey == "Ito.NewChapterCounts" }
            #expect(Set(outcomes.map(\.disposition)) == [.normalized, .unscoped, .archived])
            #expect(outcomes.map(\.elementPath).count == Set(outcomes.map(\.elementPath)).count)
            let unscopedCount = try LegacyUnscopedMediaStateRecord.fetchCount(db)
            let archiveCount = try LegacyStateArchiveRecord.fetchCount(db)
            #expect(unscopedCount == 1)
            #expect(archiveCount == 1)
            let inbox = try #require(try LegacyDefaultsInboxRecord.fetchOne(
                db, sql: "SELECT * FROM legacyDefaultsInbox WHERE sourceKey = 'Ito.NewChapterCounts'"
            ))
            #expect(inbox.expectedElementCount == 3)
            #expect(inbox.lifecycleStatus == .resolved)
        }
    }

    @Test func duplicateHistoryIndexesRemainDistinctAndRetryIsIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let item = fixture.item(id: "plugin_media", pluginID: "plugin")
        let entry = TestLegacyHistoryEntry(
            item: item,
            lastReadAt: Date(timeIntervalSince1970: 1_700_000_000),
            chapterTitle: "Chapter 1"
        )
        fixture.defaults.set(try JSONEncoder().encode([entry, entry]), forKey: "ito_reading_history")

        try fixture.migrator().migrate()
        try fixture.migrator().migrate()

        try fixture.database.dbPool.read { db in
            let history = try ReadingHistoryRecord.fetchAll(db)
            #expect(history.count == 2)
            #expect(Set(history.map(\.id)).count == 2)
            let outcomes = try LegacyDefaultsOutcomeRecord.fetchAll(db)
            #expect(outcomes.filter { $0.sourceKey == "ito_reading_history" }.count == 2)
        }
    }

    @Test func missingHistoryTitlesUseDistinctStableSourceElementKeys() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let item = fixture.item(id: "plugin_media", pluginID: "plugin")
        let entry = TestLegacyHistoryEntry(
            item: item,
            lastReadAt: Date(timeIntervalSince1970: 1_700_000_000),
            chapterTitle: nil
        )
        fixture.defaults.set(try JSONEncoder().encode([entry, entry]), forKey: "ito_reading_history")

        try fixture.migrator().migrate()
        let first = try fixture.database.dbPool.read { db in
            try ReadingHistoryRecord.order(Column("id")).fetchAll(db)
        }
        try fixture.migrator().migrate()
        let second = try fixture.database.dbPool.read { db in
            try ReadingHistoryRecord.order(Column("id")).fetchAll(db)
        }

        #expect(first == second)
        #expect(first.count == 2)
        #expect(first.allSatisfy { !$0.chapterKey.isEmpty && $0.chapterKey != "unknown" })
        #expect(Set(first.map(\.chapterKey)).count == 2)
        #expect(first.allSatisfy { $0.chapterTitle == nil })
    }

    @Test func libraryMigrationPreservesItemsAndCreatesCategoryCoverage() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let items = [
            fixture.item(id: "plugin_first", pluginID: "plugin", title: "First"),
            fixture.item(id: "plugin_second", pluginID: "plugin", title: "Second")
        ]
        fixture.defaults.set(try JSONEncoder().encode(items), forKey: "ito_library_items")

        try fixture.migrator().migrate()

        try fixture.database.dbPool.read { db in
            let storedItems = try LibraryItem.order(Column("id")).fetchAll(db)
            let categories = try LibraryCategory.fetchAll(db)
            let links = try ItemCategoryLink.fetchAll(db)
            #expect(storedItems.map(\.id) == ["plugin_first", "plugin_second"])
            #expect(storedItems.allSatisfy { item in items.contains { $0.id == item.id && $0.title == item.title } })
            #expect(categories.count == 1)
            #expect(categories.first?.name == "Uncategorized")
            #expect(categories.first?.isSystemCategory == true)
            #expect(Set(links.map(\.itemId)) == Set(items.map(\.id)))
            #expect(Set(links.map(\.categoryId)) == Set(categories.map(\.id)))
        }
        #expect(fixture.persistentDomain()["ito_library_items"] == nil)
    }

    @Test func repositoriesAndImporterAliasesNormalizeSemantically() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let index = RepoIndex(
            repoName: "Fixture", repoUrl: "https://example.com", description: "Test", packages: []
        )
        let repository = Repository(
            url: " https://example.com/index.json ",
            lastFetched: Date(timeIntervalSince1970: 123),
            index: index
        )
        fixture.defaults.set(try JSONEncoder().encode([repository]), forKey: "ito_repositories")
        fixture.defaults.set(
            try JSONEncoder().encode(["foreign.one": "plugin.one", "foreign.two": "plugin.two"]),
            forKey: "ito_user_migration_aliases"
        )

        try fixture.migrator().migrate()

        try fixture.database.dbPool.read { db in
            let storedRepository = try #require(try RepositoryRecord.fetchOne(db, key: "https://example.com"))
            let storedIndex = try #require(storedRepository.indexPayload)
            let decodedIndex = try JSONDecoder().decode(RepoIndex.self, from: storedIndex)
            #expect(storedRepository.lastFetched == repository.lastFetched)
            #expect(decodedIndex == index)
            let aliases = try PluginMigrationAliasRecord.order(Column("foreignId")).fetchAll(db)
            #expect(aliases.map(\.foreignId) == ["foreign.one", "foreign.two"])
            #expect(aliases.map(\.pluginId) == ["plugin.one", "plugin.two"])
        }
        #expect(fixture.persistentDomain()["ito_repositories"] == nil)
        #expect(fixture.persistentDomain()["ito_user_migration_aliases"] == nil)
    }

    @Test func relationalCollectionsPreserveProgressTrackerPrecedenceAndBadges() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let items = [
            fixture.item(id: "plugin_manga", pluginID: "plugin"),
            fixture.item(id: "plugin_legacyOnly", pluginID: "plugin")
        ]
        try fixture.database.dbPool.write { db in
            for item in items { try item.insert(db) }
        }
        fixture.defaults.set(
            try JSONEncoder().encode(["manga": Set(["chapter-1", "chapter-1.5"])]),
            forKey: "Ito.ReadChapters"
        )
        fixture.defaults.set(
            try JSONEncoder().encode(["manga": Set<Float>([1, 1.5])]),
            forKey: "Ito.ReadChapterNumbers"
        )
        fixture.defaults.set(
            try JSONEncoder().encode(["manga": "chapter-1.5"]),
            forKey: "Ito.LastReadChapter"
        )
        fixture.defaults.set(
            try JSONEncoder().encode(["manga": ["anilist": "111", "mal": "222"]]),
            forKey: "Ito.MultiTrackerMappings"
        )
        fixture.defaults.set(
            try JSONEncoder().encode(["manga": 999, "legacyOnly": 444]),
            forKey: "Ito.TrackerMappings"
        )
        fixture.defaults.set(
            try JSONEncoder().encode(["manga": 7, "legacyOnly": 3]),
            forKey: "Ito.NewChapterCounts"
        )

        try fixture.migrator().migrate()
        try fixture.migrator().migrate()

        try fixture.database.dbPool.read { db in
            let readKeys = try ReadProgressKeyRecord.order(Column("chapterKey")).fetchAll(db)
            #expect(readKeys.map(\.chapterKey) == ["chapter-1", "chapter-1.5"])
            #expect(readKeys.allSatisfy { $0.pluginId == "plugin" && $0.canonicalMediaId == "manga" })
            let readNumbers = try ReadProgressNumberRecord.order(Column("chapterNumber")).fetchAll(db)
            #expect(readNumbers.map(\.chapterNumber) == [1, 1.5])
            let resume = try #require(try MediaReadProgressRecord.fetchOne(db))
            #expect(resume.lastReadChapterKey == "chapter-1.5")
            let links = try TrackerLinkRecord.order(Column("canonicalMediaId"), Column("providerId")).fetchAll(db)
            #expect(links.map { "\($0.canonicalMediaId):\($0.providerId):\($0.remoteMediaId)" } == [
                "legacyOnly:anilist:444", "manga:anilist:111", "manga:mal:222"
            ])
            let badges = try UpdateBadgeRecord.order(Column("canonicalMediaId")).fetchAll(db)
            #expect(badges.map { "\($0.canonicalMediaId):\($0.count)" } == ["legacyOnly:3", "manga:7"])
            let legacyOutcomes = try LegacyDefaultsOutcomeRecord.fetchAll(db)
                .filter { $0.sourceKey == "Ito.TrackerMappings" }
            let unscopedCount = try LegacyUnscopedMediaStateRecord.fetchCount(db)
            #expect(Set(legacyOutcomes.map(\.disposition)) == [.normalized, .archived])
            #expect(unscopedCount == 0)
        }
    }

    @Test func persistentMembershipFailureRetainsSourceAndRegisteredOverlayDoesNotFailRetry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.register(defaults: [AppPreferenceKeys.appTheme: "System"])
        fixture.defaults.set("Light", forKey: AppPreferenceKeys.appTheme)
        let stickyDomain = StickyLegacyDefaultsDomain(
            defaults: fixture.defaults,
            domainName: fixture.suiteName
        )

        #expect(throws: LegacyDefaultsMigrationError.self) {
            try fixture.migrator(domain: stickyDomain).migrate()
        }
        #expect(fixture.persistentDomain()[AppPreferenceKeys.appTheme] as? String == "Light")

        try fixture.migrator().migrate()
        #expect(fixture.persistentDomain()[AppPreferenceKeys.appTheme] == nil)
        #expect(fixture.defaults.object(forKey: AppPreferenceKeys.appTheme) as? String == "System")
    }

    @Test func applicationRepairsCapturedLedgerThroughEveryAdjacentState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("Light", forKey: AppPreferenceKeys.appTheme)
        let captureFault = OneShotFault(point: .afterInboxCommitBeforeReadback)
        #expect(throws: InjectedFailure.self) { try fixture.migrator(faults: captureFault).migrate() }
        fixture.defaults.removeObject(forKey: AppPreferenceKeys.appTheme)
        let events = MigrationEventRecorder()

        try fixture.migrator(events: events).migrate()

        let progression = events.values()
            .filter { $0.sourceKey == AppPreferenceKeys.appTheme }
            .map(\.outcome)
        #expect(progression == ["cleanupPending", "cleanupVerified", "resolved"])
        try fixture.database.dbPool.read { db in
            let ledger = try #require(try LegacyStateMigrationRecord.fetchOne(
                db,
                sql: "SELECT * FROM legacyStateMigration WHERE sourceKey = ?",
                arguments: [AppPreferenceKeys.appTheme]
            ))
            #expect(ledger.status == .resolved)
        }
    }

    @Test(arguments: ["missing", "unknown"])
    func corruptedStandardMigrationStatusFailsClosedWithoutMutation(_ corruption: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("Light", forKey: AppPreferenceKeys.appTheme)
        let fault = OneShotFault(point: .afterRemovalBeforeVerification)
        #expect(throws: InjectedFailure.self) {
            try fixture.migrator(faults: fault).migrate()
        }
        let fingerprint = try fixture.database.dbPool.read { db in
            try #require(try String.fetchOne(
                db,
                sql: """
                    SELECT fingerprint FROM legacyDefaultsInbox
                    WHERE sourceDomain = ? AND sourceKey = ?
                    """,
                arguments: [fixture.suiteName, AppPreferenceKeys.appTheme]
            ))
        }
        try corruptStandardMigrationStatus(
            fixture.database,
            domain: fixture.suiteName,
            key: AppPreferenceKeys.appTheme,
            fingerprint: fingerprint,
            corruption: corruption
        )
        let before = try standardMigrationState(fixture.database)

        if corruption == "missing" {
            #expect(throws: LegacyDefaultsMigrationError.missingMigrationStatus(
                domain: fixture.suiteName,
                key: AppPreferenceKeys.appTheme,
                fingerprint: fingerprint
            )) {
                try fixture.migrator().migrate()
            }
        } else {
            #expect(throws: LegacyDefaultsMigrationError.unknownMigrationStatus(
                domain: fixture.suiteName,
                key: AppPreferenceKeys.appTheme,
                fingerprint: fingerprint,
                status: "corrupt"
            )) {
                try fixture.migrator().migrate()
            }
        }

        #expect(try standardMigrationState(fixture.database) == before)
        #expect(fixture.persistentDomain()[AppPreferenceKeys.appTheme] == nil)
    }

    @Test func unavailableStandardArchiveReadbackRollsBackAndRetriesWithoutLoss() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let legacyValue = "Unsupported Theme"
        let capture = try CanonicalPropertyListCapture.make(value: legacyValue)
        fixture.defaults.set(legacyValue, forKey: AppPreferenceKeys.appTheme)
        try fixture.database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER removeStandardArchiveBeforeReadback
                AFTER INSERT ON legacyStateArchive
                WHEN NEW.contentClass = 'appNonSecret'
                BEGIN
                    DELETE FROM legacyStateArchive WHERE id = NEW.id;
                END
                """)
        }

        #expect(throws: LegacyDefaultsMigrationError.legacyStateArchiveReadbackFailed(
            domain: fixture.suiteName,
            key: AppPreferenceKeys.appTheme,
            fingerprint: capture.fingerprint
        )) {
            try fixture.migrator().migrate()
        }

        #expect(fixture.persistentDomain()[AppPreferenceKeys.appTheme] == nil)
        try fixture.database.dbPool.read { db in
            let inbox = try #require(try LegacyDefaultsInboxRecord.fetchOne(
                db,
                sql: """
                    SELECT * FROM legacyDefaultsInbox
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [fixture.suiteName, AppPreferenceKeys.appTheme, capture.fingerprint]
            ))
            let ledger = try #require(try LegacyStateMigrationRecord.fetchOne(
                db,
                sql: """
                    SELECT * FROM legacyStateMigration
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [fixture.suiteName, AppPreferenceKeys.appTheme, capture.fingerprint]
            ))
            let decoded = try CanonicalPropertyListCapture(
                valueType: inbox.valueType,
                payload: inbox.canonicalPayload,
                fingerprint: inbox.fingerprint
            ).decodedValue() as? String

            #expect(decoded == legacyValue)
            #expect(inbox.lifecycleStatus == .captured)
            #expect(ledger.status == .cleanupVerified)
            #expect(try LegacyDefaultsOutcomeRecord.fetchCount(db) == 0)
            #expect(try LegacyStateArchiveRecord.fetchCount(db) == 0)
        }

        try fixture.database.dbPool.write { db in
            try db.execute(sql: "DROP TRIGGER removeStandardArchiveBeforeReadback")
        }
        try fixture.migrator().migrate()

        try fixture.database.dbPool.read { db in
            let archive = try #require(try LegacyStateArchiveRecord.fetchOne(
                db,
                sql: """
                    SELECT * FROM legacyStateArchive
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [fixture.suiteName, AppPreferenceKeys.appTheme, capture.fingerprint]
            ))
            let outcome = try #require(try LegacyDefaultsOutcomeRecord.fetchOne(
                db,
                sql: """
                    SELECT * FROM legacyDefaultsOutcome
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [fixture.suiteName, AppPreferenceKeys.appTheme, capture.fingerprint]
            ))
            let inbox = try #require(try LegacyDefaultsInboxRecord.fetchOne(
                db,
                sql: """
                    SELECT * FROM legacyDefaultsInbox
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [fixture.suiteName, AppPreferenceKeys.appTheme, capture.fingerprint]
            ))
            let ledger = try #require(try LegacyStateMigrationRecord.fetchOne(
                db,
                sql: """
                    SELECT * FROM legacyStateMigration
                    WHERE sourceDomain = ? AND sourceKey = ? AND fingerprint = ?
                    """,
                arguments: [fixture.suiteName, AppPreferenceKeys.appTheme, capture.fingerprint]
            ))

            #expect(archive.id != nil)
            #expect(outcome.targetIdentity == archive.id.map(String.init))
            #expect(outcome.disposition == .archived)
            #expect(inbox.lifecycleStatus == .resolved)
            #expect(ledger.status == .resolved)
        }
    }

    @Test func migrationEventsAreRedactedAndCredentialsEmitNothing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let secret = "super-secret-payload"
        fixture.defaults.set(secret, forKey: AppPreferenceKeys.appTheme)
        fixture.defaults.set(secret, forKey: LegacyDefaultsSourceTuple.aniListAccessTokenKey)
        let events = MigrationEventRecorder()

        try fixture.migrator(events: events).migrate()

        let descriptions = events.values().map {
            "\($0.sourceDomain)|\($0.sourceKey)|\($0.outcome)"
        }
        #expect(descriptions.allSatisfy { !$0.contains(secret) })
        #expect(events.values().allSatisfy {
            $0.sourceKey != LegacyDefaultsSourceTuple.aniListAccessTokenKey
        })
        #expect(fixture.persistentDomain()[LegacyDefaultsSourceTuple.aniListAccessTokenKey] as? String == secret)
    }

    @Test func backupLibraryConflictIsArchivedBeforeSourceCleanup() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let local = fixture.item(id: "media", pluginID: "plugin", title: "Local")
        let backup = fixture.item(id: "media", pluginID: "plugin", title: "Backup")
        try fixture.database.dbPool.write { db in try local.insert(db) }
        fixture.defaults.set(try JSONEncoder().encode([backup]), forKey: "ito_library_items_backup")

        try fixture.migrator().migrate()

        #expect(fixture.persistentDomain()["ito_library_items_backup"] == nil)
        try fixture.database.dbPool.read { db in
            let item = try LibraryItem.fetchOne(db, key: "media")
            let archives = try LegacyStateArchiveRecord.fetchAll(db)
            #expect(item?.title == "Local")
            #expect(archives.contains { $0.sourceKey == "ito_library_items_backup" })
        }
    }

    @Test(arguments: LegacyMigrationFaultPoint.allCases)
    func everyFaultBoundaryRetriesWithoutLossOrDuplication(_ faultPoint: LegacyMigrationFaultPoint) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(91.25, forKey: AppPreferenceKeys.novelFontSize)
        let faults = OneShotFault(point: faultPoint)

        #expect(throws: InjectedFailure.self) {
            try fixture.migrator(faults: faults).migrate()
        }

        try fixture.migrator().migrate()
        try fixture.migrator().migrate()

        try fixture.database.dbPool.read { db in
            let preference = try #require(try AppPreference.fetchOne(db, key: AppPreferenceKeys.novelFontSize))
            let value = try JSONDecoder().decode(Double.self, from: preference.value)
            let inbox = try LegacyDefaultsInboxRecord.fetchAll(db)
            let outcomes = try LegacyDefaultsOutcomeRecord.fetchAll(db)
            #expect(value == 91.25)
            #expect(inbox.filter { $0.sourceKey == AppPreferenceKeys.novelFontSize }.count == 1)
            #expect(outcomes.filter { $0.sourceKey == AppPreferenceKeys.novelFontSize }.count == 1)
            let statuses = try LegacyStateMigrationRecord.fetchAll(db)
                .filter { $0.sourceKey == AppPreferenceKeys.novelFontSize }
                .map(\.status)
            #expect(statuses == [.resolved])
        }
    }

    @Test func changedFingerprintKeepsBothCapturesRecoverable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("Light", forKey: AppPreferenceKeys.appTheme)
        let faults = OneShotFault(point: .afterInboxCommitBeforeReadback)
        #expect(throws: InjectedFailure.self) { try fixture.migrator(faults: faults).migrate() }

        fixture.defaults.set("Dark", forKey: AppPreferenceKeys.appTheme)
        try fixture.migrator().migrate()

        try fixture.database.dbPool.read { db in
            let captures = try LegacyDefaultsInboxRecord.fetchAll(db)
                .filter { $0.sourceKey == AppPreferenceKeys.appTheme }
            #expect(captures.count == 2)
            #expect(captures.allSatisfy { $0.lifecycleStatus == .resolved })
            let archives = try LegacyStateArchiveRecord.fetchAll(db)
            #expect(archives.contains { $0.reason == "supersededByNewerSourceGeneration" })
            let theme = try #require(try AppPreference.fetchOne(db, key: AppPreferenceKeys.appTheme))
            let value = try JSONDecoder().decode(String.self, from: theme.value)
            #expect(value == "Dark")
        }
    }

    @Test func newerCleanedGenerationRemainsAuthoritativeAcrossRelaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("Light", forKey: AppPreferenceKeys.appTheme)
        let olderFault = OneShotFault(point: .afterInboxCommitBeforeReadback)
        #expect(throws: InjectedFailure.self) {
            try fixture.migrator(faults: olderFault).migrate()
        }

        fixture.defaults.set("Dark", forKey: AppPreferenceKeys.appTheme)
        let newerFault = OneShotFault(point: .afterCleanupBeforeNormalization)
        #expect(throws: InjectedFailure.self) {
            try fixture.migrator(faults: newerFault).migrate()
        }
        #expect(fixture.persistentDomain()[AppPreferenceKeys.appTheme] == nil)

        try fixture.migrator().migrate()

        try fixture.database.dbPool.read { db in
            let captures = try LegacyDefaultsInboxRecord
                .filter(Column("sourceKey") == AppPreferenceKeys.appTheme)
                .order(Column("fingerprint"))
                .fetchAll(db)
            let decodedValues = try captures.map {
                try CanonicalPropertyListCapture(
                    valueType: $0.valueType,
                    payload: $0.canonicalPayload,
                    fingerprint: $0.fingerprint
                ).decodedValue() as? String
            }
            #expect(captures.count == 2)
            #expect(Set(decodedValues.compactMap { $0 }) == ["Light", "Dark"])
            #expect(captures.allSatisfy { $0.lifecycleStatus == .resolved })

            let outcomes = try LegacyDefaultsOutcomeRecord
                .filter(Column("sourceKey") == AppPreferenceKeys.appTheme)
                .fetchAll(db)
            #expect(Set(outcomes.map(\.disposition)) == [.archived, .normalized])
            let archives = try LegacyStateArchiveRecord
                .filter(Column("sourceKey") == AppPreferenceKeys.appTheme)
                .fetchAll(db)
            #expect(archives.count == 1)
            #expect(archives[0].reason == "supersededByNewerSourceGeneration")

            let theme = try #require(try AppPreference.fetchOne(
                db,
                key: AppPreferenceKeys.appTheme
            ))
            #expect(try JSONDecoder().decode(String.self, from: theme.value) == "Dark")
        }
    }

    @Test func historyOnlyEvidenceUniquelyAttributesBareMediaState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.database.dbPool.write { db in
            try fixture.history(mediaKey: "media", pluginID: "history.plugin").insert(db)
        }
        fixture.defaults.set(
            try JSONEncoder().encode(["media": 4]),
            forKey: "Ito.NewChapterCounts"
        )

        try fixture.migrator().migrate()

        try fixture.database.dbPool.read { db in
            let badge = try #require(try UpdateBadgeRecord.fetchOne(db))
            #expect(badge.pluginId == "history.plugin")
            #expect(badge.canonicalMediaId == "media")
            #expect(badge.count == 4)
            #expect(try LegacyUnscopedMediaStateRecord.fetchCount(db) == 0)
        }
    }

    @Test func registryAndImporterAliasPrefixesUniquelyAttributeMediaState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try fixture.database.dbPool.write { db in
            try PluginIdentityRecord(
                pluginId: "canonical.plugin",
                manifestId: "manifest.plugin",
                lastSeenAt: now
            ).insert(db)
            try PluginIdentityAliasRecord(
                pluginId: "canonical.plugin",
                aliasKind: "filename",
                aliasValue: "filename.plugin",
                suiteDomain: "moe.ito.runners.filename.plugin",
                discoverySource: "file",
                lastSeenAt: now
            ).insert(db)
            try PluginMigrationAliasRecord(
                foreignId: "foreign.plugin",
                pluginId: "canonical.plugin",
                updatedAt: now
            ).insert(db)
        }
        fixture.defaults.set(
            try JSONEncoder().encode([
                "filename.plugin_first": 2,
                "foreign.plugin_second": 3
            ]),
            forKey: "Ito.NewChapterCounts"
        )

        try fixture.migrator().migrate()

        try fixture.database.dbPool.read { db in
            let badges = try UpdateBadgeRecord.order(Column("canonicalMediaId")).fetchAll(db)
            #expect(badges.map(\.pluginId) == ["canonical.plugin", "canonical.plugin"])
            #expect(badges.map(\.canonicalMediaId) == ["first", "second"])
            #expect(badges.map(\.count) == [2, 3])
            #expect(try LegacyUnscopedMediaStateRecord.fetchCount(db) == 0)
        }
    }

    @Test func ambiguousAliasEvidenceRemainsUnscoped() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try fixture.database.dbPool.write { db in
            for pluginID in ["one", "two"] {
                try PluginIdentityRecord(
                    pluginId: pluginID,
                    manifestId: nil,
                    lastSeenAt: now
                ).insert(db)
                try PluginIdentityAliasRecord(
                    pluginId: pluginID,
                    aliasKind: "filename",
                    aliasValue: "shared",
                    suiteDomain: "moe.ito.runners.\(pluginID)",
                    discoverySource: "file",
                    lastSeenAt: now
                ).insert(db)
            }
        }
        fixture.defaults.set(
            try JSONEncoder().encode(["shared_media": 8]),
            forKey: "Ito.NewChapterCounts"
        )

        try fixture.migrator().migrate()

        try fixture.database.dbPool.read { db in
            #expect(try UpdateBadgeRecord.fetchCount(db) == 0)
            let unresolved = try #require(try LegacyUnscopedMediaStateRecord.fetchOne(db))
            let candidates = try JSONDecoder().decode([MediaIdentity].self, from: unresolved.candidates)
            #expect(Set(candidates.map(\.pluginId)) == ["one", "two"])
            #expect(Set(candidates.map(\.canonicalMediaId)) == ["media"])
        }
    }
}

@MainActor
private final class Fixture {
    let database: TestDatabase
    let defaults: UserDefaults
    let suiteName: String

    init() throws {
        database = try TestDatabase()
        suiteName = "LegacyDefaultsMigratorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func migrator(
        faults: OneShotFault? = nil,
        domain: (any LegacyDefaultsDomain)? = nil,
        events: MigrationEventRecorder? = nil
    ) -> LegacyDefaultsMigrator {
        LegacyDefaultsMigrator(
            dbPool: database.dbPool,
            domain: domain ?? UserDefaultsLegacyDomain(defaults: defaults, domainName: suiteName),
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
            faultHandler: { point, _ in try faults?.hit(point) },
            eventObserver: { event in events?.record(event) }
        )
    }

    func persistentDomain() -> [String: Any] {
        defaults.persistentDomain(forName: suiteName) ?? [:]
    }

    func item(id: String, pluginID: String, title: String = "Title") -> LibraryItem {
        LibraryItem(
            id: id, title: title, coverUrl: nil, pluginId: pluginID, isAnime: false,
            pluginType: .manga, rawPayload: Data("payload".utf8), anilistId: nil,
            status: nil, lastCheckedAt: nil, lastUpdatedAt: nil, knownChapterCount: 1
        )
    }

    func history(mediaKey: String, pluginID: String) -> ReadingHistoryRecord {
        ReadingHistoryRecord(
            id: "history-\(pluginID)-\(mediaKey)",
            mediaKey: mediaKey,
            title: "History",
            coverUrl: nil,
            pluginId: pluginID,
            chapterKey: "chapter",
            chapterTitle: nil,
            readAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        database.cleanup()
    }
}

private struct TestLegacyHistoryEntry: Codable {
    let item: LibraryItem
    let lastReadAt: Date
    let chapterTitle: String?
}

private struct StandardMigrationState: Equatable {
    let inbox: Int
    let ledger: Int
    let outcomes: Int
    let preferences: Int
}

private func standardMigrationState(_ database: TestDatabase) throws -> StandardMigrationState {
    try database.dbPool.read { db in
        StandardMigrationState(
            inbox: try LegacyDefaultsInboxRecord.fetchCount(db),
            ledger: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM legacyStateMigration") ?? 0,
            outcomes: try LegacyDefaultsOutcomeRecord.fetchCount(db),
            preferences: try AppPreference.fetchCount(db)
        )
    }
}

private func corruptStandardMigrationStatus(
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

private struct InjectedFailure: Error {}

private final class OneShotFault: @unchecked Sendable {
    private let lock = NSLock()
    private let point: LegacyMigrationFaultPoint
    private var hasThrown = false

    init(point: LegacyMigrationFaultPoint) {
        self.point = point
    }

    func hit(_ candidate: LegacyMigrationFaultPoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard candidate == point, !hasThrown else { return }
        hasThrown = true
        throw InjectedFailure()
    }
}

private final class StickyLegacyDefaultsDomain: LegacyDefaultsDomain, @unchecked Sendable {
    let domainName: String
    private let defaults: UserDefaults

    init(defaults: UserDefaults, domainName: String) {
        self.defaults = defaults
        self.domainName = domainName
    }

    func persistentDomain() -> [String: Any] {
        defaults.persistentDomain(forName: domainName) ?? [:]
    }

    func removeObject(forKey key: String) {}
}

private final class MigrationEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LegacyMigrationEvent] = []

    func record(_ event: LegacyMigrationEvent) {
        lock.withLock { storage.append(event) }
    }

    func values() -> [LegacyMigrationEvent] {
        lock.withLock { storage }
    }
}
