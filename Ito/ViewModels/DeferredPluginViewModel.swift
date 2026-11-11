import Combine
import Foundation
import ito_runner
import UIKit

enum DeferredPluginFailure: Equatable {
    case packageLookup
    case pluginTypeMismatch
    case install
    case runnerLoad
    case payloadDecode
}

/// What the Library row itself saved about a series, shown when its payload can't be decoded.
struct DeferredSavedFields: Equatable {
    let title: String
    let coverURL: URL?
}

enum DeferredPluginDestination {
    /// `runner` is nil for a saved-only series, whose installed source is missing or cannot be loaded.
    case manga(pluginID: String, runner: ItoRunner?, media: Manga)
    case anime(pluginID: String, runner: ItoRunner, media: Anime)
    case novel(pluginID: String, runner: ItoRunner?, media: Novel)

    var pluginID: String {
        switch self {
        case .manga(let pluginID, _, _),
             .anime(let pluginID, _, _),
             .novel(let pluginID, _, _):
            return pluginID
        }
    }

    var runner: ItoRunner? {
        switch self {
        case .manga(_, let runner, _),
             .novel(_, let runner, _):
            return runner
        case .anime(_, let runner, _):
            return runner
        }
    }
}

private extension DeferredPluginMedia {
    var pluginType: MediaKind {
        switch self {
        case .manga: return .manga
        case .anime: return .anime
        case .novel: return .novel
        }
    }

    var mediaKey: String {
        switch self {
        case .manga(let manga): return manga.key
        case .anime(let anime): return anime.key
        case .novel(let novel): return novel.key
        }
    }
}

struct DeferredPluginRoute: Identifiable {
    let id: UUID
    let destination: DeferredPluginDestination
    /// What the series screen opens once loaded. Only the first route carries it, so a route
    /// rebuilt later (returning to the screen, a plugin update) does not open the reader again.
    let openIntent: MediaDetailOpenIntent?
}

enum DeferredPluginPhase {
    case idle
    case decoding
    case loadingRunner
    case loadingSavedDetails
    case pluginMissing
    case checkingPackage
    case packageUnavailable
    case incompatible(PluginIncompatibility)
    case installing
    case ready(DeferredPluginRoute)
    case failure(DeferredPluginFailure)
    case cancelled
}

@MainActor
final class DeferredPluginViewModel: ObservableObject {
    let item: LibraryItem

    @Published private(set) var phase: DeferredPluginPhase = .idle
    /// Why the installed source refused to load. Set only while `phase` is `.failure(.runnerLoad)`, and cleared by
    /// every new operation, so a retry or a new publication never shows a stale direction.
    @Published private(set) var runnerRefusal: PluginIncompatibility?
    /// Why the install was refused. Set only while `phase` is `.failure(.install)`.
    @Published private(set) var installRefusal: PluginIncompatibility?

    private let plugins: any LibraryPluginServing
    private let installer: any DeferredPluginInstalling
    private let payloadDecoder: any DeferredPluginPayloadDecoding
    private let offlineReading: any OfflineChapterReading
    private let coverThumbnails: any LibraryCoverThumbnailServing
    private let presentationLogger: any PresentationEventLogging

    private var pluginSnapshot: LibraryPluginSnapshot
    private var decodedMedia: DeferredPluginMedia?
    private var hasCurrentInstallCompleted = false
    private var generation: UInt = 0
    private var isPresentationActive = false
    private var decodeTask: Task<Void, Never>?
    private var packageLookupTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var runnerTask: Task<Void, Never>?
    private var savedDetailsTask: Task<Void, Never>?
    private var pendingOpenIntent: MediaDetailOpenIntent?
    private var cancellables: Set<AnyCancellable> = []

    init(
        item: LibraryItem,
        openIntent: MediaDetailOpenIntent? = nil,
        plugins: any LibraryPluginServing,
        installer: any DeferredPluginInstalling,
        payloadDecoder: any DeferredPluginPayloadDecoding,
        offlineReading: any OfflineChapterReading = UnavailableOfflineChapterReading(),
        coverThumbnails: any LibraryCoverThumbnailServing = UnavailableLibraryCoverThumbnails(),
        presentationLogger: any PresentationEventLogging
    ) {
        self.item = item
        pendingOpenIntent = openIntent
        self.plugins = plugins
        self.installer = installer
        self.payloadDecoder = payloadDecoder
        self.offlineReading = offlineReading
        self.coverThumbnails = coverThumbnails
        self.presentationLogger = presentationLogger
        pluginSnapshot = plugins.libraryPluginSnapshot

        plugins.libraryPluginSnapshotPublisher
            .sink { [weak self] snapshot in
                self?.applyInstalledPluginPublication(snapshot)
            }
            .store(in: &cancellables)
    }

