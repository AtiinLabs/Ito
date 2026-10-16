import Combine
import XCTest
import UIKit
@testable import Ito
import ito_runner

@MainActor
final class DiscoverDetailViewModelTests: XCTestCase {
    func testInitialMediaAndResolverIdentityAreStable() {
        let initial = makeMedia(id: 7, title: "Summary")
        let dependencies = makeDependencies(media: initial)
        let viewModel = dependencies.viewModel
        let resolverIdentity = ObjectIdentifier(viewModel.sourceResolver)

        XCTAssertEqual(viewModel.media.id, 7)
        XCTAssertEqual(viewModel.media.title, "Summary")
        XCTAssertEqual(viewModel.detailLoadState, .idle)
        XCTAssertEqual(viewModel.mediaThemeKey, "anilist_7")

        viewModel.requestConfirmation(for: makeMatch(key: "one"))
        viewModel.cancelConfirmation()

        XCTAssertEqual(ObjectIdentifier(viewModel.sourceResolver), resolverIdentity)
    }

    func testStartFetchesDetailsOnceAndPublishesFullPayload() async {
        let initial = makeMedia(id: 7, title: "Summary")
        let full = makeMedia(id: 7, title: "Full", description: "Details")
        let dependencies = makeDependencies(media: initial)
        dependencies.detailService.results = [.success(full)]

        dependencies.viewModel.start()
        dependencies.viewModel.start()
        await waitUntil { dependencies.viewModel.detailLoadState == .loaded }

        XCTAssertEqual(dependencies.detailService.requestedIDs, [7])
        XCTAssertEqual(dependencies.viewModel.media.title, "Full")
        XCTAssertEqual(dependencies.viewModel.media.description, "Details")
    }

    func testNilDetailsPreserveSummaryWithoutFailureMessage() async {
        let dependencies = makeDependencies(media: makeMedia(id: 7, title: "Summary"))
        dependencies.detailService.results = [.success(nil)]

        dependencies.viewModel.start()
        await waitUntil { dependencies.viewModel.detailLoadState == .loaded }

        XCTAssertEqual(dependencies.viewModel.media.title, "Summary")
        XCTAssertTrue(dependencies.messagePresenter.messages.isEmpty)
    }

    func testDetailFailurePreservesSummaryPublishesSanitizedMessageAndRetries() async {
        let dependencies = makeDependencies(media: makeMedia(id: 7, title: "Summary"))
        dependencies.detailService.results = [
            .failure(DetailTestError.failed),
            .success(makeMedia(id: 7, title: "Retried"))
        ]

        dependencies.viewModel.start()
        await waitUntil { dependencies.viewModel.detailLoadState == .failed }

        XCTAssertEqual(dependencies.viewModel.media.title, "Summary")
        XCTAssertEqual(dependencies.messagePresenter.messages, [.refreshFailed])

        dependencies.viewModel.retryDetails()
        await waitUntil { dependencies.viewModel.detailLoadState == .loaded }

        XCTAssertEqual(dependencies.viewModel.media.title, "Retried")
        XCTAssertEqual(dependencies.detailService.requestedIDs, [7, 7])
    }

    func testStaleDetailCompletionCannotOverwriteRetry() async {
        let dependencies = makeDependencies(media: makeMedia(id: 7, title: "Summary"))
        dependencies.detailService.suspendsRequests = true

        dependencies.viewModel.start()
        await waitUntil { dependencies.detailService.requestedIDs.count == 1 }
        dependencies.viewModel.retryDetails()
        await waitUntil { dependencies.detailService.requestedIDs.count == 2 }

        dependencies.detailService.complete(
            request: 1,
            with: .success(makeMedia(id: 7, title: "Newest"))
        )
        await waitUntil { dependencies.viewModel.media.title == "Newest" }
        dependencies.detailService.complete(
            request: 0,
            with: .success(makeMedia(id: 7, title: "Stale"))
        )
        await Task.yield()

        XCTAssertEqual(dependencies.viewModel.media.title, "Newest")
        XCTAssertEqual(dependencies.viewModel.detailLoadState, .loaded)
    }

