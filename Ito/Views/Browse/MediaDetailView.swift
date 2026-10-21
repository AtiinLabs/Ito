import SwiftUI
import ito_runner

private struct NavTitleVisibilityKey: PreferenceKey {
    static var defaultValue: Bool = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

struct MediaDetailView<M: MediaDisplayable>: View {
    @StateObject private var viewModel: MediaDetailViewModel<M>
    private let trackingViewFactory: TrackingViewFactory
    private let readerViewFactory: MediaDetailReaderViewFactory
    private let categoryHistoryViewFactory: CategoryHistoryViewFactory

    @State private var showNavTitle = false

    init(
        viewModel: MediaDetailViewModel<M>,
        trackingViewFactory: TrackingViewFactory,
        readerViewFactory: MediaDetailReaderViewFactory,
        categoryHistoryViewFactory: CategoryHistoryViewFactory
    ) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.trackingViewFactory = trackingViewFactory
        self.readerViewFactory = readerViewFactory
        self.categoryHistoryViewFactory = categoryHistoryViewFactory
    }

    var body: some View {
        lifecycleContent
    }

    private var lifecycleContent: some View {
        presentationContent
            .task {
                viewModel.start()
            }
            .onAppear {
                viewModel.appear()
            }
            .onDisappear {
                viewModel.disappear()
            }
            .refreshable {
                await viewModel.refresh()
            }
    }

    private var presentationContent: some View {
        navigationContent
            .sheet(item: trackerSheetBinding) { intent in
                trackerSheet(for: intent)
            }
            .fullScreenCover(item: readerDestinationBinding) { destination in
                readerViewFactory.destination(for: destination)
            }
            .sheet(item: categoryAssignmentBinding) { intent in
                categoryHistoryViewFactory.makeCategoryAssignmentSheet(itemID: intent.itemID)
            }
            .sheet(item: relinkPresentationBinding) { _ in
                relinkSearchSheet
            }
    }

