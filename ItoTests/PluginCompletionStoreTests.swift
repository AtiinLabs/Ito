import Foundation
import GRDB
import Security
import Testing
@testable import Ito

@MainActor
struct PluginCompletionStoreTests {
    // MARK: - Local progress and outbox commit together

    @Test func markingReadSavesProgressAndQueuesOneIntentWithTheOriginalKeys() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let media = MediaIdentity(pluginId: "komga", canonicalMediaId: "local-canonical-1")
        let context = fixture.manager.captureCompletionContext(
            media: media, mediaKey: "/series/42?lang=EN fr", kind: .manga
        )

        try await fixture.manager.markAsRead(context: context, chapterId: "Ch/1 ✓", chapterNum: 1)

        #expect(fixture.manager.isRead(media: media, chapterId: "Ch/1 ✓"))
        #expect(fixture.wakes.count == 1)
        let rows = try await fixture.rows()
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.pluginId == "komga")
        #expect(row.canonicalMediaId == "local-canonical-1")
        #expect(row.mediaKey == "/series/42?lang=EN fr")
        #expect(row.unitKey == "Ch/1 ✓")
        #expect(row.kind == .manga)
        #expect(row.status == .pending)
        #expect(row.pauseReason == nil)
        #expect(row.originatingEpoch == context.originatingEpoch)
        #expect(row.originatingEpoch != nil)
        #expect(row.attemptCount == 0)
    }

    @Test func markingAnEpisodeWatchedQueuesAnAnimeIntent() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let media = MediaIdentity(pluginId: "anime.source", canonicalMediaId: "canon")
        let context = fixture.manager.captureCompletionContext(media: media, mediaKey: "show-9", kind: .anime)

        try await fixture.manager.markAsWatched(context: context, episodeId: "ep-3", episodeNum: 3)

        let row = try #require(try await fixture.rows().first)
        #expect(row.kind == .anime)
        #expect(row.mediaKey == "show-9")
        #expect(row.unitKey == "ep-3")
        #expect(fixture.manager.isRead(media: media, chapterId: "ep-3"))
    }

    @Test func aFailedQueueWriteRollsBackEveryLocalProgressRow() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let media = MediaIdentity(pluginId: "komga", canonicalMediaId: "series")
        let context = fixture.manager.captureCompletionContext(media: media, mediaKey: "series", kind: .manga)
        try await fixture.database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER rejectCompletionInsert BEFORE INSERT ON pluginCompletionOutbox
                BEGIN SELECT RAISE(ABORT, 'rejected'); END
                """)
        }

        await #expect(throws: (any Error).self) {
            try await fixture.manager.markAsRead(context: context, chapterId: "chapter-1", chapterNum: 1)
        }

        let counts = try await fixture.localProgressCounts()
        #expect(counts.keys == 0)
        #expect(counts.numbers == 0)
        #expect(counts.resume == 0)
        #expect(try await fixture.rows().isEmpty)
        #expect(!fixture.manager.isRead(media: media, chapterId: "chapter-1", chapterNum: 1))
        #expect(fixture.manager.lastReadChapter(for: media) == nil)
        #expect(fixture.wakes.count == 0)

        try await fixture.database.dbPool.write { db in
            try db.execute(sql: "DROP TRIGGER rejectCompletionInsert")
        }
        try await fixture.manager.markAsRead(context: context, chapterId: "chapter-1", chapterNum: 1)
        #expect(fixture.manager.isRead(media: media, chapterId: "chapter-1"))
        #expect(try await fixture.rows().count == 1)
        #expect(fixture.wakes.count == 1)
    }

    @Test func aResumedSeriesStillQueuesWithoutMovingTheReadingPlace() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let media = MediaIdentity(pluginId: "komga", canonicalMediaId: "series")
        try await fixture.manager.savePosition(media: media, chapterKey: "chapter-5", position: 7)
        let context = fixture.manager.captureCompletionContext(media: media, mediaKey: "series", kind: .manga)

        try await fixture.manager.markAsRead(context: context, chapterId: "chapter-2", chapterNum: 2)

        #expect(fixture.manager.lastReadChapter(for: media) == "chapter-5")
        #expect(fixture.manager.savedPosition(media: media, chapterKey: "chapter-5") == 7)
        let first = try #require(try await fixture.rows().first)
        #expect(first.unitKey == "chapter-2")
        #expect(first.status == .pending)

        try await fixture.manager.markAsRead(context: context, chapterId: "chapter-2", chapterNum: 2)

        let rows = try await fixture.rows()
        #expect(rows.count == 1)
        #expect(rows[0].id == first.id)
        #expect(rows[0].revision > first.revision)
        #expect(rows[0].status == .pending)
        #expect(fixture.wakes.count == 2)
    }

    @Test func markingAnAlreadyAcknowledgedChapterAgainQueuesAFreshDelivery() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let media = MediaIdentity(pluginId: "komga", canonicalMediaId: "series")
        let context = fixture.manager.captureCompletionContext(media: media, mediaKey: "series", kind: .manga)
        try await fixture.manager.markAsRead(context: context, chapterId: "chapter-1", chapterNum: 1)
        try await fixture.acknowledgeEverything(at: fixture.time(10))
        #expect(try await fixture.rows().isEmpty)

        try await fixture.manager.markAsRead(context: context, chapterId: "chapter-1", chapterNum: 1)

        let rows = try await fixture.rows()
        #expect(rows.count == 1)
        #expect(rows[0].status == .pending)
        #expect(rows[0].revision == 1)
    }

    @Test func aManagerWithoutDeliveryQueuesAPausedUnknownOriginIntent() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let bare = ReadProgressManager(dbPool: fixture.database.dbPool)
        let media = MediaIdentity(pluginId: "komga", canonicalMediaId: "series")
        let context = bare.captureCompletionContext(media: media, mediaKey: "series", kind: .manga)
        #expect(context.originatingEpoch == nil)

        try await bare.markAsRead(context: context, chapterId: "chapter-1", chapterNum: 1)

        #expect(bare.isRead(media: media, chapterId: "chapter-1"))
        let row = try #require(try await fixture.rows().first)
        #expect(row.status == .paused)
        #expect(row.pauseReason == .unknownOrigin)
        #expect(row.originatingEpoch == nil)
        #expect(try await fixture.store.dueIntents(now: fixture.time(1_000)).isEmpty)
        #expect(try await fixture.store.beginAttempt(row, now: fixture.time(1_000)) == nil)
        #expect(PluginCompletionAttempt(row) == nil)
        #expect(throws: PluginCompletionScopeError.configurationChanged) {
            try fixture.store.snapshot(for: row)
        }
        let summaries = try await fixture.store.summaries()
        #expect(summaries == [
            PluginCompletionSummary(pluginID: "komga", pendingCount: 0, pausedCount: 1, pauseReasons: [.unknownOrigin])
        ])
    }

    @Test func unknownOriginMarksOfTheSameUnitShareOneRow() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let context = PluginCompletionContext(
            media: MediaIdentity(pluginId: "komga", canonicalMediaId: "series"),
            mediaKey: "series", kind: .manga, originatingEpoch: nil
        )

        try await fixture.enqueue(context, unit: "ch-1", at: fixture.time(1))
        try await fixture.enqueue(context, unit: "ch-1", at: fixture.time(2))

        let rows = try await fixture.rows()
        #expect(rows.count == 1)
        #expect(rows[0].status == .paused)
        #expect(rows[0].pauseReason == .unknownOrigin)
        #expect(rows[0].revision == 2)
    }

    @Test func aFailedScopeCaptureFailsClosedAsUnknownOrigin() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        try await fixture.database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER rejectScopeInsert BEFORE INSERT ON pluginCompletionScope
                BEGIN SELECT RAISE(ABORT, 'rejected'); END
                """)
        }
        let media = MediaIdentity(pluginId: "brand.new", canonicalMediaId: "series")

        let context = fixture.manager.captureCompletionContext(media: media, mediaKey: "series", kind: .novel)
        try await fixture.manager.markAsRead(context: context, chapterId: "chapter-1")

        #expect(context.originatingEpoch == nil)
        let row = try #require(try await fixture.rows().first)
        #expect(row.status == .paused)
        #expect(row.pauseReason == .unknownOrigin)
        #expect(fixture.manager.isRead(media: media, chapterId: "chapter-1"))
    }

    @Test func corruptScopeMetadataPausesDeliveryAndBlocksReauthorization() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let context = fixture.capture("komga")
        try await fixture.enqueue(context, unit: "ch-1", at: fixture.time(1))
        try await fixture.database.dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try db.execute(sql: "UPDATE pluginCompletionScope SET epoch = 'not-an-epoch' WHERE pluginId = 'komga'")
            try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
        }

        let row = try #require(try await fixture.rows().first)
        #expect(row.status == .paused)
        #expect(row.pauseReason == .configurationChanged)
        #expect(fixture.capture("komga").originatingEpoch == nil)
        try await fixture.enqueue(context, unit: "ch-2", at: fixture.time(2))
        let later = try #require(try await fixture.rows().last)
        #expect(later.unitKey == "ch-2")
        #expect(later.status == .paused)
        #expect(later.pauseReason == .configurationChanged)
        await #expect(throws: PluginCompletionScopeError.invalidMetadata) {
            try await fixture.store.reauthorizePaused(pluginID: "komga", now: fixture.time(3))
        }
        #expect(try await fixture.rows().allSatisfy { $0.status == .paused })
        #expect(try await fixture.store.dueIntents(now: fixture.time(1_000)).isEmpty)
    }

    @Test func aMissingScopeRowPausesQueuedIntentsAndRejectsOldOrigins() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let context = fixture.capture("komga")
        try await fixture.enqueue(context, unit: "ch-1", at: fixture.time(1))

        try await fixture.database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM pluginCompletionScope WHERE pluginId = 'komga'")
        }
        try await fixture.enqueue(context, unit: "ch-2", at: fixture.time(2))

        let rows = try await fixture.rows()
        #expect(rows.map(\.status) == [.paused, .paused])
        #expect(rows.compactMap(\.pauseReason) == [.configurationChanged, .configurationChanged])
        #expect(try await fixture.store.dueIntents(now: fixture.time(1_000)).isEmpty)
        #expect(try await fixture.store.nextAttemptDate() == nil)
    }

    // MARK: - Source and account scope

    @Test func changingASecretPausesPendingIntentsAndStaleAcknowledgementIsIgnored() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let context = fixture.capture("komga")
        try await fixture.enqueue(context, unit: "ch-1", at: fixture.time(1))
        let intent = try #require(try await fixture.store.dueIntents(now: fixture.time(1)).first)
        let attempt = try #require(try await fixture.store.beginAttempt(intent, now: fixture.time(1)))

        #expect(fixture.settings.setSecret(pluginId: "komga", key: "token", value: "other-account"))

        let paused = try #require(try await fixture.rows().first)
        #expect(paused.status == .paused)
        #expect(paused.pauseReason == .configurationChanged)
        #expect(paused.revision > intent.revision)
        try await fixture.store.finish(attempt, outcome: .acknowledged, now: fixture.time(2))
        let afterAck = try #require(try await fixture.rows().first)
        #expect(afterAck.id == intent.id)
        #expect(afterAck.status == .paused)
        #expect(try await fixture.store.dueIntents(now: fixture.time(1_000)).isEmpty)
        #expect(try await fixture.store.beginAttempt(intent, now: fixture.time(2)) == nil)
        #expect(throws: PluginCompletionScopeError.configurationChanged) {
            try fixture.store.snapshot(for: intent)
        }
    }

    @Test func aStaleFailureAfterAScopeChangeCannotRewriteTheIntent() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        #expect(fixture.settings.set(pluginId: "komga", key: "server", value: "https://a.example"))
        let context = fixture.capture("komga")
        try await fixture.enqueue(context, unit: "ch-1", at: fixture.time(1))
        let intent = try #require(try await fixture.store.dueIntents(now: fixture.time(1)).first)
        let attempt = try #require(try await fixture.store.beginAttempt(intent, now: fixture.time(1)))

        #expect(fixture.settings.set(pluginId: "komga", key: "server", value: "https://b.example"))
        try await fixture.store.finish(attempt, outcome: .retryable(.network), now: fixture.time(2))
        try await fixture.store.finish(attempt, outcome: .paused(.credentials, .credentials), now: fixture.time(2))
        try await fixture.store.finish(attempt, outcome: .unsupported, now: fixture.time(2))

        let row = try #require(try await fixture.rows().first)
        #expect(row.status == .paused)
        #expect(row.pauseReason == .configurationChanged)
        #expect(row.attemptCount == 0)
        #expect(row.lastErrorCategory == nil)
    }

    @Test func aStaleAcknowledgementCannotAcknowledgeAReauthorizedReplacement() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let context = fixture.capture("komga")
        try await fixture.enqueue(context, unit: "ch-1", at: fixture.time(1))
        let intent = try #require(try await fixture.store.dueIntents(now: fixture.time(1)).first)
        let stale = try #require(try await fixture.store.beginAttempt(intent, now: fixture.time(1)))
        #expect(fixture.settings.setSecret(pluginId: "komga", key: "token", value: "new-account"))
        try await fixture.store.reauthorizePaused(pluginID: "komga", now: fixture.time(5))

        try await fixture.store.finish(stale, outcome: .acknowledged, now: fixture.time(6))

        let row = try #require(try await fixture.rows().first)
        #expect(row.status == .pending)
        #expect(row.originatingEpoch != context.originatingEpoch)
        let fresh = try #require(try await fixture.store.dueIntents(now: fixture.time(5)).first)
        let attempt = try #require(try await fixture.store.beginAttempt(fresh, now: fixture.time(5)))
        try await fixture.store.finish(attempt, outcome: .acknowledged, now: fixture.time(7))
        #expect(try await fixture.rows().isEmpty)
    }

    @Test func aRemarkDuringAnAttemptInvalidatesThatAttempt() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let context = fixture.capture("komga")
        try await fixture.enqueue(context, unit: "ch-1", at: fixture.time(1))
        let intent = try #require(try await fixture.store.dueIntents(now: fixture.time(1)).first)
        let attempt = try #require(try await fixture.store.beginAttempt(intent, now: fixture.time(1)))

        try await fixture.enqueue(context, unit: "ch-1", at: fixture.time(2))
        try await fixture.store.finish(attempt, outcome: .acknowledged, now: fixture.time(3))

        let row = try #require(try await fixture.rows().first)
        #expect(row.status == .pending)
        #expect(row.revision == intent.revision + 1)
        #expect(throws: PluginCompletionScopeError.configurationChanged) {
            try fixture.store.snapshot(for: intent)
        }
    }

    @Test func plainSettingsChangesPauseButResavingTheSameValueKeepsTheScope() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        #expect(fixture.settings.set(pluginId: "komga", key: "server", value: "https://a.example"))
        let context = fixture.capture("komga")
        try await fixture.enqueue(context, unit: "ch-1", at: fixture.time(1))

        #expect(fixture.settings.set(pluginId: "komga", key: "server", value: "https://a.example"))
        #expect(fixture.capture("komga").originatingEpoch == context.originatingEpoch)
        var row = try #require(try await fixture.rows().first)
        #expect(row.status == .pending)

        #expect(fixture.settings.set(pluginId: "komga", key: "server", value: "https://b.example"))
        row = try #require(try await fixture.rows().first)
        #expect(row.status == .paused)
        #expect(row.pauseReason == .configurationChanged)
        #expect(fixture.capture("komga").originatingEpoch != context.originatingEpoch)
    }

    @Test func removingAPlainSettingPausesPendingIntents() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        #expect(fixture.settings.set(pluginId: "komga", key: "server", value: "https://a.example"))
        let context = fixture.capture("komga")
        try await fixture.enqueue(context, unit: "ch-1", at: fixture.time(1))

        #expect(fixture.settings.remove(pluginId: "komga", key: "server"))

        let row = try #require(try await fixture.rows().first)
        #expect(row.status == .paused)
        #expect(row.pauseReason == .configurationChanged)
    }

    @Test func aChangeToOneSourceLeavesOtherSourcesPending() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let komga = fixture.capture("komga")
        let kavita = fixture.capture("kavita")
        try await fixture.enqueue(komga, unit: "k-1", at: fixture.time(1))
        try await fixture.enqueue(kavita, unit: "v-1", at: fixture.time(2))

        #expect(fixture.settings.setSecret(pluginId: "komga", key: "token", value: "new"))

        let rows = try await fixture.rows()
        #expect(rows.first { $0.pluginId == "komga" }?.status == .paused)
        #expect(rows.first { $0.pluginId == "kavita" }?.status == .pending)
    }

    @Test func removingEverySecretPausesEverySource() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        try await fixture.enqueue(fixture.capture("komga"), unit: "k-1", at: fixture.time(1))
        try await fixture.enqueue(fixture.capture("kavita"), unit: "v-1", at: fixture.time(2))

        try fixture.secrets.removeAll()

        let rows = try await fixture.rows()
        #expect(rows.map(\.status) == [.paused, .paused])
        #expect(rows.compactMap(\.pauseReason) == [.configurationChanged, .configurationChanged])
    }

    @Test func removingOneSourcesSecretsPausesOnlyThatSource() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        try await fixture.enqueue(fixture.capture("komga"), unit: "k-1", at: fixture.time(1))
        try await fixture.enqueue(fixture.capture("kavita"), unit: "v-1", at: fixture.time(2))

        try fixture.secrets.removeAll(pluginID: "komga")

        let rows = try await fixture.rows()
        #expect(rows.first { $0.pluginId == "komga" }?.status == .paused)
        #expect(rows.first { $0.pluginId == "kavita" }?.status == .pending)
    }

    // MARK: - Per-origin dedup and reauthorization

    @Test func eachOriginHasItsOwnRowForTheSameUnit() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let first = fixture.capture("komga")
        try await fixture.enqueue(first, unit: "ch-1", at: fixture.time(1))
        #expect(fixture.settings.setSecret(pluginId: "komga", key: "token", value: "second-account"))
        let second = fixture.capture("komga")
        #expect(second.originatingEpoch != first.originatingEpoch)

        try await fixture.enqueue(first, unit: "ch-1", at: fixture.time(2))
        try await fixture.enqueue(second, unit: "ch-1", at: fixture.time(3))
        try await fixture.enqueue(second, unit: "ch-1", at: fixture.time(4))

        let rows = try await fixture.rows()
        #expect(rows.count == 2)
        let old = try #require(rows.first { $0.originatingEpoch == first.originatingEpoch })
        let current = try #require(rows.first { $0.originatingEpoch == second.originatingEpoch })
        #expect(old.status == .paused)
        #expect(old.pauseReason == .configurationChanged)
        #expect(current.status == .pending)
    }

    @Test func remarkingAPausedRowKeepsItPausedUntilExplicitlyReauthorized() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let context = fixture.capture("komga")
        try await fixture.enqueue(context, unit: "ch-1", at: fixture.time(1))
        let intent = try #require(try await fixture.store.dueIntents(now: fixture.time(1)).first)
        let attempt = try #require(try await fixture.store.beginAttempt(intent, now: fixture.time(1)))
        try await fixture.store.finish(attempt, outcome: .paused(.credentials, .credentials), now: fixture.time(2))

        try await fixture.enqueue(context, unit: "ch-1", at: fixture.time(3))

        let row = try #require(try await fixture.rows().first)
        #expect(try await fixture.rows().count == 1)
        #expect(row.status == .paused)
        #expect(row.pauseReason == .credentials)
        #expect(row.revision > intent.revision)
        #expect(try await fixture.store.dueIntents(now: fixture.time(1_000)).isEmpty)
    }

    @Test func reauthorizingMovesPausedIntentsToTheCurrentAccountAndResetsRetries() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let old = fixture.capture("komga")
        try await fixture.enqueue(old, unit: "ch-1", at: fixture.time(1))
        try await fixture.enqueue(
            PluginCompletionContext(media: old.media, mediaKey: old.mediaKey, kind: .manga, originatingEpoch: nil),
            unit: "ch-2", at: fixture.time(2)
        )
        let kavita = fixture.capture("kavita")
        try await fixture.enqueue(kavita, unit: "other", at: fixture.time(3))
        #expect(fixture.settings.setSecret(pluginId: "komga", key: "token", value: "new-account"))
        #expect(try await fixture.store.dueIntents(now: fixture.time(10)).map(\.pluginId) == ["kavita"])

        try await fixture.store.reauthorizePaused(pluginID: "komga", now: fixture.time(20))

        let current = fixture.capture("komga")
        let komga = try await fixture.rows().filter { $0.pluginId == "komga" }
        #expect(komga.map(\.unitKey) == ["ch-1", "ch-2"])
        #expect(komga.allSatisfy { $0.status == .pending && $0.pauseReason == nil })
        #expect(komga.allSatisfy { $0.originatingEpoch == current.originatingEpoch })
        #expect(komga.allSatisfy { $0.attemptCount == 0 && $0.lastErrorCategory == nil && $0.lastAttemptAt == nil })
        #expect(komga.allSatisfy { $0.nextAttemptAt == fixture.time(20) })
        #expect(komga.allSatisfy { $0.mediaKey == "series" })
        let other = try #require(try await fixture.rows().first { $0.pluginId == "kavita" })
        #expect(other.status == .pending)
        let due = try await fixture.store.dueIntents(now: fixture.time(20))
        #expect(due.map(\.unitKey).sorted() == ["ch-1", "other"])
    }

    @Test func reauthorizingCoalescesWithARowAlreadyQueuedForTheCurrentAccount() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let old = fixture.capture("komga")
        try await fixture.enqueue(old, unit: "ch-1", at: fixture.time(1))
        try await fixture.enqueue(old, unit: "ch-2", at: fixture.time(2))
        #expect(fixture.settings.setSecret(pluginId: "komga", key: "token", value: "new-account"))
        let current = fixture.capture("komga")
        try await fixture.enqueue(current, unit: "ch-1", at: fixture.time(3))
        let queued = try #require(try await fixture.rows().first {
            $0.unitKey == "ch-1" && $0.originatingEpoch == current.originatingEpoch
        })

        try await fixture.store.reauthorizePaused(pluginID: "komga", now: fixture.time(10))

        let rows = try await fixture.rows()
        #expect(rows.count == 2)
        #expect(rows.map(\.unitKey).sorted() == ["ch-1", "ch-2"])
        #expect(rows.allSatisfy { $0.status == .pending && $0.originatingEpoch == current.originatingEpoch })
        let survivor = try #require(rows.first { $0.unitKey == "ch-1" })
        #expect(survivor.id == queued.id)
        #expect(survivor.revision > queued.revision)
    }

    @Test func reauthorizingCollapsesPausedRowsFromSeveralOldAccounts() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let first = fixture.capture("komga")
        try await fixture.enqueue(first, unit: "ch-1", at: fixture.time(1))
        #expect(fixture.settings.setSecret(pluginId: "komga", key: "token", value: "second"))
        let second = fixture.capture("komga")
        try await fixture.enqueue(second, unit: "ch-1", at: fixture.time(2))
        #expect(fixture.settings.setSecret(pluginId: "komga", key: "token", value: "third"))
        #expect(try await fixture.rows().count == 2)
        #expect(try await fixture.rows().allSatisfy { $0.status == .paused })

        try await fixture.store.reauthorizePaused(pluginID: "komga", now: fixture.time(10))

        let rows = try await fixture.rows()
        #expect(rows.count == 1)
        #expect(rows[0].status == .pending)
        #expect(rows[0].originatingEpoch == fixture.capture("komga").originatingEpoch)
    }

    @Test func reauthorizingRevivesRowsPausedForRetryLimitWithAFreshBudget() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        try await fixture.enqueue(fixture.capture("komga"), unit: "ch-1", at: fixture.time(0))
        var now = fixture.time(0)
        for _ in 0..<6 {
            let intent = try #require(try await fixture.store.dueIntents(now: now).first)
            let attempt = try #require(try await fixture.store.beginAttempt(intent, now: now))
            try await fixture.store.finish(attempt, outcome: .retryable(.server), now: now)
            now = now.addingTimeInterval(86_400)
        }
        #expect(try #require(try await fixture.rows().first).pauseReason == .retryLimit)

        try await fixture.store.reauthorizePaused(pluginID: "komga", now: now)

        let row = try #require(try await fixture.rows().first)
        #expect(row.status == .pending)
        #expect(row.attemptCount == 0)
        #expect(row.nextAttemptAt == now)
    }

    @Test func discardingDeletesOnlyThatSourcesPausedRows() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let komga = fixture.capture("komga")
        try await fixture.enqueue(komga, unit: "paused", at: fixture.time(1))
        #expect(fixture.settings.setSecret(pluginId: "komga", key: "token", value: "new"))
        let current = fixture.capture("komga")
        try await fixture.enqueue(current, unit: "pending", at: fixture.time(2))
        let kavita = fixture.capture("kavita")
        try await fixture.enqueue(kavita, unit: "v-1", at: fixture.time(3))
        #expect(fixture.settings.setSecret(pluginId: "kavita", key: "token", value: "new"))

        try await fixture.store.discardPaused(pluginID: "komga")

        let rows = try await fixture.rows()
        #expect(rows.map(\.unitKey).sorted() == ["pending", "v-1"])
        #expect(rows.first { $0.unitKey == "pending" }?.status == .pending)
        #expect(rows.first { $0.unitKey == "v-1" }?.status == .paused)
    }

    @Test func summariesCountPendingAndPausedRowsPerSource() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let old = fixture.capture("komga")
        try await fixture.enqueue(old, unit: "ch-1", at: fixture.time(1))
        #expect(fixture.settings.setSecret(pluginId: "komga", key: "token", value: "new"))
        let current = fixture.capture("komga")
        try await fixture.enqueue(current, unit: "ch-2", at: fixture.time(2))
        try await fixture.enqueue(current, unit: "ch-3", at: fixture.time(3))
        let intent = try #require(try await fixture.store.dueIntents(now: fixture.time(3)).first)
        let attempt = try #require(try await fixture.store.beginAttempt(intent, now: fixture.time(3)))
        try await fixture.store.finish(attempt, outcome: .paused(.missingRemote, .missingRemote), now: fixture.time(3))

        let summaries = try await fixture.store.summaries()

        #expect(summaries == [
            PluginCompletionSummary(
                pluginID: "komga", pendingCount: 1, pausedCount: 2,
                pauseReasons: [.configurationChanged, .missingRemote]
            )
        ])
    }

    // MARK: - Snapshots

    @Test func aSnapshotCarriesPlainSettingsAndSecretsOfOnlyItsOwnSource() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        #expect(fixture.settings.set(pluginId: "komga", key: "server", value: "https://a.example"))
        #expect(fixture.settings.setSecret(pluginId: "komga", key: "token", value: "komga-secret"))
        #expect(fixture.settings.set(pluginId: "komga", key: "token", value: "plain-shadow"))
        #expect(fixture.settings.setSecret(pluginId: "komga.beta", key: "token", value: "beta-secret"))
        #expect(fixture.settings.set(pluginId: "komga.beta", key: "server", value: "https://beta.example"))
        #expect(fixture.settings.setSecret(pluginId: "kavita", key: "token", value: "kavita-secret"))
        let context = fixture.capture("komga")
        try await fixture.enqueue(context, unit: "ch-1", at: fixture.time(1))
        let intent = try #require(try await fixture.store.dueIntents(now: fixture.time(1)).first)

        let snapshot = try fixture.store.snapshot(for: intent)

        #expect(snapshot.intent.id == intent.id)
        #expect(snapshot.settings == ["server": "https://a.example", "token": "komga-secret"])
    }

    @Test func aSnapshotWithoutSecretsCarriesJustThePlainSettings() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        #expect(fixture.settings.set(pluginId: "komga", key: "server", value: "https://a.example"))
        try await fixture.enqueue(fixture.capture("komga"), unit: "ch-1", at: fixture.time(1))
        let intent = try #require(try await fixture.store.dueIntents(now: fixture.time(1)).first)

        #expect(try fixture.store.snapshot(for: intent).settings == ["server": "https://a.example"])
    }

    @Test func aSnapshotFailsWhenAPlainSettingIsNotUTF8() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        #expect(fixture.settings.set(pluginId: "komga", key: "server", value: "placeholder"))
        try await fixture.database.dbPool.write { db in
            try db.execute(
                sql: "UPDATE pluginSetting SET value = ? WHERE pluginId = 'komga' AND key = 'server'",
                arguments: [Data([0xFF, 0xFE, 0xFD])]
            )
        }
        try await fixture.enqueue(fixture.capture("komga"), unit: "ch-1", at: fixture.time(1))
        let intent = try #require(try await fixture.store.dueIntents(now: fixture.time(1)).first)

        #expect(throws: PluginCompletionScopeError.invalidSettingEncoding) {
            try fixture.store.snapshot(for: intent)
        }
    }

    @Test func aSnapshotFailsWhileTheKeychainIsUnreadable() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        #expect(fixture.settings.setSecret(pluginId: "komga", key: "token", value: "secret"))
        try await fixture.enqueue(fixture.capture("komga"), unit: "ch-1", at: fixture.time(1))
        let intent = try #require(try await fixture.store.dueIntents(now: fixture.time(1)).first)

        fixture.keychain.failingStatus = errSecInteractionNotAllowed
        #expect(throws: PluginSecretStoreError(status: errSecInteractionNotAllowed)) {
            try fixture.store.snapshot(for: intent)
        }

        fixture.keychain.failingStatus = nil
        #expect(try fixture.store.snapshot(for: intent).settings == ["token": "secret"])
    }

    // MARK: - Retry, cancellation and ordering

    @Test func transientFailuresBackOffOnTheFixedScheduleThenPauseAtTheRetryLimit() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        try await fixture.enqueue(fixture.capture("komga"), unit: "ch-1", at: fixture.time(0))
        var now = fixture.time(0)

        for (index, delay) in [15.0, 60, 300, 1_800, 7_200].enumerated() {
            let intent = try #require(try await fixture.store.dueIntents(now: now).first)
            let attempt = try #require(try await fixture.store.beginAttempt(intent, now: now))
            try await fixture.store.finish(attempt, outcome: .retryable(.network), now: now)

            let row = try #require(try await fixture.rows().first)
            #expect(row.status == .pending)
            #expect(row.attemptCount == index + 1)
            #expect(row.lastErrorCategory == .network)
            #expect(row.nextAttemptAt == now.addingTimeInterval(delay))
            #expect(row.lastAttemptAt == now)
            #expect(try await fixture.store.nextAttemptDate() == now.addingTimeInterval(delay))
            #expect(try await fixture.store.dueIntents(now: now.addingTimeInterval(delay - 1)).isEmpty)
            now = now.addingTimeInterval(delay)
        }

        let last = try #require(try await fixture.store.dueIntents(now: now).first)
        let attempt = try #require(try await fixture.store.beginAttempt(last, now: now))
        try await fixture.store.finish(attempt, outcome: .retryable(.server), now: now)

        let row = try #require(try await fixture.rows().first)
        #expect(row.status == .paused)
        #expect(row.pauseReason == .retryLimit)
        #expect(row.attemptCount == 6)
        #expect(row.lastErrorCategory == .server)
        #expect(try await fixture.store.dueIntents(now: now.addingTimeInterval(1_000_000)).isEmpty)
        #expect(try await fixture.store.nextAttemptDate() == nil)
    }

    @Test func pausingOutcomesStopDeliveryAndRecordTheReason() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let context = fixture.capture("komga")
        let outcomes: [(PluginCompletionPauseReason, PluginCompletionFailureCategory?)] = [
            (.credentials, .credentials), (.missingRemote, .missingRemote),
            (.sourceUnavailable, .sourceUnavailable), (.incompatible, .incompatible), (.sourceError, nil)
        ]
        for (index, outcome) in outcomes.enumerated() {
            let unit = "ch-\(index)"
            try await fixture.enqueue(context, unit: unit, at: fixture.time(Double(index)))
            let intent = try #require(try await fixture.store.dueIntents(now: fixture.time(100)).first)
            #expect(intent.unitKey == unit)
            let attempt = try #require(try await fixture.store.beginAttempt(intent, now: fixture.time(100)))
            try await fixture.store.finish(attempt, outcome: .paused(outcome.0, outcome.1), now: fixture.time(100))
            let row = try #require(try await fixture.rows().first { $0.unitKey == unit })
            #expect(row.status == .paused)
            #expect(row.pauseReason == outcome.0)
            #expect(row.lastErrorCategory == outcome.1)
            #expect(row.attemptCount == 1)
        }
        #expect(try await fixture.store.dueIntents(now: fixture.time(100)).isEmpty)
    }

    @Test func cancellationLeavesTheIntentQueuedAndUnchanged() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        try await fixture.enqueue(fixture.capture("komga"), unit: "ch-1", at: fixture.time(1))
        let intent = try #require(try await fixture.store.dueIntents(now: fixture.time(1)).first)
        let attempt = try #require(try await fixture.store.beginAttempt(intent, now: fixture.time(2)))

        try await fixture.store.finish(attempt, outcome: .cancelled, now: fixture.time(3))

        let row = try #require(try await fixture.rows().first)
        #expect(row.status == .pending)
        #expect(row.revision == intent.revision)
        #expect(row.attemptCount == 0)
        #expect(row.nextAttemptAt == intent.nextAttemptAt)
        #expect(row.lastErrorCategory == nil)
        #expect(try await fixture.store.dueIntents(now: fixture.time(3)).map(\.id) == [intent.id])
    }

    @Test func acknowledgedAndUnsupportedIntentsAreRemoved() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let context = fixture.capture("komga")
        try await fixture.enqueue(context, unit: "ack", at: fixture.time(1))
        try await fixture.enqueue(fixture.capture("kavita"), unit: "unsupported", at: fixture.time(2))
        let due = try await fixture.store.dueIntents(now: fixture.time(5))
        #expect(due.count == 2)

        for (intent, outcome) in zip(due, [PluginCompletionOutcome.acknowledged, .unsupported]) {
            let attempt = try #require(try await fixture.store.beginAttempt(intent, now: fixture.time(5)))
            try await fixture.store.finish(attempt, outcome: outcome, now: fixture.time(5))
        }

        #expect(try await fixture.rows().isEmpty)
        #expect(try await fixture.store.summaries().isEmpty)
    }

    @Test func aSourcesIntentsAreDeliveredStrictlyOldestFirstEvenWhenTheHeadIsBackedOff() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let komga = fixture.capture("komga")
        let kavita = fixture.capture("kavita")
        try await fixture.enqueue(komga, unit: "k-1", at: fixture.time(1))
        try await fixture.enqueue(komga, unit: "k-2", at: fixture.time(2))
        try await fixture.enqueue(kavita, unit: "v-1", at: fixture.time(3))
        try await fixture.enqueue(kavita, unit: "v-2", at: fixture.time(4))

        let firstWave = try await fixture.store.dueIntents(now: fixture.time(10))
        #expect(firstWave.map(\.unitKey) == ["k-1", "v-1"])

        let head = try #require(firstWave.first)
        let attempt = try #require(try await fixture.store.beginAttempt(head, now: fixture.time(10)))
        try await fixture.store.finish(attempt, outcome: .retryable(.network), now: fixture.time(10))

        #expect(try await fixture.store.dueIntents(now: fixture.time(11)).map(\.unitKey) == ["v-1"])
        #expect(try await fixture.store.nextAttemptDate() == fixture.time(3))

        let kavitaHead = try #require(try await fixture.store.dueIntents(now: fixture.time(11)).first)
        let kavitaAttempt = try #require(try await fixture.store.beginAttempt(kavitaHead, now: fixture.time(11)))
        try await fixture.store.finish(kavitaAttempt, outcome: .acknowledged, now: fixture.time(11))
        #expect(try await fixture.store.dueIntents(now: fixture.time(12)).map(\.unitKey) == ["v-2"])

        #expect(try await fixture.store.dueIntents(now: fixture.time(25)).map(\.unitKey) == ["k-1", "v-2"])
        let retried = try #require(try await fixture.store.dueIntents(now: fixture.time(25)).first)
        let retryAttempt = try #require(try await fixture.store.beginAttempt(retried, now: fixture.time(25)))
        try await fixture.store.finish(retryAttempt, outcome: .acknowledged, now: fixture.time(25))
        #expect(try await fixture.store.dueIntents(now: fixture.time(25)).map(\.unitKey) == ["k-2", "v-2"])
    }

    @Test func theNextAttemptDateOnlyConsidersEachSourcesOldestPendingRow() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let komga = fixture.capture("komga")
        try await fixture.enqueue(komga, unit: "k-1", at: fixture.time(1))
        try await fixture.enqueue(komga, unit: "k-2", at: fixture.time(2))
        let head = try #require(try await fixture.store.dueIntents(now: fixture.time(10)).first)
        let attempt = try #require(try await fixture.store.beginAttempt(head, now: fixture.time(10)))
        try await fixture.store.finish(attempt, outcome: .retryable(.network), now: fixture.time(10))

        #expect(try await fixture.store.nextAttemptDate() == fixture.time(25))
    }

    @Test func aPausedHeadDoesNotBlockLaterRowsOfItsSource() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let komga = fixture.capture("komga")
        try await fixture.enqueue(komga, unit: "k-1", at: fixture.time(1))
        try await fixture.enqueue(komga, unit: "k-2", at: fixture.time(2))
        let head = try #require(try await fixture.store.dueIntents(now: fixture.time(10)).first)
        let attempt = try #require(try await fixture.store.beginAttempt(head, now: fixture.time(10)))
        try await fixture.store.finish(attempt, outcome: .paused(.missingRemote, .missingRemote), now: fixture.time(10))

        #expect(try await fixture.store.dueIntents(now: fixture.time(10)).map(\.unitKey) == ["k-2"])
    }

    // MARK: - Removal

    @Test func holdingASourcePausesItsIntentsAndLeavesOtherSourcesAlone() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let komga = fixture.capture("komga")
        try await fixture.enqueue(komga, unit: "k-1", at: fixture.time(1))
        try await fixture.enqueue(fixture.capture("kavita"), unit: "v-1", at: fixture.time(2))
        let intent = try #require(try await fixture.store.dueIntents(now: fixture.time(5)).first)
        #expect(intent.pluginId == "komga")
        let attempt = try #require(try await fixture.store.beginAttempt(intent, now: fixture.time(5)))

        try await fixture.store.holdForRemoval(pluginID: "komga")

        // A removal that fails afterwards must leave the intent recoverable, not lost.
        let held = try #require(try await fixture.rows().first { $0.pluginId == "komga" })
        #expect(held.status == .paused)
        #expect(held.pauseReason == .configurationChanged)
        try await fixture.store.finish(attempt, outcome: .acknowledged, now: fixture.time(6))
        try await fixture.store.finish(attempt, outcome: .retryable(.network), now: fixture.time(6))
        #expect(try await fixture.rows().first { $0.pluginId == "komga" }?.status == .paused)
        #expect(try await fixture.rows().first { $0.pluginId == "kavita" }?.status == .pending)
        #expect(throws: PluginCompletionScopeError.configurationChanged) {
            try fixture.store.snapshot(for: intent)
        }
        #expect(try await fixture.store.beginAttempt(intent, now: fixture.time(6)) == nil)

        try await fixture.store.purgeRemoved(pluginID: "komga")

        #expect(try await fixture.rows().map(\.pluginId) == ["kavita"])
    }

    @Test func aMarkCapturedBeforeRemovalCannotDeliverToAReinstalledSource() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let before = fixture.capture("komga")
        try await fixture.store.holdForRemoval(pluginID: "komga")

        try await fixture.enqueue(before, unit: "late", at: fixture.time(1))

        let row = try #require(try await fixture.rows().first)
        #expect(row.status == .paused)
        #expect(row.pauseReason == .configurationChanged)
        #expect(try await fixture.store.dueIntents(now: fixture.time(1_000)).isEmpty)
        let after = fixture.capture("komga")
        #expect(after.originatingEpoch != nil)
        #expect(after.originatingEpoch != before.originatingEpoch)
    }

    @Test func removingASourceWithNothingQueuedLeavesAUsableScope() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }

        try await fixture.store.holdForRemoval(pluginID: "never.seen")

        let context = fixture.capture("never.seen")
        #expect(context.originatingEpoch != nil)
        #expect(try await fixture.rows().isEmpty)
    }

    // MARK: - Opaque original keys

    @Test func keysAreStoredVerbatimAndComparedExactly() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let media = MediaIdentity(pluginId: "komga", canonicalMediaId: "imported:1234")
        let context = PluginCompletionContext(
            media: media, mediaKey: " /Series/ÄÖ%2F?x=1 ", kind: .novel, originatingEpoch: fixture.capture("komga").originatingEpoch
        )

        for unit in ["Ch-1", "ch-1", "ch-1 ", "ch-1", ""] {
            try await fixture.enqueue(context, unit: unit, at: fixture.time(1))
        }

        let rows = try await fixture.rows()
        #expect(rows.map(\.unitKey) == ["Ch-1", "ch-1", "ch-1 ", ""])
        #expect(rows.allSatisfy { $0.mediaKey == " /Series/ÄÖ%2F?x=1 " })
        #expect(rows.allSatisfy { $0.canonicalMediaId == "imported:1234" })
        #expect(rows.allSatisfy { $0.kind == .novel })
    }

    @Test func theSameUnitOfADifferentSeriesOrKindIsADifferentDelivery() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let epoch = fixture.capture("komga").originatingEpoch
        let media = MediaIdentity(pluginId: "komga", canonicalMediaId: "canon")
        for (key, kind) in [("a", PluginCompletionKind.manga), ("b", .manga), ("a", .novel)] {
            try await fixture.enqueue(
                PluginCompletionContext(media: media, mediaKey: key, kind: kind, originatingEpoch: epoch),
                unit: "ch-1", at: fixture.time(1)
            )
        }

        #expect(try await fixture.rows().count == 3)
    }

    // MARK: - Change notification

    @Test func observersHearCommittedChangesButNotRolledBackOnes() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.cleanup() }
        let context = fixture.capture("komga")
        let counter = ChangeCounter()
        let observation = fixture.store.observeChanges { counter.increment() }
        defer { withExtendedLifetime(observation) {} }

        try await fixture.enqueue(context, unit: "ch-1", at: fixture.time(1))
        #expect(counter.count == 1)

        let pool = fixture.database.dbPool
        await #expect(throws: RollbackProbe.self) {
            try await pool.write { db in
                try PluginCompletionStore.enqueue(context: context, unitKey: "ch-2", now: Date(), in: db)
                throw RollbackProbe()
            }
        }
        #expect(counter.count == 1)
        #expect(try await fixture.rows().count == 1)

        #expect(fixture.settings.setSecret(pluginId: "komga", key: "token", value: "new"))
        #expect(counter.count > 1)
    }
}

