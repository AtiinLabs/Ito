import GRDB

extension AppDatabase {
    // MARK: - v21: Series edition preferences
    /// Adds the scanlators a user chose to download for a series, kept when they ask to remember the choice.
    ///
    /// `selection` holds `EditionSelection` JSON (`storageData()`), which the table never reads: a choice
    /// is a filter the user picked, not the identity of a stored chapter. Like the offline chapter tables,
    /// it is installation-local and not a backup component.
    nonisolated static func registerEditionPreferencesMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v21") { db in
            try db.execute(sql: """
                CREATE TABLE seriesEditionPreference (
                  pluginId TEXT NOT NULL,
                  mediaKind TEXT NOT NULL CHECK(mediaKind IN ('manga','novel')),
                  canonicalMediaId TEXT NOT NULL,
                  selection BLOB NOT NULL,
                  updatedAt DATETIME NOT NULL,
                  PRIMARY KEY (pluginId, mediaKind, canonicalMediaId)
                );
                """)
        }
    }
}
