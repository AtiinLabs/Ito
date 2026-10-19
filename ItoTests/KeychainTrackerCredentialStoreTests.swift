import Foundation
import Security
import Testing
@testable import Ito

@Suite(.serialized)
struct KeychainTrackerCredentialStoreTests {
    @Test func systemAddQueryUsesOnlyExactDeviceLocalGenericPasswordAttributes() throws {
        let data = Data("fixture-token".utf8)
        let query = try #require(
            SystemKeychainSecurityClient.addQuery(
                data: data,
                service: "test-service",
                account: "anilist"
            ) as? [CFString: Any]
        )

        #expect(query.count == 5)
        #expect(query[kSecClass] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService] as? String == "test-service")
        #expect(query[kSecAttrAccount] as? String == "anilist")
        #expect(query[kSecAttrAccessible] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(query[kSecValueData] as? Data == data)
        #expect(query[kSecAttrAccessGroup] == nil)
        #expect(query[kSecAttrSynchronizable] == nil)
    }

    @Test func realKeychainCRUDUsesOneExactGenericPasswordItem() async throws {
        let service = "moe.itoapp.ito.tests.\(UUID().uuidString)"
        let providerID = "anilist-\(UUID().uuidString)"

        deleteItem(service: service, account: providerID)

        let store = KeychainTrackerCredentialStore(service: service)
        defer { deleteItem(service: service, account: providerID) }

        #expect(try await store.token(for: providerID) == nil)

        try await store.setToken("fixture-token-one", for: providerID)
        #expect(try await store.token(for: providerID) == "fixture-token-one")

        try await store.setToken("fixture-token-two", for: providerID)
        #expect(try await store.token(for: providerID) == "fixture-token-two")

        let attributes = try #require(itemAttributes(service: service, account: providerID))
        #expect(attributes[kSecAttrAccessible] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable] == nil || attributes[kSecAttrSynchronizable] as? Bool == false)
        #expect(itemCount(service: service, account: providerID) == 1)

        try await store.removeToken(for: providerID)
        #expect(try await store.token(for: providerID) == nil)
        try await store.removeToken(for: providerID)
    }

    @Test func statusPolicyClassifiesKnownFailures() {
        #expect(KeychainStatusPolicy.error(for: errSecInteractionNotAllowed, operation: .read) == .protectedDataUnavailable(errSecInteractionNotAllowed))
        #expect(KeychainStatusPolicy.error(for: errSecNotAvailable, operation: .add) == .protectedDataUnavailable(errSecNotAvailable))
        #expect(KeychainStatusPolicy.error(for: errSecAuthFailed, operation: .read) == .accessDenied(errSecAuthFailed))
        #expect(KeychainStatusPolicy.error(for: errSecUserCanceled, operation: .delete) == .accessDenied(errSecUserCanceled))
        #expect(KeychainStatusPolicy.error(for: errSecMissingEntitlement, operation: .add) == .configuration(errSecMissingEntitlement))
        #expect(KeychainStatusPolicy.error(for: errSecParam, operation: .update) == .configuration(errSecParam))
        #expect(KeychainStatusPolicy.error(for: -9_999, operation: .delete) == .unexpected(operation: .delete, status: -9_999))
    }

    @Test func readAndDeleteTreatOnlyItemNotFoundAsAbsenceOrSuccess() async throws {
        let client = ScriptedKeychainClient(
            copyResults: [(errSecItemNotFound, nil), (errSecInteractionNotAllowed, nil)],
            deleteResults: [errSecItemNotFound, errSecNotAvailable]
        )
        let store = KeychainTrackerCredentialStore(service: "test-service", client: client)

        #expect(try await store.token(for: "anilist") == nil)
        await #expect(throws: TrackerCredentialStoreError.protectedDataUnavailable(errSecInteractionNotAllowed)) {
            try await store.token(for: "anilist")
        }
        try await store.removeToken(for: "anilist")
        await #expect(throws: TrackerCredentialStoreError.protectedDataUnavailable(errSecNotAvailable)) {
            try await store.removeToken(for: "anilist")
        }
    }

    @Test func duplicateAddRecoversByExactReadThenUpdateWithoutDelete() async throws {
        let client = ScriptedKeychainClient(
            copyResults: [(errSecSuccess, Data("older-fixture".utf8))],
            updateResults: [errSecItemNotFound, errSecSuccess],
            addResults: [errSecDuplicateItem]
        )
        let store = KeychainTrackerCredentialStore(service: "test-service", client: client)

        try await store.setToken("newer-fixture", for: "anilist")

        #expect(client.recordedOperations == [
            .update(service: "test-service", account: "anilist"),
            .add(service: "test-service", account: "anilist"),
            .copy(service: "test-service", account: "anilist"),
            .update(service: "test-service", account: "anilist")
        ])
    }

    @Test func duplicateAddRereadFailurePropagatesWithoutReplacementOrDelete() async {
        let client = ScriptedKeychainClient(
            copyResults: [(errSecInteractionNotAllowed, nil)],
            updateResults: [errSecItemNotFound],
            addResults: [errSecDuplicateItem]
        )
        let store = KeychainTrackerCredentialStore(service: "test-service", client: client)

        await #expect(throws: TrackerCredentialStoreError.protectedDataUnavailable(errSecInteractionNotAllowed)) {
            try await store.setToken("newer-fixture", for: "anilist")
        }
        #expect(client.recordedOperations == [
            .update(service: "test-service", account: "anilist"),
            .add(service: "test-service", account: "anilist"),
            .copy(service: "test-service", account: "anilist")
        ])
    }

    @Test func malformedAndEmptyCredentialDataIsRejected() async {
        let client = ScriptedKeychainClient(copyResults: [
            (errSecSuccess, Data()),
            (errSecSuccess, Data([0xFF]))
        ])
        let store = KeychainTrackerCredentialStore(service: "test-service", client: client)

        await #expect(throws: TrackerCredentialStoreError.invalidData) {
            try await store.token(for: "anilist")
        }
        await #expect(throws: TrackerCredentialStoreError.invalidData) {
            try await store.token(for: "anilist")
        }
        await #expect(throws: TrackerCredentialStoreError.invalidData) {
            try await store.setToken("", for: "anilist")
        }
    }

    @Test func errorsAndFakeOperationsAreRedacted() async throws {
        let fixture = "fixture-secret-value-with-unique-fragment"
        let errors: [TrackerCredentialStoreError] = [
            .protectedDataUnavailable(errSecInteractionNotAllowed),
            .accessDenied(errSecAuthFailed),
            .invalidData,
            .configuration(errSecMissingEntitlement),
            .unexpected(operation: .add, status: -9_999)
        ]

        for error in errors {
            let description = try #require(error.errorDescription)
            #expect(!description.contains(fixture))
            #expect(!description.contains("unique-fragment"))
            #expect(!description.contains(String(fixture.utf8.count)))
        }

        let fake = FakeTrackerCredentialStore(readResults: [.success(fixture)])
        #expect(try await fake.token(for: "anilist") == fixture)
        try await fake.setToken(fixture, for: "anilist")
        try await fake.removeToken(for: "anilist")
        #expect(await fake.recordedOperations() == [
            .read(providerID: "anilist"),
            .set(providerID: "anilist"),
            .remove(providerID: "anilist")
        ])
    }
}

