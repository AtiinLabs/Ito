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

    init(viewModel: SourceViewModel, viewFactory: AppViewFactory) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.viewFactory = viewFactory
    }

    var body: some View {
        sourceContent
            .navigationTitle(viewModel.plugin.info.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if viewModel.settingsDestination != nil {
                        Button(action: { viewModel.showSettings = true }) {
                            Image(systemName: "gear")
                        }
                    }
                }
            }
            .sheet(isPresented: $viewModel.showSettings, onDismiss: {
                Task { await viewModel.reloadAfterSettingsChange() }
            }) {
                if let destination = viewModel.settingsDestination {
                    viewFactory.makePluginSettingsView(destination: destination)
                }
            }
            .searchable(
                text: $viewModel.searchQuery,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search source..."
            )
            .onChange(of: viewModel.searchQuery) { query in
                viewModel.performSearch(query: query)
            }
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
            failureView(message: "Error: \(error)") {
                Task { await viewModel.retry() }
            }
        case .cancelled:
            failureView(message: "Source loading was cancelled.") {
                Task { await viewModel.retry() }
            }
        case .content, .empty:
            if !viewModel.hasActiveSearchQuery {
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
            default:
                Text("Unsupported component type.")
                    .foregroundColor(.secondary)
                    .padding()
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        switch viewModel.searchPhase {
        case .idle, .loading:
            ProgressView("Searching source...")
        case .failure(let error):
            failureView(message: "Search error: \(error)") {
                viewModel.performSearch(query: viewModel.searchQuery)
            }
        case .cancelled:
            failureView(message: "Search was cancelled.") {
                viewModel.performSearch(query: viewModel.searchQuery)
            }
        case .empty:
            Text("No results found.")
                .foregroundStyle(.secondary)
        case .content:
            renderSearchList()
        }
    }

    @ViewBuilder
    private func renderSearchList() -> some View {
        switch viewModel.plugin.info.type {
        case .anime:
            List(viewModel.searchAnimes, id: \.key) { anime in
                MediaRowView(media: anime) { mediaDestination(anime) }
            }
            .listStyle(.plain)
        case .manga:
            List(viewModel.searchMangas, id: \.key) { manga in
                MediaRowView(media: manga) { mediaDestination(manga) }
            }
            .listStyle(.plain)
        case .novel:
            List(viewModel.searchNovels, id: \.key) { novel in
                MediaRowView(media: novel) { mediaDestination(novel) }
            }
            .listStyle(.plain)
        @unknown default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func mediaDestination(_ manga: Manga) -> some View {
        if let destination = viewModel.destination(for: manga) {
            viewFactory.searchRouteFactory.destination(for: destination)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func mediaDestination(_ anime: Anime) -> some View {
        if let destination = viewModel.destination(for: anime) {
            viewFactory.searchRouteFactory.destination(for: destination)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func mediaDestination(_ novel: Novel) -> some View {
        if let destination = viewModel.destination(for: novel) {
            viewFactory.searchRouteFactory.destination(for: destination)
        } else {
            EmptyView()
        }
    }

    private func failureView(message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(message).foregroundColor(.red)
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
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
        default: return nil
        }
    }
}
