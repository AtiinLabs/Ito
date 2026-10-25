import Foundation
import Security
import Testing
@testable import Ito

@Suite("Plugin trust store")
struct PluginTrustStoreTests {
    // Self-signed test certificate for 127.0.0.1, generated under /tmp without private key committed.
    private static let testCertBase64 =
        "MIIC6DCCAdCgAwIBAgIUMhgKH8Ai9NhUyUTT4eMcQpw0e/YwDQYJKoZIhvcNAQELBQAwFDESMBAGA1UEAwwJMTI3LjAuMC4xMB4XDTI2MTAyNDE0NDEwN1oXDTM2MTAyMTE0NDEwN1owFDESMBAGA1UEAwwJMTI3LjAuMC4xMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoEYrX1YmERraiXXbE1zmdu+NyHJMrwhLr2Ct8mAh+Z/hrSYzkswri3Sw5xdzQizpIlct+OX7Z8kDzTaasK4Hey7/863vCarAMLMu44Jp1dN9Sswu7FiNDFTYcn9N/KXLKbHEOQ8mLFZJzOn6J54pFL8+vppYzfTMPzf2NomrQ31NZnPXcPWVtLKRyIj2F0fRHDOqVaFAPYAZAeivWsL76UbikOLTPidTf0aHGjD0emntiO4Na0OWyDTI5ipy2CopMrhD4v6vk6PElO4fylofIDRVtIVDSuQDIMBbd+2BTKPM/kk8WL9d+ZXh45S+VqvwbAM6jYXZsNjsHaSFaAMr/QIDAQAB"
        + "ozIwMDAdBgNVHQ4EFgQU4VmDbG3XLfyV4QBp4pxbkdNF+b0wDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAe6FSPgelJyahWtAWtgZT/EmId5cnydNczJATvzs6oCvRUd68/hdDC1icZxrcg8cZy5Ce/f99qQa4Q+9vMfZ3ytTimEErcQGNJpuKbsJ6drIqVyVAtp+NnH96vxIHXAyNkjAYXD5QD2fMaRLEkNEIifq8e+VV1XD9Nh9bKsyjR85xM0t1LZtp5PKJGy5a2x7jESEyTGhmaH9bYx4lddZbgYmCwwHMNYOSB8+A2IXOSp1YH1eJIRFK2H9VDjD7a8anhey8qPaFnIecHHsziE+pNKIqjZ05oXH55SPqS2pTdU7TPVqKIO8BxiU+KZkZFBt0NuuuIPng7WbzZGlhpsitBw=="

    private static let testCertFingerprint = "25FBD9B293CFE8ECC405E67B5DFEEFB997E502E0F3FAB3B8736A73262913F4A4"

