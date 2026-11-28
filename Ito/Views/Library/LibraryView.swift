import SwiftUI
import Nuke
import NukeUI
import ito_runner

struct LibraryView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject var navigator: PaneNavigator<LibraryDetailSelection>
    let viewFactory: AppViewFactory
    @State private var settingsFailure: LibraryUpdateFailure?
    @State private var signInTarget: PluginSignInTarget?
    @State private var trustAction: TrustCertificateAction?
    @State private var listScreen: LibraryListScreen?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        PaneHost(
            navigator: navigator,
            placeholder: PanePlaceholder(
                systemImage: "books.vertical",
                title: Text("No Series Selected", comment: "Title of the Library detail placeholder shown when no series is selected"),
                message: Text("Choose a series to see its details.", comment: "Message of the Library detail placeholder shown when no series is selected")
            ),
            listWidthRule: .library,
            willCollapse: { listScreen = LibraryPaneRules.screenAfterCollapse(listScreen) },
            list: { libraryRoot },
            detail: { viewFactory.makeLibraryDetail($0) }
        )
        .sheet(item: $settingsFailure, onDismiss: {
            Task { await viewModel.requestUpdate() }
        }) { failure in
            viewFactory.makePluginSettingsSheet(pluginID: failure.pluginID)
        }
        .sheet(item: $signInTarget, onDismiss: {
            Task { await viewModel.requestUpdate() }
        }) { target in
            viewFactory.makePluginSignInSheet(target: target)
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
        .onAppear { viewModel.appear() }
        .onDisappear { viewModel.disappear() }
    }

    /// The list column: the grid and its toolbar, plus the links the toolbar opens over the grid.
    private var libraryRoot: some View {
        ZStack(alignment: .top) {
            switch viewModel.phase {
            case .loading:
                WidthClassReader { widthClass, size in
                    loadingSkeletonScrollView(columns: widthClass.spacing.gridColumns(forWidth: size.width), spacing: widthClass.spacing)
                }
            case .empty:
                emptyStateView
            case .content:
                mainContentView
            }

            if viewModel.isRefreshing {
                UpdateProgressBanner(
                    current: viewModel.updateProgressCurrent,
                    total: viewModel.updateProgressTotal
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(2)
            }
        }
        // The category chips scroll sideways and would draw into the trailing inset, under iOS 27's side tab pill.
        .clipShape(TrailingEdgeClip(layoutDirection: layoutDirection))
        .navigationTitle("Library")
        .toolbar { toolbarContent }
        .searchable(
            text: $viewModel.searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search library"
        )
        .fileExporter(
            isPresented: exportPresentationBinding,
            document: viewModel.exportPresentation?.document,
            contentType: .itoBackup,
            defaultFilename: viewModel.exportPresentation?.defaultFilename ?? "ItoBackup"
        ) { result in
            switch result {
            case .success:
                viewModel.exporterDidSucceed()
            case .failure:
                viewModel.exporterDidFail()
            }
        }
        .alert(isPresented: alertBinding) {
            Alert(
                title: Text(viewModel.alert?.title ?? String(localized: "Backup Error")),
                message: Text(viewModel.alert?.message ?? String(localized: "The operation failed.")),
                dismissButton: .default(Text("OK")) {
                    viewModel.dismissAlert()
                }
            )
        }
        .paneDetailLink(isEnabled: listScreen == nil)
        .background {
            LibraryListScreenLinks(listScreen: $listScreen, navigator: navigator, viewFactory: viewFactory)
        }
    }

    private var exportPresentationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.exportPresentation != nil },
            set: { isPresented in
                if !isPresented { viewModel.dismissExportPresentation() }
            }
        )
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.alert != nil },
            set: { isPresented in
                if !isPresented { viewModel.dismissAlert() }
            }
        )
    }

    private var mainContentView: some View {
        VStack(spacing: 0) {
            if viewModel.isOffline {
                OfflineBanner(
                    text: String(
                        localized: "Offline — showing saved Library",
                        comment: "Banner above the Library grid while the device has no network. The series, details and covers shown are the ones saved on this device."
                    ),
                    systemImage: "wifi.slash"
                )
            }
            if viewModel.layoutStyle == .tabbed {
                pillBar
                Divider()
            }
            if viewModel.showsNoResults {
                updateFailureSection
                LibraryNoResultsView(
                    searchText: viewModel.searchText,
                    isFiltered: viewModel.offlineFacet != .all,
                    isAwaitingOfflineProofs: viewModel.isAwaitingOfflineProofs
                )
            } else {
                WidthClassReader { widthClass, size in
                    // The grid width comes from the container this view is given, so the column count follows the layout.
                    libraryScrollView(columns: widthClass.spacing.gridColumns(forWidth: size.width), spacing: widthClass.spacing, isCompact: widthClass == .compact)
                }
            }
        }
    }

    private func libraryScrollView(columns: [GridItem], spacing: LayoutSpacing, isCompact: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                if let entry = viewModel.continueEntry {
                    LibraryContinueSlot(
                        isCompact: isCompact,
                        entry: entry,
                        isPluginInstalled: viewModel.isPluginInstalled(for: entry.item),
                        onCoverLoaded: { image in viewModel.coverLoaded(for: entry.item, image: image) },
                        loadDurableCover: { await viewModel.durableCover(for: entry.item) },
                        onContinue: {
                            navigator.select(
                                .opened(
                                    entry.item,
                                    intent: .resume(
                                        preferredScanlator: entry.record.scanlator,
                                        preferredScanlatorID: entry.record.scanlatorID
                                    )
                                )
                            )
                        },
                        spacing: spacing
                    )
                }
                updateFailureSection
                if viewModel.layoutStyle == .tabbed && viewModel.selectedCategoryID == nil {
                    Section {
                        libraryGrid(items: viewModel.filteredItems, columns: columns, spacing: spacing)
                            .padding(.horizontal, spacing.margin)
                            .padding(.bottom, 24)
                    }
                } else {
                    ForEach(viewModel.groups) { group in
                        Section {
                            if group.items.isEmpty {
                                actionableEmptyState(for: group.name)
                            } else {
                                libraryGrid(items: group.items, columns: columns, spacing: spacing)
                                    .padding(.horizontal, spacing.margin)
                                    .padding(.bottom, 24)
                            }
                        } header: {
                            if viewModel.layoutStyle == .sectioned {
                                SectionHeaderView(
                                    label: group.name,
                                    icon: group.isSystem ? "tray" : "folder",
                                    count: group.items.count
                                )
                            }
                        }
                    }
                }
            }
            .padding(.top, viewModel.layoutStyle == .sectioned ? 4 : 16)
            .padding(.bottom, 16)
        }
        .refreshable { await viewModel.requestUpdate() }
        .sheet(item: categoryAssignmentBinding) { intent in
            viewFactory.makeCategoryAssignmentSheet(itemID: intent.id)
        }
        .confirmationDialog(
            "Remove from Library?",
            isPresented: removalConfirmationBinding,
            titleVisibility: .visible,
            presenting: viewModel.pendingRemoval
        ) { request in
            if request.hasDownloads {
                Button("Remove from Library") {
                    viewModel.confirmRemoval(request, includingDownloads: false)
                }
                Button(role: .destructive) {
                    viewModel.confirmRemoval(request, includingDownloads: true)
                } label: {
                    Text(
                        "Remove Library and Downloads",
                        comment: "Removes the series from the Library and deletes its saved chapters and queued downloads"
                    )
                }
            } else {
                Button("Remove", role: .destructive) {
                    viewModel.confirmRemoval(request, includingDownloads: false)
                }
            }
        } message: { request in
            Text(request.message)
        }
    }

    @ViewBuilder
    private var updateFailureSection: some View {
        if !viewModel.updateFailures.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Some sources couldn't update", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                ForEach(viewModel.updateFailures) { failure in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewFactory.sourceName(pluginID: failure.pluginID))
                            .font(.caption.weight(.semibold))
                        Text(failure.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if failure.needsSettings {
                            Button("Open Settings") {
                                settingsFailure = failure
                            }
                            .font(.caption.weight(.semibold))
                            .disabled(viewModel.isRefreshing)
                        }
                        if failure.needsLogin, let target = viewFactory.signInTarget(pluginID: failure.pluginID) {
                            Button("Sign In") {
                                signInTarget = target
                            }
                            .font(.caption.weight(.semibold))
                            .disabled(viewModel.isRefreshing)
                        }
                        if let request = failure.pendingTrust ?? viewFactory.pendingTrust(for: failure.pluginID) {
                            Button("Trust Certificate…") {
                                trustAction = viewFactory.trustAction(for: request) {
                                    Task { await viewModel.requestUpdate() }
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .disabled(viewModel.isRefreshing)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingRemoval != nil },
            set: { isPresented in
                if !isPresented { viewModel.cancelRemoval() }
            }
        )
    }

    private var categoryAssignmentBinding: Binding<LibraryCategoryAssignmentIntent?> {
        Binding(
            get: {
                viewModel.categoryAssignmentItemID.map {
                    LibraryCategoryAssignmentIntent(id: $0)
                }
            },
            set: { intent in
                if let intent {
                    viewModel.presentCategoryAssignment(for: intent.id)
                } else {
                    viewModel.dismissCategoryAssignment()
                }
            }
        )
    }

    private func libraryGrid(items: [LibraryItem], columns: [GridItem], spacing: LayoutSpacing) -> some View {
        LazyVGrid(columns: columns, spacing: spacing.gridRowSpacing) {
            ForEach(items) { item in
                LibraryItemView(
                    item: item,
                    badgeCount: viewModel.badgeCount(for: item),
                    savedCount: viewModel.savedCount(for: item),
                    isPluginInstalled: viewModel.isPluginInstalled(for: item),
                    isEditing: viewModel.isEditing,
                    isSelected: navigator.selection?.item.id == item.id,
                    progress: viewModel.seriesProgress[item.id],
                    onOpen: {
                        viewModel.itemSelected(item)
                        navigator.select(.plain(item))
                    },
                    onCoverLoaded: { image in viewModel.coverLoaded(for: item, image: image) },
                    loadDurableCover: { await viewModel.durableCover(for: item) },
                    onAssignCategories: {
                        viewModel.presentCategoryAssignment(for: item.id)
                    },
                    onRemove: { viewModel.requestRemoval(item) }
                )
            }
        }
    }

    @ViewBuilder
    private var pillBar: some View {
        if dynamicTypeSize >= .accessibility1 {
            Picker("List", selection: categorySelectionBinding) {
                Text("All").tag(String?.none)
                ForEach(viewModel.categories) { category in
                    Text(category.name).tag(String?.some(category.id))
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal)
            .padding(.vertical, 8)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    pillButton(title: String(localized: "All", comment: "Filter chip: show every list"), id: nil)
                    ForEach(viewModel.categories) { category in
                        pillButton(title: category.name, id: category.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private var categorySelectionBinding: Binding<String?> {
        Binding(
            get: { viewModel.selectedCategoryID },
            set: { viewModel.selectCategory($0) }
        )
    }

    private func pillButton(title: String, id: String?) -> some View {
        let isSelected = viewModel.selectedCategoryID == id
        return Button {
            withAnimation(.snappy) { viewModel.selectCategory(id) }
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .frame(minWidth: 44, minHeight: 44)
                .background(isSelected ? Color.accentColor : Color(.systemGray5))
                .foregroundColor(isSelected ? .itoOnAccent : .primary)
                .clipShape(Capsule())
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            HStack(spacing: 16) {
                Button {
                    listScreen = .history
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .accessibilityLabel("History")
                }
                if viewFactory.hasDownloads {
                    Button {
                        listScreen = .downloads
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .accessibilityLabel(Text("Downloads", comment: "Library toolbar: open the downloads manager"))
                    }
                }
                Button {
                    listScreen = .lists
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .accessibilityLabel("Manage Lists")
                }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 16) {
                Button {
                    withAnimation { viewModel.toggleLayout() }
                } label: {
                    Image(
                        systemName: viewModel.layoutStyle == .sectioned
                            ? "rectangle.grid.1x2"
                            : "square.grid.2x2"
                    )
                }
                .accessibilityLabel(
                    viewModel.layoutStyle == .sectioned
                        ? String(localized: "Switch to tabbed layout")
                        : String(localized: "Switch to sectioned layout")
                )
                if viewModel.hasItems {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.toggleEditing()
                        }
                    } label: {
                        Text(viewModel.isEditing ? "Done" : "Edit")
                            .font(.body)
                            .fontWeight(viewModel.isEditing ? .semibold : .regular)
                    }
                }
                Menu {
                    if viewModel.supportsOfflineFacets {
                        LibraryOfflineFilterPicker(viewModel: viewModel)
                    }
                    if viewModel.hasItems {
                        Button {
                            Task { await viewModel.requestUpdate() }
                        } label: {
                            Label("Check for Updates", systemImage: "arrow.clockwise")
                        }
                        .disabled(viewModel.isRefreshing)
                    }
                    Button {
                        viewModel.beginExport()
                    } label: {
                        Label("Export Library", systemImage: "square.and.arrow.up")
                    }
                    .disabled(viewModel.isGeneratingExport)
                } label: {
                    Image(systemName: viewModel.offlineFacet == .all ? "ellipsis.circle" : "ellipsis.circle.fill")
                        .accessibilityLabel("More Options")
                        .accessibilityValue(
                            viewModel.offlineFacet == .all
                                ? Text(verbatim: "")
                                : LibraryOfflineFilterPicker.title(for: viewModel.offlineFacet)
                        )
                }
            }
        }
    }

    private func loadingSkeletonScrollView(columns: [GridItem], spacing: LayoutSpacing) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: spacing.gridRowSpacing) {
                ForEach(0..<8, id: \.self) { index in
                    let fakeItem = LibraryItem(
                        id: "loading-\(index)",
                        title: "Loading Item Title",
                        coverUrl: nil,
                        pluginId: "",
                        isAnime: false,
                        pluginType: .manga,
                        rawPayload: Data(),
                        anilistId: nil
                    )
                    LibraryItemView(
                        item: fakeItem,
                        badgeCount: 0,
                        savedCount: 0,
                        isPluginInstalled: true,
                        isEditing: false,
                        isSelected: false,
                        onOpen: {},
                        onCoverLoaded: { _ in },
                        loadDurableCover: { nil },
                        onAssignCategories: {},
                        onRemove: {}
                    )
                }
            }
            .padding(.horizontal, spacing.margin)
            .padding(.top, 16)
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
    }

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Your Library is Empty")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Manga, anime, and novels you save\nwill appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    private func actionableEmptyState(for categoryName: String) -> some View {
        VStack(spacing: 14) {
            Text("No items in \(categoryName).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Browse Discover", action: viewModel.browseDiscover)
            .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

/// Hidden links that present the toolbar's History, Downloads, and Manage Lists screens.
///
/// Driven by `listScreen` so the toolbar can open a screen with a plain button in both the
/// stack and split layouts.
private struct LibraryListScreenLinks: View {
    @Binding var listScreen: LibraryListScreen?
    let navigator: PaneNavigator<LibraryDetailSelection>
    let viewFactory: AppViewFactory
    @Environment(\.paneArrangement) private var arrangement

    var body: some View {
        ZStack {
            NavigationLink(
                tag: LibraryListScreen.history,
                selection: binding(for: .history),
                destination: { viewFactory.makeHistoryView() },
                label: { EmptyView() }
            )
            if viewFactory.hasDownloads {
                NavigationLink(
                    tag: LibraryListScreen.downloads,
                    selection: binding(for: .downloads),
                    destination: { viewFactory.makeDownloadsView() },
                    label: { EmptyView() }
                )
            }
            NavigationLink(
                tag: LibraryListScreen.lists,
                selection: binding(for: .lists),
                destination: { viewFactory.makeCategorySettingsView() },
                label: { EmptyView() }
            )
        }
        .hidden()
    }

    private func binding(for screen: LibraryListScreen) -> Binding<LibraryListScreen?> {
        Binding(
            get: { listScreen == screen ? screen : nil },
            set: { newValue in
                guard newValue == nil, listScreen == screen else { return }
                listScreen = nil
                if LibraryPaneRules.clearsSelection(afterClosing: screen, arrangement: arrangement) {
                    navigator.clearSelection()
                }
            }
        )
    }
}

struct SectionHeaderView: View {
    let label: String
    let icon: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text("·  \(count)")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Rectangle()
                .fill(.background)
                .ignoresSafeArea(edges: .horizontal)
        )
    }
}

struct LibraryItemView: View {
    @Environment(\.paneShowsSelection) private var showsSelection
    let item: LibraryItem
    let badgeCount: Int
    /// Verified saved chapters; the card shows nothing for zero.
    let savedCount: Int
    let isPluginInstalled: Bool
    let isEditing: Bool
    let isSelected: Bool
    var progress: LibrarySeriesProgress?
    let onOpen: () -> Void
    /// Told when the card's cover finished loading, with the image it displays.
    let onCoverLoaded: (UIImage) -> Void
    /// Reads the cover saved on this device.
    let loadDurableCover: () async -> UIImage?
    let onAssignCategories: () -> Void
    let onRemove: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wiggleAngle = Double.random(in: -1.2...1.2)
    @State private var isWiggling = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: onOpen) {
                cardContent.contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isEditing)
            .accessibilityAddTraits(isSelected && showsSelection ? .isSelected : [])
            .contextMenu {
                Button(action: onAssignCategories) {
                    Label("Add to List...", systemImage: "list.bullet.rectangle")
                }
                Button(role: .destructive, action: onRemove) {
                    Label("Remove from Library", systemImage: "trash")
                }
            }
            if isEditing {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, .red)
                        .background(Color.white.clipShape(Circle()).padding(3))
                        // A 44 pt target around the 22 pt symbol.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Remove \(item.title)")
                .offset(x: -17, y: -17)
                .transition(.scale.combined(with: .opacity))
                .zIndex(1)
            }
        }
        .rotationEffect(.degrees(isWiggling ? wiggleAngle : 0))
        .animation(
            isWiggling
                ? .easeInOut(duration: 0.12).repeatForever(autoreverses: true)
                : .easeInOut(duration: 0.15),
            value: isWiggling
        )
        // Cards that appear while editing wiggle too; Reduce Motion turns the wiggle off.
        .onAppear { isWiggling = isEditing && !reduceMotion }
        .onChange(of: isEditing) { editing in
            withAnimation { isWiggling = editing && !reduceMotion }
        }
        .onChange(of: reduceMotion) { reduce in
            isWiggling = isEditing && !reduce
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                coverImageView
                    .overlay {
                        if isSelected && showsSelection {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.accentColor, lineWidth: 3)
                        }
                    }
                progressLine
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.footnote)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundColor(isPluginInstalled ? .primary : .secondary)
                if !isPluginInstalled {
                    Label("Plugin missing", systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
        }
    }

    private var coverImageView: some View {
        LibraryCoverImageView(
            item: item,
            isPluginInstalled: isPluginInstalled,
            onCoverLoaded: onCoverLoaded,
            loadDurableCover: loadDurableCover
        )
        .overlay(alignment: .topTrailing) {
            if !isPluginInstalled {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange, Color(.systemBackground))
                    .padding(5)
            } else if badgeCount > 0 && !isEditing {
                Text("\(badgeCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red))
                    .overlay(
                        Capsule().stroke(Color(UIColor.systemBackground), lineWidth: 1.5)
                    )
                    .padding(4)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel(updateBadgeAccessibilityLabel)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if savedCount > 0 {
                savedChip
            }
        }
    }

    /// Reading progress under the cover: an accent line over a neutral track. It is absent until something is read.
    @ViewBuilder
    private var progressLine: some View {
        if let progress, progress.isVisible {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                GeometryReader { geometry in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * progress.fraction)
                }
            }
            .frame(height: 3)
            .padding(.top, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Reading progress", comment: "Accessibility label for the reading progress line under a Library card's cover."))
            .accessibilityValue(readProgressValue(progress))
        }
    }

    private func readProgressValue(_ progress: LibrarySeriesProgress) -> String {
        if item.isAnime {
            return String(
                localized: "Read \(progress.readCount) of \(progress.totalCount) episodes",
                comment: "Accessibility value for a Library card's reading progress for an anime series. The placeholders are the number of episodes read and the total number of episodes. Plural-aware: the total can be 1."
            )
        }
        return String(
            localized: "Read \(progress.readCount) of \(progress.totalCount) chapters",
            comment: "Accessibility value for a Library card's reading progress for a manga or novel series. The placeholders are the number of chapters read and the total number of chapters. Plural-aware: the total can be 1."
        )
    }

    /// Verified saved chapters of the series. It is not shown for zero, so a damaged or queued copy never
    /// reads as saved.
    private var savedChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.down.circle.fill")
            Text("\(savedCount) saved", comment: "Library card chip: how many chapters of the series are saved on this device. The count is the number of saved chapters.")
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundColor(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.65)))
        .padding(4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(savedCount) chapters saved", comment: "Accessibility label for a count of chapters saved on this device, on a Library card and in a series' details header. The placeholder is the number of saved chapters."))
    }
}

