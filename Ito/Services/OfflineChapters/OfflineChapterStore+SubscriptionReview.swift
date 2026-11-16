import Foundation
import GRDB
import ito_runner

/// The reads and the one claim the screens of automatic downloads need. Every read writes nothing. The claim is the
/// only writer of `subscriptionEvent.notifiedAt`.
extension OfflineChapterStore {
    // MARK: - Reviews

    /// The open events of a rule that wait for a person, oldest first, at most `SubscriptionAttention.limit`, with the
    /// total. The candidate rows come from the accepted catalog's frozen entry, which is decoded here, off the main
    /// actor, for this one rule.
    func subscriptionAttention(subscriptionId: String) async throws -> SubscriptionAttention {
        try await database.read { db in
            guard let subscription = try SubscriptionLedger.subscription(id: subscriptionId, in: db),
                  subscription.state != .disabled else { return SubscriptionAttention(events: [], totalCount: 0) }
            let attention = [SubscriptionDecision.needsChoice, .needsReview].map(\.rawValue)
            let filter = Column("subscriptionId") == subscriptionId
                && Column("incarnation") == subscription.incarnation
                && attention.contains(Column("decision"))
            let total = try SubscriptionEventRecord.filter(filter).fetchCount(db)
            let events = try SubscriptionEventRecord
                .filter(filter)
                .order(Column("createdAt"), Column("ordinal"), Column("id"))
                .limit(SubscriptionAttention.limit)
                .fetchAll(db)
            let chapters = try Self.chaptersByKey(of: subscriptionId, in: db)
            return SubscriptionAttention(
                events: events.map { event in
                    SubscriptionEventReview(
                        eventId: event.id,
                        kind: event.kind,
                        identityKind: event.identityKind,
                        decision: event.decision,
                        reviewReason: event.reviewReason,
                        candidates: event.candidates.map { Self.candidateRow(key: $0, chapters: chapters) },
                        incarnation: event.incarnation,
                        configGeneration: subscription.configGeneration,
                        candidateRevision: event.candidateRevision
                    )
                },
                totalCount: total
            )
        }
    }

    private nonisolated static func chaptersByKey(
        of subscriptionId: String,
        in db: Database
    ) throws -> [ScanlatorUTF8: Chapter] {
        guard let record = try SubscriptionLedger.baselineRecord(of: subscriptionId, in: db),
              let catalog = try? SubscriptionAcceptedCatalog(record: record) else { return [:] }
        var result: [ScanlatorUTF8: Chapter] = [:]
        for chapter in catalog.chapters { result[ScanlatorUTF8(value: chapter.key)] = chapter }
        return result
    }

    private nonisolated static func candidateRow(
        key: String,
        chapters: [ScanlatorUTF8: Chapter]
    ) -> SubscriptionCandidateRow {
        guard let chapter = chapters[ScanlatorUTF8(value: key)] else {
            return SubscriptionCandidateRow(key: key, title: nil, number: nil, volume: nil, scanlator: nil, isLocked: false)
        }
        return SubscriptionCandidateRow(
            key: key, title: chapter.title, number: chapter.chapterNumber, volume: chapter.volumeNumber,
            scanlator: chapter.scanlator, isLocked: chapter.paywalled == true
        )
    }

    // MARK: - Backfill

