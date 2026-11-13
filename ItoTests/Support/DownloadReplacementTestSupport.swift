import Foundation
import Testing
@testable import Ito

extension DownloadWorkerFixture {
    /// The frozen preview a confirmation shows for the published chapter-1 copy. Fails the test when the copy
    /// cannot be replaced from its source.
    func confirmablePreview() async throws -> DownloadReplacementPreview {
        let request = OfflineStoreFixture.request()
        let access = try await center.replacementPreview(
            media: MediaDetailDownloadsFake.series, entry: request.entry,
            chapter: request.chapter, seriesTitle: request.seriesTitle
        )
        return try #require(access.preview)
    }
}