    @Test func aCorruptKeychainItemCannotBeOverwrittenByANewPin() throws {
        let keychain = InMemoryPluginSecretKeychain()
        let corrupt = Data("not a pin map".utf8)
        #expect(keychain.setData(corrupt, account: "plugin-a") == errSecSuccess)
        let store = PluginTrustStore(keychain: keychain)
        #expect(store.pinnedFingerprint(pluginID: "plugin-a", host: "a.local") == nil)
        #expect(throws: PluginSecretStoreError(status: errSecDecode)) {
            try store.trust(fingerprint: Self.testCertFingerprint, host: "b.local", pluginID: "plugin-a")
        }
        #expect(keychain.data(account: "plugin-a").1 == corrupt)
    }

    @Test func aBackgroundEvaluationDoesNotChangeForegroundConfirmation() throws {
        let store = PluginTrustStore(keychain: InMemoryPluginSecretKeychain())
        let pending = PendingTrust(pluginID: "plugin-a", host: "foreground.local", fingerprint: "foreground")
        store.recordPending(pending)
        let trust = try makeTestSecTrust(host: "127.0.0.1")
        #expect(store.evaluate(
            trust: trust, host: "127.0.0.1", pluginID: "plugin-a", recordsPending: false
        ) == .refused)
        #expect(store.pending(pluginID: "plugin-a") == pending)
    }

    @Test func trustStoresPinsWithPluginAndHostIsolation() throws {
        let keychain = InMemoryPluginSecretKeychain()
        let store = PluginTrustStore(keychain: keychain)

        try store.trust(fingerprint: "AA11", host: "Komga.Local", pluginID: "plugin-a")
        try store.trust(fingerprint: "BB22", host: "suwayomi.local", pluginID: "plugin-a")
        try store.trust(fingerprint: "CC33", host: "komga.local", pluginID: "plugin-b")

        #expect(store.pinnedFingerprint(pluginID: "plugin-a", host: "komga.local") == "AA11")
        #expect(store.pinnedFingerprint(pluginID: "plugin-a", host: "KOMGA.LOCAL") == "AA11")
        #expect(store.pinnedFingerprint(pluginID: "plugin-a", host: "suwayomi.local") == "BB22")
        #expect(store.pinnedFingerprint(pluginID: "plugin-b", host: "komga.local") == "CC33")
        #expect(store.pinnedFingerprint(pluginID: "plugin-b", host: "suwayomi.local") == nil)
        #expect(store.pinnedFingerprint(pluginID: "plugin-other", host: "komga.local") == nil)
    }

    @Test func pinPersistsAndReopensAcrossNewStoreInstances() throws {
        let keychain = InMemoryPluginSecretKeychain()
        let store1 = PluginTrustStore(keychain: keychain)
        try store1.trust(fingerprint: "AA11", host: "server.local", pluginID: "plugin-a")

        let store2 = PluginTrustStore(keychain: keychain)
        #expect(store2.pinnedFingerprint(pluginID: "plugin-a", host: "server.local") == "AA11")
    }

    @Test func trustingHostReplacesExistingPin() throws {
        let keychain = InMemoryPluginSecretKeychain()
        let store = PluginTrustStore(keychain: keychain)

        try store.trust(fingerprint: "OLD1", host: "server.local", pluginID: "plugin-a")
        #expect(store.pinnedFingerprint(pluginID: "plugin-a", host: "server.local") == "OLD1")

        try store.trust(fingerprint: "NEW2", host: "server.local", pluginID: "plugin-a")
        #expect(store.pinnedFingerprint(pluginID: "plugin-a", host: "server.local") == "NEW2")
    }

    @Test func confirmStaleRequestThrowsAndSavesNoPinWhileConfirmCurrentSucceedsAndClears() throws {
        let keychain = InMemoryPluginSecretKeychain()
        let store = PluginTrustStore(keychain: keychain)

        let requestA = PendingTrust(pluginID: "plugin-a", host: "server.local", fingerprint: "FINGERPRINT_A")
        let requestB = PendingTrust(pluginID: "plugin-a", host: "server.local", fingerprint: "FINGERPRINT_B")

        store.recordPending(requestA)
        #expect(store.pending(pluginID: "plugin-a") == requestA)

        // Replace pending with B
        store.recordPending(requestB)
        #expect(store.pending(pluginID: "plugin-a") == requestB)

        // Confirming stale request A throws PluginTrustConfirmationError.staleRequest and saves no pin
        #expect(throws: PluginTrustConfirmationError.staleRequest) {
            try store.confirm(requestA)
        }
        #expect(store.pinnedFingerprint(pluginID: "plugin-a", host: "server.local") == nil)
        #expect(store.pending(pluginID: "plugin-a") == requestB)

        // Confirming current request B succeeds, stores pin, and clears pending
        try store.confirm(requestB)
        #expect(store.pinnedFingerprint(pluginID: "plugin-a", host: "server.local") == "FINGERPRINT_B")
        #expect(store.pending(pluginID: "plugin-a") == nil)
    }

    @Test func clearPendingRemovesPendingEntry() {
        let store = PluginTrustStore(keychain: InMemoryPluginSecretKeychain())
        store.recordPending(PendingTrust(pluginID: "plugin-a", host: "server.local", fingerprint: "F1"))
        #expect(store.pending(pluginID: "plugin-a") != nil)

        store.clearPending(pluginID: "plugin-a")
        #expect(store.pending(pluginID: "plugin-a") == nil)
    }

    @Test func removeAllForPluginDeletesOnlyThatPluginPinsAndPending() throws {
        let keychain = InMemoryPluginSecretKeychain()
        let store = PluginTrustStore(keychain: keychain)

        try store.trust(fingerprint: "AA11", host: "a.local", pluginID: "plugin-a")
        try store.trust(fingerprint: "BB22", host: "b.local", pluginID: "plugin-b")
        store.recordPending(PendingTrust(pluginID: "plugin-a", host: "a.local", fingerprint: "AA11"))
        store.recordPending(PendingTrust(pluginID: "plugin-b", host: "b.local", fingerprint: "BB22"))

        try store.removeAll(pluginID: "plugin-a")

        #expect(store.pinnedFingerprint(pluginID: "plugin-a", host: "a.local") == nil)
        #expect(store.pending(pluginID: "plugin-a") == nil)
        #expect(store.pinnedFingerprint(pluginID: "plugin-b", host: "b.local") == "BB22")
        #expect(store.pending(pluginID: "plugin-b") != nil)
    }

    @Test func removeEveryPluginClearsAllPluginsPinsAndPending() throws {
        let keychain = InMemoryPluginSecretKeychain()
        let store = PluginTrustStore(keychain: keychain)

        try store.trust(fingerprint: "AA11", host: "a.local", pluginID: "plugin-a")
        try store.trust(fingerprint: "BB22", host: "b.local", pluginID: "plugin-b")
        store.recordPending(PendingTrust(pluginID: "plugin-a", host: "a.local", fingerprint: "AA11"))
        store.recordPending(PendingTrust(pluginID: "plugin-b", host: "b.local", fingerprint: "BB22"))

        try store.removeEveryPlugin()

        #expect(store.pinnedFingerprint(pluginID: "plugin-a", host: "a.local") == nil)
        #expect(store.pinnedFingerprint(pluginID: "plugin-b", host: "b.local") == nil)
        #expect(store.pending(pluginID: "plugin-a") == nil)
        #expect(store.pending(pluginID: "plugin-b") == nil)
        #expect(keychain.storedAccounts.isEmpty)
    }

    @Test func writeFailureThrowsErrorAndClearsCacheEntry() throws {
        let keychain = InMemoryPluginSecretKeychain()
        let store = PluginTrustStore(keychain: keychain)

        try store.trust(fingerprint: "INITIAL", host: "a.local", pluginID: "plugin-a")
        #expect(store.pinnedFingerprint(pluginID: "plugin-a", host: "a.local") == "INITIAL")

        keychain.failingStatus = errSecIO
        #expect(throws: PluginSecretStoreError.self) {
            try store.trust(fingerprint: "UPDATED", host: "a.local", pluginID: "plugin-a")
        }

        keychain.failingStatus = nil
        #expect(store.pinnedFingerprint(pluginID: "plugin-a", host: "a.local") == "INITIAL")
    }

    @Test func observersHearEveryTrustChangeOfTheirSourceButNotAFailedWrite() throws {
        let keychain = InMemoryPluginSecretKeychain()
        let store = PluginTrustStore(keychain: keychain)
        let heard = ObservedGenerations()
        let other = ObservedGenerations()
        // Callbacks read the store again: they must run outside its lock.
        let watched = store.observeTrustChanges(pluginID: "plugin-a") {
            heard.record(store.transportGeneration(for: "plugin-a"))
        }
        let otherWatched = store.observeTrustChanges(pluginID: "plugin-b") {
            other.record(store.transportGeneration(for: "plugin-b"))
        }
        #expect(store.transportGeneration(for: "plugin-a") == watched.generation)

        try store.trust(fingerprint: "AA11", host: "a.local", pluginID: "plugin-a")
        let confirmation = PendingTrust(pluginID: "plugin-a", host: "a.local", fingerprint: "BB22")
        store.recordPending(confirmation)
        try store.confirm(confirmation)
        #expect(heard.count == 2)
        #expect(heard.latest != watched.generation)

        keychain.failingStatus = errSecIO
        #expect(throws: PluginSecretStoreError.self) {
            try store.trust(fingerprint: "CC33", host: "a.local", pluginID: "plugin-a")
        }
        #expect(heard.count == 2)
        // The pin is revoked in memory first, so even a failed delete is a change.
        #expect(throws: PluginSecretStoreError.self) {
            try store.removeAll(pluginID: "plugin-a")
        }
        #expect(heard.count == 3)
        keychain.failingStatus = nil
        #expect(other.count == 0)

        try store.removeEveryPlugin()
        #expect(heard.count == 4)
        #expect(other.count == 1)

        watched.observation.cancel()
        try store.trust(fingerprint: "DD44", host: "a.local", pluginID: "plugin-a")
        try store.trust(fingerprint: "EE55", host: "b.local", pluginID: "plugin-b")
        #expect(heard.count == 4)
        #expect(other.count == 2)
        withExtendedLifetime(otherWatched.observation) {}
    }

    @Test func aFailedRemovalKeepsPinsUnusableUntilARetrySucceedsAndTheSourceIsReinstalled() throws {
        let keychain = InMemoryPluginSecretKeychain()
        let store = PluginTrustStore(keychain: keychain)
        let secTrust = try makeTestSecTrust(host: "127.0.0.1")
        try store.trust(fingerprint: Self.testCertFingerprint, host: "127.0.0.1", pluginID: "plugin-a")
        try store.trust(fingerprint: Self.testCertFingerprint, host: "127.0.0.1", pluginID: "plugin-b")

        keychain.failingStatus = errSecIO
        #expect(throws: PluginSecretStoreError.self) {
            try store.removeAll(pluginID: "plugin-a")
        }
        keychain.failingStatus = nil

        // The pin is still in the Keychain, but it no longer authorizes anything, nor can the
        // source be offered or given trust again, even after a reload publishes it.
        store.activateInstalledPlugin("plugin-a")
        #expect(store.evaluate(trust: secTrust, host: "127.0.0.1", pluginID: "plugin-a") == .refused)
        #expect(store.pending(pluginID: "plugin-a") == nil)
        #expect(throws: PluginTrustConfirmationError.revoked) {
            try store.trust(fingerprint: Self.testCertFingerprint, host: "127.0.0.1", pluginID: "plugin-a")
        }
        #expect(store.evaluate(trust: secTrust, host: "127.0.0.1", pluginID: "plugin-b") == .pinned)

        try store.removeAll(pluginID: "plugin-a")
        #expect(keychain.storedAccounts == ["plugin-b"])
        #expect(store.evaluate(trust: secTrust, host: "127.0.0.1", pluginID: "plugin-a") == .refused)

        // A reinstall starts without trust and asks again.
        store.activateInstalledPlugin("plugin-a")
        #expect(store.evaluate(trust: secTrust, host: "127.0.0.1", pluginID: "plugin-a") == .refused)
        #expect(store.pending(pluginID: "plugin-a")?.fingerprint == Self.testCertFingerprint)
        try store.trust(fingerprint: Self.testCertFingerprint, host: "127.0.0.1", pluginID: "plugin-a")
        #expect(store.evaluate(trust: secTrust, host: "127.0.0.1", pluginID: "plugin-a") == .pinned)
    }

    @Test func aFailedCleanupOfEveryPluginRefusesEveryPinUntilACleanupSucceeds() throws {
        let keychain = InMemoryPluginSecretKeychain()
        let store = PluginTrustStore(keychain: keychain)
        let secTrust = try makeTestSecTrust(host: "127.0.0.1")
        try store.trust(fingerprint: Self.testCertFingerprint, host: "127.0.0.1", pluginID: "plugin-a")

        keychain.failingStatus = errSecInteractionNotAllowed
        #expect(throws: PluginSecretStoreError.self) {
            try store.removeEveryPlugin()
        }
        keychain.failingStatus = nil

        store.activateInstalledPlugin("plugin-a")
        #expect(store.evaluate(trust: secTrust, host: "127.0.0.1", pluginID: "plugin-a") == .refused)
        #expect(store.pending(pluginID: "plugin-a") == nil)
        #expect(throws: PluginTrustConfirmationError.revoked) {
            try store.trust(fingerprint: Self.testCertFingerprint, host: "127.0.0.1", pluginID: "plugin-new")
        }

        try store.removeEveryPlugin()
        #expect(keychain.storedAccounts.isEmpty)
        try store.trust(fingerprint: Self.testCertFingerprint, host: "127.0.0.1", pluginID: "plugin-a")
        #expect(store.evaluate(trust: secTrust, host: "127.0.0.1", pluginID: "plugin-a") == .pinned)
    }

    @Test func evaluateUnpinnedSelfSignedCertificateReturnsRefusedAndRecordsPending() throws {
        let store = PluginTrustStore(keychain: InMemoryPluginSecretKeychain())
        let secTrust = try makeTestSecTrust(host: "127.0.0.1")

        let decision = store.evaluate(trust: secTrust, host: "127.0.0.1", pluginID: "test-plugin")
        #expect(decision == .refused)

        let pending = store.pending(pluginID: "test-plugin")
        #expect(pending?.pluginID == "test-plugin")
        #expect(pending?.host == "127.0.0.1")
        #expect(pending?.fingerprint == Self.testCertFingerprint)
    }

    @Test func evaluateExactPinnedCertificateReturnsPinned() throws {
        let store = PluginTrustStore(keychain: InMemoryPluginSecretKeychain())
        try store.trust(fingerprint: Self.testCertFingerprint, host: "127.0.0.1", pluginID: "test-plugin")
        let secTrust = try makeTestSecTrust(host: "127.0.0.1")

        let decision = store.evaluate(trust: secTrust, host: "127.0.0.1", pluginID: "test-plugin")
        #expect(decision == .pinned)
    }

    @Test func evaluateChangedPinCertificateReturnsRefusedAndRecordsNewPending() throws {
        let store = PluginTrustStore(keychain: InMemoryPluginSecretKeychain())
        try store.trust(fingerprint: "OLD_FINGERPRINT", host: "127.0.0.1", pluginID: "test-plugin")
        let secTrust = try makeTestSecTrust(host: "127.0.0.1")

        let decision = store.evaluate(trust: secTrust, host: "127.0.0.1", pluginID: "test-plugin")
        #expect(decision == .refused)

        let pending = store.pending(pluginID: "test-plugin")
        #expect(pending?.fingerprint == Self.testCertFingerprint)
    }

    @Test func evaluateMismatchedPluginOrHostCannotReuseTrust() throws {
        let store = PluginTrustStore(keychain: InMemoryPluginSecretKeychain())
        try store.trust(fingerprint: Self.testCertFingerprint, host: "127.0.0.1", pluginID: "plugin-a")
        let secTrust = try makeTestSecTrust(host: "127.0.0.1")

        // Different plugin, same host
        let decisionPluginB = store.evaluate(trust: secTrust, host: "127.0.0.1", pluginID: "plugin-b")
        #expect(decisionPluginB == .refused)

        // Same plugin, different host
        let secTrustOtherHost = try makeTestSecTrust(host: "other.local")
        let decisionOtherHost = store.evaluate(trust: secTrustOtherHost, host: "other.local", pluginID: "plugin-a")
        #expect(decisionOtherHost == .refused)
    }

    // MARK: - Helpers

    private func makeTestSecTrust(host: String) throws -> SecTrust {
        let certData = try #require(Data(base64Encoded: Self.testCertBase64))
        let certificate = try #require(SecCertificateCreateWithData(nil, certData as CFData))
        let policy = SecPolicyCreateSSL(true, host as CFString)
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, policy, &trust)
        #expect(status == errSecSuccess)
        let unwrappedTrust = try #require(trust)
        // Disable network fetch on test trust to stay deterministic.
        SecTrustSetNetworkFetchAllowed(unwrappedTrust, false)
        return unwrappedTrust
    }
}

/// The trust generations an observer saw, in order.
private nonisolated final class ObservedGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [UUID] = []

    var count: Int { lock.withLock { generations.count } }
    var latest: UUID? { lock.withLock { generations.last } }

    func record(_ generation: UUID) {
        lock.withLock { generations.append(generation) }
    }
}
