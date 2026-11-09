import Foundation

extension URLSessionConfiguration {
    /// Transport configuration for bulk downloads. The flags make the system refuse expensive
    /// (cellular, hotspot) and constrained (Low Data Mode) paths at the transport, independent of
    /// `BulkDownloadPolicy`. Each access returns a fresh configuration, so callers can mutate it.
    /// The resource limit bounds one asset's whole transfer, so it allows a large page on a slow
    /// connection.
    nonisolated static var bulkDownload: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.urlCredentialStorage = nil
        return configuration
    }
}