nonisolated private final class ScriptedKeychainClient: KeychainSecurityClient, @unchecked Sendable {
    nonisolated enum Operation: Equatable {
        case copy(service: String, account: String)
        case update(service: String, account: String)
        case add(service: String, account: String)
        case delete(service: String, account: String)
    }

    private let lock = NSLock()
    private var copyResults: [(OSStatus, Data?)]
    private var updateResults: [OSStatus]
    private var addResults: [OSStatus]
    private var deleteResults: [OSStatus]
    private var operations: [Operation] = []

    init(
        copyResults: [(OSStatus, Data?)] = [],
        updateResults: [OSStatus] = [],
        addResults: [OSStatus] = [],
        deleteResults: [OSStatus] = []
    ) {
        self.copyResults = copyResults
        self.updateResults = updateResults
        self.addResults = addResults
        self.deleteResults = deleteResults
    }

    var recordedOperations: [Operation] {
        lock.withLock { operations }
    }

    func copyTokenData(service: String, account: String) -> (OSStatus, Data?) {
        lock.withLock {
            operations.append(.copy(service: service, account: account))
            return copyResults.isEmpty ? (errSecItemNotFound, nil) : copyResults.removeFirst()
        }
    }

    func updateTokenData(_ data: Data, service: String, account: String) -> OSStatus {
        lock.withLock {
            operations.append(.update(service: service, account: account))
            return updateResults.isEmpty ? errSecSuccess : updateResults.removeFirst()
        }
    }

    func addTokenData(_ data: Data, service: String, account: String) -> OSStatus {
        lock.withLock {
            operations.append(.add(service: service, account: account))
            return addResults.isEmpty ? errSecSuccess : addResults.removeFirst()
        }
    }

    func deleteTokenData(service: String, account: String) -> OSStatus {
        lock.withLock {
            operations.append(.delete(service: service, account: account))
            return deleteResults.isEmpty ? errSecSuccess : deleteResults.removeFirst()
        }
    }
}

private func deleteItem(service: String, account: String) {
    SecItemDelete([
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account
    ] as CFDictionary)
}

private func itemAttributes(service: String, account: String) -> [CFString: Any]? {
    var result: CFTypeRef?
    let status = SecItemCopyMatching([
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecReturnAttributes: true,
        kSecMatchLimit: kSecMatchLimitOne
    ] as CFDictionary, &result)
    guard status == errSecSuccess else { return nil }
    return result as? [CFString: Any]
}

private func itemCount(service: String, account: String) -> Int {
    var result: CFTypeRef?
    let status = SecItemCopyMatching([
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecReturnAttributes: true,
        kSecMatchLimit: kSecMatchLimitAll
    ] as CFDictionary, &result)
    guard status == errSecSuccess else { return 0 }
    if let items = result as? [[CFString: Any]] { return items.count }
    return result == nil ? 0 : 1
}
