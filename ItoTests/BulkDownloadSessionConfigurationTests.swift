import Foundation
import Testing
@testable import Ito

struct BulkDownloadSessionConfigurationTests {
    @Test func refusesExpensiveAndConstrainedPathsAndNeverWaitsForConnectivity() {
        let configuration = URLSessionConfiguration.bulkDownload

        #expect(configuration.allowsExpensiveNetworkAccess == false)
        #expect(configuration.allowsConstrainedNetworkAccess == false)
        #expect(configuration.waitsForConnectivity == false)
    }

    @Test func usesBoundedTimeoutsAndNoCredentialStorage() {
        let configuration = URLSessionConfiguration.bulkDownload

        #expect(configuration.timeoutIntervalForRequest == 30)
        #expect(configuration.timeoutIntervalForResource == 300)
        #expect(configuration.urlCredentialStorage == nil)
    }

    @Test func eachAccessReturnsAnIndependentConfiguration() {
        let first = URLSessionConfiguration.bulkDownload
        let second = URLSessionConfiguration.bulkDownload

        first.timeoutIntervalForRequest = 1

        #expect(first !== second)
        #expect(second.timeoutIntervalForRequest == 30)
    }
}