/// Shows the cover kept on this device in place of a cover that is loading or failed, and the placeholder when
/// there is none.
struct DurableCoverFallback<Placeholder: View>: View {
    let loadKey: String
    let load: () async -> UIImage?
    let width: CGFloat
    let saturation: Double
    let failed: Bool
    @ViewBuilder let placeholder: (Bool) -> Placeholder
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width)
                    .saturation(saturation)
            } else {
                placeholder(failed)
            }
        }
        .task(id: loadKey) {
            image = await load()
        }
    }
}

/// A slim notice above content that is shown from what this device saved.
struct OfflineBanner: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
            .accessibilityElement(children: .combine)
    }
}

struct UpdateProgressBanner: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.8)
                .padding(.trailing, 4)
            Text("Checking for updates... \(current)/\(total)")
                .font(.footnote)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.thickMaterial)
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 3)
        )
        .padding(.top, 8)
    }
}

private struct LibraryCategoryAssignmentIntent: Identifiable {
    let id: String
}

/// A Library cover: the network image, the cover kept on this device while it loads or fails, and a placeholder.
struct LibraryCoverImageView: View {
    @Environment(\.sourceCoverRequests) private var coverRequests
    @Environment(\.displayScale) private var displayScale
    let item: LibraryItem
    let isPluginInstalled: Bool
    /// Told when the cover finished loading, with the image it displays.
    let onCoverLoaded: (UIImage) -> Void
    /// Reads the cover saved on this device.
    let loadDurableCover: () async -> UIImage?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let targetSize = CGSize(
                width: width * displayScale,
                height: width * 1.5 * displayScale
            )
            coverContent(width: width, targetSize: targetSize)
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .cornerRadius(8)
        .clipped()
    }

    @ViewBuilder
    private func coverContent(width: CGFloat, targetSize: CGSize) -> some View {
        if let coverURL = item.coverUrl, let url = URL(string: coverURL) {
            LazyImage(request: coverRequests.request(url, pluginID: item.pluginId)) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: width)
                        .saturation(isPluginInstalled ? 1.0 : 0.35)
                } else {
                    // One view for both states, so the saved cover found while loading is not dropped when the
                    // load then fails.
                    durableCover(width: width, failed: state.error != nil) { failed in
                        if failed {
                            coverPlaceholder(icon: "exclamationmark.triangle")
                        } else {
                            ShimmerView()
                        }
                    }
                }
            }
            // The image is the processed one the card shows; keeping it costs no request.
            .onCompletion { result in
                if case .success(let response) = result {
                    onCoverLoaded(response.image)
                }
            }
            .processors([.resize(size: targetSize)])
        } else {
            coverPlaceholder(icon: "photo.on.rectangle.angled")
        }
    }

    /// The cover saved on this device, while the network cache has none to show.
    private func durableCover<Placeholder: View>(
        width: CGFloat,
        failed: Bool,
        @ViewBuilder placeholder: @escaping (Bool) -> Placeholder
    ) -> some View {
        DurableCoverFallback(
            loadKey: "\(item.id)\u{1F}\(item.coverUrl ?? "")",
            load: loadDurableCover,
            width: width,
            saturation: isPluginInstalled ? 1.0 : 0.35,
            failed: failed,
            placeholder: placeholder
        )
    }

    private func coverPlaceholder(icon: String) -> some View {
        ZStack {
            Color.itoCardBackground
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tertiary)
        }
    }
}

