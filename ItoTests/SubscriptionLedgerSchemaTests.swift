import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// The v27 migration and the schema it creates. Every enum is compared with the closed list of the CHECK it mirrors, so
/// a value the database refuses cannot be built and a value it accepts cannot be forgotten.
struct SubscriptionLedgerSchemaTests {
    private static let batchOne = "11111111-1111-1111-1111-111111111111"
    private static let batchTwo = "22222222-2222-2222-2222-222222222222"
    private static let jobOne = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private static let jobTwo = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    private static let jobThree = "cccccccc-cccc-cccc-cccc-cccccccccccc"
    private static let customPreset = "dddddddd-dddd-dddd-dddd-dddddddddddd"

    /// A database at schema v26: two batches (one custom with its window provenance), three jobs of them, one of which
    /// has a v24 replacement intent.
    private func databaseAtV26() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(queue, upTo: "v26")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO downloadBatch
                  (id, pluginId, mediaKind, canonicalMediaId, preset, windowKind, positionCount, customPresetId,
                   selection, catalogDigest, entrySnapshot, createdAt)
                VALUES (?, 'plugin.test', 'manga', 'series-1', 'next5', NULL, NULL, NULL, ?, ?, ?, 10),
                       (?, 'plugin.test', 'novel', 'series-2', 'custom', 'next', 7, ?, ?, NULL, ?, 20)
                """, arguments: [
                    Self.batchOne, Data(#"{"formatVersion":1,"kind":"sourceList"}"#.utf8), String(repeating: "d", count: 64),
                    Data("snapshot-one".utf8),
                    Self.batchTwo, Self.customPreset, Data(#"{"formatVersion":2,"kind":"allUploads"}"#.utf8),
                    Data("snapshot-two".utf8)
                ])
            for (id, batch, sequence, series, kind, key, created) in [
                (Self.jobOne, Self.batchOne, 0, "series-1", "manga", "c1", 10.0),
                (Self.jobTwo, Self.batchOne, 1, "series-1", "manga", "c2", 10.0),
                (Self.jobThree, Self.batchTwo, 0, "series-2", "novel", "n1", 20.0)
            ] {
                try db.execute(sql: """
                    INSERT INTO downloadJob
                      (id, batchId, sequence, pluginId, mediaKind, canonicalMediaId, chapterKey, authorityScope,
                       chapterSnapshot, seriesTitle, sourceEpoch, state, waitingReason, failureReason, stagingVersionId,
                       attemptCount, createdAt, updatedAt)
                    VALUES (?, ?, ?, 'plugin.test', ?, ?, ?, 'publicUnscoped', ?, 'Series', NULL, 'queued', NULL, NULL,
                            NULL, 0, ?, ?)
                    """, arguments: [id, batch, sequence, kind, series, key, Data("{}".utf8), created, created])
            }
            try db.execute(sql: """
                INSERT INTO downloadReplacementIntent
                  (jobId, expectedVersionId, expectedRevision, targetRevision, sourceEpoch, authorizationId)
                VALUES (?, 'version-1', 'r1', 'r2', 'epoch', 'authorization')
                """, arguments: [Self.jobTwo])
        }
        return queue
    }

    // MARK: - C25: the migration

    @Test func c25_everyExistingJobGetsExactlyOneManualOwnerNamedByItsBatch() throws {
        let queue = try databaseAtV26()
        let batchesBefore = try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM downloadBatch ORDER BY id") }
        let jobsBefore = try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM downloadJob ORDER BY id") }

        try AppDatabase.makeMigrator().migrate(queue)

        try queue.read { db in
            let owners = try Row.fetchAll(db, sql: "SELECT * FROM downloadJobOwner ORDER BY jobId")
            #expect(owners.count == 3)
            let expected = [
                (Self.jobOne, Self.batchOne, 10.0), (Self.jobTwo, Self.batchOne, 10.0), (Self.jobThree, Self.batchTwo, 20.0)
            ]
            for (jobId, batchId, created) in expected {
                let rows = owners.filter { ($0["jobId"] as String) == jobId }
                #expect(rows.count == 1)
                let owner = try #require(rows.first)
                #expect((owner["ownerKind"] as String) == "manual")
                #expect((owner["manualRequestId"] as String?) == batchId)
                #expect((owner["subscriptionId"] as String?) == nil)
                #expect((owner["subscriptionIncarnation"] as Int64?) == nil)
                #expect((owner["eventId"] as String?) == nil)
                #expect((owner["attachedAt"] as Double) == created)
            }
            // Jobs, batches and the replacement intent are copied exactly.
            #expect(try Row.fetchAll(db, sql: "SELECT * FROM downloadJob ORDER BY id") == jobsBefore)
            #expect(try Row.fetchAll(db, sql: "SELECT * FROM downloadBatch ORDER BY id") == batchesBefore)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloadReplacementIntent") == 1)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            // J1 holds for the migrated database.
            #expect(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM downloadJob
                WHERE NOT EXISTS (SELECT 1 FROM downloadJobOwner WHERE jobId = downloadJob.id)
                """) == 0)
            // The batch's foreign key and the job indexes survived the rebuild.
            let foreignKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(downloadJob)")
            #expect(foreignKeys.contains { (row: Row) in (row["table"] as String?) == "downloadBatch" })
            let indexes = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'downloadJobOwner'"
            )
            #expect(Set(indexes).isSuperset(of: [
                "idx_downloadJobOwner_manual", "idx_downloadJobOwner_subscription", "idx_downloadJobOwner_job",
                "idx_downloadJobOwner_bySubscription"
            ]))
        }
    }

    @Test func theOwnerRowsFollowTheirJobAndNeverTheirSubscription() throws {
        let queue = try databaseAtV26()
        try AppDatabase.makeMigrator().migrate(queue)
        try queue.write { db in
            // Deleting a job takes its owner rows with it.
            try db.execute(sql: "DELETE FROM downloadJob WHERE id = ?", arguments: [Self.jobOne])
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloadJobOwner WHERE jobId = ?", arguments: [Self.jobOne]) == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloadJobOwner") == 2)
        }
        let subscription = UUID().uuidString
        try queue.write { db in
            try insertSubscription(db, id: subscription)
            try db.execute(sql: """
                INSERT INTO downloadJobOwner (jobId, ownerKind, subscriptionId, subscriptionIncarnation, eventId, attachedAt)
                VALUES (?, 'subscription', ?, 1, ?, 0)
                """, arguments: [Self.jobTwo, subscription, UUID().uuidString])
        }
        // A subscription that still owns a job cannot be deleted: release is explicit.
        #expect(throws: DatabaseError.self) {
            try queue.write { db in try db.execute(sql: "DELETE FROM seriesSubscription WHERE id = ?", arguments: [subscription]) }
        }
        try queue.write { db in
            try db.execute(sql: "DELETE FROM downloadJobOwner WHERE subscriptionId = ?", arguments: [subscription])
            try db.execute(sql: "DELETE FROM seriesSubscription WHERE id = ?", arguments: [subscription])
        }
    }

    // MARK: - Constraints

    private func insertSubscription(
        _ db: Database,
        id: String = UUID().uuidString,
        media: String = "series-9",
        state: String = "enabled",
        pauseReason: String? = nil,
        mode: String = "newReleases",
        windowSize: DatabaseValueConvertible? = nil,
        cap: DatabaseValueConvertible = 5,
        lastAttemptAt: DatabaseValueConvertible? = nil,
        lastAttemptOutcome: String? = nil
    ) throws {
        let values: [DatabaseValueConvertible?] = [
            id, media, state, pauseReason, mode, windowSize, cap, Data("{}".utf8), lastAttemptAt, lastAttemptOutcome
        ]
        try db.execute(sql: """
            INSERT INTO seriesSubscription
              (id, pluginId, mediaKind, canonicalMediaId, state, pauseReason, mode, windowSize, perRunPositionCap,
               selection, replacementRule, incarnation, configGeneration, nextCheckTicket, lastAttemptAt,
               lastAttemptOutcome, lastSuccessAt, createdAt, updatedAt)
            VALUES (?, 'plugin.test', 'manga', ?, ?, ?, ?, ?, ?, ?, 'off', 1, 1, 1, ?, ?, NULL, 0, 0)
            """, arguments: StatementArguments(values))
    }

    private func latestDatabase() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(queue)
        return queue
    }

    private func expectRejected(_ queue: DatabaseQueue, _ body: @escaping (Database) throws -> Void) {
        #expect(throws: DatabaseError.self) {
            try queue.write { db in try body(db) }
        }
    }

    @Test func automaticBatchesAcceptNoWindowOrCustomProvenance() throws {
        let queue = try latestDatabase()
        func insert(_ db: Database, preset: String, windowKind: String?, count: Int?, custom: String?) throws {
            try db.execute(sql: """
                INSERT INTO downloadBatch
                  (id, pluginId, mediaKind, canonicalMediaId, preset, windowKind, positionCount, customPresetId,
                   selection, catalogDigest, entrySnapshot, createdAt)
                VALUES (?, 'plugin.test', 'manga', 'series-1', ?, ?, ?, ?, ?, NULL, ?, 0)
                """, arguments: [UUID().uuidString, preset, windowKind, count, custom, Data("{}".utf8), Data("{}".utf8)])
        }
        try queue.write { db in try insert(db, preset: "automatic", windowKind: nil, count: nil, custom: nil) }
        expectRejected(queue) { try insert($0, preset: "automatic", windowKind: "next", count: 3, custom: nil) }
        expectRejected(queue) { try insert($0, preset: "automatic", windowKind: nil, count: nil, custom: UUID().uuidString) }
        expectRejected(queue) { try insert($0, preset: "scheduled", windowKind: nil, count: nil, custom: nil) }
    }

    @Test func provenanceKnowsTheAutomaticPresetAndItsConsistencyRule() {
        #expect(DownloadBatchProvenance.automatic.preset == .automatic)
        #expect(DownloadBatchProvenance.automatic.isConsistent)
        #expect(!DownloadBatchProvenance(preset: .automatic, windowKind: .next, positionCount: 3, customPresetId: nil).isConsistent)
        #expect(!DownloadBatchProvenance(preset: .automatic, windowKind: nil, positionCount: nil, customPresetId: "x").isConsistent)
    }

    @Test func subscriptionRowsRefuseEveryOutOfContractCombination() throws {
        let queue = try latestDatabase()
        try queue.write { db in
            try insertSubscription(db, media: "ok-1")
            try insertSubscription(db, media: "ok-2", state: "paused", pauseReason: "user")
            try insertSubscription(db, media: "ok-3", mode: "maintainNextUnread", windowSize: 3)
            try insertSubscription(db, media: "ok-4", lastAttemptAt: 5, lastAttemptOutcome: "fetchFailed")
        }
        // One identity per series.
        expectRejected(queue) { try self.insertSubscription($0, media: "ok-1") }
        // A paused rule has a reason, and only a paused rule does.
        expectRejected(queue) { try self.insertSubscription($0, media: "x1", state: "paused") }
        expectRejected(queue) { try self.insertSubscription($0, media: "x2", state: "enabled", pauseReason: "user") }
        expectRejected(queue) { try self.insertSubscription($0, media: "x3", state: "paused", pauseReason: "other") }
        // A window size exactly in maintain mode, between 1 and 100, as an integer.
        expectRejected(queue) { try self.insertSubscription($0, media: "x4", mode: "maintainNextUnread") }
        expectRejected(queue) { try self.insertSubscription($0, media: "x5", windowSize: 3) }
        expectRejected(queue) { try self.insertSubscription($0, media: "x6", mode: "maintainNextUnread", windowSize: 0) }
        expectRejected(queue) { try self.insertSubscription($0, media: "x7", mode: "maintainNextUnread", windowSize: 101) }
        expectRejected(queue) { try self.insertSubscription($0, media: "x8", mode: "maintainNextUnread", windowSize: 2.5) }
        expectRejected(queue) { try self.insertSubscription($0, media: "x9", mode: "everything") }
        // The per-run cap is an integer from 1 to 20.
        expectRejected(queue) { try self.insertSubscription($0, media: "y1", cap: 0) }
        expectRejected(queue) { try self.insertSubscription($0, media: "y2", cap: 21) }
        expectRejected(queue) { try self.insertSubscription($0, media: "y3", cap: 5.5) }
        // The last attempt is recorded as a pair, with a known outcome.
        expectRejected(queue) { try self.insertSubscription($0, media: "z1", lastAttemptAt: 5) }
        expectRejected(queue) { try self.insertSubscription($0, media: "z2", lastAttemptOutcome: "fetchFailed") }
        expectRejected(queue) { try self.insertSubscription($0, media: "z3", lastAttemptAt: 5, lastAttemptOutcome: "exploded") }
    }

    @Test func ownerRowsRefuseInconsistentOwnerKinds() throws {
        let queue = try databaseAtV26()
        try AppDatabase.makeMigrator().migrate(queue)
        let subscription = UUID().uuidString
        try queue.write { db in try insertSubscription(db, id: subscription) }
        func insert(_ db: Database, kind: String, request: String?, subscription: String?, incarnation: Int?, event: String?) throws {
            try db.execute(sql: """
                INSERT INTO downloadJobOwner
                  (jobId, ownerKind, manualRequestId, subscriptionId, subscriptionIncarnation, eventId, attachedAt)
                VALUES (?, ?, ?, ?, ?, ?, 0)
                """, arguments: [Self.jobThree, kind, request, subscription, incarnation, event])
        }
        let request = UUID().uuidString
        let event = UUID().uuidString
        expectRejected(queue) { try insert($0, kind: "manual", request: nil, subscription: nil, incarnation: nil, event: nil) }
        expectRejected(queue) { try insert($0, kind: "manual", request: request, subscription: subscription, incarnation: nil, event: nil) }
        expectRejected(queue) { try insert($0, kind: "manual", request: "short", subscription: nil, incarnation: nil, event: nil) }
        expectRejected(queue) { try insert($0, kind: "subscription", request: nil, subscription: subscription, incarnation: nil, event: event) }
        expectRejected(queue) { try insert($0, kind: "subscription", request: nil, subscription: subscription, incarnation: 0, event: event) }
        expectRejected(queue) { try insert($0, kind: "subscription", request: nil, subscription: subscription, incarnation: 1, event: nil) }
        expectRejected(queue) { try insert($0, kind: "subscription", request: request, subscription: subscription, incarnation: 1, event: event) }
        expectRejected(queue) { try insert($0, kind: "subscription", request: nil, subscription: UUID().uuidString, incarnation: 1, event: event) }
        expectRejected(queue) { try insert($0, kind: "robot", request: nil, subscription: nil, incarnation: nil, event: nil) }
        try queue.write { db in
            try insert(db, kind: "subscription", request: nil, subscription: subscription, incarnation: 1, event: event)
        }
        // One row per owner of a job: the same subscription cannot own it twice.
        expectRejected(queue) {
            try insert($0, kind: "subscription", request: nil, subscription: subscription, incarnation: 1, event: UUID().uuidString)
        }
    }

    // MARK: - Enum parity

    /// The raw values of the `IN (...)` list that follows `column` in the stored `CREATE TABLE` statement.
    private func checkList(_ db: Database, table: String, column: String) throws -> Set<String> {
        let sql = try #require(try String.fetchOne(
            db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", arguments: [table]
        ))
        let pattern = "(?:^|[\\s(,])\(column)\\s+TEXT\\b.*?\\bIN\\s*\\(([^)]*)\\)"
        let expression = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(sql.startIndex..., in: sql)
        let match = try #require(expression.firstMatch(in: sql, range: range), "no CHECK list for \(table).\(column)")
        let list = (sql as NSString).substring(with: match.range(at: 1))
        return Set(list.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        })
    }

    @Test func everyEnumMirrorsItsCheckConstraintExactly() throws {
        let queue = try latestDatabase()
        try queue.read { db in
            func parity<E: CaseIterable & RawRepresentable>(
                _ type: E.Type, _ table: String, _ column: String, except: Set<String> = [],
                sourceLocation: SourceLocation = #_sourceLocation
            ) throws where E.RawValue == String {
                let cases = Set(type.allCases.map(\.rawValue)).subtracting(except)
                #expect(try checkList(db, table: table, column: column) == cases, "\(table).\(column)", sourceLocation: sourceLocation)
            }
            try parity(SubscriptionState.self, "seriesSubscription", "state")
            try parity(SubscriptionPauseReason.self, "seriesSubscription", "pauseReason")
            try parity(SubscriptionMode.self, "seriesSubscription", "mode")
            try parity(SubscriptionReplacementRule.self, "seriesSubscription", "replacementRule")
            try parity(SubscriptionCheckOutcome.self, "seriesSubscription", "lastAttemptOutcome")
            try parity(MediaKind.self, "seriesSubscription", "mediaKind", except: ["anime"])
            try parity(SubscriptionAcquisition.self, "subscriptionBaseline", "acquisition")
            try parity(LibraryCatalogScope.self, "subscriptionBaseline", "catalogScope", except: ["unknown"])
            try parity(SubscriptionOrderConfidence.self, "subscriptionBaseline", "orderConfidence")
            try parity(SubscriptionPositionKind.self, "subscriptionBaseline", "highWaterKind")
            try parity(SubscriptionPositionKind.self, "subscriptionSeenKey", "positionKind")
            try parity(SubscriptionEventKind.self, "subscriptionEvent", "kind")
            try parity(SubscriptionIdentityKind.self, "subscriptionEvent", "identityKind")
            try parity(SubscriptionDecision.self, "subscriptionEvent", "decision")
            try parity(SubscriptionPendingReason.self, "subscriptionEvent", "pendingReason")
            try parity(SubscriptionReviewReason.self, "subscriptionEvent", "reviewReason")
            try parity(DownloadOwnerKind.self, "downloadJobOwner", "ownerKind")
            try parity(DownloadBatchPreset.self, "downloadBatch", "preset")
        }
    }

    @Test func openDecisionsAreExactlyTheUndecidedAndWaitingOnes() {
        let open = Set(SubscriptionDecision.allCases.filter(\.isOpen))
        #expect(open == [.undecided, .pending, .awaitingEdition, .needsChoice, .needsReview, .locked])
    }

    @Test func eventRowsRefuseInconsistentDecisions() throws {
        let queue = try latestDatabase()
        let subscription = UUID().uuidString
        try queue.write { db in try insertSubscription(db, id: subscription) }
        func insert(
            _ db: Database,
            kind: String = "newPosition",
            decision: String = "undecided",
            pending: String? = nil,
            review: String? = nil,
            decided: Data? = nil,
            target: String? = nil,
            qualifier: String? = nil,
            value: String = UUID().uuidString
        ) throws {
            try db.execute(sql: """
                INSERT INTO subscriptionEvent
                  (id, subscriptionId, incarnation, kind, identityKind, identityValue, qualifier, decision, pendingReason,
                   reviewReason, candidateKeys, candidateRevision, approvedKeys, decidedKeys, previousRevision,
                   targetRevision, ordinal, observedCatalogDigest, configGeneration, scopeGeneration, createdAt, decidedAt)
                VALUES (?, ?, 1, ?, 'exact', ?, ?, ?, ?, ?, ?, 1, NULL, ?, NULL, ?, 0, ?, 1, 1, 0, NULL)
                """, arguments: [
                    UUID().uuidString, subscription, kind, value, qualifier, decision, pending, review,
                    Data("[]".utf8), decided, target, String(repeating: "d", count: 64)
                ])
        }
        try queue.write { db in
            try insert(db)
            try insert(db, decision: "pending", pending: "runCap")
            try insert(db, decision: "needsReview", review: "bulkArrival")
            try insert(db, decision: "enqueued", decided: Data("[]".utf8))
            try insert(db, kind: "revisionChanged", target: "r2", qualifier: "r2")
        }
        expectRejected(queue) { try insert($0, decision: "pending") }
        expectRejected(queue) { try insert($0, decision: "undecided", pending: "runCap") }
        expectRejected(queue) { try insert($0, decision: "pending", pending: "never") }
        expectRejected(queue) { try insert($0, decision: "needsReview") }
        expectRejected(queue) { try insert($0, decision: "enqueued") }
        expectRejected(queue) { try insert($0, decision: "undecided", decided: Data("[]".utf8)) }
        expectRejected(queue) { try insert($0, kind: "revisionChanged") }
        expectRejected(queue) { try insert($0, kind: "revisionChanged", target: "r2", qualifier: "other") }
        expectRejected(queue) { try insert($0, kind: "newPosition", target: "r2") }
        // The identity is unique per incarnation and kind, with the qualifier part of it.
        let fixed = "same-identity"
        try queue.write { db in try insert(db, qualifier: nil, value: fixed) }
        expectRejected(queue) { try insert($0, qualifier: nil, value: fixed) }
        try queue.write { db in try insert(db, qualifier: "other", value: fixed) }
    }

    @Test func baselineAndSeenKeyRowsRefuseOutOfContractValues() throws {
        let queue = try latestDatabase()
        let subscription = UUID().uuidString
        try queue.write { db in try insertSubscription(db, id: subscription) }
        func baseline(
            _ db: Database,
            id: String,
            epoch: String = String(repeating: "a", count: 32),
            scope: String = "allEligible",
            rows: Int = 3,
            confidence: String = "confident",
            highWaterKind: String? = "logical",
            highWaterValue: String? = "u3"
        ) throws {
            try db.execute(sql: """
                INSERT INTO subscriptionBaseline
                  (subscriptionId, incarnation, revision, acceptedTicket, scopeGeneration, acquisition, sourceEpoch,
                   pluginVersion, chapterABI, catalogScope, catalogDigest, rowCount, orderConfidence, highWaterKind,
                   highWaterValue, maxDateUpdated, tombstonesTruncated, entrySnapshot, acceptedAt)
                VALUES (?, 1, 1, 1, 1, 'mediaUpdate', ?, '1.0.0', 3, ?, ?, ?, ?, ?, ?, NULL, 0, ?, 0)
                """, arguments: [
                    id, epoch, scope, String(repeating: "d", count: 64), rows, confidence, highWaterKind, highWaterValue,
                    Data("{}".utf8)
                ])
        }
        expectRejected(queue) { try baseline($0, id: subscription, epoch: "short") }
        expectRejected(queue) { try baseline($0, id: subscription, scope: "unknown") }
        expectRejected(queue) { try baseline($0, id: subscription, rows: 0) }
        expectRejected(queue) { try baseline($0, id: subscription, rows: 20_001) }
        expectRejected(queue) { try baseline($0, id: subscription, confidence: "confident", highWaterKind: nil, highWaterValue: nil) }
        expectRejected(queue) { try baseline($0, id: subscription, confidence: "ambiguous") }
        expectRejected(queue) { try baseline($0, id: subscription, highWaterKind: "logical", highWaterValue: nil) }
        expectRejected(queue) { try baseline($0, id: UUID().uuidString) }
        try queue.write { db in try baseline(db, id: subscription) }

        func seen(_ db: Database, key: String, present: Int = 1, rank: Int? = 0, kind: String = "exact") throws {
            try db.execute(sql: """
                INSERT INTO subscriptionSeenKey
                  (subscriptionId, chapterKey, positionKind, positionValue, lastRevision, presentInAccepted, acceptedRank,
                   firstSeenScopeGeneration, firstSeenAt)
                VALUES (?, ?, ?, 'p', NULL, ?, ?, 1, 0)
                """, arguments: [subscription, key, kind, present, rank])
        }
        try queue.write { db in
            try seen(db, key: "a")
            try seen(db, key: "tombstone", present: 0, rank: nil)
        }
        expectRejected(queue) { try seen($0, key: "a") }
        expectRejected(queue) { try seen($0, key: "") }
        expectRejected(queue) { try seen($0, key: String(repeating: "k", count: 513)) }
        expectRejected(queue) { try seen($0, key: "bad-kind", kind: "number") }
        expectRejected(queue) { try seen($0, key: "ranked-tombstone", present: 0, rank: 1) }
        expectRejected(queue) { try seen($0, key: "negative", rank: -1) }

        // Deleting the subscription's baseline row set follows the subscription: seen keys and baseline cascade.
        try queue.write { db in
            try db.execute(sql: "DELETE FROM seriesSubscription WHERE id = ?", arguments: [subscription])
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM subscriptionBaseline") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM subscriptionSeenKey") == 0)
        }
    }

    // MARK: - Backup classification

    @Test func theNewTablesAreExcludedFromBackupAndSanitizedChildFirst() throws {
        let tables = [
            "downloadJobOwner", "seriesSubscription", "subscriptionBaseline", "subscriptionSeenKey", "subscriptionEvent"
        ]
        for table in tables {
            #expect(BackupExportOperation.excludedTableReasons[table] != nil, "\(table) needs a backup policy")
            #expect(BackupExportOperation.sanitizedTables.contains(table), "\(table) must be sanitized")
        }
        func index(_ table: String) throws -> Int {
            try #require(BackupExportOperation.sanitizedTables.firstIndex(of: table))
        }
        // A row is deleted before the rows it references: owners before jobs and subscriptions, jobs before batches,
        // and a subscription's events, seen keys and baseline before the subscription.
        #expect(try index("downloadJobOwner") < index("downloadJob"))
        #expect(try index("downloadJob") < index("downloadBatch"))
        #expect(try index("downloadJobOwner") < index("seriesSubscription"))
        for child in ["subscriptionEvent", "subscriptionSeenKey", "subscriptionBaseline"] {
            #expect(try index(child) < index("seriesSubscription"))
        }
    }
}