    deinit {
        decodeTask?.cancel()
        packageLookupTask?.cancel()
        installTask?.cancel()
        runnerTask?.cancel()
        savedDetailsTask?.cancel()
    }

    var route: DeferredPluginRoute? {
        guard case .ready(let route) = phase else { return nil }
        return route
    }

    /// The Library row's own saved fields, while its payload can't be decoded. The row stays in the
    /// Library; this only lets the failure screen say which series it is.
    var savedFieldsFallback: DeferredSavedFields? {
        guard case .failure(.payloadDecode) = phase, decodedMedia == nil else { return nil }
        return DeferredSavedFields(title: item.title, coverURL: item.coverUrl.flatMap { URL(string: $0) })
    }

    /// The cover this device saved for the row, used only while it was captured for the row's current cover
    /// address, as the Library card does.
    func savedCover() async -> UIImage? {
        guard let coverUrl = item.coverUrl else { return nil }
        return await coverThumbnails.thumbnail(itemID: item.id, coverUrl: coverUrl)?.image
    }

    var isBusy: Bool {
        switch phase {
        case .decoding, .loadingRunner, .checkingPackage, .installing, .loadingSavedDetails:
            return true
        case .idle, .pluginMissing, .packageUnavailable, .incompatible,
             .ready, .failure, .cancelled:
            return false
        }
    }

    func appear() {
        guard !isPresentationActive else { return }
        isPresentationActive = true
        switch phase {
        case .idle, .cancelled:
            beginDecode()
        case .decoding, .loadingRunner, .pluginMissing, .checkingPackage,
             .packageUnavailable, .incompatible, .installing, .ready, .failure, .loadingSavedDetails:
            break
        }
    }

    func disappear() {
        guard isPresentationActive else { return }
        isPresentationActive = false
        generation &+= 1
        cancelSupersedableTasks()
        runnerRefusal = nil
        installRefusal = nil
        phase = .cancelled
    }

    func retry() {
        guard isPresentationActive else { return }
        switch phase {
        case .failure(.packageLookup), .failure(.install), .packageUnavailable:
            installMissingPlugin()
        case .failure(.pluginTypeMismatch):
            if pluginSnapshot.plugins[item.pluginId] == nil {
                installMissingPlugin()
            } else {
                beginDecode()
            }
        case .failure(.runnerLoad), .failure(.payloadDecode), .cancelled:
            beginDecode()
        case .idle:
            beginDecode()
        case .decoding, .loadingRunner, .pluginMissing, .checkingPackage,
             .incompatible, .installing, .ready, .loadingSavedDetails:
            break
        }
    }

    func installMissingPlugin() {
        guard isPresentationActive else { return }
        switch phase {
        case .pluginMissing, .packageUnavailable, .failure(.packageLookup),
             .failure(.pluginTypeMismatch), .failure(.install):
            break
        case .idle, .decoding, .loadingRunner, .checkingPackage, .incompatible,
             .installing, .ready, .failure(.runnerLoad), .failure(.payloadDecode),
             .cancelled, .loadingSavedDetails:
            return
        }

        beginNewGeneration()
        let operationGeneration = generation
        let operationID = UUID()
        phase = .checkingPackage
        logStarted(kind: .remoteLoad, operationID: operationID)
        let installer = self.installer
        let pluginID = item.pluginId
        packageLookupTask = Task { @MainActor [weak self, installer] in
            do {
                let candidate = try await installer.findPackage(forExactPluginID: pluginID)
                guard let self,
                      self.isCurrent(operationGeneration) else {
                    self?.logFinished(
                        kind: .remoteLoad,
                        operationID: operationID,
                        outcome: .ignoredStale
                    )
                    return
                }
                self.packageLookupTask = nil
                guard let candidate,
                      candidate.package.id == pluginID else {
                    self.phase = .packageUnavailable
                    self.logFinished(
                        kind: .remoteLoad,
                        operationID: operationID,
                        outcome: .failed(.pluginUnavailable)
                    )
                    return
                }
                guard candidate.supportedKinds.contains(self.item.effectiveType) else {
                    self.phase = .failure(.pluginTypeMismatch)
                    self.logFinished(
                        kind: .remoteLoad,
                        operationID: operationID,
                        outcome: .failed(.pluginUnavailable)
                    )
                    return
                }
                if let refusal = candidate.incompatibility {
                    self.phase = .incompatible(refusal)
                    self.logFinished(
                        kind: .remoteLoad,
                        operationID: operationID,
                        outcome: .failed(.pluginUnavailable)
                    )
                    return
                }
                self.logFinished(
                    kind: .remoteLoad,
                    operationID: operationID,
                    outcome: .succeeded
                )
                self.beginInstall(candidate, operationGeneration: operationGeneration)
            } catch {
                guard let self,
                      self.isCurrent(operationGeneration) else {
                    self?.logFinished(
                        kind: .remoteLoad,
                        operationID: operationID,
                        outcome: .ignoredStale
                    )
                    return
                }
                self.packageLookupTask = nil
                self.phase = .failure(.packageLookup)
                self.logFinished(
                    kind: .remoteLoad,
                    operationID: operationID,
                    outcome: .failed(.network)
                )
            }
        }
    }

