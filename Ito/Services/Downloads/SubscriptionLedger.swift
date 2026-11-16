import Foundation
import GRDB
import ito_runner

/// The writes and reads of the ledger's own tables, each in the caller's transaction: subscriptions, their single
/// accepted baseline, the cumulative seen keys and the events. It never inserts or deletes a job, a batch, an owner
/// or a deletion record: everything that touches the queue goes through `OfflineChapterStore`, whose write
/// transaction is the only entry point.
nonisolated enum SubscriptionLedger {
    /// Terminal events kept per subscription; the oldest by decision time are pruned.
    static let terminalEventLimit = 500
    /// Tombstoned seen keys kept per subscription. Pruning one makes the baseline say so.
    static let tombstoneLimit = 20_000

    /// The decisions an event can still leave.
    static let openDecisions: [SubscriptionDecision] = SubscriptionDecision.allCases.filter(\.isOpen)
    /// The open decisions as a SQL list of quoted constants.
    static var openDecisionsSQL: String { openDecisions.map { "'\($0.rawValue)'" }.joined(separator: ",") }

    // MARK: - Reads

    static func subscription(id: String, in db: Database) throws -> SeriesSubscriptionRecord? {
        try SeriesSubscriptionRecord.fetchOne(db, key: id)
    }

    static func baselineRecord(of subscriptionId: String, in db: Database) throws -> SubscriptionBaselineRecord? {
        try SubscriptionBaselineRecord.fetchOne(db, key: subscriptionId)
    }

    /// The accepted baseline as the classifier reads it: the header and every seen key, tombstones included.
    static func view(of record: SubscriptionBaselineRecord, in db: Database) throws -> SubscriptionBaselineView {
        var seen: [ScanlatorUTF8: SubscriptionBaselineView.SeenKey] = [:]
        let cursor = try SubscriptionSeenKeyRecord
            .filter(Column("subscriptionId") == record.subscriptionId)
            .fetchCursor(db)
        while let key = try cursor.next() {
            seen[ScanlatorUTF8(value: key.chapterKey)] = key.evidence
        }
        return SubscriptionBaselineView(
            incarnation: record.incarnation,
            revision: record.revision,
            acceptedTicket: record.acceptedTicket,
            scopeGeneration: record.scopeGeneration,
            fingerprint: record.fingerprint,
            catalogDigest: record.catalogDigest,
            rowCount: record.rowCount,
            orderConfidence: record.orderConfidence.confidence,
            highWater: record.highWater,
            maxDateUpdated: record.maxDateUpdated,
            seen: seen
        )
    }

    /// Open events in the order they are decided: oldest first, then reading order, then identity.
    static func events(
        of subscriptionId: String,
        decisions: [SubscriptionDecision],
        in db: Database
    ) throws -> [SubscriptionEventRecord] {
        try SubscriptionEventRecord
            .filter(Column("subscriptionId") == subscriptionId && decisions.map(\.rawValue).contains(Column("decision")))
            .order(Column("createdAt"), Column("ordinal"), Column("id"))
            .fetchAll(db)
    }

    /// The exact read state of a series: marked chapter keys, the last chapter read, and whether it has number-only
    /// markers. A number never identifies a row here.
    static func readState(for media: MediaIdentity, in db: Database) throws -> SubscriptionReadState {
        let arguments: StatementArguments = [media.pluginId, media.mediaKind.rawValue, media.canonicalMediaId]
        let keys = try String.fetchAll(
            db,
            sql: "SELECT chapterKey FROM readProgressKey WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ?",
            arguments: arguments
        )
        let last = try String.fetchOne(
            db,
            sql: """
                SELECT lastReadChapterKey FROM mediaReadProgress
                WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ?
                """,
            arguments: arguments
        )
        let numbers = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM readProgressNumber WHERE pluginId = ? AND mediaKind = ? AND canonicalMediaId = ?",
            arguments: arguments
        ) ?? 0
        return SubscriptionReadState(
            readKeys: Set(keys.map { ScanlatorUTF8(value: $0) }),
            lastReadKey: last,
            hasNumberOnlyMarkers: numbers > 0
        )
    }

    // MARK: - Attempts

    /// Records the outcome of one check. `success` also moves `lastSuccessAt`: the catalog was read and judged, whatever
    /// it concluded. A rejected or failed attempt never touches the last accepted baseline.
    static func recordAttempt(
        _ subscriptionId: String,
        outcome: SubscriptionCheckOutcome,
        success: Bool,
        now: Date,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE seriesSubscription
                SET lastAttemptAt = ?, lastAttemptOutcome = ?, lastSuccessAt = CASE WHEN ? THEN ? ELSE lastSuccessAt END,
                    updatedAt = ?
                WHERE id = ?
                """,
            arguments: [now, outcome.rawValue, success, now, now, subscriptionId]
        )
    }

    // MARK: - Baseline

    /// Writes the accepted snapshot: the header (`revision + 1`, the check that produced it), the entry snapshot, and
    /// the seen keys. Every present key is upserted, every other seen key becomes a tombstone, and tombstones beyond
    /// the limit are pruned oldest first. Only rows that changed are written.
    @discardableResult
    static func accept(
        _ write: BaselineWrite,
        observation: CatalogObservation,
        subscription: SeriesSubscriptionRecord,
        ticket: Int64,
        previous: (record: SubscriptionBaselineRecord, view: SubscriptionBaselineView)?,
        now: Date,
        in db: Database
    ) throws -> SubscriptionBaselineRecord {
        let scopeGeneration = (previous?.record.scopeGeneration ?? 1) + (write.scopeGenerationIncrement ? 1 : 0)
        var record = SubscriptionBaselineRecord(
            subscriptionId: subscription.id,
            incarnation: subscription.incarnation,
            revision: (previous?.record.revision ?? 0) + 1,
            acceptedTicket: ticket,
            scopeGeneration: scopeGeneration,
            acquisition: SubscriptionAcquisition(rawValue: write.fingerprint.acquisition) ?? .mediaUpdate,
            sourceEpoch: write.fingerprint.sourceEpoch,
            pluginVersion: write.fingerprint.pluginVersion,
            chapterABI: write.fingerprint.chapterABI,
            catalogScope: write.fingerprint.catalogScope,
            catalogDigest: write.catalogDigest,
            rowCount: write.rowCount,
            orderConfidence: SubscriptionOrderConfidence(write.orderConfidence),
            highWaterKind: write.highWater?.positionKind,
            highWaterValue: write.highWater?.value,
            maxDateUpdated: write.maxDateUpdated,
            tombstonesTruncated: previous?.record.tombstonesTruncated ?? false,
            entrySnapshot: observation.entrySnapshot,
            acceptedAt: now
        )

        let seen = previous?.view.seen ?? [:]
        let insert = try db.makeStatement(sql: """
            INSERT INTO subscriptionSeenKey
              (subscriptionId, chapterKey, positionKind, positionValue, lastRevision, presentInAccepted, acceptedRank,
               firstSeenScopeGeneration, firstSeenAt)
            VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)
            """)
        let update = try db.makeStatement(sql: """
            UPDATE subscriptionSeenKey
            SET positionKind = ?, positionValue = ?, lastRevision = ?, presentInAccepted = 1, acceptedRank = ?
            WHERE subscriptionId = ? AND chapterKey = ?
            """)
        // Source order, so a replay writes the rows in the same order.
        for row in observation.rows {
            let key = ScanlatorUTF8(value: row.facts.key)
            guard let evidence = write.seenUpserts[key] else { continue }
            if let known = seen[key] {
                guard known != evidence else { continue }
                try update.execute(arguments: [
                    evidence.position.positionKind.rawValue, evidence.position.value,
                    evidence.lastRevision?.value, evidence.rank, subscription.id, key.value
                ])
            } else {
                try insert.execute(arguments: [
                    subscription.id, key.value, evidence.position.positionKind.rawValue, evidence.position.value,
                    evidence.lastRevision?.value, evidence.rank, scopeGeneration, now
                ])
            }
        }
        let tombstone = try db.makeStatement(sql: """
            UPDATE subscriptionSeenKey SET presentInAccepted = 0, acceptedRank = NULL
            WHERE subscriptionId = ? AND chapterKey = ?
            """)
        for (key, evidence) in seen where evidence.present && write.seenUpserts[key] == nil {
            try tombstone.execute(arguments: [subscription.id, key.value])
        }
        if try pruneTombstones(of: subscription.id, in: db) { record.tombstonesTruncated = true }
        try record.save(db)
        return record
    }

    /// Deletes the oldest tombstones beyond the limit. Returns whether any were deleted.
    private static func pruneTombstones(of subscriptionId: String, in db: Database) throws -> Bool {
        let tombstones = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM subscriptionSeenKey WHERE subscriptionId = ? AND presentInAccepted = 0",
            arguments: [subscriptionId]
        ) ?? 0
        guard tombstones > tombstoneLimit else { return false }
        try db.execute(
            sql: """
                DELETE FROM subscriptionSeenKey
                WHERE subscriptionId = ? AND chapterKey IN (
                    SELECT chapterKey FROM subscriptionSeenKey
                    WHERE subscriptionId = ? AND presentInAccepted = 0
                    ORDER BY firstSeenAt, firstSeenScopeGeneration, chapterKey
                    LIMIT ?
                )
                """,
            arguments: [subscriptionId, subscriptionId, tombstones - tombstoneLimit]
        )
        return true
    }

    // MARK: - Events

    /// Inserts the classified events through the unique identity index. An event that already exists is ignored,
    /// so a replayed observation records nothing twice. Returns the events that were inserted.
    static func insert(
        _ events: [ClassifiedEvent],
        for subscription: SeriesSubscriptionRecord,
        observedCatalogDigest: String,
        scopeGeneration: Int64,
        now: Date,
        in db: Database
    ) throws -> [SubscriptionEventRecord] {
        var inserted: [SubscriptionEventRecord] = []
        for event in events {
            let isTerminal = !event.initialDecision.isOpen
            let record = SubscriptionEventRecord(
                id: UUID().uuidString,
                subscriptionId: subscription.id,
                incarnation: subscription.incarnation,
                kind: event.kind,
                identityKind: event.identity.kind,
                identityValue: event.identity.value,
                qualifier: event.qualifier,
                decision: event.initialDecision,
                pendingReason: nil,
                reviewReason: event.initialDecision == .needsReview ? event.reviewReason : nil,
                candidateKeys: SubscriptionEventRecord.encode(keys: event.candidateKeys),
                candidateRevision: 1,
                approvedKeys: nil,
                decidedKeys: nil,
                previousRevision: event.previousRevision,
                targetRevision: event.targetRevision,
                ordinal: event.ordinal,
                observedCatalogDigest: observedCatalogDigest,
                configGeneration: subscription.configGeneration,
                scopeGeneration: scopeGeneration,
                createdAt: now,
                decidedAt: isTerminal ? now : nil
            )
            try record.insert(db, onConflict: .ignore)
            if db.changesCount == 1 { inserted.append(record) }
        }
        return inserted
    }

    /// A new alternate of a position whose event still waits (for the right group, for a choice, or because the
    /// row is locked) is one more candidate of that event. Its candidate revision grows, so a sheet that showed
    /// the old list is stale, and the event is decided again. The alternate's own event stays recorded.
    static func attachAlternates(
        _ alternates: [SubscriptionEventRecord],
        positions: [ScanlatorUTF8: SubscriptionBaselineView.SeenKey],
        subscription: SeriesSubscriptionRecord,
        in db: Database
    ) throws {
        let waiting: [SubscriptionDecision] = [.awaitingEdition, .needsChoice, .locked]
        for alternate in alternates {
            guard let position = positions[ScanlatorUTF8(value: alternate.identityValue)]?.position else { continue }
            let holders = try SubscriptionEventRecord
                .filter(
                    Column("subscriptionId") == subscription.id
                        && Column("incarnation") == subscription.incarnation
                        && Column("identityKind") == position.kind
                        && Column("identityValue") == position.value
                        && Column("kind") != SubscriptionEventKind.newAlternate.rawValue
                        && waiting.map(\.rawValue).contains(Column("decision"))
                )
                .order(Column("createdAt"), Column("ordinal"), Column("id"))
                .fetchAll(db)
            for var holder in holders {
                var keys = holder.candidates
                guard keys.count < SubscriptionCatalogClassifier.candidateKeyLimit,
                      !keys.contains(where: { ScanlatorUTF8.bytesEqual($0, alternate.identityValue) }) else { continue }
                keys.append(alternate.identityValue)
                holder.candidateKeys = SubscriptionEventRecord.encode(keys: keys)
                holder.candidateRevision += 1
                holder.decision = .undecided
                holder.pendingReason = nil
                try holder.update(db)
            }
        }
    }

    /// Edits and scope changes decide again: events that were waiting for queue or disk room, a group, a choice or an
    /// unlocked row start over under the new configuration. A review stays a review. An event held by the per-run cap
    /// stays held: only the next check commit admits it, so an edit never bypasses the cap.
    static func reopenWaitingEvents(of subscriptionId: String, in db: Database) throws {
        let waiting: [SubscriptionDecision] = [.pending, .awaitingEdition, .needsChoice, .locked]
        try db.execute(
            sql: """
                UPDATE subscriptionEvent SET decision = 'undecided', pendingReason = NULL
                WHERE subscriptionId = ? AND decision IN (\(waiting.map { "'\($0.rawValue)'" }.joined(separator: ",")))
                  AND NOT (decision = 'pending' AND pendingReason = 'runCap')
                """,
            arguments: [subscriptionId]
        )
    }

    /// Window events of an anchor that has moved on are stale; the current anchor's are not.
    static func supersedeWindowEvents(
        of subscriptionId: String,
        exceptQualifier qualifier: String?,
        now: Date,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE subscriptionEvent
                SET decision = 'superseded', pendingReason = NULL, decidedAt = ?
                WHERE subscriptionId = ? AND kind = 'window' AND ifnull(qualifier, '') != ifnull(?, '')
                  AND decision IN (\(openDecisionsSQL))
                """,
            arguments: [now, subscriptionId, qualifier]
        )
    }

    /// Stores what became of an event. `decidedKeys` is stored exactly for `enqueued` and `satisfied`, the only
    /// decisions that carry them; an open decision keeps no decision time.
    static func settle(
        _ event: SubscriptionEventRecord,
        as decision: SubscriptionDecision,
        pending: SubscriptionPendingReason? = nil,
        review: SubscriptionReviewReason? = nil,
        decidedKeys: [String]? = nil,
        approvedKeys: [String]? = nil,
        now: Date,
        in db: Database
    ) throws {
        var updated = event
        updated.decision = decision
        updated.pendingReason = decision == .pending ? pending : nil
        if decision == .needsReview { updated.reviewReason = review ?? event.reviewReason }
        updated.decidedKeys = (decision == .enqueued || decision == .satisfied)
            ? SubscriptionEventRecord.encode(keys: decidedKeys ?? [])
            : nil
        if let approvedKeys { updated.approvedKeys = SubscriptionEventRecord.encode(keys: approvedKeys) }
        updated.decidedAt = decision.isOpen ? nil : now
        try updated.update(db)
    }

    /// Keeps at most `terminalEventLimit` terminal events, dropping the oldest by decision time.
    static func pruneTerminalEvents(of subscriptionId: String, in db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM subscriptionEvent
                WHERE id IN (
                    SELECT id FROM subscriptionEvent
                    WHERE subscriptionId = ?
                      AND decision NOT IN (\(openDecisionsSQL))
                    ORDER BY ifnull(decidedAt, createdAt) DESC, createdAt DESC, id DESC
                    LIMIT -1 OFFSET ?
                )
                """,
            arguments: [subscriptionId, terminalEventLimit]
        )
    }

    // MARK: - Evidence

    /// Discards everything a subscription learned: open events are revoked, and the baseline and the seen keys are
    /// deleted. The next observation is a first baseline again. Terminal events stay as history.
    static func discardEvidence(of subscriptionId: String, now: Date, in db: Database) throws {
        try db.execute(
            sql: """
                UPDATE subscriptionEvent
                SET decision = 'revoked', pendingReason = NULL, decidedAt = ?
                WHERE subscriptionId = ? AND decision IN (\(openDecisionsSQL))
                """,
            arguments: [now, subscriptionId]
        )
        try db.execute(sql: "DELETE FROM subscriptionBaseline WHERE subscriptionId = ?", arguments: [subscriptionId])
        try db.execute(sql: "DELETE FROM subscriptionSeenKey WHERE subscriptionId = ?", arguments: [subscriptionId])
    }
}
