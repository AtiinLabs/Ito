import Foundation
import Testing
@testable import Ito

@MainActor
struct PluginTrustRecoveryTests {
    @Test func confirmingTheObservedCertificateThenRetryingClearsTheFailure() async throws {
        let fixture = Fixture()
        await fixture.model.loadIfNeeded()
        #expect(fixture.model.failurePendingTrust == fixture.request)
        #expect(fixture.model.phase == .failure("Certificate refused"))

        try fixture.trust.confirm(fixture.request)
        await fixture.model.retry()

        #expect(fixture.model.phase == .empty)
        #expect(fixture.model.failurePendingTrust == nil)
        #expect(fixture.trust.pending(pluginID: fixture.request.pluginID) == nil)
    }

    @Test func anUnrelatedLaterFailureDoesNotOfferAStaleCertificate() async {
        let fixture = Fixture()
        fixture.provider.next.homeResult = .failure(PluginCallError(kind: .reported, message: "Offline"))
        await fixture.model.loadIfNeeded()
        #expect(fixture.model.failurePendingTrust == fixture.request)

        await fixture.model.retry()

        #expect(fixture.model.phase == .failure("Offline"))
        #expect(fixture.model.failurePendingTrust == nil)
        #expect(fixture.trust.pending(pluginID: fixture.request.pluginID) == nil)
    }
    @MainActor private struct Fixture {
        let trust = PluginTrustStore(keychain: InMemoryPluginSecretKeychain())
        let request: PendingTrust
        let provider: CertificateProvider
        let model: SourceViewModel

        init() {
            let plugin = pr7bPlugin()
            request = PendingTrust(pluginID: plugin.id, host: "server.local", fingerprint: "observed-certificate")
            provider = CertificateProvider(trust: trust, request: request)
            let publisher = PR7BPluginStatePublisherSpy()
            publisher.currentPlugins[plugin.id] = plugin
            model = SourceViewModel(
                plugin: plugin,
                runnerProvider: provider,
                pluginStatePublisher: publisher,
                fileDeletion: PR7BFileDeletionSpy(),
                messagePresenter: PR7BMessagePresenterSpy(),
                searchDebounceNanoseconds: nil
            )
        }
    }
}

/// First request observes a refused certificate. The following request either succeeds or
/// reports an unrelated failure, so the view model must not keep the old trust action.
@MainActor
private final class CertificateProvider: SourceRunnerProviding {
    let next = PR7BSourceRunnerContextSpy()
    private let trust: PluginTrustStore
    private let request: PendingTrust
    private var first = true

    init(trust: PluginTrustStore, request: PendingTrust) {
        self.trust = trust
        self.request = request
    }

    func sourceRunnerContext(for pluginID: String) async throws -> any SourceRunnerContext {
        guard first else { return next }
        first = false
        trust.recordPending(request)
        let refused = PR7BSourceRunnerContextSpy()
        refused.homeResult = .failure(PluginCallError(kind: .reported, message: "Certificate refused"))
        return refused
    }

    func evictSourceRunner(for pluginID: String) {}
    func pendingTrust(for pluginID: String) -> PendingTrust? { trust.pending(pluginID: pluginID) }
    func clearPendingTrust(for pluginID: String) { trust.clearPending(pluginID: pluginID) }
}
