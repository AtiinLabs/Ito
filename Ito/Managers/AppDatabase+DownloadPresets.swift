import GRDB

extension AppDatabase {
    /// Custom download presets and "Download N More" batch provenance.
    ///
    /// - `downloadBatch` is rebuilt in the SQLite 12-step order (create, copy, drop, rename). It must not be renamed
    ///   first: since SQLite 3.26 a rename rewrites the foreign keys of `downloadJob`, which would then point at the
    ///   dropped table. `downloadBatch` has no indexes or triggers to recreate.
    /// - `backupCapability` is rebuilt as v25 did, with the v25 component list plus `downloadPresets`.
    /// - `downloadPresetDefinition` is created. It is the single authority for custom definitions and is a backup
    ///   component.
    ///
    /// Foreign-key checks are deferred by GRDB around the migration, so this migration issues no PRAGMA of its own.
    nonisolated static func registerDownloadPresetsMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v26") { db in
            try db.execute(sql: """
                CREATE TABLE downloadBatch_v26 (
                  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
                  pluginId TEXT NOT NULL,
                  mediaKind TEXT NOT NULL CHECK(mediaKind IN ('manga','novel')),
                  canonicalMediaId TEXT NOT NULL,
                  preset TEXT NOT NULL CHECK(preset IN ('single','next','next5','next10','unread','all','custom','more')),
                  windowKind TEXT CHECK(windowKind IS NULL OR windowKind IN ('next','more')),
                  positionCount INTEGER CHECK(positionCount IS NULL OR (typeof(positionCount) = 'integer' AND positionCount BETWEEN 1 AND 1000)),
                  customPresetId TEXT CHECK(customPresetId IS NULL OR length(customPresetId) = 36),
                  selection BLOB NOT NULL,
                  catalogDigest TEXT CHECK(catalogDigest IS NULL OR length(catalogDigest) = 64),
                  entrySnapshot BLOB NOT NULL,
                  createdAt DATETIME NOT NULL,
                  CHECK ((preset IN ('custom','more')) = (windowKind IS NOT NULL)),
                  CHECK ((windowKind IS NULL) = (positionCount IS NULL)),
                  CHECK ((preset = 'custom') = (customPresetId IS NOT NULL)),
                  CHECK (preset != 'more' OR windowKind = 'more')
                );
                INSERT INTO downloadBatch_v26
                  (id, pluginId, mediaKind, canonicalMediaId, preset, windowKind, positionCount, customPresetId,
                   selection, catalogDigest, entrySnapshot, createdAt)
                SELECT id, pluginId, mediaKind, canonicalMediaId, preset, NULL, NULL, NULL,
                   selection, catalogDigest, entrySnapshot, createdAt
                FROM downloadBatch;
                DROP TABLE downloadBatch;
                ALTER TABLE downloadBatch_v26 RENAME TO downloadBatch;
                """)

            // Rebuilt the way v25 rebuilt it: the text primary key keeps the NOT NULL constraint.
            try db.execute(sql: "ALTER TABLE backupCapability RENAME TO backupCapability_beforeDownloadPresets")
            try db.create(table: "backupCapability") { t in
                t.primaryKey("component", .text)
                t.column("representation", .text).notNull()
                t.check(sql: """
                    component IN (
                      'libraryCore', 'readingHistory', 'sourceMappings', 'scalarAppPreferences',
                      'readProgressAndResume', 'trackerLinks', 'updateBadges', 'repositories',
                      'userImporterAliases', 'pluginIdentityAndAliases', 'pluginSettings',
                      'legacyUnscopedMediaState', 'savedLibraryThumbnails', 'downloadPresets',
                      'legacyStateArchive'
                    )
                    """)
                t.check(sql: "representation IN ('representedEmpty', 'representedNonempty')")
            }
            try db.execute(sql: """
                INSERT INTO backupCapability (component, representation)
                SELECT component, representation FROM backupCapability_beforeDownloadPresets
                """)
            try db.drop(table: "backupCapability_beforeDownloadPresets")

            try db.execute(sql: """
                CREATE TABLE downloadPresetDefinition (
                  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) = 36),
                  name TEXT CHECK(name IS NULL OR (typeof(name) = 'text' AND length(CAST(name AS BLOB)) BETWEEN 1 AND 256)),
                  windowKind TEXT NOT NULL CHECK(windowKind IN ('next','more')),
                  positionCount INTEGER NOT NULL CHECK(typeof(positionCount) = 'integer' AND positionCount BETWEEN 1 AND 1000),
                  sortIndex INTEGER NOT NULL UNIQUE CHECK(typeof(sortIndex) = 'integer' AND sortIndex BETWEEN 0 AND 19)
                );
                """)
        }
    }
}
