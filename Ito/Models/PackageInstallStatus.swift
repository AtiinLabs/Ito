import Foundation
import ito_runner

/// What a repository package means to this Ito, from its feed entry and the installed source with the same
/// identifier. The precedence is written once, here: the detail screen, the row labels and the Browse update
/// count all read it, so they cannot disagree.
nonisolated enum PackageInstallStatus: Equatable {
    /// The repository archived the package, so it can't be installed or updated.
    case archived
    /// The package, or the installed file, needs a newer Ito or a host function this Ito lacks.
    case requiresNewerApp(minimumAppVersion: String?)
    /// The installed file can't run here, and the feed declares a build this Ito runs. Installing it replaces the file
    /// whatever the version numbers say, so a rebuilt package of the same version counts.
    case sourceUpdateRequired
    /// The installed file can't run here, and the feed's build is too old for this Ito. Nothing in this repository can
    /// repair it, so the repository is asked to refresh.
    case noCompatibleUpdate
    /// The installed file can't run here, and the feed lists this version with no ABI. Whether a build can repair the
    /// file is unknown until its bytes are inspected, so it is installable by hand but never counted as an update.
    case repairUnverified
    /// Not installed, and the feed's build is too old for this Ito.
    case unavailableForThisIto
    /// Installed and runnable, with a newer build in the feed that is not refused. A feed build with no ABI is offered
    /// as a newer version only; no compatibility is claimed for it.
    case updateAvailable
    /// Installed and runnable, with a build at least as new as the feed's.
    case installed
    /// Not installed, and the feed offers a build that is not refused.
    case notInstalled

    /// The precedence, evaluated in order:
    /// 1. archived;
    /// 2. the feed build is refused as too new, or for a missing import;
    /// 3. the feed build is too old or unsupported: `unavailableForThisIto` when nothing is installed, `installed` when
    ///    the installed file runs, otherwise the installed file's own requirement (`requiresNewerApp`), or
    ///    `noCompatibleUpdate`;
    /// 4. the installed file needs a newer Ito: `requiresNewerApp`;
    /// 5. the installed file is too old or unusable, and the feed declares a build this Ito runs: `sourceUpdateRequired`;
    /// 6. the installed file is too old or unusable and the feed lists no ABI: `updateAvailable` when the feed version is
    ///    newer, otherwise `repairUnverified`;
    /// 7. the installed file runs and the feed is newer: `updateAvailable`;
    /// 8. the installed file runs: `installed`;
    /// 9. otherwise `notInstalled`.
    ///
    /// An installed file that needs a newer Ito is reported as such, not as a source update: installing the feed's
    /// build would be a downgrade, and the Ito version is the only fix.
    ///
    /// - Parameters:
    ///   - package: The feed entry.
    ///   - feedRefusal: Why the feed entry can't run, or nil when it can or its ABI is unknown.
    ///   - installed: The installed source with the same identifier, or nil.
    ///   - supported: The ABI range this Ito reads, used to judge the installed file.
    static func resolve(
        for package: RepoPackage,
        feedRefusal: PluginIncompatibility?,
        installed: InstalledPlugin?,
        supported: ClosedRange<Int>
    ) -> PackageInstallStatus {
        if package.isArchived {
            return .archived
        }
        let installedRefusal = installed?.compatibilityRefusal(supported: supported)
        if let feedRefusal {
            switch feedRefusal {
            case .requiresNewerApp(let minimumAppVersion):
                return .requiresNewerApp(minimumAppVersion: minimumAppVersion)
            case .requiresSourceUpdate, .unsupportedFile:
                guard installed != nil else { return .unavailableForThisIto }
                switch installedRefusal {
                case nil:
                    return .installed
                case .requiresNewerApp(let minimumAppVersion)?:
                    return .requiresNewerApp(minimumAppVersion: minimumAppVersion)
                case .requiresSourceUpdate?, .unsupportedFile?:
                    return .noCompatibleUpdate
                }
            }
        }
        guard let installed else { return .notInstalled }
        let isNewer = installed.info.version.compare(package.version, options: .numeric) == .orderedAscending
        switch installedRefusal {
        case .requiresNewerApp(let minimumAppVersion)?:
            return .requiresNewerApp(minimumAppVersion: minimumAppVersion)
        case .requiresSourceUpdate?, .unsupportedFile?:
            if package.abi != nil {
                return .sourceUpdateRequired
            }
            return isNewer ? .updateAvailable : .repairUnverified
        case nil:
            return isNewer ? .updateAvailable : .installed
        }
    }
}

/// How much a repository listing is known to run in this Ito, most certain first.
nonisolated enum PackageCompatibilityTier: Int, Comparable, Sendable {
    /// The listing declares an ABI, and this Ito does not refuse it.
    case declared
    /// The listing declares no ABI, so compatibility is unknown until its bytes are inspected.
    case unknown
    /// The listing is refused by what it declares.
    case refused

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(_ package: RepoPackage, refusal: PluginIncompatibility?) {
        if refusal != nil {
            self = .refused
        } else if package.abi == nil {
            self = .unknown
        } else {
            self = .declared
        }
    }
}

/// The one ranking used to choose a listing of a package across repositories, on every surface that installs.
nonisolated enum RepositoryListingRanking {
    /// The index of the listing to offer among listings of one package, given in repository order. Declared listings
    /// come first, then listings with an unknown ABI, then refused ones. Within a tier the newer version wins, then the
    /// earlier repository. An unknown listing is never preferred merely because it is listed first or is newer than a
    /// declared one.
    static func preferredIndex(among listings: [(package: RepoPackage, refusal: PluginIncompatibility?)]) -> Int? {
        listings.indices.min { lhs, rhs in
            let left = listings[lhs]
            let right = listings[rhs]
            let leftTier = PackageCompatibilityTier(left.package, refusal: left.refusal)
            let rightTier = PackageCompatibilityTier(right.package, refusal: right.refusal)
            if leftTier != rightTier {
                return leftTier < rightTier
            }
            let versionOrder = left.package.version.compare(right.package.version, options: .numeric)
            if versionOrder != .orderedSame {
                return versionOrder == .orderedDescending
            }
            return lhs < rhs
        }
    }
}
