import Foundation
import GRDB
import Testing
import ito_runner
@testable import Ito

@MainActor
struct TrackerLinkStoreTests {
    @Test func scopedLinkReplacementUnlinkAndReload() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = TrackerManager(
            dbPool: database.dbPool,
            credentialStore: FakeTrackerCredentialStore(),
            malCredentialStore: FakeTrackerCredentialStore(),
            mangaBakaCredentialStore: FakeTrackerCredentialStore(),
            legacyTokenStore: FakeLegacyTokenStore(),
            usernameDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let first = MediaIdentity(pluginId: "one", canonicalMediaId: "same", mediaKind: .manga)
        let second = MediaIdentity(pluginId: "two", canonicalMediaId: "same", mediaKind: .manga)

        try await manager.link(media: first, providerId: "anilist", remoteMediaId: "1")
        try await manager.link(media: first, providerId: "anilist", remoteMediaId: "2")
        try await manager.link(media: second, providerId: "anilist", remoteMediaId: "3")
        #expect(manager.trackerId(for: first, providerId: "anilist") == "2")
        #expect(manager.trackerId(for: second, providerId: "anilist") == "3")

        try await manager.reload()
        #expect(manager.trackerId(for: first, providerId: "anilist") == "2")
        try await manager.unlink(media: first, providerId: "anilist")
        #expect(manager.trackerId(for: first, providerId: "anilist") == nil)

        try await database.dbPool.read { db in
            let count = try TrackerLinkRecord.fetchCount(db)
            #expect(count == 1)
        }
    }

    @Test func databaseFailureKeepsCommittedMappingPublished() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = TrackerManager(
            dbPool: database.dbPool,
            credentialStore: FakeTrackerCredentialStore(),
            malCredentialStore: FakeTrackerCredentialStore(),
            mangaBakaCredentialStore: FakeTrackerCredentialStore(),
            legacyTokenStore: FakeLegacyTokenStore(),
            usernameDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let media = MediaIdentity(pluginId: "plugin", canonicalMediaId: "media", mediaKind: .manga)
        try await manager.link(media: media, providerId: "anilist", remoteMediaId: "old")
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_tracker_update
                BEFORE UPDATE ON trackerLink
                BEGIN
                    SELECT RAISE(ABORT, 'injected tracker failure');
                END
                """)
        }

        await #expect(throws: (any Error).self) {
            try await manager.link(
                media: media,
                providerId: "anilist",
                remoteMediaId: "new"
            )
        }

        #expect(manager.trackerId(for: media, providerId: "anilist") == "old")
        try await database.dbPool.read { db in
            let record = try TrackerLinkRecord.fetchOne(db)
            #expect(record?.remoteMediaId == "old")
            let count = try TrackerLinkRecord.fetchCount(db)
            #expect(count == 1)
        }
    }

    @Test func unlinkFailurePreservesPublishedAndDurableMapping() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = TrackerManager(
            dbPool: database.dbPool,
            credentialStore: FakeTrackerCredentialStore(),
            malCredentialStore: FakeTrackerCredentialStore(),
            mangaBakaCredentialStore: FakeTrackerCredentialStore(),
            legacyTokenStore: FakeLegacyTokenStore(),
            usernameDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let media = MediaIdentity(pluginId: "plugin", canonicalMediaId: "media", mediaKind: .manga)
        try await manager.link(media: media, providerId: "anilist", remoteMediaId: "remote")
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_tracker_delete
                BEFORE DELETE ON trackerLink
                BEGIN
                    SELECT RAISE(ABORT, 'injected tracker delete failure');
                END
                """)
        }

        await #expect(throws: (any Error).self) {
            try await manager.unlink(media: media, providerId: "anilist")
        }

        #expect(manager.trackerId(for: media, providerId: "anilist") == "remote")
        try await database.dbPool.read { db in
            let record = try TrackerLinkRecord.fetchOne(db)
            #expect(record?.remoteMediaId == "remote")
            #expect(try TrackerLinkRecord.fetchCount(db) == 1)
        }
    }

    @Test func linksToSignedOutTrackersDoNotCountAsTracked() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = TrackerManager(
            dbPool: database.dbPool,
            credentialStore: FakeTrackerCredentialStore(),
            malCredentialStore: FakeTrackerCredentialStore(),
            mangaBakaCredentialStore: FakeTrackerCredentialStore(),
            legacyTokenStore: FakeLegacyTokenStore(),
            usernameDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let media = MediaIdentity(pluginId: "plugin", canonicalMediaId: "media", mediaKind: .manga)

        try await manager.link(media: media, providerId: "myanimelist", remoteMediaId: "anime:1")

        #expect(manager.trackerId(for: media, providerId: "myanimelist") == "anime:1")
        #expect(!manager.hasAuthenticatedLink(for: media))
    }

    @Test func sameKeyMangaAndNovelTrackAndUnlinkIndependently() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = TrackerManager(
            dbPool: database.dbPool,
            credentialStore: FakeTrackerCredentialStore(),
            malCredentialStore: FakeTrackerCredentialStore(),
            mangaBakaCredentialStore: FakeTrackerCredentialStore(),
            legacyTokenStore: FakeLegacyTokenStore(),
            usernameDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let manga = MediaIdentity(pluginId: "source", canonicalMediaId: "key42", mediaKind: .manga)
        let novel = MediaIdentity(pluginId: "source", canonicalMediaId: "key42", mediaKind: .novel)

        try await manager.link(media: manga, providerId: "anilist", remoteMediaId: "manga-remote")
        try await manager.link(media: novel, providerId: "anilist", remoteMediaId: "novel-remote")

        #expect(manager.trackerId(for: manga, providerId: "anilist") == "manga-remote")
        #expect(manager.trackerId(for: novel, providerId: "anilist") == "novel-remote")

        let reloaded = TrackerManager(
            dbPool: database.dbPool,
            credentialStore: FakeTrackerCredentialStore(),
            malCredentialStore: FakeTrackerCredentialStore(),
            mangaBakaCredentialStore: FakeTrackerCredentialStore(),
            legacyTokenStore: FakeLegacyTokenStore(),
            usernameDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        try await reloaded.reload()
        #expect(reloaded.trackerId(for: manga, providerId: "anilist") == "manga-remote")
        #expect(reloaded.trackerId(for: novel, providerId: "anilist") == "novel-remote")

        try await manager.unlink(media: manga, providerId: "anilist")
        #expect(manager.trackerId(for: manga, providerId: "anilist") == nil)
        #expect(manager.trackerId(for: novel, providerId: "anilist") == "novel-remote")

        try await reloaded.reload()
        #expect(reloaded.trackerId(for: manga, providerId: "anilist") == nil)
        #expect(reloaded.trackerId(for: novel, providerId: "anilist") == "novel-remote")
    }
}