    private func beginDecode() {
        beginNewGeneration()
        let operationGeneration = generation
        let operationID = UUID()
        phase = .decoding
        decodedMedia = nil
        logStarted(kind: .payloadDecode, operationID: operationID)
        let decoder = payloadDecoder
        let item = self.item
        decodeTask = Task { @MainActor [weak self, decoder] in
            do {
                let media = try await decoder.decode(item)
                guard let self,
                      self.isCurrent(operationGeneration) else {
                    self?.logFinished(
                        kind: .payloadDecode,
                        operationID: operationID,
                        outcome: .ignoredStale
                    )
                    return
                }
                self.decodeTask = nil
                guard media.pluginType == item.effectiveType else {
                    self.phase = .failure(.payloadDecode)
                    self.logFinished(
                        kind: .payloadDecode,
                        operationID: operationID,
                        outcome: .failed(.pluginExecution)
                    )
                    return
                }
                self.decodedMedia = media
                self.logFinished(
                    kind: .payloadDecode,
                    operationID: operationID,
                    outcome: .succeeded
                )
                if let plugin = self.pluginSnapshot.plugins[item.pluginId] {
                    guard plugin.supportedKinds.contains(item.effectiveType) else {
                        self.phase = .failure(.pluginTypeMismatch)
                        return
                    }
                    self.beginRunnerLoad(
                        media: media,
                        plugin: plugin,
                        publicationRevision: self.pluginSnapshot.publicationRevision,
                        operationGeneration: operationGeneration
                    )
                } else {
                    self.phase = .pluginMissing
                }
            } catch {
                guard let self,
                      self.isCurrent(operationGeneration) else {
                    self?.logFinished(
                        kind: .payloadDecode,
                        operationID: operationID,
                        outcome: .ignoredStale
                    )
                    return
                }
                self.decodeTask = nil
                self.phase = .failure(.payloadDecode)
                self.logFinished(
                    kind: .payloadDecode,
                    operationID: operationID,
                    outcome: .failed(.pluginExecution)
                )
            }
        }
    }

    private func beginInstall(
        _ candidate: DeferredPluginPackageCandidate,
        operationGeneration: UInt
    ) {
        guard isCurrent(operationGeneration), installTask == nil else { return }
        hasCurrentInstallCompleted = false
        let operationID = UUID()
        phase = .installing
        logStarted(kind: .pluginInstall, operationID: operationID)
        let installer = self.installer
        installTask = Task { @MainActor [weak self, installer] in
            do {
                try await installer.install(candidate)
                guard let self,
                      self.isCurrent(operationGeneration) else {
                    self?.logFinished(
                        kind: .pluginInstall,
                        operationID: operationID,
                        outcome: .ignoredStale
                    )
                    return
                }
                self.installTask = nil
                self.hasCurrentInstallCompleted = true
                self.logFinished(
                    kind: .pluginInstall,
                    operationID: operationID,
                    outcome: .succeeded
                )
                if let plugin = self.pluginSnapshot.plugins[self.item.pluginId],
                   plugin.supportedKinds.contains(self.item.effectiveType),
                   let media = self.decodedMedia {
                    self.beginRunnerLoad(
                        media: media,
                        plugin: plugin,
                        publicationRevision: self.pluginSnapshot.publicationRevision,
                        operationGeneration: operationGeneration
                    )
                }
                // Otherwise remain installing until authoritative publication arrives.
            } catch {
                guard let self,
                      self.isCurrent(operationGeneration) else {
                    self?.logFinished(
                        kind: .pluginInstall,
                        operationID: operationID,
                        outcome: .ignoredStale
                    )
                    return
                }
                self.installTask = nil
                self.installRefusal = error as? PluginIncompatibility
                self.phase = .failure(.install)
                self.logFinished(
                    kind: .pluginInstall,
                    operationID: operationID,
                    outcome: .failed(.persistence)
                )
            }
        }
    }

