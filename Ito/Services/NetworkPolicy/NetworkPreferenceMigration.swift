import Foundation
import GRDB

/// Derives the network preferences a store does not have yet, from what it does have.
///
/// A key is absent when it has no row at all. A row that holds zero or false is a stored choice and is never
/// touched; an invalid row is left to the settings store's load-issue handling. Nothing here overwrites a row.
nonisolated enum NetworkPreferenceMigration {
    /// Rows to insert for the absent network preferences, derived once:
    /// - the download mode is `unmeteredOnly`, for an existing and for a new installation;
    /// - the adjacent-chapter prefetch amount follows the stored image preload: a stored zero gives zero, any other
    ///   preload gives two (the two-sided prefetch earlier builds always did), and an installation with no preload
    ///   row yet gets the default, two.
    static func missingRows(in rows: [AppPreference]) -> [AppPreference] {
        let keys = Set(rows.map(\.key))
        var missing: [AppPreference] = []
        if !keys.contains(AppPreferenceKeys.networkDownloadMode),
           let row = try? AppPreference(
               key: AppPreferenceCatalog.networkDownloadMode,
               value: AppPreferenceCatalog.networkDownloadMode.defaultValue
           ) {
            missing.append(row)
        }
        if !keys.contains(AppPreferenceKeys.adjacentChapterPrefetchCount) {
            let preload = rows.last { $0.key == AppPreferenceKeys.preloadImageCount }
            if let row = try? AppPreference(
                key: AppPreferenceCatalog.adjacentChapterPrefetchCount,
                value: adjacentAmount(derivedFromPreload: preload)
            ) {
                missing.append(row)
            }
        }
        return missing
    }

    static func adjacentAmount(derivedFromPreload preload: AppPreference?) -> AdjacentChapterPrefetchPreference {
        guard let preload,
              let stored = try? preload.decodedValue(for: AppPreferenceCatalog.preloadImageCount) else {
            return AppPreferenceCatalog.adjacentChapterPrefetchCount.defaultValue
        }
        return stored == .none ? .none : .two
    }

    /// Inserts the absent network preferences inside the caller's write transaction, so no reader sees a
    /// materialized default for them before the derived value exists.
    static func insertMissing(in db: Database) throws {
        for row in missingRows(in: try AppPreference.fetchAll(db)) {
            try row.insert(db, onConflict: .ignore)
        }
    }
}
