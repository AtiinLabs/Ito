import Foundation
import GRDB

nonisolated enum PluginCompletionScopeError: Error, Equatable, Sendable {
    case invalidMetadata
    case configurationChanged
    case invalidSettingEncoding
}

nonisolated enum PluginCompletionScope {
    static let tableName = "pluginCompletionScope"
    static let outboxTableName = "pluginCompletionOutbox"

    static func capture(pluginID: String, in db: Database) throws -> String {
        try db.execute(
            sql: """
                INSERT INTO pluginCompletionScope(pluginId, epoch)
                VALUES (?, lower(hex(randomblob(16)))) ON CONFLICT(pluginId) DO NOTHING
                """,
            arguments: [pluginID]
        )
        guard let epoch = try current(pluginID: pluginID, in: db) else {
            throw PluginCompletionScopeError.invalidMetadata
        }
        return epoch
    }

    static func current(pluginID: String, in db: Database) throws -> String? {
        guard let epoch = try String.fetchOne(
            db, sql: "SELECT epoch FROM pluginCompletionScope WHERE pluginId = ?", arguments: [pluginID]
        ) else { return nil }
        guard PluginImageCacheEpoch.isValidEpoch(epoch) else {
            throw PluginCompletionScopeError.invalidMetadata
        }
        return epoch
    }

    /// Called in the same writer transaction as image-cache invalidation, before Keychain mutation.
    static func rotate(pluginID: String?, in db: Database) throws {
        let hasScope = try db.tableExists(tableName)
        let hasOutbox = try db.tableExists(outboxTableName)
        guard hasScope || hasOutbox else { return } // Bootstrapping a pre-v14 database.
        guard hasScope && hasOutbox else { throw PluginCompletionScopeError.invalidMetadata }
        if let pluginID {
            try db.execute(
                sql: """
                    INSERT INTO pluginCompletionScope(pluginId, epoch)
                    VALUES (?, lower(hex(randomblob(16))))
                    ON CONFLICT(pluginId) DO UPDATE SET epoch = excluded.epoch
                    """,
                arguments: [pluginID]
            )
        } else {
            try db.execute(sql: "UPDATE pluginCompletionScope SET epoch = lower(hex(randomblob(16)))")
        }
    }
}
