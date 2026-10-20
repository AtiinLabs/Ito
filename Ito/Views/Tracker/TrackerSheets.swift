import NukeUI
import SwiftUI

struct TrackerSheetOrchestrator: View {
    let configuration: TrackerSheetConfiguration
    let factory: TrackingViewFactory
    var onTracked: ((TrackerMedia, Int?, String?) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProviderID: String?
    @StateObject private var selectionViewModel: TrackerProviderSelectionViewModel

    init(
        configuration: TrackerSheetConfiguration,
        factory: TrackingViewFactory,
        onTracked: ((TrackerMedia, Int?, String?) -> Void)?
    ) {
        self.configuration = configuration
        self.factory = factory
        self.onTracked = onTracked
        _selectionViewModel = StateObject(
            wrappedValue: factory.makeProviderSelectionViewModel(configuration: configuration)
        )
    }

    var body: some View {
        if configuration.providers.isEmpty {
            unauthenticatedView
        } else if configuration.providers.count == 1,
                  let provider = configuration.providers.first {
            providerDestination(provider)
        } else if let provider = selectedProvider {
            providerDestination(provider)
        } else {
            providerSelectionView
        }
    }

    private var selectedProvider: TrackerSheetProviderPresentation? {
        guard let selectedProviderID else { return nil }
        return configuration.providers.first { $0.id == selectedProviderID }
    }

    private var unauthenticatedView: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 50))
                    .foregroundColor(.orange)
                Text("No Trackers Authenticated")
                    .font(.title2)
                    .fontWeight(.bold)
                Text(configuration.isAnime
                    ? "Go to Settings > Trackers and sign in to AniList or MyAnimeList to track anime."
                    : "Go to Settings > Trackers and sign in to AniList, MyAnimeList or MangaBaka before tracking.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
            .navigationTitle("Track Series")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Close") { dismiss() })
        }
    }

    private var providerSelectionView: some View {
        NavigationView {
            List(configuration.providers) { provider in
                Button {
                    selectedProviderID = provider.id
                } label: {
                    HStack {
                        Text(provider.provider.name)
                            .foregroundColor(.primary)
                        Spacer()
                        Text(selectionViewModel.label(for: provider.id))
                            .font(.caption)
                            .foregroundColor(provider.isTracked ? .green : .secondary)
                            .padding(.trailing, 4)
                        Image(systemName: "chevron.right")
                            .foregroundColor(.gray)
                    }
                }
            }
            .task { selectionViewModel.start() }
            .onDisappear(perform: selectionViewModel.cancelOwnedWork)
            .navigationTitle("Select Tracker")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Cancel") { dismiss() })
        }
        .modifier(PresentationDetentsModifier())
    }

    @ViewBuilder
    private func providerDestination(_ provider: TrackerSheetProviderPresentation) -> some View {
        if let destination = factory.makeExistingDetailsDestination(
            configuration: configuration,
            provider: provider
        ) {
            NavigationView {
                TrackerDetailsSheet(
                    viewModel: factory.makeDetailsViewModel(destination: destination),
                    onOutput: { output in
                        handleDetailsOutput(output, media: destination.media)
                    }
                )
            }
        } else {
            TrackerSearchSheet(
                viewModel: factory.makeSearchViewModel(
                    configuration: configuration,
                    provider: provider
                ),
                makeDetailsViewModel: factory.makeDetailsViewModel,
                onTracked: { media, progress, status in
                    onTracked?(media, progress, status)
                    dismiss()
                }
            )
        }
    }

    private func handleDetailsOutput(_ output: TrackerDetailsOutput, media: TrackerMedia) {
        switch output.kind {
        case .saved(let progress, let status):
            onTracked?(media, progress, status)
            dismiss()
        case .unlinked:
            onTracked?(media, nil, nil)
            dismiss()
        case .cancelled:
            onTracked?(media, nil, nil)
            dismiss()
        }
    }
}

struct PresentationDetentsModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.presentationDetents([.medium, .large])
        } else {
            content
        }
    }
}

