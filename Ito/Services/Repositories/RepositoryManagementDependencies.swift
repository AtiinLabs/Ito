import Foundation
import Combine

@MainActor
protocol RepositoryListManaging: AnyObject {
    var repositories: [Repository] { get }
    var repositoriesPublisher: AnyPublisher<[Repository], Never> { get }

    func addRepository(url: String) async throws -> RepositoryAdditionResult
    func removeRepository(url: String) async throws
    func refreshAllReportingFailures() async throws
}

@MainActor
protocol RepositoryDetailManaging: AnyObject {
    var repositories: [Repository] { get }
    var repositoriesPublisher: AnyPublisher<[Repository], Never> { get }

    func installPackage(_ package: RepoPackage, repositoryURL: String) async throws
    func compatibilityRefusal(for package: RepoPackage) -> PluginRequiresNewerAppError?
}

extension RepoManager: RepositoryListManaging, RepositoryDetailManaging {}

@MainActor
struct PreparedRepositoryManagementDependencies {
    let repositoryListManager: any RepositoryListManaging
    let repositoryDetailManager: any RepositoryDetailManaging
}

@MainActor
protocol RepositoryPluginStatePublishing: AnyObject {
    /// Strict: scans, registers and publishes, and throws when an installed plugin can't be prepared. Requires
    /// the plugin directory gate, passed as `lease`.
    func publishInstalledPluginStateLocked(_ lease: PluginDirectoryLease) async throws
    /// Non-strict: republishes what the disk holds and logs a failure. Requires the plugin directory gate.
    func reloadInstalledPluginsLocked(_ lease: PluginDirectoryLease) async
}

extension PluginManager: RepositoryPluginStatePublishing {
    func publishInstalledPluginStateLocked(_ lease: PluginDirectoryLease) async throws {
        try await discoverAndPrepareInstalledPluginsLocked(failOnInvalidPlugin: true, lease)
    }
}

enum RepositoryManagementMessage: Equatable {
    case alreadyAdded
    case removeFailed(reason: String)
    case refreshFailed(reason: String)
    case installFailed(packageName: String, reason: String)
}

@MainActor
protocol RepositoryManagementMessagePresenting: AnyObject {
    func present(_ message: RepositoryManagementMessage)
}

@MainActor
final class AppMessageRepositoryManagementPresenter: RepositoryManagementMessagePresenting {
    private let messageCenter: AppMessageCenter

    init(messageCenter: AppMessageCenter) {
        self.messageCenter = messageCenter
    }

    func present(_ message: RepositoryManagementMessage) {
        messageCenter.publish(message.appMessageKind)
    }
}

private extension RepositoryManagementMessage {
    var appMessageKind: AppMessageKind {
        switch self {
        case .alreadyAdded:
            return .repositoryAlreadyAdded
        case .removeFailed:
            return .repositoryRemoveFailed
        case .refreshFailed:
            return .repositoryRefreshFailed
        case .installFailed:
            return .repositoryInstallFailed
        }
    }
}
