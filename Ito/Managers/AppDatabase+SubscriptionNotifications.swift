import GRDB

extension AppDatabase {
    /// Remembers which events that wait for a person already had their notification decided.
    ///
    /// `notifiedAt` is written by exactly one writer: the claim of `OfflineChapterStore.claimSubscriptionAttention`.
    /// An event is claimed once, whether or not a notification could be posted, so turning the setting on later
    /// never announces what was already there. Reopening, editing or discarding an event leaves the column alone.
    /// The partial index serves the claim, which only ever looks for open events that were not claimed yet.
    ///
    /// The version number is the one the integration will order: automatic-download backup (S6c) takes v28 in its own
    /// branch, so this migration is registered after v27 and numbered v29. Both are additive and independent.
    nonisolated static func registerSubscriptionNotificationsMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v29") { db in
            try db.execute(sql: """
                ALTER TABLE subscriptionEvent ADD COLUMN notifiedAt DATETIME;
                CREATE INDEX idx_subscriptionEvent_unnotifiedAttention ON subscriptionEvent(subscriptionId)
                  WHERE decision IN ('needsChoice','needsReview') AND notifiedAt IS NULL;
                """)
        }
    }
}
