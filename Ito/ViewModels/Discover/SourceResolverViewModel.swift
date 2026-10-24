import Combine
import Foundation
import ito_runner

public struct SourceRoute: Equatable {
    public let media: ResolvedPluginMedia
    public let pluginID: String
    public let runner: ItoRunner
    public let anilistID: Int?

    public init(media: ResolvedPluginMedia, pluginID: String, runner: ItoRunner, anilistID: Int?) {
        self.media = media
        self.pluginID = pluginID
        self.runner = runner
        self.anilistID = anilistID
    }

    public static func == (lhs: SourceRoute, rhs: SourceRoute) -> Bool {
        lhs.pluginID == rhs.pluginID
            && lhs.media.key() == rhs.media.key()
            && lhs.anilistID == rhs.anilistID
    }
}

@MainActor
protocol SourceRouteBuilding {
    func route(
        media: ResolvedPluginMedia,
        pluginID: String,
        context: any SourceRunnerContext,
        anilistID: Int?
    ) -> SourceRoute
}

struct SourceRouteFactory: SourceRouteBuilding {
    func route(
        media: ResolvedPluginMedia,
        pluginID: String,
        context: any SourceRunnerContext,
        anilistID: Int?
    ) -> SourceRoute {
        SourceRoute(
            media: media,
            pluginID: pluginID,
            runner: context.runner,
            anilistID: anilistID
        )
    }
}

public struct SourceRoutePresentationState: Equatable {
    public enum Phase: Equatable {
        case idle
        case preparing
        case presented
        case dismissing
        case dismissedByUser
    }

    public private(set) var route: SourceRoute?
    public private(set) var isPresented = false
    public private(set) var phase: Phase = .idle
    public private(set) var presentationCount = 0

    public init() {}

    public mutating func present(_ route: SourceRoute) {
        self.route = route
        phase = .preparing
        isPresented = true
        presentationCount += 1
    }

    public mutating func destinationDidAppear() {
        guard isPresented, route != nil else { return }
        phase = .presented
    }

    public mutating func navigationBindingDidSet(_ isActive: Bool) {
        // NavigationLink may transiently write false while reevaluating its
        // hierarchy. Only the explicit Back action starts dismissal.
        guard isActive else { return }
    }

    public mutating func manualDestinationPopRequested() {
        guard isPresented, route != nil else { return }
        phase = .dismissing
        isPresented = false
    }

    public mutating func destinationDidDisappear() {
        guard phase == .dismissing else { return }
        route = nil
        phase = .dismissedByUser
    }
}

public struct SourceMatchIdentity: Hashable, Sendable {
    public let pluginID: String
    public let pluginVersion: String?
    public let mediaKey: String
    public let mediaKind: String

    public init(match: MatchedSource) {
        self.init(
            pluginID: match.pluginID,
            pluginVersion: match.pluginVersion,
            media: match.media
        )
    }

    public init(
        pluginID: String,
        pluginVersion: String?,
        media: ResolvedPluginMedia
    ) {
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        mediaKey = media.key()
        switch media {
        case .manga:
            mediaKind = "manga"
        case .anime:
            mediaKind = "anime"
        case .novel:
            mediaKind = "novel"
        }
    }
}

@MainActor
public final class SourceResolverViewModel: ObservableObject {
    public enum State {
        case idle
        case loading(matches: [MatchedSource])
        case completed(matches: [MatchedSource])
        case empty
        case noCompatiblePlugins
        case partialFailure(matches: [MatchedSource], failedPlugins: [String])
        case fatalFailure(error: String)
        case cancelled
        case savedSource(mapping: SourceMappingRecord, payload: ResolvedPluginMedia)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var isSearching = false
    @Published public private(set) var pluginSearchError: String?
    @Published public private(set) var processingMatchIdentity: SourceMatchIdentity?
    @Published public private(set) var routePresentation = SourceRoutePresentationState()

    public var sourceRoute: SourceRoute? { routePresentation.route }
    public var isSourceDestinationPresented: Bool { routePresentation.isPresented }

    private let media: DiscoverMedia
    private let repository: any SourceMappingRepository
    private let pluginProvider: any SourceResolverPluginProviding
    private let routeFactory: any SourceRouteBuilding
    private let libraryObserver: any SourceResolverLibraryObserving
    private let trackerLinker: any SourceResolverTrackerLinking