// MARK: - Fixtures

private struct RollbackProbe: Error {}

private nonisolated final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

@MainActor
private final class QueueWakes {
    var count = 0
}

@MainActor
private struct CompletionFixture {
    let database: TestDatabase
    let keychain: CompletionFakeKeychain
    let secrets: PluginSecretStore
    let tokens = PluginSecretStore(keychain: CompletionFakeKeychain())
    let settings: PluginSettingsStore
    let store: PluginCompletionStore
    let manager: ReadProgressManager
    let wakes = QueueWakes()

    init() throws {
        database = try TestDatabase()
        keychain = CompletionFakeKeychain()
        secrets = PluginSecretStore(keychain: keychain)
        settings = PluginSettingsStore(
            dbPool: database.dbPool,
            domainFactory: { CompletionTestDomain(name: $0) },
            secrets: secrets,
            tokens: tokens
        )
        store = PluginCompletionStore(dbPool: database.dbPool, secrets: secrets, tokens: tokens)
        manager = ReadProgressManager(dbPool: database.dbPool)
        let wakes = wakes
        manager.configureCompletionDelivery(store: store) { wakes.count += 1 }
    }

    func cleanup() {
        database.cleanup()
    }

    /// Whole seconds keep Date round trips through SQLite exact.
    func time(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + seconds)
    }

    func capture(_ pluginID: String, mediaKey: String = "series") -> PluginCompletionContext {
        store.captureContext(
            media: MediaIdentity(pluginId: pluginID, canonicalMediaId: "canonical-\(pluginID)"),
            mediaKey: mediaKey,
            kind: .manga
        )
    }

    func enqueue(_ context: PluginCompletionContext, unit: String, at now: Date) async throws {
        try await database.dbPool.write { db in
            try PluginCompletionStore.enqueue(context: context, unitKey: unit, now: now, in: db)
        }
    }

    func rows() async throws -> [PluginCompletionIntent] {
        try await database.dbPool.read { db in
            try PluginCompletionIntent.fetchAll(db, sql: "SELECT * FROM pluginCompletionOutbox ORDER BY id")
        }
    }

    func acknowledgeEverything(at now: Date) async throws {
        for intent in try await store.dueIntents(now: now) {
            if let attempt = try await store.beginAttempt(intent, now: now) {
                try await store.finish(attempt, outcome: .acknowledged, now: now)
            }
        }
    }

    func localProgressCounts() async throws -> (keys: Int, numbers: Int, resume: Int) {
        try await database.dbPool.read { db in
            (
                try ReadProgressKeyRecord.fetchCount(db),
                try ReadProgressNumberRecord.fetchCount(db),
                try MediaReadProgressRecord.fetchCount(db)
            )
        }
    }
}

