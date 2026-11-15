import Foundation
import ito_runner
@testable import Ito

/// The host context of one direct export call in a test. Every call is a new export with a new generation.
nonisolated func makeTestNetworkContext(
    purpose: NetworkOperationContext.Purpose = .foregroundReading,
    pluginID: String = "plugin.test",
    operationID: UUID = UUID(),
    batchID: UUID? = nil
) -> NetworkOperationContext {
    PluginNetworkContexts(policy: NetworkPolicyCenter()).context(
        pluginID: pluginID,
        PluginNetworkOperation(purpose: purpose, operationID: operationID, batchID: batchID)
    )
}

/// A fresh operation for a test that calls a loader directly.
nonisolated func makeTestNetworkOperation(
    _ purpose: NetworkOperationContext.Purpose = .foregroundReading
) -> PluginNetworkOperation {
    PluginNetworkOperation(purpose: purpose, operationID: UUID())
}