    private var autoLinkTask: Task<Void, Never>?
    private var linkingMediaIdentity: MediaIdentity?
    private var cancellables = Set<AnyCancellable>()

    private var mappingCheckTask: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?
    private var routePreparationTask: Task<Void, Never>?
    private var rejectionTask: Task<Void, Never>?
    private var mappingOperationID: UUID?
    private var resolutionOperationID: UUID?
    private var actionOperationID: UUID?
    private var hasStartedInitialLookup = false

    var canonicalProvider: String { "anilist" }
    private var canonicalMediaId: String { String(media.id) }
    private var canonicalMediaType: PluginMediaType {
        if media.type == "ANIME" {
            return .anime
        }
        if media.format?.uppercased() == "NOVEL" {
            return .novel
        }
        return .manga
    }

    init(
        media: DiscoverMedia,
        repository: any SourceMappingRepository,
        pluginProvider: any SourceResolverPluginProviding,
        routeFactory: any SourceRouteBuilding,
        libraryObserver: any SourceResolverLibraryObserving,
        trackerLinker: any SourceResolverTrackerLinking
    ) {
        self.media = media
        self.repository = repository
        self.pluginProvider = pluginProvider
        self.routeFactory = routeFactory
        self.libraryObserver = libraryObserver
        self.trackerLinker = trackerLinker

        libraryObserver.libraryItemsPublisher
            .sink { [weak self] items in
                self?.linkAniListIfNeeded(items: items)
            }
            .store(in: &cancellables)
    }

    convenience init(
        media: DiscoverMedia,
        repository: any SourceMappingRepository,
        pluginProvider: any SourceResolverPluginProviding,
        routeFactory: any SourceRouteBuilding
    ) {
        let unavailable = UnavailableDiscoverDetailDependency()
        self.init(
            media: media,
            repository: repository,
            pluginProvider: pluginProvider,
            routeFactory: routeFactory,
            libraryObserver: unavailable,
            trackerLinker: unavailable
        )
    }

    deinit {
        mappingCheckTask?.cancel()
        resolutionTask?.cancel()
        routePreparationTask?.cancel()
        rejectionTask?.cancel()
        autoLinkTask?.cancel()
    }

    public func isProcessing(_ match: MatchedSource) -> Bool {
        processingMatchIdentity == SourceMatchIdentity(match: match)
    }

    public func present(route: SourceRoute) {
        routePresentation.present(route)
        linkAniListIfNeeded(items: libraryObserver.libraryItems)
    }

    public func navigationBindingDidSet(_ isActive: Bool) {
        routePresentation.navigationBindingDidSet(isActive)
    }

    public func destinationDidAppear() {
        routePresentation.destinationDidAppear()
        linkAniListIfNeeded(items: libraryObserver.libraryItems)
    }

    public func manualDestinationPopRequested() {
        routePresentation.manualDestinationPopRequested()
    }

    public func destinationDidDisappear() {
        routePresentation.destinationDidDisappear()
        if routePresentation.route == nil {
            autoLinkTask?.cancel()
            autoLinkTask = nil
            linkingMediaIdentity = nil
        }
    }

    private func linkAniListIfNeeded(items: [LibraryItem]) {
        guard let route = sourceRoute,
              let anilistID = route.anilistID else { return }
        let itemKey = route.media.key()
        let mediaKind: MediaKind
        switch route.media {
        case .manga: mediaKind = .manga
        case .anime: mediaKind = .anime
        }
        let mediaIdentity = MediaIdentity(pluginId: route.pluginID, canonicalMediaId: itemKey, mediaKind: mediaKind)
        guard items.contains(where: { $0.mediaIdentity == mediaIdentity }) else { return }
        guard trackerLinker.anilistTrackerID(for: mediaIdentity) == nil,
              linkingMediaIdentity != mediaIdentity else { return }

        linkingMediaIdentity = mediaIdentity
        let remoteMediaID = String(anilistID)
        let trackerLinker = trackerLinker
        autoLinkTask = Task { [weak self, trackerLinker] in
            defer {
                if self?.linkingMediaIdentity == mediaIdentity {
                    self?.linkingMediaIdentity = nil
                    self?.autoLinkTask = nil
                }
            }
            try? await trackerLinker.linkAniList(
                media: mediaIdentity,
                remoteMediaID: remoteMediaID
            )
        }
    }