private final class CompletionTestDomain: LegacyDefaultsDomain, @unchecked Sendable {
    let domainName: String

    init(name: String) {
        domainName = name
    }

    func persistentDomain() -> [String: Any] { [:] }
    func removeObject(forKey key: String) {}
}

/// A stateful Keychain. `failingStatus`, when set, is returned by every call.
private nonisolated final class CompletionFakeKeychain: PluginSecretKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var failure: OSStatus?

    var failingStatus: OSStatus? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    func data(account: String) -> (OSStatus, Data?) {
        lock.withLock {
            if let failure { return (failure, nil) }
            guard let data = items[account] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
    }

    func setData(_ data: Data, account: String) -> OSStatus {
        lock.withLock {
            if let failure { return failure }
            items[account] = data
            return errSecSuccess
        }
    }

    func delete(account: String) -> OSStatus {
        lock.withLock {
            if let failure { return failure }
            return items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    func accounts() -> (OSStatus, [String]) {
        lock.withLock {
            if let failure { return (failure, []) }
            return items.isEmpty ? (errSecItemNotFound, []) : (errSecSuccess, Array(items.keys))
        }
    }

    func deleteAll() -> OSStatus {
        lock.withLock {
            if let failure { return failure }
            let hadItems = !items.isEmpty
            items.removeAll()
            return hadItems ? errSecSuccess : errSecItemNotFound
        }
    }
}
