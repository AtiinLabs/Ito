import SwiftUI
import NukeUI
import Nuke

struct DiscoverView: View {
    @StateObject private var viewModel: DiscoverViewModel
    private let viewFactory: AppViewFactory
    @State private var showFilters = false

    init(viewModel: DiscoverViewModel, viewFactory: AppViewFactory) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.viewFactory = viewFactory
    }

    var body: some View {
        NavigationView {
            Group {
                if viewModel.isShowingHome {
                    DiscoverHomeView(viewModel: viewModel, viewFactory: viewFactory)
                } else {
                    searchResultsView
                }
            }
            .navigationTitle("Discover")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        viewModel.loadFilterOptionsIfNeeded()
                        showFilters = true
                    } label: {
                        Image(systemName: viewModel.isFilterActive
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel(viewModel.isFilterActive ? "Filters, active" : "Filters")
                }
            }
            .searchable(
                text: $viewModel.searchQuery,
                prompt: "Search \(viewModel.selectedType == .anime ? "anime" : "manga")..."
            )
            .sheet(isPresented: $showFilters) {
                DiscoverFilterView(
                    viewModel: viewModel,
                    mediaType: viewModel.selectedType,
                    filters: viewModel.activeFilters,
                    onApply: { filters in
                        viewModel.applyFilters(filters)
                    }
                )
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Search Results

    private var searchResultsView: some View {
        Group {
            if viewModel.isLoadingResults && viewModel.searchResults.isEmpty {
                ProgressView("Searching...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.searchResults.isEmpty && !viewModel.searchQuery.isEmpty {
                noSearchResultsView
            } else {
                searchResultsList
            }
        }
    }

    private var noSearchResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.secondary)
            Text("No results found")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Try different search terms or adjust your filters")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchResultsList: some View {
        List {
            if viewModel.isFilterActive {
                activeFilterPills
            }

            ForEach(viewModel.searchResults) { media in
                NavigationLink(
                    destination: viewFactory.makeDiscoverDetailView(media: media)
                ) {
                    DiscoverSearchRow(media: media)
                }
                .onAppear {
                    viewModel.loadMoreIfNeeded(after: media)
                }
            }

            if viewModel.isLoadingResults && !viewModel.searchResults.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding()
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Active Filters

    private var activeFilterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.activeFilters.genres, id: \.self) { genre in
                    filterPill(genre, style: .include) {
                        viewModel.removeIncludedGenre(genre)
                    }
                }
                ForEach(viewModel.activeFilters.excludedGenres, id: \.self) { genre in
                    filterPill("− \(genre)", style: .exclude) {
                        viewModel.removeExcludedGenre(genre)
                    }
                }
                ForEach(viewModel.activeFilters.tags, id: \.self) { tag in
                    filterPill(tag, style: .include) {
                        viewModel.removeIncludedTag(tag)
                    }
                }
                ForEach(viewModel.activeFilters.excludedTags, id: \.self) { tag in
                    filterPill("− \(tag)", style: .exclude) {
                        viewModel.removeExcludedTag(tag)
                    }
                }
                if let format = viewModel.activeFilters.format {
                    filterPill(format, style: .include) {
                        viewModel.removeFormat()
                    }
                }
                if let status = viewModel.activeFilters.status {
                    filterPill(
                        status.replacingOccurrences(of: "_", with: " ").capitalized,
                        style: .include
                    ) {
                        viewModel.removeStatus()
                    }
                }
                if let year = viewModel.activeFilters.year {
                    let label = viewModel.activeFilters.season != nil
                        ? "\(viewModel.activeFilters.season!.capitalized) \(year)"
                        : "\(year)"
                    filterPill(label, style: .include) {
                        viewModel.removeYearAndSeason()
                    }
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    private enum PillStyle {
        case include
        case exclude
    }

    private func filterPill(
        _ label: String,
        style: PillStyle,
        onRemove: @escaping () -> Void
    ) -> some View {
        let tint: Color = style == .exclude ? .red : .accentColor
        return Button(action: onRemove) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption.weight(.medium))
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(tint.opacity(0.12))
            .foregroundStyle(tint)
            .cornerRadius(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(label) filter")
    }
}

// MARK: - Discover Home View

private struct DiscoverHomeView: View {
    @ObservedObject var viewModel: DiscoverViewModel
    let viewFactory: AppViewFactory

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                typePicker
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                if isInitialLoading {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 100)
                } else if viewModel.currentHomeContent.primarySectionsAreEmpty {
                    DiscoverErrorView(
                        errorMessage: homeFailure?.message,
                        isOutage: homeFailure?.isAniListOutage == true,
                        onRetry: viewModel.retryHome
                    )
                    .padding(.top, 60)
                } else {
                    homeSections
                }
            }
        }
        .refreshable {
            await viewModel.refreshHome()
        }
        .task {
            await viewModel.loadInitialHomeIfNeeded()
        }
    }

    private var typePicker: some View {
        Picker(
            "Type",
            selection: Binding(
                get: { viewModel.selectedType },
                set: { mediaType in
                    viewModel.selectMediaType(mediaType)
                }
            )
        ) {
            Text("Anime").tag(DiscoverMediaType.anime)
            Text("Manga").tag(DiscoverMediaType.manga)
        }
        .pickerStyle(.segmented)
    }

    private var isInitialLoading: Bool {
        guard case .loading = viewModel.state else { return false }
        return viewModel.currentHomeContent.trending.isEmpty
    }

    private var homeFailure: DiscoverPresentationFailure? {
        guard case .error(let failure, _) = viewModel.state,
              failure.context == .home else {
            return nil
        }
        return failure
    }

    private var homeSections: some View {
        LazyVStack(spacing: 24) {
            let content = viewModel.currentHomeContent
            if !content.trending.isEmpty {
                discoverSection(title: "Trending Now", items: content.trending)
            }
            if viewModel.selectedType == .anime && !content.seasonal.isEmpty {
                discoverSection(title: "Popular This Season", items: content.seasonal)
            }
            if !content.popular.isEmpty {
                discoverSection(title: "All-Time Popular", items: content.popular)
            }
            if !content.topRated.isEmpty {
                discoverSection(title: "Top Rated", items: content.topRated)
            }
        }
        .padding(.bottom, 24)
    }

    private func discoverSection(
        title: String,
        items: [DiscoverMedia]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items) { media in
                        NavigationLink(
                            destination: viewFactory.makeDiscoverDetailView(media: media)
                        ) {
                            DiscoverCardView(media: media)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Discover Card

struct DiscoverCardView: View {
    let media: DiscoverMedia

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                if let coverURL = media.coverImage, let url = URL(string: coverURL) {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image.resizable().scaledToFill()
                                .frame(width: 120, height: 170)
                                .clipped()
                        } else {
                            // Skeleton loading state instead of spinner
                            Color.itoCardBackground
                                .opacity(state.isLoading ? 0.5 : 1.0)
                        }
                    }
                    .processors([
                        .resize(size: CGSize(width: 240, height: 340), contentMode: .aspectFill, crop: true)
                    ])
                    .priority(.normal)
                    .frame(width: 120, height: 170)
                    .cornerRadius(10)
                    .clipped()
                } else {
                    Color.itoCardBackground
                        .frame(width: 120, height: 170)
                        .cornerRadius(10)
                }

                if let score = media.averageScore {
                    Text("\(score)%")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(scoreColor(score).opacity(0.9))
                        .cornerRadius(6)
                        .padding(4)
                        .accessibilityLabel("Score: \(score) percent")
                }
            }

            Text(media.title)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 120, alignment: .leading)
        }
    }

    private func scoreColor(_ score: Int) -> Color {
        if score >= 75 { return .green }
        if score >= 50 { return .orange }
        return .red
    }
}