    private func beginInitialLookup() -> Bool {
        guard !hasStartedInitialLookup else { return false }
        hasStartedInitialLookup = true
        return true
    }

    public func startCheckAndResolve() {
        guard beginInitialLookup() else { return }
        startMappingCheck()
    }

    func checkAndResolve() async {
        guard beginInitialLookup() else { return }
        let operationID = UUID()
        mappingOperationID = operationID
        await runMappingCheck(operationID: operationID)
    }

    private func startMappingCheck() {
        mappingCheckTask?.cancel()
        let operationID = UUID()
        mappingOperationID = operationID
        let repository = repository
        let pluginProvider = pluginProvider
        let canonicalProvider = canonicalProvider
        let canonicalMediaID = canonicalMediaId
        let canonicalMediaType = canonicalMediaType
        mappingCheckTask = Task { [weak self, repository, pluginProvider] in
            await Self.performMappingCheck(
                repository: repository,
                pluginProvider: pluginProvider,
                canonicalProvider: canonicalProvider,
                canonicalMediaID: canonicalMediaID,
                canonicalMediaType: canonicalMediaType,
                isCurrent: { [weak self] in
                    self?.isCurrentMappingOperation(operationID) == true
                },
                mappingNotFound: { [weak self] in
                    guard self?.mappingOperationID == operationID else { return }
                    self?.mappingOperationID = nil
                    self?.mappingCheckTask = nil
                    self?.resolve()
                },
                mappingFound: { [weak self] mapping, payload in
                    guard self?.mappingOperationID == operationID else { return }
                    self?.mappingOperationID = nil
                    self?.mappingCheckTask = nil
                    self?.setSavedSourceState(mapping: mapping, payload: payload)
                }
            )
        }
    }

    private func runMappingCheck(operationID: UUID) async {
        await Self.performMappingCheck(
            repository: repository,
            pluginProvider: pluginProvider,
            canonicalProvider: canonicalProvider,
            canonicalMediaID: canonicalMediaId,
            canonicalMediaType: canonicalMediaType,
            isCurrent: { [weak self] in
                self?.isCurrentMappingOperation(operationID) == true
            },
            mappingNotFound: { [weak self] in
                guard self?.mappingOperationID == operationID else { return }
                self?.mappingOperationID = nil
                self?.resolve()
            },
            mappingFound: { [weak self] mapping, payload in
                guard self?.mappingOperationID == operationID else { return }
                self?.mappingOperationID = nil
                self?.setSavedSourceState(mapping: mapping, payload: payload)
            }
        )
    }

    private static func performMappingCheck(
        repository: any SourceMappingRepository,
        pluginProvider: any SourceResolverPluginProviding,
        canonicalProvider: String,
        canonicalMediaID: String,
        canonicalMediaType: PluginMediaType,
        isCurrent: @escaping @MainActor () -> Bool,
        mappingNotFound: @escaping @MainActor () -> Void,
        mappingFound: @escaping @MainActor (SourceMappingRecord, ResolvedPluginMedia) -> Void
    ) async {
        guard isCurrent() else { return }
        guard let (mapping, payload) = await findExistingMapping(
            repository: repository,
            pluginProvider: pluginProvider,
            canonicalProvider: canonicalProvider,
            canonicalMediaID: canonicalMediaID,
            canonicalMediaType: canonicalMediaType
        ) else {
            guard isCurrent() else { return }
            mappingNotFound()
            return
        }

        try? await repository.upsert(verifiedMapping(mapping))
        guard isCurrent() else { return }
        mappingFound(mapping, payload)
    }

    private func isCurrentMappingOperation(_ operationID: UUID) -> Bool {
        mappingOperationID == operationID && !Task.isCancelled
    }

    private func prepareRoute(
        media: ResolvedPluginMedia,
        pluginID: String
    ) async throws -> SourceRoute {
        try await Self.prepareRoute(
            media: media,
            pluginID: pluginID,
            pluginProvider: pluginProvider,
            routeFactory: routeFactory,
            anilistID: canonicalProvider == "anilist" ? self.media.id : nil
        )
    }

    private static func prepareRoute(
        media: ResolvedPluginMedia,
        pluginID: String,
        pluginProvider: any SourceResolverPluginProviding,
        routeFactory: any SourceRouteBuilding,
        anilistID: Int?
    ) async throws -> SourceRoute {
        let context = try await pluginProvider.sourceRunnerContext(for: pluginID)
        return routeFactory.route(
            media: media,
            pluginID: pluginID,
            context: context,
            anilistID: anilistID
        )
    }

