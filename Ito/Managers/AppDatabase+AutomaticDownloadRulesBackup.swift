import GRDB

extension AppDatabase {
    /// Lets a backup carry automatic download rules. Only `backupCapability` changes: it is rebuilt exactly as v26
    /// rebuilt it, with v26's component list plus `automaticDownloadRules` before `legacyStateArchive`. The rule
    /// table itself already exists (v27) and is unchanged.
    ///
    /// Foreign-key checks are deferred by GRDB around the migration, so this migration issues no PRAGMA of its own.
    nonisolated static func registerAutomaticDownloadRulesBackupMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v28") { db in
            try db.execute(sql: "ALTER TABLE backupCapability RENAME TO backupCapability_beforeAutomaticRules")
            try db.create(table: "backupCapability") { t in
                t.primaryKey("component", .text)
                t.column("representation", .text).notNull()
                t.check(sql: """
                    component IN (
                      'libraryCore', 'readingHistory', 'sourceMappings', 'scalarAppPreferences',
                      'readProgressAndResume', 'trackerLinks', 'updateBadges', 'repositories',
                      'userImporterAliases', 'pluginIdentityAndAliases', 'pluginSettings',
                      'legacyUnscopedMediaState', 'savedLibraryThumbnails', 'downloadPresets',
                      'automaticDownloadRules', 'legacyStateArchive'
                    )
                    """)
                t.check(sql: "representation IN ('representedEmpty', 'representedNonempty')")
            }
            try db.execute(sql: """
                INSERT INTO backupCapability (component, representation)
                SELECT component, representation FROM backupCapability_beforeAutomaticRules
                """)
            try db.drop(table: "backupCapability_beforeAutomaticRules")
        }
    }
}
