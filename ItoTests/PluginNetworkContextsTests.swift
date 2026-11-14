import Foundation
import GRDB
import ito_runner
import Testing
@testable import Ito

struct PluginNetworkContextsTests {
    private static let epochA = "0123456789abcdef0123456789abcdef"
    private static let epochB = "fedcba9876543210fedcba9876543210"
    private static let scopeA = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")
    private static let scopeB = UUID(uuidString: "FEDCBA98-7654-3210-FEDC-BA9876543210")

    private static func operation(_ purpose: NetworkOperationContext.Purpose = .foregroundReading) -> PluginNetworkOperation {
        PluginNetworkOperation(purpose: purpose, operationID: UUID())
    }

    @Test func theScopeIsTheEpochBytesMappedOntoAUUID() {
        #expect(PluginNetworkScopeID.uuid(epoch: Self.epochA) == Self.scopeA)
        #expect(PluginNetworkScopeID.uuid(epoch: "not-an-epoch") == nil)
    }

    @Test func theMirrorFollowsTheCommittedEpochsAndAFrozenEpochWins() {
        let contexts = PluginNetworkContexts(epochs: ["plugin.a": Self.epochA], policy: NetworkPolicyCenter())

        #expect(contexts.context(pluginID: "plugin.a", Self.operation()).authorizationScope == Self.scopeA)
        #expect(contexts.context(
            pluginID: "plugin.a", Self.operation(), frozenScope: Self.epochB
        ).authorizationScope == Self.scopeB)

        contexts.replaceEpochs(["plugin.a": Self.epochB])
        #expect(contexts.context(pluginID: "plugin.a", Self.operation()).authorizationScope == Self.scopeB)
        #expect(contexts.context(
            pluginID: "plugin.a", Self.operation(), frozenScope: Self.epochA
        ).authorizationScope == Self.scopeA)
    }

    @Test func twoPluginsNeverShareAScope() {
        let contexts = PluginNetworkContexts(epochs: ["plugin.a": Self.epochA, "plugin.b": Self.epochB], policy: NetworkPolicyCenter())

        let first = contexts.context(pluginID: "plugin.a", Self.operation())
        let second = contexts.context(pluginID: "plugin.b", Self.operation())

        #expect(first.authorizationScope == Self.scopeA)
        #expect(second.authorizationScope == Self.scopeB)
        #expect(first.sourceID == "plugin.a")
        #expect(second.sourceID == "plugin.b")
    }

    @Test func aMissingRowGivesAStableScopeUntilTheScopeTableCommits() {
        let contexts = PluginNetworkContexts(epochs: ["plugin.a": Self.epochA], policy: NetworkPolicyCenter())

        let first = contexts.context(pluginID: "plugin.new", Self.operation()).authorizationScope
        let second = contexts.context(pluginID: "plugin.new", Self.operation()).authorizationScope
        #expect(first == second)
        #expect(first != Self.scopeA)

        contexts.replaceEpochs(["plugin.a": Self.epochA])
        #expect(contexts.context(pluginID: "plugin.new", Self.operation()).authorizationScope != first)
    }

    @Test func everyCallGetsItsOwnGenerationAndPassesTheOperationThrough() {
        let contexts = PluginNetworkContexts(epochs: ["plugin.a": Self.epochA], policy: NetworkPolicyCenter())
        let operationID = UUID()
        let batchID = UUID()
        let operation = PluginNetworkOperation(purpose: .manualBulkDownload, operationID: operationID, batchID: batchID)

        let first = contexts.context(pluginID: "plugin.a", operation)
        let second = contexts.context(pluginID: "plugin.a", operation)

        #expect(first.generation != second.generation)
        #expect(first.operationID == operationID)
        #expect(second.operationID == operationID)
        #expect(first.batchID == batchID)
        #expect(first.purpose == .manualBulkDownload)
        #expect(first.policyRevision == contexts.policy.revision)
        #expect(first.scopedGrant == nil)
    }

    @Test func rotatingASettingOrASecretChangesTheScopeBeforeTheWriteReturns() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let settings = PluginSettingsStore(dbPool: database.dbPool,
        secrets: PluginSecretStore(keychain: InMemoryPluginSecretKeychain()), networkPolicy: NetworkPolicyCenter())
        let contexts = settings.networkContexts
        func scope(_ pluginID: String) -> UUID? {
            contexts.context(pluginID: pluginID, Self.operation()).authorizationScope
        }

        let before = scope("plugin.rotate")
        #expect(settings.set(pluginId: "plugin.rotate", key: "server", value: "https://a.example"))
        let afterSetting = scope("plugin.rotate")
        #expect(afterSetting != before)

        #expect(settings.setSecret(pluginId: "plugin.rotate", key: "token", value: "secret-1"))
        let afterSecret = scope("plugin.rotate")
        #expect(afterSecret != afterSetting)

        let committed = try database.dbPool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT epoch FROM pluginCompletionScope WHERE pluginId = ?",
                arguments: ["plugin.rotate"]
            )
        }
        #expect(afterSecret == PluginNetworkScopeID.uuid(epoch: try #require(committed)))
    }

    @Test func aSettingChangeForOnePluginLeavesAnotherPluginsScopeAlone() throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let settings = PluginSettingsStore(dbPool: database.dbPool,
        secrets: PluginSecretStore(keychain: InMemoryPluginSecretKeychain()), networkPolicy: NetworkPolicyCenter())
        #expect(settings.set(pluginId: "plugin.other", key: "server", value: "https://b.example"))
        let otherBefore = settings.networkContexts
            .context(pluginID: "plugin.other", Self.operation()).authorizationScope

        #expect(settings.set(pluginId: "plugin.rotate", key: "server", value: "https://a.example"))

        #expect(settings.networkContexts
            .context(pluginID: "plugin.other", Self.operation()).authorizationScope == otherBefore)
    }
}
