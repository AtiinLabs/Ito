import GRDB

extension AppDatabase {
    // MARK: - v18: Offline chapters
    /// Installation-local inventory of downloaded chapters, the download queue, and the binding to
    /// the offline files directory. None of these tables is a backup component: backups carry no
    /// rows, and a restored database reconciles its queue into a paused state.
    nonisolated static func registerOfflineChaptersMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v18") { db in
            try db.execute(sql: """
                CREATE TABLE downloadedChapter (
                  pluginId TEXT NOT NULL,
                  mediaKind TEXT NOT NULL CHECK(mediaKind IN ('manga','novel')),
                  canonicalMediaId TEXT NOT NULL,
                  chapterKey TEXT NOT NULL,
                  authorityScope TEXT NOT NULL CHECK(authorityScope IN ('publicUnscoped')),
                  versionId TEXT NOT NULL UNIQUE CHECK(length(versionId) = 36),
                  state TEXT NOT NULL CHECK(state IN ('verified','damaged')),
                  damageReason TEXT CHECK(damageReason IS NULL OR damageReason IN ('manifestMismatch','pageMismatch','manifestUnreadable')),
                  contentKind TEXT NOT NULL CHECK(contentKind IN ('images','text','mixed')),
                  pageCount INTEGER NOT NULL CHECK(pageCount > 0),
                  byteCount INTEGER NOT NULL CHECK(byteCount >= 0),
                  manifestFormatVersion INTEGER NOT NULL CHECK(manifestFormatVersion >= 1),
                  manifestSHA256 TEXT NOT NULL CHECK(length(manifestSHA256) = 64),
                  chapterSnapshot BLOB NOT NULL,
                  seriesTitle TEXT NOT NULL,
                  sourceEpoch TEXT,
                  verifiedAt DATETIME NOT NULL,
                  CHECK ((state = 'damaged') = (damageReason IS NOT NULL)),
                  PRIMARY KEY (pluginId, mediaKind, canonicalMediaId, chapterKey, authorityScope)
                );
                CREATE INDEX idx_downloadedChapter_media
                  ON downloadedChapter(pluginId, mediaKind, canonicalMediaId);
                CREATE TABLE downloadJob (
                  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
                  pluginId TEXT NOT NULL,
                  mediaKind TEXT NOT NULL CHECK(mediaKind IN ('manga','novel')),
                  canonicalMediaId TEXT NOT NULL,
                  chapterKey TEXT NOT NULL,
                  authorityScope TEXT NOT NULL CHECK(authorityScope IN ('publicUnscoped')),
                  entrySnapshot BLOB NOT NULL,
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
                CREATE TABLE downloadStore (
                  id INTEGER PRIMARY KEY NOT NULL CHECK(id = 1),
                  storeId TEXT NOT NULL CHECK(length(storeId) = 36),
                  createdAt DATETIME NOT NULL
                );
                """)
        }
    }
}
