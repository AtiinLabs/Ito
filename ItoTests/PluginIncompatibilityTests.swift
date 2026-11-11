import Foundation
import Testing
import ito_runner
@testable import Ito

/// The ABI range these tests inject instead of the production range: the host reads only ABI 3, so ABI 1 and 2
/// modules are too old for it and ABI 4 is too new. Production keeps `ItoRunner.supportedABIVersions`.
private let injectedHost = 3...3

@MainActor
struct PluginIncompatibilityTests {
    @Test func aModuleBuiltForAnOlderABIIsASourceUpdateNotAnAppUpdate() {
        let binary = PluginBinaryInterface(abiVersion: 2, imports: [], kinds: [.manga])

        let refusal = PluginIncompatibility.binary(ItoRunner.compatibility(of: binary, supported: injectedHost))

        #expect(refusal == .requiresSourceUpdate)
    }

    @Test func aModuleBuiltForANewerABIOrNeedingAMissingFunctionNeedsANewerApp() {
        let newer = PluginBinaryInterface(abiVersion: 4, imports: [], kinds: [.manga])
        let missingImport = PluginBinaryInterface(
            abiVersion: 3,
            imports: ["ito:core/net.fetch_v9"],
            kinds: [.manga]
        )

        #expect(
            PluginIncompatibility.binary(ItoRunner.compatibility(of: newer, supported: injectedHost))
                == .requiresNewerApp(minimumAppVersion: nil)
        )
        #expect(
            PluginIncompatibility.binary(ItoRunner.compatibility(of: missingImport, supported: injectedHost))
                == .requiresNewerApp(minimumAppVersion: nil)
        )
    }

    @Test func aModuleThisHostReadsIsNotRefused() {
        let binary = PluginBinaryInterface(abiVersion: 3, imports: [], kinds: [.manga])

        #expect(PluginIncompatibility.binary(ItoRunner.compatibility(of: binary, supported: injectedHost)) == nil)
    }

    @Test func aModuleWithAStartSectionIsAnUnsupportedFile() {
        // A start section runs plugin code before any export, so no host runs such a module.
        let binary = PluginBinaryInterface(abiVersion: 3, imports: [], kinds: [.manga], hasStartSection: true)

        let refusal = PluginIncompatibility.binary(ItoRunner.compatibility(of: binary, supported: injectedHost))

        #expect(refusal == .unsupportedFile)
    }

    @Test func aMinimumAppVersionNamesItsVersionAndIsCheckedBeforeTheModule() {
        #expect(PluginIncompatibility.appVersion(required: "999.0") == .requiresNewerApp(minimumAppVersion: "999.0"))
        #expect(PluginIncompatibility.appVersion(required: "1.0") == nil)

        // A manifest naming a newer Ito is refused as that version, even when its module is also too old.
        let plugin = InstalledPlugin(
            url: URL(fileURLWithPath: "/test/named.ito"),
            info: PluginInfo(id: "named", name: "Named", version: "1.0", minAppVersion: "999.0", type: .manga, abi: 2),
            iconData: nil,
            binary: PluginBinaryInterface(abiVersion: 2, imports: [], kinds: [.manga])
        )
        #expect(plugin.compatibilityRefusal(supported: injectedHost) == .requiresNewerApp(minimumAppVersion: "999.0"))
    }

    @Test func anInstalledModuleDecidesItsDirectionWhenTheManifestIsSilent() {
        let tooOld = InstalledPlugin(
            url: URL(fileURLWithPath: "/test/old.ito"),
            info: PluginInfo(id: "old", name: "Old", version: "1.0", minAppVersion: "1.0", type: .manga),
            iconData: nil,
            binary: PluginBinaryInterface(abiVersion: 2, imports: [], kinds: [.manga])
        )
        let compatible = InstalledPlugin(
            url: URL(fileURLWithPath: "/test/current.ito"),
            info: PluginInfo(id: "current", name: "Current", version: "1.0", minAppVersion: "1.0", type: .manga),
            iconData: nil,
            binary: PluginBinaryInterface(abiVersion: 3, imports: [], kinds: [.manga])
        )

        #expect(tooOld.compatibilityRefusal(supported: injectedHost) == .requiresSourceUpdate)
        #expect(compatible.compatibilityRefusal(supported: injectedHost) == nil)
    }

    @Test func aFeedPackageBuiltForAnOlderABIIsASourceUpdateAndOneForTheHostIsNot() {
        func package(abi: Int) -> RepoPackage {
            RepoPackage(
                id: "p", name: "P", version: "1.0", minAppVersion: "1.0", downloadUrl: "p.ito",
                iconUrl: nil, sha256: "x", pluginType: "manga", archived: nil, archivedReason: nil,
                archivedDate: nil, abi: abi
            )
        }

        #expect(package(abi: 2).compatibilityRefusal(supported: injectedHost) == .requiresSourceUpdate)
        #expect(package(abi: 3).compatibilityRefusal(supported: injectedHost) == nil)
        #expect(package(abi: 4).compatibilityRefusal(supported: injectedHost) == .requiresNewerApp(minimumAppVersion: nil))
    }

    @Test func aRunnerLoadRefusalIsWordedByItsDirection() {
        #expect(PluginIncompatibility.loading(.unsupportedABI(version: 2, supported: injectedHost)) == .requiresSourceUpdate)
        #expect(
            PluginIncompatibility.loading(.unsupportedABI(version: 4, supported: injectedHost))
                == .requiresNewerApp(minimumAppVersion: nil)
        )
        #expect(
            PluginIncompatibility.loading(.requiresNewerHost(missingImports: ["ito:core/net.fetch_v9"]))
                == .requiresNewerApp(minimumAppVersion: nil)
        )
        #expect(PluginIncompatibility.loading(.wasmTrap("x")) == nil)
    }

    @Test func aFeedEntryWithAnOldABIIsASourceUpdateEvenWhenItsImportsAreAlsoMissing() {
        // The ABI is read first, so the old module is named as the source's problem, not the missing function.
        let refusal = PluginIncompatibility.declared(
            abi: 2,
            imports: ["ito:core/net.fetch_v9"],
            supported: injectedHost
        )

        #expect(refusal == .requiresSourceUpdate)
    }

    @Test func anInstalledSourceWhoseFileNoHostRunsGetsANeutralMessageNamingNoSelectedFile() {
        let message = PluginIncompatibility.unsupportedFile.message

        #expect(!message.localizedCaseInsensitiveContains("selected file"))
        #expect(!message.localizedCaseInsensitiveContains("Update Ito"))
    }

    @Test func aCandidateListedOnlyByRefusedRepositoriesFallsBackToTheFirstOne() {
        func candidate(_ repository: String, _ incompatibility: PluginIncompatibility?) -> DeferredPluginPackageCandidate {
            DeferredPluginPackageCandidate(
                package: RepoPackage(
                    id: "p", name: "P", version: "1.0", minAppVersion: "1.0", downloadUrl: "p.ito",
                    iconUrl: nil, sha256: "x", pluginType: "manga", archived: nil, archivedReason: nil,
                    archivedDate: nil
                ),
                repositoryURL: repository,
                incompatibility: incompatibility
            )
        }
        let first = candidate("https://first.example", .requiresSourceUpdate)
        let second = candidate("https://second.example", .requiresNewerApp(minimumAppVersion: nil))

        #expect(DeferredPluginPackageCandidate.preferred(among: [first, second]) == first)
        #expect(DeferredPluginPackageCandidate.preferred(among: []) == nil)
        #expect(DeferredPluginPackageCandidate.preferred(among: [second, candidate("https://ok.example", nil)])?.repositoryURL == "https://ok.example")
    }

    @Test func aSourceBuiltForAnOlderABIIsNeverToldToUpdateIto() {
        let text = PluginIncompatibility.requiresSourceUpdate.message

        #expect(text == "This source was built for an older version of Ito. Update the source to use it.")
        #expect(!text.contains("Update Ito"))
        #expect(PluginCallError(ItoError.unsupportedABI(version: 2, supported: injectedHost)).message == text)
        #expect(
            PluginCallError(ItoError.unsupportedABI(version: 4, supported: injectedHost)).message
                == PluginIncompatibility.requiresNewerApp(minimumAppVersion: nil).message
        )
    }
}
