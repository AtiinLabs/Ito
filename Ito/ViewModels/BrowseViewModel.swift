import Combine
import Foundation
import ito_runner

@MainActor
public final class BrowseViewModel: ObservableObject {
    public enum Phase: Equatable {
        case loading
        case empty
        case content
    }

    public struct UpdateItem: Identifiable {
        public var id: String { pkg.id }
        public let pkg: RepoPackage
        public let repoURL: String
    }

    public struct PluginGroup: Identifiable {
        public var id: String { String(describing: type) }
        public let type: PluginType
        public let plugins: [InstalledPlugin]
    }

    @Published public var showDeleteConfirmation = false
    @Published public var showRepositories = false
    @Published public private(set) var isInstallingUpdate: String?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isProcessingPluginFile = false
    @Published public private(set) var pendingDeletePluginID: String?
    @Published private var installedPlugins: [String: InstalledPlugin]
    @Published private var repositories: [Repository]

    private let repositoryManager: any BrowseRepositoryManaging
    private let pluginManager: any BrowsePluginManaging
    private let fileOperations: any BrowsePluginFileOperating
    private let messagePresenter: any BrowseMessagePresenting
    private let repositoryIntentRouter: any BrowseRepositoryIntentRouting
    private var pendingDeletePlugin: InstalledPlugin?
    private var repositoryIntentDrainTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(
        repositoryManager: any BrowseRepositoryManaging,
        pluginManager: any BrowsePluginManaging,
        fileOperations: any BrowsePluginFileOperating,
        messagePresenter: any BrowseMessagePresenting,
        repositoryIntentRouter: any BrowseRepositoryIntentRouting
    ) {
        self.repositoryManager = repositoryManager
        self.pluginManager = pluginManager
        self.fileOperations = fileOperations
        self.messagePresenter = messagePresenter
        self.repositoryIntentRouter = repositoryIntentRouter
        installedPlugins = pluginManager.installedPlugins
        repositories = repositoryManager.repositories

        pluginManager.installedPluginsPublisher
            .sink { @MainActor [weak self] plugins in
                self?.installedPlugins = plugins
            }
            .store(in: &cancellables)

        repositoryManager.repositoriesPublisher
            .sink { @MainActor [weak self] repositories in
                self?.repositories = repositories
            }
            .store(in: &cancellables)

        repositoryIntentRouter.repositoryIntentPublisher
            .sink { @MainActor [weak self] _ in
                self?.startRepositoryIntentDrain()
            }
            .store(in: &cancellables)
    }

    deinit {
        repositoryIntentDrainTask?.cancel()
    }

    public var phase: Phase {
        if isInstallingUpdate != nil || isRefreshing || isProcessingPluginFile {
            return .loading
        }
        return installedPlugins.isEmpty ? .empty : .content
    }

    public var sortedPlugins: [InstalledPlugin] {
        installedPlugins.values.sorted { $0.info.name < $1.info.name }
    }

    public var pluginGroups: [PluginGroup] {
        let types: [PluginType] = [.anime, .manga, .novel]
        return types.compactMap { type in
            let plugins = sortedPlugins.filter { $0.info.type == type }
            return plugins.isEmpty ? nil : PluginGroup(type: type, plugins: plugins)
        }
    }

    public var availableUpdates: [UpdateItem] {
        var updates: [String: UpdateItem] = [:]
        for repository in repositories {
            guard let packages = repository.index?.packages else { continue }
            for package in packages {
                // An update this version of Ito can't run isn't offered.
                guard let installed = installedPlugins[package.id],
                      installed.info.version.compare(
                        package.version,
                        options: .numeric
                      ) == .orderedAscending,
                      package.compatibilityRefusal() == nil else {
                    continue
                }

                if let existing = updates[package.id],
                   existing.pkg.version.compare(
                    package.version,
                    options: .numeric
                   ) != .orderedAscending {
                    continue
                }
                updates[package.id] = UpdateItem(pkg: package, repoURL: repository.url)
            }
        }
        return updates.values.sorted { $0.pkg.name < $1.pkg.name }
    }

    public func openRepositories() {
        showRepositories = true
    }

