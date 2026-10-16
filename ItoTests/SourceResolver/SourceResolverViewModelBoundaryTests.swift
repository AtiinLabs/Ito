import Combine
import Foundation
import XCTest
@testable import Ito
import ito_runner

@MainActor
extension SourceResolverViewModelTests {
    func testNoConfirmedMappingAutomaticallyStartsResolution() async {
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )

        vm.startCheckAndResolve()
        await waitUntil {
            if case .noCompatiblePlugins = vm.state { return true }
            return false
        }

        XCTAssertFalse(vm.isSearching)
    }

    func testFatalRepositoryFailurePublishesSanitizedFailure() async {
        let failingRepository = SourceResolverRepositorySpy()
        await failingRepository.setFetchAllFailure(true)
        pluginProvider.installedPlugins["p1"] = makePlugin()
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: failingRepository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )

        vm.resolve()
        await waitUntil {
            if case .fatalFailure = vm.state { return true }
            return false
        }

        guard case .fatalFailure(let message) = vm.state else {
            return XCTFail("Expected fatal failure")
        }
        XCTAssertEqual(message, "Unable to search sources. Please try again.")
    }

    func testConfirmPersistenceFailureNeverPublishesSavedStateOrRoute() async {
        let failingRepository = SourceResolverRepositorySpy()
        await failingRepository.setUpsertFailure(true)
        pluginProvider.installedPlugins["p1"] = makePlugin()
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: failingRepository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )

        vm.confirmAndRoute(match: makeMangaMatch())
        await waitUntil { vm.processingMatchIdentity == nil }

        if case .savedSource = vm.state {
            XCTFail("Failed persistence must not publish saved source")
        }
        XCTAssertNil(vm.sourceRoute)
        XCTAssertEqual(vm.routePresentation.presentationCount, 0)
        XCTAssertEqual(vm.pluginSearchError, "The source could not be saved. Please try again.")
    }

    func testRouteFailureAfterConfirmPreservesDurableSavedMappingForRetry() async throws {
        pluginProvider.installedPlugins["p1"] = makePlugin()
        pluginProvider.runnerError = URLError(.cannotOpenFile)
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        let match = makeMangaMatch()

        vm.confirmAndRoute(match: match)
        await waitUntil { vm.processingMatchIdentity == nil }

        guard case .savedSource(let mapping, let payload) = vm.state else {
            return XCTFail("Durable confirmation should remain saved")
        }
        XCTAssertNil(vm.sourceRoute)
        XCTAssertEqual(
            vm.pluginSearchError,
            "The source was saved, but could not be opened. Try Open again."
        )
        let records = try await repository.fetchAll(
            canonicalProvider: "anilist",
            canonicalMediaId: "1",
            mediaType: .manga
        )
        XCTAssertEqual(records.count, 1)

        pluginProvider.runnerError = nil
        vm.openSavedSource(mapping: mapping, payload: payload)
        await waitUntil { vm.routePresentation.presentationCount == 1 }
        XCTAssertNotNil(vm.sourceRoute)
    }

    func testSavedSourceOpenFailureDoesNotCorruptSavedState() async {
        pluginProvider.installedPlugins["p1"] = makePlugin()
        pluginProvider.runnerError = URLError(.cannotOpenFile)
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        let mapping = makeMappingRecord()
        let payload = ResolvedPluginMedia.manga(makeCompleteManga())
        vm.setSavedSourceState(mapping: mapping, payload: payload)

        vm.openSavedSource(mapping: mapping, payload: payload)
        await waitUntil { vm.processingMatchIdentity == nil }

        guard case .savedSource(let savedMapping, let savedPayload) = vm.state else {
            return XCTFail("Expected saved source to remain")
        }
        XCTAssertEqual(savedMapping.pluginMediaKey, mapping.pluginMediaKey)
        XCTAssertEqual(savedPayload.key(), payload.key())
        XCTAssertNil(vm.sourceRoute)
        XCTAssertEqual(
            vm.pluginSearchError,
            "The saved source could not be opened. Please try again."
        )
    }

    func testRejectionFailureLeavesExactMatchVisibleAndRetryable() async {
        let failingRepository = SourceResolverRepositorySpy()
        await failingRepository.setRejectionFailure(true)
        pluginProvider.installedPlugins["p1"] = makePlugin()
        let adapter = FakePluginSearchAdapter(
            pluginID: "p1",
            pluginVersion: "1.0",
            mediaType: .manga
        )
        await adapter.setResults([.manga(Manga(key: "m1", title: "Test"))])
        pluginProvider.configuredAdapters["p1"] = adapter
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: failingRepository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        vm.resolve()
        await waitUntil {
            if case .completed = vm.state { return true }
            return false
        }
        guard case .completed(let matches) = vm.state,
              let match = matches.first else {
            return XCTFail("Expected resolved match")
        }

        vm.rejectAndMark(match: match)
        await waitUntil { vm.processingMatchIdentity == nil }

        guard case .completed(let remainingMatches) = vm.state else {
            return XCTFail("Expected completed state")
        }
        XCTAssertEqual(remainingMatches.first?.sourceIdentity, match.sourceIdentity)
        XCTAssertNotEqual(remainingMatches.first?.decision, .discard)
        XCTAssertEqual(
            vm.pluginSearchError,
            "The source rejection could not be saved. Please try again."
        )
    }

    func testProcessingIdentityIncludesPluginVersionTypeAndMediaKey() async {
        pluginProvider.installedPlugins["p1"] = makePlugin(id: "p1")
        pluginProvider.installedPlugins["p2"] = makePlugin(id: "p2")
        pluginProvider.suspendedRunnerPluginIDs.insert("p1")
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        let first = makeMangaMatch()
        let second = MatchedSource(
            pluginID: "p2",
            pluginVersion: "2.0",
            media: first.media,
            matchMethod: first.matchMethod,
            score: first.score,
            decision: first.decision
        )

        vm.confirmAndRoute(match: first)
        await waitUntil { self.pluginProvider.runnerRequestCount == 1 }

        XCTAssertTrue(vm.isProcessing(first))
        XCTAssertFalse(vm.isProcessing(second))
        XCTAssertNotEqual(first.sourceIdentity, second.sourceIdentity)
        pluginProvider.resumeRunnerRequest(for: "p1")
        await waitUntil { vm.processingMatchIdentity == nil }
    }

    func testRapidDuplicateConfirmationIsSuppressed() async {
        pluginProvider.installedPlugins["p1"] = makePlugin()
        pluginProvider.suspendedRunnerPluginIDs.insert("p1")
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        let match = makeMangaMatch()

        vm.confirmAndRoute(match: match)
        vm.confirmAndRoute(match: match)
        await waitUntil { self.pluginProvider.runnerRequestCount == 1 }
        let records = try? await repository.fetchAll(
            canonicalProvider: "anilist",
            canonicalMediaId: "1",
            mediaType: .manga
        )

        XCTAssertEqual(records?.count, 1)
        pluginProvider.resumeRunnerRequest(for: "p1")
        await waitUntil { vm.processingMatchIdentity == nil }
        XCTAssertEqual(vm.routePresentation.presentationCount, 1)
    }

    func testResolutionCannotStartDuringConfirmedRoutePreparation() async {
        pluginProvider.installedPlugins["p1"] = makePlugin()
        pluginProvider.suspendedRunnerPluginIDs.insert("p1")
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        let match = makeMangaMatch()

        vm.confirmAndRoute(match: match)
        await waitUntil { self.pluginProvider.runnerRequestCount == 1 }
        guard case .savedSource(let mapping, _) = vm.state else {
            return XCTFail("Confirmation should publish its durable save before route preparation")
        }

        vm.resolve()

        guard case .savedSource(let unchangedMapping, _) = vm.state else {
            return XCTFail("Resolution must not supersede an active confirmation")
        }
        XCTAssertEqual(unchangedMapping.pluginMediaKey, mapping.pluginMediaKey)
        XCTAssertFalse(vm.isSearching)
        XCTAssertTrue(vm.isProcessing(match))

        pluginProvider.resumeRunnerRequest(for: "p1")
        await waitUntil { vm.routePresentation.presentationCount == 1 }

        guard case .savedSource(let finalMapping, _) = vm.state else {
            return XCTFail("Route completion must preserve saved state")
        }
        XCTAssertEqual(finalMapping.pluginMediaKey, mapping.pluginMediaKey)
        XCTAssertEqual(vm.sourceRoute?.media.key(), match.media.key())
    }

    func testStaleRoutePreparationCannotPushAfterNewerOpen() async {
        pluginProvider.installedPlugins["p1"] = makePlugin(id: "p1")
        pluginProvider.installedPlugins["p2"] = makePlugin(id: "p2")
        pluginProvider.suspendedRunnerPluginIDs.insert("p1")
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        let firstPayload = ResolvedPluginMedia.manga(Manga(key: "first", title: "First"))
        let secondPayload = ResolvedPluginMedia.manga(Manga(key: "second", title: "Second"))
        let firstMapping = makeMappingRecordForPlugin(
            pluginID: "p1",
            mediaKey: "first",
            payload: firstPayload
        )
        let secondMapping = makeMappingRecordForPlugin(
            pluginID: "p2",
            mediaKey: "second",
            payload: secondPayload
        )

        vm.openSavedSource(mapping: firstMapping, payload: firstPayload)
        await waitUntil { self.pluginProvider.runnerRequestCount == 1 }
        vm.cancelOwnedOperations()
        vm.openSavedSource(mapping: secondMapping, payload: secondPayload)
        await waitUntil { vm.routePresentation.presentationCount == 1 }
        pluginProvider.resumeRunnerRequest(for: "p1")
        await Task.yield()

        XCTAssertEqual(vm.sourceRoute?.pluginID, "p2")
        XCTAssertEqual(vm.sourceRoute?.media.key(), "second")
        XCTAssertEqual(vm.routePresentation.presentationCount, 1)
    }

    func testConfirmationDuringProgressiveResolutionInvalidatesLateResults() async {
        pluginProvider.installedPlugins["p1"] = makePlugin(id: "p1")
        pluginProvider.installedPlugins["p2"] = makePlugin(id: "p2")
        let immediate = FakePluginSearchAdapter(
            pluginID: "p1",
            pluginVersion: "1.0",
            mediaType: .manga
        )
        await immediate.setResults([.manga(Manga(key: "m1", title: "Test"))])
        let suspended = SuspendedPluginSearchAdapter(pluginID: "p2")
        pluginProvider.configuredAdapters["p1"] = immediate
        pluginProvider.configuredAdapters["p2"] = suspended
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )

        vm.resolve()
        await waitUntil {
            guard case .loading(let matches) = vm.state else { return false }
            guard !matches.isEmpty else { return false }
            return await suspended.hasPendingRequest()
        }
        guard case .loading(let matches) = vm.state,
              let match = matches.first else {
            return XCTFail("Expected a progressive match")
        }

        vm.confirmAndRoute(match: match)
        await waitUntil {
            if case .savedSource = vm.state {
                return vm.routePresentation.presentationCount == 1
            }
            return false
        }
        await suspended.resume(with: [.manga(Manga(key: "late", title: "Test"))])
        await Task.yield()

        guard case .savedSource(let mapping, _) = vm.state else {
            return XCTFail("Late resolution must not overwrite saved state")
        }
        XCTAssertEqual(mapping.pluginMediaKey, "m1")
        XCTAssertEqual(vm.routePresentation.presentationCount, 1)
        XCTAssertFalse(vm.isSearching)
    }

    func testRejectionDuringProgressiveResolutionInvalidatesLateResults() async {
        pluginProvider.installedPlugins["p1"] = makePlugin(id: "p1")
        pluginProvider.installedPlugins["p2"] = makePlugin(id: "p2")
        let immediate = FakePluginSearchAdapter(
            pluginID: "p1",
            pluginVersion: "1.0",
            mediaType: .manga
        )
        await immediate.setResults([.manga(Manga(key: "m1", title: "Test"))])
        let suspended = SuspendedPluginSearchAdapter(pluginID: "p2")
        pluginProvider.configuredAdapters["p1"] = immediate
        pluginProvider.configuredAdapters["p2"] = suspended
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )

        vm.resolve()
        await waitUntil {
            guard case .loading(let matches) = vm.state else { return false }
            guard !matches.isEmpty else { return false }
            return await suspended.hasPendingRequest()
        }
        guard case .loading(let matches) = vm.state,
              let match = matches.first else {
            return XCTFail("Expected a progressive match")
        }

        vm.rejectAndMark(match: match)
        await waitUntil { vm.processingMatchIdentity == nil }
        await suspended.resume(with: [.manga(Manga(key: "late", title: "Test"))])
        await Task.yield()

        guard case .completed(let finalMatches) = vm.state else {
            return XCTFail("Late resolution must not overwrite rejected state")
        }
        XCTAssertEqual(finalMatches.first?.sourceIdentity, match.sourceIdentity)
        XCTAssertEqual(finalMatches.first?.decision, .discard)
        XCTAssertFalse(vm.isSearching)
    }

    func testRejectionMarksExactMatchInsidePartialFailure() async {
        pluginProvider.installedPlugins["p1"] = makePlugin(id: "p1")
        pluginProvider.installedPlugins["p2"] = makePlugin(id: "p2")
        let immediate = FakePluginSearchAdapter(
            pluginID: "p1",
            pluginVersion: "1.0",
            mediaType: .manga
        )
        await immediate.setResults([.manga(Manga(key: "m1", title: "Test"))])
        let failing = FakePluginSearchAdapter(
            pluginID: "p2",
            pluginVersion: "1.0",
            mediaType: .manga
        )
        await failing.setError(SourceResolverTestError.failed)
        pluginProvider.configuredAdapters["p1"] = immediate
        pluginProvider.configuredAdapters["p2"] = failing
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )

        vm.resolve()
        await waitUntil {
            if case .partialFailure = vm.state { return true }
            return false
        }
        guard case .partialFailure(let matches, _) = vm.state,
              let match = matches.first else {
            return XCTFail("Expected a partial result")
        }

        vm.rejectAndMark(match: match)
        await waitUntil { vm.processingMatchIdentity == nil }

        guard case .partialFailure(let finalMatches, let failures) = vm.state else {
            return XCTFail("Expected partial failure state to remain")
        }
        XCTAssertEqual(finalMatches.first?.sourceIdentity, match.sourceIdentity)
        XCTAssertEqual(finalMatches.first?.decision, .discard)
        XCTAssertEqual(failures, ["p2"])
    }

    func testResolverReleasesWhileRunnerRequestIsSuspended() async {
        pluginProvider.installedPlugins["p1"] = makePlugin()
        pluginProvider.suspendedRunnerPluginIDs.insert("p1")
        var vm: SourceResolverViewModel? = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        weak var releasedViewModel = vm
        let payload = ResolvedPluginMedia.manga(makeCompleteManga())

        vm?.openSavedSource(mapping: makeMappingRecord(payload: payload), payload: payload)
        await waitUntil { self.pluginProvider.runnerRequestCount == 1 }
        vm = nil
        await waitUntil { releasedViewModel == nil }
        pluginProvider.resumeRunnerRequest(for: "p1")
        await Task.yield()

        XCTAssertNil(releasedViewModel)
    }

    func testSourceResolverRequiresRepositoryAndRouteFactoryInjection() throws {
        let source = try sourceFile("Ito/ViewModels/Discover/SourceResolverViewModel.swift")
        let initializerStart = try XCTUnwrap(source.range(of: "init(\n        media:"))
        let signatureEnd = try XCTUnwrap(
            source.range(of: "    ) {", range: initializerStart.lowerBound..<source.endIndex)
        )
        let initializer = source[initializerStart.lowerBound..<signatureEnd.lowerBound]

        XCTAssertTrue(initializer.contains("repository: any SourceMappingRepository"))
        XCTAssertTrue(initializer.contains("routeFactory: any SourceRouteBuilding"))
        XCTAssertTrue(initializer.contains("libraryObserver: any SourceResolverLibraryObserving"))
        XCTAssertTrue(initializer.contains("trackerLinker: any SourceResolverTrackerLinking"))
        XCTAssertFalse(initializer.contains("="))
        XCTAssertFalse(source.contains("AppDatabase.shared"))
        XCTAssertFalse(source.contains("public protocol PluginProviding"))
        XCTAssertFalse(source.contains("any PluginProviding"))
        XCTAssertFalse(source.contains("AppLogger"))
    }

    func testSourceDestinationAutoLinksAniListOnDirectAndCollisionPrefixedSave() async {
        let libraryObserver = SourceResolverLibraryObserverFake()
        let trackerLinker = SourceResolverTrackerLinkerSpy()
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory(),
            libraryObserver: libraryObserver,
            trackerLinker: trackerLinker
        )
        let route = SourceRoute(
            media: .manga(Manga(key: "m1", title: "Title")),
            pluginID: "p1",
            runner: ItoRunner(),
            anilistID: 42
        )

        vm.present(route: route)
        XCTAssertTrue(trackerLinker.linked.isEmpty)

        libraryObserver.publish([
            Ito.LibraryItem(
                id: "p1_m1",
                title: "Title",
                coverUrl: nil,
                pluginId: "p1",
                isAnime: false,
                pluginType: .manga,
                rawPayload: Data(),
                anilistId: nil,
                knownChapterCount: 0
            )
        ])
        await waitUntil { trackerLinker.linked.count == 1 }

        XCTAssertEqual(trackerLinker.linked.count, 1)
        XCTAssertEqual(trackerLinker.linked.first?.media, MediaIdentity(pluginId: "p1", itemId: "m1"))
        XCTAssertEqual(trackerLinker.linked.first?.remoteMediaID, "42")
    }

    func testSourceDestinationSkipsAlreadyLinkedAndCancelsAutoLinkOnDismiss() async {
        let libraryObserver = SourceResolverLibraryObserverFake(items: [
            Ito.LibraryItem(
                id: "m1",
                title: "Title",
                coverUrl: nil,
                pluginId: "p1",
                isAnime: false,
                pluginType: .manga,
                rawPayload: Data(),
                anilistId: nil,
                knownChapterCount: 0
            )
        ])
        let trackerLinker = SourceResolverTrackerLinkerSpy()
        let identity = MediaIdentity(pluginId: "p1", itemId: "m1")
        trackerLinker.existingIDs[identity] = "99"
        let vm = SourceResolverViewModel(
            media: makeDiscoverMedia(),
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory(),
            libraryObserver: libraryObserver,
            trackerLinker: trackerLinker
        )
        let route = SourceRoute(
            media: .manga(Manga(key: "m1", title: "Title")),
            pluginID: "p1",
            runner: ItoRunner(),
            anilistID: 99
        )

        vm.present(route: route)
        vm.destinationDidAppear()
        XCTAssertTrue(trackerLinker.linked.isEmpty)

        trackerLinker.existingIDs.removeAll()
        trackerLinker.suspendLinks = true
        vm.destinationDidAppear()
        await waitUntil { trackerLinker.callCount == 1 }

        vm.manualDestinationPopRequested()
        vm.destinationDidDisappear()
        XCTAssertNil(vm.sourceRoute)
        trackerLinker.resumeSuspendedLink()
        await Task.yield()
        XCTAssertTrue(trackerLinker.linked.isEmpty)
    }

}

