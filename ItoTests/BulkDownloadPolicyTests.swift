import ito_runner
import Foundation
import Testing
@testable import Ito

struct NetworkPolicyTests {
    @Test func modePathIntentConsentMatrix() {
        for mode in NetworkDownloadMode.allCases {
            for intent in NetworkIntent.allCases {
                for consent in [false, true] {
                    var configuration = NetworkPolicyConfiguration.defaults
                    configuration.downloadMode = mode
                    for status in [NetworkPathSnapshot.Status.unknown, .unsatisfied, .requiresConnection, .satisfied] {
                        for expensive in [false, true] {
                            for constrained in [false, true] {
                                let path = NetworkPathSnapshot(status: status, isExpensive: expensive, isConstrained: constrained)
                                let result = NetworkPolicy.evaluate(intent, path: path, configuration: configuration, hasBatchConsent: consent)
                                if status == .unsatisfied || status == .requiresConnection { #expect(result == .wait(.noConnection)); continue }
                                if status == .unknown { #expect(result == (intent == .interactive ? .allow : .wait(.networkUnknown))); continue }
                                if intent == .interactive { #expect(result == .allow); continue }
                                let deniedMetered: Bool
                                switch intent {
                                case .manualBulkDownload, .automaticBulkDownload:
                                    deniedMetered = mode == .unmeteredOnly || (mode == .askMetered && !consent)
                                case .speculativePrefetch: deniedMetered = true
                                default: deniedMetered = false
                                }
                                #expect((result == .allow) == (!constrained && !(expensive && deniedMetered)))
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func wifiOnlyAppliesOnlyToAutomaticMetadata() {
        var configuration = NetworkPolicyConfiguration.defaults
        configuration.wifiOnlyUpdates = true
        let path = NetworkPathSnapshot(status: .satisfied, isExpensive: true)
        #expect(NetworkPolicy.evaluate(.automaticMetadata, path: path, configuration: configuration) == .wait(.wifiOnlyUpdates))
        #expect(NetworkPolicy.evaluate(.interactive, path: path, configuration: configuration) == .allow)
    }

    @Test func speculativeProjectionDoesNotRewriteConfiguration() {
        var configuration = NetworkPolicyConfiguration.defaults
        configuration.preloadImageCount = 15
        #expect(NetworkPolicy.projection(configuration: configuration, path: .init(status: .satisfied, isExpensive: true)).imagePreloadCount == 0)
        #expect(NetworkPolicy.projection(configuration: configuration, path: .init(status: .satisfied)).imagePreloadCount == 15)
        configuration.preloadImageCount = 0
        #expect(NetworkPolicy.projection(configuration: configuration, path: .init(status: .satisfied)).adjacentChapterPrefetch == 0)
    }

    @Test func consentIsExactAndExpiresIrreversibly() throws {
        let path = ManualNetworkPathObserver(initial: .init(status: .satisfied, isExpensive: true))
        var configuration = NetworkPolicyConfiguration.defaults
        configuration.downloadMode = .askMetered
        let policy = NetworkPolicyCenter(configuration: configuration, path: path)
        let contexts = PluginNetworkContexts(policy: policy)
        let batch = UUID()
        let binding = contexts.consentBinding(batchID: batch, pluginID: "fixture")
        #expect(policy.mintBatchConsent(binding) == nil)
        policy.enterForeground()
        #expect(policy.mintBatchConsent(binding) != nil)
        #expect(policy.hasValidConsent(binding))
        #expect(!policy.hasValidConsent(contexts.consentBinding(batchID: UUID(), pluginID: "fixture")))
        #expect(!policy.hasValidConsent(contexts.consentBinding(batchID: batch, pluginID: "other")))
        policy.mintBatchConsent(binding)
        policy.enterBackground()
        policy.enterForeground()
        #expect(!policy.hasValidConsent(binding))
        policy.mintBatchConsent(binding)
        path.set(.init(status: .satisfied))
        path.set(.init(status: .satisfied, isExpensive: true))
        #expect(!policy.hasValidConsent(binding))
        policy.mintBatchConsent(binding)
        configuration.wifiOnlyUpdates.toggle()
        policy.apply(configuration)
        #expect(!policy.hasValidConsent(binding))
        policy.mintBatchConsent(binding)
        contexts.replaceEpochs([:])
        #expect(!policy.hasValidConsent(binding))
    }

    @Test func staleContextIsNeverUpgraded() {
        let path = ManualNetworkPathObserver(initial: .init(status: .satisfied))
        let policy = NetworkPolicyCenter(path: path)
        let contexts = PluginNetworkContexts(policy: policy)
        let old = contexts.context(pluginID: "fixture", .init(purpose: .manualBulkDownload, operationID: UUID()))
        let gate = NetworkPathAdmissionGate(observer: path, policy: policy)
        var configuration = policy.current
        configuration.downloadMode = .allowMetered
        policy.apply(configuration)
        configuration.downloadMode = .unmeteredOnly
        policy.apply(configuration)
        #expect(!gate.isCurrent(old))
        #expect(gate.isCurrent(contexts.context(pluginID: "fixture", .init(purpose: .manualBulkDownload, operationID: UUID()))))
    }
}
