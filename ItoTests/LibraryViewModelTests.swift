import Combine
import GRDB
import XCTest
import ito_runner
@testable import Ito

@MainActor
final class LibraryViewModelTests: XCTestCase {
    func testRootPhasesAndAuthoritativeItemCategoryLinkPublication() async {
        let subject = makeSubject(snapshot: snapshot(isLoading: true))
        let sameModel = subject.viewModel
        XCTAssertEqual(subject.viewModel.phase, .loading)

        subject.library.publish(snapshot())
        XCTAssertEqual(subject.viewModel.phase, .empty)

        let first = item("one", "Alpha")
        let second = item("two", "Beta")
        let system = category("system", "Uncategorized", isSystem: true)
        let favorites = category("favorites", "Favorites")
        subject.library.publish(
            snapshot(
                items: [first],
                categories: [system],
                links: [link(first, system)]
            )
        )
        XCTAssertEqual(subject.viewModel.phase, .content)
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["one"])

        subject.library.publish(
            snapshot(
                items: [first, second],
                categories: [system],
                links: [link(first, system)]
            )
        )
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["one", "two"])
        subject.library.publish(
            snapshot(
                items: [first, second],
                categories: [system, favorites],
                links: [link(first, system)]
            )
        )
        XCTAssertEqual(subject.viewModel.categories.map(\.id), ["system", "favorites"])
        subject.library.publish(
            snapshot(
                items: [first, second],
                categories: [system, favorites],
                links: [link(first, system), link(second, favorites)]
            )
        )
        XCTAssertEqual(subject.viewModel.groups.map(\.id), ["system", "favorites"])
        XCTAssertEqual(subject.viewModel.groups[1].items.map(\.id), ["two"])
        XCTAssertTrue(subject.viewModel === sameModel)

        subject.library.publish(
            snapshot(
                items: [second],
                categories: [system, favorites],
                links: [link(second, favorites)]
            )
        )
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["two"])
    }

    func testSearchAndGroupingPreserveCharacterizedSemanticsAndOrder() {
        let alpha = item("alpha", "Alpha Hero")
        let beta = item("beta", "beta story")
        let spaced = item("spaced", "Alpha  Hero")
        let first = category("first", "First")
        let empty = category("empty", "Empty")
        let second = category("second", "Second")
        let subject = makeSubject(
            snapshot: snapshot(
                items: [alpha, beta, spaced],
                categories: [first, empty, second],
                links: [link(alpha, first), link(spaced, first), link(beta, second)]
            )
        )

        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["alpha", "beta", "spaced"])
        XCTAssertEqual(subject.viewModel.groups.map(\.id), ["first", "second"])
        XCTAssertEqual(subject.viewModel.groups[0].items.map(\.id), ["alpha", "spaced"])
        XCTAssertEqual(subject.viewModel.groups.map(\.items.count), [2, 1])

        subject.viewModel.searchText = "ALPHA"
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["alpha", "spaced"])
        XCTAssertFalse(subject.viewModel.showsNoResults)
        subject.viewModel.searchText = "Alpha Hero"
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["alpha"])
        subject.viewModel.searchText = " Alpha"
        XCTAssertTrue(subject.viewModel.filteredItems.isEmpty)
        XCTAssertTrue(subject.viewModel.showsNoResults)

        subject.viewModel.searchText = ""
        subject.viewModel.toggleLayout()
        XCTAssertEqual(subject.viewModel.layoutStyle, .tabbed)
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["alpha", "beta", "spaced"])
        subject.viewModel.selectCategory("second")
        XCTAssertEqual(subject.viewModel.groups.map(\.id), ["second"])
        XCTAssertEqual(subject.viewModel.groups[0].items.map(\.id), ["beta"])
        subject.viewModel.searchText = "Alpha"
        XCTAssertTrue(subject.viewModel.groups[0].items.isEmpty)
        XCTAssertTrue(subject.viewModel.showsNoResults)

        let only = category("only", "Only")
        subject.library.publish(
            snapshot(items: [alpha], categories: [only], links: [])
        )
        subject.viewModel.selectCategory(nil)
        subject.layout.publish(.sectioned)
        XCTAssertEqual(subject.viewModel.groups.map(\.id), ["only"])
        XCTAssertTrue(subject.viewModel.groups[0].items.isEmpty)
    }

    func testSearchInAllFindsSeriesThatAreInNoList() {
        let listless = item("listless", "The Infinite Mage")
        let subject = makeSubject(
            snapshot: snapshot(items: [listless]),
            layoutRawValue: LibraryLayoutStyle.tabbed.rawValue
        )

        subject.viewModel.searchText = "Mage"

        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["listless"])
        XCTAssertFalse(subject.viewModel.showsNoResults)
        subject.viewModel.searchText = "Knight"
        XCTAssertTrue(subject.viewModel.showsNoResults)
    }

    func testLayoutInitialFallbackPersistenceFailureAndRapidStaleWrites() async {
        let initialTabbed = makeSubject(layoutRawValue: LibraryLayoutStyle.tabbed.rawValue)
        XCTAssertEqual(initialTabbed.viewModel.layoutStyle, .tabbed)
        let invalid = makeSubject(layoutRawValue: 99)
        XCTAssertEqual(invalid.viewModel.layoutStyle, .sectioned)

        let success = makeSubject()
        success.viewModel.toggleLayout()
        await waitUntil { success.layout.requests.count == 1 }
        XCTAssertEqual(success.viewModel.layoutStyle, .tabbed)
        success.layout.resolve(at: 0, result: .success(()))
        await waitUntil {
            success.layout.storedLibraryLayoutStyle == LibraryLayoutStyle.tabbed.rawValue
        }
        XCTAssertEqual(success.layout.storedLibraryLayoutStyle, LibraryLayoutStyle.tabbed.rawValue)
        XCTAssertEqual(success.viewModel.layoutStyle, .tabbed)

        let failure = makeSubject()
        failure.viewModel.toggleLayout()
        await waitUntil { failure.layout.requests.count == 1 }
        failure.layout.resolve(at: 0, result: .failure(TestFailure.expected))
        await waitUntil { failure.messages.messages == [.layoutPersistenceFailed] }
        XCTAssertEqual(failure.viewModel.layoutStyle, .sectioned)

        let rapid = makeSubject()
        rapid.viewModel.toggleLayout()
        await waitUntil { rapid.layout.requests.count == 1 }
        rapid.viewModel.toggleLayout()
        XCTAssertEqual(rapid.viewModel.layoutStyle, .sectioned)
        rapid.layout.resolve(at: 0, result: .success(()))
        await waitUntil { rapid.layout.requests.count == 2 }
        XCTAssertEqual(rapid.viewModel.layoutStyle, .sectioned)
        rapid.layout.resolve(at: 0, result: .success(()))
        await waitUntil {
            rapid.layout.storedLibraryLayoutStyle == LibraryLayoutStyle.sectioned.rawValue
        }
        XCTAssertEqual(rapid.layout.storedLibraryLayoutStyle, LibraryLayoutStyle.sectioned.rawValue)
        XCTAssertEqual(rapid.viewModel.layoutStyle, .sectioned)
    }

    func testSelectedCategoryEditAssignmentAndAuthoritativeInvalidation() {
        let first = item("one", "One")
        let second = item("two", "Two")
        let a = category("a", "A")
        let b = category("b", "B")
        let subject = makeSubject(
            snapshot: snapshot(
                items: [first, second],
                categories: [a, b],
                links: [link(first, a), link(second, b)]
            ),
            layoutRawValue: LibraryLayoutStyle.tabbed.rawValue
        )

        subject.viewModel.selectCategory("b")
        XCTAssertEqual(subject.viewModel.selectedCategoryID, "b")
        subject.viewModel.toggleEditing()
        XCTAssertTrue(subject.viewModel.isEditing)
        subject.viewModel.presentCategoryAssignment(for: second.id)
        XCTAssertEqual(subject.viewModel.categoryAssignmentItemID, second.id)
        subject.viewModel.dismissCategoryAssignment()
        XCTAssertNil(subject.viewModel.categoryAssignmentItemID)
        subject.viewModel.toggleEditing()
        XCTAssertFalse(subject.viewModel.isEditing)

        subject.library.publish(
            snapshot(items: [first, second], categories: [a], links: [link(first, a)])
        )
        XCTAssertNil(subject.viewModel.selectedCategoryID)
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["one", "two"])
    }

    func testRemovalNeedsConfirmationAndCancelRemovesNothing() {
        let first = item("one", "One", pluginID: "plugin.one")
        let subject = makeSubject(snapshot: snapshot(items: [first]))

        subject.viewModel.requestRemoval(first)
        XCTAssertEqual(subject.viewModel.pendingRemoval?.id, "one")
        subject.viewModel.cancelRemoval()
        XCTAssertNil(subject.viewModel.pendingRemoval)
        subject.viewModel.confirmRemoval()
        XCTAssertTrue(subject.library.removeRequests.isEmpty)

        subject.viewModel.requestRemoval(first)
        subject.library.publish(snapshot(items: []))
        XCTAssertNil(subject.viewModel.pendingRemoval)
    }

    func testDurableRemoveSuppressesDuplicateAndFollowsAuthoritativePublication() async {
        let first = item("one", "One", pluginID: "plugin.one")
        let second = item("two", "Two", pluginID: "plugin.two")
        let subject = makeSubject(snapshot: snapshot(items: [first, second]))

        subject.viewModel.requestRemoval(first)
        subject.viewModel.confirmRemoval()
        subject.viewModel.requestRemoval(first)
        subject.viewModel.confirmRemoval()
        XCTAssertNil(subject.viewModel.pendingRemoval)
        await waitUntil { subject.library.removeRequests.count == 1 }
        XCTAssertEqual(subject.library.removeRequests[0], .init(itemID: "one", pluginID: "plugin.one"))
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["one", "two"])
        subject.library.resolveRemove(at: 0, result: .success(()))
        await waitUntil { subject.viewModel.removingItemIDs.isEmpty }
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["one", "two"])
        subject.library.publish(snapshot(items: [second]))
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["two"])

        subject.viewModel.requestRemoval(second)
        subject.viewModel.confirmRemoval()
        await waitUntil { subject.library.removeRequests.count == 2 }
        subject.library.resolveRemove(at: 0, result: .failure(TestFailure.expected))
        await waitUntil { subject.messages.messages == [.itemRemovalFailed] }
        XCTAssertEqual(subject.viewModel.filteredItems.map(\.id), ["two"])
    }

    func testBadgesUseExactMediaIdentityPublishAndDoNotClearWhileEditing() async {
        let first = item("same", "One", pluginID: "plugin.one")
        let second = item("same", "Two", pluginID: "plugin.two")
        let firstIdentity = MediaIdentity(pluginId: "plugin.one", itemId: "same")
        let secondIdentity = MediaIdentity(pluginId: "plugin.two", itemId: "same")
        let subject = makeSubject(snapshot: snapshot(items: [first, second]))
        subject.updates.publish(badges: [firstIdentity: 2, secondIdentity: 4])

        XCTAssertEqual(subject.viewModel.badgeCount(for: first), 2)
        XCTAssertEqual(subject.viewModel.badgeCount(for: second), 4)
        subject.viewModel.itemSelected(first)
        await waitUntil { subject.updates.clearRequests == [firstIdentity] }
        XCTAssertEqual(subject.viewModel.badgeCount(for: first), 0)
        XCTAssertEqual(subject.viewModel.badgeCount(for: second), 4)

        subject.viewModel.toggleEditing()
        subject.viewModel.itemSelected(second)
        await Task.yield()
        XCTAssertEqual(subject.updates.clearRequests, [firstIdentity])
    }

    func testUpdateRequestDeduplicationProgressFailureAndRetry() async {
        let subject = makeSubject(snapshot: snapshot(items: [item("one", "One")]))
        let first = Task { await subject.viewModel.requestUpdate() }
        let duplicate = Task { await subject.viewModel.requestUpdate() }
        await waitUntil { subject.updates.checkCallCount == 1 }
        subject.updates.publish(isRefreshing: true, current: 1, total: 3)
        XCTAssertTrue(subject.viewModel.isRefreshing)
        XCTAssertEqual(subject.viewModel.updateProgressCurrent, 1)
        XCTAssertEqual(subject.viewModel.updateProgressTotal, 3)
        subject.updates.resolveCheck(at: 0, result: .success(()))
        await first.value
        await duplicate.value
        subject.updates.publish(isRefreshing: false, current: 3, total: 3)
        XCTAssertFalse(subject.viewModel.isRefreshing)

        let retry = Task { await subject.viewModel.requestUpdate() }
        await waitUntil { subject.updates.checkCallCount == 2 }
        subject.updates.resolveCheck(at: 0, result: .failure(TestFailure.expected))
        await retry.value
        XCTAssertEqual(subject.messages.messages, [.updateFailed])

        let final = Task { await subject.viewModel.requestUpdate() }
        await waitUntil { subject.updates.checkCallCount == 3 }
        subject.updates.resolveCheck(at: 0, result: .success(()))
        await final.value
    }

    func testExportSuccessFailureDuplicateCallbacksAndStaleCancellationAreSanitized() async {
        let subject = makeSubject()
        subject.viewModel.beginExport()
        subject.viewModel.beginExport()
        await waitUntil { subject.export.requests == 1 }
        XCTAssertTrue(subject.viewModel.isGeneratingExport)
        let sensitiveURL = URL(fileURLWithPath: "/tmp/private/user/library.itobackup")
        subject.export.resolve(
            at: 0,
            result: .success(
                LibraryExportArtifact(
                    document: BackupDocument(url: sensitiveURL),
                    defaultFilename: "Ito_Backup.itobackup"
                )
            )
        )
        await waitUntil { subject.viewModel.exportPresentation != nil }
        XCTAssertEqual(subject.viewModel.exportPresentation?.defaultFilename, "Ito_Backup.itobackup")
        XCTAssertFalse(subject.logger.formattedMessages.joined().contains(sensitiveURL.path))
        subject.viewModel.exporterDidSucceed()
        XCTAssertNil(subject.viewModel.exportPresentation)

        subject.viewModel.beginExport()
        await waitUntil { subject.export.requests == 2 }
        subject.export.resolve(at: 0, result: .failure(TestFailure.expected))
        await waitUntil { subject.viewModel.alert == .exportGenerationFailed }
        XCTAssertNil(subject.viewModel.exportPresentation)
        subject.viewModel.dismissAlert()

        subject.viewModel.beginExport()
        await waitUntil { subject.export.requests == 3 }
        subject.viewModel.cancelExportGeneration()
        subject.viewModel.beginExport()
        await waitUntil { subject.export.requests == 4 }
        subject.export.resolve(
            at: 0,
            result: .success(
                LibraryExportArtifact(
                    document: BackupDocument(url: sensitiveURL),
                    defaultFilename: "Stale.itobackup"
                )
            )
        )
        await Task.yield()
        XCTAssertNil(subject.viewModel.exportPresentation)
        subject.export.resolve(
            at: 0,
            result: .success(
                LibraryExportArtifact(
                    document: BackupDocument(url: sensitiveURL),
                    defaultFilename: "Current.itobackup"
                )
            )
        )
        await waitUntil {
            subject.viewModel.exportPresentation?.defaultFilename == "Current.itobackup"
        }
        subject.viewModel.exporterDidFail()
        XCTAssertEqual(subject.viewModel.alert, .exporterFailed)
        XCTAssertNil(subject.viewModel.exportPresentation)
    }

    func testDiscordLifecycleSelectionDeduplicationAndCategoryRemoval() {
        let a = category("a", "A")
        let b = category("b", "B")
        let subject = makeSubject(snapshot: snapshot(categories: [a, b]))

        subject.viewModel.appear()
        subject.viewModel.appear()
        XCTAssertEqual(subject.discord.calls.count, 1)
        XCTAssertNil(subject.discord.calls[0])
        subject.viewModel.selectCategory("b")
        subject.viewModel.selectCategory("b")
        XCTAssertEqual(subject.discord.calls.count, 2)
        XCTAssertEqual(subject.discord.calls[1], "B")
        subject.library.publish(snapshot(items: [item("x", "X")], categories: [a, b]))
        XCTAssertEqual(subject.discord.calls.count, 2)
        subject.library.publish(snapshot(categories: [a]))
        XCTAssertNil(subject.viewModel.selectedCategoryID)
        XCTAssertEqual(subject.discord.calls.count, 3)
        XCTAssertNil(subject.discord.calls[2])
        subject.viewModel.disappear()
        XCTAssertEqual(subject.discord.calls.count, 3)
        subject.viewModel.appear()
        XCTAssertEqual(subject.discord.calls.count, 4)
        XCTAssertNil(subject.discord.calls[3])
    }

    func testProductionLibraryBoundaryReflectsDurableCanonicalSnapshotsAndRemoval() async throws {
        let database = try TestDatabase()
        defer { database.cleanup() }
        let manager = LibraryManager(dbPool: database.dbPool)
        let uncategorized = LibraryCategory(
            id: "uncategorized",
            name: "Uncategorized",
            sortOrder: 0,
            isSystemCategory: true,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        try await database.dbPool.write { db in
            // The fixture's system list replaces the migrated one.
            try db.execute(sql: "DELETE FROM libraryCategory WHERE isSystemCategory = 1")
            try uncategorized.insert(db)
        }
        try await manager.reload()
        let manga = Manga(key: "durable", title: "Durable")
        let itemID = try await manager.saveMangaDurably(manga: manga, pluginId: "plugin")
        await waitUntil { manager.rootSnapshot.items.contains(where: { $0.id == itemID }) }

        XCTAssertEqual(manager.rootSnapshot.items.map(\.id), [itemID])
        XCTAssertEqual(manager.rootSnapshot.categories.count, 1)
        XCTAssertEqual(manager.rootSnapshot.links.map(\.itemId), [itemID])
        try await manager.removeItem(itemID: itemID, pluginID: "plugin")
        XCTAssertTrue(manager.rootSnapshot.items.isEmpty)
        let durableCount = try await database.dbPool.read { db in
            try LibraryItem.fetchCount(db)
        }
        XCTAssertEqual(durableCount, 0)
    }

    private func makeSubject(
        snapshot: LibraryRootSnapshot? = nil,
        layoutRawValue: Int = LibraryLayoutStyle.sectioned.rawValue
    ) -> LibrarySubject {
        let library = FakeLibraryRoot(snapshot: snapshot ?? self.snapshot())
        let layout = FakeLibraryLayout(rawValue: layoutRawValue)
        let updates = FakeLibraryUpdates()
        let export = FakeLibraryExport()
        let discord = FakeLibraryDiscord()
        let plugins = FakeLibraryPlugins()
        let installer = FakeDeferredInstaller()
        let decoder = FakeDeferredDecoder()
        let messages = FakeLibraryMessages()
        let logger = PresentationEventCaptureSpy()
        let dependencies = PreparedLibraryDependencies(
            library: library,
            layout: layout,
            updates: updates,
            export: export,
            discord: discord,
            plugins: plugins,
            installer: installer,
            payloadDecoder: decoder
        )
        return LibrarySubject(
            viewModel: LibraryViewModel(
                dependencies: dependencies,
                messagePresenter: messages,
                presentationLogger: logger
            ),
            library: library,
            layout: layout,
            updates: updates,
            export: export,
            discord: discord,
            messages: messages,
            logger: logger
        )
    }

    private func snapshot(
        items: [Ito.LibraryItem] = [],
        categories: [LibraryCategory] = [],
        links: [ItemCategoryLink] = [],
        isLoading: Bool = false
    ) -> LibraryRootSnapshot {
        LibraryRootSnapshot(
            items: items,
            categories: categories,
            links: links,
            isLoading: isLoading
        )
    }

    private func item(
        _ id: String,
        _ title: String,
        pluginID: String = "plugin"
    ) -> Ito.LibraryItem {
        Ito.LibraryItem(
            id: id,
            title: title,
            coverUrl: nil,
            pluginId: pluginID,
            isAnime: false,
            pluginType: .manga,
            rawPayload: Data(),
            anilistId: nil
        )
    }

    private func category(
        _ id: String,
        _ name: String,
        isSystem: Bool = false
    ) -> LibraryCategory {
        LibraryCategory(
            id: id,
            name: name,
            sortOrder: 0,
            isSystemCategory: isSystem,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func link(_ item: Ito.LibraryItem, _ category: LibraryCategory) -> ItemCategoryLink {
        ItemCategoryLink(
            itemId: item.id,
            categoryId: category.id,
            addedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

private struct LibrarySubject {
    let viewModel: LibraryViewModel
    let library: FakeLibraryRoot
    let layout: FakeLibraryLayout
    let updates: FakeLibraryUpdates
    let export: FakeLibraryExport
    let discord: FakeLibraryDiscord
    let messages: FakeLibraryMessages
    let logger: PresentationEventCaptureSpy
}

private enum TestFailure: Error {
    case expected
}

@MainActor
private final class FakeLibraryRoot: LibraryRootServing {
    struct RemoveRequest: Equatable {
        let itemID: String
        let pluginID: String
    }

    private let subject: CurrentValueSubject<LibraryRootSnapshot, Never>
    private(set) var removeRequests: [RemoveRequest] = []
    private var removeContinuations: [CheckedContinuation<Void, Error>] = []

    init(snapshot: LibraryRootSnapshot) {
        subject = CurrentValueSubject(snapshot)
    }

    var rootSnapshot: LibraryRootSnapshot { subject.value }
    var rootSnapshotPublisher: AnyPublisher<LibraryRootSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }

    func publish(_ snapshot: LibraryRootSnapshot) {
        subject.send(snapshot)
    }

    func removeItem(itemID: String, pluginID: String) async throws {
        removeRequests.append(.init(itemID: itemID, pluginID: pluginID))
        try await withCheckedThrowingContinuation { continuation in
            removeContinuations.append(continuation)
        }
    }

    func resolveRemove(at index: Int, result: Result<Void, Error>) {
        removeContinuations.remove(at: index).resume(with: result)
    }
}

@MainActor
private final class FakeLibraryLayout: LibraryLayoutPersisting {
    private let subject: CurrentValueSubject<Int, Never>
    private(set) var requests: [Int] = []
    private var continuations: [CheckedContinuation<Void, Error>] = []

    init(rawValue: Int) {
        subject = CurrentValueSubject(rawValue)
    }

    var storedLibraryLayoutStyle: Int { subject.value }
    var storedLibraryLayoutStylePublisher: AnyPublisher<Int, Never> {
        subject.eraseToAnyPublisher()
    }
    var pendingCount: Int { continuations.count }

    func publish(_ style: LibraryLayoutStyle) {
        subject.send(style.rawValue)
    }

    func persistLibraryLayoutStyle(_ rawValue: Int) async throws {
        requests.append(rawValue)
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
        subject.send(rawValue)
    }

    func resolve(at index: Int, result: Result<Void, Error>) {
        continuations.remove(at: index).resume(with: result)
    }
}

@MainActor
private final class FakeLibraryUpdates: LibraryUpdateServing {
    private let subject = CurrentValueSubject<LibraryUpdateSnapshot, Never>(
        LibraryUpdateSnapshot(isRefreshing: false, current: 0, total: 0, badgeCounts: [:])
    )
    private(set) var clearRequests: [MediaIdentity] = []
    private(set) var checkCallCount = 0
    private var checkContinuations: [CheckedContinuation<Void, Error>] = []

    var libraryUpdateSnapshot: LibraryUpdateSnapshot { subject.value }
    var libraryUpdateSnapshotPublisher: AnyPublisher<LibraryUpdateSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }

    func publish(
        isRefreshing: Bool = false,
        current: Int = 0,
        total: Int = 0,
        badges: [MediaIdentity: Int]? = nil
    ) {
        subject.send(
            LibraryUpdateSnapshot(
                isRefreshing: isRefreshing,
                current: current,
                total: total,
                badgeCounts: badges ?? subject.value.badgeCounts
            )
        )
    }

    func checkLibraryForUpdates() async throws {
        checkCallCount += 1
        try await withCheckedThrowingContinuation { continuation in
            checkContinuations.append(continuation)
        }
    }

    func resolveCheck(at index: Int, result: Result<Void, Error>) {
        checkContinuations.remove(at: index).resume(with: result)
    }

    func clearLibraryBadge(for media: MediaIdentity) async throws {
        clearRequests.append(media)
        var badges = subject.value.badgeCounts
        badges[media] = nil
        publish(badges: badges)
    }
}

@MainActor
private final class FakeLibraryExport: LibraryExportServing {
    private(set) var requests = 0
    private var continuations: [CheckedContinuation<LibraryExportArtifact, Error>] = []

    func generateLibraryExport() async throws -> LibraryExportArtifact {
        requests += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resolve(at index: Int, result: Result<LibraryExportArtifact, Error>) {
        continuations.remove(at: index).resume(with: result)
    }
}

@MainActor
private final class FakeLibraryDiscord: LibraryDiscordPresenting {
    private(set) var calls: [String?] = []

    func presentLibrary(categoryName: String?) {
        calls.append(categoryName)
    }
}

@MainActor
private final class FakeLibraryPlugins: LibraryPluginServing {
    private let subject = CurrentValueSubject<LibraryPluginSnapshot, Never>(
        LibraryPluginSnapshot(publicationRevision: 0, plugins: [:])
    )

    var libraryPluginSnapshot: LibraryPluginSnapshot { subject.value }
    var libraryPluginSnapshotPublisher: AnyPublisher<LibraryPluginSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }

    func libraryRunner(
        for plugin: LibraryInstalledPluginIdentity,
        publicationRevision: UInt64
    ) async throws -> ItoRunner {
        _ = plugin
        _ = publicationRevision
        return ItoRunner()
    }
}

@MainActor
private final class FakeDeferredInstaller: DeferredPluginInstalling {
    func findPackage(forExactPluginID pluginID: String) async throws
        -> DeferredPluginPackageCandidate? {
        _ = pluginID
        return nil
    }

    func install(_ candidate: DeferredPluginPackageCandidate) async throws {
        _ = candidate
    }
}

@MainActor
private final class FakeDeferredDecoder: DeferredPluginPayloadDecoding {
    func decode(_ item: Ito.LibraryItem) async throws -> DeferredPluginMedia {
        _ = item
        throw TestFailure.expected
    }
}

@MainActor
private final class FakeLibraryMessages: LibraryMessagePresenting {
    private(set) var messages: [LibraryMessage] = []

    func present(_ message: LibraryMessage) {
        messages.append(message)
    }
}