    func testCachedThemeUsesStableMediaKey() async {
        let dependencies = makeDependencies(media: makeMedia(id: 42, title: "Media"))
        let theme = ThemeColors(dominantHex: "#111111", secondaryHex: "#222222")
        dependencies.themeService.cachedResults = [theme]

        dependencies.viewModel.start()
        await waitUntil { dependencies.viewModel.theme == theme }

        XCTAssertEqual(dependencies.themeService.cachedKeys, ["anilist_42"])
    }

    func testNoCachedThemeLeavesThemeUnset() async {
        let dependencies = makeDependencies(media: makeMedia(id: 42, title: "Media"))
        dependencies.themeService.cachedResults = [nil]

        dependencies.viewModel.start()
        await waitUntil { dependencies.themeService.cachedKeys.count == 1 }

        XCTAssertNil(dependencies.viewModel.theme)
    }

    func testThemeExtractionPublishesThemeForStableMediaKey() async {
        let dependencies = makeDependencies(media: makeMedia(id: 42, title: "Media"))
        let theme = ThemeColors(dominantHex: "#333333", secondaryHex: "#444444")
        dependencies.themeService.extractedResults = [theme]

        dependencies.viewModel.heroImageLoaded(UIImage())
        await waitUntil { dependencies.viewModel.theme == theme }

        XCTAssertEqual(dependencies.themeService.extractedKeys, ["anilist_42"])
    }

    func testStaleCachedThemeCannotOverwriteNewerExtraction() async {
        let dependencies = makeDependencies(media: makeMedia(id: 42, title: "Media"))
        dependencies.themeService.suspendsCachedRequests = true
        dependencies.themeService.suspendsExtractionRequests = true
        let fresh = ThemeColors(dominantHex: "#555555", secondaryHex: "#666666")
        let stale = ThemeColors(dominantHex: "#777777", secondaryHex: "#888888")

        dependencies.viewModel.start()
        await waitUntil { dependencies.themeService.cachedKeys.count == 1 }
        dependencies.viewModel.heroImageLoaded(UIImage())
        await waitUntil { dependencies.themeService.extractedKeys.count == 1 }

        dependencies.themeService.completeExtraction(request: 0, with: fresh)
        await waitUntil { dependencies.viewModel.theme == fresh }
        dependencies.themeService.completeCached(request: 0, with: stale)
        await Task.yield()

        XCTAssertEqual(dependencies.viewModel.theme, fresh)
    }

    func testConfirmationSelectionCancellationAndExactForwarding() async {
        let dependencies = makeDependenciesWithPlugin()
        let first = makeMatch(key: "first")
        let second = makeMatch(key: "second")

        dependencies.viewModel.requestConfirmation(for: first)
        XCTAssertEqual(dependencies.viewModel.confirmationCandidate, first)
        dependencies.viewModel.cancelConfirmation()
        XCTAssertNil(dependencies.viewModel.confirmationCandidate)
        var records = await dependencies.repository.records()
        XCTAssertTrue(records.isEmpty)

        dependencies.viewModel.requestConfirmation(for: second)
        dependencies.viewModel.confirmPresentedSource(first)
        XCTAssertEqual(dependencies.viewModel.confirmationCandidate, second)
        records = await dependencies.repository.records()
        XCTAssertTrue(records.isEmpty)

        dependencies.viewModel.confirmPresentedSource(second)
        await waitUntil { await dependencies.repository.records().count == 1 }

        XCTAssertNil(dependencies.viewModel.confirmationCandidate)
        records = await dependencies.repository.records()
        XCTAssertEqual(records.first?.pluginMediaKey, "second")
    }

    func testConfirmationFailureDoesNotPublishSavedStateOrRoute() async {
        let dependencies = makeDependenciesWithPlugin()
        await dependencies.repository.setUpsertFailure(true)
        let match = makeMatch(key: "failed-confirm")

        dependencies.viewModel.requestConfirmation(for: match)
        dependencies.viewModel.confirmPresentedSource(match)
        await waitUntil { dependencies.viewModel.sourceResolver.processingMatchIdentity == nil }

        if case .savedSource = dependencies.viewModel.sourceResolver.state {
            XCTFail("Failed persistence must not publish saved state")
        }
        XCTAssertNil(dependencies.viewModel.sourceResolver.sourceRoute)
        XCTAssertNotNil(dependencies.viewModel.sourceResolver.pluginSearchError)
    }