    public func resolve() {
        guard !isSearching, processingMatchIdentity == nil else { return }

        mappingOperationID = nil
        mappingCheckTask?.cancel()
        resolutionTask?.cancel()

        let request = SourceSearchRequest(
            canonicalProvider: canonicalProvider,
            canonicalMediaId: canonicalMediaId,
            mediaType: canonicalMediaType,
            preferredTitle: media.title,
            titleEnglish: media.titleEnglish,
            titleRomaji: media.titleRomaji,
            titleNative: media.titleNative,
            synonyms: media.synonyms
        )
        let operationID = UUID()
        resolutionOperationID = operationID
        isSearching = true
        state = .loading(matches: [])
        let repository = repository
        let pluginProvider = pluginProvider

        resolutionTask = Task { [weak self, repository, pluginProvider] in
            await Self.performResolution(
                request: request,
                repository: repository,
                pluginProvider: pluginProvider,
                isCurrent: { [weak self] in
                    self?.isCurrentResolution(operationID) == true
                },
                publish: { [weak self] publishedState in
                    guard self?.isCurrentResolution(operationID) == true else { return }
                    self?.state = publishedState
                },
                finish: { [weak self] in
                    self?.finishResolution(operationID: operationID)
                }
            )
        }
    }

    private static func performResolution(
        request: SourceSearchRequest,
        repository: any SourceMappingRepository,
        pluginProvider: any SourceResolverPluginProviding,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        publish: @escaping @MainActor @Sendable (State) -> Void,
        finish: @escaping @MainActor @Sendable () -> Void
    ) async {
        defer { finish() }

        do {
            let matchingPlugins = pluginProvider.installedPlugins.values.filter {
                $0.info.supportedKinds.contains(request.mediaType.mediaKind)
            }
            guard !matchingPlugins.isEmpty else {
                guard isCurrent() else { return }
                publish(.noCompatiblePlugins)
                return
            }

            var adapters: [any PluginSearching] = []
            for plugin in matchingPlugins {
                guard isCurrent() else { return }
                if let adapter = try? await pluginProvider.sourceSearchAdapter(
                    for: plugin.id,
                    mediaType: request.mediaType
                ) {
                    adapters.append(adapter)
                }
            }

            let records = try await repository.fetchAll(
                canonicalProvider: request.canonicalProvider,
                canonicalMediaId: request.canonicalMediaId,
                mediaType: request.mediaType
            )
            var rejectedKeysByPlugin: [String: Set<String>] = [:]
            for record in records where record.decision == .discard {
                rejectedKeysByPlugin[record.pluginId, default: []].insert(record.pluginMediaKey)
            }

            guard isCurrent() else { return }
            let resolver = SourceResolver(plugins: adapters)
            let result = await resolver.resolve(
                request: request,
                isRejected: { [rejectedKeysByPlugin] pluginID, key in
                    rejectedKeysByPlugin[pluginID]?.contains(key) ?? false
                }
            ) { partialMatches in
                guard isCurrent() else { return }
                publish(.loading(matches: partialMatches))
            }

            guard isCurrent() else { return }
            guard !result.isCancelled else {
                publish(.cancelled)
                return
            }

            if !result.pluginFailures.isEmpty {
                publish(.partialFailure(
                    matches: result.matches,
                    failedPlugins: result.pluginFailures.keys.sorted()
                ))
            } else if result.matches.isEmpty {
                publish(.empty)
            } else {
                publish(.completed(matches: result.matches))
            }
        } catch {
            guard isCurrent() else { return }
            publish(.fatalFailure(error: "Unable to search sources. Please try again."))
        }
    }

    private func finishResolution(operationID: UUID) {
        guard resolutionOperationID == operationID else { return }
        resolutionOperationID = nil
        resolutionTask = nil
        isSearching = false
    }

    private func isCurrentResolution(_ operationID: UUID) -> Bool {
        resolutionOperationID == operationID && !Task.isCancelled
    }

    public func setSavedSourceState(
        mapping: SourceMappingRecord,
        payload: ResolvedPluginMedia
    ) {
        state = .savedSource(mapping: mapping, payload: payload)
    }

