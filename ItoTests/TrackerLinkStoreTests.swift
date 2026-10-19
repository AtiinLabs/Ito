import Foundation
import GRDB
import Testing
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
        let first = MediaIdentity(pluginId: "one", canonicalMediaId: "same")
        let second = MediaIdentity(pluginId: "two", canonicalMediaId: "same")

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
        let media = MediaIdentity(pluginId: "plugin", canonicalMediaId: "media")
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
        let media = MediaIdentity(pluginId: "plugin", canonicalMediaId: "media")
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
        let media = MediaIdentity(pluginId: "plugin", canonicalMediaId: "media")

        try await manager.link(media: media, providerId: "myanimelist", remoteMediaId: "anime:1")

        #expect(manager.trackerId(for: media, providerId: "myanimelist") == "anime:1")
        #expect(!manager.hasAuthenticatedLink(for: media))
    }
}
