import Combine
import Foundation
import XCTest
import ito_runner
@testable import Ito

enum PR7BTestFailure: LocalizedError {
    case failed

    var errorDescription: String? { "fixture failure" }
}

@MainActor
func pr7bPlugin(
    id: String = "plugin.manga",
    name: String = "Fixture Source",
    type: PluginType = .manga,
    archived: Bool = false,
    url: URL? = nil
) -> InstalledPlugin {
    InstalledPlugin(
        url: url ?? URL(fileURLWithPath: "/plugins/\(id).ito"),
        info: PluginInfo(
            id: id,
            name: name,
            version: "1.0",
            minAppVersion: "1.0",
            type: type,
            archived: archived
        ),
        iconData: nil
    )
}

@MainActor
func pr7bSettingsSchema(settings: [Setting] = []) throws -> SettingsSchema {
    var schema = try JSONDecoder().decode(
        SettingsSchema.self,
        from: Data(#"{"settings":[]}"#.utf8)
    )
    schema.settings = settings
    return schema
}

@MainActor
func pr7bHome(ids: [String]) -> HomeLayout {
    HomeLayout(
        components: ids.map {
            HomeComponent(title: $0, value: .scroller([Manga(key: $0, title: $0)], nil))
        }
    )
}

@MainActor
func pr7bWaitUntil(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
    XCTFail("Condition was not met before timeout", file: file, line: line)
}

@MainActor
final class PR7BSourceRunnerProviderSpy: SourceRunnerProviding {
    var contexts: [any SourceRunnerContext]
    var error: (any Error)?
    private(set) var requestedPluginIDs: [String] = []
    private(set) var evictedPluginIDs: [String] = []

    init(contexts: [any SourceRunnerContext] = [PR7BSourceRunnerContextSpy()]) {
        self.contexts = contexts
    }

    func sourceRunnerContext(for pluginID: String) async throws -> any SourceRunnerContext {
        requestedPluginIDs.append(pluginID)
        if let error { throw error }
        guard !contexts.isEmpty else { throw PR7BTestFailure.failed }
        if contexts.count == 1 { return contexts[0] }
        return contexts.removeFirst()
    }

    func evictSourceRunner(for pluginID: String) {
        evictedPluginIDs.append(pluginID)
    }
}

@MainActor
final class PR7BSourceRunnerContextSpy: @MainActor SourceRunnerContext {
    struct SearchInvocation: Equatable {
        let pluginType: PluginType
        let query: String
        let page: Int32
        let filterCount: Int?
    }

    struct ListingInvocation: Equatable {
        let pluginType: PluginType
        let listingID: String
        let page: Int32
    }

    struct PendingSearch {
        let query: String
        let continuation: CheckedContinuation<SourceSearchPage, any Error>
    }

    struct PendingListing {
        let page: Int32
        let continuation: CheckedContinuation<ListingContentPage, any Error>
    }

    let runner = ItoRunner()
    var homeResult: Result<HomeLayout, any Error> = .success(HomeLayout(components: []))
    var settingsResult: Result<SettingsSchema?, any Error> = .success(nil)
    var searchResult: Result<SourceSearchPage, any Error> = .success(.manga([]))
    var listingResults: [Int32: Result<ListingContentPage, any Error>] = [:]
    var suspendsHome = false
    var suspendsSearch = false
    var suspendedListingPages: Set<Int32> = []
    private(set) var homeLoadCount = 0
    private(set) var settingsLoadCount = 0
    private(set) var loadEvents: [String] = []
    private(set) var searchInvocations: [SearchInvocation] = []
    private(set) var listingInvocations: [ListingInvocation] = []
    private var pendingHomes: [CheckedContinuation<HomeLayout, any Error>] = []
    private(set) var pendingSearches: [PendingSearch] = []
    private(set) var pendingListings: [PendingListing] = []
    private(set) var mangaDetailLoadCount = 0
    private(set) var animeDetailLoadCount = 0
    private(set) var novelDetailLoadCount = 0

    func loadHome() async throws -> HomeLayout {
        homeLoadCount += 1
        loadEvents.append("home")
        if suspendsHome {
            return try await withCheckedThrowingContinuation { pendingHomes.append($0) }
        }
        return try homeResult.get()
    }

    func loadSettingsSchema() async throws -> SettingsSchema? {
        settingsLoadCount += 1
        loadEvents.append("settings")
        return try settingsResult.get()
    }

    func search(
        pluginType: PluginType,
        query: String,
        page: Int32,
        filters: [FilterItem]?
    ) async throws -> SourceSearchPage {
        searchInvocations.append(
            .init(pluginType: pluginType, query: query, page: page, filterCount: filters?.count)
        )
        if suspendsSearch {
            return try await withCheckedThrowingContinuation {
                pendingSearches.append(.init(query: query, continuation: $0))
            }
        }
        return try searchResult.get()
    }

    func loadListing(
        pluginType: PluginType,
        listing: Listing,
        page: Int32
    ) async throws -> ListingContentPage {
        listingInvocations.append(
            .init(pluginType: pluginType, listingID: listing.id, page: page)
        )
        if suspendedListingPages.contains(page) {
            return try await withCheckedThrowingContinuation {
                pendingListings.append(.init(page: page, continuation: $0))
            }
        }
        return try listingResults[page, default: .success(.manga(entries: [], hasNextPage: false))].get()
    }

    func loadManga(_ manga: Manga) async throws -> Manga {
        mangaDetailLoadCount += 1
        return manga
    }

    func loadAnime(_ anime: Anime) async throws -> Anime {
        animeDetailLoadCount += 1
        return anime
    }

    func loadNovel(_ novel: Novel) async throws -> Novel {
        novelDetailLoadCount += 1
        return novel
    }

    func completeHome(with result: Result<HomeLayout, any Error>) {
        guard !pendingHomes.isEmpty else { return }
        let continuation = pendingHomes.removeFirst()
        continuation.resume(with: result)
    }

    func completeSearch(query: String, with result: Result<SourceSearchPage, any Error>) {
        guard let index = pendingSearches.firstIndex(where: { $0.query == query }) else { return }
        let pending = pendingSearches.remove(at: index)
        pending.continuation.resume(with: result)
    }

    func completeListing(page: Int32, with result: Result<ListingContentPage, any Error>) {
        guard let index = pendingListings.firstIndex(where: { $0.page == page }) else { return }
        let pending = pendingListings.remove(at: index)
        pending.continuation.resume(with: result)
    }
}

@MainActor
final class PR7BSettingsStoreSpy: PluginSettingsPersisting {
    @Published var revision = 0
    var values: [String: String] = [:]
    var secrets: [String: String] = [:]
    var prepareError: (any Error)?
    var persistSucceeds = true
    var reloadResults: [Result<Void, any Error>] = [.success(())]
    var suspendsReload = false
    private(set) var preparedPluginIDs: [String] = []
    private(set) var reads: [(pluginID: String, key: String)] = []
    private(set) var writes: [(pluginID: String, key: String, value: String)] = []
    private(set) var reloadCount = 0
    private var reloadContinuations: [CheckedContinuation<Void, any Error>] = []

    var settingsRevisionPublisher: AnyPublisher<Int, Never> {
        $revision.eraseToAnyPublisher()
    }

    func prepareSettings(pluginID: String) throws {
        preparedPluginIDs.append(pluginID)
        if let prepareError { throw prepareError }
    }

    func storedValue(pluginID: String, key: String) -> String? {
        reads.append((pluginID, key))
        return values[key]
    }

    func persistValue(pluginID: String, key: String, value: String) -> Bool {
        writes.append((pluginID, key, value))
        guard persistSucceeds else { return false }
        values[key] = value
        revision += 1
        return true
    }

    func hasSecret(pluginID: String, key: String) -> Bool {
        secrets[key] != nil
    }

    func persistSecret(pluginID: String, key: String, value: String) -> Bool {
        guard persistSucceeds else { return false }
        secrets[key] = value
        values[key] = nil
        revision += 1
        return true
    }

    func clearSecret(pluginID: String, key: String) -> Bool {
        guard persistSucceeds else { return false }
        secrets[key] = nil
        revision += 1
        return true
    }

    func reloadPersistedSettings() async throws {
        reloadCount += 1
        if suspendsReload {
            return try await withCheckedThrowingContinuation { reloadContinuations.append($0) }
        }
        guard !reloadResults.isEmpty else { return }
        if reloadResults.count == 1 {
            try reloadResults[0].get()
        } else {
            try reloadResults.removeFirst().get()
        }
    }

    var pendingReloadCount: Int { reloadContinuations.count }

    func completeReload(at index: Int = 0, with result: Result<Void, any Error>) {
        guard reloadContinuations.indices.contains(index) else { return }
        let continuation = reloadContinuations.remove(at: index)
        continuation.resume(with: result)
    }
}

@MainActor
final class PR7BMessagePresenterSpy: SourceMessagePresenting {
    private(set) var messages: [SourceMessage] = []

    func present(_ message: SourceMessage) {
        messages.append(message)
    }
}

@MainActor
final class PR7BPluginStatePublisherSpy: SourcePluginStatePublishing {
    var results: [Result<Void, any Error>] = [.success(())]
    var suspends = false
    var currentPlugins: [String: InstalledPlugin] = [:]
    var onPublish: (() -> Void)?
    private(set) var callCount = 0
    private(set) var publishCount = 0
    private(set) var removedSecretsPluginIDs: [String] = []
    var completionHoldError: (any Error)?
    var trustRevocationError: (any Error)?
    private(set) var revokedTrustPluginIDs: [String] = []
    private(set) var purgedCompletionPluginIDs: [String] = []
    private var continuations: [CheckedContinuation<Void, any Error>] = []

    func currentSourcePlugin(for pluginID: String) -> InstalledPlugin? {
        currentPlugins[pluginID]
    }

    func holdCompletionDelivery(for pluginID: String) async throws {
        if let completionHoldError { throw completionHoldError }
    }

    func revokeTrust(for pluginID: String) throws {
        revokedTrustPluginIDs.append(pluginID)
        if let trustRevocationError { throw trustRevocationError }
    }

    func purgeCompletionDelivery(for pluginID: String) async {
        purgedCompletionPluginIDs.append(pluginID)
    }

    func removeSecrets(for pluginID: String) {
        removedSecretsPluginIDs.append(pluginID)
    }

    func prepareSourcePluginStatePublication() async throws -> any SourcePluginStatePublication {
        callCount += 1
        let expectedIdentities = currentPlugins.mapValues(
            SourcePluginDeletionIdentity.init(plugin:)
        )
        if suspends {
            try await withCheckedThrowingContinuation { continuations.append($0) }
        }
        if results.count == 1 {
            try results[0].get()
        } else if !results.isEmpty {
            try results.removeFirst().get()
        }
        return PR7BSourcePluginStatePublicationSpy(
            owner: self,
            expectedIdentities: expectedIdentities
        )
    }

    func complete(at index: Int = 0, with result: Result<Void, any Error> = .success(())) {
        guard continuations.indices.contains(index) else { return }
        let continuation = continuations.remove(at: index)
        continuation.resume(with: result)
    }

    fileprivate func publishPreparedState() {
        onPublish?()
        publishCount += 1
        currentPlugins = [:]
    }

    fileprivate func validatePreparedState(
        expectedIdentities: [String: SourcePluginDeletionIdentity]
    ) throws {
        let currentIdentities = currentPlugins.mapValues(
            SourcePluginDeletionIdentity.init(plugin:)
        )
        guard currentIdentities == expectedIdentities else {
            throw SourcePluginFileError.stalePluginState
        }
    }
}

@MainActor
private final class PR7BSourcePluginStatePublicationSpy: SourcePluginStatePublication {
    private weak var owner: PR7BPluginStatePublisherSpy?
    private let expectedIdentities: [String: SourcePluginDeletionIdentity]

    init(
        owner: PR7BPluginStatePublisherSpy,
        expectedIdentities: [String: SourcePluginDeletionIdentity]
    ) {
        self.owner = owner
        self.expectedIdentities = expectedIdentities
    }

    func validateCurrentState() throws {
        try owner?.validatePreparedState(expectedIdentities: expectedIdentities)
    }

    func publish() {
        owner?.publishPreparedState()
    }
}

@MainActor
final class PR7BFileDeletionTransactionSpy: PluginFileDeletionTransaction {
    var commitError: (any Error)?
    var rollbackError: (any Error)?
    private(set) var commitCount = 0
    private(set) var rollbackCount = 0

    func commit() throws {
        commitCount += 1
        if let commitError { throw commitError }
    }

    func rollback() throws {
        rollbackCount += 1
        if let rollbackError { throw rollbackError }
    }
}

@MainActor
final class PR7BFileDeletionSpy: SourcePluginFileDeleting {
    let transaction = PR7BFileDeletionTransactionSpy()
    var snapshotError: (any Error)?
    var stageError: (any Error)?
    private(set) var snapshotPlugins: [InstalledPlugin] = []
    private(set) var stagedSnapshots: [SourcePluginFileSnapshot] = []

    func snapshotPluginFile(for plugin: InstalledPlugin) throws -> SourcePluginFileSnapshot {
        snapshotPlugins.append(plugin)
        if let snapshotError { throw snapshotError }
        return SourcePluginFileSnapshot(
            identity: SourcePluginDeletionIdentity(plugin: plugin),
            fileData: Data("\(plugin.id)-fixture".utf8)
        )
    }

    func stagePluginFileDeletion(
        from snapshot: SourcePluginFileSnapshot
    ) throws -> any PluginFileDeletionTransaction {
        stagedSnapshots.append(snapshot)
        if let stageError { throw stageError }
        return transaction
    }
}