actor SourceResolverRepositorySpy: SourceMappingRepository {
    private var records: [SourceMappingRecord] = []
    private var failsFetchAll = false
    private var failsUpsert = false
    private var failsRejection = false

    func setFetchAllFailure(_ shouldFail: Bool) {
        failsFetchAll = shouldFail
    }

    func setUpsertFailure(_ shouldFail: Bool) {
        failsUpsert = shouldFail
    }

    func setRejectionFailure(_ shouldFail: Bool) {
        failsRejection = shouldFail
    }

    func fetchConfirmed(
        canonicalProvider: String,
        canonicalMediaId: String,
        mediaType: PluginMediaType
    ) async throws -> [SourceMappingRecord] {
        records.filter {
            $0.canonicalProvider == canonicalProvider
                && $0.canonicalMediaId == canonicalMediaId
                && $0.mediaType == mediaType
                && $0.decision != .discard
        }
    }

    func fetchAll(
        canonicalProvider: String,
        canonicalMediaId: String,
        mediaType: PluginMediaType
    ) async throws -> [SourceMappingRecord] {
        if failsFetchAll { throw SourceResolverTestError.failed }
        return records.filter {
            $0.canonicalProvider == canonicalProvider
                && $0.canonicalMediaId == canonicalMediaId
                && $0.mediaType == mediaType
        }
    }

    func find(pluginId: String, pluginMediaKey: String) async throws -> [SourceMappingRecord] {
        records.filter {
            $0.pluginId == pluginId && $0.pluginMediaKey == pluginMediaKey
        }
    }

    func upsert(_ record: SourceMappingRecord) async throws {
        if failsUpsert { throw SourceResolverTestError.failed }
        records.removeAll {
            $0.canonicalProvider == record.canonicalProvider
                && $0.canonicalMediaId == record.canonicalMediaId
                && $0.mediaType == record.mediaType
                && $0.pluginId == record.pluginId
                && $0.pluginMediaKey == record.pluginMediaKey
        }
        records.append(record)
    }

    func persistRejection(
        canonicalProvider: String,
        canonicalMediaId: String,
        mediaType: PluginMediaType,
        pluginId: String,
        pluginMediaKey: String
    ) async throws {
        if failsRejection { throw SourceResolverTestError.failed }
        let now = Date()
        try await upsert(SourceMappingRecord(
            canonicalProvider: canonicalProvider,
            canonicalMediaId: canonicalMediaId,
            mediaType: mediaType,
            pluginId: pluginId,
            pluginMediaKey: pluginMediaKey,
            decision: .discard,
            matchMethod: .none,
            confidence: 1,
            titleSnapshot: "",
            createdAt: now,
            updatedAt: now
        ))
    }

    func unlink(
        canonicalProvider: String,
        canonicalMediaId: String,
        mediaType: PluginMediaType,
        pluginId: String,
        pluginMediaKey: String
    ) async throws {
        records.removeAll {
            $0.canonicalProvider == canonicalProvider
                && $0.canonicalMediaId == canonicalMediaId
                && $0.mediaType == mediaType
                && $0.pluginId == pluginId
                && $0.pluginMediaKey == pluginMediaKey
        }
    }
}

