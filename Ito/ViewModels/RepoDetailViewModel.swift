import Combine
import Foundation
import ito_runner

@MainActor
final class RepoDetailViewModel: ObservableObject {
    let repositoryURL: String

    @Published var searchQuery = ""
    @Published private(set) var repository: Repository?
    @Published private(set) var installingPackageIDs: Set<String> = []
    @Published private(set) var installationFailureMessage: String?
    @Published private(set) var isRefreshingSources = false
    @Published private var installedPlugins: [String: InstalledPlugin]

    private let repositoryManager: any RepositoryDetailManaging
    private let pluginManager: any BrowsePluginManaging
    private let messagePresenter: any RepositoryManagementMessagePresenting
    private var installOperations: [String: UUID] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(
        repositoryURL: String,
        repositoryManager: any RepositoryDetailManaging,
        pluginManager: any BrowsePluginManaging,
        messagePresenter: any RepositoryManagementMessagePresenting
    ) {
        self.repositoryURL = repositoryURL
        self.repositoryManager = repositoryManager
        self.pluginManager = pluginManager
        self.messagePresenter = messagePresenter
        repository = repositoryManager.repositories.first { $0.url == repositoryURL }
        installedPlugins = pluginManager.installedPlugins

        repositoryManager.repositoriesPublisher
            .sink { @MainActor [weak self] repositories in
                guard let self else { return }
                self.repository = repositories.first { $0.url == self.repositoryURL }
            }
            .store(in: &cancellables)

        pluginManager.installedPluginsPublisher
            .sink { @MainActor [weak self] plugins in
                self?.installedPlugins = plugins
            }
            .store(in: &cancellables)
    }

    var filteredPackages: [RepoPackage] {
        guard let packages = repository?.index?.packages else { return [] }
        guard !searchQuery.isEmpty else { return packages }
        return packages.filter { package in
            package.name.localizedCaseInsensitiveContains(searchQuery) ||
                package.pluginType.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    func installState(for package: RepoPackage) -> PackageInstallStatus {
        PackageInstallStatus.resolve(
            for: package,
            feedRefusal: repositoryManager.compatibilityRefusal(for: package),
            installed: installedPlugins[package.id],
            supported: pluginManager.supportedABI
        )
    }

    /// Refreshes every repository index because the user asked. Install states never fetch on their own, so a
    /// refresh that fails, or an offline device, changes nothing until this is called again. A second request while
    /// one runs is ignored, so the running refresh is the only one.
    func refreshSources() async {
        guard !isRefreshingSources else { return }
        isRefreshingSources = true
        defer { isRefreshingSources = false }
        do {
            try await repositoryManager.refreshAllReportingFailures()
            messagePresenter.present(.sourcesRefreshed)
        } catch {
            messagePresenter.present(.refreshFailed(reason: error.localizedDescription))
        }
    }

    func isInstalling(packageID: String) -> Bool {
        installingPackageIDs.contains(packageID)
    }

    func installPackage(_ package: RepoPackage) async {
        guard !package.isArchived,
              !installingPackageIDs.contains(package.id) else { return }

        let operationID = UUID()
        installOperations[package.id] = operationID
        installingPackageIDs.insert(package.id)
        installationFailureMessage = nil

        defer {
            if installOperations[package.id] == operationID {
                installOperations[package.id] = nil
                installingPackageIDs.remove(package.id)
            }
        }

        do {
            try await repositoryManager.installPackage(
                package,
                repositoryURL: repositoryURL
            )
        } catch {
            installationFailureMessage = error.localizedDescription
            messagePresenter.present(
                .installFailed(
                    packageName: package.name,
                    reason: error.localizedDescription
                )
            )
        }
    }
}
