import GRDB

extension AppDatabase {
    // MARK: - v24: Download replacement

    /// A replacement's approval is a one-to-one intent child of its job, removed with the job. The job's
    /// failure reasons gain the three terminal outcomes of a replacement. SQLite cannot widen a CHECK in
    /// place, so `downloadJob` is rebuilt with the same columns, constraints and indexes as v19.
    nonisolated static func registerDownloadReplacementMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v24") { db in
            try db.execute(sql: """
                CREATE TABLE downloadJob_v24 (
                  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
                  batchId TEXT NOT NULL REFERENCES downloadBatch(id),
                  sequence INTEGER NOT NULL CHECK(sequence >= 0),
                  pluginId TEXT NOT NULL,
                  mediaKind TEXT NOT NULL CHECK(mediaKind IN ('manga','novel')),
                  canonicalMediaId TEXT NOT NULL,
                  chapterKey TEXT NOT NULL,
                  authorityScope TEXT NOT NULL CHECK(authorityScope IN ('publicUnscoped')),
                  chapterSnapshot BLOB NOT NULL,
                  seriesTitle TEXT NOT NULL,
                  sourceEpoch TEXT,
                  state TEXT NOT NULL CHECK(state IN ('queued','waiting','downloading','failed')),
                  waitingReason TEXT CHECK(waitingReason IS NULL OR waitingReason IN (
                    'networkUnknown','noConnection','meteredNetwork','lowDataMode','insufficientStorage',
                    'protectedDataUnavailable','sourceUnavailable','sourceConfigurationChanged',
                    'restoredPendingReview','appInBackground')),
                  failureReason TEXT CHECK(failureReason IS NULL OR failureReason IN (
                    'sourceError','network','httpStatus','emptyChapter','tooManyPages','assetTooLarge',
                    'unsupportedImageFormat','unsupportedPageLocator','requiresInteractiveSource',
                    'integrityMismatch','fileSystem',
                    'replacementStale','replacementContentChanged','replacementInterrupted')),
                  stagingVersionId TEXT UNIQUE,
                  attemptCount INTEGER NOT NULL DEFAULT 0 CHECK(attemptCount >= 0),
                  createdAt DATETIME NOT NULL,
                  updatedAt DATETIME NOT NULL,
                  CHECK ((state = 'waiting') = (waitingReason IS NOT NULL)),
                  CHECK ((state = 'failed') = (failureReason IS NOT NULL)),
                  CHECK ((state = 'downloading') = (stagingVersionId IS NOT NULL)),
                  UNIQUE (pluginId, mediaKind, canonicalMediaId, chapterKey, authorityScope)
                );
                INSERT INTO downloadJob_v24
                  (id, batchId, sequence, pluginId, mediaKind, canonicalMediaId, chapterKey, authorityScope,
                   chapterSnapshot, seriesTitle, sourceEpoch, state, waitingReason, failureReason,
                   stagingVersionId, attemptCount, createdAt, updatedAt)
                SELECT id, batchId, sequence, pluginId, mediaKind, canonicalMediaId, chapterKey, authorityScope,
                   chapterSnapshot, seriesTitle, sourceEpoch, state, waitingReason, failureReason,
                   stagingVersionId, attemptCount, createdAt, updatedAt
                FROM downloadJob;
                DROP TABLE downloadJob;
                ALTER TABLE downloadJob_v24 RENAME TO downloadJob;
                CREATE INDEX idx_downloadJob_queue ON downloadJob(state, createdAt, batchId, sequence, id);
                CREATE INDEX idx_downloadJob_batch ON downloadJob(batchId);
                """)
            try db.create(table: "downloadReplacementIntent") { t in
                t.primaryKey("jobId", .text).references("downloadJob", onDelete: .cascade)
                t.column("expectedVersionId", .text).notNull()
                t.column("expectedRevision", .text)
                t.column("targetRevision", .text)
                t.column("sourceEpoch", .text).notNull()
                t.column("authorizationId", .text).notNull()
                t.check(sql: "targetRevision IS NULL OR length(targetRevision) > 0")
            }
        }
    }
}