/// The Library's Continue card for compact width: History's latest series, the chapter or episode it reached, and the action that resumes it.
struct LibraryContinueCard: View {
    let entry: LibraryContinueEntry
    let isPluginInstalled: Bool
    /// Told when the cover finished loading, with the image it displays.
    let onCoverLoaded: (UIImage) -> Void
    /// Reads the cover saved on this device.
    let loadDurableCover: () async -> UIImage?
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                LibraryCoverImageView(
                    item: entry.item,
                    isPluginInstalled: isPluginInstalled,
                    onCoverLoaded: onCoverLoaded,
                    loadDurableCover: loadDurableCover
                )
                .frame(width: 112)
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.item.title)
                        .font(.headline)
                        .lineLimit(2)
                        .foregroundStyle(isPluginInstalled ? .primary : .secondary)
                    Text(HistoryViewModel.chapterLabel(for: entry.record))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Button(action: onContinue) {
                Text("Continue", comment: "Library Continue card: resume reading or watching the most recent series from its latest chapter or episode.")
                    .frame(maxWidth: .infinity)
            }
            .itoProminentButtonStyle()
            .controlSize(.large)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.itoCardBackground))
    }
}

/// The Continue card's slot in the Library list. It reads the pane arrangement that PaneHost gives its list content,
/// so it must be rendered inside that content, not in the view that hosts PaneHost.
private struct LibraryContinueSlot: View {
    @Environment(\.paneArrangement) private var arrangement
    let isCompact: Bool
    let entry: LibraryContinueEntry
    let isPluginInstalled: Bool
    let onCoverLoaded: (UIImage) -> Void
    let loadDurableCover: () async -> UIImage?
    let onContinue: () -> Void
    let spacing: LayoutSpacing

    var body: some View {
        if LibraryContinueVisibility.isShown(isCompact: isCompact, arrangement: arrangement) {
            LibraryContinueCard(
                entry: entry,
                isPluginInstalled: isPluginInstalled,
                onCoverLoaded: onCoverLoaded,
                loadDurableCover: loadDurableCover,
                onContinue: onContinue
            )
            .padding(.horizontal, spacing.margin)
            .padding(.top, 16)
            .padding(.bottom, 8)
        }
    }
}
