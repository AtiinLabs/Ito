import Combine
import Foundation

@MainActor
protocol MigrationRepositoryProviding: AnyObject {
    var repositories: [Repository] { get }
    var repositoriesPublisher: AnyPublisher<[Repository], Never> { get }

    func refreshAll() async
    func installPackage(_ package: RepoPackage, repositoryURL: String) async throws
}

extension RepoManager: MigrationRepositoryProviding {}

@MainActor
protocol MigrationInstalledPluginProviding: AnyObject {
    var installedPlugins: [String: InstalledPlugin] { get }
    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> { get }
}

extension PluginManager: MigrationInstalledPluginProviding {}

struct MigrationRemapRequest: Equatable, Sendable {
    let foreignID: String
    let oldPluginID: String
    let newPluginID: String
    let affectedItemIDs: [String]
}

enum MigrationRemapOutcome: Equatable, Sendable {
    case remappedAndAliased
    /// The database remap committed; the alias write failed afterwards.
    case remappedAliasNotSaved
}

@MainActor
protocol MigrationSourceRemapping: AnyObject {
    func remapSource(_ request: MigrationRemapRequest) async throws -> MigrationRemapOutcome
}

@MainActor
final class LibrarySourceRemapperMigrationAdapter: MigrationSourceRemapping {
    let remapper: LibrarySourceRemapper
    private let aliasWriter: LibrarySourceRemapper.AliasWriter

    init(remapper: LibrarySourceRemapper, aliasWriter: @escaping LibrarySourceRemapper.AliasWriter) {
        self.remapper = remapper
        self.aliasWriter = aliasWriter
    }

    func remapSource(_ request: MigrationRemapRequest) async throws -> MigrationRemapOutcome {
        let aliasWriter = self.aliasWriter
        do {
            _ = try await remapper.remapAndPersistAlias(
                foreignId: request.foreignID,
                oldPluginId: request.oldPluginID,
                newPluginId: request.newPluginID,
                affectedItemIds: request.affectedItemIDs
            ) { foreignId, newPluginId in
                do {
                    try await aliasWriter(foreignId, newPluginId)
                } catch {
                    throw MigrationAliasWriteFailure()
                }
            }
            return .remappedAndAliased
        } catch is MigrationAliasWriteFailure {
            return .remappedAliasNotSaved
        }
    }
}

private struct MigrationAliasWriteFailure: Error {}

@MainActor
struct PreparedMigrationReportDependencies {
    let repositories: any MigrationRepositoryProviding
    let plugins: any MigrationInstalledPluginProviding
    let remapper: any MigrationSourceRemapping

    static func production(
        repoManager: RepoManager,
        pluginManager: PluginManager,
        librarySourceRemapper: LibrarySourceRemapper,
        pluginResolver: PluginResolver
    ) -> Self {
        Self(
            repositories: repoManager,
            plugins: pluginManager,
            remapper: LibrarySourceRemapperMigrationAdapter(
                remapper: librarySourceRemapper,
                aliasWriter: { foreignID, pluginID in
                    try await pluginResolver.saveUserAlias(
                        foreignId: foreignID,
                        itoPluginId: pluginID
                    )
                }
            )
        )
    }

    static func unavailable() -> Self {
        let service = UnavailableMigrationReportService()
        return Self(repositories: service, plugins: service, remapper: service)
    }
}

private enum MigrationReportDependencyUnavailableError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Migration remediation is unavailable." }
}

@MainActor
private final class UnavailableMigrationReportService: MigrationRepositoryProviding,
    MigrationInstalledPluginProviding, MigrationSourceRemapping {
    var repositories: [Repository] { [] }
    var repositoriesPublisher: AnyPublisher<[Repository], Never> {
        Just([]).eraseToAnyPublisher()
    }

    var installedPlugins: [String: InstalledPlugin] { [:] }
    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> {
        Just([:]).eraseToAnyPublisher()
    }

    func refreshAll() async {}

    func installPackage(_ package: RepoPackage, repositoryURL: String) async throws {
        throw MigrationReportDependencyUnavailableError.unavailable
    }

    func remapSource(_ request: MigrationRemapRequest) async throws -> MigrationRemapOutcome {
        throw MigrationReportDependencyUnavailableError.unavailable
    }
}