struct TrackerSearchSheet: View {
    @StateObject private var viewModel: TrackerSearchViewModel
    private let makeDetailsViewModel: (TrackerDetailsDestination) -> TrackerDetailsViewModel
    private let onTracked: (TrackerMedia, Int?, String?) -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        viewModel: TrackerSearchViewModel,
        makeDetailsViewModel: @escaping (TrackerDetailsDestination) -> TrackerDetailsViewModel,
        onTracked: @escaping (TrackerMedia, Int?, String?) -> Void
    ) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.makeDetailsViewModel = makeDetailsViewModel
        self.onTracked = onTracked
    }

    var body: some View {
        NavigationView {
            VStack {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField(
                        "Search \(viewModel.providerName)",
                        text: $viewModel.searchQuery,
                        onCommit: viewModel.performSearch
                    )
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    if viewModel.isLoading {
                        ProgressView()
                    }
                }
                .padding()

                if let hint = viewModel.queryHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }

                if let errorMessage = viewModel.errorMessage {
                    HStack {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                        Spacer()
                        Button("Retry", action: viewModel.retry)
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal)
                }

                List(viewModel.results) { media in
                    TrackerSearchResultRow(
                        media: media,
                        isAnime: viewModel.isAnime,
                        isSelected: viewModel.selectedMedia?.id == media.id
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.select(mediaID: media.id)
                    }
                }

                if let attribution = viewModel.attribution {
                    Text(attribution)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }

                ZStack {
                    NavigationLink(
                        isActive: $viewModel.isPresentingDetails,
                        destination: detailsDestination,
                        label: { EmptyView() }
                    )

                    Button(action: viewModel.presentSelectedDetails) {
                        Text("Select Series")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(viewModel.selectedMedia == nil ? Color.gray : Color.accentColor)
                            .foregroundColor(viewModel.selectedMedia == nil ? .white : .itoOnAccent)
                            .cornerRadius(10)
                    }
                    .disabled(viewModel.selectedMedia == nil)
                }
                .padding()
            }
            .navigationTitle("Search on \(viewModel.providerName)")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("Back", action: dismissSearch),
                trailing: Button("Cancel", action: dismissSearch)
            )
            .task { viewModel.start() }
            .onDisappear {
                if viewModel.destination == nil {
                    viewModel.cancelOwnedWork()
                }
            }
        }
    }

    @ViewBuilder
    private func detailsDestination() -> some View {
        if let destination = viewModel.destination {
            TrackerDetailsSheet(
                viewModel: makeDetailsViewModel(destination),
                onOutput: { output in
                    switch output.kind {
                    case .saved(let progress, let status):
                        onTracked(destination.media, progress, status)
                    case .unlinked:
                        onTracked(destination.media, nil, nil)
                    case .cancelled:
                        viewModel.navigationBindingDidSet(false)
                    }
                }
            )
        } else {
            EmptyView()
        }
    }

    private func dismissSearch() {
        viewModel.cancelOwnedWork()
        dismiss()
    }
}

private struct TrackerSearchResultRow: View {
    let media: TrackerMedia
    let isAnime: Bool
    let isSelected: Bool

    var body: some View {
        HStack {
            if let cover = media.coverImage, let url = URL(string: cover) {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.gray.opacity(0.3)
                    }
                }
                .frame(width: 50, height: 75)
                .cornerRadius(4)
            }

            VStack(alignment: .leading) {
                Text(media.title)
                    .font(.headline)
                    .lineLimit(2)
                if let romaji = media.titleRomaji {
                    Text(romaji)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text(media.format ?? (isAnime ? "Anime" : "Manga"))
                    .font(.caption2)
                    .padding(4)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(4)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title2)
            }
        }
    }
}

struct TrackerDetailsSheet: View {
    @StateObject private var viewModel: TrackerDetailsViewModel
    private let onOutput: (TrackerDetailsOutput) -> Void

