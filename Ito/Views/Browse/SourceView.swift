import SwiftUI
import Nuke
import NukeUI
import ito_runner

extension PluginInfo {
    public var isArchived: Bool { archived ?? false }

    public var archiveNotice: String {
        if let reason = archivedReason {
            return "This plugin is no longer maintained.\nReason: \(reason)"
        }
        return "This plugin is no longer maintained."
    }
}

struct SourceView: View {
    @StateObject private var viewModel: SourceViewModel
    private let viewFactory: AppViewFactory
    @Environment(\.dismiss) private var dismiss
    @State private var trustAction: TrustCertificateAction?

    init(viewModel: SourceViewModel, viewFactory: AppViewFactory) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.viewFactory = viewFactory
    }

    var body: some View {
        sourceContent
            .navigationTitle(viewModel.plugin.info.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    searchControls
                    if viewModel.hasSettings {
                        Button(action: { viewModel.showSettings = true }) {
                            Image(systemName: "gear")
                        }
                        .accessibilityLabel("Source settings")
                    }
                }
            }
            .sheet(isPresented: $viewModel.showSettings, onDismiss: {
                Task { await viewModel.reloadAfterSettingsChange() }
            }) {
                if let destination = viewModel.settingsDestination {
                    viewFactory.makePluginSettingsView(destination: destination)
                } else if let reason = viewModel.settingsUnavailableReason {
                    SourceSettingsUnavailableView(pluginName: viewModel.plugin.info.name, reason: reason)
                }
            }
            .sheet(isPresented: $viewModel.showSearchFilters) {
                if let capabilities = viewModel.searchCapabilities {
                    SearchFilterSheet(
                        capabilities: capabilities,
                        values: viewModel.filterValues,
                        optionCatalog: { viewModel.makeOptionCatalogModel($0) },
                        onApply: { viewModel.applyFilters($0) }
                    )
                }
            }
            .sheet(isPresented: $viewModel.showSignIn, onDismiss: {
                // Reload the source, and repeat the search if that was what asked for a sign-in.
                let searchNeededSignIn = viewModel.searchFailureNeedsLogin
                Task {
                    await viewModel.retry()
                    if searchNeededSignIn {
                        viewModel.performSearch(query: viewModel.searchQuery)
                    }
                }
            }) {
                if let target = signInTarget {
                    viewFactory.makePluginSignInSheet(target: target)
                }
            }
            .sheet(item: $trustAction) { action in
                PluginCertificateConfirmationSheet(
                    sourceName: action.sourceName,
                    request: action.request,
                    onTrust: {
                        try action.confirm()
                        action.onSuccess()
                    }
                )
            }
            .searchable(
                text: $viewModel.searchQuery,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search source..."
            )
            .onChange(of: viewModel.searchQuery) { query in
                viewModel.performSearch(query: query)
            }
            .onSubmit(of: .search) { viewModel.submitSearch() }
            .onChange(of: viewModel.shouldDismiss) { shouldDismiss in
                if shouldDismiss { dismiss() }
            }
            .alert("Remove \(viewModel.plugin.info.name)?", isPresented: $viewModel.showArchivedPluginDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    viewModel.cancelArchivedPluginDeletion()
                }
                Button("Remove", role: .destructive) {
                    Task { await viewModel.confirmArchivedPluginDeletion() }
                }
            } message: {
                Text("This permanently removes the archived plugin from this device.")
            }
            .task {
                await viewModel.loadIfNeeded()
            }
            .onDisappear {
                viewModel.cancelActiveOperations()
            }
    }

    @ViewBuilder
    private var sourceContent: some View {
        switch viewModel.phase {
        case .idle, .loading:
            ProgressView("Loading Source...")
        case .failure(let error):
            failureView(
                message: "Error: \(error)",
                opensSettings: viewModel.failureOffersSettings,
                offersSignIn: viewModel.failureNeedsLogin && signInTarget != nil,
                pendingTrust: viewModel.failurePendingTrust
            ) {
                Task { await viewModel.retry() }
            }
        case .cancelled:
            failureView(message: "Source loading was cancelled.") {
                Task { await viewModel.retry() }
            }
        case .content, .empty:
            if !viewModel.hasActiveSearch {
                homeContent
            } else {
                searchContent
            }
        }
    }

    private var homeContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                if viewModel.plugin.info.isArchived {
                    archivedPluginBanner
                }

                if let layout = viewModel.homeLayout {
                    ForEach(layout.components.indices, id: \.self) { index in
                        let component = layout.components[index]
                        Section(header: sectionHeader(component)) {
                            renderComponent(component.value)
                        }
                    }
                }
            }
            .padding(.vertical)
        }
    }

    private var archivedPluginBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label {
                    Text("Archived Plugin")
                        .font(.headline)
                        .foregroundColor(.primary)
                } icon: {
                    Image(systemName: "archivebox.fill")
                        .foregroundStyle(.orange)
                }
                Spacer()
                if let date = viewModel.plugin.info.archivedDate {
                    Text(date)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text(.init(viewModel.plugin.info.archiveNotice))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .tint(.accentColor)
                .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive) {
                viewModel.requestArchivedPluginDeletion()
            } label: {
                if viewModel.isDeletingArchivedPlugin {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label("Remove Plugin", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(viewModel.isDeletingArchivedPlugin)

            if let error = viewModel.archivedPluginDeleteError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal)
    }

    @ViewBuilder
    private func sectionHeader(_ component: HomeComponent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let listing = component.value.listing,
                   let destination = viewModel.listingDestination(
                    listing: listing,
                    title: component.title ?? listing.name
                   ) {
                    NavigationLink(destination: viewFactory.makeListingView(destination: destination)) {
                        HStack {
                            Text(component.title ?? "")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text(component.title ?? "")
                        .font(.title2)
                        .fontWeight(.bold)
                }
                Spacer()
            }
            if let subtitle = component.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func renderComponent(_ value: HomeComponentValue) -> some View {
        switch value {
            case .scroller(let mangas, _):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(mangas, id: \.key) { manga in
                            MediaCardView(media: manga) { mediaDestination(manga) }
                        }
                    }
                    .padding(.horizontal)
                }
            case .mangaList(_, _, let mangas, _):
                VStack {
                    ForEach(mangas, id: \.key) { manga in
                        MediaRowView(media: manga) { mediaDestination(manga) }
                        Divider().padding(.leading, 72)
                    }
                }
            case .mangaChapterList(_, let entries, _):
                VStack(spacing: 0) {
                    ForEach(entries.indices, id: \.self) { idx in
                        let entry = entries[idx]
                        VStack(spacing: 2) {
                            MediaRowView(media: entry.manga) {
                                mediaDestination(entry.manga)
                            }
                            HStack {
                                Text(entry.chapter.title ?? "Chapter \(entry.chapter.chapter.map { String(Int($0)) } ?? "—")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.leading, 88)
                            .padding(.trailing)
                            .padding(.bottom, 8)
                        }
                        Divider().padding(.leading, 88)
                    }
                }
            case .bigScroller(let mangas, _):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(mangas, id: \.key) { manga in
                            MediaBigCardView(media: manga) { mediaDestination(manga) }
                        }
                    }
                    .padding(.horizontal)
                }
            case .animeScroller(let animes, _):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(animes, id: \.key) { anime in
                            MediaCardView(media: anime) { mediaDestination(anime) }
                        }
                    }
                    .padding(.horizontal)
                }
            case .animeList(_, _, let animes, _):
                VStack {
                    ForEach(animes, id: \.key) { anime in
                        MediaRowView(media: anime) { mediaDestination(anime) }
                        Divider().padding(.leading, 72)
                    }
                }
            case .animeEpisodeList(_, let entries, _):
                VStack(spacing: 0) {
                    ForEach(entries.indices, id: \.self) { idx in
                        let entry = entries[idx]
                        VStack(spacing: 2) {
                            MediaRowView(media: entry.anime) {
                                mediaDestination(entry.anime)
                            }
                            HStack {
                                Text(entry.episode.title ?? "Episode \(entry.episode.episode.map { String(Int($0)) } ?? "—")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.leading, 88)
                            .padding(.trailing)
                            .padding(.bottom, 8)
                        }
                        Divider().padding(.leading, 88)
                    }
                }
            case .animeBigScroller(let animes, _):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(animes, id: \.key) { anime in
                            MediaBigCardView(media: anime) { mediaDestination(anime) }
                        }
                    }
                    .padding(.horizontal)
                }
            case .novelScroller(let novels, _):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(novels, id: \.key) { novel in
                            MediaCardView(media: novel) { mediaDestination(novel) }
                        }
                    }
                    .padding(.horizontal)
                }
            case .novelList(_, _, let novels, _):
                VStack {
                    ForEach(novels, id: \.key) { novel in
                        MediaRowView(media: novel) { mediaDestination(novel) }
                        Divider().padding(.leading, 72)
                    }
                }
            case .novelChapterList(_, let entries, _):
                VStack(spacing: 0) {
                    ForEach(entries.indices, id: \.self) { idx in
                        let entry = entries[idx]
                        VStack(spacing: 2) {
                            MediaRowView(media: entry.novel) {
                                mediaDestination(entry.novel)
                            }
                            HStack {
                                Text(entry.chapter.title ?? "Chapter \(entry.chapter.chapter.map { String(Int($0)) } ?? "—")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.leading, 88)
                            .padding(.trailing)
                            .padding(.bottom, 8)
                        }
                        Divider().padding(.leading, 88)
                    }
                }
            case .links(let links):
                VStack(spacing: 12) {
                    ForEach(links.indices, id: \.self) { idx in
                        let link = links[idx]
                        Button(action: {
                            // Link tap handler not directly opening Safari/media in layout unless wrapped in nav link, so this is just UI dummy for now if we don't have routing manager
                        }) {
                            HStack {
                                Text(link.title)
                                    .font(.body)
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                            .padding(.horizontal)
                        }
                        .foregroundColor(.primary)
                    }
                }
            case .novelBigScroller(let novels, _):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(novels, id: \.key) { novel in
                            MediaBigCardView(media: novel) { mediaDestination(novel) }
                        }
                    }
                    .padding(.horizontal)
                }
            case .mediaScroller(let entries, _):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(entries, id: \.catalogIdentity) { entry in
                            mediaCard(entry)
                        }
                    }
                    .padding(.horizontal)
                }
            case .mediaList(_, _, let entries, _):
                VStack {
                    ForEach(entries, id: \.catalogIdentity) { entry in
                        mediaRow(entry)
                        Divider().padding(.leading, 72)
                    }
                }
            case .mediaBigScroller(let entries, _):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(entries, id: \.catalogIdentity) { entry in
                            mediaBigCard(entry)
                        }
                    }
                    .padding(.horizontal)
                }
            default:
                Text("Unsupported component type.")
                    .foregroundColor(.secondary)
                    .padding()
        }
    }

    @ViewBuilder
    private var searchControls: some View {
        if let capabilities = viewModel.searchCapabilities {
            if let sort = capabilities.sort, case .select(let body) = sort.kind,
               case .inline(let options) = body.options {
                Menu {
                    ForEach(options, id: \.identity) { option in
                        Button {
                            viewModel.selectSort(.select(option.value))
                        } label: {
                            if (viewModel.filterValues[sort.id] ?? sort.kind.defaultValue) == .select(option.value) {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .disabled(!viewModel.sortEnabled)
                .accessibilityLabel("Sort")
                .accessibilityHint(viewModel.sortEnabled ? "" : "Sorting is only available without search text.")
            }
            if !capabilities.sections.isEmpty {
                Button { viewModel.showSearchFilters = true } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .disabled(!viewModel.filtersEnabled)
                .accessibilityLabel("Filters")
                .accessibilityHint(viewModel.filtersEnabled ? "" : "Filters are only available without search text.")
            }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        VStack(spacing: 0) {
            if let capabilities = viewModel.searchCapabilities, viewModel.hasActiveSearchQuery {
                if capabilities.sort != nil && !viewModel.sortEnabled {
                    Text("Sorting is only available without search text.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                if !capabilities.sections.isEmpty && !viewModel.filtersEnabled {
                    Text("Filters are only available without search text.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
            }
            ForEach(viewModel.searchSuggestions.indices, id: \.self) { index in
                let suggestion = viewModel.searchSuggestions[index]
                Button {
                    viewModel.searchQuery = suggestion.query
                } label: {
                    VStack(alignment: .leading) {
                        Text(suggestion.query)
                        if let subtitle = suggestion.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }
            if viewModel.isMultiKind {
                scopePicker
            }
            searchBody
        }
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $viewModel.selectedKind) {
            Text("All").tag(MediaKind?.none)
            ForEach(viewModel.plugin.info.distinctKinds, id: \.self) { kind in
                Text(kindTitle(kind)).tag(MediaKind?.some(kind))
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func kindTitle(_ kind: MediaKind) -> String {
        switch kind {
        case .manga: return "Manga"
        case .anime: return "Anime"
        case .novel: return "Novel"
        }
    }

    @ViewBuilder
    private var searchBody: some View {
        switch viewModel.searchPhase {
        case .idle, .loading:
            ProgressView("Searching source...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failure(let error):
            failureView(
                message: "Search error: \(error)",
                opensSettings: viewModel.searchFailureOffersSettings,
                offersSignIn: viewModel.searchFailureNeedsLogin && signInTarget != nil,
                pendingTrust: viewModel.searchFailurePendingTrust
            ) {
                viewModel.performSearch(query: viewModel.searchQuery)
            }
        case .cancelled:
            failureView(message: "Search was cancelled.") {
                viewModel.performSearch(query: viewModel.searchQuery)
            }
        case .empty:
            Text("No results found.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            renderSearchList()
        }
    }

    private func renderSearchList() -> some View {
        List(viewModel.searchEntries, id: \.catalogIdentity) { entry in
            mediaRow(entry)
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func mediaCard(_ entry: MediaEntry) -> some View {
        switch entry {
        case .manga(let manga):
            MediaCardView(media: manga) { mediaDestination(entry) }
        case .anime(let anime):
            MediaCardView(media: anime) { mediaDestination(entry) }
        case .novel(let novel):
            MediaCardView(media: novel) { mediaDestination(entry) }
        }
    }

    @ViewBuilder
    private func mediaRow(_ entry: MediaEntry) -> some View {
        switch entry {
        case .manga(let manga):
            MediaRowView(media: manga) { mediaDestination(entry) }
        case .anime(let anime):
            MediaRowView(media: anime) { mediaDestination(entry) }
        case .novel(let novel):
            MediaRowView(media: novel) { mediaDestination(entry) }
        }
    }

    @ViewBuilder
    private func mediaBigCard(_ entry: MediaEntry) -> some View {
        switch entry {
        case .manga(let manga):
            MediaBigCardView(media: manga) { mediaDestination(entry) }
        case .anime(let anime):
            MediaBigCardView(media: anime) { mediaDestination(entry) }
        case .novel(let novel):
            MediaBigCardView(media: novel) { mediaDestination(entry) }
        }
    }

    @ViewBuilder
    private func mediaDestination(_ entry: MediaEntry) -> some View {
        if let destination = viewModel.destination(for: entry) {
            viewFactory.searchRouteFactory.destination(for: destination)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func mediaDestination(_ manga: Manga) -> some View {
        mediaDestination(.manga(manga))
    }

    @ViewBuilder
    private func mediaDestination(_ anime: Anime) -> some View {
        mediaDestination(.anime(anime))
    }

    @ViewBuilder
    private func mediaDestination(_ novel: Novel) -> some View {
        mediaDestination(.novel(novel))
    }

    /// The source's website for signing in, when it has one and sign-in is available.
    private var signInTarget: PluginSignInTarget? {
        viewFactory.signInTarget(pluginID: viewModel.plugin.id)
    }

    /// A failure with Retry, plus Open Settings, Sign In, or Trust Certificate when the source needs one to recover.
    private func failureView(
        message: String,
        opensSettings: Bool = false,
        offersSignIn: Bool = false,
        pendingTrust: PendingTrust? = nil,
        retry: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Text(message).foregroundColor(.red)
            HStack(spacing: 12) {
                if opensSettings {
                    Button("Open Settings") { viewModel.showSettings = true }
                        .buttonStyle(.borderedProminent)
                }
                if offersSignIn {
                    Button("Sign In") { viewModel.showSignIn = true }
                        .buttonStyle(.borderedProminent)
                }
                if let pendingTrust {
                    Button("Trust Certificate…") {
                        trustAction = viewFactory.trustAction(for: pendingTrust, retry: retry)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Retry", action: retry)
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// Shown in place of a source's settings when the source couldn't describe them.
private struct SourceSettingsUnavailableView: View {
    let pluginName: String
    let reason: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Label("These settings can't be shown.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("\(pluginName) Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Done") { dismiss() })
        }
    }
}

extension HomeComponentValue {
    var listing: Listing? {
        switch self {
        case .scroller(_, let listing): return listing
        case .mangaList(_, _, _, let listing): return listing
        case .mangaChapterList(_, _, let listing): return listing
        case .animeScroller(_, let listing): return listing
        case .animeList(_, _, _, let listing): return listing
        case .animeEpisodeList(_, _, let listing): return listing
        case .novelScroller(_, let listing): return listing
        case .novelList(_, _, _, let listing): return listing
        case .novelChapterList(_, _, let listing): return listing
        case .mediaScroller(_, let listing): return listing
        case .mediaList(_, _, _, let listing): return listing
        default: return nil
        }
    }
}