    private func beginRunnerLoad(
        media: DeferredPluginMedia,
        plugin: LibraryInstalledPluginIdentity,
        publicationRevision: UInt64,
        operationGeneration: UInt
    ) {
        guard isCurrent(operationGeneration), runnerTask == nil else { return }
        let operationID = UUID()
        runnerRefusal = nil
        phase = .loadingRunner
        logStarted(kind: .runnerLoad, operationID: operationID)
        let plugins = self.plugins
        let pluginID = plugin.id
        runnerTask = Task { @MainActor [weak self, plugins] in
            do {
                let runner = try await plugins.libraryRunner(
                    for: plugin,
                    publicationRevision: publicationRevision
                )
                guard let self,
                      self.isCurrent(operationGeneration),
                      self.pluginSnapshot.publicationRevision == publicationRevision,
                      self.pluginSnapshot.plugins[pluginID] == plugin else {
                    self?.logFinished(
                        kind: .runnerLoad,
                        operationID: operationID,
                        outcome: .ignoredStale
                    )
                    return
                }
                self.runnerTask = nil
                self.phase = .ready(
                    DeferredPluginRoute(
                        id: UUID(),
                        destination: Self.destination(
                            pluginID: pluginID,
                            runner: runner,
                            media: media
                        ),
                        openIntent: self.takeOpenIntent()
                    )
                )
                self.logFinished(
                    kind: .runnerLoad,
                    operationID: operationID,
                    outcome: .succeeded
                )
            } catch {
                guard let self,
                      self.isCurrent(operationGeneration) else {
                    self?.logFinished(
                        kind: .runnerLoad,
                        operationID: operationID,
                        outcome: .ignoredStale
                    )
                    return
                }
                self.runnerTask = nil
                self.runnerRefusal = error as? PluginIncompatibility
                self.phase = .failure(.runnerLoad)
                self.logFinished(
                    kind: .runnerLoad,
                    operationID: operationID,
                    outcome: .failed(.pluginExecution)
                )
            }
        }
    }

    private func takeOpenIntent() -> MediaDetailOpenIntent? {
        defer { pendingOpenIntent = nil }
        return pendingOpenIntent
    }

    private func applyInstalledPluginPublication(_ snapshot: LibraryPluginSnapshot) {
        let previousRevision = pluginSnapshot.publicationRevision
        let previousPlugin = pluginSnapshot.plugins[item.pluginId]
        pluginSnapshot = snapshot
        guard isPresentationActive,
              snapshot.publicationRevision != previousRevision else { return }

        guard let plugin = snapshot.plugins[item.pluginId] else {
            guard previousPlugin != nil else { return }
            switch phase {
            case .decoding:
                break
            case .idle, .pluginMissing, .packageUnavailable, .incompatible,
                 .failure(.packageLookup), .failure(.pluginTypeMismatch),
                 .failure(.install), .failure(.payloadDecode), .cancelled, .loadingSavedDetails:
                break
            case .checkingPackage, .installing, .loadingRunner, .ready,
                 .failure(.runnerLoad):
                beginNewGeneration()
                phase = .pluginMissing
            }
            return
        }

        guard plugin.supportedKinds.contains(item.effectiveType) else {
            beginNewGeneration()
            phase = .failure(.pluginTypeMismatch)
            return
        }
        guard let decodedMedia else { return }

        switch phase {
        case .installing:
            if hasCurrentInstallCompleted {
                beginRunnerLoad(
                    media: decodedMedia,
                    plugin: plugin,
                    publicationRevision: snapshot.publicationRevision,
                    operationGeneration: generation
                )
            }
        case .idle, .decoding, .failure(.payloadDecode), .cancelled, .loadingSavedDetails:
            break
        case .pluginMissing, .checkingPackage, .packageUnavailable, .incompatible,
             .loadingRunner, .ready, .failure(.packageLookup),
             .failure(.pluginTypeMismatch), .failure(.install), .failure(.runnerLoad):
            beginNewGeneration()
            beginRunnerLoad(
                media: decodedMedia,
                plugin: plugin,
                publicationRevision: snapshot.publicationRevision,
                operationGeneration: generation
            )
        }
    }

