import Combine
import Foundation

enum TrackerSettingsOperationKind: Equatable {
    case authentication
    case logout
}

enum TrackerSettingsProviderFailure: Equatable {
    case authentication
    case tokenRejected
    case logout

    var message: String {
        switch self {
        case .authentication:
            return "Authentication failed. Please try again."
        case .tokenRejected:
            return "The token was not accepted. Check that it was copied completely and has not been revoked."
        case .logout:
            return "Logout failed. Please try again."
        }
    }
}

@MainActor
final class TrackerSettingsViewModel: ObservableObject {
    @Published private(set) var credentialState: TrackerSettingsCredentialState
    @Published private(set) var providers: [TrackerProviderPresentation]
    @Published private(set) var operatingProviderID: String?
    @Published private(set) var operationKind: TrackerSettingsOperationKind?
    @Published private(set) var providerFailures: [String: TrackerSettingsProviderFailure] = [:]
    /// The token-based tracker whose sign-in sheet is shown.
    @Published var signInSheetProvider: TrackerProviderPresentation?
    @Published var syncTrackersToLocal: Bool {
        didSet {
            guard !isPublishingAuthoritativePreference else { return }
            persistSyncTrackersToLocal(syncTrackersToLocal)
        }
    }
    @Published private(set) var isPersistingPreference = false

    private struct AuthenticationOperation {
        let id: UUID
        let providerID: String
        let kind: TrackerSettingsOperationKind
    }

    private let service: any TrackerSettingsServicing
    private let settingsStore: any TrackerSettingsPreferenceStoring
    private let messagePresenter: any TrackingMessagePresenting
    private let presentationLogger: any PresentationEventLogging
    private var authenticationOperation: AuthenticationOperation?
    private var authenticationTask: Task<Void, Never>?
    private var preferenceOperationID: UUID?
    private var preferenceWriteTask: Task<Void, Never>?
    private var isPublishingAuthoritativePreference = false
    private var cancellables = Set<AnyCancellable>()

    init(
        service: any TrackerSettingsServicing,
        settingsStore: any TrackerSettingsPreferenceStoring,
        messagePresenter: any TrackingMessagePresenting,
        presentationLogger: any PresentationEventLogging
    ) {
        self.service = service
        self.settingsStore = settingsStore
        self.messagePresenter = messagePresenter
        self.presentationLogger = presentationLogger

        let state = service.settingsState
        credentialState = state.credentialState
        providers = state.providers
        syncTrackersToLocal = settingsStore.autoSyncTrackersToLocal

        service.settingsStatePublisher
            .sink { [weak self] state in
                self?.apply(state)
            }
            .store(in: &cancellables)
    }

    var isAuthenticationOperationActive: Bool {
        authenticationOperation != nil
    }

    func footer(for provider: TrackerProviderPresentation) -> String {
        switch provider.identifier {
        case MALCredentialRepository.providerID:
            return "Ito updates progress for series you are watching or reading on MyAnimeList. It never deletes entries, lowers progress, or changes scores, dates, tags or comments."
        case MangaBakaCredentialRepository.providerID:
            return "Ito updates chapter progress for manga and novels you are reading on MangaBaka. Ratings, dates and notes are left as they are. Series data from MangaBaka is licensed CC BY-NC-SA 4.0."
        default:
            return "Sync your progress automatically with \(provider.name)."
        }
    }

    func failure(for providerID: String) -> TrackerSettingsProviderFailure? {
        providerFailures[providerID]
    }

    func refreshAuthoritativeState() {
        service.refreshSettingsState()
        apply(service.settingsState)
        if preferenceOperationID == nil {
            publishAuthoritativePreference()
        }
    }

    /// Starts sign-in: the OAuth flow, or the token sheet for trackers that use tokens.
    func authenticate(providerID: String) {
        if let provider = providers.first(where: { $0.identifier == providerID }), provider.tokenCreationURL != nil {
            guard authenticationOperation == nil else { return }
            signInSheetProvider = provider
            return
        }
        startAuthenticationOperation(providerID: providerID, kind: .authentication)
    }

    /// Signs in to a token-based tracker with the token from the sign-in sheet.
    func signIn(providerID: String, token: String) {
        signInSheetProvider = nil
        startAuthenticationOperation(providerID: providerID, kind: .authentication, token: token)
    }

    func logout(providerID: String) {
        startAuthenticationOperation(providerID: providerID, kind: .logout)
    }

    func setSyncTrackersToLocal(_ proposedValue: Bool) {
        guard syncTrackersToLocal != proposedValue else { return }
        syncTrackersToLocal = proposedValue
    }

