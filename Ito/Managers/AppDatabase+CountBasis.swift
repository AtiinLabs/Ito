import GRDB

extension AppDatabase {
    // MARK: - v23: Library update-count basis
    /// Records what identity `libraryItem.knownChapterCount` counted. Existing rows stay NULL, so the
    /// first current nonempty refresh adopts the exact-key count without creating an update badge.
    /// v22 is reserved for the independent History group-ID migration.
    nonisolated static func registerLibraryCountBasisMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v23") { db in
            try db.alter(table: "libraryItem") { table in
                table.add(column: "knownChapterCountBasis", .text)
            }
        }
    }
}