    public func cancel() {
        resolutionOperationID = nil
        resolutionTask?.cancel()
        resolutionTask = nil
        isSearching = false
        state = .cancelled
    }

    func cancelOwnedOperations() {
        mappingOperationID = nil
        resolutionOperationID = nil
        actionOperationID = nil
        mappingCheckTask?.cancel()
        resolutionTask?.cancel()
        routePreparationTask?.cancel()
        rejectionTask?.cancel()
        mappingCheckTask = nil
        resolutionTask = nil
        routePreparationTask = nil
        rejectionTask = nil
        isSearching = false
        processingMatchIdentity = nil
        autoLinkTask?.cancel()
        autoLinkTask = nil
        linkingMediaIdentity = nil
    }

    public func checkExistingMapping() async -> (SourceMappingRecord, ResolvedPluginMedia)? {
        await Self.findExistingMapping(
            repository: repository,
            pluginProvider: pluginProvider,
            canonicalProvider: canonicalProvider,
            canonicalMediaID: canonicalMediaId,
            canonicalMediaType: canonicalMediaType
        )
    }

    private static func findExistingMapping(
        repository: any SourceMappingRepository,
        pluginProvider: any SourceResolverPluginProviding,
        canonicalProvider: String,
        canonicalMediaID: String,
        canonicalMediaType: PluginMediaType
    ) async -> (SourceMappingRecord, ResolvedPluginMedia)? {
        guard let confirmed = try? await repository.fetchConfirmed(
            canonicalProvider: canonicalProvider,
            canonicalMediaId: canonicalMediaID,
            mediaType: canonicalMediaType
        ) else {
            return nil
        }

        for mapping in confirmed {
            guard let payload = mapping.encodedPayload,
                  let version = mapping.payloadVersion,
                  let decoded = try? JSONDecoder().decode(SourceMediaSnapshot.self, from: payload),
                  decoded.version == version,
                  let plugin = pluginProvider.installedPlugins[mapping.pluginId] else {
                continue
            }

            guard decoded.payload.mediaType == canonicalMediaType else { continue }
            guard plugin.info.supportedKinds.contains(canonicalMediaType.mediaKind) else { continue }

            if let storedVersion = mapping.pluginVersion,
               plugin.info.version != storedVersion {
                continue
            }
            return (mapping, decoded.payload)
        }
        return nil
    }

    public func markMappingUsed(_ mapping: SourceMappingRecord) async {
        try? await repository.upsert(Self.verifiedMapping(mapping))
    }

    private static func verifiedMapping(_ mapping: SourceMappingRecord) -> SourceMappingRecord {
        SourceMappingRecord(
            canonicalProvider: mapping.canonicalProvider,
            canonicalMediaId: mapping.canonicalMediaId,
            mediaType: mapping.mediaType,
            pluginId: mapping.pluginId,
            pluginMediaKey: mapping.pluginMediaKey,
            decision: mapping.decision,
            matchMethod: mapping.matchMethod,
            confidence: mapping.confidence,
            titleSnapshot: mapping.titleSnapshot,
            createdAt: mapping.createdAt,
            updatedAt: mapping.updatedAt,
            coverURLSnapshot: mapping.coverURLSnapshot,
            encodedPayload: mapping.encodedPayload,
            payloadVersion: mapping.payloadVersion,
            pluginVersion: mapping.pluginVersion,
            lastVerifiedAt: Date()
        )
    }

    public func confirmAndRoute(match: MatchedSource) {
        guard processingMatchIdentity == nil else { return }
        stopResolutionForAction()
        beginConfirmAndRoute(match)
    }

