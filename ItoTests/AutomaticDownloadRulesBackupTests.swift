// swiftlint:disable file_length
import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

private typealias Fixture = SubscriptionLedgerFixture

/// The `automaticDownloadRules` backup component: what export keeps and sanitizes, what import accepts, and how
/// restore turns a rule into a new paused rule without baseline, events, owners or jobs. Every test is deterministic:
/// real databases and stores with a fixed clock, no sleeps.
struct AutomaticDownloadRulesBackupTests {
    private static let date = Date(timeIntervalSince1970: 1_700_000_000)
    private static let plugin = "plugin.test"

    // MARK: - Helpers

    private static func media(_ id: String, kind: MediaKind = .manga) -> MediaIdentity {
        MediaIdentity(pluginId: plugin, canonicalMediaId: id, mediaKind: kind)
    }

    private static func storage(_ selection: EditionSelection) -> Data {
        (try? selection.storageData()) ?? Data()
    }

    private static func portable(
        _ id: String,
        mode: SubscriptionMode = .newReleases,
        window: Int? = nil,
        cap: Int = 5,
        selection: EditionSelection = .sourceList,
        replacement: SubscriptionReplacementRule = .off
    ) -> PortableSubscriptionRule {
        PortableSubscriptionRule(
            pluginId: plugin, mediaKind: .manga, canonicalMediaId: id, mode: mode, windowSize: window,
            perRunPositionCap: cap, selection: storage(selection), replacementRule: replacement
        )
    }

    private static func backup(
        _ rules: [PortableSubscriptionRule],
        represented: Bool = true,
        items: [LibraryItem] = []
    ) -> ImportedBackup {
        var capabilities: [BackupCapabilityRecord] = []
        if represented {
            capabilities.append(BackupCapabilityRecord(
                component: .automaticDownloadRules,
                representation: rules.isEmpty ? .representedEmpty : .representedNonempty
            ))
        }
        if !items.isEmpty {
            capabilities.append(BackupCapabilityRecord(component: .libraryCore, representation: .representedNonempty))
        }
        return ImportedBackup(
            metadata: BackupMetadataRecord(formatVersion: 1, createdAt: date),
            capabilities: capabilities,
            items: items,
            automaticDownloadRules: rules
        )
    }

    private static func operation(_ pool: DatabasePool) -> ComponentAwareBackupRestoreOperation {
        ComponentAwareBackupRestoreOperation(
            dbPool: pool,
            standardApplicationDomain: "test.app",
            operationIdProvider: { "generated" },
            now: { date }
        )
    }

    private static func item(_ id: String, pluginId: String = plugin) -> LibraryItem {
        LibraryItem(
            id: id, title: "Series", coverUrl: nil, pluginId: pluginId, isAnime: false, pluginType: .manga,
            rawPayload: Data(), anilistId: nil
        )
    }

    private static func outcome(_ report: BackupRestoreReport) throws -> ComponentOutcome {
        try #require(report.outcomes.first { $0.component == .automaticDownloadRules })
    }

    /// A rule written around the store, as a previous installation of this device left it.
    private static func seedRule(
        _ db: Database,
        _ media: MediaIdentity,
        state: SubscriptionState = .enabled,
        configuration: SubscriptionConfiguration = SubscriptionConfiguration(),
        incarnation: Int64 = 3,
        generation: Int64 = 4,
        ticket: Int64 = 9
    ) throws -> SeriesSubscriptionRecord {
        var record = SeriesSubscriptionRecord(
            id: UUID().uuidString, pluginId: media.pluginId, mediaKind: media.mediaKind,
            canonicalMediaId: media.canonicalMediaId, state: state, pauseReason: state == .paused ? .user : nil,
            mode: .newReleases, windowSize: nil, perRunPositionCap: 5, selection: storage(.sourceList),
            replacementRule: .off, incarnation: incarnation, configGeneration: generation, nextCheckTicket: ticket,
            lastAttemptAt: date, lastAttemptOutcome: .advanced, lastSuccessAt: date, createdAt: date, updatedAt: date
        )
        record.apply(configuration, selection: storage(configuration.selection))
        try record.insert(db)
        return record
    }

    private static func rule(_ pool: DatabasePool, _ media: MediaIdentity) throws -> SeriesSubscriptionRecord? {
        try pool.read { db in try SeriesSubscriptionRecord.forMedia(media).fetchOne(db) }
    }

    private static func count(_ pool: DatabasePool, _ table: String) throws -> Int {
        try pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    private static let evidenceTables = [
        "subscriptionBaseline", "subscriptionSeenKey", "subscriptionEvent", "downloadJobOwner", "downloadJob",
        "downloadBatch"
    ]

    private static func insertPreferenceCatalog(into pool: DatabasePool) throws {
        try pool.write { db in
            for entry in AppPreferenceCatalogEntry.allCases {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO appPreference (key, value) VALUES (?, ?)",
                    arguments: [entry.rawValue, entry.canonicalDefaultJSON]
                )
            }
        }
    }

