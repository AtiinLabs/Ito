import Foundation
import Testing
import ito_runner
@testable import Ito

/// The install-state precedence of a feed package against the installed source, with the ABI range injected.
@MainActor
struct PackageInstallStatusTests {
    private let host = 3...3

    private func package(
        version: String = "1.0",
        abi: Int? = nil,
        minAppVersion: String = "1.0",
        archived: Bool? = nil
    ) -> RepoPackage {
        RepoPackage(
            id: "plugin.fixture",
            name: "Fixture",
            version: version,
            minAppVersion: minAppVersion,
            downloadUrl: "fixture.ito",
            iconUrl: nil,
            sha256: "fixture",
            pluginType: "manga",
            archived: archived,
            archivedReason: nil,
            archivedDate: nil,
            abi: abi
        )
    }

    private func installed(
        version: String = "1.0",
        minAppVersion: String = "1.0",
        binary: PluginBinaryInterface?
    ) -> InstalledPlugin {
        InstalledPlugin(
            url: URL(fileURLWithPath: "/plugins/fixture.ito"),
            info: PluginInfo(
                id: "plugin.fixture",
                name: "Fixture",
                version: version,
                minAppVersion: minAppVersion,
                type: .manga
            ),
            iconData: nil,
            binary: binary
        )
    }

    private func runnable(abi: Int) -> PluginBinaryInterface {
        PluginBinaryInterface(abiVersion: abi, imports: [], kinds: [.manga])
    }

    private func status(_ feed: RepoPackage, installed: InstalledPlugin? = nil) -> PackageInstallStatus {
        PackageInstallStatus.resolve(
            for: feed,
            feedRefusal: feed.compatibilityRefusal(supported: host),
            installed: installed,
            supported: host
        )
    }

    // MARK: Cross-product of installed file and feed entry

