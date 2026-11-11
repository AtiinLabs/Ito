import XCTest
import ito_runner
@testable import Ito

@MainActor
extension MediaDetailViewModelTests {
    func testStartLoadsAsSeriesMetadataAndRefreshAsManualCatalogRefresh() async {
        let subject = makeMangaSubject()
        subject.route.loadResponses = [
            .suspended,
            .value(manga(key: "m1", title: "Second"))
        ]

        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            subject.route.onLoadSuspended = {
                subject.route.onLoadSuspended = nil
                started.resume()
            }
            subject.viewModel.start()
        }
        subject.route.resolveLoad(at: 0, with: .success(manga(key: "m1", title: "First")))
        await subject.viewModel.refresh()

        let operations = subject.route.loadOperations
        XCTAssertEqual(operations.map(\.purpose), [.seriesMetadata, .manualCatalogRefresh])
        XCTAssertNotEqual(operations[0].operationID, operations[1].operationID)
    }
}
