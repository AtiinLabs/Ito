import Combine
import Foundation
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class RepositoriesViewModelTests: XCTestCase {
    func testInitialRepositoriesAndAuthoritativePublicationDriveEmptyAndListState() {
        let first = makeRepository(url: "https://one.example")
        let manager = RepositoryManagerSpy(repositories: [first])
        let viewModel = makeRepositoriesViewModel(manager: manager)

        XCTAssertEqual(viewModel.repositories, [first])
        XCTAssertFalse(viewModel.isEmpty)

        manager.publishRepositories([])

        XCTAssertTrue(viewModel.repositories.isEmpty)
        XCTAssertTrue(viewModel.isEmpty)
    }

    func testAddTrimsPresentationWhitespaceAndDismissesOnlyAfterAuthoritativeSuccess() async {
        let manager = RepositoryManagerSpy()
        manager.suspendedAdds.insert("https://example.com/repo")
        let viewModel = makeRepositoriesViewModel(manager: manager)
        viewModel.presentAddRepository()
        viewModel.repositoryURLInput = "  https://example.com/repo  "

        let task = Task { await viewModel.addRepository() }
        await waitUntil { manager.addInvocations == ["https://example.com/repo"] }

        XCTAssertTrue(viewModel.showingAddRepository)
        XCTAssertEqual(viewModel.repositoryURLInput, "  https://example.com/repo  ")
        XCTAssertTrue(viewModel.isAddingRepository)

        manager.resumeAdd(url: "https://example.com/repo")
        await task.value

        XCTAssertFalse(viewModel.showingAddRepository)
        XCTAssertEqual(viewModel.repositoryURLInput, "")
        XCTAssertFalse(viewModel.isAddingRepository)
        XCTAssertNil(viewModel.addFailureMessage)
    }

    func testAddFailureRetainsInputRemainsRetryableAndDoesNotDismiss() async {
        let manager = RepositoryManagerSpy()
        manager.addErrors["https://failure.example"] = RepositoryTestFailure.failed
        let viewModel = makeRepositoriesViewModel(manager: manager)
        viewModel.presentAddRepository()
        viewModel.repositoryURLInput = "https://failure.example"

        await viewModel.addRepository()

        XCTAssertTrue(viewModel.showingAddRepository)
        XCTAssertEqual(viewModel.repositoryURLInput, "https://failure.example")
        XCTAssertEqual(
            viewModel.addFailureMessage,
            "Failed to add repository. Please check the URL and try again."
        )
        XCTAssertTrue(viewModel.canSubmitRepository)

        manager.addErrors.removeAll()
        await viewModel.addRepository()

        XCTAssertEqual(manager.addInvocations.count, 2)
        XCTAssertFalse(viewModel.showingAddRepository)
    }

    func testRapidDuplicateAddDoesNotOverlapDurableMutation() async {
        let manager = RepositoryManagerSpy()
        manager.suspendedAdds.insert("https://example.com")
        let viewModel = makeRepositoriesViewModel(manager: manager)
        viewModel.presentAddRepository()
        viewModel.repositoryURLInput = "https://example.com"

        let first = Task { await viewModel.addRepository() }
        await waitUntil { manager.addInvocations.count == 1 }
        let second = Task { await viewModel.addRepository() }
        await Task.yield()

        XCTAssertEqual(manager.addInvocations.count, 1)
        manager.resumeAdd(url: "https://example.com")
        await first.value
        await second.value
    }

    func testAddFailureDoesNotRenderCredentialBearingServiceDetails() async throws {
        let manager = RepositoryManagerSpy()
        manager.addErrors["https://failure.example"] = SensitiveRepositoryTestFailure()
        let viewModel = makeRepositoriesViewModel(manager: manager)
        viewModel.presentAddRepository()
        viewModel.repositoryURLInput = "https://failure.example"

        await viewModel.addRepository()

        let message = try XCTUnwrap(viewModel.addFailureMessage)
        XCTAssertFalse(message.contains("user:password"))
        XCTAssertFalse(message.contains("token=secret"))
        XCTAssertTrue(viewModel.showingAddRepository)
    }

    func testAlreadyPresentDismissesAndReportsAlreadyAdded() async {
        let manager = RepositoryManagerSpy()
        manager.addResults["https://example.com"] = .alreadyPresent
        let messages = RepositoryMessagePresenterSpy()
        let viewModel = makeRepositoriesViewModel(manager: manager, messages: messages)
        viewModel.presentAddRepository()
        viewModel.repositoryURLInput = "https://example.com"

        await viewModel.addRepository()

        XCTAssertFalse(viewModel.showingAddRepository)
        XCTAssertEqual(viewModel.repositoryURLInput, "")
        XCTAssertNil(viewModel.addFailureMessage)
        XCTAssertEqual(messages.messages, [.alreadyAdded])
    }

    func testRemoveStillDeletesWhenDialogDismissalIsReportedBeforeTheAction() async {
        let repository = makeRepository()
        let manager = RepositoryManagerSpy(repositories: [repository])
        let viewModel = makeRepositoriesViewModel(manager: manager)

        viewModel.requestDelete(repositoryURL: repository.url)
        viewModel.deleteConfirmationDismissed()
        await viewModel.confirmDelete()?.value

        XCTAssertEqual(manager.removeInvocations, [repository.url])
        XCTAssertFalse(viewModel.showDeleteConfirmation)
    }

    func testDeleteUsesStableURLAfterAuthoritativeListReorders() async {
        let first = makeRepository(url: "https://one.example")
        let second = makeRepository(url: "https://two.example")
        let manager = RepositoryManagerSpy(repositories: [first, second])
        let viewModel = makeRepositoriesViewModel(manager: manager)

        viewModel.requestDelete(repositoryURL: second.url)
        manager.publishRepositories([second, first])
        await viewModel.confirmDelete()?.value

        XCTAssertEqual(manager.removeInvocations, [second.url])
        XCTAssertFalse(viewModel.showDeleteConfirmation)
    }

    func testDeleteSuccessPublishesAuthoritativeRemovalWithoutOptimisticMutation() async {
        let repository = makeRepository()
        let manager = RepositoryManagerSpy(repositories: [repository])
        manager.suspendedRemovals.insert(repository.url)
        manager.publishRemovalOnSuccess = true
        let viewModel = makeRepositoriesViewModel(manager: manager)
        viewModel.requestDelete(repositoryURL: repository.url)

        let task = viewModel.confirmDelete()
        await waitUntil { manager.removeInvocations.count == 1 }

        XCTAssertEqual(viewModel.repositories, [repository])
        XCTAssertTrue(viewModel.deletingRepositoryURLs.contains(repository.url))

        manager.resumeRemoval(url: repository.url)
        await task?.value

        XCTAssertTrue(viewModel.repositories.isEmpty)
        XCTAssertFalse(viewModel.deletingRepositoryURLs.contains(repository.url))
    }

    func testDeleteFailurePreservesRepositoryAndProducesVisibleFailure() async {
        let repository = makeRepository()
        let manager = RepositoryManagerSpy(repositories: [repository])
        manager.removeErrors[repository.url] = RepositoryTestFailure.failed
        let messages = RepositoryMessagePresenterSpy()
        let viewModel = makeRepositoriesViewModel(manager: manager, messages: messages)
        viewModel.requestDelete(repositoryURL: repository.url)

        await viewModel.confirmDelete()?.value

        XCTAssertEqual(viewModel.repositories, [repository])
        XCTAssertEqual(viewModel.deleteFailureMessage, "fixture failure")
        XCTAssertEqual(messages.messages, [.removeFailed(reason: "fixture failure")])
    }

    func testDuplicateDeleteForSameRepositoryIsSuppressed() async {
        let repository = makeRepository()
        let manager = RepositoryManagerSpy(repositories: [repository])
        manager.suspendedRemovals.insert(repository.url)
        let viewModel = makeRepositoriesViewModel(manager: manager)
        viewModel.requestDelete(repositoryURL: repository.url)

        let first = viewModel.confirmDelete()
        await waitUntil { manager.removeInvocations.count == 1 }
        viewModel.requestDelete(repositoryURL: repository.url)
        XCTAssertNil(viewModel.confirmDelete())

        XCTAssertEqual(manager.removeInvocations.count, 1)
        manager.resumeRemoval(url: repository.url)
        await first?.value
    }

    func testDeleteConfirmationClaimsStableTargetSynchronouslyAndCancelDoesNotDelete() async {
        let repository = makeRepository()
        let manager = RepositoryManagerSpy(repositories: [repository])
        manager.suspendedRemovals.insert(repository.url)
        let viewModel = makeRepositoriesViewModel(manager: manager)

        viewModel.requestDelete(repositoryURL: repository.url)
        viewModel.cancelDelete()
        XCTAssertNil(viewModel.confirmDelete())
        XCTAssertTrue(manager.removeInvocations.isEmpty)

        viewModel.requestDelete(repositoryURL: repository.url)
        let deletion = viewModel.confirmDelete()

        XCTAssertNotNil(deletion)
        XCTAssertNil(viewModel.pendingDeleteRepositoryURL)
        XCTAssertFalse(viewModel.showDeleteConfirmation)
        await waitUntil { manager.removeInvocations == [repository.url] }

        manager.resumeRemoval(url: repository.url)
        await deletion?.value
    }

    func testRefreshSuccessComesFromAuthoritativePublication() async {
        let old = makeRepository(indexName: "Old")
        let refreshed = makeRepository(indexName: "Refreshed")
        let manager = RepositoryManagerSpy(repositories: [old])
        manager.onRefresh = { manager.publishRepositories([refreshed]) }
        let viewModel = makeRepositoriesViewModel(manager: manager)

        await viewModel.refreshRepositories()

        XCTAssertEqual(viewModel.repositories, [refreshed])
        XCTAssertNil(viewModel.refreshFailureMessage)
        XCTAssertFalse(viewModel.isRefreshing)
    }

    func testRefreshFailureIsVisibleAndPreservesAuthoritativeState() async {
        let repository = makeRepository()
        let manager = RepositoryManagerSpy(repositories: [repository])
        manager.refreshError = RepositoryTestFailure.failed
        let messages = RepositoryMessagePresenterSpy()
        let viewModel = makeRepositoriesViewModel(manager: manager, messages: messages)

        await viewModel.refreshRepositories()

        XCTAssertEqual(viewModel.repositories, [repository])
        XCTAssertEqual(viewModel.refreshFailureMessage, "fixture failure")
        XCTAssertEqual(messages.messages, [.refreshFailed(reason: "fixture failure")])
    }

    func testConcurrentRefreshIsSuppressedSoStaleCompletionCannotOverwriteNewerState() async {
        let manager = RepositoryManagerSpy(repositories: [makeRepository(indexName: "Old")])
        manager.suspendRefresh = true
        let viewModel = makeRepositoriesViewModel(manager: manager)

        let first = Task { await viewModel.refreshRepositories() }
        await waitUntil { manager.refreshCallCount == 1 }
        let second = Task { await viewModel.refreshRepositories() }
        await Task.yield()

        XCTAssertEqual(manager.refreshCallCount, 1)
        manager.resumeRefresh()
        await first.value
        await second.value
    }

    func testRepoDetailUsesStableIdentityAndFollowsAuthoritativeIndexReplacement() {
        let old = makeRepository(indexName: "Old", packages: [makePackage(id: "old")])
        let other = makeRepository(url: "https://other.example", indexName: "Other")
        let manager = RepositoryManagerSpy(repositories: [old, other])
        let viewModel = makeRepoDetailViewModel(repositoryURL: old.url, manager: manager)

        XCTAssertEqual(viewModel.repositoryURL, old.url)
        XCTAssertEqual(viewModel.repository, old)

        let refreshed = makeRepository(
            url: old.url,
            indexName: "Refreshed",
            packages: [makePackage(id: "new")]
        )
        manager.publishRepositories([other, refreshed])

        XCTAssertEqual(viewModel.repository, refreshed)
        XCTAssertEqual(viewModel.filteredPackages.map(\.id), ["new"])
    }

    func testRepoDetailMissingRepositoryOrIndexProducesNoPackages() {
        let manager = RepositoryManagerSpy(repositories: [Repository(url: "https://missing.example")])
        let viewModel = makeRepoDetailViewModel(
            repositoryURL: "https://missing.example",
            manager: manager
        )

        XCTAssertNotNil(viewModel.repository)
        XCTAssertTrue(viewModel.filteredPackages.isEmpty)

        manager.publishRepositories([])
        XCTAssertNil(viewModel.repository)
        XCTAssertTrue(viewModel.filteredPackages.isEmpty)
    }

    func testPackageSearchFiltersNameAndTypeCaseInsensitively() {
        let packages = [
            makePackage(id: "one", name: "Alpha Reader", pluginType: "manga"),
            makePackage(id: "two", name: "Beta Player", pluginType: "ANIME")
        ]
        let manager = RepositoryManagerSpy(repositories: [makeRepository(packages: packages)])
        let viewModel = makeRepoDetailViewModel(manager: manager)

        viewModel.searchQuery = "aLpHa"
        XCTAssertEqual(viewModel.filteredPackages.map(\.id), ["one"])

        viewModel.searchQuery = "anime"
        XCTAssertEqual(viewModel.filteredPackages.map(\.id), ["two"])
    }

    func testInstallStateCoversCompatibilityNotInstalledInstalledAndNumericUpdate() {
        let package = makePackage(version: "1.10", minAppVersion: "2.0")
        let manager = RepositoryManagerSpy(repositories: [makeRepository(packages: [package])])
        manager.compatibility["2.0"] = false
        let plugins = RepositoryPluginManagerSpy()
        let viewModel = makeRepoDetailViewModel(manager: manager, plugins: plugins)

        XCTAssertEqual(
            viewModel.installState(for: package),
            .incompatible(minVersion: "2.0")
        )

        manager.compatibility["2.0"] = true
        XCTAssertEqual(viewModel.installState(for: package), .notInstalled)

        plugins.publish([package.id: makeInstalledPlugin(id: package.id, version: "1.9")])
        XCTAssertEqual(viewModel.installState(for: package), .updateAvailable)

        plugins.publish([package.id: makeInstalledPlugin(id: package.id, version: "1.10")])
        XCTAssertEqual(viewModel.installState(for: package), .installed)
    }

    func testInstallSuccessAndUpdateSuccessReflectAuthoritativePluginPublication() async {
        let package = makePackage(version: "2.0")
        let manager = RepositoryManagerSpy(repositories: [makeRepository(packages: [package])])
        let plugins = RepositoryPluginManagerSpy()
        manager.onInstall = { installedPackage in
            plugins.publish([
                installedPackage.id: self.makeInstalledPlugin(
                    id: installedPackage.id,
                    version: installedPackage.version
                )
            ])
        }
        let viewModel = makeRepoDetailViewModel(manager: manager, plugins: plugins)

        XCTAssertEqual(viewModel.installState(for: package), .notInstalled)
        await viewModel.installPackage(package)
        XCTAssertEqual(viewModel.installState(for: package), .installed)

        plugins.publish([package.id: makeInstalledPlugin(id: package.id, version: "1.0")])
        XCTAssertEqual(viewModel.installState(for: package), .updateAvailable)
        await viewModel.installPackage(package)
        XCTAssertEqual(viewModel.installState(for: package), .installed)
        XCTAssertEqual(manager.installInvocations.map(\.packageID), [package.id, package.id])
    }

    func testInstallFailureLeavesDetailIntactProducesMessageAndNeverPresentsSuccess() async {
        let package = makePackage(name: "Fixture Package")
        let repository = makeRepository(packages: [package])
        let manager = RepositoryManagerSpy(repositories: [repository])
        manager.installErrors[package.id] = RepositoryTestFailure.failed
        let messages = RepositoryMessagePresenterSpy()
        let viewModel = makeRepoDetailViewModel(manager: manager, messages: messages)

        await viewModel.installPackage(package)

        XCTAssertEqual(viewModel.repository, repository)
        XCTAssertEqual(viewModel.installState(for: package), .notInstalled)
        XCTAssertEqual(viewModel.installationFailureMessage, "fixture failure")
        XCTAssertEqual(
            messages.messages,
            [.installFailed(packageName: "Fixture Package", reason: "fixture failure")]
        )
        XCTAssertTrue(viewModel.installingPackageIDs.isEmpty)
    }

    func testSamePackageRapidDuplicateInstallIsSuppressed() async {
        let package = makePackage()
        let manager = RepositoryManagerSpy(repositories: [makeRepository(packages: [package])])
        manager.suspendedInstalls.insert(package.id)
        let viewModel = makeRepoDetailViewModel(manager: manager)

        let first = Task { await viewModel.installPackage(package) }
        await waitUntil { manager.installInvocations.count == 1 }
        let second = Task { await viewModel.installPackage(package) }
        await Task.yield()

        XCTAssertEqual(manager.installInvocations.count, 1)
        XCTAssertTrue(viewModel.isInstalling(packageID: package.id))
        manager.resumeInstall(packageID: package.id)
        await first.value
        await second.value
    }

    func testDifferentPackagesInstallIndependentlyAndOlderCompletionDoesNotClearNewerProgress() async {
        let firstPackage = makePackage(id: "one")
        let secondPackage = makePackage(id: "two")
        let manager = RepositoryManagerSpy(
            repositories: [makeRepository(packages: [firstPackage, secondPackage])]
        )
        manager.suspendedInstalls = [firstPackage.id, secondPackage.id]
        let viewModel = makeRepoDetailViewModel(manager: manager)

        let first = Task { await viewModel.installPackage(firstPackage) }
        let second = Task { await viewModel.installPackage(secondPackage) }
        await waitUntil { manager.installInvocations.count == 2 }

        XCTAssertEqual(viewModel.installingPackageIDs, [firstPackage.id, secondPackage.id])
        manager.resumeInstall(packageID: firstPackage.id)
        await first.value

        XCTAssertFalse(viewModel.isInstalling(packageID: firstPackage.id))
        XCTAssertTrue(viewModel.isInstalling(packageID: secondPackage.id))

        manager.resumeInstall(packageID: secondPackage.id)
        await second.value
        XCTAssertTrue(viewModel.installingPackageIDs.isEmpty)
    }

    func testProductionSourceContractsUseScreenOwnershipInjectionAndNoPresentationGlobals() throws {
        let repositorySource = try sourceFile("Ito/ViewModels/RepositoriesViewModel.swift")
        let detailSource = try sourceFile("Ito/ViewModels/RepoDetailViewModel.swift")
        let viewSource = try sourceFile("Ito/Views/Browse/RepositoriesView.swift")
        let combined = [repositorySource, detailSource, viewSource].joined(separator: "\n")

        for forbidden in [
            "RepoManager.shared",
            "PluginManager.shared",
            "SnackBarManager.shared",
            "AppDatabase.shared",
            "URLSession.shared",
            "FileManager.default",
            "UIApplication.shared",
            "UserDefaults.standard",
            "AppLogger",
            "@EnvironmentObject",
            "func configure("
        ] {
            XCTAssertFalse(combined.contains(forbidden), "Forbidden repository access: \(forbidden)")
        }
        XCTAssertTrue(viewSource.contains("@StateObject private var viewModel"))
        XCTAssertTrue(viewSource.contains("makeRepoDetailViewModel"))
        XCTAssertTrue(viewSource.contains("interactiveDismissDisabled(viewModel.isAddingRepository)"))
        XCTAssertTrue(viewSource.contains("viewModel.confirmDelete()"))
        XCTAssertFalse(viewSource.contains("Task { await viewModel.confirmDelete() }"))
        XCTAssertTrue(repositorySource.contains("any RepositoryListManaging"))
        XCTAssertFalse(repositorySource.contains("any BrowseRepositoryManaging"))
        XCTAssertTrue(detailSource.contains("any RepositoryDetailManaging"))
        XCTAssertFalse(detailSource.contains("any BrowseRepositoryManaging"))
    }

    func testAppFactoryOwnsConstructionWithoutAddingRepositoryModelsToRootStore() throws {
        let factorySource = try sourceFile("Ito/Views/Search/SearchRouteFactory.swift")
        let scopeSource = try sourceFile("Ito/AppScope.swift")

        XCTAssertTrue(factorySource.contains("func makeRepositoriesView()"))
        XCTAssertTrue(factorySource.contains("func makeRepoDetailViewModel(repositoryURL:"))
        XCTAssertTrue(factorySource.contains("RepositoriesViewModel("))
        XCTAssertTrue(factorySource.contains("RepoDetailViewModel("))
        XCTAssertFalse(scopeSource.contains("storedRepositoriesViewModel"))
        XCTAssertFalse(scopeSource.contains("storedRepoDetailViewModel"))
    }

    func testPR7BScreensRemainIsolatedFromRepositoryManagementMigration() throws {
        for path in [
            "Ito/Views/Browse/SourceView.swift",
            "Ito/Views/Browse/ListingView.swift",
            "Ito/Views/Browse/PluginSettingsView.swift",
            "Ito/ViewModels/SourceViewModel.swift",
            "Ito/ViewModels/ListingViewModel.swift",
            "Ito/ViewModels/PluginSettingsViewModel.swift"
        ] {
            let source = try sourceFile(path)
            XCTAssertFalse(source.contains("RepositoriesViewModel"))
            XCTAssertFalse(source.contains("RepoDetailViewModel"))
        }
        for migratedType in ["SourceViewModel", "ListingViewModel", "PluginSettingsViewModel"] {
            XCTAssertTrue(try allProductionSwiftSource().contains("final class \(migratedType)"))
        }
    }

    private func makeRepositoriesViewModel(
        manager: RepositoryManagerSpy,
        messages: RepositoryMessagePresenterSpy = RepositoryMessagePresenterSpy()
    ) -> RepositoriesViewModel {
        RepositoriesViewModel(repositoryManager: manager, messagePresenter: messages)
    }

    private func makeRepoDetailViewModel(
        repositoryURL: String = "https://repo.example",
        manager: RepositoryManagerSpy,
        plugins: RepositoryPluginManagerSpy = RepositoryPluginManagerSpy(),
        messages: RepositoryMessagePresenterSpy = RepositoryMessagePresenterSpy()
    ) -> RepoDetailViewModel {
        RepoDetailViewModel(
            repositoryURL: repositoryURL,
            repositoryManager: manager,
            pluginManager: plugins,
            messagePresenter: messages
        )
    }

    private func makeRepository(
        url: String = "https://repo.example",
        indexName: String = "Fixture",
        packages: [RepoPackage] = []
    ) -> Repository {
        Repository(
            url: url,
            index: RepoIndex(
                repoName: indexName,
                repoUrl: url,
                description: "Description",
                packages: packages
            )
        )
    }

    private func makePackage(
        id: String = "plugin.fixture",
        name: String = "Fixture",
        version: String = "1.0",
        minAppVersion: String = "1.0",
        pluginType: String = "manga"
    ) -> RepoPackage {
        RepoPackage(
            id: id,
            name: name,
            version: version,
            minAppVersion: minAppVersion,
            downloadUrl: "\(id).ito",
            iconUrl: nil,
            sha256: "fixture",
            pluginType: pluginType,
            archived: false,
            archivedReason: nil,
            archivedDate: nil
        )
    }

    private func makeInstalledPlugin(id: String, version: String) -> InstalledPlugin {
        InstalledPlugin(
            url: URL(fileURLWithPath: "/plugins/\(id).ito"),
            info: PluginInfo(
                id: id,
                name: id,
                version: version,
                minAppVersion: "1.0",
                type: .manga
            ),
            iconData: nil
        )
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Condition was not met before timeout", file: file, line: line)
    }

    private func sourceFile(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func allProductionSwiftSource() throws -> String {
        let enumerator = FileManager.default.enumerator(
            at: repositoryRoot.appendingPathComponent("Ito"),
            includingPropertiesForKeys: nil
        )
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private enum RepositoryTestFailure: LocalizedError {
    case failed

    var errorDescription: String? { "fixture failure" }
}

private struct SensitiveRepositoryTestFailure: LocalizedError {
    var errorDescription: String? {
        "https://user:password@private.example/index.json?token=secret"
    }
}

@MainActor
private final class RepositoryManagerSpy: RepositoryListManaging, RepositoryDetailManaging {
    struct InstallInvocation {
        let packageID: String
        let repositoryURL: String
    }

    @Published private(set) var repositories: [Repository]
    private(set) var addInvocations: [String] = []
    private(set) var removeInvocations: [String] = []
    private(set) var installInvocations: [InstallInvocation] = []
    private(set) var refreshCallCount = 0
    var addResults: [String: RepositoryAdditionResult] = [:]
    var addErrors: [String: any Error] = [:]
    var removeErrors: [String: any Error] = [:]
    var installErrors: [String: any Error] = [:]
    var refreshError: (any Error)?
    var compatibility: [String: Bool] = [:]
    var suspendedAdds: Set<String> = []
    var suspendedRemovals: Set<String> = []
    var suspendedInstalls: Set<String> = []
    var suspendRefresh = false
    var publishRemovalOnSuccess = false
    var onRefresh: (() -> Void)?
    var onInstall: ((RepoPackage) -> Void)?

    private var addContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var removeContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var installContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var refreshContinuation: CheckedContinuation<Void, Never>?

    init(repositories: [Repository] = []) {
        self.repositories = repositories
    }

    var repositoriesPublisher: AnyPublisher<[Repository], Never> {
        $repositories.eraseToAnyPublisher()
    }

    func publishRepositories(_ repositories: [Repository]) {
        self.repositories = repositories
    }

    func addRepository(url: String) async throws -> RepositoryAdditionResult {
        addInvocations.append(url)
        if suspendedAdds.contains(url) {
            await withCheckedContinuation { addContinuations[url] = $0 }
        }
        if let error = addErrors[url] { throw error }
        return addResults[url] ?? .added
    }

    func removeRepository(url: String) async throws {
        removeInvocations.append(url)
        if suspendedRemovals.contains(url) {
            await withCheckedContinuation { removeContinuations[url] = $0 }
        }
        if let error = removeErrors[url] { throw error }
        if publishRemovalOnSuccess {
            repositories.removeAll { $0.url == url }
        }
    }

    func installPackage(_ package: RepoPackage, repositoryURL: String) async throws {
        installInvocations.append(.init(packageID: package.id, repositoryURL: repositoryURL))
        if suspendedInstalls.contains(package.id) {
            await withCheckedContinuation { installContinuations[package.id] = $0 }
        }
        if let error = installErrors[package.id] { throw error }
        onInstall?(package)
    }

    func refreshAll() async {
        try? await refreshAllReportingFailures()
    }

    func refreshAllReportingFailures() async throws {
        refreshCallCount += 1
        if suspendRefresh {
            await withCheckedContinuation { refreshContinuation = $0 }
        }
        if let refreshError { throw refreshError }
        onRefresh?()
    }

    func compatibilityRefusal(for package: RepoPackage) -> PluginRequiresNewerAppError? {
        (compatibility[package.minAppVersion] ?? true) ? nil : PluginRequiresNewerAppError(minimumAppVersion: package.minAppVersion)
    }

    func resumeAdd(url: String) {
        suspendedAdds.remove(url)
        addContinuations.removeValue(forKey: url)?.resume()
    }

    func resumeRemoval(url: String) {
        suspendedRemovals.remove(url)
        removeContinuations.removeValue(forKey: url)?.resume()
    }

    func resumeInstall(packageID: String) {
        suspendedInstalls.remove(packageID)
        installContinuations.removeValue(forKey: packageID)?.resume()
    }

    func resumeRefresh() {
        suspendRefresh = false
        refreshContinuation?.resume()
        refreshContinuation = nil
    }
}

@MainActor
private final class RepositoryPluginManagerSpy: BrowsePluginManaging {
    @Published private(set) var installedPlugins: [String: InstalledPlugin] = [:]

    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> {
        $installedPlugins.eraseToAnyPublisher()
    }

    func reloadInstalledPlugins() async {}
    func holdCompletionDelivery(for pluginID: String) async throws {}
    func purgeCompletionDelivery(for pluginID: String) async {}
    func revokeTrust(for pluginID: String) throws {}
    func removeSecrets(for pluginID: String) {}

    func publish(_ plugins: [String: InstalledPlugin]) {
        installedPlugins = plugins
    }
}

@MainActor
private final class RepositoryMessagePresenterSpy: RepositoryManagementMessagePresenting {
    private(set) var messages: [RepositoryManagementMessage] = []

    func present(_ message: RepositoryManagementMessage) {
        messages.append(message)
    }
}
