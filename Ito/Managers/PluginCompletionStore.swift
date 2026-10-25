import Foundation
import GRDB

/// SQL authority for installation-local completion delivery. No request material is persisted.
nonisolated final class PluginCompletionStore: Sendable {
    private let dbPool: DatabasePool
    private let secrets: PluginSecretStore
    private let tokens: PluginSecretStore

    init(dbPool: DatabasePool, secrets: PluginSecretStore, tokens: PluginSecretStore) {
        self.dbPool = dbPool
        self.secrets = secrets
        self.tokens = tokens
    }

    func observeChanges(_ onChange: @escaping @Sendable () -> Void) -> PluginCompletionObservation {
        let observation = PluginCompletionObservation(onChange: onChange)
        dbPool.add(transactionObserver: observation, extent: .observerLifetime)
        return observation
    }

    func captureContext(media: MediaIdentity, mediaKey: String) -> PluginCompletionContext {
        let epoch = try? secrets.withConfigurationLock {
            try dbPool.write { db in try PluginCompletionScope.capture(pluginID: media.pluginId, in: db) }
        }
        return PluginCompletionContext(media: media, mediaKey: mediaKey, originatingEpoch: epoch)
    }

    static func enqueue(context: PluginCompletionContext, unitKey: String, now: Date, in db: Database) throws {
        let reason: PluginCompletionPauseReason?
        if let origin = context.originatingEpoch {
            do {
                reason = try PluginCompletionScope.current(pluginID: context.media.pluginId, in: db) == origin
                    ? nil : .configurationChanged
            } catch PluginCompletionScopeError.invalidMetadata {
                reason = .configurationChanged
            }
        } else {
            reason = .unknownOrigin
        }
        let status = reason == nil ? PluginCompletionStatus.pending : .paused
        if let existing = try PluginCompletionIntent.fetchOne(
            db,
            sql: """
                SELECT * FROM pluginCompletionOutbox
                WHERE pluginId = ? AND kind = ? AND mediaKey = ? AND unitKey = ?
                    AND originatingEpoch IS ?
                """,
            arguments: [context.media.pluginId, context.kind.rawValue, context.mediaKey, unitKey, context.originatingEpoch]
        ) {
            let keptReason = existing.status == .paused ? existing.pauseReason : reason
            try db.execute(
                sql: """
                    UPDATE pluginCompletionOutbox SET revision = revision + 1,
                        status = ?, pauseReason = ? WHERE id = ?
                    """,
                arguments: [keptReason == nil ? "pending" : "paused", keptReason?.rawValue, existing.id]
            )
        } else {
            try db.execute(
                sql: """
                    INSERT INTO pluginCompletionOutbox
                        (pluginId, canonicalMediaId, mediaKey, unitKey, kind, originatingEpoch,
                         status, pauseReason, createdAt, nextAttemptAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    context.media.pluginId, context.media.canonicalMediaId, context.mediaKey, unitKey,
                    context.kind.rawValue, context.originatingEpoch, status.rawValue, reason?.rawValue, now, now
                ]
            )
        }
    }

    func dueIntents(now: Date, limit: Int = 32) async throws -> [PluginCompletionIntent] {
        try await dbPool.write { db in
            try Self.pauseInvalidOrigins(in: db)
            return try PluginCompletionIntent.fetchAll(
                db,
                sql: """
                    SELECT o.* FROM pluginCompletionOutbox o
                    WHERE o.status = 'pending' AND o.nextAttemptAt <= ?
                        AND NOT EXISTS(
                            SELECT 1 FROM pluginCompletionOutbox earlier
                            WHERE earlier.pluginId = o.pluginId AND earlier.status = 'pending'
                                AND (earlier.createdAt < o.createdAt OR
                                    (earlier.createdAt = o.createdAt AND earlier.id < o.id))
                        )
                    ORDER BY o.createdAt, o.id LIMIT ?
                    """,
                arguments: [now, limit]
            )
        }
    }

    func nextAttemptDate() async throws -> Date? {
        try await dbPool.read { db in
            try Date.fetchOne(db, sql: """
                SELECT MIN(o.nextAttemptAt) FROM pluginCompletionOutbox o
                JOIN pluginCompletionScope s ON s.pluginId = o.pluginId AND s.epoch = o.originatingEpoch
                WHERE o.status = 'pending' AND NOT EXISTS(
                    SELECT 1 FROM pluginCompletionOutbox earlier
                    WHERE earlier.pluginId = o.pluginId AND earlier.status = 'pending'
                        AND (earlier.createdAt < o.createdAt OR
                            (earlier.createdAt = o.createdAt AND earlier.id < o.id))
                )
                """)
        }
    }

    func beginAttempt(_ intent: PluginCompletionIntent, now: Date) async throws -> PluginCompletionAttempt? {
        guard let attempt = PluginCompletionAttempt(intent) else { return nil }
        return try await dbPool.write { db in
            guard try Self.matches(attempt, in: db) else { return nil }
            try db.execute(
                sql: "UPDATE pluginCompletionOutbox SET lastAttemptAt = ? WHERE id = ?",
                arguments: [now, attempt.id]
            )
            return attempt
        }
    }

    /// The caller runs this finite blocking capture off MainActor. Lock order is secret lock ->
    /// token lock -> DB read.
    func snapshot(for intent: PluginCompletionIntent) throws -> PluginCompletionSnapshot {
        guard let attempt = PluginCompletionAttempt(intent) else {
            throw PluginCompletionScopeError.configurationChanged
        }
        return try secrets.withSnapshot(pluginID: intent.pluginId) { secretValues in
            try tokens.withSnapshot(pluginID: intent.pluginId) { tokenValues in
                try dbPool.read { db in
                    guard try Self.matches(attempt, in: db) else {
                        throw PluginCompletionScopeError.configurationChanged
                    }
                    let rows = try PluginSettingRecord.filter(Column("pluginId") == intent.pluginId).fetchAll(db)
                    let settings = try PluginSettingsStore.layeredSettings(
                        rows: rows, tokens: tokenValues, secrets: secretValues
                    )
                    return PluginCompletionSnapshot(intent: intent, settings: settings)
                }
            }
        }
    }

    func finish(_ attempt: PluginCompletionAttempt, outcome: PluginCompletionOutcome, now: Date) async throws {
        if case .cancelled = outcome { return }
        try await dbPool.write { db in
            guard try Self.matches(attempt, in: db),
                  let intent = try PluginCompletionIntent.fetchOne(db, key: attempt.id) else { return }
            switch outcome {
            case .acknowledged, .unsupported:
                try db.execute(sql: "DELETE FROM pluginCompletionOutbox WHERE id = ?", arguments: [attempt.id])
            case .cancelled:
                break
            case .retryable(let category):
                let failures = intent.attemptCount + 1
                if let delay = PluginCompletionRetryPolicy.delay(afterCompletedFailures: failures) {
                    try db.execute(
                        sql: """
                            UPDATE pluginCompletionOutbox SET attemptCount = ?, lastErrorCategory = ?,
                                nextAttemptAt = ? WHERE id = ?
                            """,
                        arguments: [failures, category.rawValue, now.addingTimeInterval(delay), attempt.id]
                    )
                } else {
                    try Self.pause(id: attempt.id, failures: failures, reason: .retryLimit, category: category, in: db)
                }
            case .paused(let reason, let category):
                try Self.pause(id: attempt.id, failures: intent.attemptCount + 1, reason: reason, category: category, in: db)
            }
        }
    }

    func summaries() async throws -> [PluginCompletionSummary] {
        try await dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT pluginId, status, pauseReason, COUNT(*) AS count FROM pluginCompletionOutbox
                GROUP BY pluginId, status, pauseReason ORDER BY pluginId
                """)
            var counts: [String: (pending: Int, paused: Int, reasons: Set<PluginCompletionPauseReason>)] = [:]
            for row in rows {
                let pluginID: String = row["pluginId"]
                let status: String = row["status"]
                let count: Int = row["count"]
                var value = counts[pluginID] ?? (0, 0, [])
                if status == PluginCompletionStatus.pending.rawValue { value.pending += count } else { value.paused += count }
                if let raw: String = row["pauseReason"], let reason = PluginCompletionPauseReason(rawValue: raw) {
                    value.reasons.insert(reason)
                }
                counts[pluginID] = value
            }
            return counts.keys.sorted().map { pluginID in
                let value = counts[pluginID]!
                return PluginCompletionSummary(
                    pluginID: pluginID, pendingCount: value.pending, pausedCount: value.paused, pauseReasons: value.reasons
                )
            }
        }
    }

    func reauthorizePaused(pluginID: String, now: Date) async throws {
        try await dbPool.write { db in
            let epoch = try PluginCompletionScope.capture(pluginID: pluginID, in: db)
            let paused = try PluginCompletionIntent.fetchAll(
                db, sql: "SELECT * FROM pluginCompletionOutbox WHERE pluginId = ? AND status = 'paused' ORDER BY id",
                arguments: [pluginID]
            )
            for original in paused {
                guard let row = try PluginCompletionIntent.fetchOne(db, key: original.id), row.status == .paused else { continue }
                let survivor = try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT id FROM pluginCompletionOutbox
                        WHERE pluginId = ? AND kind = ? AND mediaKey = ? AND unitKey = ? AND originatingEpoch = ?
                        """,
                    arguments: [pluginID, row.kind.rawValue, row.mediaKey, row.unitKey, epoch]
                ) ?? row.id
                if survivor != row.id {
                    try db.execute(sql: "DELETE FROM pluginCompletionOutbox WHERE id = ?", arguments: [row.id])
                }
                try db.execute(
                    sql: """
                        UPDATE pluginCompletionOutbox SET originatingEpoch = ?, revision = revision + 1,
                            status = 'pending', pauseReason = NULL, attemptCount = 0, nextAttemptAt = ?,
                            lastAttemptAt = NULL, lastErrorCategory = NULL WHERE id = ?
                        """,
                    arguments: [epoch, now, survivor]
                )
            }
        }
    }

    func discardPaused(pluginID: String) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM pluginCompletionOutbox WHERE pluginId = ? AND status = 'paused'", arguments: [pluginID]
            )
        }
    }

    /// Stops a source's delivery before its file is removed. Rotating the scope pauses every pending
    /// intent, so a removal that then fails leaves them recoverable instead of silently lost.
    func holdForRemoval(pluginID: String) async throws {
        try await dbPool.write { db in
            try PluginCompletionScope.rotate(pluginID: pluginID, in: db)
        }
    }

    /// Forgets a source's intents once its file is gone.
    func purgeRemoved(pluginID: String) async throws {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM pluginCompletionOutbox WHERE pluginId = ?", arguments: [pluginID])
        }
    }

    private static func matches(_ attempt: PluginCompletionAttempt, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM pluginCompletionOutbox o
                JOIN pluginCompletionScope s ON s.pluginId = o.pluginId AND s.epoch = o.originatingEpoch
                WHERE o.id = ? AND o.revision = ? AND o.pluginId = ? AND o.originatingEpoch = ? AND o.status = 'pending'
            )
            """, arguments: [attempt.id, attempt.revision, attempt.pluginID, attempt.originatingEpoch]) ?? false
    }

    private static func pauseInvalidOrigins(in db: Database) throws {
        try db.execute(sql: """
            UPDATE pluginCompletionOutbox SET status = 'paused', revision = revision + 1,
                pauseReason = CASE WHEN originatingEpoch IS NULL THEN 'unknownOrigin' ELSE 'configurationChanged' END
            WHERE status = 'pending' AND NOT EXISTS(
                SELECT 1 FROM pluginCompletionScope s
                WHERE s.pluginId = pluginCompletionOutbox.pluginId AND s.epoch = pluginCompletionOutbox.originatingEpoch
            )
            """)
    }

    private static func pause(
        id: Int64,
        failures: Int,
        reason: PluginCompletionPauseReason,
        category: PluginCompletionFailureCategory?,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE pluginCompletionOutbox SET status = 'paused', pauseReason = ?,
                    attemptCount = ?, lastErrorCategory = ? WHERE id = ?
                """,
            arguments: [reason.rawValue, failures, category?.rawValue, id]
        )
    }
}
