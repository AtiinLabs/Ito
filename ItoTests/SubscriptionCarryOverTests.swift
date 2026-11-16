import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// The S6a carry-overs: a restore never leaves a rule without its series (A7), the idempotency of window events does
/// not depend on how many other events were raised since (A8), and a rule paused by a restore or a source change is
/// resumed only through review (A9).
struct SubscriptionCarryOverTests {
    private static let restoreDate = Date(timeIntervalSince1970: 5_000)

    private func numbered(_ numbers: some Sequence<Int>) -> [Chapter] {
        SubscriptionLedgerFixture.numbered(numbers)
    }

    // MARK: - A7: a restore releases the rules of the series it removes

    /// A saved series with a rule, an automatic-only job that is being staged, an automatic job a person also asked
    /// for, and a verified copy of another chapter.
    private func seedSubscribedSeries(_ f: SubscriptionLedgerFixture) async throws -> (autoOnly: String, mixed: String) {
        try await f.enable()
        try await f.check(numbered(1...2))
        try await f.check(numbered(1...4))
        let jobs = try await f.jobs()
        let autoOnly = try #require(jobs.first { $0.chapterKey == "c3" })
        let mixed = try #require(jobs.first { $0.chapterKey == "c4" })
        // A person asks for c4 too: the job keeps one automatic and one manual owner.
        let attach = try await f.store.enqueueBatch(
            DownloadBatchRequest(
                pluginId: f.media.pluginId, mediaKind: f.media.mediaKind, canonicalMediaId: f.media.canonicalMediaId,
                entry: .manga(Manga(key: f.media.canonicalMediaId, title: "Series")), seriesTitle: "Series",
                provenance: .builtIn(.next5), selection: DownloadBatchRecord.sourceListSelection,
                catalogDigest: String(repeating: "c", count: 64), chapters: [OfflineStoreFixture.chapter("c4")]
            ),
            sourceEpoch: OfflineStoreFixture.epoch
        )
        #expect(attach.alreadyQueued == 1)
        // The automatic-only job is being staged when the restore comes.
        _ = try await f.store.beginAttempt(jobID: autoOnly.id)
        // Files exist that no rule owns.
        try await f.publishedCopy(SubscriptionLedgerFixture.chapter("saved", unit: "usaved", order: 5))
        return (autoOnly.id, mixed.id)
    }