extension TrackerLinkStoreTests {
    private func guardedManager(_ database: TestDatabase) -> TrackerManager {
        TrackerManager(
            dbPool: database.dbPool,
            credentialStore: FakeTrackerCredentialStore(),
            malCredentialStore: FakeTrackerCredentialStore(),
            mangaBakaCredentialStore: FakeTrackerCredentialStore(),
            legacyTokenStore: FakeLegacyTokenStore(),
            usernameDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )
    }

    @Test func guardedLinkHoldsIdentityThroughActualCommit() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = guardedManager(database)
        let provider = try #require(manager.providers.first as? AnilistTracker)
        let authority = provider.scoreIdentity
        let session = TrackerScoreSession(format: .point10, identity: authority.current)
        let observer = ScoreLinkCommitObserver(authority: authority)
        try await database.dbPool.writeWithoutTransaction { db in
            db.add(transactionObserver: observer)
        }
        let media = MediaIdentity(pluginId: "guard", canonicalMediaId: "commit", mediaKind: .manga)
        try await manager.link(media: media, providerId: "anilist", remoteMediaId: "42", scoreSession: session)
        #expect(observer.commitCount == 1)
        #expect(observer.wasProtected)
        #expect(!authority.isLockedForTesting())
        #expect(manager.trackerId(for: media, providerId: "anilist") == "42")
        try await manager.reload()
        #expect(manager.trackerId(for: media, providerId: "anilist") == "42")
    }

    @Test(arguments: [false, true])
    func staleGuardPreservesDurableAndPublishedMapping(existing: Bool) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = guardedManager(database)
        let provider = try #require(manager.providers.first as? AnilistTracker)
        let media = MediaIdentity(pluginId: "guard", canonicalMediaId: "stale", mediaKind: .manga)
        if existing { try await manager.link(media: media, providerId: "anilist", remoteMediaId: "old") }
        let session = TrackerScoreSession(format: .point10, identity: provider.scoreEditingIdentity)
        provider.scoreIdentity.rotate()
        await #expect(throws: TrackerScoreEditingError.accountChanged) {
            try await manager.link(media: media, providerId: "anilist", remoteMediaId: "new", scoreSession: session)
        }
        #expect(manager.trackerId(for: media, providerId: "anilist") == (existing ? "old" : nil))
        try await manager.reload()
        #expect(manager.trackerId(for: media, providerId: "anilist") == (existing ? "old" : nil))
    }

    @Test(arguments: [false, true])
    func rotationBeforeWriterAdmissionRejectsLink(existing: Bool) async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = guardedManager(database)
        let provider = try #require(manager.providers.first as? AnilistTracker)
        let media = MediaIdentity(pluginId: "guard", canonicalMediaId: "queued", mediaKind: .manga)
        if existing { try await manager.link(media: media, providerId: "anilist", remoteMediaId: "old") }
        let session = TrackerScoreSession(format: .point10, identity: provider.scoreEditingIdentity)
        let gate = ScoreLinkWriterGate()
        defer { gate.release() }
        let blocker = Task {
            try await database.dbPool.writeWithoutTransaction { _ in gate.blockWriter() }
        }
        await gate.waitUntilBlocked()
        var link: Task<Void, any Error>?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            link = Task { @MainActor in
                // The test resumes only after this task suspends at writer admission.
                continuation.resume()
                try await manager.link(
                    media: media, providerId: "anilist", remoteMediaId: "new", scoreSession: session
                )
            }
        }
        provider.scoreIdentity.rotate()
        gate.release()
        try await blocker.value
        let operation = try #require(link)
        await #expect(throws: TrackerScoreEditingError.accountChanged) { try await operation.value }
        #expect(manager.trackerId(for: media, providerId: "anilist") == (existing ? "old" : nil))
        try await manager.reload()
        #expect(manager.trackerId(for: media, providerId: "anilist") == (existing ? "old" : nil))
    }

    @Test func guardedSQLRollbackReleasesAuthorityAndPreservesOldLink() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = guardedManager(database)
        let provider = try #require(manager.providers.first as? AnilistTracker)
        let media = MediaIdentity(pluginId: "guard", canonicalMediaId: "rollback", mediaKind: .manga)
        try await manager.link(media: media, providerId: "anilist", remoteMediaId: "old")
        try await database.dbPool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_guarded_link BEFORE UPDATE ON trackerLink
                BEGIN SELECT RAISE(ABORT, 'injected guarded link failure'); END
                """)
        }
        let session = TrackerScoreSession(format: .point10, identity: provider.scoreEditingIdentity)
        await #expect(throws: (any Error).self) {
            try await manager.link(media: media, providerId: "anilist", remoteMediaId: "new", scoreSession: session)
        }
        #expect(!provider.scoreIdentity.isLockedForTesting())
        provider.scoreIdentity.rotate()
        #expect(manager.trackerId(for: media, providerId: "anilist") == "old")
        try await manager.reload()
        #expect(manager.trackerId(for: media, providerId: "anilist") == "old")
    }
}

private nonisolated final class ScoreLinkCommitObserver: TransactionObserver, @unchecked Sendable {
    private let authority: TrackerScoreIdentity
    private let lock = NSLock()
    private var commits = 0
    private var protected = true

    init(authority: TrackerScoreIdentity) { self.authority = authority }
    var commitCount: Int { lock.withLock { commits } }
    var wasProtected: Bool { lock.withLock { protected } }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { eventKind.tableName == "trackerLink" }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseWillCommit() throws {
        let held = authority.isLockedForTesting()
        lock.withLock {
            commits += 1
            protected = protected && held
        }
    }
    func databaseDidCommit(_ db: Database) {}
    func databaseDidRollback(_ db: Database) {}
}

private nonisolated final class ScoreLinkWriterGate: @unchecked Sendable {
    private let lock = NSLock()
    private let released = DispatchSemaphore(value: 0)
    private var blocked = false
    private var waiter: CheckedContinuation<Void, Never>?

    func blockWriter() {
        let continuation = lock.withLock {
            blocked = true
            let continuation = waiter
            waiter = nil
            return continuation
        }
        continuation?.resume()
        released.wait()
    }

    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            let alreadyBlocked = lock.withLock {
                if blocked { return true }
                waiter = continuation
                return false
            }
            if alreadyBlocked { continuation.resume() }
        }
    }

    func release() { released.signal() }
}