    private func beginConfirmAndRoute(_ match: MatchedSource) {
        let identity = SourceMatchIdentity(match: match)
        let operationID = UUID()
        processingMatchIdentity = identity
        actionOperationID = operationID
        pluginSearchError = nil
        routePreparationTask?.cancel()
        let repository = repository
        let pluginProvider = pluginProvider
        let routeFactory = routeFactory
        let canonicalProvider = canonicalProvider
        let canonicalMediaID = canonicalMediaId
        let canonicalMediaType = canonicalMediaType
        let anilistID = canonicalProvider == "anilist" ? media.id : nil

        routePreparationTask = Task { [weak self, repository, pluginProvider, routeFactory] in
            var didPersist = false
            do {
                let mapping = try await Self.persistConfirmation(
                    match,
                    repository: repository,
                    canonicalProvider: canonicalProvider,
                    canonicalMediaID: canonicalMediaID,
                    canonicalMediaType: canonicalMediaType
                )
                didPersist = true
                guard self?.isCurrentAction(operationID, identity: identity) == true else {
                    return
                }
                self?.state = .savedSource(mapping: mapping, payload: match.media)

                let route = try await Self.prepareRoute(
                    media: match.media,
                    pluginID: match.pluginID,
                    pluginProvider: pluginProvider,
                    routeFactory: routeFactory,
                    anilistID: anilistID
                )
                guard self?.isCurrentAction(operationID, identity: identity) == true else {
                    return
                }
                self?.present(route: route)
                self?.finishAction(operationID, identity: identity)
            } catch is CancellationError {
                self?.finishAction(operationID, identity: identity)
            } catch {
                guard self?.isCurrentAction(operationID, identity: identity) == true else {
                    return
                }
                self?.pluginSearchError = didPersist
                    ? "The source was saved, but could not be opened. Try Open again."
                    : "The source could not be saved. Please try again."
                self?.finishAction(operationID, identity: identity)
            }
        }
    }

    func confirmAndPrepareRoute(_ match: MatchedSource) async throws {
        let mapping = try await confirmMatch(match)
        state = .savedSource(mapping: mapping, payload: match.media)
        let route = try await prepareRoute(media: match.media, pluginID: match.pluginID)
        try Task.checkCancellation()
        present(route: route)
    }

    public func openSavedSource(
        mapping: SourceMappingRecord,
        payload: ResolvedPluginMedia
    ) {
        guard processingMatchIdentity == nil else { return }
        let identity = SourceMatchIdentity(
            pluginID: mapping.pluginId,
            pluginVersion: mapping.pluginVersion,
            media: payload
        )
        let operationID = UUID()
        processingMatchIdentity = identity
        actionOperationID = operationID
        pluginSearchError = nil
        routePreparationTask?.cancel()
        let pluginProvider = pluginProvider
        let routeFactory = routeFactory
        let anilistID = canonicalProvider == "anilist" ? media.id : nil

        routePreparationTask = Task { [weak self, pluginProvider, routeFactory] in
            do {
                let route = try await Self.prepareRoute(
                    media: payload,
                    pluginID: mapping.pluginId,
                    pluginProvider: pluginProvider,
                    routeFactory: routeFactory,
                    anilistID: anilistID
                )
                guard self?.isCurrentAction(operationID, identity: identity) == true else {
                    return
                }
                self?.present(route: route)
                self?.finishAction(operationID, identity: identity)
            } catch is CancellationError {
                self?.finishAction(operationID, identity: identity)
            } catch {
                guard self?.isCurrentAction(operationID, identity: identity) == true else {
                    return
                }
                self?.pluginSearchError = "The saved source could not be opened. Please try again."
                self?.finishAction(operationID, identity: identity)
            }
        }
    }

    public func rejectAndMark(match: MatchedSource) {
        guard processingMatchIdentity == nil else { return }
        stopResolutionForAction()
        let identity = SourceMatchIdentity(match: match)
        let operationID = UUID()
        processingMatchIdentity = identity
        actionOperationID = operationID
        pluginSearchError = nil
        rejectionTask?.cancel()
        let repository = repository
        let canonicalProvider = canonicalProvider
        let canonicalMediaID = canonicalMediaId
        let canonicalMediaType = canonicalMediaType

        rejectionTask = Task { [weak self, repository] in
            do {
                try await Self.persistRejection(
                    match,
                    repository: repository,
                    canonicalProvider: canonicalProvider,
                    canonicalMediaID: canonicalMediaID,
                    canonicalMediaType: canonicalMediaType
                )
                guard self?.isCurrentAction(operationID, identity: identity) == true else {
                    return
                }
                self?.markRejected(identity: identity)
                self?.finishAction(operationID, identity: identity)
            } catch is CancellationError {
                self?.finishAction(operationID, identity: identity)
            } catch {
                guard self?.isCurrentAction(operationID, identity: identity) == true else {
                    return
                }
                self?.pluginSearchError = "The source rejection could not be saved. Please try again."
                self?.finishAction(operationID, identity: identity)
            }
        }
    }

