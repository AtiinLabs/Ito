import Combine
import Foundation
import ito_runner
@testable import Ito

@MainActor
final class MigrationRepositoryFake: MigrationRepositoryProviding {
    @Published private(set) var repositories: [Repository]
    var repositoriesAfterRefresh: [Repository]?
    var installError: Error?
    private(set) var events: [String] = []

    init(repositories: [Repository] = []) {
        self.repositories = repositories
    }

    var repositoriesPublisher: AnyPublisher<[Repository], Never> {
        $repositories.eraseToAnyPublisher()
    }

    func refreshAll() async {
        events.append("refresh")
        if let repositoriesAfterRefresh {
            repositories = repositoriesAfterRefresh
        }
    }

    func installPackage(_ package: RepoPackage, repositoryURL: String) async throws {
        events.append("install:\(package.id)@\(repositoryURL)")
        if let installError {
            throw installError
        }
    }
}

@MainActor
final class MigrationPluginCatalogFake: MigrationInstalledPluginProviding {
    @Published private(set) var installedPlugins: [String: InstalledPlugin]

    init(installedPlugins: [String: InstalledPlugin] = [:]) {
        self.installedPlugins = installedPlugins
    }

    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> {
        $installedPlugins.eraseToAnyPublisher()
    }

    func publish(_ plugins: [String: InstalledPlugin]) {
        installedPlugins = plugins
    }
}

@MainActor
final class MigrationSourceRemapperFake: MigrationSourceRemapping {
    private(set) var requests: [MigrationRemapRequest] = []
    var response: Result<MigrationRemapOutcome, Error> = .success(.remappedAndAliased)

    func remapSource(_ request: MigrationRemapRequest) async throws -> MigrationRemapOutcome {
        requests.append(request)
        return try response.get()
    }
}

@MainActor
struct MigrationSubject {
    let viewModel: MigrationReportViewModel
    let repositories: MigrationRepositoryFake
    let plugins: MigrationPluginCatalogFake
    let remapper: MigrationSourceRemapperFake
    let logger: PresentationEventCaptureSpy
}

@MainActor
func makeMigrationSubject(
    unresolved: [MigrationReport.UnresolvedPlugin],
    repositories: [Repository] = [],
    installed: [InstalledPlugin] = []
) -> MigrationSubject {
    let report = MigrationReport(
        unresolvedPlugins: unresolved,
        totalItemsImported: 3,
        totalItemsSkipped: 0
    )
    let repositoryFake = MigrationRepositoryFake(repositories: repositories)
    let pluginFake = MigrationPluginCatalogFake(
        installedPlugins: Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
    )
    let remapper = MigrationSourceRemapperFake()
    let logger = PresentationEventCaptureSpy()
    let viewModel = MigrationReportViewModel(
        report: report,
        dependencies: PreparedMigrationReportDependencies(
            repositories: repositoryFake,
            plugins: pluginFake,
            remapper: remapper
        ),
        presentationLogger: logger
    )
    return MigrationSubject(
        viewModel: viewModel,
        repositories: repositoryFake,
        plugins: pluginFake,
        remapper: remapper,
        logger: logger
    )
}

func migrationReport(_ unresolved: [MigrationReport.UnresolvedPlugin]) -> MigrationReport {
    MigrationReport(unresolvedPlugins: unresolved, totalItemsImported: 3, totalItemsSkipped: 0)
}

func migrationUnresolved(
    foreignId: String,
    resolvedId: String,
    confidence: Int = 80,
    isInstalled: Bool = false,
    affectedItemIds: [String] = ["item"]
) -> MigrationReport.UnresolvedPlugin {
    MigrationReport.UnresolvedPlugin(
        foreignId: foreignId,
        resolvedId: resolvedId,
        confidence: confidence,
        isInstalled: isInstalled,
        affectedItemIds: affectedItemIds,
        candidates: []
    )
}

func migrationPackage(id: String, name: String) -> RepoPackage {
    RepoPackage(
        id: id,
        name: name,
        version: "1.0",
        minAppVersion: "1.0",
        downloadUrl: "\(id).ito",
        iconUrl: nil,
        sha256: "fixture",
        pluginType: "manga",
        archived: false,
        archivedReason: nil,
        archivedDate: nil
    )
}

func migrationRepository(url: String, packages: [RepoPackage]) -> Repository {
    Repository(
        url: url,
        index: RepoIndex(
            repoName: "Fixture",
            repoUrl: url,
            description: "Description",
            packages: packages
        )
    )
}

struct MigrationTestFailure: LocalizedError {
    var errorDescription: String? { "fixture install failure" }
}
