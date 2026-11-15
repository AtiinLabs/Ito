import Foundation

extension URLSessionConfiguration {
    /// Transport configuration for bulk downloads that keeps to an unmetered path. The flags make the system
    /// refuse expensive (cellular, hotspot) and constrained (Low Data Mode) paths at the transport, independent
    /// of `NetworkPolicy`. Each access returns a fresh configuration, so callers can mutate it. The resource
    /// limit bounds one asset's whole transfer, so it allows a large page on a slow connection.
    nonisolated static var bulkDownload: URLSessionConfiguration {
        bulkDownload(allowingExpensiveAccess: false)
    }

    /// The bulk configuration for a transfer the policy admitted on an expensive path: the system may use
    /// cellular or a hotspot, because the configured mode or the batch's consent says so. Low Data Mode is
    /// refused either way: no mode or consent overrides it.
    nonisolated static func bulkDownload(allowingExpensiveAccess: Bool) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.allowsExpensiveNetworkAccess = allowingExpensiveAccess
        configuration.allowsConstrainedNetworkAccess = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.urlCredentialStorage = nil
        return configuration
    }
}