    func testRejectionSelectionCancellationAndExactForwarding() async {
        let dependencies = makeDependenciesWithPlugin()
        let first = makeMatch(key: "first")
        let second = makeMatch(key: "second")

        dependencies.viewModel.requestRejection(for: first)
        XCTAssertEqual(dependencies.viewModel.rejectionCandidate, first)
        dependencies.viewModel.cancelRejection()
        XCTAssertNil(dependencies.viewModel.rejectionCandidate)
        var rejections = await dependencies.repository.rejections()
        XCTAssertTrue(rejections.isEmpty)

        dependencies.viewModel.requestRejection(for: second)
        dependencies.viewModel.rejectPresentedSource(first)
        XCTAssertEqual(dependencies.viewModel.rejectionCandidate, second)
        rejections = await dependencies.repository.rejections()
        XCTAssertTrue(rejections.isEmpty)

        dependencies.viewModel.rejectPresentedSource(second)
        await waitUntil { await dependencies.repository.rejections().count == 1 }

        XCTAssertNil(dependencies.viewModel.rejectionCandidate)
        rejections = await dependencies.repository.rejections()
        XCTAssertEqual(rejections.first?.pluginMediaKey, "second")
    }

    func testRejectionFailureLeavesMatchRetryable() async {
        let dependencies = makeDependenciesWithPlugin()
        await dependencies.repository.setRejectionFailure(true)
        let match = makeMatch(key: "failed-reject")
        dependencies.viewModel.sourceResolver.setSavedSourceState(
            mapping: makeMappingRecord(key: "saved"),
            payload: match.media
        )

        dependencies.viewModel.requestRejection(for: match)
        dependencies.viewModel.rejectPresentedSource(match)
        await waitUntil { dependencies.viewModel.sourceResolver.processingMatchIdentity == nil }

        XCTAssertNotNil(dependencies.viewModel.sourceResolver.pluginSearchError)
        let rejections = await dependencies.repository.rejections()
        XCTAssertTrue(rejections.isEmpty)
    }

    func testInstalledPluginPublicationDoesNotRecreateResolver() async {
        let dependencies = makeDependencies(media: makeMedia(id: 7, title: "Summary"))
        let identity = ObjectIdentifier(dependencies.viewModel.sourceResolver)

        dependencies.pluginProvider.install(makePlugin())
        await waitUntil { dependencies.viewModel.installedPlugins["p1"] != nil }

        XCTAssertNotNil(dependencies.viewModel.installedPlugins["p1"])
        XCTAssertEqual(ObjectIdentifier(dependencies.viewModel.sourceResolver), identity)
    }

    func testCancelScreenOperationsSuppressesLateDetailAndThemePublication() async {
        let dependencies = makeDependencies(media: makeMedia(id: 7, title: "Summary"))
        dependencies.detailService.suspendsRequests = true
        dependencies.themeService.suspendsCachedRequests = true

        dependencies.viewModel.start()
        await waitUntil {
            dependencies.detailService.requestedIDs.count == 1
                && dependencies.themeService.cachedKeys.count == 1
        }
        dependencies.viewModel.cancelScreenOperations()
        dependencies.detailService.complete(
            request: 0,
            with: .success(makeMedia(id: 7, title: "Late"))
        )
        dependencies.themeService.completeCached(
            request: 0,
            with: ThemeColors(dominantHex: "#999999", secondaryHex: "#AAAAAA")
        )
        await Task.yield()

        XCTAssertEqual(dependencies.viewModel.media.title, "Summary")
        XCTAssertNil(dependencies.viewModel.theme)
        XCTAssertEqual(dependencies.viewModel.detailLoadState, .idle)
    }

