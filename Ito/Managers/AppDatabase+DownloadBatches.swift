import GRDB

extension AppDatabase {
    // MARK: - v19: Download batches
    /// Moves the frozen series snapshot of a download from every job to one `downloadBatch` row, so a
    /// bulk request stores the series once. Jobs reference their batch and carry their position in it.
    /// Existing jobs each become a one-chapter `single` batch that follows the source's list. Also adds
    /// the origin identity a moved copy's manifest is checked against and the record of deliberately
    /// deleted downloads. Like the v18 tables, none of these is a backup component.
    nonisolated static func registerDownloadBatchesMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v19") { db in
            try db.execute(sql: """
                CREATE TABLE downloadBatch (
                  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
                  pluginId TEXT NOT NULL,
                  mediaKind TEXT NOT NULL CHECK(mediaKind IN ('manga','novel')),
                  canonicalMediaId TEXT NOT NULL,
                  preset TEXT NOT NULL CHECK(preset IN ('single','next','next5','next10','unread','all')),
                  selection BLOB NOT NULL,
                  catalogDigest TEXT CHECK(catalogDigest IS NULL OR length(catalogDigest) = 64),
                  entrySnapshot BLOB NOT NULL,
                  createdAt DATETIME NOT NULL
                );
                CREATE TABLE downloadJob_v19 (
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
                    'integrityMismatch','fileSystem')),
                  stagingVersionId TEXT UNIQUE,
                  attemptCount INTEGER NOT NULL DEFAULT 0 CHECK(attemptCount >= 0),
                  createdAt DATETIME NOT NULL,
                  updatedAt DATETIME NOT NULL,
                  CHECK ((state = 'waiting') = (waitingReason IS NOT NULL)),
                  CHECK ((state = 'failed') = (failureReason IS NOT NULL)),
                  CHECK ((state = 'downloading') = (stagingVersionId IS NOT NULL)),
                  UNIQUE (pluginId, mediaKind, canonicalMediaId, chapterKey, authorityScope)
                );
                """)
            // One `single` batch per existing job, with the job's id so the pair stays traceable.
            try db.execute(
                sql: """
                    INSERT INTO downloadBatch
                      (id, pluginId, mediaKind, canonicalMediaId, preset, selection, catalogDigest, entrySnapshot, createdAt)
                    SELECT id, pluginId, mediaKind, canonicalMediaId, 'single', ?, NULL, entrySnapshot, createdAt
                    FROM downloadJob
                    """,
                arguments: [DownloadBatchRecord.sourceListSelection]
            )
            try db.execute(sql: """
                INSERT INTO downloadJob_v19
                  (id, batchId, sequence, pluginId, mediaKind, canonicalMediaId, chapterKey, authorityScope,
                   chapterSnapshot, seriesTitle, sourceEpoch, state, waitingReason, failureReason,
                   stagingVersionId, attemptCount, createdAt, updatedAt)
                SELECT id, id, 0, pluginId, mediaKind, canonicalMediaId, chapterKey, authorityScope,
                   chapterSnapshot, seriesTitle, sourceEpoch, state, waitingReason, failureReason,
                   stagingVersionId, attemptCount, createdAt, updatedAt
                FROM downloadJob;
                DROP TABLE downloadJob;
                ALTER TABLE downloadJob_v19 RENAME TO downloadJob;
                CREATE INDEX idx_downloadJob_queue ON downloadJob(state, createdAt, batchId, sequence, id);
                CREATE INDEX idx_downloadJob_batch ON downloadJob(batchId);
                ALTER TABLE downloadedChapter ADD COLUMN originIdentity BLOB;
                CREATE TABLE downloadSuppression (
                  pluginId TEXT NOT NULL,
                  mediaKind TEXT NOT NULL CHECK(mediaKind IN ('manga','novel')),
                  canonicalMediaId TEXT NOT NULL,
                  chapterKey TEXT NOT NULL,
                  authorityScope TEXT NOT NULL CHECK(authorityScope IN ('publicUnscoped')),
                  suppressedAt DATETIME NOT NULL,
                  PRIMARY KEY (pluginId, mediaKind, canonicalMediaId, chapterKey, authorityScope)
                );
                """)
        }
    }
}
