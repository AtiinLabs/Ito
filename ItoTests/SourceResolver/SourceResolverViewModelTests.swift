import XCTest
import Combine
import GRDB
@testable import Ito
import ito_runner

@MainActor
final class FakePluginProvider: SourceResolverPluginProviding {
    var installedPlugins: [String: InstalledPlugin] = [:] {
        didSet { installedPluginsSubject.send(installedPlugins) }
    }
    var configuredAdapters: [String: any PluginSearching] = [:]
    private var runners: [String: ItoRunner] = [:]
    private(set) var runnerRequestCount = 0
    var runnerError: Error?
    var suspendedRunnerPluginIDs = Set<String>()
    private var runnerContinuations: [
        String: CheckedContinuation<any SourceRunnerContext, Error>
    ] = [:]
    private let installedPluginsSubject = CurrentValueSubject<
        [String: InstalledPlugin],
        Never
    >([:])

    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> {
        installedPluginsSubject.eraseToAnyPublisher()
    }

    func sourceRunnerContext(for pluginID: String) async throws -> any SourceRunnerContext {
        runnerRequestCount += 1
        if suspendedRunnerPluginIDs.contains(pluginID) {
            return try await withCheckedThrowingContinuation { continuation in
                runnerContinuations[pluginID] = continuation
            }
        }
        if let runnerError { throw runnerError }
        guard installedPlugins[pluginID] != nil else { throw URLError(.badURL) }
        if let runner = runners[pluginID] {
            return ItoRunnerSourceContext(runner: runner)
        }
        let runner = ItoRunner()
        runners[pluginID] = runner
        return ItoRunnerSourceContext(runner: runner)
    }

    func evictSourceRunner(for pluginID: String) {
        runners[pluginID] = nil
    }

    func resumeRunnerRequest(for pluginID: String) {
        guard let continuation = runnerContinuations.removeValue(forKey: pluginID) else {
            return
        }
        let runner = runners[pluginID] ?? ItoRunner()
        runners[pluginID] = runner
        continuation.resume(returning: ItoRunnerSourceContext(runner: runner))
    }

    func sourceSearchAdapter(
        for pluginID: String,
        mediaType: PluginMediaType
    ) async throws -> any PluginSearching {
        guard let plugin = installedPlugins[pluginID] else { throw URLError(.badURL) }
        if let adapter = configuredAdapters[pluginID] { return adapter }
        return FakePluginSearchAdapter(
            pluginID: pluginID,
            pluginVersion: plugin.info.version,
            mediaType: mediaType
        )
    }
}

actor FakePluginSearchAdapter: PluginSearching {
    let pluginID: String
    let pluginVersion: String?
    let mediaType: PluginMediaType

    var resultsToReturn: [ResolvedPluginMedia] = []
    var errorToThrow: Error?

    init(pluginID: String, pluginVersion: String?, mediaType: PluginMediaType) {
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.mediaType = mediaType
    }

    func search(query: String) async throws -> [ResolvedPluginMedia] {
        if let err = errorToThrow { throw err }
        return resultsToReturn
    }

    func setResults(_ results: [ResolvedPluginMedia]) {
        self.resultsToReturn = results
    }

    func setError(_ error: Error) {
        self.errorToThrow = error
    }
}

@MainActor
final class SourceResolverViewModelTests: XCTestCase {
    var dbQueue: DatabaseQueue!
    var repository: GRDBSourceMappingRepository!
    var pluginProvider: FakePluginProvider!

    override func setUp() async throws {
        dbQueue = try DatabaseQueue()
        try AppDatabase.makeMigrator().migrate(dbQueue)
        repository = GRDBSourceMappingRepository(dbWriter: dbQueue)
        pluginProvider = FakePluginProvider()
    }

    func testValidSavedMappingPublishesSavedSourceState() async throws {
        let record = makeMappingRecord()
        let payload = ResolvedPluginMedia.manga(makeCompleteManga())
        pluginProvider.installedPlugins["p1"] = makePlugin()
        try await repository.upsert(makeMappingRecord(payload: payload))
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )

        await vm.checkAndResolve()

