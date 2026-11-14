import GRDB

extension AppDatabase {
    /// Widens the portable component allowlist without changing any shipped migration or granting freshness.
    ///
    /// The table is rebuilt the way v8 built it, so the text primary key keeps the NOT NULL constraint GRDB
    /// adds for it; SQLite would otherwise accept a NULL component.
    nonisolated static func registerPortableThumbnailsMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v25") { db in
            try db.execute(sql: "ALTER TABLE backupCapability RENAME TO backupCapability_beforeThumbnails")
            try db.create(table: "backupCapability") { t in
                t.primaryKey("component", .text)
                t.column("representation", .text).notNull()
                t.check(sql: """
                    component IN (
                      'libraryCore', 'readingHistory', 'sourceMappings', 'scalarAppPreferences',
                      'readProgressAndResume', 'trackerLinks', 'updateBadges', 'repositories',
                      'userImporterAliases', 'pluginIdentityAndAliases', 'pluginSettings',
                      'legacyUnscopedMediaState', 'legacyStateArchive', 'savedLibraryThumbnails'
                    )
                    """)
                t.check(sql: "representation IN ('representedEmpty', 'representedNonempty')")
            }
            try db.execute(sql: """
                INSERT INTO backupCapability (component, representation)
                SELECT component, representation FROM backupCapability_beforeThumbnails
                """)
            try db.drop(table: "backupCapability_beforeThumbnails")
        }
    }
}