    private func persistSyncTrackersToLocal(_ proposedValue: Bool) {
        let operationID = UUID()
        let precedingWrite = preferenceWriteTask
        preferenceOperationID = operationID
        isPersistingPreference = true
        presentationLogger.log(
            .started(
                feature: .trackingSettings,
                kind: .preferenceWrite,
                operationID: operationID
            )
        )

        preferenceWriteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let precedingWrite {
                await precedingWrite.value
            }
            do {
                try await settingsStore.setAutoSyncTrackersToLocal(proposedValue)
                guard preferenceOperationID == operationID else {
                    logIgnoredStale(kind: .preferenceWrite, operationID: operationID)
                    return
                }
                publishAuthoritativePreference()
                isPersistingPreference = false
                preferenceOperationID = nil
                preferenceWriteTask = nil
                presentationLogger.log(
                    .finished(
                        feature: .trackingSettings,
                        kind: .preferenceWrite,
                        operationID: operationID,
                        outcome: .succeeded
                    )
                )
            } catch {
                guard preferenceOperationID == operationID else {
                    logIgnoredStale(kind: .preferenceWrite, operationID: operationID)
                    return
                }
                publishAuthoritativePreference()
                isPersistingPreference = false
                preferenceOperationID = nil
                preferenceWriteTask = nil
                messagePresenter.present(.preferencePersistenceFailed)
                presentationLogger.log(
                    .finished(
                        feature: .trackingSettings,
                        kind: .preferenceWrite,
                        operationID: operationID,
                        outcome: .failed(.persistence)
                    )
                )
            }
        }
    }

    func cancelOwnedWork() {
        if let operation = authenticationOperation {
            presentationLogger.log(
                .finished(
                    feature: .trackingSettings,
                    kind: operation.kind.presentationKind,
                    operationID: operation.id,
                    outcome: .cancelled
                )
            )
        }
        authenticationOperation = nil
        authenticationTask?.cancel()
        authenticationTask = nil
        operatingProviderID = nil
        operationKind = nil
    }

    private func startAuthenticationOperation(
        providerID: String,
        kind: TrackerSettingsOperationKind,
        token: String? = nil
    ) {
        guard authenticationOperation == nil,
              providers.contains(where: { $0.identifier == providerID }) else { return }

        let operation = AuthenticationOperation(id: UUID(), providerID: providerID, kind: kind)
        authenticationOperation = operation
        operatingProviderID = providerID
        operationKind = kind
        providerFailures.removeValue(forKey: providerID)
        presentationLogger.log(
            .started(
                feature: .trackingSettings,
                kind: kind.presentationKind,
                operationID: operation.id
            )
        )

        authenticationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch kind {
                case .authentication:
                    if let token {
                        try await service.authenticate(providerID: providerID, token: token)
                    } else {
                        try await service.authenticate(providerID: providerID)
                    }
                case .logout:
                    try await service.logout(providerID: providerID)
                }

                guard isCurrent(operation), !Task.isCancelled else {
                    logIgnoredStale(kind: kind.presentationKind, operationID: operation.id)
                    return
                }
                service.refreshSettingsState()
                apply(service.settingsState)
                finishAuthenticationOperation(operation, outcome: .succeeded)
            } catch is CancellationError {
                guard isCurrent(operation) else {
                    logIgnoredStale(kind: kind.presentationKind, operationID: operation.id)
                    return
                }
                finishAuthenticationOperation(operation, outcome: .cancelled)
            } catch {
                guard isCurrent(operation), !Task.isCancelled else {
                    logIgnoredStale(kind: kind.presentationKind, operationID: operation.id)
                    return
                }
                service.refreshSettingsState()
                apply(service.settingsState)
                providerFailures[providerID] = switch (kind, error) {
                case (.authentication, TrackerTokenError.rejected): .tokenRejected
                case (.authentication, _): .authentication
                case (.logout, _): .logout
                }
                let category: PresentationErrorCategory = kind == .authentication
                    ? .authentication
                    : .logout
                finishAuthenticationOperation(operation, outcome: .failed(category))
            }
        }
    }

    private func finishAuthenticationOperation(
        _ operation: AuthenticationOperation,
        outcome: PresentationEventOutcome
    ) {
        guard isCurrent(operation) else { return }
        presentationLogger.log(
            .finished(
                feature: .trackingSettings,
                kind: operation.kind.presentationKind,
                operationID: operation.id,
                outcome: outcome
            )
        )
        authenticationOperation = nil
        authenticationTask = nil
        operatingProviderID = nil
        operationKind = nil
    }

    private func isCurrent(_ operation: AuthenticationOperation) -> Bool {
        authenticationOperation?.id == operation.id
            && authenticationOperation?.providerID == operation.providerID
            && authenticationOperation?.kind == operation.kind
    }

    private func apply(_ state: TrackerSettingsAuthoritativeState) {
        credentialState = state.credentialState
        providers = state.providers
    }

    private func publishAuthoritativePreference() {
        isPublishingAuthoritativePreference = true
        syncTrackersToLocal = settingsStore.autoSyncTrackersToLocal
        isPublishingAuthoritativePreference = false
    }

    private func logIgnoredStale(
        kind: PresentationEventKind,
        operationID: UUID
    ) {
        presentationLogger.log(
            .finished(
                feature: .trackingSettings,
                kind: kind,
                operationID: operationID,
                outcome: .ignoredStale
            )
        )
    }
}

private extension TrackerSettingsOperationKind {
    var presentationKind: PresentationEventKind {
        switch self {
        case .authentication:
            return .authentication
        case .logout:
            return .logout
        }
    }
}
