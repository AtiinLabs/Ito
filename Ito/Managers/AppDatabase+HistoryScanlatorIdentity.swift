import GRDB

extension AppDatabase {
    // MARK: - v22: History scanlator identity
    /// Persists the source-scoped group ID captured with each chapter visit. Existing history and
    /// imported rows remain unknown rather than being matched by display name.
    nonisolated static func registerHistoryScanlatorIdentityMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v22") { db in
            try db.alter(table: "readingHistory") { t in
                t.add(column: "scanlatorID", .text)
            }
        }
    }
}
