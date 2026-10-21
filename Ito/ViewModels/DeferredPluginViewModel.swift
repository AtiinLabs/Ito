import Combine
import Foundation
import ito_runner

enum DeferredPluginFailure: Equatable {
    case packageLookup
    case pluginTypeMismatch
    case install
    case runnerLoad
    case payloadDecode
}

enum DeferredPluginDestination {
    case manga(pluginID: String, runner: ItoRunner, media: Manga)
    case anime(pluginID: String, runner: ItoRunner, media: Anime)
    case novel(pluginID: String, runner: ItoRunner, media: Novel)

    var pluginID: String {
        switch self {
        case .manga(let pluginID, _, _),
             .anime(let pluginID, _, _),
             .novel(let pluginID, _, _):
            return pluginID
        }
    }

    var runner: ItoRunner {
        switch self {
        case .manga(_, let runner, _),
             .anime(_, let runner, _),
             .novel(_, let runner, _):
            return runner
        }
    }
}

private extension DeferredPluginMedia {
    var pluginType: PluginType {
        switch self {
        case .manga: return .manga
        case .anime: return .anime
        case .novel: return .novel
        }
    }
}

struct DeferredPluginRoute: Identifiable {
    let id: UUID
    let destination: DeferredPluginDestination
}

enum DeferredPluginPhase {
    case idle
    case decoding
    case loadingRunner
    case pluginMissing
    case checkingPackage
    case packageUnavailable
    case incompatible(minimumVersion: String?)
    case installing
    case ready(DeferredPluginRoute)
    case failure(DeferredPluginFailure)
    case cancelled
}

@MainActor
final class DeferredPluginViewModel: ObservableObject {
    let item: LibraryItem

    @Published private(set) var phase: DeferredPluginPhase = .idle

    private let plugins: any LibraryPluginServing
    private let installer: any DeferredPluginInstalling
    private let payloadDecoder: any DeferredPluginPayloadDecoding
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
    private var cancellables: Set<AnyCancellable> = []

    init(
        item: LibraryItem,
        plugins: any LibraryPluginServing,
        installer: any DeferredPluginInstalling,
        payloadDecoder: any DeferredPluginPayloadDecoding,
        presentationLogger: any PresentationEventLogging
    ) {
        self.item = item
        self.plugins = plugins
        self.installer = installer
        self.payloadDecoder = payloadDecoder
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
    }

    var route: DeferredPluginRoute? {
        guard case .ready(let route) = phase else { return nil }
        return route
    }

    var isBusy: Bool {
        switch phase {
        case .decoding, .loadingRunner, .checkingPackage, .installing:
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
             .packageUnavailable, .incompatible, .installing, .ready, .failure:
            break
        }
    }

    func disappear() {
        guard isPresentationActive else { return }
        isPresentationActive = false
        generation &+= 1
        cancelSupersedableTasks()
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
             .incompatible, .installing, .ready:
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
             .cancelled:
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
                guard candidate.pluginType == self.item.effectiveType else {
                    self.phase = .failure(.pluginTypeMismatch)
                    self.logFinished(
                        kind: .remoteLoad,
                        operationID: operationID,
                        outcome: .failed(.pluginUnavailable)
                    )
                    return
                }
                if let refusal = candidate.incompatibility {
                    self.phase = .incompatible(minimumVersion: refusal.minimumAppVersion)
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
                    guard plugin.pluginType == item.effectiveType else {
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
                   plugin.pluginType == self.item.effectiveType,
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
                        )
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
                self.phase = .failure(.runnerLoad)
                self.logFinished(
                    kind: .runnerLoad,
                    operationID: operationID,
                    outcome: .failed(.pluginExecution)
                )
            }
        }
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
                 .failure(.install), .failure(.payloadDecode), .cancelled:
                break
            case .checkingPackage, .installing, .loadingRunner, .ready,
                 .failure(.runnerLoad):
                beginNewGeneration()
                phase = .pluginMissing
            }
            return
        }

        guard plugin.pluginType == item.effectiveType else {
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
        case .idle, .decoding, .failure(.payloadDecode), .cancelled:
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

    private func beginNewGeneration() {
        generation &+= 1
        hasCurrentInstallCompleted = false
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
