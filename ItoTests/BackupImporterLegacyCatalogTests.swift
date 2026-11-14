import Foundation
import GRDB
import Testing
@testable import Ito

/// A native backup written before the reader's group-switch setting existed carries the earlier,
/// still complete twenty-key scalar catalog. Restore treats the newer key as absent, never as missing.
struct BackupImporterLegacyCatalogTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func backupDatabase(keys: [AppPreferenceCatalogEntry], extra: [AppPreference] = []) async throws -> TestDatabase {
        let database = try TestDatabase()
        try await database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM libraryCategory")
            try BackupMetadataRecord(formatVersion: 1, createdAt: date).insert(db)
            try BackupCapabilityRecord(
                component: .scalarAppPreferences,
                representation: .representedNonempty
            ).insert(db)
            for entry in keys {
                try AppPreference(key: entry.rawValue, value: entry.canonicalDefaultJSON).insert(db)
            }
            for preference in extra { try preference.insert(db) }
        }
        return database
    }

    @Test func nativeScalarCapabilityAcceptsTheEarlierTwentyKeyCatalog() async throws {
        let legacy = try await backupDatabase(
            keys: AppPreferenceCatalogEntry.allCases.filter { $0 != .askBeforeSwitchingGroups }
        )
        defer { legacy.cleanup() }

        let parsed = try await ItoNativeImporter().parse(url: legacy.databaseURL)

        #expect(parsed.preferences.count == AppPreferenceCatalogEntry.allCases.count - 1)
        #expect(!parsed.representedPreferenceKeys.contains(AppPreferenceKeys.askBeforeSwitchingGroups))
    }

    @Test func aMissingRequiredKeyStillFailsTheCatalogClosed() async throws {
        let missing = try await backupDatabase(
            keys: AppPreferenceCatalogEntry.allCases.filter {
                $0 != .askBeforeSwitchingGroups && $0 != .appTheme
            }
        )
        defer { missing.cleanup() }

        await #expect(
            throws: BackupPreflightError.rejected(
                .invalidCapabilityMetadata(
                    component: .scalarAppPreferences,
                    code: "incompletePreferenceCatalog"
                )
            )
        ) {
            _ = try await ItoNativeImporter().parse(url: missing.databaseURL)
        }
    }

    @Test func anUnknownKeyStillFailsTheCatalogClosed() async throws {
        let unknown = try await backupDatabase(
            keys: AppPreferenceCatalogEntry.allCases,
            extra: [AppPreference(key: "future-key", value: Data([1]))]
        )
        defer { unknown.cleanup() }

        await #expect(throws: (any Error).self) {
            _ = try await ItoNativeImporter().parse(url: unknown.databaseURL)
        }
    }
}