    init(
        viewModel: TrackerDetailsViewModel,
        onOutput: @escaping (TrackerDetailsOutput) -> Void
    ) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.onOutput = onOutput
    }

    var body: some View {
        Form {
            switch viewModel.remoteEntryState {
            case .loading:
                HStack {
                    Spacer()
                    ProgressView("Checking existing progress...")
                    Spacer()
                }
            case .failure:
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(viewModel.remoteLoadErrorMessage ?? "Tracker progress is unavailable.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry", action: viewModel.retryRemoteEntryLoad)
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
            case .existing, .new:
                detailsForm
            }
        }
        .navigationTitle("Update Entry")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(viewModel.isDurableOperationInFlight)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if viewModel.showCancelButton {
                    Button("Cancel", action: viewModel.cancel)
                        .disabled(viewModel.isDurableOperationInFlight)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: viewModel.save) {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Text("Save").fontWeight(.bold)
                    }
                }
                .disabled(
                    viewModel.remoteEntryState == .loading
                        || viewModel.remoteEntryState == .failure
                        || viewModel.isDurableOperationInFlight
                )
            }
        }
        .alert("Sync Local History", isPresented: $viewModel.isPresentingLocalProgressAlert) {
            Button("Cancel", role: .cancel, action: viewModel.cancelLocalProgressSync)
            if case .found = viewModel.localProgressCandidate {
                Button("Sync", action: viewModel.confirmLocalProgressSync)
            }
        } message: {
            switch viewModel.localProgressCandidate {
            case .found(let maximum):
                Text("We found local reading/watching history up to chapter/episode \(maximum). Do you want to update your \(viewModel.providerName) progress to match?")
            case .notFound:
                Text("No local reading or watching history was found for this series.")
            case nil:
                EmptyView()
            }
        }
        .alert("Tracker Change Not Saved", isPresented: $viewModel.isPresentingFailureAlert) {
            Button("OK", role: .cancel, action: viewModel.dismissFailure)
        } message: {
            Text(viewModel.failure?.message ?? "Your tracker change couldn't be saved. Please try again.")
        }
        .task { viewModel.start() }
        .onChange(of: viewModel.output?.id) { _ in
            guard let output = viewModel.consumeOutput() else { return }
            onOutput(output)
        }
        .onDisappear(perform: viewModel.cancelOwnedWork)
        .interactiveDismissDisabled(viewModel.isDurableOperationInFlight)
    }

    private var detailsForm: some View {
        Group {
            Section(header: Text("Series Info")) {
                HStack {
                    if let cover = viewModel.media.coverImage, let url = URL(string: cover) {
                        LazyImage(url: url) { state in
                            if let image = state.image {
                                image.resizable().scaledToFill()
                            } else {
                                Color.gray
                            }
                        }
                        .frame(width: 60, height: 90)
                        .cornerRadius(6)
                    }
                    Text(viewModel.media.title)
                        .font(.headline)
                }
            }

            Section(
                header: Text("Progress"),
                footer: Text(viewModel.automaticSyncNote ?? "")
            ) {
                Picker("Status", selection: $viewModel.status) {
                    ForEach(TrackerDetailsViewModel.statuses, id: \.self) { statusOption in
                        Text(viewModel.displayLabel(for: statusOption))
                            .tag(String?.some(statusOption))
                    }
                }

                HStack {
                    Text("Progress")
                    Spacer()
                    TextField("0", text: $viewModel.progress)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 50)

                    Stepper(
                        "",
                        onIncrement: viewModel.incrementProgress,
                        onDecrement: viewModel.decrementProgress
                    )
                    .labelsHidden()

                    if let total = viewModel.totalProgress {
                        Text("/ \(total)")
                            .foregroundColor(.secondary)
                    } else {
                        Text("/ ?")
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    Text("Score")
                    Spacer()
                    Text(viewModel.scoreText)
                        .foregroundColor(.secondary)
                }
            }

            Section(
                header: Text("Dates"),
                footer: Text("Score and dates come from \(viewModel.providerName). Change them on \(viewModel.providerName).")
            ) {
                HStack {
                    Text("Started")
                    Spacer()
                    Text(viewModel.startDateText)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Finished")
                    Spacer()
                    Text(viewModel.finishDateText)
                        .foregroundColor(.secondary)
                }
            }

            Section(
                footer: Text(viewModel.canStopTracking
                    ? "Stop Tracking removes the link in Ito. Your \(viewModel.providerName) list entry is kept."
                    : "")
            ) {
                Button(action: viewModel.prepareLocalProgressSync) {
                    Label("Sync Local History", systemImage: "arrow.triangle.2.circlepath")
                }

                Button(action: viewModel.openExternalURL) {
                    HStack {
                        if viewModel.isOpeningExternalURL {
                            ProgressView()
                        }
                        Label("View on \(viewModel.providerName)", systemImage: "safari")
                    }
                }
                .disabled(viewModel.isOpeningExternalURL)

                if viewModel.canStopTracking {
                    Button(role: .destructive, action: viewModel.stopTracking) {
                        HStack {
                            if viewModel.isUnlinking {
                                ProgressView()
                                    .accessibilityLabel("Stopping tracking")
                            }
                            Label("Stop Tracking", systemImage: "link")
                                .foregroundColor(.red)
                        }
                    }
                    .disabled(viewModel.isDurableOperationInFlight)
                }
            }
        }
    }
}