    /// Every installed file state against every feed entry state, with the expected status written out by hand.
    /// Versions are equal, so the version order never decides a row.
    @Test func everyInstalledFileAgainstEveryFeedEntryHasItsDocumentedStatus() {
        let installedStates: [(name: String, plugin: InstalledPlugin?)] = [
            ("not installed", nil),
            ("runnable", installed(binary: runnable(abi: host.upperBound))),
            ("built for an older ABI", installed(binary: runnable(abi: host.lowerBound - 1))),
            ("built for a newer ABI", installed(binary: runnable(abi: host.upperBound + 1))),
            ("needs a newer app", installed(minAppVersion: "999.0", binary: runnable(abi: host.upperBound))),
            ("damaged, no readable module", installed(binary: nil))
        ]
        let feedStates: [(name: String, package: RepoPackage)] = [
            ("declared compatible", package(abi: host.upperBound)),
            ("no ABI declared", package(abi: nil)),
            ("declared older ABI", package(abi: host.lowerBound - 1)),
            ("declared newer ABI", package(abi: host.upperBound + 1)),
            ("needs a newer app", package(abi: host.upperBound, minAppVersion: "999.0"))
        ]
        // Rows follow installed states in order; columns follow feed states in order.
        let expected: [[PackageInstallStatus]] = [
            // not installed
            [.notInstalled, .notInstalled, .unavailableForThisIto, .requiresNewerApp(minimumAppVersion: nil),
             .requiresNewerApp(minimumAppVersion: "999.0")],
            // runnable
            [.installed, .installed, .installed, .requiresNewerApp(minimumAppVersion: nil),
             .requiresNewerApp(minimumAppVersion: "999.0")],
            // built for an older ABI
            [.sourceUpdateRequired, .repairUnverified, .noCompatibleUpdate, .requiresNewerApp(minimumAppVersion: nil),
             .requiresNewerApp(minimumAppVersion: "999.0")],
            // built for a newer ABI
            [.requiresNewerApp(minimumAppVersion: nil), .requiresNewerApp(minimumAppVersion: nil),
             .requiresNewerApp(minimumAppVersion: nil), .requiresNewerApp(minimumAppVersion: nil),
             .requiresNewerApp(minimumAppVersion: "999.0")],
            // needs a newer app
            [.requiresNewerApp(minimumAppVersion: "999.0"), .requiresNewerApp(minimumAppVersion: "999.0"),
             .requiresNewerApp(minimumAppVersion: "999.0"), .requiresNewerApp(minimumAppVersion: nil),
             .requiresNewerApp(minimumAppVersion: "999.0")],
            // damaged, no readable module
            [.sourceUpdateRequired, .repairUnverified, .noCompatibleUpdate, .requiresNewerApp(minimumAppVersion: nil),
             .requiresNewerApp(minimumAppVersion: "999.0")]
        ]
        for (row, installedState) in installedStates.enumerated() {
            for (column, feedState) in feedStates.enumerated() {
                let actual = status(feedState.package, installed: installedState.plugin)
                #expect(
                    actual == expected[row][column],
                    "installed \(installedState.name) with feed \(feedState.name): \(actual)"
                )
            }
        }
    }

    // MARK: Declared ABI

    @Test func aSameVersionRebuildOfAnIncompatibleInstalledSourceIsASourceUpdate() {
        let feed = package(version: "1.0", abi: host.upperBound)
        let plugin = installed(version: "1.0", binary: runnable(abi: host.lowerBound - 1))

        #expect(status(feed, installed: plugin) == .sourceUpdateRequired)
    }

    @Test func aDamagedOrUnreadableInstalledModuleIsUnsupportedAndASourceUpdateWhenTheFeedDeclaresABuild() {
        let feed = package(version: "1.0", abi: host.upperBound)

        #expect(installed(binary: nil).compatibilityRefusal(supported: host) == .unsupportedFile)
        #expect(status(feed, installed: installed(binary: nil)) == .sourceUpdateRequired)
    }

    @Test func archivedPackagesWinOverEveryOtherDirection() {
        let feed = package(version: "2.0", abi: 99, archived: true)
        let plugin = installed(version: "1.0", binary: runnable(abi: host.lowerBound - 1))

        #expect(status(feed, installed: plugin) == .archived)
        #expect(status(feed) == .archived)
    }

    @Test func aRunnableInstalledSourceWithANewerRunnableBuildIsAnUpdate() {
        let plugin = installed(version: "1.0", binary: runnable(abi: host.upperBound))

        #expect(status(package(version: "1.1", abi: host.upperBound), installed: plugin) == .updateAvailable)
        #expect(status(package(version: "1.0", abi: host.upperBound), installed: plugin) == .installed)
    }

    // MARK: Unknown ABI

    @Test func anUnknownFeedABIWithoutAnInstalledSourceIsOfferedForInstallOnly() {
        #expect(status(package(abi: nil)) == .notInstalled)
    }

    @Test func aNewerUnknownFeedBuildIsAnUpdateThatClaimsNoCompatibility() {
        let plugin = installed(version: "1.0", binary: runnable(abi: host.lowerBound - 1))

        #expect(status(package(version: "2.0", abi: nil), installed: plugin) == .updateAvailable)
    }

    @Test func aSameVersionUnknownFeedBuildRepairsOnlyByHandAndIsNeverASourceUpdate() {
        let plugin = installed(version: "1.0", binary: runnable(abi: host.lowerBound - 1))

        #expect(status(package(version: "1.0", abi: nil), installed: plugin) == .repairUnverified)
    }

    @Test func anUnknownFeedBuildNeverMakesARunnableSourceNeedAnUpdate() {
        let plugin = installed(version: "1.0", binary: runnable(abi: host.upperBound))

        #expect(status(package(version: "1.0", abi: nil), installed: plugin) == .installed)
    }

    // MARK: Candidate ranking

    private func listing(
        _ version: String,
        abi: Int?,
        refusal: PluginIncompatibility? = nil
    ) -> (package: RepoPackage, refusal: PluginIncompatibility?) {
        (package(version: version, abi: abi), refusal)
    }

    @Test func aDeclaredListingIsPreferredOverANewerUnknownOne() {
        let index = RepositoryListingRanking.preferredIndex(among: [
            listing("2.0", abi: nil),
            listing("1.0", abi: host.upperBound)
        ])

        #expect(index == 1)
    }

    @Test func anUnknownListingIsPreferredOverARefusedOneWhateverItsVersion() {
        let index = RepositoryListingRanking.preferredIndex(among: [
            listing("3.0", abi: host.upperBound + 1, refusal: .requiresNewerApp(minimumAppVersion: nil)),
            listing("1.0", abi: nil)
        ])

        #expect(index == 1)
    }

    @Test func aNewerDeclaredListingWinsWithinItsTier() {
        let index = RepositoryListingRanking.preferredIndex(among: [
            listing("1.0", abi: host.upperBound),
            listing("2.0", abi: host.upperBound)
        ])

        #expect(index == 1)
    }

    @Test func theEarlierRepositoryWinsATieWithinATier() {
        let index = RepositoryListingRanking.preferredIndex(among: [
            listing("1.0", abi: nil),
            listing("1.0", abi: nil)
        ])

        #expect(index == 0)
    }

    @Test func anUnknownListingListedFirstDoesNotBeatADeclaredOneListedLater() {
        let index = RepositoryListingRanking.preferredIndex(among: [
            listing("1.0", abi: nil),
            listing("1.0", abi: host.upperBound)
        ])

        #expect(index == 1)
    }

    @Test func noListingsRankToNothing() {
        #expect(RepositoryListingRanking.preferredIndex(among: []) == nil)
    }

    // MARK: Retained rule

    @Test func onlyTooOldAndUnusableInstalledSourcesNeedASourceUpdate() {
        #expect(PluginIncompatibility.requiresSourceUpdate.needsSourceUpdate)
        #expect(PluginIncompatibility.unsupportedFile.needsSourceUpdate)
        #expect(!PluginIncompatibility.requiresNewerApp(minimumAppVersion: nil).needsSourceUpdate)
        #expect(!PluginIncompatibility.requiresNewerApp(minimumAppVersion: "999.0").needsSourceUpdate)
    }
}