    func testScreenReleaseCancelsNoncooperativeWorkAndSuppressesLateMessage() async throws {
        let media = makeMedia(id: 7, title: "Summary")
        let detailService = DiscoverDetailServiceFake()
        detailService.suspendsRequests = true
        let themeService = DiscoverDetailThemeServiceFake()
        themeService.suspendsCachedRequests = true
        let messagePresenter = DiscoverDetailMessagePresenterSpy()
        let pluginProvider = DiscoverDetailPluginProviderFake()
        let repository = DiscoverDetailRepositorySpy()
        var resolver: SourceResolverViewModel? = SourceResolverViewModel(
            media: media,
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        var viewModel: DiscoverDetailViewModel? = DiscoverDetailViewModel(
            media: media,
            detailService: detailService,
            themeService: themeService,
            messagePresenter: messagePresenter,
            pluginProvider: pluginProvider,
            sourceResolver: try XCTUnwrap(resolver)
        )
        weak var releasedViewModel = viewModel
        weak var releasedResolver = resolver

        viewModel?.start()
        await waitUntil {
            detailService.requestedIDs.count == 1
                && themeService.cachedKeys.count == 1
        }

        resolver = nil
        viewModel = nil
        await waitUntil { releasedViewModel == nil && releasedResolver == nil }

        detailService.complete(request: 0, with: .failure(DetailTestError.failed))
        themeService.completeCached(
            request: 0,
            with: ThemeColors(dominantHex: "#999999", secondaryHex: "#AAAAAA")
        )
        await Task.yield()

        XCTAssertTrue(messagePresenter.messages.isEmpty)
    }

    func testViewModelAndViewContainNoForbiddenGlobalsOrMutableConfiguration() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            "Ito/ViewModels/Discover/DiscoverDetailViewModel.swift",
            "Ito/ViewModels/Discover/SourceResolverViewModel.swift",
            "Ito/Views/Discover/DiscoverDetailView.swift"
        ]
        let forbidden = [
            "AppDatabase.shared",
            "DiscoverManager.shared",
            "ThemeManager.shared",
            "PluginManager.shared",
            "SnackBarManager.shared",
            "URLSession.shared",
            "FileManager.default",
            "UserDefaults.standard",
            "UIApplication.shared",
            "func configure(",
            "AnyView",
            "@EnvironmentObject",
            "LibraryManager",
            "TrackerManager"
        ]