// MARK: - Search Row

struct DiscoverSearchRow: View {
    let media: DiscoverMedia

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let coverURL = media.coverImage, let url = URL(string: coverURL) {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                            .frame(width: 60, height: 85)
                            .clipped()
                    } else {
                        Color.itoCardBackground
                            .opacity(state.isLoading ? 0.5 : 1.0)
                    }
                }
                .processors([
                    .resize(size: CGSize(width: 120, height: 170), contentMode: .aspectFill, crop: true)
                ])
                .priority(.normal)
                .frame(width: 60, height: 85)
                .cornerRadius(8)
            } else {
                Color.itoCardBackground
                    .frame(width: 60, height: 85)
                    .cornerRadius(8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(media.title)
                    .font(.headline)
                    .lineLimit(2)

                if let romaji = media.titleRomaji, romaji != media.title {
                    Text(romaji)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if let format = media.format {
                        Text(format.replacingOccurrences(of: "_", with: " "))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .cornerRadius(6)
                    }
                    if let score = media.averageScore {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                            Text("\(score)%")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    if let eps = media.episodes {
                        Text("\(eps) ep")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let chs = media.chapters {
                        Text("\(chs) ch")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct DiscoverView_Previews: PreviewProvider {
    static var previews: some View {
        Text("DiscoverView requires a prepared runtime")
    }
}
