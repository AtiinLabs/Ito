import Foundation
import GRDB
import Testing
@testable import Ito

/// V13: the notification claim's column is added without touching a row, and the table stays sanitized in a backup.
struct SubscriptionAttentionMigrationTests {
    private static let rule = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

    /// A database at schema v27 with a rule and events that wait for a person, were decided and were dismissed.
    private func databaseAtV27() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(queue, upTo: "v27")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO seriesSubscription
                  (id, pluginId, mediaKind, canonicalMediaId, state, pauseReason, mode, windowSize, perRunPositionCap,
                   selection, replacementRule, incarnation, configGeneration, nextCheckTicket, createdAt, updatedAt)
                VALUES (?, 'plugin.test', 'manga', 'series-1', 'enabled', NULL, 'newReleases', NULL, 5, ?, 'off', 1, 1, 1, 1, 1)
                """, arguments: [Self.rule, Data(#"{"formatVersion":1,"kind":"sourceList"}"#.utf8)])
            for (index, decision) in ["needsChoice", "needsReview", "dismissed", "enqueued"].enumerated() {
                try db.execute(sql: """
                    INSERT INTO subscriptionEvent
                      (id, subscriptionId, incarnation, kind, identityKind, identityValue, qualifier, decision, pendingReason,
                       reviewReason, candidateKeys, candidateRevision, ordinal, observedCatalogDigest, configGeneration,
                       scopeGeneration, createdAt, decidedAt, decidedKeys)
                    VALUES (?, ?, 1, 'newPosition', 'exact', ?, NULL, ?, NULL, ?, '[]', 1, ?, ?, 1, 1, 1, NULL, ?)
                    """, arguments: [
                        UUID().uuidString, Self.rule, "k\(index)", decision,
                        decision == "needsReview" ? "bulkArrival" : nil, index, String(repeating: "d", count: 64),
                        decision == "enqueued" ? Data("[]".utf8) : nil
                    ])
            }
        }
        return queue
    }

    @Test func theColumnIsNullForEveryExistingRowTheIndexExistsAndNoForeignKeyIsBroken() throws {
        let queue = try databaseAtV27()
        #expect(try queue.read { db in try !Self.columns(of: "subscriptionEvent", in: db).contains("notifiedAt") })
        let before = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, decision, decidedAt FROM subscriptionEvent ORDER BY id")
        }

        try AppDatabase.makeMigrator().migrate(queue)

        try queue.read { db in
            #expect(try Self.columns(of: "subscriptionEvent", in: db).contains("notifiedAt"))
            let rows = try Row.fetchAll(db, sql: "SELECT id, decision, decidedAt, notifiedAt FROM subscriptionEvent ORDER BY id")
            #expect(rows.count == 4)
            #expect(rows.allSatisfy { ($0["notifiedAt"] as Date?) == nil })
            // Nothing else about a row changed.
            #expect(rows.map { $0["id"] as String } == before.map { $0["id"] as String })
            #expect(rows.map { $0["decision"] as String } == before.map { $0["decision"] as String })

            let index = try Row.fetchOne(
                db, sql: "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'idx_subscriptionEvent_unnotifiedAttention'"
            )
            let definition = try #require(index?["sql"] as String?)
            #expect(definition.contains("needsChoice") && definition.contains("needsReview") && definition.contains("notifiedAt IS NULL"))
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    @Test func aRecordInsertedByTheAppLeavesTheColumnNullAndATableCheckStillHolds() throws {
        let queue = try databaseAtV27()
        try AppDatabase.makeMigrator().migrate(queue)
        try queue.write { db in
            try SubscriptionEventRecord(
                id: UUID().uuidString, subscriptionId: Self.rule, incarnation: 1, kind: .newPosition, identityKind: .exact,
                identityValue: "fresh", qualifier: nil, decision: .needsChoice, pendingReason: nil, reviewReason: nil,
                candidateKeys: SubscriptionEventRecord.encode(keys: ["a"]), candidateRevision: 1, approvedKeys: nil,
                decidedKeys: nil, previousRevision: nil, targetRevision: nil, ordinal: 9,
                observedCatalogDigest: String(repeating: "d", count: 64), configGeneration: 1, scopeGeneration: 1,
                createdAt: Date(), decidedAt: nil
            ).insert(db)
            let record = try #require(try SubscriptionEventRecord.filter(Column("identityValue") == "fresh").fetchOne(db))
            #expect(record.notifiedAt == nil)
        }
    }

    @Test func subscriptionEventStaysASanitizedTableSoABackupNeverCarriesIts() {
        let tables = BackupExportOperation.sanitizedTables
        let index = tables.firstIndex(of: "subscriptionEvent")
        #expect(index != nil)
        // Events are children of the rule: they are cleared before it.
        #expect(index.map { $0 < (tables.firstIndex(of: "seriesSubscription") ?? -1) } == true)
        #expect(BackupExportOperation.excludedTableReasons["subscriptionEvent"] != nil)
    }

    private static func columns(of table: String, in db: Database) throws -> [String] {
        try db.columns(in: table).map(\.name)
    }
}
