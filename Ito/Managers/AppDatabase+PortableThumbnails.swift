import GRDB

extension AppDatabase {
    /// Widens the portable component allowlist without changing any shipped migration or granting freshness.
    nonisolated static func registerPortableThumbnailsMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v25") { db in
            try db.execute(sql: "ALTER TABLE backupCapability RENAME TO backupCapability_beforeThumbnails")
            try db.execute(sql: """
                CREATE TABLE backupCapability (
                  component TEXT PRIMARY KEY,
                  representation TEXT NOT NULL CHECK(representation IN ('representedEmpty', 'representedNonempty')),
                  CHECK(component IN (
                    'libraryCore', 'readingHistory', 'sourceMappings', 'scalarAppPreferences',
                    'readProgressAndResume', 'trackerLinks', 'updateBadges', 'repositories',
                    'userImporterAliases', 'pluginIdentityAndAliases', 'pluginSettings',
                    'legacyUnscopedMediaState', 'legacyStateArchive', 'savedLibraryThumbnails'
                  ))
                );
                INSERT INTO backupCapability (component, representation)
                SELECT component, representation FROM backupCapability_beforeThumbnails;
                DROP TABLE backupCapability_beforeThumbnails;
                """)
        }
    }
}
