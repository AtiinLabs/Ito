import GRDB

extension AppDatabase {
    // MARK: - v17: History chapter numbers
    /// Chapter and episode numbers, so history can name a chapter without a title. Null for rows
    /// written before v17 and for chapters the source gives no number. History keeps one row per
    /// chapter from v17 on, so earlier visits to the same chapter are folded into the newest.
    nonisolated static func registerHistoryChapterNumberMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v17") { db in
            try db.alter(table: "readingHistory") { t in
                t.add(column: "chapterNumber", .double)
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