        guard case .savedSource(let savedMapping, let savedPayload) = vm.state else {
            return XCTFail("Expected saved source state")
        }
        XCTAssertEqual(savedMapping.pluginId, record.pluginId)
        XCTAssertEqual(savedPayload.key(), payload.key())
    }

    func testValidSavedMappingDoesNotPrepareRoute() async throws {
        pluginProvider.installedPlugins["p1"] = makePlugin()
        try await repository.upsert(makeMappingRecord())
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )

        await vm.checkAndResolve()

        XCTAssertNil(vm.sourceRoute)
        XCTAssertEqual(vm.routePresentation.presentationCount, 0)
        XCTAssertEqual(pluginProvider.runnerRequestCount, 0)
    }

    func testValidSavedMappingLeavesNavigationInactive() async throws {
        pluginProvider.installedPlugins["p1"] = makePlugin()
        try await repository.upsert(makeMappingRecord())
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )

        await vm.checkAndResolve()

        XCTAssertFalse(vm.isSourceDestinationPresented)
        XCTAssertEqual(vm.routePresentation.phase, .idle)
    }

    func testOpeningSavedDetailRemainsOnDiscoverDetails() async throws {
        pluginProvider.installedPlugins["p1"] = makePlugin()
        try await repository.upsert(makeMappingRecord())
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        let savedSourcePublished = expectation(description: "Saved source published")
        var didFulfill = false
        let subscription = vm.$state.sink { state in
            guard !didFulfill, case .savedSource = state else { return }
            didFulfill = true
            savedSourcePublished.fulfill()
        }

        vm.startCheckAndResolve()
        await fulfillment(of: [savedSourcePublished], timeout: 2)

        XCTAssertFalse(vm.isSourceDestinationPresented)
        XCTAssertNil(vm.sourceRoute)
        subscription.cancel()
    }

    func testSavedSourceOpenExplicitlyPreparesOneRoute() async throws {
        let payload = ResolvedPluginMedia.manga(makeCompleteManga())
        let mapping = makeMappingRecord(payload: payload)
        pluginProvider.installedPlugins["p1"] = makePlugin()
        try await repository.upsert(mapping)
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        await vm.checkAndResolve()

        await openSavedSourceAndWait(vm, mapping: mapping, payload: payload)

        XCTAssertEqual(vm.routePresentation.presentationCount, 1)
        XCTAssertEqual(vm.sourceRoute?.pluginID, mapping.pluginId)
        XCTAssertEqual(pluginProvider.runnerRequestCount, 1)
    }

    func testRepeatedSavedSourceOpenTapsRouteOnce() async throws {
        let payload = ResolvedPluginMedia.manga(makeCompleteManga())
        let mapping = makeMappingRecord(payload: payload)
        pluginProvider.installedPlugins["p1"] = makePlugin()
        try await repository.upsert(mapping)
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        await vm.checkAndResolve()
        let routePresented = expectation(description: "Route presented")
        var didFulfill = false
        let subscription = vm.$routePresentation.sink { presentation in
            guard !didFulfill, presentation.presentationCount == 1 else { return }
            didFulfill = true
            routePresented.fulfill()
        }

        vm.openSavedSource(mapping: mapping, payload: payload)
        vm.openSavedSource(mapping: mapping, payload: payload)
        await fulfillment(of: [routePresented], timeout: 2)

        XCTAssertEqual(vm.routePresentation.presentationCount, 1)
        XCTAssertEqual(pluginProvider.runnerRequestCount, 1)
        subscription.cancel()
    }

    func testSavedSourceStateRetainsCompleteMangaPayload() async throws {
        let manga = makeCompleteManga()
        pluginProvider.installedPlugins["p1"] = makePlugin()
        try await repository.upsert(makeMappingRecord(payload: .manga(manga)))
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )

        await vm.checkAndResolve()

        guard case .savedSource(_, .manga(let savedManga)) = vm.state else {
            return XCTFail("Expected saved Manga")
        }
        XCTAssertEqual(savedManga.description, manga.description)
        XCTAssertEqual(savedManga.tags, manga.tags)
        XCTAssertEqual(savedManga.authors, manga.authors)
        XCTAssertEqual(savedManga.chapters?.first?.url, manga.chapters?.first?.url)
        XCTAssertEqual(savedManga.chapters?.first?.paywalled, true)
    }

    func testSavedSourceStateRetainsCompleteAnimePayload() async throws {
        let anime = makeCompleteAnime()
        pluginProvider.installedPlugins["p1"] = makePlugin(type: .anime)
        try await repository.upsert(
            makeMappingRecord(mediaType: .anime, payload: .anime(anime))
        )
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(type: "ANIME"),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )

        await vm.checkAndResolve()

        guard case .savedSource(_, .anime(let savedAnime)) = vm.state else {
            return XCTFail("Expected saved Anime")
        }
        XCTAssertEqual(savedAnime.studios, anime.studios)
        XCTAssertEqual(savedAnime.episodes?.first?.paywalled, anime.episodes?.first?.paywalled)
        XCTAssertEqual(savedAnime.seasons?.first?.key, anime.seasons?.first?.key)
    }

    func testChangeSourcePreservesConfirmedMapping() async throws {
        let mapping = makeMappingRecord()
        pluginProvider.installedPlugins["p1"] = makePlugin()
        try await repository.upsert(mapping)
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        await vm.checkAndResolve()

        await resolveAndWait(vm)

        let records = try await repository.fetchAll(
            canonicalProvider: "anilist",
            canonicalMediaId: "1",
            mediaType: .manga
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.pluginId, mapping.pluginId)
        XCTAssertEqual(records.first?.decision, .autoConfirm)
    }

    func testSearchingAlternativesDoesNotRoute() async throws {
        pluginProvider.installedPlugins["p1"] = makePlugin()
        try await repository.upsert(makeMappingRecord())
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        await vm.checkAndResolve()

        await resolveAndWait(vm)

        XCTAssertFalse(vm.isSourceDestinationPresented)
        XCTAssertNil(vm.sourceRoute)
        XCTAssertEqual(vm.routePresentation.presentationCount, 0)
    }

    func testNewConfirmationPersistsAndRoutesOnce() async throws {
        pluginProvider.installedPlugins["p1"] = makePlugin()
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        let match = makeMangaMatch()

        try await vm.confirmAndPrepareRoute(match)

        let records = try await repository.fetchAll(
            canonicalProvider: "anilist",
            canonicalMediaId: "1",
            mediaType: .manga
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.pluginId, match.pluginID)
        XCTAssertEqual(records.first?.pluginMediaKey, match.media.key())
        XCTAssertEqual(vm.routePresentation.presentationCount, 1)
        XCTAssertTrue(vm.isSourceDestinationPresented)
    }

    func testReturningFromPluginDestinationRemainsOnDiscoverDetails() async throws {
        pluginProvider.installedPlugins["p1"] = makePlugin()
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        let match = makeMangaMatch()
        try await vm.confirmAndPrepareRoute(match)
        vm.destinationDidAppear()

        vm.manualDestinationPopRequested()
        vm.destinationDidDisappear()

        guard case .savedSource(let mapping, let payload) = vm.state else {
            return XCTFail("Expected saved source state after manual pop")
        }
        XCTAssertEqual(mapping.pluginId, match.pluginID)
        XCTAssertEqual(payload.key(), match.media.key())
        XCTAssertFalse(vm.isSourceDestinationPresented)
        XCTAssertNil(vm.sourceRoute)
    }

    func testReturningDoesNotAutomaticallyReopenSavedSource() async throws {
        let payload = ResolvedPluginMedia.manga(makeCompleteManga())
        let mapping = makeMappingRecord(payload: payload)
        pluginProvider.installedPlugins["p1"] = makePlugin()
        try await repository.upsert(mapping)
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        await vm.checkAndResolve()
        await openSavedSourceAndWait(vm, mapping: mapping, payload: payload)
        vm.destinationDidAppear()

        vm.manualDestinationPopRequested()
        vm.destinationDidDisappear()
        vm.startCheckAndResolve()

        XCTAssertFalse(vm.isSourceDestinationPresented)
        XCTAssertNil(vm.sourceRoute)
        XCTAssertEqual(vm.routePresentation.presentationCount, 1)
    }

    func testSavedSourceCanBeOpenedAgainAfterExplicitReturn() async throws {
        let payload = ResolvedPluginMedia.manga(makeCompleteManga())
        let mapping = makeMappingRecord(payload: payload)
        pluginProvider.installedPlugins["p1"] = makePlugin()
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        vm.setSavedSourceState(mapping: mapping, payload: payload)
        await openSavedSourceAndWait(vm, mapping: mapping, payload: payload)
        vm.destinationDidAppear()
        vm.manualDestinationPopRequested()
        vm.destinationDidDisappear()

        let reopened = expectation(description: "Source route reopened")
        let subscription = vm.$routePresentation.sink { presentation in
            if presentation.presentationCount == 2 { reopened.fulfill() }
        }
        vm.openSavedSource(mapping: mapping, payload: payload)
        await fulfillment(of: [reopened], timeout: 2)

        XCTAssertEqual(vm.routePresentation.presentationCount, 2)
        XCTAssertTrue(vm.isSourceDestinationPresented)
        XCTAssertEqual(vm.sourceRoute?.media.key(), payload.key())
        subscription.cancel()
    }

    func testReopeningSavedDetailDoesNotAutomaticallyOpen() async throws {
        pluginProvider.installedPlugins["p1"] = makePlugin()
        try await repository.upsert(makeMappingRecord())
        let first = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        await first.checkAndResolve()

        let reopened = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        await reopened.checkAndResolve()

        guard case .savedSource = reopened.state else {
            return XCTFail("Expected reopened saved source state")
        }
        XCTAssertFalse(first.isSourceDestinationPresented)
        XCTAssertFalse(reopened.isSourceDestinationPresented)
        XCTAssertNil(reopened.sourceRoute)
        XCTAssertEqual(reopened.routePresentation.presentationCount, 0)
    }

    func testSavedSourceLookupPerformsNoLibraryMutation() async throws {
        let initialCount = try libraryItemCount()
        pluginProvider.installedPlugins["p1"] = makePlugin()
        try await repository.upsert(makeMappingRecord())
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )

        await vm.checkAndResolve()

        XCTAssertEqual(try libraryItemCount(), initialCount)
        XCTAssertFalse(vm.isSourceDestinationPresented)
    }

    func testExplicitSavedSourceOpenPerformsNoLibraryMutation() async throws {
        let initialCount = try libraryItemCount()
        let payload = ResolvedPluginMedia.manga(makeCompleteManga())
        let mapping = makeMappingRecord(payload: payload)
        pluginProvider.installedPlugins["p1"] = makePlugin()
        try await repository.upsert(mapping)
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        await vm.checkAndResolve()

        await openSavedSourceAndWait(vm, mapping: mapping, payload: payload)

        XCTAssertEqual(try libraryItemCount(), initialCount)
        XCTAssertTrue(vm.isSourceDestinationPresented)
    }

    func testConfirmationPerformsNoLibraryMutation() async throws {
        let initialCount = try libraryItemCount()
        pluginProvider.installedPlugins["p1"] = makePlugin()
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )

        try await vm.confirmAndPrepareRoute(makeMangaMatch())

        XCTAssertEqual(try libraryItemCount(), initialCount)
        XCTAssertTrue(vm.isSourceDestinationPresented)
    }

    func testParentNavigationDisappearanceDoesNotClearRoute() {
        var presentation = SourceRoutePresentationState()
        presentation.present(makeRoute(media: .manga(makeCompleteManga())))
        presentation.destinationDidAppear()

        presentation.destinationDidDisappear()

        XCTAssertTrue(presentation.isPresented)
        XCTAssertNotNil(presentation.route)
        XCTAssertEqual(presentation.phase, .presented)
    }

    func testTransientFalseBindingUpdateDoesNotClearActiveRoute() {
        var presentation = SourceRoutePresentationState()
        presentation.present(makeRoute(media: .manga(makeCompleteManga())))
        presentation.destinationDidAppear()

        presentation.navigationBindingDidSet(false)

        XCTAssertTrue(presentation.isPresented)
        XCTAssertNotNil(presentation.route)
        XCTAssertEqual(presentation.phase, .presented)
    }

    func testManualDestinationPopClearsPresentationAfterDisappearance() {
        var presentation = SourceRoutePresentationState()
        presentation.present(makeRoute(media: .manga(makeCompleteManga())))
        presentation.destinationDidAppear()

        presentation.manualDestinationPopRequested()

        XCTAssertFalse(presentation.isPresented)
        XCTAssertNotNil(presentation.route)
        XCTAssertEqual(presentation.phase, .dismissing)

        presentation.destinationDidDisappear()

        XCTAssertNil(presentation.route)
        XCTAssertEqual(presentation.phase, .dismissedByUser)
    }

    // 1. valid confirmed mapping routes without resolver execution
    func testValidConfirmedMappingRoutesWithoutResolverExecution() async throws {
        let media = makeDiscoverMedia()
        pluginProvider.installedPlugins["p1"] = makePlugin()
        try await repository.upsert(makeMappingRecord(version: 1))

        let vm = SourceResolverViewModel(media: media, repository: repository, pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory())
        let result = await vm.checkExistingMapping()
        XCTAssertNotNil(result)
    }

    // 2. unsupported database snapshot version starts fresh resolution
    func testUnsupportedDatabaseSnapshotVersion() async throws {
        let media = makeDiscoverMedia()
        pluginProvider.installedPlugins["p1"] = makePlugin()
        let record = makeMappingRecord(version: 1, payloadVersionOverride: 2)
        try await repository.upsert(record)

        let vm = SourceResolverViewModel(media: media, repository: repository, pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory())
        let res = await vm.checkExistingMapping()
        XCTAssertNil(res)
    }

    // 3. unsupported decoded envelope version starts fresh resolution
    func testUnsupportedDecodedEnvelopeVersion() async throws {
        let media = makeDiscoverMedia()
        pluginProvider.installedPlugins["p1"] = makePlugin()
        let snapshot = SourceMediaSnapshot(version: 2, payload: .manga(Manga(key: "m1", title: "Test"))) // Envelope 2
        let record = makeMappingRecord(version: 1, payloadOverride: try JSONEncoder().encode(snapshot))
        try await repository.upsert(record)

        let vm = SourceResolverViewModel(media: media, repository: repository, pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory())
        let res = await vm.checkExistingMapping()
        XCTAssertNil(res)
    }

    // 4. decode failure starts fresh resolution
    func testDecodeFailureStartsFreshResolution() async throws {
        let media = makeDiscoverMedia()
        pluginProvider.installedPlugins["p1"] = makePlugin()
        let record = makeMappingRecord(version: 1, payloadOverride: Data("invalid".utf8))
        try await repository.upsert(record)

        let vm = SourceResolverViewModel(media: media, repository: repository, pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory())
        let res = await vm.checkExistingMapping()
        XCTAssertNil(res)
    }

    // 5. missing plugin starts fresh resolution
    func testMissingPluginStartsFreshResolution() async throws {
        let media = makeDiscoverMedia()
        try await repository.upsert(makeMappingRecord(version: 1))

        let vm = SourceResolverViewModel(media: media, repository: repository, pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory())
        let res = await vm.checkExistingMapping()
        XCTAssertNil(res)
    }

    // 6. incompatible plugin version starts fresh resolution
    func testIncompatiblePluginVersionStartsFreshResolution() async throws {
        let media = makeDiscoverMedia()
        let plugin = makePlugin(version: "2.0") // current is 2.0
        pluginProvider.installedPlugins["p1"] = plugin
        let record = makeMappingRecord(version: 1, pluginVersionOverride: "1.0")
        try await repository.upsert(record)

        let vm = SourceResolverViewModel(media: media, repository: repository, pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory())
        let res = await vm.checkExistingMapping()
        XCTAssertNil(res)
    }

    // 7. media-type mismatch never routes
    func testMediaTypeMismatchNeverRoutes() async throws {
        let media = makeDiscoverMedia(type: "ANIME") // Requesting Anime
        pluginProvider.installedPlugins["p1"] = makePlugin(type: .anime)

        let record = makeMappingRecord(mediaType: .manga, payload: .manga(Manga(key: "m1", title: "M")))
        try await repository.upsert(record)

        let vm = SourceResolverViewModel(media: media, repository: repository, pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory())
        let res = await vm.checkExistingMapping()
        XCTAssertNil(res)
    }

    // 8. stale record remains persisted
    func testStaleRecordRemainsPersisted() async throws {
        let media = makeDiscoverMedia()
        pluginProvider.installedPlugins["p1"] = makePlugin(version: "2.0")
        let record = makeMappingRecord(version: 1)
        try await repository.upsert(record)

        let vm = SourceResolverViewModel(media: media, repository: repository, pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory())
        _ = await vm.checkExistingMapping() // Should return nil

        let all = try await repository.fetchAll(canonicalProvider: "anilist", canonicalMediaId: "1", mediaType: .manga)
        XCTAssertEqual(all.count, 1) // Remains persisted
    }

    // 9. valid stored route updates verification timestamp
    func testValidStoredRouteUpdatesVerificationTimestamp() async throws {
        let record = makeMappingRecord(version: 1)
        try await repository.upsert(record)
        let vm = SourceResolverViewModel(media: makeDiscoverMedia(), repository: repository, pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory())

        await vm.markMappingUsed(record)
        for _ in 0..<100 {
            let all = try await repository.fetchAll(canonicalProvider: "anilist", canonicalMediaId: "1", mediaType: .manga)
            if all[0].lastVerifiedAt != record.lastVerifiedAt { break }
            await Task.yield()
        }

        let all = try await repository.fetchAll(canonicalProvider: "anilist", canonicalMediaId: "1", mediaType: .manga)
        XCTAssertNotEqual(all[0].lastVerifiedAt, record.lastVerifiedAt)
    }

    // 10, 11, 12. accumulated yields, callback awaited, removes searching state
    func testResolutionStateTransitions() async throws {
        let media = makeDiscoverMedia()
        pluginProvider.installedPlugins["p1"] = makePlugin()
        let vm = SourceResolverViewModel(media: media, repository: repository, pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory())
        let adapter = FakePluginSearchAdapter(pluginID: "p1", pluginVersion: "1.0", mediaType: .manga)
        await adapter.setResults([.manga(Manga(key: "m1", title: "Test"))])
        pluginProvider.configuredAdapters["p1"] = adapter

        let exp = expectation(description: "Complete")
        var states: [SourceResolverViewModel.State] = []
        let sub = vm.$state.sink { state in
            states.append(state)
            if case .completed = state { exp.fulfill() }
        }

        vm.resolve()
        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertTrue(states.contains(where: { if case .loading = $0 { return true }; return false }))
        XCTAssertTrue(states.contains(where: {
            if case .loading(let matches) = $0 { return !matches.isEmpty }
            return false
        }))
        XCTAssertTrue(states.contains(where: { if case .completed = $0 { return true }; return false }))
        XCTAssertFalse(vm.isSearching) // 12
        sub.cancel()
    }

    // 13. partial plugin failures preserve successful candidates
    func testPartialPluginFailures() async throws {
        let media = makeDiscoverMedia()
        pluginProvider.installedPlugins["p1"] = makePlugin(id: "p1")
        pluginProvider.installedPlugins["p2"] = makePlugin(id: "p2")
        let vm = SourceResolverViewModel(media: media, repository: repository, pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory())

        let adapter1 = FakePluginSearchAdapter(pluginID: "p1", pluginVersion: "1.0", mediaType: .manga)
        await adapter1.setResults([.manga(Manga(key: "m1", title: "Test"))])

        let adapter2 = FakePluginSearchAdapter(pluginID: "p2", pluginVersion: "1.0", mediaType: .manga)
        await adapter2.setError(URLError(.badServerResponse))

        pluginProvider.configuredAdapters["p1"] = adapter1
        pluginProvider.configuredAdapters["p2"] = adapter2

        let exp = expectation(description: "Complete")
        let sub = vm.$state.sink { state in
            if case .partialFailure(let matches, let failed) = state {
                XCTAssertEqual(matches.count, 1)
                XCTAssertEqual(failed, ["p2"])
                exp.fulfill()
            }
        }

        vm.resolve()
        await fulfillment(of: [exp], timeout: 2.0)
        sub.cancel()
    }

    // 14. no compatible plugins has its own empty state
    func testNoCompatiblePlugins() async throws {
        let media = makeDiscoverMedia()
        let vm = SourceResolverViewModel(media: media, repository: repository, pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory())

        let exp = expectation(description: "Empty")
        let sub = vm.$state.sink { state in
            if case .noCompatiblePlugins = state { exp.fulfill() }
        }
        vm.resolve()
        await fulfillment(of: [exp], timeout: 2.0)
        sub.cancel()
    }

    // 15. compatible plugins with no candidates has the no-results state
    func testCompatiblePluginsWithNoCandidates() async throws {
        let media = makeDiscoverMedia()
        pluginProvider.installedPlugins["p1"] = makePlugin()
        let vm = SourceResolverViewModel(media: media, repository: repository, pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory())
        let adapter = FakePluginSearchAdapter(pluginID: "p1", pluginVersion: "1.0", mediaType: .manga)
        pluginProvider.configuredAdapters["p1"] = adapter

        let exp = expectation(description: "Complete")
        let sub = vm.$state.sink { state in
            if case .empty = state { exp.fulfill() }
        }

        vm.resolve()
        await fulfillment(of: [exp], timeout: 2.0)
        sub.cancel()
    }

    // 16, 17, 18, 19, 20, 21. confirmation, rejection
    func testConfirmationAndRejection() async throws {
        let media = makeDiscoverMedia()
        let vm = SourceResolverViewModel(media: media, repository: repository, pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory())
        let match = MatchedSource(pluginID: "p1", pluginVersion: "1.0", media: .manga(Manga(key: "m1", title: "Test")), matchMethod: .exactPreferred, score: 1.0, decision: .autoConfirm)

        try await vm.rejectMatch(match)
        let all = try await repository.fetchAll(canonicalProvider: "anilist", canonicalMediaId: "1", mediaType: .manga)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].decision, .discard)
        XCTAssertNil(all[0].encodedPayload) // Payload free

        pluginProvider.installedPlugins["p1"] = makePlugin()
        let adapter = FakePluginSearchAdapter(pluginID: "p1", pluginVersion: "1.0", mediaType: .manga)
        pluginProvider.configuredAdapters["p1"] = adapter
        await adapter.setResults([.manga(Manga(key: "m1", title: "Test"))])

        let exp = expectation(description: "Complete")
        var fulfilled = false
        let sub = vm.$state.sink { state in
            if !fulfilled {
                if case .empty = state {
                    fulfilled = true
                    exp.fulfill()
                } else if case .completed = state {
                    fulfilled = true
                    exp.fulfill()
                }
            }
        }
        vm.resolve()
        await fulfillment(of: [exp], timeout: 2.0)
        sub.cancel()

        try await vm.confirmMatch(match)
        let all2 = try await repository.fetchAll(canonicalProvider: "anilist", canonicalMediaId: "1", mediaType: .manga)
        XCTAssertEqual(all2.count, 1) // repeated confirmation does not duplicate
        XCTAssertEqual(all2[0].decision, .autoConfirm)
        XCTAssertNotNil(all2[0].encodedPayload)
    }

    // 25. cancellation prevents avoidable UI work
    func testCancellation() async throws {
        let media = makeDiscoverMedia()
        pluginProvider.installedPlugins["p1"] = makePlugin()
        let vm = SourceResolverViewModel(media: media, repository: repository, pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory())
        let adapter = FakePluginSearchAdapter(pluginID: "p1", pluginVersion: "1.0", mediaType: .manga)
        pluginProvider.configuredAdapters["p1"] = adapter

        vm.resolve()
        vm.cancel()

        XCTAssertFalse(vm.isSearching)
        if case .cancelled = vm.state { } else { XCTFail("Expected .cancelled") }
    }

    // Library saving
    func testLibrarySaving() async throws {
        let testDatabase = try TestDatabase()
        defer { testDatabase.cleanup() }
        let libraryManager = LibraryManager(dbPool: testDatabase.dbPool)
        let mangaID = try await libraryManager.saveMangaDurably(
            manga: Manga(key: "m1", title: "T"),
            pluginId: "p1"
        )
        XCTAssertEqual(mangaID, "m1")
        XCTAssertTrue(libraryManager.items.contains(where: { $0.id == "m1" }))

        let animeID = try await libraryManager.saveAnimeDurably(
            anime: Anime(key: "a1", title: "A"),
            pluginId: "p1"
        )
        XCTAssertEqual(animeID, "a1")
        XCTAssertTrue(libraryManager.items.contains(where: { $0.id == "a1" }))
    }
    // Helpers
    func makeDiscoverMedia(type: String = "MANGA") -> DiscoverMedia {
        DiscoverMedia(id: 1, title: "Test", titleEnglish: nil, titleRomaji: nil, titleNative: nil, synonyms: [], coverImage: nil, bannerImage: nil, format: nil, status: nil, description: nil, cleanDescription: nil, genres: nil, averageScore: nil, episodes: nil, chapters: nil, season: nil, seasonYear: nil, type: type, recommendations: nil)
    }

    func makePlugin(id: String = "p1", version: String = "1.0", type: MediaKind = .manga) -> InstalledPlugin {
        InstalledPlugin(url: URL(fileURLWithPath: "/"), info: PluginInfo(id: id, name: id, version: version, minAppVersion: "1.0", type: type), iconData: nil)
    }

    func openSavedSourceAndWait(
        _ viewModel: SourceResolverViewModel,
        mapping: SourceMappingRecord,
        payload: ResolvedPluginMedia
    ) async {
        let routePresented = expectation(description: "Route presented")
        var didFulfill = false
        let subscription = viewModel.$routePresentation.sink { presentation in
            guard !didFulfill, presentation.presentationCount == 1 else { return }
            didFulfill = true
            routePresented.fulfill()
        }

        viewModel.openSavedSource(mapping: mapping, payload: payload)
        await fulfillment(of: [routePresented], timeout: 2)
        subscription.cancel()
    }

    func resolveAndWait(_ viewModel: SourceResolverViewModel) async {
        let resolutionCompleted = expectation(description: "Resolution completed")
        var didFulfill = false
        let subscription = viewModel.$state.sink { state in
            guard !didFulfill else { return }
            switch state {
            case .completed, .partialFailure, .empty:
                didFulfill = true
                resolutionCompleted.fulfill()
            default:
                break
            }
        }

        viewModel.resolve()
        await fulfillment(of: [resolutionCompleted], timeout: 2)
        subscription.cancel()
    }

    func makeMappingRecord(mediaType: PluginMediaType = .manga, version: Int = 1, payload: ResolvedPluginMedia = .manga(Manga(key: "m1", title: "Test")), payloadVersionOverride: Int? = nil, payloadOverride: Data? = nil, pluginVersionOverride: String? = nil) -> SourceMappingRecord {
        let snapshot = SourceMediaSnapshot(version: version, payload: payload)
        let data = (try? JSONEncoder().encode(snapshot)) ?? Data()
        return SourceMappingRecord(canonicalProvider: "anilist", canonicalMediaId: "1", mediaType: mediaType, pluginId: "p1", pluginMediaKey: "m1", decision: .autoConfirm, matchMethod: .exactPreferred, confidence: 1.0, titleSnapshot: "Test", createdAt: Date(), updatedAt: Date(), coverURLSnapshot: nil, encodedPayload: payloadOverride ?? data, payloadVersion: payloadVersionOverride ?? 1, pluginVersion: pluginVersionOverride ?? "1.0", lastVerifiedAt: Date())
    }

    func makeMappingRecordForPlugin(
        pluginID: String,
        mediaKey: String,
        payload: ResolvedPluginMedia
    ) -> SourceMappingRecord {
        let snapshot = SourceMediaSnapshot(version: 1, payload: payload)
        return SourceMappingRecord(
            canonicalProvider: "anilist",
            canonicalMediaId: "1",
            mediaType: .manga,
            pluginId: pluginID,
            pluginMediaKey: mediaKey,
            decision: .autoConfirm,
            matchMethod: .exactPreferred,
            confidence: 1,
            titleSnapshot: mediaKey,
            createdAt: Date(),
            updatedAt: Date(),
            encodedPayload: try? JSONEncoder().encode(snapshot),
            payloadVersion: 1,
            pluginVersion: "1.0"
        )
    }

    func makeRoute(media: ResolvedPluginMedia) -> SourceRoute {
        SourceRoute(media: media, pluginID: "p1", runner: ItoRunner(), anilistID: 1)
    }

    func makeMangaMatch() -> MatchedSource {
        MatchedSource(
            pluginID: "p1",
            pluginVersion: "1.0",
            media: .manga(makeCompleteManga()),
            matchMethod: .exactPreferred,
            score: 1,
            decision: .autoConfirm
        )
    }

    func makeCompleteManga() -> Manga {
        Manga(
            key: "m1",
            title: "Complete Manga",
            authors: ["Author"],
            artist: "Artist",
            description: "Full description",
            tags: ["Drama"],
            cover: "https://example.com/manga.jpg",
            url: "https://example.com/manga",
            status: .Ongoing,
            chapters: [
                Manga.Chapter(
                    key: "c1",
                    title: "Chapter 1",
                    chapter: 1,
                    url: "https://example.com/chapter/1",
                    lang: "en",
                    paywalled: true
                )
            ]
        )
    }

    func makeCompleteAnime() -> Anime {
        Anime(
            key: "a1",
            title: "Complete Anime",
            studios: ["Studio"],
            description: "Full anime description",
            tags: ["Action"],
            cover: "https://example.com/anime.jpg",
            url: "https://example.com/anime",
            status: .Completed,
            episodes: [
                Anime.Episode(
                    key: "e1",
                    title: "Episode 1",
                    episode: 1,
                    url: "https://example.com/episode/1",
                    lang: "ja",
                    paywalled: false
                )
            ],
            seasons: [Anime.Season(key: "s1", title: "Season 1", isCurrent: true)]
        )
    }

    func libraryItemCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM libraryItem") ?? 0
        }
    }

    func sourceFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let didSatisfyCondition = await condition()
        XCTAssertTrue(didSatisfyCondition)
    }
}
