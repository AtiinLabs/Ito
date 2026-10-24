import Foundation
import GRDB

nonisolated final class PluginCompletionObservation: TransactionObserver, @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var changed = false

    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        eventKind.tableName == PluginCompletionScope.tableName
            || eventKind.tableName == PluginCompletionScope.outboxTableName
    }

    func databaseDidChange() { markChanged() }
    func databaseDidChange(with event: DatabaseEvent) { markChanged() }

    private func markChanged() {
        lock.lock()
        changed = true
        lock.unlock()
        stopObservingDatabaseChangesUntilNextTransaction()
    }

    func databaseDidCommit(_ db: Database) {
        lock.lock()
        let notify = changed
        changed = false
        lock.unlock()
        if notify { onChange() }
    }

    func databaseDidRollback(_ db: Database) {
        lock.lock()
        changed = false
        lock.unlock()
    }
}