    public func refreshRepositories() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await repositoryManager.refreshAll()
    }

    /// Refreshes indexes older than `maxAge`, or missing (never fetched or unreadable), so new
    /// plugin versions show under Updates without a manual pull to refresh. Leaves the list on screen.
    public func refreshStaleRepositories(now: Date = Date(), maxAge: TimeInterval = 600) async {
        let hasStaleRepository = repositories.contains { repository in
            guard let lastFetched = repository.lastFetched, repository.index != nil else { return true }
            return now.timeIntervalSince(lastFetched) >= maxAge
        }
        guard hasStaleRepository else { return }
        await repositoryManager.refreshAll()
    }

    public func installUpdate(_ updateItem: UpdateItem) async {
        guard isInstallingUpdate == nil else { return }
        isInstallingUpdate = updateItem.id
        defer { isInstallingUpdate = nil }

        do {
            try await repositoryManager.installPackage(
                updateItem.pkg,
                repositoryURL: updateItem.repoURL
            )
        } catch {
            messagePresenter.present(.updateFailed(reason: error.localizedDescription))
        }
    }

    public func requestDelete(_ plugin: InstalledPlugin) {
        guard !isProcessingPluginFile else { return }
        pendingDeletePlugin = plugin
        pendingDeletePluginID = plugin.id
        showDeleteConfirmation = true
    }

    public func cancelDelete() {
        guard !isProcessingPluginFile else { return }
        pendingDeletePlugin = nil
        pendingDeletePluginID = nil
        showDeleteConfirmation = false
    }

    public func confirmDelete() async {
        guard let plugin = pendingDeletePlugin, !isProcessingPluginFile else { return }
        showDeleteConfirmation = false
        isProcessingPluginFile = true
        defer {
            pendingDeletePlugin = nil
            pendingDeletePluginID = nil
            isProcessingPluginFile = false
        }

        do {
            try await pluginManager.holdCompletionDelivery(for: plugin.id)
            try pluginManager.revokeTrust(for: plugin.id)
            try fileOperations.deletePluginFile(at: plugin.url)
            await pluginManager.purgeCompletionDelivery(for: plugin.id)
            pluginManager.removeSecrets(for: plugin.id)
            await pluginManager.reloadInstalledPlugins()
        } catch {
            messagePresenter.present(
                .deleteFailed(
                    pluginName: plugin.info.name,
                    reason: error.localizedDescription
                )
            )
        }
    }

    @discardableResult
    public func importPluginFile(
        at url: URL,
        source: BrowseImportSource
    ) async -> Bool {
        guard fileOperations.supportsPluginFile(at: url) else {
            messagePresenter.present(.unsupportedPluginFile)
            return false
        }
        guard !isProcessingPluginFile else { return false }

        isProcessingPluginFile = true
        defer { isProcessingPluginFile = false }

        do {
            try fileOperations.installPluginFile(from: url)
            await pluginManager.reloadInstalledPlugins()
            return true
        } catch BrowsePluginFileError.pluginsDirectoryUnavailable {
            messagePresenter.present(.pluginDirectoryUnavailable)
            return false
        } catch {
            messagePresenter.present(
                .importFailed(source: source, reason: error.localizedDescription)
            )
            return false
        }
    }

    public func reportDropLoadingFailure(_ error: (any Error)?) {
        messagePresenter.present(.dropLoadFailed(reason: String(describing: error)))
    }

    public func consumePendingRepositoryIntents() async {
        let task = startRepositoryIntentDrain()
        await task.value
    }

    @discardableResult
    private func startRepositoryIntentDrain() -> Task<Void, Never> {
        if let repositoryIntentDrainTask {
            return repositoryIntentDrainTask
        }

        let repositoryManager = self.repositoryManager
        let messagePresenter = self.messagePresenter
        let repositoryIntentRouter = self.repositoryIntentRouter
        let task = Task { @MainActor [weak self] in
            await Self.drainRepositoryIntents(
                repositoryManager: repositoryManager,
                messagePresenter: messagePresenter,
                repositoryIntentRouter: repositoryIntentRouter,
                showRepositoryList: { self?.showRepositories = true }
            )
            self?.repositoryIntentDrainTask = nil
        }
        repositoryIntentDrainTask = task
        return task
    }

    private static func drainRepositoryIntents(
        repositoryManager: any BrowseRepositoryManaging,
        messagePresenter: any BrowseMessagePresenting,
        repositoryIntentRouter: any BrowseRepositoryIntentRouting,
        showRepositoryList: @MainActor () -> Void
    ) async {
        while !Task.isCancelled,
              let intent = repositoryIntentRouter.claimPendingRepositoryIntent() {
            do {
                let result = try await repositoryManager.addRepository(
                    url: intent.repositoryURL.absoluteString
                )
                guard !Task.isCancelled else { return }
                switch result {
                case .added:
                    messagePresenter.present(.repositoryAdded)
                case .alreadyPresent:
                    messagePresenter.present(.repositoryAlreadyAdded)
                }
                showRepositoryList()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                messagePresenter.present(.repositoryAddFailed)
            }
            repositoryIntentRouter.acknowledgeRepositoryIntent(token: intent.token)
        }
    }
}
