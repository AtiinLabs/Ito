import Foundation
import GRDB

nonisolated enum PluginImageCacheEpochError: Error, Equatable, Sendable {
    case invalidOrMissingEpoch
}

nonisolated enum PluginImageCacheEpoch {
    static let tableName = "pluginImageCacheEpoch"

    static func isValidEpoch(_ epoch: String) -> Bool {
        epoch.count == 32 && epoch.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
        }
    }

    static func current(in db: Database) throws -> String? {
        guard try db.tableExists(tableName) else {
            return nil
        }
        guard let epoch = try String.fetchOne(
            db,
            sql: "SELECT epoch FROM \(tableName) WHERE id = 1"
        ) else {
            return nil
        }
        guard isValidEpoch(epoch) else {
            return nil
        }
        return epoch
    }

    static func rotate(in db: Database) throws {
        guard try db.tableExists(tableName) else { return }
        try db.execute(sql: """
            UPDATE \(tableName)
            SET epoch = lower(hex(randomblob(16)))
            WHERE id = 1
            """)
        if db.changesCount == 0 {
            try db.execute(sql: """
                INSERT INTO \(tableName) (id, epoch)
                VALUES (1, lower(hex(randomblob(16))))
                ON CONFLICT(id) DO UPDATE SET epoch = lower(hex(randomblob(16)))
                """)
        }
        guard let updated = try String.fetchOne(
            db,
            sql: "SELECT epoch FROM \(tableName) WHERE id = 1"
        ), isValidEpoch(updated) else {
            throw PluginImageCacheEpochError.invalidOrMissingEpoch
        }
    }
}

nonisolated final class PluginImageCacheEpochObservation: TransactionObserver, @unchecked Sendable {
    private let onChange: @Sendable (String?) -> Void
    private let lock = NSLock()
    private var epochChangedInTransaction = false

    internal init(onChange: @escaping @Sendable (String?) -> Void) {
        self.onChange = onChange
    }

    internal func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        eventKind.tableName == PluginImageCacheEpoch.tableName
    }

    private func markEpochChanged() {
        lock.lock()
        epochChangedInTransaction = true
        lock.unlock()
        stopObservingDatabaseChangesUntilNextTransaction()
    }

    internal func databaseDidChange() {
        markEpochChanged()
    }

    internal func databaseDidChange(with event: DatabaseEvent) {
        markEpochChanged()
    }

    internal func databaseDidCommit(_ db: Database) {
        lock.lock()
        let didChange = epochChangedInTransaction
        epochChangedInTransaction = false
        lock.unlock()

        guard didChange else { return }

        do {
            let epoch = try PluginImageCacheEpoch.current(in: db)
            onChange(epoch)
        } catch {
            onChange(nil)
        }
    }

    internal func databaseDidRollback(_ db: Database) {
        lock.lock()
        epochChangedInTransaction = false
        lock.unlock()
    }
}
