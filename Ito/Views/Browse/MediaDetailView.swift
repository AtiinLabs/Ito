import Nuke
import NukeUI
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
    @Environment(\.scenePhase) private var scenePhase

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
            .onChange(of: viewModel.relinkDownloadsNotice) { message in
                // Announced once when a relink produces the notice; the banner reappearing after a reload
                // or a pushed screen is not news.
                if let message {
                    UIAccessibility.post(notification: .announcement, argument: message)
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase != .active { viewModel.cancelGroupSwitch() }
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
            .sheet(item: downloadSheetBinding, onDismiss: {
                // Reports the end of the dismissal, so a metered prompt held behind this sheet can be shown.
                viewModel.downloadBatch.downloadSheetDidDismiss()
            }) { sheet in
                downloadSheetContent(sheet)
                    // Only a sheet that was shown reports its dismissal; the model waits for that and no other.
                    .onAppear { viewModel.downloadBatch.downloadSheetDidAppear() }
            }
            .confirmationDialog(
                String(localized: "Use Metered Data?", comment: "Confirmation for one download batch on cellular or a hotspot"),
                isPresented: Binding(
                    get: { viewModel.downloadBatch.meteredPrompt != nil },
                    // The dialog hides itself while a button's action is still to run: that action resolves the
                    // batch it presented, so only Cancel drops it.
                    set: { if !$0 { viewModel.downloadBatch.hideMeteredPrompt() } }
                ),
                titleVisibility: .visible,
                presenting: viewModel.downloadBatch.meteredPrompt
            ) { prompt in
                Button(String(localized: "Use Metered Data for This Batch", comment: "Grants cellular permission only to this exact download batch")) {
                    viewModel.downloadBatch.resolveMeteredPrompt(prompt.id, useMeteredData: true)
                }
                Button(String(localized: "Queue and Wait for Wi-Fi", comment: "Queues downloads without cellular permission")) {
                    viewModel.downloadBatch.resolveMeteredPrompt(prompt.id, useMeteredData: false)
                }
                Button("Cancel", role: .cancel) { viewModel.downloadBatch.cancelMeteredPrompt() }
            } message: { _ in
                Text("This batch may use cellular data or a personal hotspot while the app stays in the foreground. Other downloads and prefetching are not approved.", comment: "Scope of temporary metered download permission")
            }
            .alert(
                String(localized: "Switch groups?", comment: "Reader consent title: open one exact upload from another translation group"),
                // The buttons decide: a setter that cancelled could run before Continue's action.
                isPresented: Binding(get: { viewModel.groupSwitchConsent != nil }, set: { _ in }),
                presenting: viewModel.groupSwitchConsent
            ) { consent in
                Button(String(localized: "Open This Upload", comment: "Reader consent alert button: opens the one upload from another translation group, for this reading only")) { viewModel.confirmGroupSwitch(consent.id) }
                Button("Cancel", role: .cancel) { viewModel.cancelGroupSwitch() }
            } message: { consent in
                Text(consent.message)
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

    private var downloadSheetBinding: Binding<DownloadSheet?> {
        Binding(
            get: { viewModel.downloadBatch.sheet },
            set: { if $0 == nil { viewModel.downloadBatch.dismissDownloadSheet() } }
        )
    }

    /// The one download sheet: the scanlator chooser, then the preview, in the same presentation.
    @ViewBuilder
    private func downloadSheetContent(_ sheet: DownloadSheet) -> some View {
        switch sheet {
        case .chooser(let presentation):
            EditionChooserSheet(
                presentation: presentation,
                isApplying: viewModel.downloadBatch.isApplyingChoice,
                onConfirm: { selection, remember in
                    _ = viewModel.downloadBatch.applyEditionChoice(
                        selection, remember: remember, then: presentation.preset, chooserID: presentation.id
                    )
                },
                onCancel: viewModel.downloadBatch.dismissDownloadSheet
            )
        case .preview(let preview):
            DownloadPreviewSheet(
                preview: preview,
                availableBytes: viewModel.downloadBatch.availableBytes,
                isEnqueuing: viewModel.downloadBatch.isEnqueuing,
                onConfirm: { viewModel.downloadBatch.confirmDownloadPreview(including: $0, previewID: preview.id) },
                onCancel: viewModel.downloadBatch.dismissDownloadSheet,
                onEditFallback: { viewModel.downloadBatch.editFallbackOrder(previewID: preview.id) }
            )
        }
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
        case .content, .failure, .savedOnly:
            loadedChapterSection
        }
    }

    @ViewBuilder
    private var loadedChapterSection: some View {
        if let message = viewModel.relinkDownloadsNotice {
            relinkDownloadsNotice(message)
        }

        if case .failure(let message) = viewModel.detailLoadState {
            detailFailureBanner(message: message, notice: viewModel.offlineNotice)
        }

        if let notice = viewModel.offlineNotice, notice.kind == .savedOnly {
            savedOnlyNotice(notice)
        }

        let displayed = viewModel.displayedChapters
        let chapters = viewModel.media.chapterList ?? []
        // Saved editions the list lacks still show, even when the list itself is empty. An empty list still
        // offers to link the series to a source that has chapters.
        if viewModel.offersRelinkBanner {
            relinkBanner
        }
        if !chapters.isEmpty || viewModel.savedOnlyChapterCount > 0 {
            chapterListHeader(
                totalCount: chapters.count + viewModel.savedOnlyChapterCount,
                displayedChapters: displayed
            )
            let textKeys = chapters.textChapterKeysInMixedSeries(defaultKind: viewModel.media is Novel ? .text : .images)
            chapterList(chapters: displayed, textKeys: textKeys)
        } else if !viewModel.offersRelinkBanner,
                  viewModel.detailLoadState == .content || viewModel.detailLoadState == .savedOnly {
            Text("No content found.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        }
    }

    /// Shown after a relink cancelled queued downloads, until the user dismisses it.
    private func relinkDownloadsNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: viewModel.dismissRelinkDownloadsNotice) {
                Image(systemName: "xmark")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(String(
                localized: "Dismiss",
                comment: "Accessibility label of the button that closes the notice about downloads that were cancelled when a series was linked to another source."
            ))
        }
        .padding(.horizontal, 16)
    }

    /// Shown above a saved series that opens without a source that can refresh it.
    private func savedOnlyNotice(_ notice: MediaDetailOfflineNotice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(
                localized: "Showing saved details. They refresh when the source is available again.",
                comment: "Notice above a saved series shown from this device's saved copy because its source is not installed, is incompatible, or failed to load. The details refresh once the source works again."
            ))
            OfflineNoticeUpdatedLine(notice: notice)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    private func detailFailureBanner(message: String, notice: MediaDetailOfflineNotice?) -> some View {
        VStack(spacing: 12) {
            if let notice, notice.kind == .offline {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 36, weight: .thin))
                    .foregroundStyle(.secondary)
                Text(String(
                    localized: "Offline — showing saved details",
                    comment: "Notice above a saved series whose details could not be refreshed because the device has no network. The details shown are the ones saved on this device."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                OfflineNoticeUpdatedLine(notice: notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36, weight: .thin))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
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
        totalCount: Int,
        displayedChapters: [M.Chapter]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.resumeChapter != nil {
                Button {
                    viewModel.resumeReading()
                } label: {
                    Label(resumeTitle, systemImage: resumeIcon)
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
                allChapterCount: totalCount,
                displayedChapterCount: displayedChapters.count
            )
        }
    }

    private var resumeTitle: String {
        if viewModel.isResumeRereading {
            return viewModel.media is Anime ? String(localized: "Watch Again") : String(localized: "Read Again")
        }
        return viewModel.hasReadProgress ? String(localized: "Resume") : String(localized: "Start")
    }

    private var resumeIcon: String {
        if viewModel.isResumeRereading { return "arrow.counterclockwise" }
        if viewModel.media is Anime { return "play.fill" }
        return viewModel.hasReadProgress ? "book.fill" : "play.fill"
    }

    private func chapterControls(
        allChapterCount: Int,
        displayedChapterCount: Int
    ) -> some View {
        let title = viewModel.media is Anime ? String(localized: "Episodes") : String(localized: "Chapters")
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

                if viewModel.showsBatchDownloadControls {
                    DownloadPresetMenu(
                        isEnabled: !viewModel.downloadBatch.isEnqueuing,
                        onSelect: { viewModel.downloadBatch.startDownload($0) },
                        onChooseScanlators: { viewModel.downloadBatch.openEditionChooser() }
                    )
                    .padding(.trailing, 8)
                }
                chapterFilterMenu(isFiltered: isFiltered)
            }
            .padding(.horizontal, 16)

            if viewModel.showsDownloadControls, !viewModel.downloadBatch.summary.isEmpty {
                SeriesDownloadSummaryView(
                    summary: viewModel.downloadBatch.summary,
                    byteCount: viewModel.downloadBatch.storedBytes,
                    coversEntireSeries: viewModel.offlineCoverage() == .entireSeries
                )
            }

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
                            order.localizedTitle,
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
                            option.localizedTitle,
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
                    ActiveFilterPill(label: viewModel.sortOrder.localizedTitle) {
                        withAnimation { viewModel.sortOrder = .descending }
                    }
                }
                if viewModel.filterOption != .all {
                    ActiveFilterPill(label: viewModel.filterOption.localizedTitle) {
                        withAnimation { viewModel.filterOption = .all }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// `textKeys` comes from the whole series, so a filter that leaves only text chapters keeps their marks.
    private func chapterList(chapters: [M.Chapter], textKeys: Set<String>) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(chapters, id: \.key) { chapter in
                ChapterRowView(
                    chapter: chapter,
                    isRead: viewModel.isRead(chapter),
                    marksText: textKeys.contains(chapter.key),
                    downloadState: viewModel.downloadState(for: chapter),
                    isSavedOnly: viewModel.isSavedOnlyRow(chapter)
                ) {
                    viewModel.selectChapter(chapter)
                }
                .modifier(downloadContextMenu(for: chapter))
                Divider().padding(.leading, 16)
            }
        }
    }

    private func downloadContextMenu(for chapter: M.Chapter) -> DownloadContextMenu<some View> {
        let actions = viewModel.downloadActions(for: chapter)
        return DownloadContextMenu(isEnabled: !actions.isEmpty) {
            downloadMenu(for: chapter, actions: actions)
        }
    }

    /// The chapter's download actions, headed by its state where the state explains what to do next.
    @ViewBuilder
    private func downloadMenu(for chapter: M.Chapter, actions: [ChapterDownloadAction]) -> some View {
        if let state = viewModel.downloadState(for: chapter), state.explainsMenu {
            state.label
        }
        ForEach(actions) { action in
            Button(role: action == .delete ? .destructive : nil) {
                viewModel.performDownloadAction(action, for: chapter)
            } label: {
                Label { action.title } icon: { Image(systemName: action.systemImage) }
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
                    relinkEmptyState(message: String(localized: "No results found. Try again."))
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
                    // The app's image pipeline, so plugin (`ito://`) covers load too.
                    LazyImage(url: URL(string: result.cover ?? "")) { state in
                        if let image = state.image {
                            image.resizable().scaledToFill()
                        } else {
                            Rectangle().fill(.quaternary)
                        }
                    }
                    .processors([.resize(width: 96)])
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

/// Attaches a context menu only when there is something in it, so rows without download actions, and every
/// row where downloads are not composed, keep exactly the interaction they had before.
private struct DownloadContextMenu<MenuItems: View>: ViewModifier {
    let isEnabled: Bool
    @ViewBuilder let menuItems: () -> MenuItems

    func body(content: Content) -> some View {
        if isEnabled {
            content.contextMenu { menuItems() }
        } else {
            content
        }
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

/// "Updated 3 hours ago", kept current while the screen stays open.
private struct OfflineNoticeUpdatedLine: View {
    let notice: MediaDetailOfflineNotice

    var body: some View {
        if notice.refreshedAt != nil {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if let text = notice.updatedText(relativeTo: context.date) {
                    Text(text)
                }
            }
        }
    }
}
