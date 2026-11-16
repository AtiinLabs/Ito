#if DEBUG
import Foundation
import GRDB
import ito_runner

/// Debug-only: seeds what a UI test needs to open a review of new chapters without a source that changes its answer.
/// It uses the store's own entry points, so the rule, its first chapter list and the event that waits for a person are
/// exactly what a real check would have written.
extension AutomaticDownloads {
    nonisolated static let uiTestPluginID = "moe.itoapp.test.reader-consent-fixture"
    nonisolated static let uiTestSeriesID = "ui-test-seeded-series"
    nonisolated static let uiTestSeriesTitle = "Seeded Review Series"
    nonisolated static let uiTestNewChapterTitle = "Seeded Unplaced Chapter"

    /// A saved series with a rule that took its first chapter list of three ordered chapters, and then saw a fourth the
    /// source gave no reading position: that one waits for the person.
    func seedUITestAttentionFixture() async throws {
        let media = MediaIdentity(pluginId: Self.uiTestPluginID, itemId: Self.uiTestSeriesID, mediaKind: .manga)
        try await store.database.write { db in
            guard try LibraryItem.fetchOne(db, key: Self.uiTestSeriesID) == nil else { return }
            try LibraryItem(
                id: Self.uiTestSeriesID, title: Self.uiTestSeriesTitle, coverUrl: nil, pluginId: Self.uiTestPluginID,
                isAnime: false, pluginType: .manga, rawPayload: Data(), anilistId: nil
            ).insert(db)
        }
        let epoch = try sourceEpoch(for: Self.uiTestPluginID)
        guard case .enabled = try await store.enableSubscription(SubscriptionEnableRequest(
            media: media, reviewedSourceEpoch: epoch, configuration: SubscriptionConfiguration()
        )) else { return }

        let ordered = (1...3).reversed().map { number in
            Chapter(key: "seed-\(number)", title: "Seeded Chapter \(number)", logicalUnitID: "unit-\(number)", readingOrder: Int64(number))
        }
        let unplaced = Chapter(key: "seed-new", title: Self.uiTestNewChapterTitle)
        for chapters in [ordered, [unplaced] + ordered] {
            guard let ticket = try await store.beginSubscriptionCheck(media: media, capturedEpoch: epoch) else { return }
            let catalog = ChapterCatalog(scope: .allEligible, completeness: .complete)
            let entry = MediaEntry.manga(Manga(key: Self.uiTestSeriesID, title: Self.uiTestSeriesTitle, chapters: chapters, catalog: catalog))
            guard case .success(let observation) = CatalogObservation.make(
                media: media, entry: entry, pluginVersion: "1.0.0", sourceEpoch: epoch
            ) else { return }
            _ = try await store.commitSubscriptionObservation(ticket, observation, limits: limits)
        }
    }
}
#endif
