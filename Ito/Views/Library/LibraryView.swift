import SwiftUI
import Nuke
import NukeUI
import ito_runner

struct LibraryView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let viewFactory: AppViewFactory
    @State private var settingsFailure: LibraryUpdateFailure?
    @State private var signInTarget: PluginSignInTarget?
    @State private var trustAction: TrustCertificateAction?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let columns = [
        // Top-aligned so a two-line title doesn't push its cover up the row.
        GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 12, alignment: .top)
    ]

    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                switch viewModel.phase {
                case .loading:
                    loadingSkeletonView
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
        }
        .navigationViewStyle(.stack)
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
                noResultsView
            } else {
                contentScrollView
            }
        }
    }

    private var contentScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                updateFailureSection
                if viewModel.layoutStyle == .tabbed && viewModel.selectedCategoryID == nil {
                    Section {
                        libraryGrid(items: viewModel.filteredItems)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)
                    }
                } else {
                    ForEach(viewModel.groups) { group in
                        Section {
                            if group.items.isEmpty {
                                actionableEmptyState(for: group.name)
                            } else {
                                libraryGrid(items: group.items)
                                    .padding(.horizontal, 16)
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

    private func libraryGrid(items: [LibraryItem]) -> some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(items) { item in
                LibraryItemView(
                    item: item,
                    badgeCount: viewModel.badgeCount(for: item),
                    savedCount: viewModel.savedCount(for: item),
                    isPluginInstalled: viewModel.isPluginInstalled(for: item),
                    isEditing: viewModel.isEditing,
                    destination: viewFactory.makeDeferredPluginView(item: item),
                    onSelect: { viewModel.itemSelected(item) },
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
                NavigationLink(destination: viewFactory.makeHistoryView()) {
                    Image(systemName: "clock.arrow.circlepath")
                        .accessibilityLabel("History")
                }
                if viewFactory.hasDownloads {
                    NavigationLink(destination: viewFactory.makeDownloadsView()) {
                        Image(systemName: "arrow.down.circle")
                            .accessibilityLabel(Text("Downloads", comment: "Library toolbar: open the downloads manager"))
                    }
                }
                if viewModel.hasItems {
                    Button {
                        Task { await viewModel.requestUpdate() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .accessibilityLabel("Check for Updates")
                    }
                    .disabled(viewModel.isRefreshing)
                }
                NavigationLink(destination: viewFactory.makeCategorySettingsView()) {
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
                    Button {
                        viewModel.beginExport()
                    } label: {
                        Label("Export Library", systemImage: "square.and.arrow.up")
                    }
                    .disabled(viewModel.isGeneratingExport)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("More Options")
                }
            }
        }
    }

    private var loadingSkeletonView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
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
                        destination: viewFactory.makeDeferredPluginView(item: fakeItem),
                        onSelect: {},
                        onCoverLoaded: { _ in },
                        loadDurableCover: { nil },
                        onAssignCategories: {},
                        onRemove: {}
                    )
                }
            }
            .padding(.horizontal, 16)
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

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No Results")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Nothing in your library matches\n\"\(viewModel.searchText)\".")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
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
    let item: LibraryItem
    let badgeCount: Int
    /// Verified saved chapters; the card shows nothing for zero.
    let savedCount: Int
    let isPluginInstalled: Bool
    let isEditing: Bool
    let destination: DeferredPluginView
    let onSelect: () -> Void
    /// Told when the card's cover finished loading, with the image it displays.
    let onCoverLoaded: (UIImage) -> Void
    /// Reads the cover saved on this device.
    let loadDurableCover: () async -> UIImage?
    let onAssignCategories: () -> Void
    let onRemove: () -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wiggleAngle = Double.random(in: -1.2...1.2)
    @State private var isWiggling = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            NavigationLink(destination: destination) {
                cardContent.contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isEditing)
            .simultaneousGesture(
                TapGesture().onEnded {
                    guard !isEditing else { return }
                    onSelect()
                }
            )
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
            coverImageView
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
        GeometryReader { geometry in
            let width = geometry.size.width
            let targetSize = CGSize(
                width: width * displayScale,
                height: width * 1.5 * displayScale
            )
            ZStack(alignment: .topTrailing) {
                coverContent(width: width, targetSize: targetSize)
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
                }
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .overlay(alignment: .bottomLeading) {
            if savedCount > 0 {
                savedChip
            }
        }
        .cornerRadius(8)
        .clipped()
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

    @ViewBuilder
    private func coverContent(width: CGFloat, targetSize: CGSize) -> some View {
        if let coverURL = item.coverUrl, let url = URL(string: coverURL) {
            LazyImage(url: url) { state in
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

/// Shows the cover kept on this device in place of a cover that is loading or failed, and the placeholder when
/// there is none.
private struct DurableCoverFallback<Placeholder: View>: View {
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

struct DeferredPluginView: View {
    @StateObject private var viewModel: DeferredPluginViewModel
    let viewFactory: AppViewFactory

    init(item: LibraryItem, openIntent: MediaDetailOpenIntent? = nil, viewFactory: AppViewFactory) {
        _viewModel = StateObject(
            wrappedValue: viewFactory.makeDeferredPluginViewModel(item: item, openIntent: openIntent)
        )
        self.viewFactory = viewFactory
    }

    var body: some View {
        content
            .onAppear { viewModel.appear() }
            .onDisappear { viewModel.disappear() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .decoding, .loadingRunner, .loadingSavedDetails, .cancelled:
            loadingView(label: "Loading…")
        case .checkingPackage:
            loadingView(label: "Searching repositories…")
        case .installing:
            loadingView(label: "Installing extension…")
        case .pluginMissing:
            missingPluginView
        case .packageUnavailable:
            failureView(
                title: "Extension Not Found",
                message: Text("This extension was not found in your configured repositories."),
                retryTitle: "Search Again",
                retry: viewModel.installMissingPlugin
            )
        case .incompatible(let incompatibility):
            failureView(
                title: "Extension Incompatible",
                message: Self.incompatibilityMessage(incompatibility),
                retryTitle: nil,
                retry: nil
            )
        case .failure(let failure):
            deferredFailureView(failure)
        case .ready(let route):
            viewFactory.makeDeferredPluginDestination(route.destination, openIntent: route.openIntent)
                .id(route.id)
        }
    }

    private func loadingView(label: LocalizedStringKey) -> some View {
        VStack(spacing: 14) {
            ProgressView().scaleEffect(1.2)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingPluginView: some View {
        VStack(spacing: 20) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 6) {
                Text("Extension Required")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(
                    "To read this content, you must install the '\(viewModel.item.pluginId)' extension."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            Button(action: viewModel.installMissingPlugin) {
                Text("Search Repositories & Install")
                    .font(.headline)
                    .foregroundColor(.itoOnAccent)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }
            .padding(.top, 10)
            if viewModel.canOpenSavedDetails {
                Button(action: viewModel.openSavedDetails) {
                    Text(
                        "Open Saved Details",
                        comment: "Button on a library series whose source is unavailable: shows the details saved in the library."
                    )
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func deferredFailureView(_ failure: DeferredPluginFailure) -> some View {
        switch failure {
        case .packageLookup:
            failureView(
                title: "Repository Search Failed",
                message: Text("The configured repositories could not be refreshed. Please try again."),
                retryTitle: "Search Again",
                retry: viewModel.installMissingPlugin
            )
        case .pluginTypeMismatch:
            failureView(
                title: "Extension Type Mismatch",
                message: Text("The saved item and extension types do not match."),
                retryTitle: "Retry",
                retry: viewModel.retry
            )
        case .install:
            failureView(
                title: "Installation Failed",
                message: viewModel.installRefusal.map { Text(verbatim: $0.message) }
                    ?? Text("The extension could not be installed. Please try again."),
                retryTitle: "Retry Install",
                retry: viewModel.installMissingPlugin
            )
        case .runnerLoad:
            failureView(
                title: "Couldn't Load Plugin",
                message: viewModel.runnerRefusal.map { Text(verbatim: $0.message) }
                    ?? Text("The installed extension could not be loaded."),
                retryTitle: "Retry",
                retry: viewModel.retry
            )
        case .payloadDecode:
            failureView(
                title: "Couldn't Load Saved Item",
                message: Text("The saved media data is invalid or incompatible."),
                retryTitle: "Retry",
                retry: viewModel.retry,
                savedFields: viewModel.savedFieldsFallback
            )
        }
    }

    /// The explanation on a saved series' screen when its source is refused by the repositories' feed. Text that is
    /// already localized is passed verbatim, so it is never looked up again as a key.
    private static func incompatibilityMessage(_ incompatibility: PluginIncompatibility) -> Text {
        switch incompatibility {
        case .requiresNewerApp(let minimumVersion?):
            return Text("This extension requires Ito \(minimumVersion) or later.")
        case .requiresNewerApp(nil):
            return Text("This extension requires a newer version of Ito.")
        case .requiresSourceUpdate:
            // Reached only from the feed lookup, which checks every repository for a compatible build first.
            return Text(verbatim: String(
                localized: "No compatible source update is available yet.",
                comment: "Shown where a source was built for an older version of Ito and no repository offers a compatible version: a source package's status label, and a saved series' failure message. The source's publisher must release an update."
            ))
        case .unsupportedFile:
            return Text(verbatim: incompatibility.message)
        }
    }

    private func failureView(
        title: LocalizedStringKey,
        message: Text,
        retryTitle: LocalizedStringKey?,
        retry: (() -> Void)?,
        savedFields: DeferredSavedFields? = nil
    ) -> some View {
        // Scrolls, so Retry stays reachable at accessibility text sizes; short content stays centered.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    if let savedFields {
                        savedFieldsHeader(savedFields)
                    }
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 42, weight: .thin))
                        .foregroundStyle(.red)
                    Text(title).font(.headline)
                    message
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    if let retryTitle, let retry {
                        Button(retryTitle, action: retry)
                            .itoProminentButtonStyle()
                    }
                    if viewModel.canOpenSavedDetails {
                        Button(action: viewModel.openSavedDetails) {
                            Text(
                                "Open Saved Details",
                                comment: "Button on a library series whose source is unavailable: shows the details saved in the library."
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }

    /// The series the Library row still names, with the cover it saved: the cover from the network cache, or
    /// the one this device kept while that is loading or failed.
    private func savedFieldsHeader(_ savedFields: DeferredSavedFields) -> some View {
        VStack(spacing: 8) {
            savedCover(savedFields)
                .frame(width: 96, height: 144)
                .cornerRadius(8)
                .clipped()
                .accessibilityHidden(true)
            Text(verbatim: savedFields.title)
                .font(.title3)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func savedCover(_ savedFields: DeferredSavedFields) -> some View {
        let loadKey = "\(viewModel.item.id)\u{1F}\(viewModel.item.coverUrl ?? "")"
        if let url = savedFields.coverURL {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    DurableCoverFallback(
                        loadKey: loadKey, load: viewModel.savedCover, width: 96,
                        saturation: 1, failed: state.error != nil
                    ) { _ in Color.itoCardBackground }
                }
            }
        } else {
            DurableCoverFallback(
                loadKey: loadKey, load: viewModel.savedCover, width: 96,
                saturation: 1, failed: false
            ) { _ in Color.itoCardBackground }
        }
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
