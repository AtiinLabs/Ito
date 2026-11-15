import GRDB

extension AppDatabase {
    /// Registers the migrations from v16 on, in version order. Each later schema change adds its
    /// registration here, after the newest one, so the order lives in one place.
    nonisolated static func registerExtensionMigrations(_ migrator: inout DatabaseMigrator) {
        registerMultiKindSourceMappingMigration(&migrator)
        registerHistoryChapterDetailsMigration(&migrator)
        registerOfflineChaptersMigration(&migrator)
        registerDownloadBatchesMigration(&migrator)
        registerLibraryOfflineMetadataMigration(&migrator)
        registerEditionPreferencesMigration(&migrator)
        registerHistoryScanlatorIdentityMigration(&migrator)
        registerLibraryCountBasisMigration(&migrator)
        registerPortableThumbnailsMigration(&migrator)
    }

    nonisolated private static func registerMultiKindSourceMappingMigration(_ migrator: inout DatabaseMigrator) {
        // MARK: - v16: Multi-kind source mappings
        migrator.registerMigration("v16") { db in
            try db.execute(sql: "ALTER TABLE sourceMapping RENAME TO sourceMapping_v15")
            try db.create(table: "sourceMapping") { t in
                t.column("canonicalProvider", .text).notNull()
                t.column("canonicalMediaId", .text).notNull()
                t.column("mediaType", .text).notNull()
                t.column("pluginId", .text).notNull()
                t.column("pluginMediaKey", .text).notNull()

                t.column("decision", .text).notNull()
                t.column("matchMethod", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("titleSnapshot", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()

                t.column("coverURLSnapshot", .text)
                t.column("encodedPayload", .blob)
                t.column("payloadVersion", .integer)
                t.column("pluginVersion", .text)
                t.column("lastVerifiedAt", .datetime)

                t.primaryKey(["canonicalProvider", "canonicalMediaId", "mediaType", "pluginId", "pluginMediaKey"])

                t.check(sql: "mediaType IN ('manga', 'anime', 'novel')")
            }
            try db.execute(sql: """
                INSERT INTO sourceMapping (
                    canonicalProvider,
                    canonicalMediaId,
                    mediaType,
                    pluginId,
                    pluginMediaKey,
                    decision,
                    matchMethod,
                    confidence,
                    titleSnapshot,
                    createdAt,
                    updatedAt,
                    coverURLSnapshot,
                    encodedPayload,
                    payloadVersion,
                    pluginVersion,
                    lastVerifiedAt
                )
                SELECT
                    canonicalProvider,
                    canonicalMediaId,
                    mediaType,
                    pluginId,
                    pluginMediaKey,
                    decision,
                    matchMethod,
                    confidence,
                    titleSnapshot,
                    createdAt,
                    updatedAt,
                    coverURLSnapshot,
                    encodedPayload,
                    payloadVersion,
                    pluginVersion,
                    lastVerifiedAt
                FROM sourceMapping_v15
                """)
            try db.drop(table: "sourceMapping_v15")
            try db.create(
                index: "idx_sourceMapping_canonical",
                on: "sourceMapping",
                columns: ["canonicalProvider", "canonicalMediaId", "mediaType", "decision"]
            )
            try db.create(
                index: "idx_sourceMapping_plugin",
                on: "sourceMapping",
                columns: ["pluginId", "pluginMediaKey"]
            )
        }
    }
}
