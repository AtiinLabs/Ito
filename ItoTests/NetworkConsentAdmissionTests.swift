import Foundation
import ito_runner
import Testing
@testable import Ito

@MainActor
struct NetworkConsentAdmissionTests {
    @MainActor private struct Authority {
        let path = ManualNetworkPathObserver(initial: .init(status: .satisfied, isExpensive: true))
        let policy: NetworkPolicyCenter
        let contexts: PluginNetworkContexts
        let batch = UUID()
        let source = "fixture"
        let epoch = String(repeating: "a", count: 32)

        init() {
            var configuration = NetworkPolicyConfiguration.defaults
            configuration.downloadMode = .askMetered
            policy = NetworkPolicyCenter(configuration: configuration, path: path)
            contexts = PluginNetworkContexts(epochs: [source: epoch], policy: policy)
            policy.enterForeground()
        }

        var binding: NetworkConsentBinding { contexts.consentBinding(batchID: batch, pluginID: source) }
        var scope: UUID { contexts.liveScope(pluginID: source) }

        func operation() -> PluginNetworkOperation {
            var operation = PluginNetworkOperation(
                purpose: .manualBulkDownload, operationID: UUID(), batchID: batch, policyRevision: policy.revision
            )
            operation.scopedGrant = policy.authorizeBatchOperation(binding, operationID: operation.operationID)
            return operation
        }

        func gate(_ operation: PluginNetworkOperation) -> NetworkPathAdmissionGate {
            NetworkPathAdmissionGate(
                observer: path, policy: policy, consent: binding, operation: operation, authorizationScope: scope
            )
        }
    }

    @Test func revokedContextCannotBorrowAReplacementGrantForTheSameBatch() async throws {
        let authority = Authority()
        authority.policy.mintBatchConsent(authority.binding)
        let operation = authority.operation()
        let old = authority.contexts.context(pluginID: authority.source, operation, frozenScope: authority.epoch)
        let gate = authority.gate(operation)
        #expect(gate.isCurrent(old))
        #expect(gate.admission() == .allow)
        authority.policy.revokeConsent(forBatch: authority.batch)
        authority.policy.mintBatchConsent(authority.binding)
        let replacement = authority.operation()
        #expect(replacement.scopedGrant != old.scopedGrant)
        #expect(!gate.isCurrent(old))
        #expect(gate.admission() == .wait(.meteredConsentRequired))
        // Reconstructing an old operation still stamps its original reference, never the replacement.
        #expect(authority.contexts.context(pluginID: authority.source, operation).scopedGrant == old.scopedGrant)
        let inner = ScriptedInnerNet(contexts: NetworkContextRecorder())
        let net = DownloadNetModule(inner: inner, gate: gate, recorder: DownloadPolicyRecorder())
        await #expect(throws: HostNetworkPolicyOutcome.deferred(.policyChanged)) {
            try await net.fetch(request: NetRequest(url: "https://fixture.test/asset", method: "GET", headers: [:], body: nil), context: old)
        }
        #expect(inner.calls.count == 0)
    }

    @Test func nilReferenceStillValidatesFrozenSourceScope() {
        let authority = Authority()
        let operation = authority.operation()
        #expect(operation.scopedGrant == nil)
        let old = authority.contexts.context(pluginID: authority.source, operation, frozenScope: authority.epoch)
        let gate = authority.gate(operation)
        #expect(gate.isCurrent(old))
        authority.contexts.replaceEpochs([authority.source: String(repeating: "b", count: 32)])
        #expect(!gate.isCurrent(old))
    }

    @Test func aValidReferenceDoesNotAuthorizeAnotherOperationLineage() {
        let authority = Authority()
        authority.policy.mintBatchConsent(authority.binding)
        let operation = authority.operation()
        #expect(authority.policy.hasValidConsent(
            authority.binding, reference: operation.scopedGrant, operationID: operation.operationID, authorizationScope: authority.scope
        ))
        #expect(!authority.policy.hasValidConsent(
            authority.binding, reference: operation.scopedGrant, operationID: UUID(), authorizationScope: authority.scope
        ))
        let wrong = PluginNetworkOperation(
            purpose: .manualBulkDownload, operationID: UUID(), batchID: authority.batch,
            scopedGrant: operation.scopedGrant, policyRevision: authority.policy.revision
        )
        #expect(!authority.gate(operation).isCurrent(authority.contexts.context(pluginID: authority.source, wrong)))
        #expect(!authority.policy.hasValidConsent(
            authority.binding, reference: nil, operationID: operation.operationID, authorizationScope: authority.scope
        ))
    }

    @available(iOS 16, *)
    @Test(.timeLimit(.minutes(1)))
    func backgroundRevocationCancelsHeldMeteredTransferWithoutExpiringTheOSGrant() async throws {
        let fixture = try DownloadWorkerFixture()
        fixture.path.set(.init(status: .satisfied, isExpensive: true))
        var configuration = fixture.networkContexts.policy.current
        configuration.downloadMode = .askMetered
        fixture.networkContexts.policy.apply(configuration)
        await fixture.startWorker()
        await fixture.coordinator.untilIdle()
        let held = fixture.fetcher.gate(for: "https://img.test/2.jpg")
        let request = OfflineStoreFixture.batchRequest(chapterKeys: ["chapter-1"])
        let result = await fixture.center.enqueueBatch(request, confirmedMeteredUse: true)
        #expect(result.queued == 1)
        await held.awaitArrival()
        let grants = ManualBackgroundExecutionGranting()
        fixture.coordinator.suspend(allowingInFlightCompletion: grants)
        await held.awaitCancellation()
        await fixture.coordinator.untilIdle()
        await grants.awaitEnded()
        #expect(await held.wasReleased == false)
        #expect(try await fixture.copy() == nil)
        #expect(try await fixture.job()?.waitingReason == .meteredNetwork)
    }

    @Test func cancellingOneChapterKeepsTheBatchConsentForItsSiblings() async throws {
        let fixture = try DownloadWorkerFixture()
        await fixture.coordinator.reconcile()
        fixture.path.set(.init(status: .satisfied, isExpensive: true))
        var configuration = fixture.networkContexts.policy.current
        configuration.downloadMode = .askMetered
        fixture.networkContexts.policy.apply(configuration)
        fixture.networkContexts.policy.enterForeground()
        let result = await fixture.center.enqueueBatch(
            OfflineStoreFixture.batchRequest(chapterKeys: ["chapter-1", "chapter-2"]),
            confirmedMeteredUse: true
        )
        #expect(result.queued == 2)
        let batchID = try #require(result.batchId.flatMap(UUID.init(uuidString:)))
        let actualBinding = fixture.networkContexts.consentBinding(batchID: batchID, pluginID: DownloadWorkerFixture.plugin)
        #expect(fixture.networkContexts.policy.hasValidConsent(actualBinding))

        let first = OfflineChapterEdition(
            pluginId: DownloadWorkerFixture.plugin, mediaKind: .manga, canonicalMediaId: "series-1", chapterKey: "chapter-1"
        )
        try await fixture.center.cancel(first)
        #expect(fixture.networkContexts.policy.hasValidConsent(actualBinding))

        let second = OfflineChapterEdition(
            pluginId: DownloadWorkerFixture.plugin, mediaKind: .manga, canonicalMediaId: "series-1", chapterKey: "chapter-2"
        )
        let secondJob = try #require(try await fixture.store.job(for: second))
        try await fixture.center.cancel(jobIDs: [secondJob.id])
        #expect(!fixture.networkContexts.policy.hasValidConsent(actualBinding))
    }
}