    private func expectReleased(_ f: SubscriptionLedgerFixture, autoOnly: String, mixed: String) async throws {
        #expect(try await f.pool.read { db in try SeriesSubscriptionRecord.fetchCount(db) } == 0)
        #expect(try await f.store.job(id: autoOnly) == nil)
        let survivor = try #require(try await f.store.job(id: mixed))
        let owners = try await f.owners(of: survivor.id)
        #expect(owners.count == 1 && owners.first?.ownerKind == .manual)
        // Files are never touched.
        #expect(try await f.store.verifiedEdition(for: OfflineChapterEdition(media: f.media, chapterKey: "saved")) != nil)
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func aWipeRestoreThatRemovesTheSeriesReleasesItsRuleAndOnlyTheJobsNobodyElseAskedFor() async throws {
        let f = try await SubscriptionLedgerFixture()
        let (autoOnly, mixed) = try await seedSubscribedSeries(f)

        // A backup that carries a Library with no series: a wipe removes every item.
        let backup = ImportedBackup(
            metadata: BackupMetadataRecord(formatVersion: 1, createdAt: Self.restoreDate),
            capabilities: [BackupCapabilityRecord(component: .libraryCore, representation: .representedEmpty)]
        )
        _ = try await ComponentAwareBackupRestoreOperation(
            dbPool: f.pool, standardApplicationDomain: "test.app", operationIdProvider: { "release" },
            now: { Self.restoreDate }
        ).restore(backup, mode: .wipe)

        #expect(try await f.pool.read { db in try LibraryItem.fetchCount(db) } == 0)
        try await expectReleased(f, autoOnly: autoOnly, mixed: mixed)
    }

    @Test func aWipeThroughTheMergeOperationReleasesTheRuleToo() async throws {
        let f = try await SubscriptionLedgerFixture()
        let (autoOnly, mixed) = try await seedSubscribedSeries(f)

        _ = try await BackupMergeOperation(dbPool: f.pool).restore(
            ImportedBackup(categories: [], items: [], links: [], history: []), mode: .wipe
        )

        #expect(try await f.pool.read { db in try LibraryItem.fetchCount(db) } == 0)
        try await expectReleased(f, autoOnly: autoOnly, mixed: mixed)
    }

    @Test func aMergeRestoreNeverDeletesASeriesSoItLeavesTheRulesAndTheirJobsAsTheyWere() async throws {
        let f = try await SubscriptionLedgerFixture()
        _ = try await seedSubscribedSeries(f)
        let rules = try await f.pool.read { db in try SeriesSubscriptionRecord.fetchAll(db) }
        let jobs = try await f.jobSignatures()
        let owners = try await f.pool.read { db in try DownloadJobOwnerRecord.fetchCount(db) }

        _ = try await BackupMergeOperation(dbPool: f.pool).restore(
            ImportedBackup(categories: [], items: [], links: [], history: []), mode: .merge
        )
        _ = try await ComponentAwareBackupRestoreOperation(
            dbPool: f.pool, standardApplicationDomain: "test.app", operationIdProvider: { "merge" },
            now: { Self.restoreDate }
        ).restore(
            ImportedBackup(
                metadata: BackupMetadataRecord(formatVersion: 1, createdAt: Self.restoreDate),
                capabilities: [BackupCapabilityRecord(component: .libraryCore, representation: .representedEmpty)]
            ),
            mode: .merge
        )

        #expect(try await f.pool.read { db in try SeriesSubscriptionRecord.fetchAll(db) } == rules)
        #expect(try await f.jobSignatures() == jobs)
        #expect(try await f.pool.read { db in try DownloadJobOwnerRecord.fetchCount(db) } == owners)
        try await f.expectEveryJobHasAnOwner()
    }

    // MARK: - A8: window idempotency does not depend on retention luck

    private func readState(_ f: SubscriptionLedgerFixture, read: [String], last: String) async throws {
        let media = f.media
        try await f.write { db in
            for key in read {
                try ReadProgressKeyRecord(
                    pluginId: media.pluginId, canonicalMediaId: media.canonicalMediaId, mediaKind: media.mediaKind,
                    chapterKey: key, markedAt: nil, provenance: nil
                ).save(db)
            }
            try MediaReadProgressRecord(
                pluginId: media.pluginId, canonicalMediaId: media.canonicalMediaId, mediaKind: media.mediaKind,
                lastReadChapterKey: last, updatedAt: nil, provenance: nil, lastReadPosition: nil, readerViewer: nil
            ).save(db)
        }
    }

    private func insertTerminalEvents(
        _ f: SubscriptionLedgerFixture,
        subscriptionId: String,
        count: Int,
        decidedAt: Date
    ) async throws {
        try await f.write { db in
            for index in 0..<count {
                try SubscriptionEventRecord(
                    id: UUID().uuidString, subscriptionId: subscriptionId, incarnation: 1, kind: .newPosition,
                    identityKind: .exact, identityValue: "history-\(index)", qualifier: nil, decision: .dismissed,
                    pendingReason: nil, reviewReason: nil, candidateKeys: SubscriptionEventRecord.encode(keys: ["x"]),
                    candidateRevision: 1, approvedKeys: nil, decidedKeys: nil, previousRevision: nil,
                    targetRevision: nil, ordinal: index, observedCatalogDigest: String(repeating: "d", count: 64),
                    configGeneration: 1, scopeGeneration: 1,
                    createdAt: decidedAt.addingTimeInterval(Double(index)), decidedAt: decidedAt.addingTimeInterval(Double(index))
                ).insert(db)
            }
        }
    }

    @Test func theCurrentAnchorsWindowEventsSurvivePruningSoACancelledPositionStaysCancelled() async throws {
        let f = try await SubscriptionLedgerFixture()
        let id = try await f.enable(SubscriptionConfiguration(mode: .maintainNextUnread, windowSize: 2)).id
        try await readState(f, read: ["c1", "c2"], last: "c2")
        try await f.check(numbered(1...6))
        let window = try await f.events(.window)
        #expect(window.map(\.identityValue) == ["u3", "u4"])
        let currentQualifier = try #require(window.first?.qualifier)

        // The person cancels one; under this anchor it must stay cancelled.
        let cancelled = try #require(try await f.jobs().first { $0.chapterKey == "c3" })
        try await f.store.cancel(jobID: cancelled.id)
        // An event of an anchor that has moved on, long settled, and 600 newer events of other kinds.
        try await f.write { db in
            try db.execute(
                sql: """
                    INSERT INTO subscriptionEvent
                      (id, subscriptionId, incarnation, kind, identityKind, identityValue, qualifier, decision, candidateKeys,
                       candidateRevision, ordinal, observedCatalogDigest, configGeneration, scopeGeneration, createdAt, decidedAt)
                    VALUES (?, ?, 1, 'window', 'exact', 'u9', 'oldanchor', 'superseded', '[]', 1, 0, ?, 1, 1, ?, ?)
                    """,
                arguments: [UUID().uuidString, id, String(repeating: "d", count: 64), Self.restoreDate, Self.restoreDate]
            )
        }
        try await insertTerminalEvents(
            f, subscriptionId: id, count: 600, decidedAt: Self.restoreDate.addingTimeInterval(10_000)
        )

        // The next checks prune: the current anchor's events stay and nothing is created for the cancelled position.
        try await f.check(numbered(1...6))
        try await f.check(numbered(1...6))
        _ = try await f.store.drainSubscriptionEvents(subscriptionId: id, limits: SubscriptionLedgerFixture.roomy)

        let after = try await f.events(.window)
        #expect(after.filter { $0.qualifier == currentQualifier }.map(\.identityValue) == ["u3", "u4"])
        #expect(after.filter { $0.qualifier == currentQualifier }.allSatisfy { $0.decision == .enqueued })
        // An old anchor's events are pruned like any other.
        #expect(!after.contains { $0.qualifier == "oldanchor" })
        #expect(try await f.events(.newPosition).count == SubscriptionLedger.terminalEventLimit)
        // And no job came back for the cancelled position.
        #expect(try await f.jobs().map(\.chapterKey) == ["c4"])
        try await f.expectEveryJobHasAnOwner()
    }

    // MARK: - A9: resuming a reviewed pause requires review

    private struct Paused {
        let f: SubscriptionLedgerFixture
        let id: String
        let generation: Int64
    }

    private func pausedAfterRestore() async throws -> Paused {
        let f = try await SubscriptionLedgerFixture()
        let id = try await f.enable(SubscriptionConfiguration(perRunPositionCap: 3)).id
        try await f.check(numbered(1...3))
        try await f.write { db in
            try OfflineChapterStore.quarantineSubscriptionsAfterRestore(now: Self.restoreDate, in: db)
        }
        let rule = try await f.subscription()
        #expect(rule.state == .paused && rule.pauseReason == .restored)
        return Paused(f: f, id: id, generation: rule.configGeneration)
    }

    private func resume(
        _ paused: Paused,
        generation: Int64? = nil,
        epoch: String? = nil,
        configuration: SubscriptionConfiguration? = nil
    ) async throws -> SubscriptionResumeOutcome {
        try await paused.f.store.resumeSubscription(SubscriptionResumeRequest(
            subscriptionId: paused.id, expectedConfigGeneration: generation ?? paused.generation,
            reviewedSourceEpoch: epoch, configuration: configuration
        ))
    }

    @Test func aRestoredRuleIsResumedOnlyWithItsReviewedConfigurationUnderTheCurrentEpochAndASavedSeries() async throws {
        let paused = try await pausedAfterRestore()
        let f = paused.f
        let reviewed = SubscriptionConfiguration(mode: .newAndFillUnread, perRunPositionCap: 7)
        let epoch = OfflineStoreFixture.epoch
        let before = try await f.subscription()

        // Without the review: nothing changes.
        #expect(try await resume(paused) == .reviewRequired)
        #expect(try await resume(paused, epoch: epoch) == .reviewRequired)
        #expect(try await resume(paused, configuration: reviewed) == .reviewRequired)
        // A sheet that was open during another change is stale, whatever else it carries.
        #expect(try await resume(paused, generation: paused.generation - 1, epoch: epoch, configuration: reviewed) == .stale)
        // The source's settings changed after the review.
        #expect(try await resume(paused, epoch: OfflineStoreFixture.rotatedEpoch, configuration: reviewed) == .sourceChanged)
        // A configuration the database would refuse.
        let invalid = SubscriptionConfiguration(mode: .maintainNextUnread, windowSize: nil)
        #expect(try await resume(paused, epoch: epoch, configuration: invalid) == .invalidConfiguration)
        // The series left the Library.
        let item = try #require(try await f.pool.read { db in try LibraryItem.fetchAll(db).first })
        try await f.write { db in _ = try LibraryItem.deleteOne(db, key: item.id) }
        #expect(try await resume(paused, epoch: epoch, configuration: reviewed) == .seriesNotSaved)
        try await f.write { db in try item.insert(db) }
        #expect(try await f.subscription() == before)

        // The review: enabled with the reviewed rule under a new generation, waiting for its first baseline.
        let outcome = try await resume(paused, epoch: epoch, configuration: reviewed)
        #expect(outcome == .resumed(configGeneration: paused.generation + 1))
        let rule = try await f.subscription()
        #expect(rule.state == .enabled && rule.pauseReason == nil)
        #expect(rule.mode == .newAndFillUnread && rule.perRunPositionCap == 7)
        #expect(rule.configGeneration == paused.generation + 1 && rule.incarnation == before.incarnation)
        #expect(rule.lastAttemptAt == nil && rule.lastAttemptOutcome == nil && rule.lastSuccessAt == nil)
        // A resume never creates evidence, an event or a job.
        #expect(try await f.baseline() == nil)
        #expect(try await f.events().isEmpty)
        #expect(try await f.jobs().isEmpty)
        try await f.expectEveryJobHasAnOwner()
    }

    @Test func aRuleWhoseSourceWasRemappedNeedsTheSameReview() async throws {
        let f = try await SubscriptionLedgerFixture()
        let id = try await f.enable().id
        let source = f.media
        let destination = MediaIdentity(pluginId: source.pluginId, canonicalMediaId: "series-2", mediaKind: .manga)
        try await f.write { db in
            try OfflineChapterStore.rekeySubscription(from: source, to: destination, now: Self.restoreDate, in: db)
        }
        let rule = try #require(try await f.store.subscription(for: destination))
        #expect(rule.state == .paused && rule.pauseReason == .sourceRemapped)

        let missingReview = try await f.store.resumeSubscription(SubscriptionResumeRequest(
            subscriptionId: id, expectedConfigGeneration: rule.configGeneration, reviewedSourceEpoch: nil, configuration: nil
        ))
        #expect(missingReview == .reviewRequired)
    }

    @Test func aRuleThePersonPausedIsResumedAsItWasAndAnEditIsNotAResume() async throws {
        let f = try await SubscriptionLedgerFixture()
        let id = try await f.enable().id
        try await f.check(numbered(1...2))
        let baseline = try #require(try await f.baseline())
        _ = try await f.store.pauseSubscription(id: id)
        let generation = try await f.subscription().configGeneration

        // A configuration is an edit's business.
        let refused = try await f.store.resumeSubscription(SubscriptionResumeRequest(
            subscriptionId: id, expectedConfigGeneration: generation, reviewedSourceEpoch: nil,
            configuration: SubscriptionConfiguration(perRunPositionCap: 9)
        ))
        #expect(refused == .reviewRequired)
        #expect(try await f.subscription().state == .paused)
        let stale = try await f.store.resumeSubscription(SubscriptionResumeRequest(
            subscriptionId: id, expectedConfigGeneration: generation + 1, reviewedSourceEpoch: nil, configuration: nil
        ))
        #expect(stale == .stale)

        let resumed = try await f.store.resumeSubscription(SubscriptionResumeRequest(
            subscriptionId: id, expectedConfigGeneration: generation, reviewedSourceEpoch: nil, configuration: nil
        ))
        #expect(resumed == .resumed(configGeneration: generation))
        let rule = try await f.subscription()
        #expect(rule.state == .enabled && rule.configGeneration == generation)
        // Its baseline is kept, and its last attempt with it.
        #expect(try await f.baseline() == baseline)
        #expect(rule.lastAttemptOutcome == .baselineEstablished)
    }

    @Test func aRuleThatIsNotPausedOrDoesNotExistCannotBeResumed() async throws {
        let f = try await SubscriptionLedgerFixture()
        let id = try await f.enable().id
        let generation = try await f.subscription().configGeneration

        let enabled = try await f.store.resumeSubscription(SubscriptionResumeRequest(
            subscriptionId: id, expectedConfigGeneration: generation, reviewedSourceEpoch: nil, configuration: nil
        ))
        #expect(enabled == .unavailable)
        let missing = try await f.store.resumeSubscription(SubscriptionResumeRequest(
            subscriptionId: UUID().uuidString, expectedConfigGeneration: 1, reviewedSourceEpoch: nil, configuration: nil
        ))
        #expect(missing == .unavailable)
    }
}