    private var navigationContent: some View {
        screenContent
            .animation(.easeIn(duration: 0.6), value: viewModel.theme)
            .onPreferenceChange(NavTitleVisibilityKey.self) { hidden in
                withAnimation(.easeInOut(duration: 0.18)) {
                    showNavTitle = hidden
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(showNavTitle ? viewModel.media.title : "")
    }

    private var screenContent: some View {
        ZStack {
            mediaBackground
            mediaScroll
        }
    }

    @ViewBuilder
    private var mediaBackground: some View {
        if let theme = viewModel.theme {
            Color(hex: theme.dominantHex).ignoresSafeArea()
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
        } else {
            Color(uiColor: .systemBackground).ignoresSafeArea()
        }
    }

    private var mediaScroll: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                heroHeader
                detailControls
                chapterSection
            }
        }
    }

    private var heroHeader: some View {
        SharedHeroHeader(
            title: viewModel.media.title,
            coverURL: viewModel.media.cover,
            authorOrStudio: viewModel.media.studios?.joined(separator: ", ")
                ?? viewModel.media.authors?.joined(separator: ", "),
            statusLabel: viewModel.media.displayStatus,
            sourceLabel: viewModel.sourceName,
            onImageLoaded: viewModel.heroImageLoaded
        )
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: NavTitleVisibilityKey.self,
                    value: geometry.frame(in: .global).maxY < 0
                )
            }
        )
    }

    private var detailControls: some View {
        let secondaryColor = viewModel.theme.map { Color(hex: $0.secondaryHex) }
        let saveAction: () -> Void = {
            Task { await viewModel.toggleSave() }
        }
        let trackAction: (() -> Void)? = viewModel.isTrackingAvailable
            ? { viewModel.openTrackerSheet() }
            : nil
        return SharedDetailContent(
            isSaved: viewModel.isSaved,
            isTracked: viewModel.isTracked,
            tags: viewModel.media.tags,
            cleanDescription: viewModel.media.description?.strippingHTML(),
            themeSecondary: secondaryColor,
            onSaveToggle: saveAction,
            onTrackToggle: trackAction
        )
    }

    private func trackerSheet(
        for intent: MediaDetailTrackerSheetIntent
    ) -> TrackerSheetOrchestrator {
        trackingViewFactory.makeTrackerSheet(
            mediaIdentity: intent.mediaIdentity,
            title: intent.title,
            isAnime: intent.isAnime
        ) { _, progress, _ in
            viewModel.trackerDidSave(progress: progress)
        }
    }

    private var trackerSheetBinding: Binding<MediaDetailTrackerSheetIntent?> {
        Binding(
            get: { viewModel.trackerSheetIntent },
            set: { if $0 == nil { viewModel.dismissTrackerSheet() } }
        )
    }

    private var readerDestinationBinding: Binding<MediaDetailReaderDestination?> {
        Binding(
            get: { viewModel.readerDestination },
            set: { if $0 == nil { viewModel.dismissReader() } }
        )
    }

    private var categoryAssignmentBinding: Binding<MediaDetailCategoryAssignmentIntent?> {
        Binding(
            get: { viewModel.categoryAssignmentIntent },
            set: { if $0 == nil { viewModel.dismissCategoryAssignment() } }
        )
    }

    private var relinkPresentationBinding: Binding<MediaDetailRelinkPresentation?> {
        Binding(
            get: { viewModel.relinkPresentation },
            set: { if $0 == nil { viewModel.dismissRelink() } }
        )
    }

    @ViewBuilder
    private var chapterSection: some View {
        switch viewModel.detailLoadState {
        case .idle, .loading:
            ProgressView("Loading...")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        case .content, .failure:
            loadedChapterSection
        }
    }

    @ViewBuilder
    private var loadedChapterSection: some View {
        if case .failure(let message) = viewModel.detailLoadState {
            detailFailureBanner(message: message)
        }

        if let chapters = viewModel.media.chapterList, !chapters.isEmpty {
            let displayed = viewModel.displayedChapters
            chapterListHeader(allChapters: chapters, displayedChapters: displayed)
            chapterList(chapters: displayed)
        } else if viewModel.isSaved {
            relinkBanner
        } else if viewModel.detailLoadState == .content {
            Text("No content found.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        }
    }

    private func detailFailureBanner(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                viewModel.retryDetailLoad()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
    }

    private func chapterListHeader(
        allChapters: [M.Chapter],
        displayedChapters: [M.Chapter]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let target = viewModel.resumeChapter {
                Button {
                    viewModel.selectChapter(target)
                } label: {
                    Label(
                        viewModel.hasReadProgress ? "Resume" : "Start",
                        systemImage: viewModel.media is Anime
                            ? "play.fill"
                            : (viewModel.hasReadProgress ? "book.fill" : "play.fill")
                    )
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .tint(viewModel.theme.map { Color(hex: $0.secondaryHex) } ?? .accentColor)
                .buttonStyle(.borderedProminent)
                .foregroundStyle(viewModel.theme == nil ? Color.itoOnAccent : .white)
                .controlSize(.large)
                .padding(.horizontal, 16)
            }

            if let anime = viewModel.media as? Anime,
               let seasons = anime.seasons,
               seasons.count > 1 {
                Picker("Season", selection: $viewModel.selectedGroup) {
                    ForEach(seasons, id: \.key) { season in
                        Text(season.title).tag(season.key as String?)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 16)
            }

            chapterControls(
                allChapterCount: allChapters.count,
                displayedChapterCount: displayedChapters.count
            )
        }
    }

    private func chapterControls(
        allChapterCount: Int,
        displayedChapterCount: Int
    ) -> some View {
        let title = viewModel.media is Anime ? "Episodes" : "Chapters"
        let isFiltered = viewModel.filterOption != .all || viewModel.sortOrder != .descending
        return VStack(spacing: 12) {
            HStack(alignment: .center) {
                HStack(spacing: 5) {
                    Text(title).font(.title3).fontWeight(.bold)
                    if viewModel.filterOption == .all {
                        Text("· \(allChapterCount)")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("· \(displayedChapterCount) of \(allChapterCount)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                chapterFilterMenu(isFiltered: isFiltered)
            }
            .padding(.horizontal, 16)

            if isFiltered {
                activeFilters
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func chapterFilterMenu(isFiltered: Bool) -> some View {
        Menu {
            Section("Sort Order") {
                ForEach(ChapterSortOrder.allCases, id: \.self) { order in
                    Button {
                        withAnimation { viewModel.sortOrder = order }
                    } label: {
                        Label(
                            order.rawValue,
                            systemImage: viewModel.sortOrder == order ? "checkmark" : order.icon
                        )
                    }
                }
            }

            Section("Show") {
                ForEach(ChapterFilterOption.allCases, id: \.self) { option in
                    Button {
                        withAnimation { viewModel.filterOption = option }
                    } label: {
                        Label(
                            option.rawValue,
                            systemImage: viewModel.filterOption == option
                                ? "checkmark"
                                : option.icon
                        )
                    }
                }
            }

            if isFiltered {
                Divider()
                Button(role: .destructive) {
                    withAnimation {
                        viewModel.sortOrder = .descending
                        viewModel.filterOption = .all
                    }
                } label: {
                    Label("Reset Filters", systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(
                    systemName: isFiltered
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
                .font(.system(size: 20))
                if isFiltered {
                    Text("Filtered").font(.caption).fontWeight(.medium)
                }
            }
            .foregroundStyle(isFiltered ? Color.accentColor : Color.secondary)
            .animation(.easeInOut(duration: 0.15), value: isFiltered)
        }
    }

    private var activeFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if viewModel.sortOrder != .descending {
                    ActiveFilterPill(label: viewModel.sortOrder.rawValue) {
                        withAnimation { viewModel.sortOrder = .descending }
                    }
                }
                if viewModel.filterOption != .all {
                    ActiveFilterPill(label: viewModel.filterOption.rawValue) {
                        withAnimation { viewModel.filterOption = .all }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chapterList(chapters: [M.Chapter]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(chapters, id: \.key) { chapter in
                ChapterRowView(chapter: chapter, isRead: viewModel.isRead(chapter)) {
                    viewModel.selectChapter(chapter)
                }
                Divider().padding(.leading, 16)
            }
        }
    }

    private var relinkBanner: some View {
        VStack(spacing: 16) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.orange)
            VStack(spacing: 4) {
                Text("Content Not Found").font(.headline)
                Text("This item may have been imported with an incompatible content key. Search this source to link it to the correct entry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: viewModel.openRelink) {
                Label("Search & Link", systemImage: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
            .padding(.horizontal, 32)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
    }

    private var relinkSearchSheet: some View {
        NavigationView {
            Group {
                switch viewModel.relinkSearchState {
                case .idle, .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Searching for \"\(viewModel.media.title)\"…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    relinkEmptyState(message: "No results found. Try again.")
                case .failure(let message):
                    relinkEmptyState(message: message)
                case .results:
                    relinkResultsList
                }
            }
            .overlay {
                if viewModel.isRelinkMutationInFlight {
                    ZStack {
                        Rectangle().fill(.regularMaterial).ignoresSafeArea()
                        ProgressView("Linking…")
                    }
                }
            }
            .navigationTitle("Link to Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: viewModel.dismissRelink)
                        .disabled(viewModel.isRelinkMutationInFlight)
                }
            }
        }
    }

    private func relinkEmptyState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry", action: viewModel.retryRelinkSearch)
                .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var relinkResultsList: some View {
        List(viewModel.relinkSearchResults, id: \.key) { result in
            Button {
                Task { await viewModel.performRelink(with: result) }
            } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: URL(string: result.cover ?? "")) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(.quaternary)
                    }
                    .frame(width: 48, height: 68)
                    .cornerRadius(6)
                    .clipped()

                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.title)
                            .font(.body)
                            .foregroundColor(.primary)
                            .lineLimit(2)
                        if let authors = result.authors, !authors.isEmpty {
                            Text(authors.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text("Key: \(result.key)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "arrow.right.circle")
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.vertical, 4)
            }
            .disabled(viewModel.isRelinkMutationInFlight)
        }
        .listStyle(.insetGrouped)
    }
}

private struct ActiveFilterPill: View {
    let label: String
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 4) {
                Text(label).font(.caption).fontWeight(.medium)
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.12))
            .foregroundStyle(Color.accentColor)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}