    private static func export(from database: TestDatabase, to name: String) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticDownloadRulesBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try await BackupExportOperation(
            dbPool: database.dbPool, sourceDatabaseURL: database.databaseURL, standardApplicationDomain: "test.app",
            readinessGate: {}
        ).export(to: url)
        return url
    }

    private static func removeExport(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - B1, B2: export

    @Test func b1_exportKeepsEnabledAndPausedRulesAsSanitizedPausedRulesAndNothingOfTheirEvidence() async throws {
        let f = try await Fixture()
        let paused = Self.media("series-2")
        let disabled = Self.media("series-3")
        let enabledId = try await f.enable(SubscriptionConfiguration(
            perRunPositionCap: 3, replacementRule: .sameKeyReliableRevision
        )).id
        try await f.check(Fixture.numbered(1...2))
        try await f.check(Fixture.numbered(1...4))
        _ = try await f.store.enqueueBatch(
            OfflineStoreFixture.batchRequest(chapterKeys: ["m1"], preset: .next5), sourceEpoch: OfflineStoreFixture.epoch
        )
        let pausedId = try await f.enable(SubscriptionConfiguration(
            mode: .maintainNextUnread, windowSize: 7, perRunPositionCap: 2, selection: .allUploads
        ), media: paused).id
        _ = try await f.store.pauseSubscription(id: pausedId)
        _ = try await f.enable(media: disabled).id
        _ = try await f.store.disableSubscription(id: try #require(try await f.store.subscription(for: disabled)).id)
        #expect(try Self.count(f.pool, "subscriptionBaseline") == 1)
        #expect(try Self.count(f.pool, "downloadJobOwner") >= 2)
        try Self.insertPreferenceCatalog(into: f.pool)

        let url = try await Self.export(from: f.base.database, to: "rules.itobackup")
        defer { Self.removeExport(url) }

        let exported = try DatabaseQueue(path: url.path)
        defer { try? exported.close() }
        try await exported.read { db in
            let rows = try SeriesSubscriptionRecord.order(Column("canonicalMediaId")).fetchAll(db)
            #expect(rows.map(\.canonicalMediaId) == ["series-1", "series-2"])
            #expect(rows.allSatisfy {
                $0.state == .paused && $0.pauseReason == .restored && $0.incarnation == 1 && $0.configGeneration == 1
                    && $0.nextCheckTicket == 1 && $0.lastAttemptAt == nil && $0.lastAttemptOutcome == nil
                    && $0.lastSuccessAt == nil
            })
            // The choices survive; the identity of the rule does not matter.
            #expect(rows[0].id == enabledId)
            #expect(rows[0].mode == .newReleases && rows[0].windowSize == nil && rows[0].perRunPositionCap == 3)
            #expect(rows[0].decodedSelection == .sourceList && rows[0].replacementRule == .sameKeyReliableRevision)
            #expect(rows[1].mode == .maintainNextUnread && rows[1].windowSize == 7 && rows[1].perRunPositionCap == 2)
            #expect(rows[1].decodedSelection == .allUploads && rows[1].replacementRule == .off)
            for table in Self.evidenceTables {
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
            }
            let capability = try BackupCapabilityRecord.fetchOne(db, key: BackupComponent.automaticDownloadRules.rawValue)
            #expect(capability?.representation == .representedNonempty)
        }
        let parsed = try await ItoNativeImporter().parse(url: url)
        #expect(parsed.representation(of: .automaticDownloadRules) == .representedNonempty)
        #expect(parsed.automaticDownloadRules.map(\.canonicalMediaId) == ["series-1", "series-2"])
        // The source database still has all three rules and their evidence.
        #expect(try Self.count(f.pool, "seriesSubscription") == 3)
        #expect(try Self.count(f.pool, "subscriptionBaseline") == 1)
    }

    @Test func b1_withoutRulesOrOnlyDisabledRulesTheComponentIsRepresentedEmpty() async throws {
        let f = try await Fixture()
        _ = try await f.enable().id
        _ = try await f.store.disableSubscription(id: try #require(try await f.store.subscription(for: f.media)).id)
        try Self.insertPreferenceCatalog(into: f.pool)

        let url = try await Self.export(from: f.base.database, to: "empty.itobackup")
        defer { Self.removeExport(url) }

        let exported = try DatabaseQueue(path: url.path)
        defer { try? exported.close() }
        try await exported.read { db in
            #expect(try SeriesSubscriptionRecord.fetchCount(db) == 0)
            let capability = try BackupCapabilityRecord.fetchOne(db, key: BackupComponent.automaticDownloadRules.rawValue)
            #expect(capability?.representation == .representedEmpty)
        }
    }

    @Test func b2_aRuleWithAnUnreadableSelectionFailsTheExportAndPublishesNothing() async throws {
        let f = try await Fixture()
        _ = try await f.enable().id
        try Self.insertPreferenceCatalog(into: f.pool)
        try await f.write { db in
            try db.execute(sql: "UPDATE seriesSubscription SET selection = ?", arguments: [Data("not a selection".utf8)])
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomaticDownloadRulesBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("corrupt.itobackup")

        await #expect(throws: BackupExportOperation.ValidationError.invalidAutomaticDownloadRules) {
            try await BackupExportOperation(
                dbPool: f.pool, sourceDatabaseURL: f.base.database.databaseURL, standardApplicationDomain: "test.app",
                readinessGate: {}
            ).export(to: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - B3: import

    private final class BackupFile {
        let url: URL
        private let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AutomaticDownloadRulesImport-\(UUID().uuidString)", isDirectory: true)
            url = directory.appendingPathComponent("fixture.itobackup")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        /// A backup with its envelope tables, and optionally the rule table and a capability row for it.
        func create(capability: String?, ruleTable: Bool, _ body: (Database) throws -> Void = { _ in }) throws {
            let queue = try DatabaseQueue(path: url.path)
            try queue.write { db in
                try db.execute(sql: """
                    CREATE TABLE backupMetadata (id INTEGER, formatVersion INTEGER, createdAt DATETIME);
                    CREATE TABLE backupCapability (component TEXT, representation TEXT);
                    INSERT INTO backupMetadata VALUES (1, 1, 0);
                    """)
                if let capability {
                    try db.execute(
                        sql: "INSERT INTO backupCapability VALUES ('automaticDownloadRules', ?)", arguments: [capability]
                    )
                }
                if ruleTable {
                    try db.execute(sql: """
                        CREATE TABLE seriesSubscription (
                          pluginId TEXT, mediaKind TEXT, canonicalMediaId TEXT, mode TEXT, windowSize INTEGER,
                          perRunPositionCap INTEGER, selection BLOB, replacementRule TEXT
                        )
                        """)
                }
                try body(db)
            }
            try queue.close()
        }

        static func insertRule(
            _ db: Database,
            id: String = "series-1",
            mediaKind: String = "manga",
            mode: String = "newReleases",
            window: Int? = nil,
            cap: Int = 5,
            selection: DatabaseValueConvertible = AutomaticDownloadRulesBackupTests.storage(.sourceList),
            replacement: String = "off"
        ) throws {
            try db.execute(
                sql: "INSERT INTO seriesSubscription VALUES ('plugin.test', ?, ?, ?, ?, ?, ?, ?)",
                arguments: [mediaKind, id, mode, window, cap, selection, replacement]
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func b3_aBackupFromBeforeTheComponentIsUnrepresentedAndCarriesNoRules() async throws {
        let file = try BackupFile()
        defer { file.cleanup() }
        try file.create(capability: nil, ruleTable: false)

        let backup = try await ItoNativeImporter().parse(url: file.url)

        #expect(backup.representation(of: .automaticDownloadRules) == .unrepresented)
        #expect(backup.automaticDownloadRules.isEmpty)
    }

    @Test func b3_aBackupWithAnEmptyRuleTableAndNoCapabilityIsStillUnrepresented() async throws {
        let file = try BackupFile()
        defer { file.cleanup() }
        try file.create(capability: nil, ruleTable: true)

        let backup = try await ItoNativeImporter().parse(url: file.url)

        #expect(backup.representation(of: .automaticDownloadRules) == .unrepresented)
    }

    @Test func b3_ruleRowsWithoutARepresentingCapabilityAreRejectedWithoutLoadingThem() async throws {
        let file = try BackupFile()
        defer { file.cleanup() }
        try file.create(capability: nil, ruleTable: true) { db in try BackupFile.insertRule(db) }

        await #expect(throws: BackupPreflightError.rejected(
            .invalidCapabilityMetadata(component: .automaticDownloadRules, code: "unrepresentedContainsRows")
        )) {
            _ = try await ItoNativeImporter().parse(url: file.url)
        }
    }

    @Test func b3_aValidBackupYieldsItsRulesInIdentityOrderWithTheirChoices() async throws {
        let file = try BackupFile()
        defer { file.cleanup() }
        try file.create(capability: "representedNonempty", ruleTable: true) { db in
            try BackupFile.insertRule(db, id: "b", mode: "maintainNextUnread", window: 12, cap: 20, replacement: "sameKeyReliableRevision")
            try BackupFile.insertRule(db, id: "a", selection: Self.storage(.allUploads))
            // A choice this build cannot read is carried, not rejected: restore skips that rule.
            try BackupFile.insertRule(db, id: "c", selection: Data("future-format".utf8))
        }

        let backup = try await ItoNativeImporter().parse(url: file.url)

        let rules = backup.automaticDownloadRules
        #expect(rules.map(\.canonicalMediaId) == ["a", "b", "c"])
        #expect(rules[0].configuration == SubscriptionConfiguration(selection: .allUploads))
        #expect(rules[1].configuration == SubscriptionConfiguration(
            mode: .maintainNextUnread, windowSize: 12, perRunPositionCap: 20, replacementRule: .sameKeyReliableRevision
        ))
        #expect(rules[2].configuration == nil)
    }

    @Test(arguments: [
        ("future", nil, 5, "manga"),
        ("maintainNextUnread", nil, 5, "manga"),
        ("maintainNextUnread", 101, 5, "manga"),
        ("maintainNextUnread", 0, 5, "manga"),
        ("newReleases", 5, 5, "manga"),
        ("newReleases", nil, 0, "manga"),
        ("newReleases", nil, 21, "manga"),
        ("newReleases", nil, 5, "anime"),
        ("newReleases", nil, 5, "audio")
    ] as [(String, Int?, Int, String)])
    func b3_aRuleOutsideItsClosedListsOrRangesIsRejected(mode: String, window: Int?, cap: Int, kind: String) async throws {
        let file = try BackupFile()
        defer { file.cleanup() }
        try file.create(capability: "representedNonempty", ruleTable: true) { db in
            try BackupFile.insertRule(db, mediaKind: kind, mode: mode, window: window, cap: cap)
        }

        await #expect(throws: BackupPreflightError.rejected(
            .invalidCapabilityMetadata(component: .automaticDownloadRules, code: "invalidRule")
        )) {
            _ = try await ItoNativeImporter().parse(url: file.url)
        }
    }

    @Test func b3_anInvalidReplacementRuleATextSelectionOrADuplicateIdentityIsRejected() async throws {
        let cases: [(String, (Database) throws -> Void)] = [
            ("replacement", { db in try BackupFile.insertRule(db, replacement: "always") }),
            ("textSelection", { db in try BackupFile.insertRule(db, selection: "text") }),
            ("nullSelection", { db in try BackupFile.insertRule(db, selection: DatabaseValue.null) }),
            ("oversizedSelection", { db in
                try BackupFile.insertRule(db, selection: Data(repeating: 0x20, count: PortableSubscriptionRule.maximumSelectionByteCount + 1))
            }),
            ("duplicate", { db in
                try BackupFile.insertRule(db, id: "dup")
                try BackupFile.insertRule(db, id: "dup", mode: "newAndFillUnread")
            }),
            ("emptyIdentity", { db in try BackupFile.insertRule(db, id: "") })
        ]
        for (name, body) in cases {
            let file = try BackupFile()
            defer { file.cleanup() }
            try file.create(capability: "representedNonempty", ruleTable: true, body)
            await #expect(throws: BackupPreflightError.rejected(
                .invalidCapabilityMetadata(component: .automaticDownloadRules, code: "invalidRule")
            ), "\(name)") {
                _ = try await ItoNativeImporter().parse(url: file.url)
            }
        }
    }

    @Test func b3_moreRulesThanTheBoundAreRejectedBeforeAnyRowLoads() async throws {
        let file = try BackupFile()
        defer { file.cleanup() }
        try file.create(capability: "representedNonempty", ruleTable: true) { db in
            try db.execute(sql: """
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(PortableSubscriptionRule.maximumCount + 1))
                INSERT INTO seriesSubscription
                SELECT 'plugin.test', 'manga', 'series-' || i, 'newReleases', NULL, 5, X'7B7D', 'off' FROM n
                """)
        }

        await #expect(throws: BackupPreflightError.rejected(
            .invalidCapabilityMetadata(component: .automaticDownloadRules, code: "invalidRule")
        )) {
            _ = try await ItoNativeImporter().parse(url: file.url)
        }
    }

    @Test func b3_aRepresentedNonemptyCapabilityWithoutTheTableIsRejected() async throws {
        let file = try BackupFile()
        defer { file.cleanup() }
        try file.create(capability: "representedNonempty", ruleTable: false)

        await #expect(throws: BackupPreflightError.rejected(
            .invalidCapabilityMetadata(component: .automaticDownloadRules, code: "representedNonemptyHasNoRows")
        )) {
            _ = try await ItoNativeImporter().parse(url: file.url)
        }
    }

    @Test func b3_restorePreflightRejectsRulesWithoutRepresentationInvalidRulesAndRulesThatCollideAfterRemapping() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let operation = Self.operation(database.dbPool)

        await #expect(throws: BackupPreflightError.rejected(
            .invalidCapabilityMetadata(component: .automaticDownloadRules, code: "unrepresentedContainsRows")
        )) {
            _ = try await operation.restore(Self.backup([Self.portable("a")], represented: false), mode: .merge)
        }
        await #expect(throws: BackupPreflightError.rejected(
            .invalidComponentData(component: .automaticDownloadRules, code: "invalidRule")
        )) {
            _ = try await operation.restore(Self.backup([Self.portable("a", mode: .maintainNextUnread, window: nil)]), mode: .merge)
        }
        await #expect(throws: BackupPreflightError.rejected(
            .invalidComponentData(component: .automaticDownloadRules, code: "invalidRule")
        )) {
            _ = try await operation.restore(Self.backup([Self.portable("a"), Self.portable("a", cap: 2)]), mode: .merge)
        }
        #expect(try Self.count(database.dbPool, "seriesSubscription") == 0)
    }

    // MARK: - B4: merge

    @Test func b4_mergeInsertsReplacesInPlaceKeepsLocalSkipsAndCountsEachOutcome() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let fresh = Self.media("fresh")
        let differing = Self.media("differing")
        let identical = Self.media("identical")
        let disabled = Self.media("disabled")
        let absent = Self.media("absent")
        let unknown = Self.media("unknown")
        let localDisabled = try await database.dbPool.write { db -> SeriesSubscriptionRecord in
            for id in ["fresh", "differing", "identical", "disabled", "unknown"] { try Self.item(id).insert(db) }
            _ = try Self.seedRule(db, differing, state: .enabled)
            _ = try Self.seedRule(db, identical, state: .paused)
            _ = try Self.seedRule(db, unknown, state: .disabled)
            return try Self.seedRule(db, disabled, state: .disabled)
        }
        let localDifferingBefore = try #require(try Self.rule(database.dbPool, differing))
        let backup = Self.backup([
            Self.portable("fresh", mode: .maintainNextUnread, window: 9, cap: 2, selection: .allUploads),
            Self.portable("differing", cap: 1),
            Self.portable("identical"),
            Self.portable("disabled", mode: .newAndFillUnread, cap: 3, selection: .allUploads, replacement: .sameKeyReliableRevision),
            Self.portable("absent"),
            PortableSubscriptionRule(
                pluginId: Self.plugin, mediaKind: .manga, canonicalMediaId: "unknown", mode: .newReleases, windowSize: nil,
                perRunPositionCap: 5, selection: Data("future-format".utf8), replacementRule: .off
            )
        ])

        let report = try await Self.operation(database.dbPool).restore(backup, mode: .merge)

        let outcome = try Self.outcome(report)
        #expect(outcome.inserted == 1 && outcome.replaced == 1 && outcome.preservedLocal == 1)
        #expect(outcome.skipped == 3)
        let inserted = try #require(try Self.rule(database.dbPool, fresh))
        #expect(inserted.state == .paused && inserted.pauseReason == .restored)
        #expect(inserted.incarnation == 1 && inserted.configGeneration == 1 && inserted.nextCheckTicket == 1)
        #expect(inserted.createdAt == Self.date && inserted.updatedAt == Self.date)
        #expect(inserted.lastAttemptAt == nil && inserted.lastAttemptOutcome == nil && inserted.lastSuccessAt == nil)
        #expect(inserted.mode == .maintainNextUnread && inserted.windowSize == 9 && inserted.perRunPositionCap == 2)
        #expect(inserted.decodedSelection == .allUploads)
        #expect(UUID(uuidString: inserted.id) != nil && inserted.id != localDisabled.id)
        // A local enabled or paused rule is not touched, whether the backup agrees or not.
        #expect(try Self.rule(database.dbPool, differing) == localDifferingBefore)
        let replaced = try #require(try Self.rule(database.dbPool, disabled))
        #expect(replaced.id == localDisabled.id)
        #expect(replaced.state == .paused && replaced.pauseReason == .restored)
        #expect(replaced.incarnation == localDisabled.incarnation + 1)
        #expect(replaced.configGeneration == localDisabled.configGeneration + 1)
        #expect(replaced.nextCheckTicket == localDisabled.nextCheckTicket)
        #expect(replaced.lastAttemptAt == nil && replaced.lastSuccessAt == nil && replaced.updatedAt == Self.date)
        #expect(replaced.mode == .newAndFillUnread && replaced.perRunPositionCap == 3)
        #expect(replaced.replacementRule == .sameKeyReliableRevision && replaced.decodedSelection == .allUploads)
        #expect(try Self.rule(database.dbPool, absent) == nil)
        let untouchedUnknown = try #require(try Self.rule(database.dbPool, unknown))
        #expect(untouchedUnknown.state == .disabled)
    }

    @Test func b4_aBackupFromBeforeTheComponentLeavesLocalRulesUntouchedInBothModes() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let local = Self.media("local")
        try await database.dbPool.write { db in
            try Self.item("local").insert(db)
            _ = try Self.seedRule(db, local)
        }
        let before = try #require(try Self.rule(database.dbPool, local))

        for mode in [BackupRestoreMode.merge, .wipe] {
            let report = try await Self.operation(database.dbPool).restore(Self.backup([], represented: false), mode: mode)
            #expect(!report.representedComponents.contains(.automaticDownloadRules))
            #expect(try Self.rule(database.dbPool, local) == before)
        }
    }

    @Test func b4_aRepresentedEmptyBackupDoesNotTouchLocalRulesInAMerge() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let local = Self.media("local")
        try await database.dbPool.write { db in
            try Self.item("local").insert(db)
            _ = try Self.seedRule(db, local)
        }
        let before = try #require(try Self.rule(database.dbPool, local))

        _ = try await Self.operation(database.dbPool).restore(Self.backup([]), mode: .merge)

        #expect(try Self.rule(database.dbPool, local) == before)
    }

    // MARK: - B5: wipe

    @Test func b5_wipeDeletesLocalRulesTheBackupDoesNotCarryAndReplacesTheOnesItDoesInPlace() async throws {
        let f = try await Fixture()
        let second = Self.media("series-2")
        let idA = try await f.enable().id
        try await f.check(Fixture.numbered(1...2))
        try await f.check(Fixture.numbered(1...4))
        // c3 is asked for by the rule and by a person; c4 by the rule alone.
        _ = try await f.store.enqueueBatch(
            OfflineStoreFixture.batchRequest(chapterKeys: ["c3"], preset: .next5), sourceEpoch: OfflineStoreFixture.epoch
        )
        let idB = try await f.enable(media: second).id
        for chapters in [Fixture.numbered(1...2), Fixture.numbered(1...3)] {
            let ticket = try await f.begin(media: second)
            let observation = try Fixture.observation(chapters, media: second, epoch: ticket.sourceEpoch)
            _ = try await f.store.commitSubscriptionObservation(ticket, observation, limits: Fixture.roomy)
        }
        let jobsBefore = try await f.jobs()
        #expect(jobsBefore.count == 3)
        let ruleBefore = try #require(try await f.store.subscription(for: second))

        let report = try await Self.operation(f.pool).restore(
            Self.backup([Self.portable("series-2", cap: 2, selection: .allUploads)]), mode: .wipe
        )

        let outcome = try Self.outcome(report)
        #expect(outcome.replaced == 2 && outcome.inserted == 0 && outcome.skipped == 0)
        // The rule the backup does not carry is gone, and with it the job only it asked for.
        #expect(try await f.store.subscription(for: f.media) == nil)
        #expect(try await f.pool.read { db in try SeriesSubscriptionRecord.fetchOne(db, key: idA) } == nil)
        let remaining = try await f.jobs()
        #expect(remaining.map(\.chapterKey) == ["c3"])
        #expect(remaining.first?.canonicalMediaId == "series-1")
        let owners = try await f.owners(of: try #require(remaining.first).id)
        #expect(owners.map(\.ownerKind) == [.manual])
        // The rule it carries is replaced in place: no evidence, a new incarnation and generation.
        let replaced = try #require(try await f.store.subscription(for: second))
        #expect(replaced.id == idB)
        #expect(replaced.state == .paused && replaced.pauseReason == .restored)
        #expect(replaced.incarnation == ruleBefore.incarnation + 1 && replaced.configGeneration == ruleBefore.configGeneration + 1)
        #expect(replaced.perRunPositionCap == 2 && replaced.decodedSelection == .allUploads)
        #expect(try await f.baseline() == nil)
        #expect(try await f.seenCount() == 0)
        #expect(try await f.events().allSatisfy { !$0.decision.isOpen })
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func b5_aWipeOfARepresentedEmptyComponentDeletesEveryLocalRule() async throws {
        let f = try await Fixture()
        _ = try await f.enable().id
        try await f.check(Fixture.numbered(1...2))
        try await f.check(Fixture.numbered(1...3))
        #expect(try await f.jobs().count == 1)

        let report = try await Self.operation(f.pool).restore(Self.backup([]), mode: .wipe)

        #expect(try Self.outcome(report).replaced == 1)
        #expect(try Self.count(f.pool, "seriesSubscription") == 0)
        #expect(try await f.jobs().isEmpty)
        try await f.expectEveryJobHasAnOwner()
    }

    // MARK: - B6: remapped identity

    @Test func b6_aRuleFollowsTheLibraryItemItsBackupSeriesWasMappedTo() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        // The device holds the series under its `pluginId_key` id; the backup names it by the bare key.
        try await database.dbPool.write { db in try Self.item("plugin.test_series-1").insert(db) }
        let backup = Self.backup([Self.portable("series-1")], items: [Self.item("series-1")])

        let report = try await Self.operation(database.dbPool).restore(backup, mode: .merge)

        #expect(try Self.outcome(report).inserted == 1)
        let restored = try #require(try Self.rule(database.dbPool, Self.media("series-1")))
        #expect(restored.state == .paused && restored.pauseReason == .restored)
        #expect(try Self.count(database.dbPool, "libraryItem") == 1)
    }

    @Test func b6_aRuleForASeriesTheBackupLibraryLacksIsSkippedInAWipe() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let backup = Self.backup(
            [Self.portable("kept"), Self.portable("missing")],
            items: [Self.item("kept")]
        )

        let report = try await Self.operation(database.dbPool).restore(backup, mode: .wipe)

        let outcome = try Self.outcome(report)
        #expect(outcome.inserted == 1 && outcome.skipped == 1)
        #expect(try Self.rule(database.dbPool, Self.media("kept")) != nil)
        #expect(try Self.rule(database.dbPool, Self.media("missing")) == nil)
    }

    /// The rule restore runs before the final release, inside the one transaction: the rule of a series the wipe
    /// removed does not survive the backup naming it (its restored twin is skipped, its local rule is released), a
    /// local rule the backup does not carry is deleted with its Library item, and no job is left without an owner.
    @Test func b6_aWipeReleasesEveryRuleWhoseSeriesItRemovedWhetherOrNotTheBackupCarriesARuleForIt() async throws {
        let f = try await Fixture()
        let second = Self.media("series-2")
        let kept = Self.media("kept")
        try await f.enable()
        try await f.check(Fixture.numbered(1...2))
        try await f.check(Fixture.numbered(1...4))
        try await f.enable(media: second)
        for chapters in [Fixture.numbered(1...2), Fixture.numbered(1...3)] {
            let ticket = try await f.begin(media: second)
            let observation = try Fixture.observation(chapters, media: second, epoch: ticket.sourceEpoch)
            _ = try await f.store.commitSubscriptionObservation(ticket, observation, limits: Fixture.roomy)
        }
        #expect(try await f.jobs().count == 3)
        // The backup's Library holds only `kept`; it carries rules for `kept`, for `series-1` (removed by the wipe)
        // and for `ghost` (never in any Library). `series-2`'s local rule is not carried at all.
        let backup = Self.backup(
            [Self.portable("kept"), Self.portable("series-1"), Self.portable("ghost")],
            items: [Self.item("kept")]
        )

        let report = try await Self.operation(f.pool).restore(backup, mode: .wipe)

        let outcome = try Self.outcome(report)
        #expect(outcome.inserted == 1 && outcome.skipped == 2)
        let rules = try await f.pool.read { db in try SeriesSubscriptionRecord.fetchAll(db) }
        #expect(rules.map(\.media) == [kept])
        #expect(rules.first?.state == .paused && rules.first?.pauseReason == .restored)
        #expect(try await f.pool.read { db in try LibraryItem.fetchAll(db).map(\.id) } == ["kept"])
        #expect(try await f.jobs().isEmpty)
        #expect(try Self.count(f.pool, "downloadJobOwner") == 0)
        try await f.expectEveryJobHasAnOwner()
    }

    // MARK: - B7: nothing else is touched

    private static func snapshot(_ pool: DatabasePool, _ tables: [String]) throws -> [String: [String]] {
        try pool.read { db in
            var result: [String: [String]] = [:]
            for table in tables {
                result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map(\.description)
            }
            return result
        }
    }

    @Test(arguments: [BackupRestoreMode.merge, .wipe])
    func b7_restoreCreatesNoEvidenceOwnersOrJobsAndLeavesReadStateHistoryAndBadgesAlone(mode: BackupRestoreMode) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let local = Self.media("local")
        try await database.dbPool.write { db in
            try Self.item("local").insert(db)
            try Self.item("other").insert(db)
            _ = try Self.seedRule(db, local, state: .disabled)
            try MediaReadProgressRecord(
                pluginId: Self.plugin, canonicalMediaId: "local", mediaKind: .manga, lastReadChapterKey: "c9",
                updatedAt: Self.date, provenance: .runtime, lastReadPosition: 3, readerViewer: nil
            ).insert(db)
            try ReadProgressKeyRecord(
                pluginId: Self.plugin, canonicalMediaId: "local", mediaKind: .manga, chapterKey: "c1",
                markedAt: Self.date, provenance: .runtime
            ).insert(db)
            try UpdateBadgeRecord(
                pluginId: Self.plugin, canonicalMediaId: "local", mediaKind: .manga, count: 4, updatedAt: Self.date,
                provenance: .runtime
            ).insert(db)
            try ReadingHistoryRecord(
                id: "history", libraryItemId: "local", mediaKey: "local", title: "Series", coverUrl: nil,
                pluginId: Self.plugin, mediaKind: .manga, chapterKey: "c1", chapterTitle: nil, readAt: Self.date
            ).insert(db)
        }
        let untouched = ["libraryItem", "mediaReadProgress", "readProgressKey", "readProgressNumber", "updateBadge", "readingHistory"]
        let before = try Self.snapshot(database.dbPool, untouched)

        let report = try await Self.operation(database.dbPool).restore(
            Self.backup([Self.portable("local"), Self.portable("other")]), mode: mode
        )

        #expect(try Self.outcome(report).inserted + Self.outcome(report).replaced == 2)
        #expect(try Self.snapshot(database.dbPool, untouched) == before)
        for table in Self.evidenceTables {
            #expect(try Self.count(database.dbPool, table) == 0, "\(table)")
        }
    }

    // MARK: - B8: round trip

    @Test func b8_aRoundTripRestoresEveryChoicePausedAndTheFirstCheckAfterReviewIsABaseline() async throws {
        let source = try await Fixture()
        let configurations: [(String, SubscriptionConfiguration)] = [
            ("series-1", SubscriptionConfiguration(perRunPositionCap: 2, selection: .allUploads)),
            ("series-2", SubscriptionConfiguration(mode: .newAndFillUnread, perRunPositionCap: 20, replacementRule: .sameKeyReliableRevision)),
            ("series-3", SubscriptionConfiguration(mode: .maintainNextUnread, windowSize: 11, perRunPositionCap: 1))
        ]
        for (id, configuration) in configurations {
            _ = try await source.enable(configuration, media: Self.media(id))
        }
        try await source.check(Fixture.numbered(1...3))
        try Self.insertPreferenceCatalog(into: source.pool)
        let url = try await Self.export(from: source.base.database, to: "round-trip.itobackup")
        defer { Self.removeExport(url) }
        let backup = try await ItoNativeImporter().parse(url: url)
        let destination = try await Fixture()

        _ = try await Self.operation(destination.pool).restore(backup, mode: .wipe)

        for (id, configuration) in configurations {
            let restored = try #require(try await destination.store.subscription(for: Self.media(id)))
            #expect(PortableSubscriptionRule(record: restored).configuration == configuration)
            #expect(restored.state == .paused && restored.pauseReason == .restored)
        }
        for table in Self.evidenceTables {
            #expect(try Self.count(destination.pool, table) == 0, "\(table)")
        }
        // Only the store's reviewed resume enables a restored rule again: without the review it is refused and the
        // rule stays paused; with the current epoch, the Library item and the reviewed rule it starts over. It has no
        // baseline, so its first check only establishes one and creates no event or job.
        let restoredRule = try #require(try await destination.store.subscription(for: Self.media("series-1")))
        let refused = try await destination.store.resumeSubscription(SubscriptionResumeRequest(
            subscriptionId: restoredRule.id, expectedConfigGeneration: restoredRule.configGeneration,
            reviewedSourceEpoch: nil, configuration: nil
        ))
        #expect(refused == .reviewRequired)
        let stillPaused = try #require(try await destination.store.subscription(for: Self.media("series-1")))
        #expect(stillPaused.state == .paused && stillPaused.pauseReason == .restored)
        #expect(stillPaused.configGeneration == restoredRule.configGeneration)
        let resumed = try await destination.store.resumeSubscription(SubscriptionResumeRequest(
            subscriptionId: restoredRule.id, expectedConfigGeneration: restoredRule.configGeneration,
            reviewedSourceEpoch: OfflineStoreFixture.epoch, configuration: configurations[0].1
        ))
        #expect(resumed == .resumed(configGeneration: restoredRule.configGeneration + 1))
        let enabled = try await destination.store.subscription(for: Self.media("series-1"))
        #expect(enabled?.state == .enabled && enabled?.pauseReason == nil)
        #expect(try await destination.store.subscription(for: Self.media("series-2"))?.state == .paused)
        let outcome = try await destination.check(Fixture.numbered(1...5))
        #expect(outcome.outcome == .baselineEstablished)
        #expect(outcome.createdEventIds.isEmpty && outcome.queuedJobs == 0)
        #expect(try await destination.events().isEmpty)
        #expect(try await destination.jobs().isEmpty)
        try await destination.expectEveryJobHasAnOwner()
    }

    // MARK: - B9: foreign database

    @Test func b9_theForeignDatabaseQuarantineKeepsRestoredRulesPausedAsANewIncarnationWithoutOwners() async throws {
        let f = try await Fixture()
        _ = try await Self.operation(f.pool).restore(
            Self.backup([Self.portable("series-1")], items: [Self.item("series-1")]), mode: .wipe
        )
        let restored = try await f.subscription()
        #expect(restored.incarnation == 1)

        // The store's marker names another installation: the restored database counts as copied here.
        try f.base.fileSystem.writeFile(Data("another-installation".utf8), to: f.base.storeIdentifierURL)
        guard case .completed = await f.base.makeStore().reconcile() else {
            Issue.record("reconciliation must complete")
            return
        }

        let quarantined = try await f.subscription()
        #expect(quarantined.id == restored.id)
        #expect(quarantined.state == .paused && quarantined.pauseReason == .restored)
        #expect(quarantined.incarnation == restored.incarnation + 1)
        #expect(try Self.count(f.pool, "downloadJobOwner") == 0)
        #expect(PortableSubscriptionRule(record: quarantined).configuration == PortableSubscriptionRule(record: restored).configuration)
        try await f.expectEveryJobHasAnOwner()
    }

    // MARK: - B10: migration

    @Test func b10_v28KeepsEveryCapabilityRowAndItsCheckListMatchesTheEnum() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(queue, upTo: "v27")
        let older = BackupComponent.allCases.filter { $0 != .automaticDownloadRules }
        var before: [String: String] = [:]
        try queue.write { db in
            for (index, component) in older.enumerated() {
                let representation: BackupRepresentation = index.isMultiple(of: 2) ? .representedNonempty : .representedEmpty
                try BackupCapabilityRecord(component: component, representation: representation).insert(db)
                before[component.rawValue] = representation.rawValue
            }
            // The v27 constraint does not know the new component yet.
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO backupCapability VALUES ('automaticDownloadRules', 'representedEmpty')")
            }
        }

        try AppDatabase.makeMigrator().migrate(queue)

        try queue.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT component, representation FROM backupCapability")
            let after = Dictionary(uniqueKeysWithValues: rows.map { ($0["component"] as String, $0["representation"] as String) })
            #expect(after == before)
            #expect(before.count == older.count)
            try BackupCapabilityRecord(component: .automaticDownloadRules, representation: .representedNonempty).insert(db)
            for bad in ["futureComponent", "unrepresented"] {
                #expect(throws: DatabaseError.self) {
                    try db.execute(sql: "INSERT INTO backupCapability VALUES (?, 'representedEmpty')", arguments: [bad])
                }
            }
            #expect(throws: DatabaseError.self) {
                try db.execute(sql: "INSERT INTO backupCapability VALUES (NULL, 'representedEmpty')")
            }
            let definition = try #require(try String.fetchOne(
                db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'backupCapability'"
            ))
            let listStart = try #require(definition.range(of: "component IN ("))
            let list = definition[listStart.upperBound...].prefix { $0 != ")" }
            let names = Set(
                list.split(separator: "'", omittingEmptySubsequences: false).enumerated()
                    .filter { !$0.offset.isMultiple(of: 2) }.map { String($0.element) }
            )
            #expect(names == Set(BackupComponent.allCases.map(\.rawValue)))
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    // MARK: - B11: report

    @Test @MainActor func b11_theRestoreReportNamesTheComponentWithALocalizedLabel() {
        #expect(BackupComponent.automaticDownloadRules.displayName == "Automatic download rules")
    }
}
