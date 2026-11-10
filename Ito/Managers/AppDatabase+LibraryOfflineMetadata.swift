import GRDB

extension AppDatabase {
    // MARK: - v20: Offline Library metadata
    /// Adds what the Library needs to look right without a network: when a saved series' details were last
    /// refreshed from its source, and a small durable copy of its cover.
    ///
    /// `librarySnapshotState` describes the `libraryItem.rawPayload` it was written for; its digest says
    /// which one. The catalog scope and completeness are kept in separate columns, as the source reports
    /// them, so a catalog that is complete but filtered is never mistaken for the whole series. Both are
    /// `unknown` until a source says otherwise. An empty catalog is never recorded.
    ///
    /// `libraryCoverThumbnail` follows its Library item and is removed with it. Like the offline chapter
    /// tables, neither table is a backup component: a restored payload has an unknown age, and a thumbnail
    /// is captured again from the next successful cover load.
    nonisolated static func registerLibraryOfflineMetadataMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v20") { db in
            try db.execute(sql: """
                CREATE TABLE librarySnapshotState (
                  pluginId TEXT NOT NULL,
                  mediaKind TEXT NOT NULL CHECK(mediaKind IN ('manga','novel','anime')),
                  canonicalMediaId TEXT NOT NULL,
                  payloadSHA256 TEXT NOT NULL CHECK(length(payloadSHA256) = 64),
                  refreshedAt DATETIME NOT NULL,
                  catalogScope TEXT NOT NULL CHECK(catalogScope IN ('unknown','visible','allEligible')),
                  catalogCompleteness TEXT NOT NULL CHECK(catalogCompleteness IN ('unknown','partial','complete')),
                  chapterRowCount INTEGER NOT NULL CHECK(chapterRowCount > 0),
                  PRIMARY KEY (pluginId, mediaKind, canonicalMediaId)
                );
                CREATE TABLE libraryCoverThumbnail (
                  libraryItemId TEXT PRIMARY KEY NOT NULL REFERENCES libraryItem(id) ON DELETE CASCADE,
                  coverURLSHA256 TEXT NOT NULL CHECK(length(coverURLSHA256) = 64),
                  imageData BLOB NOT NULL CHECK(length(imageData) BETWEEN 1 AND 262144),
                  pixelWidth INTEGER NOT NULL CHECK(pixelWidth BETWEEN 1 AND 1024),
                  pixelHeight INTEGER NOT NULL CHECK(pixelHeight BETWEEN 1 AND 1536),
                  storedAt DATETIME NOT NULL
                );
                """)
        }
    }
}
