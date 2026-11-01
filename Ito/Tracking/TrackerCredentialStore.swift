import Foundation
import Security

nonisolated protocol TrackerCredentialStoring: Sendable {
    func token(for providerID: String) async throws -> String?
    func setToken(_ token: String, for providerID: String) async throws
    func removeToken(for providerID: String) async throws
}

nonisolated enum TrackerCredentialOperation: String, Sendable {
    case read
    case update
    case add
    case delete
}

nonisolated enum TrackerCredentialStoreError: Error, Equatable, Sendable, LocalizedError {
    case protectedDataUnavailable(OSStatus)
    case accessDenied(OSStatus)
    case invalidData
    case configuration(OSStatus)
    case unexpected(operation: TrackerCredentialOperation, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .protectedDataUnavailable(let status):
            String(localized: "Keychain protected data is unavailable (status \(String(status))).")
        case .accessDenied(let status):
            String(localized: "Keychain access was denied (status \(String(status))).")
        case .invalidData:
            String(localized: "Keychain credential data is invalid.")
        case .configuration(let status):
            String(localized: "Keychain configuration failed (status \(String(status))).")
        case .unexpected(let operation, let status):
            String(localized: "Keychain \(operation.rawValue) failed (status \(String(status))).")
        }
    }
}
