import SwiftUI

struct TrackerSheetProviderPresentation: Identifiable, Equatable {
    let provider: TrackerProviderPresentation
    let linkedRemoteMediaID: String?

    var id: String { provider.identifier }
    var isTracked: Bool { linkedRemoteMediaID != nil }
}

struct TrackerSheetConfiguration: Equatable {
    let mediaIdentity: MediaIdentity
    let title: String
    let isAnime: Bool
    let providers: [TrackerSheetProviderPresentation]
}

@MainActor
struct TrackingViewFactory {
    private let dependencies: PreparedTrackingDependencies
    private let messagePresenter: any TrackingMessagePresenting
    private let presentationLogger: any PresentationEventLogging

    init(
        dependencies: PreparedTrackingDependencies,
        messagePresenter: any TrackingMessagePresenting,
        presentationLogger: any PresentationEventLogging
    ) {
        self.dependencies = dependencies
        self.messagePresenter = messagePresenter
        self.presentationLogger = presentationLogger
    }

    func makeTrackerSettingsViewModel() -> TrackerSettingsViewModel {
        TrackerSettingsViewModel(
            service: dependencies.settingsService,
            settingsStore: dependencies.settingsStore,
            messagePresenter: messagePresenter,
            presentationLogger: presentationLogger
        )
    }

    func makeTrackerSettingsView() -> TrackerSettingsView {
        TrackerSettingsView(viewModel: makeTrackerSettingsViewModel())
    }

    func makeTrackerSheet(
        mediaIdentity: MediaIdentity,
        title: String,
        isAnime: Bool,
        onTracked: ((TrackerMedia, Int?, String?) -> Void)? = nil
    ) -> TrackerSheetOrchestrator {
        TrackerSheetOrchestrator(
            configuration: makeSheetConfiguration(
                mediaIdentity: mediaIdentity,
                title: title,
                isAnime: isAnime
            ),
            factory: self,
            onTracked: onTracked
        )
    }

    func makeProviderSelectionViewModel(
        configuration: TrackerSheetConfiguration
    ) -> TrackerProviderSelectionViewModel {
        TrackerProviderSelectionViewModel(
            configuration: configuration,
            detailsService: dependencies.detailsService
        )
    }

    func makeSearchViewModel(
        configuration: TrackerSheetConfiguration,
        provider: TrackerSheetProviderPresentation
    ) -> TrackerSearchViewModel {
        TrackerSearchViewModel(
            providerID: provider.provider.identifier,
            providerName: provider.provider.name,
            mediaIdentity: configuration.mediaIdentity,
            title: configuration.title,
            isAnime: configuration.isAnime,
            searchService: dependencies.searchService,
            presentationLogger: presentationLogger
        )
    }

    func makeDetailsViewModel(
        destination: TrackerDetailsDestination
    ) -> TrackerDetailsViewModel {
        TrackerDetailsViewModel(
            destination: destination,
            detailsService: dependencies.detailsService,
            linkStore: dependencies.linkStore,
            localProgressReader: dependencies.localProgressReader,
            externalURLOpener: dependencies.externalURLOpener,
            messagePresenter: messagePresenter,
            presentationLogger: presentationLogger
        )
    }

    func makeExistingDetailsDestination(
        configuration: TrackerSheetConfiguration,
        provider: TrackerSheetProviderPresentation
    ) -> TrackerDetailsDestination? {
        guard let linkedRemoteMediaID = provider.linkedRemoteMediaID else { return nil }
        return TrackerDetailsDestination(
            providerID: provider.provider.identifier,
            providerName: provider.provider.name,
            mediaIdentity: configuration.mediaIdentity,
            media: TrackerMedia(
                id: linkedRemoteMediaID,
                title: configuration.title,
                titleRomaji: nil,
                coverImage: nil,
                format: configuration.isAnime ? "TV" : "MANGA",
                episodes: nil,
                chapters: nil
            ),
            showCancelButton: true,
            isLocallyLinked: true
        )
    }

    private func makeSheetConfiguration(
        mediaIdentity: MediaIdentity,
        title: String,
        isAnime: Bool
    ) -> TrackerSheetConfiguration {
        // Trackers without anime (MangaBaka) are offered for manga and novels only.
        let providers = dependencies.sheetService.authenticatedProviders()
            .filter { !isAnime || $0.tracksAnime }
            .map { provider in
                TrackerSheetProviderPresentation(
                    provider: provider,
                    linkedRemoteMediaID: dependencies.sheetService.remoteMediaID(
                        for: mediaIdentity,
                        providerID: provider.identifier
                    )
                )
            }
        return TrackerSheetConfiguration(
            mediaIdentity: mediaIdentity,
            title: title,
            isAnime: isAnime,
            providers: providers
        )
    }
}