enum SourceResolverTestError: Error {
    case failed
}

private actor SuspendedPluginSearchAdapter: PluginSearching {
    let pluginID: String
    let pluginVersion: String? = "1.0"
    let mediaType: PluginMediaType = .manga

    private var continuation: CheckedContinuation<[ResolvedPluginMedia], Error>?

    init(pluginID: String) {
        self.pluginID = pluginID
    }

    func search(query: String) async throws -> [ResolvedPluginMedia] {
        _ = query
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasPendingRequest() -> Bool {
        continuation != nil
    }

    func resume(with results: [ResolvedPluginMedia]) {
        continuation?.resume(returning: results)
        continuation = nil
    }
}

@MainActor
private final class SourceResolverLibraryObserverFake: SourceResolverLibraryObserving {
    @Published private(set) var libraryItems: [Ito.LibraryItem]

    init(items: [Ito.LibraryItem] = []) {
        self.libraryItems = items
    }

    var libraryItemsPublisher: AnyPublisher<[Ito.LibraryItem], Never> {
        $libraryItems.eraseToAnyPublisher()
    }

    func publish(_ items: [Ito.LibraryItem]) {
        libraryItems = items
    }
}

@MainActor
private final class SourceResolverTrackerLinkerSpy: SourceResolverTrackerLinking {
    struct LinkCall {
        let media: MediaIdentity
        let remoteMediaID: String
    }

    var existingIDs: [MediaIdentity: String] = [:]
    var suspendLinks = false
    private(set) var callCount = 0
    private(set) var linked: [LinkCall] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func anilistTrackerID(for media: MediaIdentity) -> String? {
        existingIDs[media]
    }

    func linkAniList(media: MediaIdentity, remoteMediaID: String) async throws {
        callCount += 1
        if suspendLinks {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        try Task.checkCancellation()
        existingIDs[media] = remoteMediaID
        linked.append(LinkCall(media: media, remoteMediaID: remoteMediaID))
    }

    func resumeSuspendedLink() {
        continuation?.resume()
        continuation = nil
    }
}