    /// Whether the saved series can open without an installed source: a manga or novel, from a phase where
    /// the source is missing, unavailable, or failed to load, on a build that composes offline copies.
    /// Anime has no saved-only route.
    var canOpenSavedDetails: Bool {
        guard offlineReading.isAvailable,
              let decodedMedia, decodedMedia.pluginType != .anime else { return false }
        switch phase {
        case .pluginMissing, .packageUnavailable, .incompatible,
             .failure(.packageLookup), .failure(.install), .failure(.runnerLoad):
            return true
        case .idle, .decoding, .loadingRunner, .checkingPackage, .installing,
             .loadingSavedDetails, .ready, .failure(.pluginTypeMismatch),
             .failure(.payloadDecode), .cancelled:
            return false
        }
    }

    /// Opens the saved series without an installed source: the saved payload's chapters, plus the
    /// downloaded chapters that the payload does not list.
    func openSavedDetails() {
        guard isPresentationActive, canOpenSavedDetails, let media = decodedMedia else { return }
        beginNewGeneration()
        let operationGeneration = generation
        phase = .loadingSavedDetails
        let reader = offlineReading
        let pluginID = item.pluginId
        savedDetailsTask = Task { @MainActor [weak self, reader] in
            let inventory = await reader.inventoryChapters(
                pluginId: pluginID,
                mediaKind: media.pluginType,
                canonicalMediaId: media.mediaKey
            )
            guard let self, self.isCurrent(operationGeneration) else { return }
            self.savedDetailsTask = nil
            guard let destination = Self.savedDestination(
                pluginID: pluginID,
                media: media,
                inventory: inventory
            ) else {
                self.phase = .failure(.payloadDecode)
                return
            }
            self.phase = .ready(
                DeferredPluginRoute(id: UUID(), destination: destination, openIntent: self.takeOpenIntent())
            )
        }
    }

    private static func savedDestination(
        pluginID: String,
        media: DeferredPluginMedia,
        inventory: [DownloadedChapterRecord]
    ) -> DeferredPluginDestination? {
        switch media {
        case .manga(var manga):
            manga.chapters = SavedChapterMerge.merged(manga.chapters, inventory: inventory)
            return .manga(pluginID: pluginID, runner: nil, media: manga)
        case .novel(var novel):
            novel.chapters = SavedChapterMerge.merged(novel.chapters, inventory: inventory)
            return .novel(pluginID: pluginID, runner: nil, media: novel)
        case .anime:
            return nil
        }
    }

    private func beginNewGeneration() {
        generation &+= 1
        hasCurrentInstallCompleted = false
        runnerRefusal = nil
        installRefusal = nil
        cancelSupersedableTasks()
    }

    private func cancelSupersedableTasks() {
        decodeTask?.cancel()
        decodeTask = nil
        packageLookupTask?.cancel()
        packageLookupTask = nil
        installTask?.cancel()
        installTask = nil
        runnerTask?.cancel()
        runnerTask = nil
        savedDetailsTask?.cancel()
        savedDetailsTask = nil
    }

    private func isCurrent(_ operationGeneration: UInt) -> Bool {
        isPresentationActive && generation == operationGeneration
    }

    private static func destination(
        pluginID: String,
        runner: ItoRunner,
        media: DeferredPluginMedia
    ) -> DeferredPluginDestination {
        switch media {
        case .manga(let manga):
            return .manga(pluginID: pluginID, runner: runner, media: manga)
        case .anime(let anime):
            return .anime(pluginID: pluginID, runner: runner, media: anime)
        case .novel(let novel):
            return .novel(pluginID: pluginID, runner: runner, media: novel)
        }
    }

    private func logStarted(kind: PresentationEventKind, operationID: UUID) {
        presentationLogger.log(
            .started(feature: .deferredPlugin, kind: kind, operationID: operationID)
        )
    }

    private func logFinished(
        kind: PresentationEventKind,
        operationID: UUID,
        outcome: PresentationEventOutcome
    ) {
        presentationLogger.log(
            .finished(
                feature: .deferredPlugin,
                kind: kind,
                operationID: operationID,
                outcome: outcome
            )
        )
    }
}