    /// What approving every unread chapter of a rule that fills unread chapters would queue. It reads the accepted
    /// baseline and the exact read state, writes nothing and asks no source. Number-only read markers never say which
    /// exact row was read, so they refuse the preview.
    func subscriptionBackfillPreview(subscriptionId: String) async throws -> SubscriptionBackfillPreview {
        try await database.read { db in
            guard let subscription = try SubscriptionLedger.subscription(id: subscriptionId, in: db),
                  subscription.state == .enabled,
                  let record = try SubscriptionLedger.baselineRecord(of: subscriptionId, in: db),
                  record.incarnation == subscription.incarnation else {
                throw SubscriptionBackfillRefusal.unavailable
            }
            guard subscription.mode == .newAndFillUnread else { throw SubscriptionBackfillRefusal.unsupportedMode }
            guard let selection = subscription.decodedSelection else { throw SubscriptionBackfillRefusal.selectionUnreadable }
            guard let catalog = try? SubscriptionAcceptedCatalog(record: record) else {
                throw SubscriptionBackfillRefusal.catalogUnreadable
            }
            let readState = try SubscriptionLedger.readState(for: subscription.media, in: db)
            if readState.hasNumberOnlyMarkers { throw SubscriptionBackfillRefusal.numberOnlyReadState }
            let stored = try Self.storedStates(for: subscription.media, in: db)
            let planRows = catalog.rows.map { row in
                DownloadPlanRow(
                    facts: row.facts,
                    isRead: readState.readKeys.contains(ScanlatorUTF8(value: row.facts.key)),
                    stored: stored[ScanlatorUTF8(value: row.facts.key)] ?? .none
                )
            }
            let plan = DownloadPresetResolver.plan(rows: planRows, window: .unread, selection: selection, anchorKey: nil)

            var order: [EditionPositionKey] = []
            var keys: [EditionPositionKey: [String]] = [:]
            for index in plan.toQueue {
                let facts = planRows[index].facts
                let position = EditionPositionKey(facts)
                if keys[position] == nil { order.append(position) }
                keys[position, default: []].append(facts.key)
            }
            let positions = order.map { keys[$0] ?? [] }
            let shown = Array(positions.prefix(SubscriptionBackfillPreview.positionLimit))
            let chapters = Dictionary(
                catalog.chapters.map { (ScanlatorUTF8(value: $0.key), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var rows: [String: SubscriptionCandidateRow] = [:]
            for key in shown.joined() { rows[key] = Self.candidateRow(key: key, chapters: chapters) }
            return SubscriptionBackfillPreview(
                subscriptionId: subscriptionId,
                incarnation: subscription.incarnation,
                configGeneration: subscription.configGeneration,
                baselineRevision: record.revision,
                catalogDigest: record.catalogDigest,
                positions: shown,
                truncatedCount: positions.count - shown.count,
                issues: plan.issues,
                rows: rows
            )
        }
    }

    // MARK: - Usage

    /// How much of the queue and the disk the stored copies and the jobs use. A plain read.
    func automaticUsage() async throws -> (storedBytes: Int64, queuedJobs: Int) {
        try await database.read { db in
            (
                try Self.storedBytes(in: db),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloadJob") ?? 0
            )
        }
    }

    // MARK: - Notification claim

    /// Records, once per event, that the decision to notify was taken: every open `needsChoice` or `needsReview` event
    /// of an enabled rule that was not claimed yet gets `notifiedAt = now`. It is made whether or not a notification
    /// can be posted, so turning the setting on later never announces what was already waiting. Returns one claim per
    /// rule that had events claimed now.
    func claimSubscriptionAttention(now: Date) async throws -> [SubscriptionAttentionClaim] {
        try await database.write { db in
            let attention = [SubscriptionDecision.needsChoice, .needsReview].map { "'\($0.rawValue)'" }.joined(separator: ",")
            let claimed = try Row.fetchAll(
                db,
                sql: """
                    SELECT e.id AS id, e.subscriptionId AS subscriptionId FROM subscriptionEvent e
                    JOIN seriesSubscription s ON s.id = e.subscriptionId AND s.incarnation = e.incarnation
                    WHERE s.state = 'enabled' AND e.decision IN (\(attention)) AND e.notifiedAt IS NULL
                    ORDER BY e.subscriptionId, e.createdAt, e.id
                    """
            )
            guard !claimed.isEmpty else { return [] }
            var perRule: [String: Int] = [:]
            var order: [String] = []
            for row in claimed {
                let subscriptionId: String = row["subscriptionId"]
                if perRule[subscriptionId] == nil { order.append(subscriptionId) }
                perRule[subscriptionId, default: 0] += 1
                try db.execute(
                    sql: "UPDATE subscriptionEvent SET notifiedAt = ? WHERE id = ? AND notifiedAt IS NULL",
                    arguments: [now, row["id"] as String]
                )
            }
            return try order.compactMap { subscriptionId -> SubscriptionAttentionClaim? in
                guard let subscription = try SubscriptionLedger.subscription(id: subscriptionId, in: db) else { return nil }
                let open = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM subscriptionEvent
                        WHERE subscriptionId = ? AND incarnation = ? AND decision IN (\(attention))
                        """,
                    arguments: [subscriptionId, subscription.incarnation]
                ) ?? 0
                return SubscriptionAttentionClaim(
                    subscriptionId: subscriptionId,
                    title: try Self.libraryTitle(of: subscription.media, in: db),
                    incarnation: subscription.incarnation,
                    configGeneration: subscription.configGeneration,
                    newlyClaimed: perRule[subscriptionId] ?? 0,
                    openAttention: open
                )
            }
        }
    }

    /// The Library title of a series, matched by its media identity; nil when it is not in the Library.
    nonisolated static func libraryTitle(of media: MediaIdentity, in db: Database) throws -> String? {
        let candidates = ImportedMediaIdentity.localItemIDs(
            pluginId: media.pluginId, canonicalMediaId: media.canonicalMediaId, mediaKind: media.mediaKind
        )
        for id in candidates {
            if let item = try LibraryItem.fetchOne(db, key: id), item.mediaIdentity == media { return item.title }
        }
        return nil
    }
}