        for path in paths {
            let source = try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
            for value in forbidden {
                XCTAssertFalse(source.contains(value), "\(path): \(value)")
            }
        }
    }

    private func makeDependencies(
        media: DiscoverMedia
    ) -> DiscoverDetailTestDependencies {
        let detailService = DiscoverDetailServiceFake()
        let themeService = DiscoverDetailThemeServiceFake()
        let messagePresenter = DiscoverDetailMessagePresenterSpy()
        let pluginProvider = DiscoverDetailPluginProviderFake()
        let repository = DiscoverDetailRepositorySpy()
        let resolver = SourceResolverViewModel(
            media: media,
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: SourceRouteFactory()
        )
        let viewModel = DiscoverDetailViewModel(
            media: media,
            detailService: detailService,
            themeService: themeService,
            messagePresenter: messagePresenter,
            pluginProvider: pluginProvider,
            sourceResolver: resolver
        )
        return DiscoverDetailTestDependencies(
            viewModel: viewModel,
            detailService: detailService,
            themeService: themeService,
            messagePresenter: messagePresenter,
            pluginProvider: pluginProvider,
            repository: repository
        )
    }

    private func makeDependenciesWithPlugin() -> DiscoverDetailTestDependencies {
        let dependencies = makeDependencies(media: makeMedia(id: 7, title: "Summary"))
        dependencies.pluginProvider.install(makePlugin())
        return dependencies
    }

    private func makeMedia(
        id: Int,
        title: String,
        description: String? = nil
    ) -> DiscoverMedia {
        DiscoverMedia(
            id: id,
            title: title,
            titleEnglish: nil,
            titleRomaji: nil,
            titleNative: nil,
            synonyms: [],
            coverImage: nil,
            bannerImage: nil,
            format: nil,
            status: nil,
            description: description,
            cleanDescription: description,
            genres: nil,
            averageScore: nil,
            episodes: nil,
            chapters: nil,
            season: nil,
            seasonYear: nil,
            type: "MANGA",
            recommendations: nil
        )
    }

    private func makeMatch(key: String) -> MatchedSource {
        MatchedSource(
            pluginID: "p1",
            pluginVersion: "1.0",
            media: .manga(Manga(key: key, title: key)),
            matchMethod: .fuzzy,
            score: 0.8,
            decision: .requiresConfirmation
        )
    }

    private func makePlugin() -> InstalledPlugin {
        InstalledPlugin(
            url: URL(fileURLWithPath: "/p1.ito"),
            info: PluginInfo(
                id: "p1",
                name: "Plugin",
                version: "1.0",
                minAppVersion: "1.0",
                type: .manga
            ),
            iconData: nil
        )
    }

    private func makeMappingRecord(key: String) -> SourceMappingRecord {
        SourceMappingRecord(
            canonicalProvider: "anilist",
            canonicalMediaId: "7",
            mediaType: .manga,
            pluginId: "p1",
            pluginMediaKey: key,
            decision: .autoConfirm,
            matchMethod: .exactPreferred,
            confidence: 1,
            titleSnapshot: key,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func waitUntil(
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

private struct DiscoverDetailTestDependencies {
    let viewModel: DiscoverDetailViewModel
    let detailService: DiscoverDetailServiceFake
    let themeService: DiscoverDetailThemeServiceFake
    let messagePresenter: DiscoverDetailMessagePresenterSpy
    let pluginProvider: DiscoverDetailPluginProviderFake
    let repository: DiscoverDetailRepositorySpy
}

private enum DetailTestError: Error {
    case failed
}

@MainActor
private final class DiscoverDetailServiceFake: DiscoverDetailServing {
    var results: [Result<DiscoverMedia?, Error>] = []
    var suspendsRequests = false
    private(set) var requestedIDs: [Int] = []
    private var continuations: [Int: CheckedContinuation<DiscoverMedia?, Error>] = [:]

    func fetchDiscoverDetails(id: Int) async throws -> DiscoverMedia? {
        let request = requestedIDs.count
        requestedIDs.append(id)
        if !results.isEmpty {
            return try results.removeFirst().get()
        }
        if suspendsRequests {
            return try await withCheckedThrowingContinuation { continuation in
                continuations[request] = continuation
            }
        }
        return nil
    }

    func complete(request: Int, with result: Result<DiscoverMedia?, Error>) {
        guard let continuation = continuations.removeValue(forKey: request) else {
            return
        }
        continuation.resume(with: result)
    }
}

@MainActor
private final class DiscoverDetailThemeServiceFake: DiscoverDetailThemeServing {
    var cachedResults: [ThemeColors?] = []
    var extractedResults: [ThemeColors?] = []
    var suspendsCachedRequests = false
    var suspendsExtractionRequests = false
    private(set) var cachedKeys: [String] = []
    private(set) var extractedKeys: [String] = []
    private var cachedContinuations: [Int: CheckedContinuation<ThemeColors?, Never>] = [:]
    private var extractionContinuations: [Int: CheckedContinuation<ThemeColors?, Never>] = [:]

    func cachedTheme(for mediaKey: String) async -> ThemeColors? {
        let request = cachedKeys.count
        cachedKeys.append(mediaKey)
        if !cachedResults.isEmpty {
            return cachedResults.removeFirst()
        }
        if suspendsCachedRequests {
            return await withCheckedContinuation { continuation in
                cachedContinuations[request] = continuation
            }
        }
        return nil
    }

    func extractTheme(from image: UIImage, for mediaKey: String) async -> ThemeColors? {
        _ = image
        let request = extractedKeys.count
        extractedKeys.append(mediaKey)
        if !extractedResults.isEmpty {
            return extractedResults.removeFirst()
        }
        if suspendsExtractionRequests {
            return await withCheckedContinuation { continuation in
                extractionContinuations[request] = continuation
            }
        }
        return nil
    }

    func completeCached(request: Int, with theme: ThemeColors?) {
        cachedContinuations.removeValue(forKey: request)?.resume(returning: theme)
    }

    func completeExtraction(request: Int, with theme: ThemeColors?) {
        extractionContinuations.removeValue(forKey: request)?.resume(returning: theme)
    }
}

@MainActor
private final class DiscoverDetailMessagePresenterSpy: DiscoverDetailMessagePresenting {
    private(set) var messages: [DiscoverDetailMessage] = []

    func present(_ message: DiscoverDetailMessage) {
        messages.append(message)
    }
}

@MainActor
private final class DiscoverDetailPluginProviderFake: SourceResolverPluginProviding {
    private let installedPluginsSubject = CurrentValueSubject<
        [String: InstalledPlugin],
        Never
    >([:])
    private(set) var installedPlugins: [String: InstalledPlugin] = [:]
    var runnerError: Error?
    private let runner = ItoRunner()

    var installedPluginsPublisher: AnyPublisher<[String: InstalledPlugin], Never> {
        installedPluginsSubject.eraseToAnyPublisher()
    }

    func install(_ plugin: InstalledPlugin) {
        installedPlugins[plugin.id] = plugin
        installedPluginsSubject.send(installedPlugins)
    }

    func sourceRunnerContext(for pluginID: String) async throws -> any SourceRunnerContext {
        if let runnerError { throw runnerError }
        guard installedPlugins[pluginID] != nil else { throw DetailTestError.failed }
        return ItoRunnerSourceContext(runner: runner)
    }

    func evictSourceRunner(for pluginID: String) {
        _ = pluginID
    }

    func sourceSearchAdapter(
        for pluginID: String,
        mediaType: PluginMediaType
    ) async throws -> any PluginSearching {
        guard let plugin = installedPlugins[pluginID] else { throw DetailTestError.failed }
        return DiscoverDetailSearchAdapter(
            pluginID: pluginID,
            pluginVersion: plugin.info.version,
            mediaType: mediaType
        )
    }
}

private actor DiscoverDetailSearchAdapter: PluginSearching {
    let pluginID: String
    let pluginVersion: String?
    let mediaType: PluginMediaType

    init(
        pluginID: String,
        pluginVersion: String?,
        mediaType: PluginMediaType
    ) {
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.mediaType = mediaType
    }

    func search(query: String) async throws -> [ResolvedPluginMedia] {
        _ = query
        return []
    }
}

private actor DiscoverDetailRepositorySpy: SourceMappingRepository {
    struct Rejection: Equatable {
        let pluginID: String
        let pluginMediaKey: String
    }

    private var storedRecords: [SourceMappingRecord] = []
    private var storedRejections: [Rejection] = []
    private var failsUpsert = false
    private var failsRejection = false

    func setUpsertFailure(_ shouldFail: Bool) {
        failsUpsert = shouldFail
    }

    func setRejectionFailure(_ shouldFail: Bool) {
        failsRejection = shouldFail
    }

    func records() -> [SourceMappingRecord] {
        storedRecords
    }

    func rejections() -> [Rejection] {
        storedRejections
    }

    func fetchConfirmed(
        canonicalProvider: String,
        canonicalMediaId: String,
        mediaType: PluginMediaType
    ) async throws -> [SourceMappingRecord] {
        storedRecords.filter {
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
        storedRecords.filter {
            $0.canonicalProvider == canonicalProvider
                && $0.canonicalMediaId == canonicalMediaId
                && $0.mediaType == mediaType
        }
    }

    func find(pluginId: String, pluginMediaKey: String) async throws -> [SourceMappingRecord] {
        storedRecords.filter {
            $0.pluginId == pluginId && $0.pluginMediaKey == pluginMediaKey
        }
    }

    func upsert(_ record: SourceMappingRecord) async throws {
        if failsUpsert { throw DetailTestError.failed }
        storedRecords.removeAll {
            $0.canonicalProvider == record.canonicalProvider
                && $0.canonicalMediaId == record.canonicalMediaId
                && $0.mediaType == record.mediaType
                && $0.pluginId == record.pluginId
                && $0.pluginMediaKey == record.pluginMediaKey
        }
        storedRecords.append(record)
    }

    func persistRejection(
        canonicalProvider: String,
        canonicalMediaId: String,
        mediaType: PluginMediaType,
        pluginId: String,
        pluginMediaKey: String
    ) async throws {
        _ = canonicalProvider
        _ = canonicalMediaId
        _ = mediaType
        if failsRejection { throw DetailTestError.failed }
        storedRejections.append(.init(pluginID: pluginId, pluginMediaKey: pluginMediaKey))
    }

    func unlink(
        canonicalProvider: String,
        canonicalMediaId: String,
        mediaType: PluginMediaType,
        pluginId: String,
        pluginMediaKey: String
    ) async throws {
        storedRecords.removeAll {
            $0.canonicalProvider == canonicalProvider
                && $0.canonicalMediaId == canonicalMediaId
                && $0.mediaType == mediaType
                && $0.pluginId == pluginId
                && $0.pluginMediaKey == pluginMediaKey
        }
    }
}