    private func isCurrentAction(
        _ operationID: UUID,
        identity: SourceMatchIdentity
    ) -> Bool {
        actionOperationID == operationID
            && processingMatchIdentity == identity
            && !Task.isCancelled
    }

    private func finishAction(
        _ operationID: UUID,
        identity: SourceMatchIdentity
    ) {
        guard actionOperationID == operationID,
              processingMatchIdentity == identity else {
            return
        }
        actionOperationID = nil
        processingMatchIdentity = nil
        routePreparationTask = nil
        rejectionTask = nil
    }

    @discardableResult
    func confirmMatch(_ match: MatchedSource) async throws -> SourceMappingRecord {
        try await Self.persistConfirmation(
            match,
            repository: repository,
            canonicalProvider: canonicalProvider,
            canonicalMediaID: canonicalMediaId,
            canonicalMediaType: canonicalMediaType
        )
    }

    private static func persistConfirmation(
        _ match: MatchedSource,
        repository: any SourceMappingRepository,
        canonicalProvider: String,
        canonicalMediaID: String,
        canonicalMediaType: PluginMediaType
    ) async throws -> SourceMappingRecord {
        let snapshot = SourceMediaSnapshot(version: 1, payload: match.media)
        let payload = try JSONEncoder().encode(snapshot)

        let mediaKey = match.media.key()
        let title = match.media.title()
        let coverURL = match.media.cover()

        let now = Date()
        let record = SourceMappingRecord(
            canonicalProvider: canonicalProvider,
            canonicalMediaId: canonicalMediaID,
            mediaType: canonicalMediaType,
            pluginId: match.pluginID,
            pluginMediaKey: mediaKey,
            decision: .autoConfirm,
            matchMethod: match.matchMethod,
            confidence: match.score,
            titleSnapshot: title,
            createdAt: now,
            updatedAt: now,
            coverURLSnapshot: coverURL,
            encodedPayload: payload,
            payloadVersion: 1,
            pluginVersion: match.pluginVersion,
            lastVerifiedAt: now
        )
        try await repository.upsert(record)
        return record
    }

    func rejectMatch(_ match: MatchedSource) async throws {
        let identity = SourceMatchIdentity(match: match)
        try await persistRejection(match)
        markRejected(identity: identity)
    }

    private func persistRejection(_ match: MatchedSource) async throws {
        try await Self.persistRejection(
            match,
            repository: repository,
            canonicalProvider: canonicalProvider,
            canonicalMediaID: canonicalMediaId,
            canonicalMediaType: canonicalMediaType
        )
    }

    private static func persistRejection(
        _ match: MatchedSource,
        repository: any SourceMappingRepository,
        canonicalProvider: String,
        canonicalMediaID: String,
        canonicalMediaType: PluginMediaType
    ) async throws {
        try await repository.persistRejection(
            canonicalProvider: canonicalProvider,
            canonicalMediaId: canonicalMediaID,
            mediaType: canonicalMediaType,
            pluginId: match.pluginID,
            pluginMediaKey: match.media.key()
        )
    }

    private func markRejected(identity: SourceMatchIdentity) {
        switch state {
        case .loading(let matches):
            state = .loading(matches: markingRejected(identity, in: matches))
        case .completed(let matches):
            state = .completed(matches: markingRejected(identity, in: matches))
        case .partialFailure(let matches, let failedPlugins):
            state = .partialFailure(
                matches: markingRejected(identity, in: matches),
                failedPlugins: failedPlugins
            )
        default:
            break
        }
    }

    private func markingRejected(
        _ identity: SourceMatchIdentity,
        in matches: [MatchedSource]
    ) -> [MatchedSource] {
        matches.map { match in
            guard SourceMatchIdentity(match: match) == identity else { return match }
            return MatchedSource(
                pluginID: match.pluginID,
                pluginVersion: match.pluginVersion,
                media: match.media,
                matchMethod: match.matchMethod,
                score: match.score,
                decision: .discard
            )
        }
    }

    private func stopResolutionForAction() {
        resolutionOperationID = nil
        resolutionTask?.cancel()
        resolutionTask = nil
        isSearching = false
        if case .loading(let matches) = state, !matches.isEmpty {
            state = .completed(matches: matches)
        }
    }
}

public extension MatchedSource {
    var sourceIdentity: SourceMatchIdentity {
        SourceMatchIdentity(match: self)
    }
}
