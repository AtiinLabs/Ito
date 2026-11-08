import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

/// The schema itself refuses states the store must never produce, whatever code writes them.
struct OfflineChapterSchemaConstraintTests {
    private static func job(
        id: String = UUID().uuidString,
        chapterKey: String = "chapter-1",
        mediaKind: MediaKind = .manga,
        state: DownloadJobState,
        waitingReason: DownloadWaitingReason? = nil,
        failureReason: DownloadFailureReason? = nil,
        stagingVersionId: String? = nil
    ) -> DownloadJobRecord {
        DownloadJobRecord(
            id: id,
            pluginId: "plugin.test",
            mediaKind: mediaKind,
            canonicalMediaId: "series-1",
            chapterKey: chapterKey,
            authorityScope: .publicUnscoped,
            entrySnapshot: Data("{}".utf8),
            chapterSnapshot: Data("{}".utf8),
            seriesTitle: "Series",
            sourceEpoch: "epoch",
            state: state,
            waitingReason: waitingReason,
            failureReason: failureReason,
            stagingVersionId: stagingVersionId,
            attemptCount: 0,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private static func row(
        versionId: String = UUID().uuidString,
        chapterKey: String = "chapter-1",
        mediaKind: MediaKind = .manga,
        state: DownloadedChapterState = .verified,
        damageReason: DamageReason? = nil
    ) -> DownloadedChapterRecord {
        DownloadedChapterRecord(
            pluginId: "plugin.test",
            mediaKind: mediaKind,
            canonicalMediaId: "series-1",
            chapterKey: chapterKey,
            authorityScope: .publicUnscoped,
            versionId: versionId,
            state: state,
            damageReason: damageReason,
            contentKind: .images,
            pageCount: 1,
            byteCount: 4,
            manifestFormatVersion: 1,
            manifestSHA256: String(repeating: "a", count: 64),
            chapterSnapshot: Data("{}".utf8),
            seriesTitle: "Series",
            sourceEpoch: "epoch",
            verifiedAt: Date(timeIntervalSince1970: 1)
        )
    }

    @Test func aDownloadingJobWithoutAStagingVersionIsRejected() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        #expect(throws: DatabaseError.self) {
            try database.dbPool.write { db in
                try Self.job(state: .downloading).insert(db)
            }
        }
    }

    @Test func aWaitingJobWithoutAReasonIsRejectedAndAQueuedJobMayNotCarryOne() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        #expect(throws: DatabaseError.self) {
            try database.dbPool.write { db in
                try Self.job(state: .waiting).insert(db)
            }
        }
        #expect(throws: DatabaseError.self) {
            try database.dbPool.write { db in
                try Self.job(state: .queued, waitingReason: .noConnection).insert(db)
            }
        }
    }

    @Test func aFailedJobNeedsAFailureReasonAndAStagedJobNeedsNoFailureReason() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        #expect(throws: DatabaseError.self) {
            try database.dbPool.write { db in
                try Self.job(state: .failed).insert(db)
            }
        }
        #expect(throws: DatabaseError.self) {
            try database.dbPool.write { db in
                try Self.job(state: .downloading, failureReason: .network, stagingVersionId: UUID().uuidString)
                    .insert(db)
            }
        }
    }

    @Test func animeRowsAreRejectedByBothTables() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        #expect(throws: DatabaseError.self) {
            try database.dbPool.write { db in
                try Self.row(mediaKind: .anime).insert(db)
            }
        }
        #expect(throws: DatabaseError.self) {
            try database.dbPool.write { db in
                try Self.job(mediaKind: .anime, state: .queued).insert(db)
            }
        }
    }

    @Test func aSecondRowForTheSameEditionIsRejected() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try database.dbPool.write { db in
            try Self.row(versionId: UUID().uuidString).insert(db)
        }

        #expect(throws: DatabaseError.self) {
            try database.dbPool.write { db in
                try Self.row(versionId: UUID().uuidString).insert(db)
            }
        }
    }

    @Test func aSecondJobForTheSameEditionIsRejected() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        try database.dbPool.write { db in
            try Self.job(state: .queued).insert(db)
        }

        #expect(throws: DatabaseError.self) {
            try database.dbPool.write { db in
                try Self.job(state: .queued).insert(db)
            }
        }
    }

    @Test func damageReasonIsRequiredExactlyWhenTheCopyIsDamaged() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        #expect(throws: DatabaseError.self) {
            try database.dbPool.write { db in
                try Self.row(state: .damaged).insert(db)
            }
        }
        #expect(throws: DatabaseError.self) {
            try database.dbPool.write { db in
                try Self.row(chapterKey: "chapter-2", damageReason: .manifestMismatch).insert(db)
            }
        }
    }

    @Test func theStoreBindingIsASingleRowWithIdentifierOne() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }

        #expect(throws: DatabaseError.self) {
            try database.dbPool.write { db in
                try db.execute(
                    sql: "INSERT INTO downloadStore (id, storeId, createdAt) VALUES (2, ?, ?)",
                    arguments: [UUID().uuidString, Date(timeIntervalSince1970: 1)]
                )
            }
        }
    }
}
