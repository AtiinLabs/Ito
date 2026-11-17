import Foundation
import GRDB
import ito_runner

/// The rows of every rule, read in one transaction. It reads the rules, the header of each baseline (never the entry
/// snapshot or the seen keys), the open events grouped by decision, the jobs each rule owns, and the titles of the
/// Library items the rules are about. It writes nothing and asks no source for anything.
nonisolated enum SubscriptionRuleReadModel {
    /// - Parameter quotaBytes: the space automatic downloads may fill; a queued automatic job waits once the stored
    ///   bytes reach it.
    static func read(_ db: Database, quotaBytes: Int64) throws -> [SubscriptionRuleRow] {
        let rules = try SeriesSubscriptionRecord.order(Column("id")).fetchAll(db)
        guard !rules.isEmpty else { return [] }

        var baselines: [String: (incarnation: Int64, acceptedAt: Date)] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT subscriptionId, incarnation, acceptedAt FROM subscriptionBaseline") {
            baselines[row["subscriptionId"]] = (row["incarnation"], row["acceptedAt"])
        }

        var attention: [String: Int] = [:]
        var pending: [String: [SubscriptionPendingReason: Int]] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT e.subscriptionId AS subscriptionId, e.decision AS decision, e.pendingReason AS pendingReason,
                       COUNT(*) AS total
                FROM subscriptionEvent e
                JOIN seriesSubscription s ON s.id = e.subscriptionId AND s.incarnation = e.incarnation
                WHERE e.decision IN ('needsChoice', 'needsReview', 'pending')
                GROUP BY e.subscriptionId, e.decision, e.pendingReason
                """
        ) {
            let id: String = row["subscriptionId"]
            let total: Int = row["total"]
            switch SubscriptionDecision(rawValue: row["decision"] as String) {
            case .needsChoice?, .needsReview?:
                attention[id, default: 0] += total
            case .pending?:
                if let reason = (row["pendingReason"] as String?).flatMap(SubscriptionPendingReason.init(rawValue:)) {
                    pending[id, default: [:]][reason, default: 0] += total
                }
            default:
                break
            }
        }

        let admitted = try OfflineChapterStore.storedBytes(in: db) < quotaBytes
        var queued: [String: Int] = [:]
        var held: [String: (count: Int, reason: DownloadHoldReason)] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT o.subscriptionId AS subscriptionId, j.state AS state, j.waitingReason AS waitingReason,
                       EXISTS (SELECT 1 FROM downloadJobOwner m WHERE m.jobId = j.id AND m.ownerKind = 'manual') AS hasManual,
                       EXISTS (
                           SELECT 1 FROM downloadJobOwner e JOIN seriesSubscription es ON es.id = e.subscriptionId
                           WHERE e.jobId = j.id AND es.state = 'enabled' AND es.incarnation = e.subscriptionIncarnation
                       ) AS hasEnabledOwner
                FROM downloadJobOwner o JOIN downloadJob j ON j.id = o.jobId
                WHERE o.ownerKind = 'subscription'
                """
        ) {
            let id: String = row["subscriptionId"]
            guard let state = DownloadJobState(rawValue: row["state"] as String), state != .failed else { continue }
            queued[id, default: 0] += 1
            guard !(row["hasManual"] as Bool) else { continue }
            let reason: DownloadHoldReason?
            switch state {
            case .queued:
                if !(row["hasEnabledOwner"] as Bool) {
                    reason = .automaticRulePaused
                } else {
                    reason = admitted ? nil : .automaticSpaceFull
                }
            case .waiting:
                reason = (row["waitingReason"] as String?) == DownloadWaitingReason.meteredNetwork.rawValue
                    ? .automaticMeteredNotAllowed : nil
            case .downloading, .failed:
                reason = nil
            }
            if let reason {
                // One reason for the rule, whatever order its jobs are read in: the most basic one wins.
                let kept = held[id]?.reason
                held[id] = ((held[id]?.count ?? 0) + 1, kept.map { $0.priority <= reason.priority ? $0 : reason } ?? reason)
            }
        }

        let titles = try libraryTitles(of: rules.map(\.media), in: db)
        return rules.map { rule in
            let baseline = baselines[rule.id].flatMap { $0.incarnation == rule.incarnation ? $0 : nil }
            return SubscriptionRuleRow(
                id: rule.id,
                media: rule.media,
                title: titles[rule.media],
                state: rule.state,
                pauseReason: rule.pauseReason,
                configuration: rule.configuration,
                incarnation: rule.incarnation,
                configGeneration: rule.configGeneration,
                hasBaseline: baseline != nil,
                baselineAcceptedAt: baseline?.acceptedAt,
                lastAttemptAt: rule.lastAttemptAt,
                lastAttemptOutcome: rule.lastAttemptOutcome,
                lastSuccessAt: rule.lastSuccessAt,
                attentionCount: attention[rule.id] ?? 0,
                pending: pending[rule.id] ?? [:],
                queuedJobs: queued[rule.id] ?? 0,
                heldJobs: held[rule.id]?.count ?? 0,
                heldReason: held[rule.id]?.reason,
                sourceInstalled: true
            )
        }
    }

    /// The titles of the Library items these series are, matched by media identity in Swift.
    private static func libraryTitles(of media: [MediaIdentity], in db: Database) throws -> [MediaIdentity: String] {
        var wanted = Set<MediaIdentity>(media)
        var ids = Set<String>()
        for identity in wanted {
            ids.formUnion(ImportedMediaIdentity.localItemIDs(
                pluginId: identity.pluginId, canonicalMediaId: identity.canonicalMediaId, mediaKind: identity.mediaKind
            ))
        }
        var result: [MediaIdentity: String] = [:]
        for chunk in Array(ids).chunked(into: 500) {
            let marks = databaseQuestionMarks(count: chunk.count)
            for row in try Row.fetchAll(
                db,
                sql: "SELECT id, title, pluginId, isAnime, pluginType FROM libraryItem WHERE id IN (\(marks))",
                arguments: StatementArguments(chunk)
            ) {
                let kind = (row["pluginType"] as String?).flatMap(MediaKind.init(rawValue:))
                    ?? ((row["isAnime"] as Bool) ? .anime : .manga)
                let identity = MediaIdentity(pluginId: row["pluginId"], itemId: row["id"], mediaKind: kind)
                if wanted.remove(identity) != nil { result[identity] = row["title"] as String }
            }
        }
        return result
    }
}

nonisolated extension SeriesSubscriptionRecord {
    /// The behaviour the row stores, or nil when its choice of groups cannot be read by this build.
    var configuration: SubscriptionConfiguration? {
        guard let selection = decodedSelection else { return nil }
        return SubscriptionConfiguration(
            mode: mode, windowSize: windowSize, perRunPositionCap: perRunPositionCap,
            selection: selection, replacementRule: replacementRule
        )
    }
}

private extension Array {
    nonisolated func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
