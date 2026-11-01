import GRDB

extension AppDatabase {
    // MARK: - v17: History chapter details
    /// Chapter details and reader format let history name and reopen a chapter without its key.
    /// Loaded novel body lengths turn saved UTF-16 offsets into percentages. Unknown details and
    /// rows written before v17 stay null. History keeps one row per chapter from v17 on, so earlier
    /// visits to the same chapter are folded into the newest.
    nonisolated static func registerHistoryChapterDetailsMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v17") { db in
            try db.alter(table: "readingHistory") { t in
                t.add(column: "chapterNumber", .double)
                t.add(column: "volume", .double)
                t.add(column: "scanlator", .text)
                t.add(column: "format", .text)
                t.add(column: "textLength", .integer)
            }
            try db.execute(sql: """
                DELETE FROM readingHistory WHERE id IN (
                    SELECT id FROM (
                        SELECT id, ROW_NUMBER() OVER (
                            PARTITION BY pluginId, mediaKind, mediaKey, chapterKey
                            ORDER BY readAt DESC, id DESC
                        ) AS position
                        FROM readingHistory
                    ) WHERE position > 1
                )
                """)
        }
    }
}
