import Combine
import Foundation
@testable import Ito

@MainActor
func makeTestRepositoryManagementDependencies() -> PreparedRepositoryManagementDependencies {
    let manager = TestRepositoryManagementManager()
    return PreparedRepositoryManagementDependencies(
        repositoryListManager: manager,
        repositoryDetailManager: manager
    )
}

private enum TestRepositoryManagementError: Error {
    case unavailable
}

@MainActor
private final class TestRepositoryManagementManager: RepositoryListManaging, RepositoryDetailManaging {
    @Published private(set) var repositories: [Repository] = []

    var repositoriesPublisher: AnyPublisher<[Repository], Never> {
        $repositories.eraseToAnyPublisher()
    }

    func addRepository(url: String) async throws -> RepositoryAdditionResult {
        throw TestRepositoryManagementError.unavailable
    }

    func removeRepository(url: String) async throws {
        throw TestRepositoryManagementError.unavailable
    }

    func refreshAllReportingFailures() async throws {
        throw TestRepositoryManagementError.unavailable
    }

    func installPackage(_ package: RepoPackage, repositoryURL: String) async throws {
        throw TestRepositoryManagementError.unavailable
    }

    func compatibilityRefusal(for package: RepoPackage) -> PluginRequiresNewerAppError? {
        PluginRequiresNewerAppError(minimumAppVersion: package.minAppVersion)
    }
}
